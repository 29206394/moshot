import Cocoa
import ScreenCaptureKit

struct ScreenShot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    let scale: CGFloat
}

enum ScreenCapture {

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// 抓取全部屏幕。优先 ScreenCaptureKit，失败回退系统 screencapture。
    static func captureAll() async -> [ScreenShot] {
        if hasPermission {
            do {
                let shots = try await captureWithSCK()
                if !shots.isEmpty { return shots }
            } catch {
                NSLog("MoShot: SCK capture failed: \(error)")
            }
        }
        // 回退：系统 screencapture CLI（在 SCK 不可用时仍能工作）
        var out: [ScreenShot] = []
        for screen in NSScreen.screens {
            if let shot = captureWithCLI(screen) { out.append(shot) }
        }
        return out
    }

    static func captureWithSCK() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [ScreenShot] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }) else { continue }
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
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: tmp),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return ScreenShot(screen: screen, displayID: id, image: img, scale: screen.backingScaleFactor)
    }
}
