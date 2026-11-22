import Foundation
import Network

/// スマホに返す状態
struct RemotePageState {
    /// 現在のページ（1始まり）
    var page: Int
    var total: Int
    /// 開いているPDFの識別子。PDFを開くたびに変わる（スマホ側が古いPDFの縮小画像を捨てる合図）
    var doc: Int
}

/// スマホリモコンから操作される側（いま開いているプレゼン）。
/// どのメソッドも必ずメインスレッドから呼ぶ。
protocol RemoteControlTarget: AnyObject {
    /// 操作を受け付けられない状態なら nil
    var remotePageState: RemotePageState? { get }
    func goToNext()
    func goToPrevious()
    /// ページ（1始まり）の縮小画像（JPEG）。描画は裏で行い、completion はメインスレッドで呼ぶ。失敗なら nil
    func remoteSlideJPEG(page: Int, completion: @escaping (Data?) -> Void)
    /// ポインター（赤い点）をスライド上の割合の位置（左上 0,0・右下 1,1）に出す。nil なら消す
    func remotePointer(at position: CGPoint?)
    /// スマホがリモコン画面を読み込んだ（QRパネルを閉じる合図）
    func remoteControlDidConnect()
}

/// スマホのブラウザからページ送りを受け付ける、ごく小さなHTTPサーバー。
///
/// - アプリ全体で1つだけ持つ（`⌘O` でPDFを開き直してもURLと合言葉はそのまま使える）。
/// - 最初に `start` が呼ばれるまで待ち受けを始めない。一度始めたらアプリ終了まで動かす。
/// - 可変状態はすべて `queue`（直列）の上だけで触る。`target` だけはメインスレッド専用。
final class RemoteServer {

    static let shared = RemoteServer()

    /// まず試すポート。使用中なら OS 任せの空きポートに切り替える
    private static let preferredPort: UInt16 = 8765
    /// ヘッダの上限。超えたら切断する
    private static let maxHeaderBytes = 16 * 1024
    /// 何も送ってこない接続を閉じるまでの秒数（iOS Safari は投機的に接続だけ張ることがある）
    private static let idleTimeout: TimeInterval = 5
    /// 同時に抱える接続数の上限。超えた分は即座に閉じる
    private static let maxConnections = 32

    /// URLに載せる合言葉。アプリ起動ごとに作り直す
    let token = RemoteServer.makeToken()

    /// 操作対象。メインスレッドからのみ読み書きする
    weak var target: RemoteControlTarget?

    private let queue = DispatchQueue(label: "app.pdfpresenter.remote", qos: .userInitiated)

    // ここから下は queue の上だけで触る
    private enum State {
        case idle
        case starting
        case ready(UInt16)
    }
    private var state: State = .idle
    private var listeners: [NWListener] = []
    private var waiters: [(UInt16?) -> Void] = []
    private var clients: [ObjectIdentifier: Client] = [:]

    /// 接続元の判定に使うこのMacのネットワーク一覧。ポインターで1秒に40回ほど接続が来るので短時間だけ使い回す
    private var cachedNetworks: [LocalNetwork.Network] = []
    private var cachedNetworksAt: Date = .distantPast
    private static let networksCacheLifetime: TimeInterval = 1.5
    /// 拒否のログを間引くため、アドレスごとに最後に出した時刻を覚える
    private var rejectLoggedAt: [String: Date] = [:]
    private static let rejectLogInterval: TimeInterval = 10

    private init() {}

    // MARK: - 起動

    /// 待ち受けを（まだなら）始め、使えるポート番号をメインスレッドで返す。失敗したら nil。
    func start(completion: @escaping (UInt16?) -> Void) {
        queue.async {
            switch self.state {
            case .ready(let port):
                DispatchQueue.main.async { completion(port) }
            case .starting:
                self.waiters.append(completion)
            case .idle:
                self.waiters.append(completion)
                self.state = .starting
                self.bind(port: Self.preferredPort, attempt: 0)
            }
        }
    }

    /// IPv4 と IPv6 の両方を、同じポート番号の待ち受け1つ（デュアルスタック）で受ける。
    ///
    /// IPv4 用・IPv6 用を別々に持つ形は、NWListener では作れない（IPv6 側が IPv6 専用にならず、
    /// 自分の IPv4 の待ち受けと同じ番号を取れない）。代わりにデュアルスタック1つにしている。
    /// この形でも、他のプロセスが IPv4 だけ・IPv6 だけ・両方のどれでその番号を使っていても bind が失敗するので、
    /// ポートの取り合いは見逃さない（macOS 26 で実験して確認済み）。
    /// まず 8765、取れなければ OS が選んだ空き番号で何回かやり直す
    private static let maxBindAttempts = 5
    private var bindGeneration = 0

