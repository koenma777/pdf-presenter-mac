import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: PresentationController?

    /// `--remote` 付きで起動されたら、最初に開いたPDFでスマホリモコンのQRを出す（開発・検証用）
    private var showsRemoteOnLaunch = CommandLine.arguments.dropFirst().contains("--remote")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        if showsRemoteOnLaunch {
            // 起動時点で待ち受けを始める（URLは標準出力に出る）
            RemoteServer.shared.start { _ in }
        }

        // 開発時のテスト用：引数でPDFパスを渡せる
        if controller == nil,
           let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            openDocument(at: URL(fileURLWithPath: path))
        }

        // Finderからの「開く」イベントが先に届く場合があるので、1周待ってから判定する
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller == nil else { return }
            self.showOpenPanel()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) ?? urls.first else { return }
        openDocument(at: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - 開く

    private func openDocument(at url: URL) {
        guard let next = PresentationController(url: url) else {
            presentError("PDFとして開けませんでした。\n\n\(url.lastPathComponent)")
            if controller == nil { showOpenPanel() }
            return
        }
        controller?.close()
        controller = next
        // サーバーはアプリ単位で1つ。操作先だけを新しいプレゼンに差し替える（URLと合言葉はそのまま）
        RemoteServer.shared.target = next
        next.start()
        if showsRemoteOnLaunch {
            showsRemoteOnLaunch = false
            next.showRemotePanel()
        }
        NSApp.activate()
    }

    @objc private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "プレゼンするPDFを選んでください"
        panel.prompt = "開く"

        guard panel.runModal() == .OK, let url = panel.url else {
            // 何も開いていない状態でキャンセルされたら終了する
            if controller == nil { NSApp.terminate(nil) }
            return
        }
        openDocument(at: url)
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "開けませんでした"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - メニュー

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "PDF Presenter について",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "PDF Presenter を終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "ファイル")
        let openItem = NSMenuItem(title: "PDFを開く…", action: #selector(showOpenPanel), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
