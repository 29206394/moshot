import Cocoa

enum ToolbarAction: String {
    case undo, redo, ocr, save, copy, pin, close
}

/// 单个图标按钮（自绘，hover/active 高亮）
final class IconButton: NSView {
    let icon: NSImage
    let tooltip: String
    var action: (() -> Void)?
    var isActive: Bool = false { didSet { needsDisplay = true } }
    var isEnabled: Bool = true { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, tooltip: String) {
        self.tooltip = tooltip
        self.icon = ToolbarView.tinted(symbol, color: NSColor.white) ?? NSImage()
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        self.toolTip = tooltip
        self.wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // 按下即触发，符合截图工具的快节奏
        action?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        if isActive {
            NSColor(white: 1, alpha: 0.22).setFill()
            bg.fill()
        } else if hovering && isEnabled {
            NSColor(white: 1, alpha: 0.12).setFill()
            bg.fill()
        }
        let alpha: CGFloat = isEnabled ? 1.0 : 0.3
        let s = icon.size
        let r = CGRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2,
                       width: s.width, height: s.height)
        icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha)
    }
}

/// 颜色/线宽圆点
final class DotButton: NSView {
    let color: NSColor
    var action: (() -> Void)?
    var isActive: Bool = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    /// 直径（线宽点用不同大小）
    var dotDiameter: CGFloat = 12

    init(color: NSColor, diameter: CGFloat) {
        self.color = color
        self.dotDiameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 30))
        self.wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { action?() }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            let ring = NSBezierPath(ovalIn: CGRect(x: 1, y: 4, width: 20, height: 20))
            NSColor.white.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        } else if hovering {
            NSColor(white: 1, alpha: 0.14).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let d = isActive ? dotDiameter + 2 : dotDiameter
        let r = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        let path = NSBezierPath(ovalIn: r)
        color.setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.25).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// 浮动工具条
final class ToolbarView: NSView {

    var onTool: ((Tool) -> Void)?
    var onColor: ((Int) -> Void)?
    var onWidth: ((Int) -> Void)?
    var onAction: ((ToolbarAction) -> Void)?

    private(set) var activeTool: Tool = .rect
    private(set) var activeColor: Int = Prefs.colorIndex()
    private(set) var activeWidth: Int = Prefs.widthIndex()

    private var toolButtons: [Tool: IconButton] = [:]
    private var colorDots: [DotButton] = []
    private var widthDots: [DotButton] = []
    private var actionButtons: [ToolbarAction: IconButton] = [:]

    private let iconSize: CGFloat = 30
    private let padding: CGFloat = 7
    private let gap: CGFloat = 2
    private let groupGap: CGFloat = 9

    static let preferredHeight: CGFloat = 44

    static func tinted(_ symbol: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .medium)
        let configured = base.withSymbolConfiguration(cfg) ?? base
        let size = configured.size
        return NSImage(size: size, flipped: false) { rect in
            configured.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        for tool in Tool.allCases {
            let b = IconButton(symbol: tool.symbolName, tooltip: tool.title)
            b.action = { [weak self] in self?.select(tool: tool) }
            addSubview(b)
            toolButtons[tool] = b
        }

        for (i, c) in Prefs.palette.enumerated() {
            let d = DotButton(color: c, diameter: 13)
            d.action = { [weak self] in self?.select(color: i) }
            addSubview(d)
            colorDots.append(d)
        }

        for (i, w) in Prefs.widths.enumerated() {
            let d = DotButton(color: NSColor(white: 0.92, alpha: 1), diameter: 4 + w * 1.4)
            d.action = { [weak self] in self?.select(width: i) }
            addSubview(d)
            widthDots.append(d)
        }

        let actions: [(ToolbarAction, String, String)] = [
            (.undo, "arrow.uturn.backward", "撤销 ⌘Z"),
            (.redo, "arrow.uturn.forward", "重做 ⇧⌘Z"),
            (.ocr, "text.viewfinder", "提取文字"),
            (.close, "xmark", "取消 Esc"),
            (.pin, "pin", "贴图 P"),
            (.save, "square.and.arrow.down", "保存 ⌘S"),
            (.copy, "doc.on.doc", "复制 Enter"),
        ]
        for (a, sym, tip) in actions {
            let b = IconButton(symbol: sym, tooltip: tip)
            b.action = { [weak self] in self?.onAction?(a) }
            addSubview(b)
            actionButtons[a] = b
        }

        refreshSelection()
        autoresizesSubviews = false
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 布局

    private var orderedItems: [NSView] {
        var items: [NSView] = []
        items.append(contentsOf: Tool.allCases.compactMap { toolButtons[$0] })
        items.append(contentsOf: colorDots)
        items.append(contentsOf: widthDots)
        items.append(contentsOf: [ToolbarAction.undo, .redo, .ocr, .close, .pin, .save, .copy].compactMap { actionButtons[$0] })
        return items
    }

    /// 返回整条工具条的推荐尺寸
    func fittingSizeForContent() -> NSSize {
        var groups: [[NSView]] = [
            Tool.allCases.compactMap { toolButtons[$0] },
            colorDots,
            widthDots,
            [ToolbarAction.undo, .redo, .ocr, .close, .pin, .save, .copy].compactMap { actionButtons[$0] },
        ]
        var w = padding * 2
        for (gi, g) in groups.enumerated() {
            if gi > 0 { w += groupGap * 2 }
            for (i, v) in g.enumerated() {
                w += v.frame.width
                if i < g.count - 1 { w += gap }
            }
        }
        return NSSize(width: ceil(w), height: Self.preferredHeight)
    }

    override func layout() {
        super.layout()
        var groups: [[NSView]] = [
            Tool.allCases.compactMap { toolButtons[$0] },
            colorDots,
            widthDots,
            [ToolbarAction.undo, .redo, .ocr, .close, .pin, .save, .copy].compactMap { actionButtons[$0] },
        ]
        var x = padding
        let h = bounds.height
        for (gi, g) in groups.enumerated() {
            if gi > 0 { x += groupGap * 2 }
            for (i, v) in g.enumerated() {
                v.frame = CGRect(x: x, y: (h - v.frame.height) / 2, width: v.frame.width, height: v.frame.height)
                x += v.frame.width
                if i < g.count - 1 { x += gap }
            }
        }
    }

    // MARK: 状态

    private func select(tool: Tool) {
        activeTool = tool
        refreshSelection()
        onTool?(tool)
    }
    private func select(color i: Int) {
        activeColor = i
        Prefs.setColorIndex(i)
        refreshSelection()
        onColor?(i)
    }
    private func select(width i: Int) {
        activeWidth = i
        Prefs.setWidthIndex(i)
        refreshSelection()
        onWidth?(i)
    }

    private func refreshSelection() {
        for (t, b) in toolButtons { b.isActive = (t == activeTool) }
        for (i, d) in colorDots.enumerated() { d.isActive = (i == activeColor) }
        for (i, d) in widthDots.enumerated() { d.isActive = (i == activeWidth) }
        needsDisplay = true
    }

    func setUndoEnabled(_ canUndo: Bool, redo: Bool) {
        actionButtons[.undo]?.isEnabled = canUndo
        actionButtons[.redo]?.isEnabled = redo
    }

    /// 由外部（快捷键）切换工具时同步高亮
    func highlight(tool: Tool) {
        activeTool = tool
        refreshSelection()
    }

    // MARK: 背景

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.96).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
