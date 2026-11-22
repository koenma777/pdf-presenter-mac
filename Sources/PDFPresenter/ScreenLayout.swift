import AppKit

extension NSScreen {
    /// CoreGraphics のディスプレイIDを取り出す
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// 内蔵ディスプレイかどうか
    var isBuiltin: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }
}

/// 「発表者ビューをどの画面に出し、どの画面へ投影するか」の割り当て
struct ScreenLayout {
    let presenter: NSScreen
    /// 外部モニタが無い場合は nil（＝投影ウィンドウを作らない）
    let projector: NSScreen?

    /// 内蔵ディスプレイを発表者用、それ以外を投影用にする。
    /// 内蔵が無い機種（Mac mini 等）ではメインディスプレイを発表者用にする。
    static func resolve(swapped: Bool) -> ScreenLayout? {
        let screens = NSScreen.screens
        guard let first = screens.first else { return nil }
        guard screens.count >= 2 else {
            return ScreenLayout(presenter: NSScreen.main ?? first, projector: nil)
        }

        var presenter: NSScreen
        var projector: NSScreen
        if let builtin = screens.first(where: { $0.isBuiltin }),
           let external = screens.first(where: { $0 !== builtin }) {
            presenter = builtin
            projector = external
        } else {
            let main = NSScreen.main ?? first
            presenter = main
            projector = screens.first(where: { $0 !== main }) ?? screens[1]
        }

        if swapped { swap(&presenter, &projector) }
        return ScreenLayout(presenter: presenter, projector: projector)
    }
}
