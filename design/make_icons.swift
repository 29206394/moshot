import Cocoa

// MoShot 图标生成器
// swiftc -O -swift-version 5 -o make_icons make_icons.swift
// ./make_icons <outdir>     -> 输出 AppIcon.iconset 全尺寸 + 预览图

let canvas: CGFloat = 1024
let cornerRadius: CGFloat = 229

func render(_ size: Int, _ body: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let s = CGFloat(size) / canvas
    ctx.scaleBy(x: s, y: s)
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    body(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func save(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

func base(_ colors: [NSColor]) {
    let rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let p = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    if let g = NSGradient(colors: colors) { g.draw(in: p, angle: -90) }
    NSGraphicsContext.saveGraphicsState()
    p.addClip()
    if let gloss = NSGradient(colors: [NSColor(white: 1, alpha: 0.11), NSColor(white: 1, alpha: 0.0)]) {
        gloss.draw(in: CGRect(x: 0, y: canvas * 0.5, width: canvas, height: canvas * 0.5), angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()
}

func stroke(_ pts: [CGPoint], width: CGFloat, color: NSColor) {
    guard pts.count > 1 else { return }
    let p = NSBezierPath()
    p.move(to: pts[0])
    for pt in pts.dropFirst() { p.line(to: pt) }
    p.lineWidth = width
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    color.setStroke()
    p.stroke()
}

func viewfinder(center c: CGPoint, half: CGFloat, arm: CGFloat, width: CGFloat, color: NSColor) {
    let tl = CGPoint(x: c.x - half, y: c.y + half)
    let tr = CGPoint(x: c.x + half, y: c.y + half)
    let bl = CGPoint(x: c.x - half, y: c.y - half)
    let br = CGPoint(x: c.x + half, y: c.y - half)
    stroke([CGPoint(x: tl.x + arm, y: tl.y), tl, CGPoint(x: tl.x, y: tl.y - arm)], width: width, color: color)
    stroke([CGPoint(x: tr.x - arm, y: tr.y), tr, CGPoint(x: tr.x, y: tr.y - arm)], width: width, color: color)
    stroke([CGPoint(x: bl.x + arm, y: bl.y), bl, CGPoint(x: bl.x, y: bl.y + arm)], width: width, color: color)
    stroke([CGPoint(x: br.x - arm, y: br.y), br, CGPoint(x: br.x, y: br.y + arm)], width: width, color: color)
}

let accent = NSColor(srgbRed: 0.99, green: 0.30, blue: 0.33, alpha: 1)
let darkTop = NSColor(srgbRed: 0.17, green: 0.20, blue: 0.26, alpha: 1)
let darkBottom = NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1)

// 完整版：取景角 + 快门环
func designMain(_ ctx: CGContext) {
    base([darkTop, darkBottom])
    let center = CGPoint(x: 512, y: 512)
    viewfinder(center: center, half: 292, arm: 166, width: 44,
               color: NSColor(white: 1, alpha: 0.88))
    let r: CGFloat = 150
    let ring = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    ring.lineWidth = 46
    accent.setStroke()
    ring.stroke()
    let dotR: CGFloat = 38
    accent.setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - dotR, y: center.y - dotR,
                                width: dotR * 2, height: dotR * 2)).fill()
}

// 小尺寸简化版：粗角标 + 实心点，保证 16/32px 可读
func designCompact(_ ctx: CGContext) {
    base([darkTop, darkBottom])
    let center = CGPoint(x: 512, y: 512)
    viewfinder(center: center, half: 300, arm: 190, width: 72,
               color: NSColor(white: 1, alpha: 0.92))
    accent.setFill()
    NSBezierPath(ovalIn: CGRect(x: 512 - 112, y: 512 - 112, width: 224, height: 224)).fill()
}

// MARK: - 输出

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// 小尺寸用简化版，中大尺寸用完整版
let plan: [(String, Int, Bool)] = [
    ("icon_16x16.png", 16, true),
    ("icon_16x16@2x.png", 32, true),
    ("icon_32x32.png", 32, true),
    ("icon_32x32@2x.png", 64, true),
    ("icon_128x128.png", 128, false),
    ("icon_128x128@2x.png", 256, false),
    ("icon_256x256.png", 256, false),
    ("icon_256x256@2x.png", 512, false),
    ("icon_512x512.png", 512, false),
    ("icon_512x512@2x.png", 1024, false),
]

for (name, size, compact) in plan {
    let img = render(size, compact ? designCompact : designMain)
    save(img, "\(iconset)/\(name)")
}

// 预览图，便于肉眼比对
save(render(512, designMain), "\(outDir)/preview-512.png")
save(render(64, designCompact), "\(outDir)/preview-64.png")
save(render(32, designCompact), "\(outDir)/preview-32.png")
print("written to \(iconset)")
