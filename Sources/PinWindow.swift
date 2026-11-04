import Cocoa

/// 贴图窗口：置顶显示一张截图，可拖动、滚轮缩放、双击关闭
final class PinWindow: NSWindow {

    let image: CGImage
    var zoom: CGFloat = 1.0
    private var pointSize: NSSize

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.pointSize = NSSize(width: CGFloat(image.width) / scale,
                                height: CGFloat(image.height) / scale)
        let content = CGRect(origin: .zero, size: pointSize)
        super.init(contentRect: content, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = PinView(frame: content)
        v.pinWindow = self
        v.image = image
        contentView = v

        // 出现在鼠标所在屏的中央偏上
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let sf = screen?.frame {
            setFrameOrigin(CGPoint(x: sf.midX - pointSize.width / 2,
                                   y: sf.midY - pointSize.height / 2))
        }
    }

    func applyZoom(_ factor: CGFloat) {
        let newZoom = min(4.0, max(0.25, zoom * factor))
        guard newZoom != zoom else { return }
        let ratio = newZoom / zoom
        zoom = newZoom
        var f = frame
        let newSize = NSSize(width: pointSize.width * zoom, height: pointSize.height * zoom)
        // 以窗口中心为锚点缩放
        f.origin.x -= (newSize.width - f.width) / 2
        f.origin.y -= (newSize.height - f.height) / 2
        f.size = newSize
        setFrame(f, display: true)
        contentView?.needsDisplay = true
    }

    @objc func closePin() { orderOut(nil); PinController.shared.forget(self) }
}

final class PinView: NSView {
    weak var pinWindow: PinWindow?
    var image: CGImage?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = image else { return }
        let ctx = NSGraphicsContext.current?.cgContext
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        ctx?.saveGState()
        path.addClip()
        NSImage(cgImage: image, size: bounds.size)
            .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0,
                  respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        ctx?.restoreGState()
        NSColor(white: 1, alpha: 0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pinWindow?.closePin(); return }
        pinWindow?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        pinWindow?.applyZoom(delta > 0 ? 1.05 : 0.95)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let win = pinWindow, let img = image else { return }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "复制", action: #selector(doCopy), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let save = NSMenuItem(title: "保存到文件", action: #selector(doSave), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭", action: #selector(doClose), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        _ = img
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        _ = win
    }

    @objc private func doCopy() {
        guard let image = image, let data = ImageUtil.pngData(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
    }

    @objc private func doSave() {
        guard let image = image else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Prefs.suggestedFilename()
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url, let data = ImageUtil.pngData(image) {
            try? data.write(to: url)
        }
    }

    @objc private func doClose() { pinWindow?.closePin() }
}

final class PinController {
    static let shared = PinController()
    private var windows: [PinWindow] = []

    func show(image: CGImage, scale: CGFloat) {
        let w = PinWindow(image: image, scale: scale)
        windows.append(w)
        w.orderFrontRegardless()
    }

    func forget(_ w: PinWindow) {
        windows.removeAll { $0 === w }
    }
}
