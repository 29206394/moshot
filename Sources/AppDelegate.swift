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
        if QuitIntent.isLaunchdManaged {
            // 托管态：非 0 退出，launchd 立刻拉回一个新实例（不用再自己 open -n，避免双实例）
            QuitIntent.exitForRelaunch("menu restart")
        }
        // 非托管态（手动双击起的）：直接 Process 起的子 shell 会随 NSApp.terminate
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
    @objc private func quit() {
        // 用户主动退出：写标记，让 applicationShouldTerminate 放行正常退出，
        // launchd 那边 KeepAlive{SuccessfulExit:false} 就不会把图标又拉出来。
        QuitIntent.markUserQuit()
        NSApp.terminate(nil)
    }

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
        PermLog.write("launch: hasPermission=\(ScreenCapture.hasPermission) version=\(MoShotVersion) req=\(selfDesignatedRequirement())")

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

    /// 退出语义分流：
    /// - 菜单「退出」已写 user-quit 标记 → 真退出（exit 0），launchd 不拉起
    /// - 其它任何来路的终止（系统「退出并重新打开」、TCC 刷新、外部 kill 之外的正常 terminate）
    ///   → 以 75 退出，让 KeepAlive{SuccessfulExit:false} 把进程拉回来
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if QuitIntent.consumeUserQuit() {
            PermLog.write("quit: user-initiated, stay down")
            return .terminateNow
        }
        if QuitIntent.isLaunchdManaged {
            QuitIntent.exitForRelaunch("external terminate")
        }
        return .terminateNow
    }
}

/// 退出意图与 launchd 保活的约定：退出码 0 = 用户主动退出（保活不拉起），
/// 非 0 = 程序自己或系统发起的退出（交 launchd 10 秒内拉回）。
enum QuitIntent {
    static let flagPath = NSHomeDirectory() + "/Library/Application Support/MoShot/user-quit.flag"

    /// ppid=1 表示由 launchd 托管；手动双击 / open -a 起的 ppid 不是 1
    static var isLaunchdManaged: Bool { getppid() == 1 }

    static func markUserQuit() {
        let dir = (flagPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: flagPath, contents: Data("user".utf8))
    }

    static func consumeUserQuit() -> Bool {
        guard FileManager.default.fileExists(atPath: flagPath) else { return false }
        try? FileManager.default.removeItem(atPath: flagPath)
        return true
    }

    /// 需要被拉回时用它退出：非 0 状态码是给 launchd 的信号
    static func exitForRelaunch(_ reason: String) -> Never {
        PermLog.write("exit(75) for relaunch: \(reason)")
        exit(75)
    }
}
