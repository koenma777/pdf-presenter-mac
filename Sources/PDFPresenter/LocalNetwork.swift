import Foundation

/// スマホから届きそうな、このMacのアドレスを選ぶ（QRに載せるホスト）。
///
/// - 使える IPv4 があればそれを使う（en0 優先）。
/// - 無ければ IPv6 のグローバル（2000::/3）、それも無ければ ULA（fc00::/7）を使う。
///   iPhone のテザリング＋IPv6専用の回線では、Macの IPv4 は CLAT の仮アドレス（192.0.0.0/29）しか無く、
///   ほかの機器からは IPv6 でしか届かないため。
enum LocalNetwork {

    /// 稼働中インターフェースのアドレス1つ
    struct Candidate {
        /// インターフェース名（en0 など）
        var interface: String
        /// 数値表記のアドレス（IPv6 のスコープ "%en0" が付いていてもよい）
        var address: String
    }

    /// 選ばれたホスト。URL に入れるときは `urlHost`（IPv6 は角括弧で囲む）を使う
    static func preferredHost() -> String? {
        preferredHost(from: candidates())
    }

    /// URL のホスト部分の表記。IPv6 は `[...]` で囲む
    static func urlHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    // MARK: - 選び方（純粋な関数）

    /// 候補の一覧からホストを選ぶ。同じ条件の候補が複数あるときは一覧で先に出てくるもの
    static func preferredHost(from candidates: [Candidate]) -> String? {
        func interfaceRank(_ name: String) -> Int {
            if name == "en0" { return 0 }
            if name.hasPrefix("en") { return 1 }
            return 2
        }

        var best: (rank: (Int, Int), address: String)?
        for candidate in candidates {
            guard let kind = classify(candidate.address) else { continue }
            let rank = (kind.rawValue, interfaceRank(candidate.interface))
            if best == nil || rank < best!.rank {
                best = (rank, candidate.address)
            }
        }
        return best?.address
    }

    /// 使えるアドレスの種類（小さいほど優先）。使えないアドレスは nil
    enum Kind: Int {
        case ipv4 = 0
        case ipv6Global = 1
        case ipv6UniqueLocal = 2
    }

