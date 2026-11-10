import Cocoa
import ScreenCaptureKit

struct ScreenShot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    let scale: CGFloat
}

/// 屏幕录制授权取证日志：/tmp/moshot-perm.log
/// 每次启动、每次请求授权、每次抓屏失败都记一行，便于对端判断是 TCC 没匹配上、
/// ScreenCaptureKit 被拒，还是 screencapture CLI 自己失败。
enum PermLog {
    static let path = "/tmp/moshot-perm.log"

    static func write(_ text: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] pid=\(ProcessInfo.processInfo.processIdentifier) \(text)\n"
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        }
        NSLog("MoShot perm: %@", text)
    }
}

enum ScreenCapture {

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        PermLog.write("requestPermission: returned=\(granted) preflight=\(hasPermission)")
        return granted
    }

    /// 抓取全部屏幕。优先 ScreenCaptureKit，失败回退系统 screencapture。
    static func captureAll() async -> [ScreenShot] {
        let pre = hasPermission
        PermLog.write("captureAll: start preflight=\(pre) screens=\(NSScreen.screens.count)")

        if pre {
            do {
                let shots = try await captureWithSCK()
                PermLog.write("captureAll: SCK ok shots=\(shots.count)")
                if !shots.isEmpty { return shots }
            } catch {
                let ns = error as NSError
                PermLog.write("captureAll: SCK failed domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
            }
        } else {
            PermLog.write("captureAll: skip SCK (preflight=false)")
        }

        // 回退：系统 screencapture CLI（在 SCK 不可用时仍能工作）
        var out: [ScreenShot] = []
        for screen in NSScreen.screens {
            if let shot = captureWithCLI(screen) { out.append(shot) }
        }
        PermLog.write("captureAll: CLI fallback shots=\(out.count) preflight=\(hasPermission)")
        return out
    }

    static func captureWithSCK() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let screenIDs = NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
        PermLog.write("sck: displays=\(content.displays.count) ids=\(content.displays.map { $0.displayID }) screens=\(screenIDs)")
        var result: [ScreenShot] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }) else {
                PermLog.write("sck: no NSScreen matched display \(display.displayID)")
                continue
            }
            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = Int((screen.frame.width * scale).rounded())
            cfg.height = Int((screen.frame.height * scale).rounded())
            cfg.showsCursor = false
            cfg.captureResolution = .best
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            result.append(ScreenShot(screen: screen, displayID: display.displayID, image: img, scale: scale))
        }
        return result
    }

    static func captureWithCLI(_ screen: NSScreen) -> ScreenShot? {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("moshot-\(UUID().uuidString).png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-D", "\(id)", "-t", "png", tmp.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            PermLog.write("cli: display=\(id) launch failed error=\(error.localizedDescription)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let size = (try? Data(contentsOf: tmp).count) ?? -1
        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: tmp),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            PermLog.write("cli: display=\(id) exit=\(proc.terminationStatus) bytes=\(size) preflight=\(hasPermission)")
            return nil
        }
        PermLog.write("cli: display=\(id) exit=0 bytes=\(size) preflight=\(hasPermission)")
        return ScreenShot(screen: screen, displayID: id, image: img, scale: screen.backingScaleFactor)
    }
}
