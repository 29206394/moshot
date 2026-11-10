import Cocoa
import Vision

final class OverlayController {

    static let shared = OverlayController()

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var scrollCapture: ScrollCapture?
    private var scrollHUD: NSWindow?
    private var scrollLabel: NSTextField?
    private var toastWindow: NSWindow?
    private var scrollFrame: NSWindow?
    private var permissionWatch: Timer?
    private var probing = false
    private var ocrWindow: NSWindow?
    private(set) var isActive = false

    var lastSavedPath: String?

    func begin(fullScreen: Bool = false) {
        // 真机排障用：app 自己看到的权限状态（从终端跑 --diagnose 会继承终端权限，不可信）
        PermLog.write("begin: hasPermission=\(ScreenCapture.hasPermission) trusted=\(AXIsProcessTrusted())")
        guard !isActive else { return }
        isActive = true
        NSApp.activate(ignoringOtherApps: true)

        // 首次使用：触发系统授权。注意 CGRequestScreenCaptureAccess() 在首次授权时
        // 通常返回 false（授权对新进程才生效），这里不能直接放弃，要 1s 轮询等它变 true，
        // 命中后自动继续这次截图，不让用户再按一次热键。
        if !ScreenCapture.hasPermission {
            let granted = ScreenCapture.requestPermission()
            if !granted {
                waitForPermissionThenCapture(fullScreen: fullScreen)
                return
            }
        }

        capture(fullScreen: fullScreen)
    }

    private func capture(fullScreen: Bool) {
        Task.detached {
            let shots = await ScreenCapture.captureAll()
            DispatchQueue.main.async {
                if shots.isEmpty {
                    self.isActive = false
                    // 抓不到画面：可能是权限没生效或 ScreenCaptureKit 拒绝，
                    // 同样不弹第二个框，走同一条轻提示
                    PermLog.write("begin: capture empty (preflight=\(ScreenCapture.hasPermission))")
                    self.permissionFallback()
                    return
                }
                self.present(shots, fullScreen: fullScreen)
            }
        }
    }