    private func bind(port: UInt16?, attempt: Int) {
        cancelListeners()
        bindGeneration += 1
        let generation = bindGeneration
        let label = port.map(String.init) ?? "空きポート"

        makeListener(port: port, generation: generation) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.log("ポート \(label) を取れませんでした: \(error)")
                self.retryBind(after: attempt)
            case .success(let actual):
                self.state = .ready(actual)
                self.announce(port: actual)
                let waiters = self.waiters
                self.waiters = []
                DispatchQueue.main.async { waiters.forEach { $0(actual) } }
            }
        }
    }

    private func retryBind(after attempt: Int) {
        cancelListeners()
        if attempt + 1 < Self.maxBindAttempts {
            log("空きポートに切り替えます")
            bind(port: nil, attempt: attempt + 1)
            return
        }
        log("待ち受けを開始できませんでした")
        state = .idle
        let waiters = self.waiters
        self.waiters = []
        DispatchQueue.main.async { waiters.forEach { $0(nil) } }
    }

    private func cancelListeners() {
        listeners.forEach { $0.cancel() }
        listeners = []
    }

    /// IPv4・IPv6 両方で待ち受ける（IP のバージョンは指定しない）。port == nil は OS 任せ。
    /// 結果（取れたポート番号 or エラー）は最初の1回だけ onResult で返す
    private func makeListener(port: UInt16?, generation: Int,
                              onResult: @escaping (Result<UInt16, Error>) -> Void) {
        let parameters = NWParameters.tcp
        // こちらから接続を閉じる作りなので、終了直後は 8765 に TIME_WAIT が残る。
        // それで再起動のたびにポート（＝URL）が変わらないよう再利用を許す
        parameters.allowLocalEndpointReuse = true

        let newListener: NWListener
        do {
            if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
                newListener = try NWListener(using: parameters, on: nwPort)
            } else {
                newListener = try NWListener(using: parameters)
            }
        } catch {
            onResult(.failure(error))
            return
        }

        listeners.append(newListener)
        var reported = false
        newListener.stateUpdateHandler = { [weak self, weak newListener] newState in
            guard let self, let newListener, generation == self.bindGeneration,
                  self.listeners.contains(where: { $0 === newListener }) else { return }
            switch newState {
            case .ready:
                guard !reported, let actual = newListener.port?.rawValue else { return }
                reported = true
                onResult(.success(actual))
            case .failed(let error), .waiting(let error):
                // 使用中のポートは .failed で来ることも .waiting で来ることもあるので同じに扱う
                if !reported {
                    reported = true
                    newListener.cancel()
                    self.listeners.removeAll { $0 === newListener }
                    onResult(.failure(error))
                } else if case .ready = self.state {
                    // 稼働後に落ちたら止め、次に R が押されたとき起動し直せるよう初期状態に戻す
                    self.cancelListeners()
                    self.state = .idle
                    self.log("待ち受けが停止しました: \(error)")
                }
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.start(queue: queue)
    }

    /// 待ち受けできたことを標準出力へ知らせる（検証・開発用）。リダイレクト先にも即座に書かれるよう flush する
    private func announce(port: UInt16) {
        let host = LocalNetwork.preferredHost() ?? "127.0.0.1"
        print("Remote URL: \(Self.url(host: host, port: port, token: token))")
        fflush(stdout)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[Remote] \(message)\n".utf8))
    }

    static func url(host: String, port: UInt16, token: String) -> String {
        "http://\(LocalNetwork.urlHost(host)):\(port)/r/\(token)"
    }

    // MARK: - 接続

    /// 1接続ぶんの状態（queue の上だけで触る）
    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var timeout: DispatchWorkItem?
        var responded = false
        init(connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        // 同じネットワークの機器からの接続だけ受け付ける。拒否する接続は応答せずすぐ閉じ、上限にも数えない
        guard isAllowedPeer(connection) else {
            connection.cancel()
            return
        }
        guard clients.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let client = Client(connection: connection)
        let id = ObjectIdentifier(client)
        clients[id] = client

        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled:
                self?.forget(id)
            default:
                break
            }
        }

        // 何も送ってこない・ゆっくりしか送ってこない接続は一定時間で打ち切る
        let timeout = DispatchWorkItem { [weak self, weak client] in
            guard let client, !client.responded else { return }
            client.connection.cancel()
            self?.forget(id)
        }
        client.timeout = timeout
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: timeout)

        connection.start(queue: queue)
        receive(client)
    }

    /// 接続元のアドレスが同じネットワークか（queue の上で呼ぶ）。アドレスが取れなければ拒否
    private func isAllowedPeer(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = connection.endpoint else {
            logRejected("\(connection.endpoint)")
            return false
        }
        let bytes: [UInt8]
        switch host {
        case .ipv4(let address): bytes = [UInt8](address.rawValue)
        case .ipv6(let address): bytes = [UInt8](address.rawValue)
        default:
            logRejected("\(host)")
            return false
        }

        let now = Date()
        let isFresh = now.timeIntervalSince(cachedNetworksAt) < Self.networksCacheLifetime
        if !isFresh {
            cachedNetworks = LocalNetwork.localNetworks()
            cachedNetworksAt = now
        }
        if LocalNetwork.isAllowedPeer(bytes: bytes, networks: cachedNetworks) { return true }
        // 使い回した一覧で拒否になったときは、Wi-Fiの切り替え直後かもしれないので取り直してもう一度判定する
        if isFresh {
            cachedNetworks = LocalNetwork.localNetworks()
            cachedNetworksAt = now
            if LocalNetwork.isAllowedPeer(bytes: bytes, networks: cachedNetworks) { return true }
        }
        logRejected("\(host)")
        return false
    }

    /// 同じアドレスの拒否ログは一定時間に1回まで
    private func logRejected(_ address: String) {
        let now = Date()
        if let last = rejectLoggedAt[address], now.timeIntervalSince(last) < Self.rejectLogInterval { return }
        if rejectLoggedAt.count > 256 { rejectLoggedAt.removeAll() }
        rejectLoggedAt[address] = now
        log("同じネットワーク外からの接続を拒否: \(address)")
    }

    private func forget(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timeout?.cancel()
        client.timeout = nil
    }

    private func close(_ client: Client) {
        client.connection.cancel()
        forget(ObjectIdentifier(client))
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) {
            [weak self, weak client] data, _, isComplete, error in
            guard let self, let client, !client.responded else { return }
            if let data, !data.isEmpty {
                client.buffer.append(data)
            }

            if let end = client.buffer.range(of: Data("\r\n\r\n".utf8)) {
                // ヘッダが揃った。本文（POSTの空ボディ等）は使わないので読まない
                let header = client.buffer.subdata(in: client.buffer.startIndex..<end.lowerBound)
                self.handle(header: header, client: client)
                return
            }
            if client.buffer.count > Self.maxHeaderBytes || isComplete || error != nil {
                self.close(client)
                return
            }
            self.receive(client)
        }
    }

    // MARK: - ルーティング

    private struct Response {
        var status: Int
        var contentType: String?
        var body: Data
        var extraHeaders: [(String, String)] = []

        static func empty(_ status: Int) -> Response {
            Response(status: status, contentType: nil, body: Data())
        }
    }

    private enum Action {
        case state, next, previous
    }

    private func handle(header: Data, client: Client) {
        client.responded = true
        client.timeout?.cancel()
        client.timeout = nil

        guard let text = String(data: header, encoding: .utf8) ?? String(data: header, encoding: .isoLatin1),
              let requestLine = text.components(separatedBy: "\r\n").first else {
            send(.empty(400), to: client)
            return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            send(.empty(400), to: client)
            return
        }
        let method = String(parts[0])
        var path = String(parts[1])
        // クエリは pointer だけが使う。ほかのルートでは従来どおり無視する
        var query = ""
        if let fragment = path.firstIndex(of: "#") {
            path = String(path[..<fragment])
        }
        if let mark = path.firstIndex(of: "?") {
            query = String(path[path.index(after: mark)...])
            path = String(path[..<mark])
        }

        // /r/<token>[/<操作>] と /r/<token>/slide/<n> 以外はすべて 404。合言葉の正誤も教えない
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 3, segments.count <= 5,
              segments[0].isEmpty, segments[1] == "r",
              Self.constantTimeEquals(segments[2], token) else {
            send(.empty(404), to: client)
            return
        }

        if segments.count == 3 {
            guard method == "GET" else {
                send(methodNotAllowed("GET"), to: client)
                return
            }
            send(Response(status: 200, contentType: "text/html; charset=utf-8", body: Data(RemotePage.html.utf8)),
                 to: client)
            // リモコン画面が読み込まれた＝スマホがつながったので、QRパネルを閉じる（state のポーリングでは閉じない）
            DispatchQueue.main.async { [weak self] in
                self?.target?.remoteControlDidConnect()
            }
            return
        }

        if segments.count == 5 {
            guard segments[3] == "slide" else {
                send(.empty(404), to: client)
                return
            }
            guard method == "GET" else {
                send(methodNotAllowed("GET"), to: client)
                return
            }
            // 数字だけ（符号・空白・巨大な桁は不可）。範囲はメインスレッドで総ページ数と照らす
            let number = segments[4]
            guard !number.isEmpty, number.count <= 6, number.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let page = Int(number) else {
                send(.empty(404), to: client)
                return
            }
            sendSlide(page: page, client: client)
            return
        }

        switch (segments[3], method) {
        case ("pointer", "POST"):
            pointer(query: query, client: client)
        case ("pointer", _):
            send(methodNotAllowed("POST"), to: client)
        case ("state", "GET"):
            perform(.state, client: client)
        case ("next", "POST"):
            perform(.next, client: client)
        case ("prev", "POST"):
            perform(.previous, client: client)
        case ("state", _):
            send(methodNotAllowed("GET"), to: client)
        case ("next", _), ("prev", _):
            // リンクのプレビュー取得や先読みでページが動く事故を防ぐため、操作は POST だけ受け付ける
            send(methodNotAllowed("POST"), to: client)
        default:
            send(.empty(404), to: client)
        }
    }

    /// プレゼンへの操作はメインスレッドで行い、結果の state を返す
    private func perform(_ action: Action, client: Client) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var response = Response.empty(503)
            // 先に受け付けられる状態か確かめ、だめなら操作せずに 503 を返す
            if let target = self.target, target.remotePageState != nil {
                switch action {
                case .state: break
                case .next: target.goToNext()
                case .previous: target.goToPrevious()
                }
                // 返すのは操作した後の state
                if let state = target.remotePageState {
                    let json = "{\"page\":\(state.page),\"total\":\(state.total),\"doc\":\(state.doc)}"
                    response = Response(status: 200, contentType: "application/json", body: Data(json.utf8))
                }
            }
            self.queue.async { self.send(response, to: client) }
        }
    }

    /// 縮小画像を返す。描画を待っている間も接続は切らない（タイムアウトはヘッダ受信時点で解除済み）
    private func sendSlide(page: Int, client: Client) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let target = self.target, let state = target.remotePageState else {
                self.queue.async { self.send(.empty(503), to: client) }
                return
            }
            guard (1...state.total).contains(page) else {
                self.queue.async { self.send(.empty(404), to: client) }
                return
            }
            target.remoteSlideJPEG(page: page) { data in
                let response = data.map { Response(status: 200, contentType: "image/jpeg", body: $0) }
                    ?? .empty(503)
                self.queue.async { self.send(response, to: client) }
            }
        }
    }

    /// `pointer?x=<0〜1>&y=<0〜1>` で点を出す／動かす、`pointer?off=1` で消す。成功は 204
    private func pointer(query: String, client: Client) {
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            params[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
        }

        let position: CGPoint?
        if params["off"] == "1" {
            position = nil
        } else {
            // 数値でない・欠けている・NaN や無限大は 400。範囲外は 0〜1 に丸める
            guard let x = params["x"].flatMap(Double.init), let y = params["y"].flatMap(Double.init),
                  x.isFinite, y.isFinite else {
                send(.empty(400), to: client)
                return
            }
            position = CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var response = Response.empty(503)
            if let target = self.target, target.remotePageState != nil {
                target.remotePointer(at: position)
                response = .empty(204)
            }
            self.queue.async { self.send(response, to: client) }
        }
    }

    private func methodNotAllowed(_ allow: String) -> Response {
        var response = Response.empty(405)
        response.extraHeaders = [("Allow", allow)]
        return response
    }

    private func send(_ response: Response, to client: Client) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        if let contentType = response.contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        for (name, value) in response.extraHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)
        client.connection.send(content: payload, contentContext: .finalMessage, isComplete: true,
                               completion: .contentProcessed { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.close(client)
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    // MARK: - 合言葉

    /// 英小文字＋数字16文字（約82ビット）。SystemRandomNumberGenerator は Apple 環境では暗号学的乱数で、
    /// `random(in:using:)` は偏りが出ないよう棄却サンプリングしてくれる
    private static func makeToken() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
