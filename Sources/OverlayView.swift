import Cocoa
import Vision

enum FinishAction { case copy, save, pin }

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 每块屏幕一个覆层：负责框选、标注、快捷键
final class OverlayView: NSView {

    enum Mode { case idle, drawing, editing }
    enum Drag { case none, newSelection, moveSelection, resize(Int), drawAnnotation }

    let shot: ScreenShot
    var mode: Mode = .idle
    var selection: CGRect = .zero
    private var dragOrigin: CGPoint = .zero
    private var dragMode: Drag = .none
    private var selectionAtDragStart: CGRect = .zero
    private var current: Annotation?
    private var textEditor: NSTextField?

    private(set) var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var numberCounter = 0

    var activeTool: Tool = .rect
    var activeColor: NSColor = Prefs.palette[Prefs.colorIndex()]
    var lineWidth: CGFloat = Prefs.widths[Prefs.widthIndex()]

    private var baseImage: NSImage?
    private var mosaicCache: NSImage?

    var toolbar: ToolbarView!
    var onFinish: ((OverlayView, FinishAction) -> Void)?
    var onCancel: ((OverlayView) -> Void)?
    var onBeganDragging: ((OverlayView) -> Void)?
    var onOCR: ((CGImage) -> Void)?

    init(shot: ScreenShot) {
        self.shot = shot
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        wantsLayer = true
        buildToolbar()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func buildToolbar() {
        let tb = ToolbarView()
        tb.isHidden = true
        tb.onTool = { [weak self] tool in
            guard let self = self else { return }
            self.commitPendingText()
            self.activeTool = tool
            self.window?.makeFirstResponder(self)
        }
        tb.onColor = { [weak self] i in
            guard let self = self else { return }
            self.activeColor = Prefs.palette[i]
        }
        tb.onWidth = { [weak self] i in
            guard let self = self else { return }
            self.lineWidth = Prefs.widths[i]
        }
        tb.onAction = { [weak self] action in
            guard let self = self else { return }
            switch action {
            case .undo: self.undo()
            case .redo: self.redo()
            case .copy: self.onFinish?(self, .copy)
            case .save: self.onFinish?(self, .save)
            case .pin: self.onFinish?(self, .pin)
            case .close: self.onCancel?(self)
            case .ocr:
                if let img = self.resultImage(includeAnnotations: false) { self.onOCR?(img) }
            }
        }
        addSubview(tb)
        toolbar = tb
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 遮罩
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.38).setFill()
        bounds.fill()

        guard selection.width > 1, selection.height > 1 else {
            drawHint()
            return
        }

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.clip(to: selection)

        baseImage?.draw(in: selection, from: .zero, operation: .sourceOver, fraction: 1.0,
                        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])

        ctx?.translateBy(x: selection.minX, y: selection.minY)
        let local = CGRect(origin: .zero, size: selection.size)
        var list = annotations
        if let cur = current { list.append(cur) }
        AnnotationRenderer.drawAll(list, base: baseImage ?? NSImage(), mosaic: mosaicCache, bounds: local)

        ctx?.restoreGState()

        // 边框
        NSColor(white: 1, alpha: 0.95).setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1
        border.stroke()

