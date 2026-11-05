import Cocoa
import ApplicationServices
import Carbon.HIToolbox

let MoShotVersion = "1.1.0"

// MARK: - CLI 入口（无 GUI，便于自动化验证与集成）

func waitUntil(_ flag: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !flag() && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    return flag()
}

private func runCaptureCLI(path: String, displayIndex: Int) -> Int32 {
    var done = false
    var ok = false
    Task.detached {
        let shots = await ScreenCapture.captureAll()
        DispatchQueue.main.async {
            guard shots.indices.contains(displayIndex) else {
                done = true
                return
            }
            if let data = ImageUtil.pngData(shots[displayIndex].image) {
                ok = (try? data.write(to: URL(fileURLWithPath: path))) != nil
            }
            done = true
        }
    }
    _ = waitUntil({ done }, timeout: 25)
    if ok {
        print("saved \(path)")
        return 0
    }
    FileHandle.standardError.write("capture failed\n".data(using: .utf8)!)
    return 2
}

// MARK: - 启动

let args = CommandLine.arguments

if args.contains("--version") {
    print("MoShot \(MoShotVersion)")
    exit(0)
}

_ = NSApplication.shared

if args.contains("--help") || args.contains("-h") {
    print("""
    MoShot \(MoShotVersion) — macOS 截图标注工具

    用法:
      MoShot                     常驻菜单栏，⌘⇧A 截图
      MoShot --capture <path>    直接抓取主屏存 PNG（无 GUI）
      MoShot --selftest          运行内置自检
      MoShot --version           打印版本
    """)
    exit(0)
}

if let i = args.firstIndex(of: "--capture"), i + 1 < args.count {
    exit(runCaptureCLI(path: args[i + 1], displayIndex: 0))
}

if args.contains("--selftest") {
    exit(runSelfTest() ? 0 : 1)
}

// 端到端模拟：真实抓屏 → 中间区域裁剪 → 叠加标注 → 存 PNG（无窗口、无焦点抢占）
if args.contains("--scroll-selftest") {
    OverlayController.shared.begin(fullScreen: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
        OverlayController.shared.debugScrollSelftest()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "/tmp/scroll-selftest.png"]
        try? p.run(); p.waitUntilExit()
        print("shot /tmp/scroll-selftest.png")
        if let log = try? String(contentsOfFile: "/tmp/moshot-scroll.log", encoding: .utf8) {
            print("--- log ---"); print(log)
        } else {
            print("--- no log file ---")
        }
        exit(0)
    }
    NSApplication.shared.run()
}

if args.contains("--frame-demo") {
    let c = OverlayController()
    c.debugScrollFrame()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
        let tmp = "/tmp/moshot-frame.png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", tmp]
        try? p.run(); p.waitUntilExit()
        print("saved \(tmp)")
        exit(0)
    }
    NSApplication.shared.run()
}

if args.contains("--hud-demo") {
    let c = OverlayController()
    c.debugScrollHUD()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    let tmp = "/tmp/moshot-hud.png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", tmp]
    try? p.run(); p.waitUntilExit()
    print("saved \(tmp)")
    exit(0)
}

if let i = args.firstIndex(of: "--tooltip-demo"), i + 1 < args.count {
    let out = args[i + 1]
    let done = DispatchSemaphore(value: 0)
    Task {
        let shots = await ScreenCapture.captureAll()
        guard let shot = shots.first else { print("no screen"); exit(1) }
        let view = OverlayView(shot: shot)
        view.frame = NSRect(origin: .zero, size: shot.screen.frame.size)
        view.startWithFullSelection()
        view.layoutSubtreeIfNeeded()
        view.debugShowTooltip("滚动截图 S")
        view.displayIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: out))
            print("saved \(out)")
        }
        done.signal()
    }
    while done.wait(timeout: .now() + 0.1) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

if let i = args.firstIndex(of: "--simulate"), i + 1 < args.count {
    let out = args[i + 1]
    var done = false
    var status: Int32 = 3
    Task.detached {
        let shots = await ScreenCapture.captureAll()
        DispatchQueue.main.async {
            guard let shot = shots.first else { done = true; return }
            let view = OverlayView(shot: shot)
            let w = min(640, shot.screen.frame.width * 0.6)
            let h = min(420, shot.screen.frame.height * 0.6)
            let region = CGRect(x: (shot.screen.frame.width - w) / 2,
                                y: (shot.screen.frame.height - h) / 2,
                                width: w, height: h)
            if let img = view.simulate(region: region), let data = ImageUtil.pngData(img) {
                try? data.write(to: URL(fileURLWithPath: out))
                print("saved \(out) \(img.width)x\(img.height)")
                status = 0
            }
            done = true
        }
    }
    _ = waitUntil({ done }, timeout: 30)
    exit(status)
}

// 环境诊断：不抓屏、不弹窗，只报告热键/权限/状态栏是否就绪
if args.contains("--diagnose") {
    var lines: [String] = []
    lines.append("version=\(MoShotVersion)")
    lines.append("screens=\(NSScreen.screens.count)")
    for s in NSScreen.screens {
        lines.append("  screen \(Int(s.frame.width))x\(Int(s.frame.height))@\(s.backingScaleFactor)x")
    }
    lines.append("screenPermission=\(ScreenCapture.hasPermission)")
    lines.append("accessibilityTrusted=\(AXIsProcessTrusted())   // 自动滚动截图需要它")
    let hkSpec = HotKey.parse(HotKey.defaultSpec()) ?? (UInt32(kVK_ANSI_A), UInt32(optionKey | shiftKey))
    let hk = HotKey(keyCode: hkSpec.0, modifiers: hkSpec.1) {}
    lines.append("hotkey=\(hk.description) registered=\(hk.isRegistered)")
    let sb = StatusBar()
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3))
    lines.append("statusItem=\(sb.item.button != nil)")
    lines.append("saveDir=\(Prefs.saveDirectory.path)")
    print(lines.joined(separator: "\n"))
    exit(hk.isRegistered && sb.item.button != nil ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// 权限实验：改一行触发重建
