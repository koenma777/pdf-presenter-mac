import AppKit

/// 1つのPDFのプレゼン一式（発表者ビュー＋投影ウィンドウ＋操作）を束ねるコントローラ
final class PresentationController: NSObject, NSWindowDelegate, RemoteControlTarget {

    /// 投影側でカーソルを隠すまでの無操作時間（秒）
    private let cursorIdleInterval: TimeInterval = 3

    private let renderer: PDFRenderer
    private var currentIndex = 0

    /// PDFを開くたびに増える識別子（スマホ側で古いPDFの縮小画像を捨てる合図）
    private static var nextDocumentID = 1
    private let documentID: Int

    private let presenterWindow: KeyableWindow
    private let presenterView = PresenterContentView()
    private var projectorWindow: KeyableWindow?
    private var projectorView: SlideView?

    /// 発表者ビューと投影の画面を入れ替えているか（Sキー）
    private var swapDisplays = false

    /// 描画基準にする最大ピクセルサイズ（接続中の全ディスプレイの最大値から決める）
    private var maxPixelSize = CGSize(width: 2560, height: 1600)

    /// 非同期描画の結果が古くなっていないか判定するための世代番号
    private var renderGeneration = 0

    private var keyMonitor: Any?
    private var cursorTimer: Timer?

    /// スマホリモコンのポインター（今のスライド上の割合の位置）。nil なら非表示
    private var pointerPosition: CGPoint?
    /// 最後の更新から一定時間で点を消す（「消す」が届かなかったとき・スマホがスリープしたときの保険）
    private var pointerTimer: Timer?
    private let pointerIdleInterval: TimeInterval = 1.5
    private var isClosed = false

    init?(url: URL) {
        guard let renderer = PDFRenderer(url: url) else { return nil }
        self.renderer = renderer
        documentID = Self.nextDocumentID
        Self.nextDocumentID += 1

        presenterWindow = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        presenterWindow.title = "\(url.lastPathComponent) — 発表者ビュー"
        presenterWindow.appearance = NSAppearance(named: .darkAqua)
        presenterWindow.titlebarAppearsTransparent = true
        presenterWindow.backgroundColor = NSColor(white: 0.09, alpha: 1)
        presenterWindow.contentView = presenterView
        presenterWindow.delegate = self
        presenterWindow.isReleasedWhenClosed = false

        presenterView.currentSlide.onClick = { [weak self] in self?.goToNext() }
        presenterView.upcomingSlides.forEach { $0.onClick = { [weak self] in self?.goToNext() } }
        presenterView.remotePanel.onClick = { [weak self] in self?.hideRemotePanel() }
    }

    // MARK: - 開始 / 終了

    func start() {
        maxPixelSize = Self.computeMaxPixelSize()
        updateWindowPlacement()
        presenterWindow.makeKeyAndOrderFront(nil)
        showCurrentPage()
        installKeyMonitor()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true

        NotificationCenter.default.removeObserver(self)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        cursorTimer?.invalidate()
        cursorTimer = nil
        presenterView.stopClock()
        pointerTimer?.invalidate()
        pointerTimer = nil

        destroyProjectorWindow()
        presenterWindow.delegate = nil
        presenterWindow.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === presenterWindow else { return }
        close()
        NSApp.terminate(nil)
    }

    // MARK: - ページ送り

    func goToNext() { go(to: currentIndex + 1) }
    func goToPrevious() { go(to: currentIndex - 1) }

    private func go(to index: Int) {
        let clamped = max(0, min(renderer.pageCount - 1, index))
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        showCurrentPage()
    }

    private func showCurrentPage() {
        renderGeneration += 1
        let generation = renderGeneration

        presenterView.setPage(currentIndex, of: renderer.pageCount)
        apply(index: currentIndex, generation: generation, to: currentSinks(), placeholder: "…")

        for (offset, slide) in presenterView.upcomingSlides.enumerated() {
            let index = currentIndex + 1 + offset
            if index < renderer.pageCount {
                apply(index: index, generation: generation, to: [slide], placeholder: "…")
            } else {
                // 最後のページを越えた最初の枠にだけ END を出し、残りは空けておく
                slide.image = nil
                slide.placeholder = index == renderer.pageCount ? "END" : nil
            }
        }

        renderer.prefetch(around: currentIndex, maxPixelSize: maxPixelSize)
    }

    /// 現在スライドを映す先（発表者ビューの大きい方＋投影ウィンドウ）
    private func currentSinks() -> [SlideView] {
        var sinks = [presenterView.currentSlide]
        if let projectorView { sinks.append(projectorView) }
        return sinks
    }

    private func apply(index: Int, generation: Int, to sinks: [SlideView], placeholder: String) {
        if let cached = renderer.cachedImage(at: index, maxPixelSize: maxPixelSize) {
            sinks.forEach { $0.placeholder = nil; $0.image = cached }
            return
        }
        // キャッシュに無いときだけ一瞬プレースホルダを出し、焼き上がり次第差し替える
        sinks.forEach { $0.image = nil; $0.placeholder = placeholder }
        renderer.requestImage(at: index, maxPixelSize: maxPixelSize) { [weak self] image in
            guard let self, generation == self.renderGeneration, let image else { return }
            sinks.forEach { $0.placeholder = nil; $0.image = image }
        }
    }

    // MARK: - ディスプレイ

    @objc private func screenParametersChanged() {
        let newSize = Self.computeMaxPixelSize()
        if newSize != maxPixelSize {
            maxPixelSize = newSize
            renderer.flushCache()
        }
        updateWindowPlacement()
        showCurrentPage()
    }

