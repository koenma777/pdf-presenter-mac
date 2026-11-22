import AppKit

/// スライド1枚をアスペクト比維持（レターボックス）で描画するビュー
final class SlideView: NSView {

    enum Alignment {
        /// 領域の中央に置く
        case center
        /// 領域の上端に寄せる（NEXT欄で余白を下にまとめる）
        case top
    }

    var image: NSImage? {
        didSet {
            needsDisplay = true
            onImageChanged?()
            updatePointerDot()
        }
    }

    /// スマホリモコンのポインター位置（描かれているスライド画像に対する割合。左上 0,0・右下 1,1）。nil で非表示。
    /// 点はスライドの描画に混ぜず、上に重ねたサブビューを動かすだけにする（更新のたびに画像を描き直さない）
    var pointerPosition: CGPoint? {
        didSet { updatePointerDot() }
    }
    private var pointerDot: PointerDotView?

    /// 画像が差し替わったときに親へ知らせる（キャプション位置の追従用）
    var onImageChanged: (() -> Void)?

    /// 画像が無いときに中央へ出す文字（"END" や読み込み中表示）
    var placeholder: String? {
        didSet { needsDisplay = true }
    }

    /// 画像の外側を塗る色。投影side は黒、発表者ビューは地色に馴染ませる。
    var letterboxColor: NSColor = .black {
        didSet { needsDisplay = true }
    }

    var alignment: Alignment = .center {
        didSet {
            needsDisplay = true
            updatePointerDot()
        }
    }

    /// スライドの輪郭に細い枠を描く（地色に馴染ませたときの境界用）
    var drawsBorder = false {
        didSet { needsDisplay = true }
    }

    var onClick: (() -> Void)?
    var onMouseMoved: (() -> Void)?

    /// マウス移動を拾うか（投影ウィンドウのカーソル自動消去に使う）
    var tracksMouseMovement = false {
        didSet { refreshTrackingArea() }
    }

    private var trackingArea: NSTrackingArea?

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        letterboxColor.setFill()
        bounds.fill()

        guard let image else {
            drawPlaceholder()
            return
        }

        let rect = Self.fitRect(for: image.size, in: bounds, alignment: alignment)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect)

        if drawsBorder {
            NSColor(white: 1, alpha: 0.16).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawPlaceholder() {
        guard let placeholder, !placeholder.isEmpty else { return }
        let fontSize = max(13, min(40, bounds.height * 0.11))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor(white: 0.38, alpha: 1)
        ]
        let text = NSAttributedString(string: placeholder, attributes: attributes)
        let size = text.size()
        let y: CGFloat
        switch alignment {
        case .center: y = bounds.midY - size.height / 2
        case .top:    y = bounds.maxY - size.height - bounds.height * 0.18
        }
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: y))
    }

    /// 与えられた矩形の中に、アスペクト比を保ったまま最大サイズで収める
    static func fitRect(for imageSize: NSSize, in bounds: NSRect, alignment: Alignment = .center) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = (imageSize.width * scale).rounded(.down)
        let height = (imageSize.height * scale).rounded(.down)
        let y: CGFloat
        switch alignment {
        case .center: y = bounds.midY - height / 2
        case .top:    y = bounds.maxY - height
        }
        return NSRect(x: bounds.midX - width / 2, y: y, width: width, height: height).integral
    }

    // MARK: - ポインター

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePointerDot()
    }

    private func updatePointerDot() {
        guard let position = pointerPosition, let image else {
            pointerDot?.isHidden = true
            return
        }
        let dot: PointerDotView
        if let existing = pointerDot {
            dot = existing
        } else {
            dot = PointerDotView()
            addSubview(dot)
            pointerDot = dot
        }
        let rect = Self.fitRect(for: image.size, in: bounds, alignment: alignment)
        // 直径はスライドの表示幅に比例（下限12pt・上限40pt）
        let diameter = min(40, max(12, rect.width * 0.016)).rounded()
        // スマホ側は上が0。こちらの座標は下が0なので反転する
        let center = NSPoint(x: rect.minX + position.x * rect.width, y: rect.maxY - position.y * rect.height)
        dot.place(center: center, diameter: diameter)
        dot.isHidden = false
    }

    // MARK: - マウス

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea()
    }

    private func refreshTrackingArea() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        guard tracksMouseMovement else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }
}

/// レーザーポインター風の赤い点（明るい赤の円＋細い白の縁＋うっすら赤い光のにじみ）。
/// マウス操作は横取りしない（点の上をクリックしても下のスライドに届く）
final class PointerDotView: NSView {

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        guard let layer else { return }
        layer.backgroundColor = NSColor(red: 1, green: 0.13, blue: 0.1, alpha: 1).cgColor
        layer.borderColor = NSColor(white: 1, alpha: 0.95).cgColor
        layer.shadowColor = NSColor(red: 1, green: 0.1, blue: 0.05, alpha: 1).cgColor
        layer.shadowOpacity = 0.85
        layer.shadowOffset = .zero
        layer.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func place(center: NSPoint, diameter: CGFloat) {
        // 暗黙のアニメーションで遅れて付いてこないよう、動きは即時に反映する
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = NSRect(x: (center.x - diameter / 2).rounded(), y: (center.y - diameter / 2).rounded(),
                       width: diameter, height: diameter)
        if let layer {
            layer.cornerRadius = diameter / 2
            layer.borderWidth = max(1, diameter * 0.08)
            layer.shadowRadius = diameter * 0.45
        }
        CATransaction.commit()
    }
}