    /// 等用户在系统设置里勾上权限：命中后自动接着抓屏，无需再按热键，也无需重启。
    /// 两条判据并行：preflight 每秒查一次；每 5 秒真抓一次做探针（有些版本授权后
    /// 当前进程的 preflight 仍是旧值，但实际已经能抓屏）。
    private func waitForPermissionThenCapture(fullScreen: Bool) {
        permissionWatch?.invalidate()
        let deadline = Date().addingTimeInterval(180)
        var tick = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            tick += 1
            if ScreenCapture.hasPermission {
                t.invalidate()
                self.permissionWatch = nil
                PermLog.write("permission: granted while waiting, continue capture")
                self.capture(fullScreen: fullScreen)
            } else if tick % 5 == 0 {
                self.probePermissionByCapture(fullScreen: fullScreen)
            } else if Date() > deadline {
                t.invalidate()
                self.permissionWatch = nil
                self.isActive = false
                PermLog.write("permission: wait timeout 180s")
                self.showToast("还没拿到屏幕录制权限 · 勾选后自动继续", seconds: 5)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionWatch = timer
    }

    /// 授权后即使 preflight 还是 false，实际抓屏可能已经通了：真抓一次验证
    private func probePermissionByCapture(fullScreen: Bool) {
        guard !probing, isActive else { return }
        probing = true
        Task.detached {
            let shots = await ScreenCapture.captureAll()
            DispatchQueue.main.async {
                self.probing = false
                guard self.isActive, !shots.isEmpty else { return }
                self.permissionWatch?.invalidate()
                self.permissionWatch = nil
                PermLog.write("permission: capture probe succeeded, continue")
                self.present(shots, fullScreen: fullScreen)
            }
        }
    }

    private func present(_ shots: [ScreenShot], fullScreen: Bool) {
        let mouse = NSEvent.mouseLocation

        for shot in shots {
            let window = OverlayWindow(contentRect: shot.screen.frame,
                                       styleMask: .borderless,
                                       backing: .buffered,
                                       defer: false)
            window.setFrame(shot.screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.acceptsMouseMovedEvents = true
            window.ignoresMouseEvents = false

            let view = OverlayView(shot: shot)
            view.onFinish = { [weak self] v, action in self?.finish(v, action) }
            view.onCancel = { [weak self] _ in self?.cancel() }
            view.onBeganDragging = { [weak self] v in self?.isolate(v) }
            view.onOCR = { [weak self] img in self?.runOCR(img) }
            window.contentView = view

            windows.append(window)
            views.append(view)
            window.orderFrontRegardless()
        }

        if fullScreen {
            let target = views.first { $0.shot.screen.frame.contains(mouse) } ?? views.first
            target?.startWithFullSelection()
            return
        }

        // 让鼠标所在屏的窗口拿到键盘焦点
        let target = views.first { $0.shot.screen.frame.contains(mouse) } ?? views.first
        target?.window?.makeKey()
        target?.window?.makeFirstResponder(target)
    }

    /// 某屏开始拖选后，其余屏的遮罩淡出
    private func isolate(_ active: OverlayView) {
        for (i, v) in views.enumerated() where v !== active {
            windows[i].orderOut(nil)
        }
    }

    private func finish(_ view: OverlayView, _ action: FinishAction) {
        if action == .scroll {
            guard let region = view.globalRegion() else {
                cancel()
                return
            }
            closeAll()
            runScrollCapture(region: region)
            return
        }

        guard let image = view.resultImage() else {
            cancel()
            return
        }
        let scale = view.shot.scale
        closeAll()

        switch action {
        case .copy:
            copyToPasteboard(image)
        case .save:
            saveToDisk(image)
        case .pin:
            PinController.shared.show(image: image, scale: scale)
        case .scroll:
            break
        }
    }

    // MARK: - 滚动截图

    private func runScrollCapture(region: CGRect) {
        // 关掉遮罩和工具栏（不然挡住要滚的内容），只留一个边框取景框
        closeAll()
        showScrollFrame(region: region)
        let cap = ScrollCapture(config: ScrollCapture.Config(region: region))
        scrollCapture = cap
        // 抓帧瞬间把取景框藏掉（alpha=0 的窗口不参与合成，抓不到），抓完立刻恢复
        cap.beforeGrab = { [weak self] in self?.scrollFrame?.alphaValue = 0 }
        cap.afterGrab = { [weak self] in self?.scrollFrame?.alphaValue = 1 }
        showScrollHUD(near: region, text: "请滚动要截取的内容 · 停住约 2 秒自动完成")

        cap.onProgress = { [weak self] frames, px in
            DispatchQueue.main.async {
                self?.scrollLabel?.stringValue = "滚动截图 · 第 \(frames) 屏 · 已拼 \(px)px"
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var image: CGImage?
            var note = ""
            do {
                image = try cap.runManual()
            } catch ScrollError.noScroll {
                note = "没检测到滚动：滚动一下内容，停住 2 秒就自动完成"
            } catch ScrollError.cancelled {
                note = "已取消滚动截图"
            } catch {
                note = "滚动截图失败"
            }
            DispatchQueue.main.async {
                self?.closeScrollHUD()
                self?.closeScrollFrame()
                if let img = image {
                    self?.deliverScroll(img)
                } else if !note.isEmpty {
                    self?.flashStatus(note)
                }
            }
        }
    }

    /// 自检用：程序化框选一块区域并直接进入滚动截图
    func debugScrollSelftest() {
        guard let v = views.first else { print("SELFTEST no-view"); return }
        v.selection = CGRect(x: 400, y: 300, width: 900, height: 500)
        v.needsDisplay = true
        print("SELFTEST selection=\(v.selection) global=\(String(describing: v.globalRegion()))")
        finish(v, .scroll)
    }

    /// 自检用：在屏幕中部弹一次滚动截图的控制条
    func debugScrollHUD() {
        guard let sf = NSScreen.main?.frame else { return }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let region = CGRect(x: sf.midX - 300, y: primaryH - (primaryH - sf.midY) - 200,
                            width: 600, height: 400)
        showScrollHUD(near: region, text: "请滚动要截取的内容 · 停住 2 秒自动完成")
    }

    private func showScrollHUD(near region: CGRect, text: String) {
        let w: CGFloat = 400, h: CGFloat = 36
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        // region 是左上原点全局坐标，先换回 AppKit 全局坐标（左下原点）
        let appRect = NSRect(x: region.minX, y: primaryH - region.maxY,
                             width: region.width, height: region.height)
        // 按「选区落在哪块屏」算边界。以前一律用主屏高度做 clamp，
        // 在扩展屏上截屏时会被夹到主屏顶部去。
        let screen = NSScreen.screens.first { $0.frame.intersects(appRect) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.frame
        var y = appRect.minY - h - 22          // 优先放选区下方
        if y < sf.minY + 8 { y = appRect.maxY + 22 }   // 下方不够就放上方
        if y + h > sf.maxY - 8 { y = sf.maxY - h - 8 }
        if y < sf.minY + 8 { y = sf.minY + 8 }
        var x = appRect.midX - w / 2
        x = min(max(x, sf.minX + 8), sf.maxX - w - 8)
        let win = NSWindow(contentRect: NSRect(x: x, y: y, width: w, height: h),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.9).cgColor
        box.layer?.cornerRadius = h / 2

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 14, y: 10, width: w - 14 - 74, height: 16)
        box.addSubview(label)

        // 完成 / 取消：手动模式下没有任何键盘焦点，必须给可点的出口
        let done = IconButton(symbol: "checkmark", tooltip: "完成并保存")
        done.frame = NSRect(x: w - 68, y: (h - 26) / 2, width: 26, height: 26)
        done.action = { [weak self] in
            self?.scrollLabel?.stringValue = "正在生成长图…"
            self?.scrollCapture?.finish()
        }
        box.addSubview(done)

        let cancel = IconButton(symbol: "xmark", tooltip: "放弃这次截图")
        cancel.frame = NSRect(x: w - 38, y: (h - 26) / 2, width: 26, height: 26)
        cancel.action = { [weak self] in self?.scrollCapture?.cancel() }
        box.addSubview(cancel)

        win.contentView = box
        win.orderFrontRegardless()

        scrollHUD = win
        scrollLabel = label
        dbg("hud frame=\(win.frame) visible=\(win.isVisible) num=\(win.windowNumber)")
    }

    /// 屏幕中央的短提示（2.6 秒），比只闪菜单栏图标显眼
    private func showToast(_ text: String, seconds: Double = 2.6) {
        toastWindow?.orderOut(nil)
        let w: CGFloat = min(560, max(260, CGFloat(text.count) * 8 + 40)), h: CGFloat = 38
        guard let screen = NSScreen.main else { return }
        let sf = screen.frame
        let win = NSWindow(contentRect: NSRect(x: sf.midX - w / 2, y: sf.midY - h / 2, width: w, height: h),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        box.layer?.cornerRadius = 10
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 14, y: 11, width: w - 28, height: 17)
        box.addSubview(label)
        win.contentView = box
        win.orderFrontRegardless()
        toastWindow = win
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.toastWindow?.orderOut(nil)
            self?.toastWindow = nil
        }
    }

    /// 滚动截图时保留的取景框：只有边框，鼠标穿透，让用户看清滚进来的是什么
    private func dbg(_ msg: String) {
        let line = "[\(Date())] " + msg + "\n"
        let path = "/tmp/moshot-scroll.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 自检用：屏幕中部显示一次取景框
    func debugScrollFrame() {
        guard let sf = NSScreen.main?.frame else { return }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let region = CGRect(x: sf.midX - 320, y: primaryH - (primaryH - sf.midY) - 180,
                            width: 640, height: 360)
        showScrollFrame(region: region)
    }

    private func showScrollFrame(region: CGRect) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: region.minX, y: primaryH - region.maxY,
                          width: region.width, height: region.height)
        let win = NSWindow(contentRect: rect, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let fv = ScrollFrameView(frame: NSRect(x: 0, y: 0, width: rect.width, height: rect.height))
        win.contentView = fv
        win.orderFrontRegardless()
        scrollFrame = win
        dbg("frame region=\(region) rect=\(rect) screens=\(NSScreen.screens.count) primaryH=\(primaryH) win=\(win.frame) visible=\(win.isVisible) num=\(win.windowNumber)")
    }

    private func closeScrollFrame() {
        scrollFrame?.orderOut(nil)
        scrollFrame?.contentView = nil
        scrollFrame = nil
    }

    private func closeScrollHUD() {
        scrollHUD?.orderOut(nil)
        scrollHUD = nil
        scrollLabel = nil
    }

    private func deliverScroll(_ image: CGImage) {
        guard let data = ImageUtil.pngData(image) else {
            flashStatus("长截图编码失败")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)

        var savedName = ""
        let dir = Prefs.saveDirectory
        var url = dir.appendingPathComponent(Prefs.suggestedFilename())
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-\(n).png")
            n += 1
        }
        if (try? data.write(to: url)) != nil {
            lastSavedPath = url.path
            savedName = url.lastPathComponent
        }
        let msg = savedName.isEmpty
            ? "长截图已复制 · \(image.width)×\(image.height)"
            : "长截图已复制并保存 · \(image.width)×\(image.height) · \(savedName)"
        flashStatus(msg)
        showToast(msg)
    }

    func cancel() {
        closeAll()
    }

    private func closeAll() {
        for v in views { v.commitPendingText() }
        for w in windows {
            w.orderOut(nil)
            w.contentView = nil
        }
        windows.removeAll()
        views.removeAll()
        isActive = false
    }

    // MARK: - 动作

    func copyToPasteboard(_ image: CGImage) {
        guard let data = ImageUtil.pngData(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        flashStatus("已复制到剪贴板")
    }

    @discardableResult
    func saveToDisk(_ image: CGImage) -> URL? {
        guard let data = ImageUtil.pngData(image) else { return nil }
        let dir = Prefs.saveDirectory
        var url = dir.appendingPathComponent(Prefs.suggestedFilename())
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-\(n).png")
            n += 1
        }
        do {
            try data.write(to: url)
            lastSavedPath = url.path
            flashStatus("已保存 \(url.lastPathComponent)")
            return url
        } catch {
            NSLog("MoShot: save failed \(error)")
            return nil
        }
    }

    // MARK: - OCR

    private func runOCR(_ image: CGImage) {
        let rect = views.first?.selection ?? .zero
        let screenFrame = views.first?.shot.screen.frame ?? .zero
        closeAll()
        showOCRSpinner(in: screenFrame)

        OCRService.recognize(image) { [weak self] text in
            guard let self = self else { return }
            self.hideOCRSpinner()
            if text.isEmpty {
                self.flashStatus("未识别到文字")
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.showOCRPanel(text, image: image, selection: rect, screenFrame: screenFrame)
        }
    }

    // MARK: - OCR 进度浮窗

    private var ocrSpinner: NSWindow?

    private func showOCRSpinner(in screenFrame: CGRect) {
        let size = NSSize(width: 200, height: 60)
        let panel = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let bg = NSView(frame: CGRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.95).cgColor
        bg.layer?.cornerRadius = 10

        let spin = NSProgressIndicator(frame: CGRect(x: 18, y: 20, width: 18, height: 18))
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        bg.addSubview(spin)

        let label = NSTextField(labelWithString: "正在识别文字…")
        label.frame = CGRect(x: 46, y: 20, width: 140, height: 20)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .white
        bg.addSubview(label)

        panel.contentView = bg
        let sf = screenFrame.width > 0 ? screenFrame : (NSScreen.main?.frame ?? .zero)
        panel.setFrameOrigin(CGPoint(x: sf.midX - size.width / 2, y: sf.midY - size.height / 2))
        panel.orderFrontRegardless()
        ocrSpinner = panel
    }

    private func hideOCRSpinner() {
        ocrSpinner?.orderOut(nil)
        ocrSpinner = nil
    }

    private func showOCRPanel(_ text: String, image: CGImage, selection: CGRect, screenFrame: CGRect) {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 460, height: 340),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "识别结果（已复制）"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 460, height: 340))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.string = text
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.isEditable = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = tv
        panel.contentView = scroll

