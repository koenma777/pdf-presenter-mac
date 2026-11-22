import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 発表者ビューの現在スライドに重ねる、スマホリモコン用のQRカード（白い角丸）。
/// 中身は「QR＋その下にURL」か「短いメッセージ」のどちらか。見出しや説明文は置かない。
final class RemotePanelView: NSView {

    enum Content {
        /// サーバー起動待ち（カードだけ出しておく）
        case pending
        case qr(url: String)
        case message(String)
    }

    /// クリックされたら閉じる（ページは進めない）
    var onClick: (() -> Void)?

    private(set) var content: Content = .pending

    /// QRの一辺の目安（pt）
    private let preferredQRSide: CGFloat = 300
    private let minimumQRSide: CGFloat = 120
    /// QRの一辺の上限（pt）。IPv6 のURLはモジュールが細かくなるので、目安より大きめに取ってよい範囲
    private let maximumQRSide: CGFloat = 320
    /// 1モジュールに確保したい大きさ（pt）。これを下回るときは目安を超えて大きくする
    private let preferredModulePoints: CGFloat = 8
    /// カード内側の余白。QRのクワイエットゾーン（周囲の白）も兼ねる
    private let inset: CGFloat = 24
    private let urlGap: CGFloat = 12
    private let urlHeight: CGFloat = 16
    private let cornerRadius: CGFloat = 18

    private let urlLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// 1モジュール1ピクセルのQR画像（拡大は描画時に補間なしで行う）
    private var qrImage: CGImage?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = NSColor.white.cgColor
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            return shadow
        }()

        urlLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        urlLabel.textColor = NSColor(white: 0.25, alpha: 1)
        urlLabel.alignment = .center
        urlLabel.lineBreakMode = .byTruncatingMiddle

        messageLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        messageLabel.textColor = NSColor(white: 0.2, alpha: 1)
        messageLabel.alignment = .center

        addSubview(urlLabel)
        addSubview(messageLabel)
        setContent(.pending)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setContent(_ content: Content) {
        self.content = content
        switch content {
        case .pending:
            qrImage = nil
            urlLabel.isHidden = true
            messageLabel.isHidden = true
        case .qr(let url):
            qrImage = Self.makeQRCode(for: url)
            urlLabel.stringValue = url
            urlLabel.isHidden = false
            messageLabel.isHidden = true
        case .message(let text):
            qrImage = nil
            messageLabel.stringValue = text
            urlLabel.isHidden = true
            messageLabel.isHidden = false
        }
        needsLayout = true
        needsDisplay = true
        superview?.needsLayout = true
    }

    // MARK: - 寸法

    /// 与えられた領域（現在スライドの枠）に収まるカードの大きさ
    func cardSize(fitting available: NSSize) -> NSSize {
        let qrSide = self.qrSide(fitting: available)
        return NSSize(width: qrSide + inset * 2, height: qrSide + inset * 2 + urlGap + urlHeight)
    }

    private func qrSide(fitting available: NSSize) -> CGFloat {
        let margin: CGFloat = 16
        let maxByWidth = available.width - margin * 2 - inset * 2
        let maxByHeight = available.height - margin * 2 - inset * 2 - urlGap - urlHeight
        // ふだんは目安の一辺。モジュールが多い（URLが長い）ときは、1モジュール8ptを目指して上限まで広げる
        var target = preferredQRSide
        if let modules = qrImage?.width, modules > 0 {
            target = min(maximumQRSide, max(preferredQRSide, CGFloat(modules) * preferredModulePoints))
        }
        var side = max(minimumQRSide, min(target, maxByWidth, maxByHeight)).rounded(.down)
        // モジュールが整数ポイントになるように丸める（拡大率が半端だとモジュールの太さが揃わない）
        if let modules = qrImage?.width, modules > 0 {
            side = max(CGFloat(modules), (side / CGFloat(modules)).rounded(.down) * CGFloat(modules))
        }
        return side
    }

    private var qrRect: NSRect {
        let side = bounds.width - inset * 2
        return NSRect(x: inset, y: bounds.height - inset - side, width: side, height: side)
    }

    override func layout() {
        super.layout()
        let qr = qrRect
        urlLabel.frame = NSRect(x: 8, y: qr.minY - urlGap - urlHeight, width: bounds.width - 16, height: urlHeight)
        // 手入力用なので省略させない。収まるまで文字を小さくする（下限9pt。それでも溢れる場合だけ中央省略）
        var fontSize: CGFloat = 12
        while fontSize > 9 {
            let width = (urlLabel.stringValue as NSString)
                .size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)]).width
            if width <= urlLabel.frame.width - 4 { break }
            fontSize -= 0.5
        }
        urlLabel.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let messageHeight = messageLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: qr.width, height: 200)).height ?? 40
        messageLabel.frame = NSRect(x: inset, y: (bounds.height - messageHeight) / 2,
                                    width: bounds.width - inset * 2, height: messageHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let qrImage, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // にじませない（最近傍で拡大）
        context.interpolationQuality = .none
        context.draw(qrImage, in: qrRect)
        context.restoreGState()
    }

    // MARK: - マウス

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    // MARK: - QR生成

    /// 1モジュール＝1ピクセルのQR（誤り訂正M）。白い余白はカード側の inset で確保する
    private static func makeQRCode(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent)
    }
}
