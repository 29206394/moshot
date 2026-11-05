import Cocoa
import Vision

/// 滚动截图：自动滚动 + 逐屏抓取 + 拼接成长图
///
/// 坐标系约定（全文件统一）：
///   region 用屏幕全局点坐标，左上原点（与 screencapture -R 一致）
///   行号一律指「视觉行序」，0 = 最上面一行
///   CGImage.cropping 的 y 就是视觉行号（实测验证：cropping y=0 得到的是最上面一片）
enum ScrollError: Error {
    case captureFailed
    case noScroll
    case cancelled
}

/// 拼接器：与采集解耦，可单独喂帧做自检
final class Stitcher {
    private(set) var image: CGImage
    private var prev: CGImage
    private var lastNewRows: Int?
    let minOverlap: Int
    let maxMismatch: Double

    init(first: CGImage, minOverlap: Int = 8, maxMismatch: Double = 0.2) {
        image = first
        prev = first
        self.minOverlap = minOverlap
        self.maxMismatch = maxMismatch
    }

    /// 追加一屏。返回新增行数；nil = 到底或配准失败
    @discardableResult
    func add(_ next: CGImage) -> Int? {
        guard next.width == prev.width, next.height == prev.height else { return nil }
        if ScrollCapture.sameContent(prev, next) { return nil }
        guard let overlap = overlapRows(prev: prev, next: next) else { return nil }
        let newRows = next.height - overlap
        guard newRows > 0, let merged = ScrollCapture.append(image, next, skipRows: overlap) else { return nil }
        image = merged
        prev = next
        lastNewRows = newRows
        return newRows
    }

    /// 两屏的重叠行数。先用行亮度投影 1D 搜索，再 2D 像素差复核。
    private func overlapRows(prev: CGImage, next: CGImage) -> Int? {
        guard let pa = ScrollCapture.rowProfile(prev),
              let pb = ScrollCapture.rowProfile(next) else { return nil }
        let h = pa.count
        let lo = max(minOverlap, Int(Double(h) * 0.12))
        let hi = h - 3
        guard lo < hi else { return nil }

        let window = min(200, hi - lo)
        var scored: [(ov: Int, score: Double)] = []
        scored.reserveCapacity(hi - lo + 1)
        for ov in lo...hi {
            let cmp = min(ov, window)
            var sum = 0.0
            let base = h - ov
            for i in 0..<cmp { sum += abs(pa[base + i] - pb[i]) }
            scored.append((ov, sum / Double(cmp)))
        }
        scored.sort { $0.score < $1.score }

        var best: (ov: Int, score: Double)?
        var picked = 0
        for cand in scored {
            if picked >= 6 { break }
            if let b = best, abs(cand.ov - b.ov) < 4 { continue }
            picked += 1
            let s = ScrollCapture.mismatch(prev: prev, next: next, overlap: cand.ov)
            if best == nil || s < best!.score { best = (cand.ov, s) }
        }
        if let last = lastNewRows, last > 4 {
            for d in [0, -6, 6, -14, 14, -24, 24] {
                let ov = h - last + d
                guard ov > lo, ov < hi else { continue }
                let s = ScrollCapture.mismatch(prev: prev, next: next, overlap: ov)
                if best == nil || s < best!.score { best = (ov, s) }
            }
        }
        guard let b = best, b.score <= maxMismatch else { return nil }
        return b.ov
    }
}

final class ScrollCapture {

    struct Config {
        var region: CGRect             // 屏幕全局点坐标，左上原点
        var scrollLines: Int32 = -10   // 每轮滚动行数
        var settleMs: Int = 300        // 滚动后等待重绘/懒加载
        var maxHeightPx: Int = 24000
        var maxFrames: Int = 60
        var minOverlapPx: Int = 8
        var maxMismatch: Double = 0.2  // 重叠区像素差异率上限，超过视为配准不可信
    }

