import Cocoa
import CoreImage

// MARK: - 工具类型

enum Tool: Int, CaseIterable {
    case select, rect, ellipse, arrow, pen, highlighter, mosaic, text, number

    var symbolName: String {
        switch self {
        case .select:     return "cursorarrow"
        case .rect:       return "rectangle"
        case .ellipse:    return "circle"
        case .arrow:      return "arrow.up.right"
        case .pen:        return "pencil.tip"
        case .highlighter:return "highlighter"
        case .mosaic:     return "square.grid.3x3.fill"
        case .text:       return "textformat"
        case .number:     return "1.circle"
        }
    }

    var title: String {
        switch self {
        case .select:     return "选择/移动"
        case .rect:       return "矩形"
        case .ellipse:    return "椭圆"
        case .arrow:      return "箭头"
        case .pen:        return "画笔"
        case .highlighter:return "荧光笔"
        case .mosaic:     return "马赛克"
        case .text:       return "文字"
        case .number:     return "序号"
        }
    }
}

// MARK: - 标注模型

struct Annotation {
    var tool: Tool
    var color: NSColor
    var lineWidth: CGFloat
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var points: [CGPoint] = []
    var text: String = ""
    var number: Int = 0

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var isDegenerate: Bool {
        switch tool {
        case .pen, .highlighter: return points.count < 2
        case .text: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return rect.width < 2 && rect.height < 2
        }
    }
}

// MARK: - 标注渲染（屏幕与导出共用，坐标原点左上、y 向下）

enum AnnotationRenderer {

    /// 在已经设置好 y-down point 用户空间的绘图上下文中绘制全部标注。
    /// - Parameters:
    ///   - base: 原始截图的 NSImage（与 bounds 同尺寸）
    ///   - mosaic: 预先像素化后的整图，用于马赛克工具
    static func drawAll(_ list: [Annotation], base: NSImage, mosaic: NSImage?, bounds: CGRect) {
        for a in list { draw(a, base: base, mosaic: mosaic, bounds: bounds) }
    }

    static func draw(_ a: Annotation, base: NSImage, mosaic: NSImage?, bounds: CGRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        defer { ctx?.restoreGState() }

        switch a.tool {
        case .select:
            break

        case .rect:
            let p = NSBezierPath(rect: a.rect)
            p.lineWidth = a.lineWidth
            a.color.setStroke()
            p.stroke()

        case .ellipse:
            let p = NSBezierPath(ovalIn: a.rect)
            p.lineWidth = a.lineWidth
            a.color.setStroke()
            p.stroke()

        case .arrow:
            drawArrow(from: a.start, to: a.end, color: a.color, width: a.lineWidth)

        case .pen:
            guard a.points.count > 1 else { break }
            let p = NSBezierPath()
            p.move(to: a.points[0])
            for pt in a.points.dropFirst() { p.line(to: pt) }
            p.lineWidth = a.lineWidth
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            a.color.setStroke()
            p.stroke()

        case .highlighter:
            guard a.points.count > 1 else { break }
            let p = NSBezierPath()
            p.move(to: a.points[0])
            for pt in a.points.dropFirst() { p.line(to: pt) }
            p.lineWidth = a.lineWidth * 4
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            a.color.withAlphaComponent(0.35).setStroke()
            p.stroke()

        case .mosaic:
            guard let mosaic = mosaic else { break }
            let r = a.rect.intersection(bounds)
            guard r.width > 1, r.height > 1 else { break }
            ctx?.saveGState()
            ctx?.clip(to: r)
            mosaic.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0,
                        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
            ctx?.restoreGState()

        case .text:
            guard !a.text.isEmpty else { break }
            let font = NSFont.systemFont(ofSize: max(13, a.lineWidth * 5), weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: a.color,
            ]
            let str = NSAttributedString(string: a.text, attributes: attrs)
            str.draw(at: a.start)

        case .number:
            let d = max(22, a.lineWidth * 7)
            let r = CGRect(x: a.start.x - d / 2, y: a.start.y - d / 2, width: d, height: d)
            a.color.setFill()
            NSBezierPath(ovalIn: r).fill()
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let font = NSFont.systemFont(ofSize: d * 0.58, weight: .bold)
            let str = NSAttributedString(string: "\(a.number)", attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: para,
            ])
            let h = str.size().height
            str.draw(in: CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h))
        }
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max(1, sqrt(dx * dx + dy * dy))
        let ux = dx / len, uy = dy / len
        let head = min(max(10, width * 4.2), len * 0.55)
        let halfW = head * 0.52
        // 缩短线尾，避免穿出箭头
        let shaftEnd = CGPoint(x: to.x - ux * head * 0.75, y: to.y - uy * head * 0.75)

        let shaft = NSBezierPath()
        shaft.move(to: from)
        shaft.line(to: shaftEnd)
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        color.setStroke()
        shaft.stroke()

        let base = CGPoint(x: to.x - ux * head, y: to.y - uy * head)
        let nx = -uy, ny = ux
        let headPath = NSBezierPath()
        headPath.move(to: to)
        headPath.line(to: CGPoint(x: base.x + nx * halfW, y: base.y + ny * halfW))
        headPath.line(to: CGPoint(x: base.x - nx * halfW, y: base.y - ny * halfW))
        headPath.close()
        color.setFill()
        headPath.fill()
    }
}

