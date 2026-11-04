import Cocoa
import Vision

final class OverlayController {

    static let shared = OverlayController()

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var ocrWindow: NSWindow?
    private(set) var isActive = false

    var lastSavedPath: String?

    func begin(fullScreen: Bool = false) {
        guard !isActive else { return }
        isActive = true
        NSApp.activate(ignoringOtherApps: true)

        // 首次使用：触发系统授权（用户同意后当前进程即可抓屏，通常无需重启）
        if !ScreenCapture.hasPermission {
            let granted = ScreenCapture.requestPermission()
            if !granted {
                isActive = false
                showPermissionAlert()
                return
            }
        }

        Task.detached {
            let shots = await ScreenCapture.captureAll()
            DispatchQueue.main.async {
                if shots.isEmpty {
                    self.isActive = false
                    self.showPermissionAlert()
                    return
                }
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
        }
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

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "在 系统设置 › 隐私与安全性 › 屏幕录制 中勾选 MoShot，然后重新发起截图。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
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