    private let cfg: Config
    private var cancelFlag = false
    private var finishFlag = false
    /// 外部驱动滚动（自检用）；为 nil 时用 CGEvent 合成滚轮
    var scrollAction: (() -> Void)?
    var onProgress: ((_ frames: Int, _ heightPx: Int) -> Void)?

    init(config: Config) { self.cfg = config }
    func cancel() { cancelFlag = true }
    /// 用户点「完成」：保留已拼内容立即收工（区别于取消）
    func finish() { finishFlag = true }

    /// 手动滚动采集：不合成滚动事件，用户自己滚，这里定时抓帧。
    ///
    /// 自动滚动靠 CGEvent 合成滚轮，需要「辅助功能」权限；没这道权限时合成事件
    /// 会被静默丢弃（不报错，只是滚不动）。手动模式零权限，且对任何 app 都有效。
    /// 判定收工：连续 idleLimit 次抓帧都没有新内容。
    func runManual(idleLimit: Int = 10, intervalMs: Int = 340) throws -> CGImage {
        guard let first = grab(cfg.region) else { throw ScrollError.captureFailed }
        let stitcher = Stitcher(first: first, minOverlap: cfg.minOverlapPx, maxMismatch: cfg.maxMismatch)
        var frames = 1
        var idle = 0
        var grabFails = 0

        while frames < cfg.maxFrames && !cancelFlag && !finishFlag {
            usleep(useconds_t(intervalMs * 1000))
            guard let next = grab(cfg.region) else {
                grabFails += 1
                if grabFails > 30 { throw ScrollError.captureFailed }  // 约 10 秒抓不到，别死等
                continue
            }
            grabFails = 0
            if stitcher.add(next) != nil {
                frames += 1
                idle = 0
                onProgress?(frames, stitcher.image.height)
            } else {
                idle += 1
                // 关键：还没截到任何新增内容时绝不因"没变化"退出——用户只是还没开始滚，
                // 早退会让取景框一闪就消失，看起来像功能坏了。滚过之后再按 idle 收工。
                if frames > 1 && idle >= idleLimit { break }
            }
        }
        if cancelFlag { throw ScrollError.cancelled }
        if frames == 1 { throw ScrollError.noScroll }
        return stitcher.image
    }

    /// 自动滚动采集（需要辅助功能权限）。成功返回拼接后的长图。
    func run() throws -> CGImage {
        guard let first = grab(cfg.region) else { throw ScrollError.captureFailed }
        let stitcher = Stitcher(first: first, minOverlap: cfg.minOverlapPx, maxMismatch: cfg.maxMismatch)
        let scale = screenScale(for: cfg.region)
        let center = CGPoint(x: cfg.region.midX, y: cfg.region.midY)
        var frames = 1

        while frames < cfg.maxFrames && !cancelFlag {
            if stitcher.image.height >= Int(Double(cfg.maxHeightPx) * scale) { break }
            if let act = scrollAction { act() } else { postScroll(lines: cfg.scrollLines, at: center) }
            usleep(useconds_t(cfg.settleMs * 1000))
            guard let next = grab(cfg.region) else { throw ScrollError.captureFailed }
            guard stitcher.add(next) != nil else { break }
            frames += 1
            onProgress?(frames, stitcher.image.height)
        }
        if cancelFlag { throw ScrollError.cancelled }
        if frames == 1 { throw ScrollError.noScroll }
        return stitcher.image
    }

    // MARK: - 抓屏

    private func grab(_ rect: CGRect) -> CGImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("moshot-scroll-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R",
                       "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))",
                       tmp.path]
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard p.terminationStatus == 0,
              let d = try? Data(contentsOf: tmp),
              let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func screenScale(for rect: CGRect) -> Double {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let flipped = CGPoint(x: rect.midX, y: primaryH - rect.midY)
        for s in NSScreen.screens where s.frame.contains(flipped) {
            return Double(s.backingScaleFactor)
        }
        return Double(NSScreen.main?.backingScaleFactor ?? 2)
    }