// MARK: - 偏好

enum Prefs {
    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.26, blue: 0.28, alpha: 1), // 红
        NSColor(srgbRed: 0.98, green: 0.68, blue: 0.18, alpha: 1), // 橙黄
        NSColor(srgbRed: 0.30, green: 0.80, blue: 0.38, alpha: 1), // 绿
        NSColor(srgbRed: 0.24, green: 0.60, blue: 0.99, alpha: 1), // 蓝
        NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1), // 白
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1), // 黑
    ]

    static let widths: [CGFloat] = [2, 4, 7]

    static func colorIndex() -> Int {
        let v = UserDefaults.standard.integer(forKey: "colorIndex")
        return (0..<palette.count).contains(v) ? v : 0
    }
    static func setColorIndex(_ i: Int) { UserDefaults.standard.set(i, forKey: "colorIndex") }

    static func widthIndex() -> Int {
        let v = UserDefaults.standard.integer(forKey: "widthIndex")
        return (0..<widths.count).contains(v) ? v : 0
    }
    static func setWidthIndex(_ i: Int) { UserDefaults.standard.set(i, forKey: "widthIndex") }

    static var saveDirectory: URL {
        let fm = FileManager.default
        if let d = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first, fm.fileExists(atPath: d.path) {
            return d
        }
        if let d = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return d
        }
        return fm.homeDirectoryForCurrentUser
    }

    static func suggestedFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "MoShot-\(f.string(from: Date())).png"
    }
}

// MARK: - 图像工具

enum ImageUtil {

    static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// 马赛克：降采样再最近邻放大，块状化。返回与输入同尺寸的图像。
    static func pixelate(_ image: CGImage, block: CGFloat = 14) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let bw = max(1, Int(CGFloat(w) / block))
        let bh = max(1, Int(CGFloat(h) / block))
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let small = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: bw, height: bh))
        guard let smallImg = small.makeImage() else { return nil }

        guard let big = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        big.interpolationQuality = .none
        big.draw(smallImg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return big.makeImage()
    }

    static func cropped(_ image: CGImage, toPixelRect r: CGRect) -> CGImage? {
        image.cropping(to: r.integral)
    }
}

// MARK: - 导出

enum Exporter {

    /// 把标注渲染到截图，生成最终图像（像素尺寸 = points * scale）
    static func flatten(base: CGImage, annotations: [Annotation], pointSize: CGSize, scale: CGFloat) -> CGImage? {
        let pw = Int((pointSize.width * scale).rounded())
        let ph = Int((pointSize.height * scale).rounded())
        guard pw > 0, ph > 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height)
        let baseNS = NSImage(cgImage: base, size: bounds.size)

        // 1) 图像本身：y-up 的 point 空间，CGImage 首行落在视觉顶部
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(base, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()

        // 2) 标注：翻转成 y-down 的 point 空间（原点左上），与屏幕绘制坐标系一致
        var mosaicNS: NSImage? = nil
        if annotations.contains(where: { $0.tool == .mosaic }) {
            if let px = ImageUtil.pixelate(base, block: 14) {
                mosaicNS = NSImage(cgImage: px, size: bounds.size)
            }
        }

        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        AnnotationRenderer.drawAll(annotations, base: baseNS, mosaic: mosaicNS, bounds: bounds)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        return ctx.makeImage()
    }
}
