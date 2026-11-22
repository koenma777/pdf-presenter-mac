import AppKit

/// 発表者ビューの中身。現在スライド（大）＋この先のスライド（右列に縦並び）＋ページ番号を並べる。
final class PresenterContentView: NSView {

    /// 発表者ビューの地色。スライドのレターボックス部分もこの色で塗って馴染ませる。
    static let panelColor = NSColor(white: 0.09, alpha: 1)

    /// 右列に並べる「この先のスライド」の枚数
    static let upcomingCount = 4

    let currentSlide = SlideView()
    /// 右列のスライド。先頭が次の1枚、以降 +2, +3 … と続く
    let upcomingSlides = (0..<upcomingCount).map { _ in SlideView() }

    /// スマホリモコンのQRカード。現在スライドの上に重ねる（発表者ビューにだけ出す）
    let remotePanel = RemotePanelView()

    private let nextCaption = NSTextField(labelWithString: "NEXT")
    private let pageLabel = NSTextField(labelWithString: "–")
    private let statusLabel = NSTextField(labelWithString: "")
    /// 下部バー中央の現在時刻（発表者ビューにだけ出す）
    private let clockLabel = NSTextField(labelWithString: "")
    private var clockTimer: Timer?
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    private let padding: CGFloat = 26
    private let gap: CGFloat = 26
    /// 下部バーの高さ（時計の文字が収まる分だけ取る）
    private let barHeight: CGFloat = 52
    private let clockHeight: CGFloat = 48
    private let captionHeight: CGFloat = 18
    /// 右列のスライド同士の間隔
    private let upcomingGap: CGFloat = 10
    /// 右列が横幅に占める比率の上下限（実際の幅はスライドの縦横比から決める）
    private let upcomingWidthRange: ClosedRange<CGFloat> = 0.2...0.4

    override var isOpaque: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))

        for slide in [currentSlide] + upcomingSlides {
            slide.letterboxColor = Self.panelColor
            slide.drawsBorder = true
        }

        nextCaption.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        nextCaption.textColor = NSColor(white: 0.5, alpha: 1)

        pageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
        pageLabel.textColor = NSColor(white: 0.95, alpha: 1)

        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = NSColor(white: 0.48, alpha: 1)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail

        clockLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        clockLabel.textColor = NSColor(white: 0.95, alpha: 1)
        clockLabel.alignment = .center
        updateClock()
        startClock()

        for view in [currentSlide] + upcomingSlides + [nextCaption, pageLabel, statusLabel, clockLabel] {
            addSubview(view)
        }
        // スライドより手前に置く。非表示の間はクリックを素通しする
        remotePanel.isHidden = true
        addSubview(remotePanel)

        // 右列の幅はスライドの縦横比で、NEXTの見出しは実際に描かれるスライドの真上で決まるので、
        // 画像が変わったら組み直す
        currentSlide.onImageChanged = { [weak self] in self?.needsLayout = true }
        upcomingSlides[0].onImageChanged = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Self.panelColor.setFill()
        bounds.fill()
    }

    func setPage(_ index: Int, of total: Int) {
        pageLabel.stringValue = "\(index + 1) / \(total)"
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    // MARK: - 時計

    /// 1秒ごとに確かめ、表示が変わるときだけ書き換える（スリープ復帰や時刻変更にも追従する）。
    /// `.common` モードに載せて、ウィンドウのリサイズ中なども止まらないようにする
    private func startClock() {
        guard clockTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateClock() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func updateClock() {
        let text = clockFormatter.string(from: Date())
        if clockLabel.stringValue != text { clockLabel.stringValue = text }
    }

    override func layout() {
        super.layout()

        let contentWidth = bounds.width - padding * 2
        let contentHeight = bounds.height - padding * 2 - barHeight
        guard contentWidth > 0, contentHeight > 0 else { return }

        let contentBottom = padding + barHeight
        let contentTop = contentBottom + contentHeight

        // 見出しの帯を必ず確保しておく（縦長ページでスライドが上端まで伸びても被らないように）
        let captionBand = captionHeight + 7
        let count = CGFloat(upcomingSlides.count)
        let slotHeight = max(0, ((contentHeight - captionBand - upcomingGap * (count - 1)) / count).rounded(.down))

        // 右列は縦に積んだスライドがちょうど収まる幅にし、残りを現在スライドに回す
        let aspect = currentSlide.image.map { $0.size.width / max(1, $0.size.height) } ?? 16 / 9
        let upcomingWidth = min(
            max((slotHeight * aspect).rounded(.up), contentWidth * upcomingWidthRange.lowerBound),
            contentWidth * upcomingWidthRange.upperBound
        ).rounded(.down)
        let currentWidth = contentWidth - gap - upcomingWidth
        let upcomingX = padding + currentWidth + gap

        currentSlide.frame = NSRect(
            x: padding, y: contentBottom,
            width: currentWidth, height: contentHeight
        )
        for (offset, slide) in upcomingSlides.enumerated() {
            let top = contentTop - captionBand - CGFloat(offset) * (slotHeight + upcomingGap)
            slide.frame = NSRect(x: upcomingX, y: top - slotHeight, width: upcomingWidth, height: slotHeight)
        }

        // NEXT見出しは次スライドの実描画位置の真上へ。画像未取得なら列の上端に置く。
        let nextSlide = upcomingSlides[0]
        let captionTop = bounds.height - padding - captionHeight
        var captionY = captionTop
        if let imageSize = nextSlide.image?.size {
            let fitted = SlideView.fitRect(
                for: imageSize,
                in: NSRect(origin: .zero, size: nextSlide.frame.size)
            )
            captionY = min(captionTop, nextSlide.frame.minY + fitted.maxY + 7)
        }
        nextCaption.frame = NSRect(x: upcomingX, y: captionY, width: upcomingWidth, height: captionHeight)

        // QRカードは現在スライドの枠の中央に
        let slideFrame = currentSlide.frame
        let cardSize = remotePanel.cardSize(fitting: slideFrame.size)
        remotePanel.frame = NSRect(
            x: (slideFrame.midX - cardSize.width / 2).rounded(),
            y: (slideFrame.midY - cardSize.height / 2).rounded(),
            width: cardSize.width, height: cardSize.height
        )

        // 下部バー：左にページ番号、中央に時計、右にディスプレイ状態。
        // 時計の幅は「88:88」で固定して確保し、狭いときは右の状態表示のほうを省略させる
        let clockFont = clockLabel.font ?? NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        let clockWidth = ("88:88" as NSString).size(withAttributes: [.font: clockFont]).width.rounded(.up) + 8
        let clockX = (bounds.midX - clockWidth / 2).rounded()
        clockLabel.frame = NSRect(x: clockX, y: padding, width: clockWidth, height: clockHeight)

        let rowMid = padding + clockHeight / 2
        let labelWidth = min((contentWidth * 0.3).rounded(.down), max(0, clockX - gap - padding))
        pageLabel.frame = NSRect(x: padding, y: (rowMid - 13).rounded(), width: labelWidth, height: 26)
        let statusX = clockX + clockWidth + gap
        statusLabel.frame = NSRect(
            x: statusX, y: (rowMid - 9).rounded(),
            width: max(0, bounds.width - padding - statusX), height: 18
        )
    }
}
