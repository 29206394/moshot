import Cocoa
import Carbon.HIToolbox

final class StatusBar {
    static var shared: StatusBar?

    let item: NSStatusItem
    private var resetTimer: Timer?
    private var hotKeyLabel: String = "⌥⇧A"

    init() {
        if let (code, mods) = HotKey.parse(HotKey.defaultSpec()) {
            hotKeyLabel = HotKey.describe(keyCode: code, modifiers: mods)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "MoShot")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "MoShot — 截图 \(hotKeyLabel)"
        }
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        let shot = NSMenuItem(title: "区域截图  \(hotKeyLabel)", action: #selector(shotRegion), keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)

        let full = NSMenuItem(title: "全屏截图", action: #selector(shotFull), keyEquivalent: "")
        full.target = self
        menu.addItem(full)

        menu.addItem(.separator())

        let folder = NSMenuItem(title: "打开截图文件夹", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        let restart = NSMenuItem(title: "重新启动 MoShot", action: #selector(restartApp), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 MoShot", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func shotRegion() { OverlayController.shared.begin(fullScreen: false) }
    @objc private func shotFull() { OverlayController.shared.begin(fullScreen: true) }
    @objc private func restartApp() {
        // 交给 launchd 起新实例：直接 Process 起的子 shell 会随 NSApp.terminate
        // 一起被杀（sleep 还没结束就被带走），新实例根本起不来，app 就凭空消失了。
        let label = "com.moxian.moshot.relaunch.\(Int(Date().timeIntervalSince1970))"
        let cmd = "sleep 1.2; /usr/bin/open -n \"\(Bundle.main.bundlePath)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["submit", "-l", label, "--", "/bin/sh", "-c", cmd]
        try? p.run()
        p.waitUntilExit()
        NSApp.terminate(nil)
    }

    @objc private func openFolder() { NSWorkspace.shared.open(Prefs.saveDirectory) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MoShot \(MoShotVersion)"
        alert.informativeText = "轻量 macOS 截图标注工具\n\(hotKeyLabel) 截图 · Enter 复制 · ⌘S 保存 · P 贴图"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func showTransient(_ text: String) {
        guard let button = item.button else { return }
        resetTimer?.invalidate()
        button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: text)
        button.image?.isTemplate = true
        button.toolTip = text
        resetTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            guard let self = self, let b = self.item.button else { return }
            b.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "MoShot")
            b.image?.isTemplate = true
            b.toolTip = "MoShot — 截图 \(self.hotKeyLabel)"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 真机排障：记录 app 自己启动时看到的权限（终端跑 --diagnose 会继承终端权限）
        let boot = "launch: hasPermission=\(ScreenCapture.hasPermission) pid=\(ProcessInfo.processInfo.processIdentifier)\n"
        try? boot.write(toFile: "/tmp/moshot-perm.log", atomically: true, encoding: .utf8)

        StatusBar.shared = StatusBar()
        let spec = HotKey.defaultSpec()
        let parsed = HotKey.parse(spec) ?? (UInt32(kVK_ANSI_A), UInt32(optionKey | shiftKey))
        hotKey = HotKey(keyCode: parsed.0, modifiers: parsed.1) {
            OverlayController.shared.begin(fullScreen: false)
        }
        NSLog("MoShot: ready (version \(MoShotVersion)), statusItem=\(StatusBar.shared != nil)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSLog("MoShot: statusItem visible=\(StatusBar.shared?.item.button != nil)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
