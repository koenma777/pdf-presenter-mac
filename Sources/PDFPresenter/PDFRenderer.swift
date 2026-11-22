import AppKit
import PDFKit

/// PDFページをビットマップに焼いて保持するレンダラ。
///
/// PDFKit のオブジェクトはスレッドセーフではないため、実際の描画は必ず `queue` の上だけで行う。
/// ページ送りを待たせないよう、現在ページの前後を先読みしてキャッシュに積んでおく。
final class PDFRenderer {

    /// 先読みするページ数。発表者ビューは先の4枚まで見せるので、1枚送った先の分まで前方を厚めに取る
    private let prefetchBehind = 2
    private let prefetchAhead = 5

    let url: URL
    private let document: PDFDocument
    private let queue = DispatchQueue(label: "app.pdfpresenter.render", qos: .userInitiated)
    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var pending = Set<String>()

    /// スマホリモコン用の縮小画像（JPEG）。全画面用の `cache` とは分ける（投影用の画像を追い出さないため）
    private let thumbnailCache = NSCache<NSNumber, NSData>()
    /// 縮小画像の長辺（px）とJPEG品質
    private let thumbnailLongSide: CGFloat = 640
    private let thumbnailQuality: Double = 0.7

    var pageCount: Int { document.pageCount }

    init?(url: URL) {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        self.url = url
        self.document = document
        cache.countLimit = 16
        cache.totalCostLimit = 384 * 1024 * 1024
        thumbnailCache.countLimit = 24
    }

    // MARK: - 取得

    /// キャッシュ済みなら即返す（メインスレッドから呼ぶ用・描画は行わない）
    func cachedImage(at index: Int, maxPixelSize: CGSize) -> NSImage? {
        guard isValid(index) else { return nil }
        return cache.object(forKey: cacheKey(index, maxPixelSize) as NSString)
    }

    /// キャッシュに無ければ裏で描画し、完了をメインスレッドで返す
    func requestImage(at index: Int, maxPixelSize: CGSize, completion: @escaping (NSImage?) -> Void) {
        guard isValid(index) else { completion(nil); return }
        let key = cacheKey(index, maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }
        queue.async { [weak self] in
            let image = self?.renderAndCache(index: index, maxPixelSize: maxPixelSize, key: key)
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 現在ページの前後を裏で描画しておく
    func prefetch(around index: Int, maxPixelSize: CGSize) {
        for offset in -prefetchBehind...prefetchAhead {
            let target = index + offset
            guard isValid(target) else { continue }
            let key = cacheKey(target, maxPixelSize)
            guard cache.object(forKey: key as NSString) == nil else { continue }

            lock.lock()
            let alreadyPending = pending.contains(key)
            if !alreadyPending { pending.insert(key) }
            lock.unlock()
            guard !alreadyPending else { continue }

            queue.async { [weak self] in
                guard let self else { return }
                _ = self.renderAndCache(index: target, maxPixelSize: maxPixelSize, key: key)
                self.lock.lock()
                self.pending.remove(key)
                self.lock.unlock()
            }
        }
    }

    /// スマホリモコン用の縮小画像（長辺640px程度のJPEG）。描画は他と同じ直列キューの上で行い、完了をメインスレッドで返す
    func requestThumbnailJPEG(at index: Int, completion: @escaping (Data?) -> Void) {
        guard isValid(index) else { completion(nil); return }
        if let cached = thumbnailCache.object(forKey: NSNumber(value: index)) {
            completion(cached as Data)
            return
        }
        queue.async { [weak self] in
            let data = self?.renderThumbnailJPEG(index: index)
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// ディスプレイ構成が変わって解像度基準が変わったときに捨てる
    func flushCache() {
        cache.removeAllObjects()
    }

    // MARK: - 内部

    private func isValid(_ index: Int) -> Bool {
        index >= 0 && index < document.pageCount
    }

    private func cacheKey(_ index: Int, _ maxPixelSize: CGSize) -> String {
        "\(index)@\(Int(maxPixelSize.width))x\(Int(maxPixelSize.height))"
    }

    private func renderAndCache(index: Int, maxPixelSize: CGSize, key: String) -> NSImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let image = render(index: index, maxPixelSize: maxPixelSize) else { return nil }
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    private func renderThumbnailJPEG(index: Int) -> Data? {
        let key = NSNumber(value: index)
        if let cached = thumbnailCache.object(forKey: key) { return cached as Data }
        let side = thumbnailLongSide
        guard let cgImage = renderCGImage(index: index, maxPixelSize: CGSize(width: side, height: side)),
              let data = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: thumbnailQuality]) else { return nil }
        thumbnailCache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    /// ページを maxPixelSize に収まる最大サイズでビットマップ化する
    private func render(index: Int, maxPixelSize: CGSize) -> NSImage? {
        guard let cgImage = renderCGImage(index: index, maxPixelSize: maxPixelSize) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// render の本体（queue の上でだけ呼ぶ）
    private func renderCGImage(index: Int, maxPixelSize: CGSize) -> CGImage? {
        guard let page = document.page(at: index) else { return nil }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }

        // bounds(for:) は回転前の寸法を返すが draw(with:to:) は回転を適用して描く。
        // 90/270度回転のページでは縦横を入れ替えたサイズでキャンバスを作らないと見切れる。
        let isQuarterTurned = abs(page.rotation) % 180 == 90
        let displaySize = isQuarterTurned
            ? CGSize(width: box.height, height: box.width)
            : box.size

        let scale = min(maxPixelSize.width / displaySize.width, maxPixelSize.height / displaySize.height)
        let pixelWidth = Int((displaySize.width * scale).rounded())
        let pixelHeight = Int((displaySize.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // PDFに背景が描かれていないページでも白紙に見えるよう下地を敷く
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()

        return context.makeImage()
    }
}