        var origin = CGPoint(x: screenFrame.midX - 230, y: screenFrame.midY - 170)
        if selection.width > 0 {
            origin = CGPoint(x: screenFrame.minX + selection.maxX - 460,
                             y: screenFrame.maxY - selection.minY + 10)
        }
        origin.x = max(screenFrame.minX + 8, min(origin.x, screenFrame.maxX - 468))
        origin.y = max(screenFrame.minY + 8, min(origin.y, screenFrame.maxY - 348))
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
        ocrWindow = panel
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 提示

    /// 盯着权限：用户在设置里勾上之后，立刻自己重启一次，不用人手动退开再打开
    private func watchPermissionAndRelaunch() {
        // 已经有权限就别盯（那是抓屏失败的另一种情况，重启没用）
        guard !ScreenCapture.hasPermission else { return }
        // 防重启风暴：5 分钟内最多自动重启 2 次，超出就让人手动处理
        let now = Date().timeIntervalSince1970
        var count = UserDefaults.standard.integer(forKey: "relaunchCount")
        let last = UserDefaults.standard.double(forKey: "relaunchAt")
        if now - last > 300 { count = 0 }
        guard count < 2 else {
            showToast("权限仍未生效，请手动退出后重新打开 MoShot", seconds: 5)
            return
        }
        permissionWatch?.invalidate()
        let deadline = Date().addingTimeInterval(180)   // 最多盯 3 分钟
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if ScreenCapture.hasPermission {
                t.invalidate()
                self.permissionWatch = nil
                // 不自动退出：之前那版自动 open -n + terminate 把进程搞没了，
                // 热键跟着失灵且用户不知道发生了什么。改成一句话指引，重启由人点一次。
                self.showToast("权限已生效 · 重按 ⌥⇧A 即可截图（仍无画面再重启）", seconds: 5)
            } else if Date() > deadline {
                t.invalidate()
                self.permissionWatch = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionWatch = timer
    }

    /// 授权兜底：一条不打断操作的提示 + 自动打开设置页，替代原来的模态面板
    private func permissionFallback() {
        showToast("需要屏幕录制权限 · 勾选后自动继续，仍无画面请点菜单栏「重新启动 MoShot」", seconds: 6)
        watchPermissionAndRelaunch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = """
        打开 系统设置 › 隐私与安全性 › 屏幕录制，勾选 MoShot，然后**退出并重新打开** MoShot —— 屏幕录制授权只对新启动的进程生效。

        这次勾选之后，后续升级 MoShot 不需要再授权（已用固定签名身份绑定）。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            // 先清掉失效条目：ad-hoc 签名重建后 TCC 里留着旧 cdhash 的记录，
            // 不清掉的话系统设置里显示已勾选但实际不生效，勾选也不会重写。
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "com.moxian.moshot"]
            try? p.run()
            p.waitUntilExit()
            _ = ScreenCapture.requestPermission()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func flashStatus(_ text: String) {
        StatusBar.shared?.showTransient(text)
    }
}

// MARK: - OCR

enum OCRService {
    static func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                DispatchQueue.main.async { completion(lines.joined(separator: "\n")) }
            } catch {
                NSLog("MoShot: OCR failed \(error)")
                DispatchQueue.main.async { completion("") }
            }
        }
    }
}


/// 滚动截图的取景框：双色描边 + 四角标记，背景全透明，鼠标事件穿透到下面的 app
final class ScrollFrameView: NSView {
    private let accent = NSColor(calibratedRed: 0.33, green: 0.72, blue: 1.0, alpha: 1.0)

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        guard b.width > 4, b.height > 4 else { return }

        // 底衬：深色一圈，保证在浅色内容上也看得见
        NSColor(white: 0, alpha: 0.45).setStroke()
        let underlay = NSBezierPath(rect: b.insetBy(dx: 1.5, dy: 1.5))
        underlay.lineWidth = 3
        underlay.stroke()

        // 主色边
        accent.setStroke()
        let edge = NSBezierPath(rect: b.insetBy(dx: 1.5, dy: 1.5))
        edge.lineWidth = 1.5
        edge.stroke()

        // 四角加粗标记
        let len: CGFloat = min(20, min(b.width, b.height) / 4)
        let w: CGFloat = 3
        let inset: CGFloat = 0.75
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: b.minX + inset, y: b.minY + inset),
             CGPoint(x: b.minX + inset + len, y: b.minY + inset),
             CGPoint(x: b.minX + inset, y: b.minY + inset + len)),
            (CGPoint(x: b.maxX - inset, y: b.minY + inset),
             CGPoint(x: b.maxX - inset - len, y: b.minY + inset),
             CGPoint(x: b.maxX - inset, y: b.minY + inset + len)),
            (CGPoint(x: b.minX + inset, y: b.maxY - inset),
             CGPoint(x: b.minX + inset + len, y: b.maxY - inset),
             CGPoint(x: b.minX + inset, y: b.maxY - inset - len)),
            (CGPoint(x: b.maxX - inset, y: b.maxY - inset),
             CGPoint(x: b.maxX - inset - len, y: b.maxY - inset),
             CGPoint(x: b.maxX - inset, y: b.maxY - inset - len))
        ]
        for (origin, hEnd, vEnd) in corners {
            let path = NSBezierPath()
            path.move(to: hEnd)
            path.line(to: origin)
            path.line(to: vEnd)
            path.lineWidth = w
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}