    static func classify(_ address: String) -> Kind? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }  // ネットワークバイト順のまま
            if b[0] == 0 { return nil }                            // 0.0.0.0/8
            if b[0] == 127 { return nil }                          // ループバック
            if b[0] == 169 && b[1] == 254 { return nil }           // リンクローカル
            if b[0] == 192 && b[1] == 0 && b[2] == 0 && b[3] < 8 { return nil }  // CLAT（192.0.0.0/29）
            if b[0] >= 224 { return nil }                          // マルチキャスト等
            return .ipv4
        }

        // スコープ（%en0）は取り除いてから解釈する
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, bare, &v6) == 1 else { return nil }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[0] & 0xe0 == 0x20 { return .ipv6Global }       // 2000::/3
        if b[0] & 0xfe == 0xfc { return .ipv6UniqueLocal }  // fc00::/7
        // ループバック・未指定・リンクローカル（fe80::/10）・マルチキャスト・その他は使わない
        return nil
    }

    // MARK: - 接続元の制限（同じネットワークの機器だけ受け付ける）

    /// このMacのインターフェースに付いているネットワーク（アドレスとプレフィックス長）
    struct Network {
        /// 4バイト（IPv4）か16バイト（IPv6）
        var address: [UInt8]
        var prefixLength: Int
    }

    /// 接続元を受け付けてよいか（純粋な関数）。次のどれかに当てはまれば許可：
    /// ループバック / リンクローカル / IPv4 のプライベート範囲とキャリアNAT / IPv6 の ULA /
    /// このMacのいずれかのネットワークと同じ範囲（オンリンク）
    static func isAllowedPeer(_ address: String, networks: [Network]) -> Bool {
        guard let bytes = parseAddress(address) else { return false }
        return isAllowedPeer(bytes: bytes, networks: networks)
    }

    /// bytes は4バイト（IPv4）か16バイト（IPv6）。IPv4射影のIPv6（::ffff:a.b.c.d）は中のIPv4で判定する
    static func isAllowedPeer(bytes raw: [UInt8], networks: [Network]) -> Bool {
        let bytes = unmapIPv4(raw)
        if bytes.count == 4 {
            let b = bytes
            if b[0] == 127 { return true }                                  // ループバック
            if b[0] == 169 && b[1] == 254 { return true }                   // リンクローカル
            if b[0] == 10 { return true }                                   // 10.0.0.0/8
            if b[0] == 172 && (16...31).contains(b[1]) { return true }      // 172.16.0.0/12
            if b[0] == 192 && b[1] == 168 { return true }                   // 192.168.0.0/16
            if b[0] == 100 && (64...127).contains(b[1]) { return true }     // キャリアNAT 100.64.0.0/10
        } else if bytes.count == 16 {
            if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }  // ::1
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }      // fe80::/10
            if bytes[0] & 0xfe == 0xfc { return true }                          // ULA fc00::/7
        } else {
            return false
        }
        // オンリンク：このMacのネットワークと、そのプレフィックス長の範囲で一致するか
        for network in networks {
            let netBytes = unmapIPv4(network.address)
            guard netBytes.count == bytes.count, network.prefixLength > 0 else { continue }
            if prefixMatches(bytes, netBytes, length: min(network.prefixLength, bytes.count * 8)) { return true }
        }
        return false
    }

    /// ::ffff:a.b.c.d なら中の4バイトを、それ以外はそのまま返す
    static func unmapIPv4(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return Array(bytes[12..<16])
        }
        return bytes
    }

    private static func prefixMatches(_ a: [UInt8], _ b: [UInt8], length: Int) -> Bool {
        let fullBytes = length / 8
        for i in 0..<fullBytes where a[i] != b[i] { return false }
        let rest = length % 8
        guard rest > 0 else { return true }
        let mask = UInt8(truncatingIfNeeded: 0xff << (8 - rest))
        return a[fullBytes] & mask == b[fullBytes] & mask
    }

    /// 数値表記のアドレスをバイト列に（スコープ "%en0" は取り除く）。解釈できなければ nil
    static func parseAddress(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: v4.s_addr) { Array($0) }
        }
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, bare, &v6) == 1 else { return nil }
        return withUnsafeBytes(of: v6) { Array($0) }
    }

    /// 稼働中のインターフェースのネットワーク一覧（ネットマスクから実際のプレフィックス長を取る）
    static func localNetworks() -> [Network] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [Network] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, let mask = entry.ifa_netmask else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }

            let address: [UInt8], maskBytes: [UInt8]
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                }
                maskBytes = maskAddressBytes(mask, offset: 4, count: 4)
            case AF_INET6:
                address = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
                maskBytes = maskAddressBytes(mask, offset: 8, count: 16)
            default:
                continue
            }
            // 先頭から続く1のビット数＝プレフィックス長
            var length = 0
            for byte in maskBytes {
                if byte == 0xff { length += 8; continue }
                length += byte.leadingZeroBitCount == 0 ? (~byte).leadingZeroBitCount : 0
                break
            }
            result.append(Network(address: address, prefixLength: length))
        }
        return result
    }

    /// ネットマスクの sockaddr からアドレス部分を読む。macOS ではネットマスクの sockaddr が
    /// 構造体より短い（sa_len が小さい）ことがあるので、sa_len を超えた分は 0 とみなす
    private static func maskAddressBytes(_ mask: UnsafeMutablePointer<sockaddr>, offset: Int, count: Int) -> [UInt8] {
        let length = Int(mask.pointee.sa_len)
        let raw = UnsafeRawPointer(mask)
        return (0..<count).map { i in
            offset + i < length ? raw.load(fromByteOffset: offset + i, as: UInt8.self) : 0
        }
    }

    // MARK: - 列挙

    /// 稼働中（UP かつ RUNNING）でループバックでないインターフェースの IPv4 / IPv6 アドレス（getifaddrs の順）
    static func candidates() -> [Candidate] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [Candidate] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(Candidate(interface: String(cString: entry.ifa_name), address: String(cString: host)))
        }
        return result
    }
}