        if mode == .editing {
            drawHandles()
        }
        drawSizeBadge()
    }

    private func drawHint() {
        let text = "拖拽选择区域 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let r = CGRect(x: (bounds.width - size.width) / 2 - 14,
                       y: bounds.height / 2 - 16,
                       width: size.width + 28, height: 32)
        NSColor(srgbRed: 0.1, green: 0.11, blue: 0.13, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + 14, y: r.minY + 8), withAttributes: attrs)
    }

    private func drawSizeBadge() {
        guard selection.width > 1 else { return }
        let text = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var x = selection.minX
        var y = selection.minY - 22
        if y < 4 { y = selection.minY + 6 }
        x = min(max(2, x), bounds.width - size.width - 14)
        let r = CGRect(x: x, y: y, width: size.width + 12, height: 18)
        NSColor(srgbRed: 0.1, green: 0.11, blue: 0.13, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3), withAttributes: attrs)
    }

    private func handleRects() -> [CGRect] {
        let s = selection
        let d: CGFloat = 9
        let pts: [CGPoint] = [
            CGPoint(x: s.minX, y: s.minY), CGPoint(x: s.midX, y: s.minY), CGPoint(x: s.maxX, y: s.minY),
            CGPoint(x: s.maxX, y: s.midY), CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.midX, y: s.maxY),
            CGPoint(x: s.minX, y: s.maxY), CGPoint(x: s.minX, y: s.midY),
        ]
        return pts.map { CGRect(x: $0.x - d / 2, y: $0.y - d / 2, width: d, height: d) }
    }

    private func drawHandles() {
        for r in handleRects() {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor(srgbRed: 0.15, green: 0.55, blue: 0.95, alpha: 1).setStroke()
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1.2, dy: 1.2))
            p.lineWidth = 1.6
            p.stroke()
        }
    }

    // MARK: - 鼠标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .editing else { NSCursor.crosshair.set(); return }
        let p = convert(event.locationInWindow, from: nil)
        if let idx = handleIndex(at: p) {
            (idx == 1 || idx == 5 ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
            if idx == 0 || idx == 4 || idx == 2 || idx == 6 { NSCursor.crosshair.set() }
        } else if selection.contains(p) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func handleIndex(at p: CGPoint) -> Int? {
        for (i, r) in handleRects().enumerated() where r.insetBy(dx: -3, dy: -3).contains(p) { return i }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        if textEditor != nil { commitPendingText() }

        switch mode {
        case .idle, .drawing:
            dragOrigin = p
            dragMode = .newSelection
            mode = .drawing
            selection = CGRect(origin: p, size: .zero)
            needSelection()

        case .editing:
            if let idx = handleIndex(at: p) {
                dragMode = .resize(idx)
                selectionAtDragStart = selection
                dragOrigin = p
            } else if selection.contains(p) {
                if activeTool == .select {
                    dragMode = .moveSelection
                    selectionAtDragStart = selection
                    dragOrigin = p
                } else if activeTool == .text {
                    beginText(at: p)
                } else if activeTool == .number {
                    pushUndo()
                    numberCounter += 1
                    var a = Annotation(tool: .number, color: activeColor, lineWidth: lineWidth)
                    a.start = CGPoint(x: p.x - selection.minX, y: p.y - selection.minY)
                    a.number = numberCounter
                    annotations.append(a)
                    mosaicCache = nil
                    refreshUndoButtons()
                    needsDisplay = true
                } else {
                    dragMode = .drawAnnotation
                    dragOrigin = p
                    let local0 = CGPoint(x: p.x - selection.minX, y: p.y - selection.minY)
                    var a = Annotation(tool: activeTool, color: activeColor, lineWidth: lineWidth)
                    a.start = local0
                    a.end = local0
                    a.points = [local0]
                    current = a
                }
            } else {
                // 点选区外 = 完成并复制
                onFinish?(self, .copy)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .newSelection:
            let r = CGRect(x: min(dragOrigin.x, p.x), y: min(dragOrigin.y, p.y),
                           width: abs(p.x - dragOrigin.x), height: abs(p.y - dragOrigin.y))
            selection = clampToScreen(r)
            needSelection()
            needsDisplay = true

        case .moveSelection:
            let dx = p.x - dragOrigin.x, dy = p.y - dragOrigin.y
            var r = selectionAtDragStart.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(0, r.minX), bounds.width - r.width)
            r.origin.y = min(max(0, r.minY), bounds.height - r.height)
            selection = r
            needSelection()
            needsDisplay = true

        case .resize(let idx):
            var r = selectionAtDragStart
            let s = selectionAtDragStart
            switch idx {
            case 0: r = CGRect(x: p.x, y: p.y, width: s.maxX - p.x, height: s.maxY - p.y)
            case 1: r = CGRect(x: s.minX, y: p.y, width: s.width, height: s.maxY - p.y)
            case 2: r = CGRect(x: s.minX, y: p.y, width: p.x - s.minX, height: s.maxY - p.y)
            case 3: r = CGRect(x: s.minX, y: s.minY, width: p.x - s.minX, height: s.height)
            case 4: r = CGRect(x: s.minX, y: s.minY, width: p.x - s.minX, height: p.y - s.minY)
            case 5: r = CGRect(x: s.minX, y: s.minY, width: s.width, height: p.y - s.minY)
            case 6: r = CGRect(x: p.x, y: s.minY, width: s.maxX - p.x, height: p.y - s.minY)
            default: r = CGRect(x: p.x, y: s.minY, width: s.maxX - p.x, height: s.height)
            }
            selection = clampToScreen(r.standardized)
            needSelection()
            needsDisplay = true

        case .drawAnnotation:
            guard var a = current else { return }
            let local = CGPoint(x: p.x - selection.minX, y: p.y - selection.minY)
            a.end = local
            if a.tool == .pen || a.tool == .highlighter { a.points.append(local) }
            current = a
            needsDisplay = true

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .newSelection:
            if selection.width < 6 || selection.height < 6 {
                selection = .zero
                mode = .idle
                needsDisplay = true
            } else {
                enterEditing()
            }
        case .resize:
            needSelection()
        case .moveSelection:
            needSelection()
        case .drawAnnotation:
            if var a = current {
                if a.tool == .pen || a.tool == .highlighter, a.points.count < 2 {
                    a.points.append(a.end)
                }
                if !a.isDegenerate {
                    pushUndo()
                    annotations.append(a)
                }
            }
            current = nil
            refreshUndoButtons()
            needsDisplay = true
        case .none:
            break
        }
        dragMode = .none
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?(self)
    }

    private func clampToScreen(_ r: CGRect) -> CGRect {
        var out = r
        out.origin.x = max(0, min(out.minX, bounds.width - 1))
        out.origin.y = max(0, min(out.minY, bounds.height - 1))
        out.size.width = min(out.width, bounds.width - out.minX)
        out.size.height = min(out.height, bounds.height - out.minY)
        return out
    }

    // MARK: - 状态流转

    private func enterEditing() {
        mode = .editing
        onBeganDragging?(self)
        rebuildBase()
        toolbar.isHidden = false
        layoutToolbar()
        refreshUndoButtons()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    /// 全屏截图：选区直接铺满该屏并进入标注态
    func startWithFullSelection() {
        selection = bounds
        mode = .editing
        onBeganDragging?(self)
        rebuildBase()
        toolbar.isHidden = false
        layoutToolbar()
        refreshUndoButtons()
        needsDisplay = true
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    private func needSelection() {
        if mode == .editing { rebuildBase() }
    }

    private func rebuildBase() {
        guard selection.width > 1, selection.height > 1 else { baseImage = nil; return }
        let scale = shot.scale
        let px = CGRect(x: selection.minX * scale, y: selection.minY * scale,
                        width: selection.width * scale, height: selection.height * scale).integral
        guard let cropped = shot.image.cropping(to: px) else { baseImage = nil; return }
        baseImage = NSImage(cgImage: cropped, size: selection.size)
        mosaicCache = nil
        layoutToolbar()
    }

    private func ensureMosaic() {
        guard mosaicCache == nil, let base = baseImage, let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        if let px = ImageUtil.pixelate(cg, block: CGFloat(max(8, cg.width / 90))) {
            mosaicCache = NSImage(cgImage: px, size: selection.size)
        }
    }

    private func layoutToolbar() {
        guard toolbar != nil else { return }
        let size = toolbar.fittingSizeForContent()
        var x = selection.midX - size.width / 2
        x = min(max(8, x), bounds.width - size.width - 8)
        var y = selection.maxY + 10
        if y + size.height > bounds.height - 8 {
            y = selection.minY - size.height - 10
        }
        y = min(max(8, y), bounds.height - size.height - 8)
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        toolbar.needsLayout = true
        toolbar.layer?.shadowColor = NSColor.black.cgColor
        toolbar.layer?.shadowOpacity = 0.4
        toolbar.layer?.shadowRadius = 14
        toolbar.layer?.shadowOffset = CGSize(width: 0, height: 0)
    }

    // MARK: - 文字

    private func beginText(at p: CGPoint) {
        let field = NSTextField(frame: CGRect(x: p.x, y: p.y, width: 240, height: 28))
        field.font = NSFont.systemFont(ofSize: max(13, lineWidth * 5), weight: .medium)
        field.textColor = activeColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "输入文字，回车确认"
        field.target = self
        field.action = #selector(commitTextAction)
        addSubview(field)
        textEditor = field
        window?.makeFirstResponder(field)
    }

    @objc private func commitTextAction() { commitPendingText() }

    func commitPendingText() {
        guard let field = textEditor else { return }
        let text = field.stringValue
        let origin = field.frame.origin
        field.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, selection.width > 1 else { needsDisplay = true; return }
        pushUndo()
        var a = Annotation(tool: .text, color: activeColor, lineWidth: lineWidth)
        a.start = CGPoint(x: origin.x - selection.minX, y: origin.y - selection.minY)
        a.text = trimmed
        annotations.append(a)
        refreshUndoButtons()
        needsDisplay = true
    }

    // MARK: - 撤销

    private func pushUndo() {
        undoStack.append(annotations)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = last
        numberCounter = min(numberCounter, annotations.filter { $0.tool == .number }.count)
        refreshUndoButtons()
        needsDisplay = true
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        refreshUndoButtons()
        needsDisplay = true
    }

    private func refreshUndoButtons() {
        toolbar?.setUndoEnabled(!undoStack.isEmpty, redo: !redoStack.isEmpty)
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        if textEditor != nil { super.keyDown(with: event); return }
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: // Esc
            if mode == .editing { closeEditing() } else { onCancel?(self) }
        case 36, 76: // Return / Enter
            if mode == .editing { onFinish?(self, .copy) } else { onCancel?(self) }
        case 51, 117: // Delete
            if mode == .editing, !annotations.isEmpty {
                pushUndo(); annotations.removeLast(); refreshUndoButtons(); needsDisplay = true
            }
        default:
            let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if cmd && ch == "z" {
                if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            } else if cmd && ch == "c" {
                if mode == .editing { onFinish?(self, .copy) }
            } else if cmd && ch == "s" {
                if mode == .editing { onFinish?(self, .save) }
            } else if !cmd && ch == "p" {
                if mode == .editing { onFinish?(self, .pin) }
            } else if !cmd, let n = Int(ch), n >= 1, n <= Tool.allCases.count {
                let tool = Tool.allCases[n - 1]
                activeTool = tool
                toolbar.highlight(tool: tool)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func closeEditing() {
        mode = .idle
        selection = .zero
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        baseImage = nil
        mosaicCache = nil
        toolbar.isHidden = true
        needsDisplay = true
    }

    /// 端到端模拟（供 CLI 验证：真实屏幕 → 裁剪 → 标注 → 导出，不显示任何窗口）
    func simulate(region: CGRect) -> CGImage? {
        selection = region
        mode = .editing
        rebuildBase()
        var demo: [Annotation] = []

        var rect = Annotation(tool: .rect, color: Prefs.palette[0], lineWidth: 4)
        rect.start = CGPoint(x: 24, y: 24)
        rect.end = CGPoint(x: min(240, region.width - 24), y: min(140, region.height - 24))
        demo.append(rect)

        var arrow = Annotation(tool: .arrow, color: Prefs.palette[3], lineWidth: 4)
        arrow.start = CGPoint(x: region.width * 0.55, y: region.height * 0.7)
        arrow.end = CGPoint(x: region.width * 0.8, y: region.height * 0.35)
        demo.append(arrow)

        var num = Annotation(tool: .number, color: Prefs.palette[2], lineWidth: 4)
        num.start = CGPoint(x: region.width * 0.35, y: region.height * 0.55)
        num.number = 1
        demo.append(num)

        var txt = Annotation(tool: .text, color: Prefs.palette[0], lineWidth: 4)
        txt.start = CGPoint(x: 30, y: region.height - 60)
        txt.text = "SnapPin 标注"
        demo.append(txt)

        annotations = demo
        return resultImage()
    }

    // MARK: - 导出

    func resultImage(includeAnnotations: Bool = true) -> CGImage? {
        guard selection.width > 1, selection.height > 1 else { return nil }
        let scale = shot.scale
        let px = CGRect(x: selection.minX * scale, y: selection.minY * scale,
                        width: selection.width * scale, height: selection.height * scale).integral
        guard let base = shot.image.cropping(to: px) else { return nil }
        guard includeAnnotations, !annotations.isEmpty else { return base }
        if annotations.contains(where: { $0.tool == .mosaic }) { ensureMosaic() }
        return Exporter.flatten(base: base, annotations: annotations,
                                pointSize: selection.size, scale: scale)
    }
}
