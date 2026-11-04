import Cocoa
import Carbon.HIToolbox

/// 全局热键（Carbon RegisterEventHotKey，无需辅助功能权限）
final class HotKey {

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let callback: () -> Void
    private(set) var isRegistered = false
    private(set) var description: String = ""

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        self.description = HotKey.describe(keyCode: keyCode, modifiers: modifiers)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData = userData, let event = event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let obj = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { obj.callback() }
            return noErr
        }, 1, &eventType, selfPtr, &handler)

        let hkID = EventHotKeyID(signature: OSType(0x534E5050), id: 1) // 'SNPP'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("SnapPin: RegisterEventHotKey failed status=\(status)")
        } else {
            isRegistered = true
            NSLog("SnapPin: hotkey registered \(description)")
        }
    }

    deinit {
        if let ref = ref { UnregisterEventHotKey(ref) }
        if let handler = handler { RemoveEventHandler(handler) }
    }

    // MARK: - 配置解析

    /// 从 "opt+shift+A" / "⌘⇧A" / "cmd shift a" 这类写法解析出 keyCode 与 modifiers
    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: String?
        let parts = spec
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
            .split(separator: " ")
            .map(String.init)
        for p in parts {
            switch p {
            case "cmd", "command", "⌘", "meta": mods |= UInt32(cmdKey)
            case "opt", "option", "alt", "⌥": mods |= UInt32(optionKey)
            case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            default: key = p
            }
        }
        guard let k = key, k.count == 1, let ch = k.uppercased().first else { return nil }
        let map: [Character: Int] = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
            "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
            "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
            "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
            "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
            "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
            "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
        ]
        guard let code = map[ch] else { return nil }
        return (UInt32(code), mods)
    }

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        ]
        return s + (map[Int(keyCode)] ?? "?")
    }

    /// 默认 ⌥⇧A：避开飞书/微信的 ⌘⇧A
    static func defaultSpec() -> String {
        UserDefaults.standard.string(forKey: "hotkey") ?? "opt+shift+A"
    }
}