    private func updateWindowPlacement() {
        guard let layout = ScreenLayout.resolve(swapped: swapDisplays) else { return }
        presenterWindow.setFrame(layout.presenter.visibleFrame, display: true)

        guard let projectorScreen = layout.projector else {
            destroyProjectorWindow()
            presenterView.setStatus("外部モニタ未接続 — 接続すると自動で投影を開始します　（R＝スマホリモコン）")
            return
        }

        if let projectorWindow {
            projectorWindow.setFrame(projectorScreen.frame, display: true)
        } else {
            createProjectorWindow(on: projectorScreen)
        }
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        presenterView.setStatus("投影中: \(projectorScreen.localizedName)　（S＝画面入替・R＝スマホリモコン）")
    }

    private func createProjectorWindow(on screen: NSScreen) {
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        // 他アプリに切り替わってもプロジェクタ側が引っ込まないようにする
        window.level = .screenSaver
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenNone, .canJoinAllSpaces, .stationary]

        let view = SlideView()
        view.pointerPosition = pointerPosition
        view.tracksMouseMovement = true
        view.onClick = { [weak self] in self?.goToNext() }
        view.onMouseMoved = { [weak self] in self?.noteCursorActivity() }
        window.contentView = view

        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        projectorWindow = window
        projectorView = view
        noteCursorActivity()
    }

    private func destroyProjectorWindow() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        NSCursor.unhide()
        projectorWindow?.orderOut(nil)
        projectorWindow = nil
        projectorView = nil
        NSApp.presentationOptions = []
    }

    /// 投影側のカーソルを無操作3秒で自動的に隠す
    private func noteCursorActivity() {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: cursorIdleInterval, repeats: false) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// 接続中の全ディスプレイの実ピクセル数から、描画の基準解像度を決める
    private static func computeMaxPixelSize() -> CGSize {
        var width: CGFloat = 1280
        var height: CGFloat = 800
        for screen in NSScreen.screens {
            let scale = screen.backingScaleFactor
            width = max(width, screen.frame.width * scale)
            height = max(height, screen.frame.height * scale)
        }
        // メモリ暴走を防ぐため4K相当で頭打ちにする
        let cap: CGFloat = 3840
        if width > cap {
            let ratio = cap / width
            width *= ratio
            height *= ratio
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    // MARK: - キー操作

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event: event) else { return event }
            return nil
        }
    }

    private func handle(event: NSEvent) -> Bool {
        // ⌘系のショートカット（⌘Q / ⌘O 等）はメニューに渡す
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }

        switch event.keyCode {
        case 124, 125, 121, 49:   // → ↓ PageDown Space
            goToNext()
            return true
        case 123, 126, 116:       // ← ↑ PageUp
            goToPrevious()
            return true
        case 115:                 // Home
            go(to: 0)
            return true
        case 119:                 // End
            go(to: renderer.pageCount - 1)
            return true
        case 53:                  // Esc
            // QRパネル表示中はパネルを閉じるだけ（QRを消すつもりで発表を終わらせる事故を防ぐ）
            if isRemotePanelVisible {
                hideRemotePanel()
                return true
            }
            close()
            NSApp.terminate(nil)
            return true
        default:
            break
        }

        if event.charactersIgnoringModifiers?.lowercased() == "s" {
            swapDisplays.toggle()
            updateWindowPlacement()
            showCurrentPage()
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "r" {
            toggleRemotePanel()
            return true
        }
        return false
    }

    // MARK: - スマホリモコン

    private var isRemotePanelVisible: Bool { !presenterView.remotePanel.isHidden }

    /// QRパネルの表示／非表示を切り替える（初回はここでサーバーが起動する）
    func toggleRemotePanel() {
        if isRemotePanelVisible {
            hideRemotePanel()
        } else {
            showRemotePanel()
        }
    }

    func showRemotePanel() {
        guard !isClosed else { return }
        let panel = presenterView.remotePanel
        panel.setContent(.pending)
        panel.isHidden = false

        let server = RemoteServer.shared
        server.start { [weak self] port in
            guard let self, !self.isClosed, self.isRemotePanelVisible else { return }
            guard let port else {
                panel.setContent(.message("リモコンを開始できませんでした"))
                return
            }
            // Wi-Fiを切り替えた後でも R を押し直せば新しいURLになるよう、表示のたびに取り直す
            // IPv4 も IPv6 も使えるものが無いときだけ「未接続」と出す
            guard let host = LocalNetwork.preferredHost() else {
                panel.setContent(.message("ネットワークに接続されていません"))
                return
            }
            panel.setContent(.qr(url: RemoteServer.url(host: host, port: port, token: server.token)))
        }
    }

    func hideRemotePanel() {
        presenterView.remotePanel.isHidden = true
    }

    var remotePageState: RemotePageState? {
        guard !isClosed else { return nil }
        return RemotePageState(page: currentIndex + 1, total: renderer.pageCount, doc: documentID)
    }

    func remoteSlideJPEG(page: Int, completion: @escaping (Data?) -> Void) {
        guard !isClosed else { completion(nil); return }
        renderer.requestThumbnailJPEG(at: page - 1, completion: completion)
    }

    func remotePointer(at position: CGPoint?) {
        guard !isClosed else { return }
        pointerPosition = position
        // 点は投影と発表者ビューの「今のスライド」にだけ出す（右列には出さない）
        presenterView.currentSlide.pointerPosition = position
        projectorView?.pointerPosition = position

        pointerTimer?.invalidate()
        pointerTimer = nil
        guard position != nil else { return }
        let timer = Timer(timeInterval: pointerIdleInterval, repeats: false) { [weak self] _ in
            self?.remotePointer(at: nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    func remoteControlDidConnect() {
        guard !isClosed else { return }
        hideRemotePanel()
    }
}