    // MARK: - 滚动事件

    private func postScroll(lines: Int32, at point: CGPoint) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                              wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
        e.location = point
        e.post(tap: .cghidEventTap)
    }

    // MARK: - 图像工具

    /// 画面主体（去掉右侧滚动条）几乎没变 = 已滚到底
    static func sameContent(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let bodyW = Int(Double(a.width) * 0.94)
        guard let ca = cropCols(a, width: bodyW), let cb = cropCols(b, width: bodyW) else { return false }
        return mismatch(prev: ca, next: cb, overlap: ca.height) < 0.004
    }

    static func cropCols(_ img: CGImage, width: Int) -> CGImage? {
        guard width > 0, width <= img.width else { return nil }
        return img.cropping(to: CGRect(x: 0, y: 0, width: width, height: img.height))
    }

    /// 取视觉行区间 [from, to)
    static func cropRows(_ img: CGImage, from: Int, to: Int) -> CGImage? {
        let h = to - from
        guard h > 0, from >= 0, to <= img.height else { return nil }
        return img.cropping(to: CGRect(x: 0, y: from, width: img.width, height: h))
    }

    /// 把 next 的第 skipRows 行之后追加到 base 底部
    static func append(_ base: CGImage, _ next: CGImage, skipRows: Int) -> CGImage? {
        guard let tail = cropRows(next, from: skipRows, to: next.height) else { return nil }
        let w = base.width
        let h = base.height + tail.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // context 是 y-up：base 画在上方，tail 画在下方
        ctx.draw(base, in: CGRect(x: 0, y: tail.height, width: w, height: base.height))
        ctx.draw(tail, in: CGRect(x: 0, y: 0, width: w, height: tail.height))
        return ctx.makeImage()
    }

    static func downscale(_ img: CGImage, width: CGFloat) -> CGImage? {
        let h = CGFloat(img.height) * width / CGFloat(img.width)
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(h),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
        return ctx.makeImage()
    }

    /// 每行的平均亮度（横向压到 96 宽，纵向 1:1），供 1D 对齐搜索
    static func rowProfile(_ img: CGImage) -> [Double]? {
        let w = 96
        let hh = img.height
        guard let ctx = CGContext(data: nil, width: w, height: hh, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: hh))
        guard let data = ctx.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self)
        var out = [Double](repeating: 0, count: hh)
        for y in 0..<hh {
            var sum = 0
            for x in 0..<w {
                let o = (y * w + x) * 4
                sum += Int(p[o]) + Int(p[o+1]) + Int(p[o+2])
            }
            out[y] = Double(sum) / Double(w * 3)
        }
        return out
    }

    /// prev 的最后 overlap 行 vs next 的前 overlap 行，返回差异率 0..1
    static func mismatch(prev: CGImage, next: CGImage, overlap: Int) -> Double {
        guard overlap > 0, overlap <= prev.height, overlap <= next.height else { return 1 }
        guard let a = cropRows(prev, from: prev.height - overlap, to: prev.height),
              let b = cropRows(next, from: 0, to: overlap),
              let da = bytes(a), let db = bytes(b), da.count == db.count else { return 1 }
        let step = max(4, (da.count / 24_000) / 4 * 4)
        var diff = 0, total = 0
        var i = 0
        while i + 3 < da.count {
            if abs(Int(da[i]) - Int(db[i])) > 14 || abs(Int(da[i + 1]) - Int(db[i + 1])) > 14 {
                diff += 1
            }
            total += 1
            i += step
        }
        return total > 0 ? Double(diff) / Double(total) : 1
    }

    static func bytes(_ img: CGImage) -> [UInt8]? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height,
                                  bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let d = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start: d.assumingMemoryBound(to: UInt8.self),
                                         count: img.height * img.width * 4))
    }
}
