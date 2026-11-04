import Cocoa
import Vision

// 内置自检：验证渲染/裁剪/马赛克/编码/剪贴板/OCR 的纯逻辑。
// 全部离线，不弹窗、不抢焦点，可在 CI 或命令行直接跑。

private var passCount = 0
private var failCount = 0

private func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond {
        passCount += 1
        print("PASS  \(name)")
    } else {
        failCount += 1
        print("FAIL  \(name) \(detail)")
    }
}

private func makeImage(width: Int, height: Int,
                       topColor: NSColor, bottomColor: NSColor) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // CGContext 原点左下：先铺下半，再铺上半
    ctx.setFillColor(bottomColor.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    ctx.setFillColor(topColor.cgColor)
    ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    return ctx.makeImage()!
}

private func colorAt(_ img: CGImage, _ x: Int, _ y: Int) -> NSColor? {
    let rep = NSBitmapImageRep(cgImage: img)
    guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
    return rep.colorAt(x: x, y: y)
}

private func renderTextImage(_ text: String) -> CGImage {
    let size = NSSize(width: 520, height: 140)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(at: NSPoint(x: 24, y: 34),
                            withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .bold),
                                             .foregroundColor: NSColor.black])
    img.unlockFocus()
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

func runSelfTest() -> Bool {
    print("MoShot self-test")

    // 1. 基础图构造与像素读取
    let base = makeImage(width: 200, height: 100,
                         topColor: .black, bottomColor: .white)
    check("base size", base.width == 200 && base.height == 100)
    if let c = colorAt(base, 100, 10) {
        check("base top is dark", c.brightnessComponent < 0.2, "\(c)")
    }
    if let c = colorAt(base, 100, 90) {
        check("base bottom is light", c.brightnessComponent > 0.8, "\(c)")
    }

    // 2. flatten 尺寸 = point * scale
    var pen = Annotation(tool: .pen, color: .red, lineWidth: 6)
    pen.points = [CGPoint(x: 0, y: 3), CGPoint(x: 200, y: 3)]
    let flat = Exporter.flatten(base: base, annotations: [pen],
                                pointSize: CGSize(width: 200, height: 100), scale: 2)
    check("flatten non-nil", flat != nil)
    if let flat = flat {
        check("flatten pixel size", flat.width == 400 && flat.height == 200,
              "\(flat.width)x\(flat.height)")
        // 3. y 轴方向：线画在顶部(y=3)，导出图顶部应偏红，底部应仍是白
        let top = colorAt(flat, 200, 6)
        let bottom = colorAt(flat, 200, 194)
        check("annotation stays at top", (top?.redComponent ?? 0) > 0.6 && (top?.greenComponent ?? 1) < 0.5,
              "\(String(describing: top))")
        check("bottom untouched", (bottom?.brightnessComponent ?? 0) > 0.8,
              "\(String(describing: bottom))")
        // 4. 底图方向：导出图顶部应是原图的暗色上半
        let bgTop = colorAt(flat, 20, 20)
        check("base image upright (top dark)", (bgTop?.brightnessComponent ?? 1) < 0.2,
              "\(String(describing: bgTop))")
        let bgBottom = colorAt(flat, 20, 180)
        check("base image upright (bottom light)", (bgBottom?.brightnessComponent ?? 0) > 0.8,
              "\(String(describing: bgBottom))")
    }

    // 5. 马赛克降低局部方差
    var mosaic = Annotation(tool: .mosaic, color: .black, lineWidth: 4)
    mosaic.start = CGPoint(x: 0, y: 0)
    mosaic.end = CGPoint(x: 200, y: 100)
    let flatM = Exporter.flatten(base: base, annotations: [mosaic],
                                 pointSize: CGSize(width: 200, height: 100), scale: 1)
    if let fm = flatM {
        // 原图在 y=50 处由上黑下白突变；马赛克后应出现大量中间灰像素
        let rep = NSBitmapImageRep(cgImage: fm)
        var mid = 0
        for y in stride(from: 40, to: 60, by: 2) {
            for x in stride(from: 0, to: 200, by: 4) {
                if let c = rep.colorAt(x: x, y: y) {
                    let b = c.brightnessComponent
                    if b > 0.15 && b < 0.85 { mid += 1 }
                }
            }
        }
        check("mosaic produces intermediate tone", mid > 20, "mid pixels=\(mid)")
    } else {
        check("mosaic render", false)
    }

    // 6. PNG 编码往返
    if let png = ImageUtil.pngData(base),
       let src = CGImageSourceCreateWithData(png as CFData, nil),
       let back = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        check("png roundtrip", back.width == 200 && back.height == 100 && png.count > 100)
    } else {
        check("png roundtrip", false)
    }

    // 7. 剪贴板写入/读回（用独立剪贴板，避免污染用户剪贴板）
    let pb = NSPasteboard(name: NSPasteboard.Name("MoShotSelfTest"))
    if let png = ImageUtil.pngData(base) {
        pb.clearContents()
        pb.setData(png, forType: .png)
        check("pasteboard png", pb.data(forType: .png) != nil)
        pb.releaseGlobally()
    } else {
        check("pasteboard png", false)
    }

    // 8. 标注退化判断
    var emptyRect = Annotation(tool: .rect, color: .red, lineWidth: 2)
    emptyRect.start = CGPoint(x: 10, y: 10)
    emptyRect.end = CGPoint(x: 10.5, y: 10.5)
    check("degenerate rect detected", emptyRect.isDegenerate)
    var realRect = emptyRect
    realRect.end = CGPoint(x: 60, y: 60)
    check("real rect not degenerate", !realRect.isDegenerate)

    // 9. 全工具渲染不崩溃
    var allTools = true
    for tool in Tool.allCases {
        var a = Annotation(tool: tool, color: .red, lineWidth: 4)
        a.start = CGPoint(x: 10, y: 10)
        a.end = CGPoint(x: 80, y: 60)
        a.points = [a.start, CGPoint(x: 40, y: 30), a.end]
        a.text = "测试"
        a.number = 1
        if Exporter.flatten(base: base, annotations: [a],
                            pointSize: CGSize(width: 200, height: 100), scale: 1) == nil {
            allTools = false
        }
    }
    check("all tools render", allTools)

    // 10. OCR（主线程跑 RunLoop 等待，避免 main queue 回调被阻塞）
    let textImage = renderTextImage("MoShot 截图")
    var ocrText: String?
    var ocrDone = false
    OCRService.recognize(textImage) { t in
        ocrText = t
        ocrDone = true
    }
    _ = waitUntil({ ocrDone }, timeout: 90)
    let lower = (ocrText ?? "").lowercased()
    let alnum = lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        .map { String($0) }.joined()
    let hex = lower.unicodeScalars.prefix(14).map { String($0.value, radix: 16) }.joined(separator: " ")
    check("ocr reads latin text", alnum.contains("moshot"), "got: \(ocrText ?? "nil") [hex \(hex)]")
    check("ocr reads chinese text", (ocrText ?? "").contains("截"), "got: \(ocrText ?? "nil")")

    // 11. 屏幕常量
    check("screen(s) available", !NSScreen.screens.isEmpty)
    print("screen permission: \(ScreenCapture.hasPermission)")

    print("\n\(passCount) passed, \(failCount) failed")
    return failCount == 0
}
