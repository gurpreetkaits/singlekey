import CoreGraphics
import Foundation

struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64

    static let relevantModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// ⌃⌥⌘Space
    static let `default` = Hotkey(
        keyCode: 49,
        modifiers: CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
    )

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode && flags.intersection(Self.relevantModifiers).rawValue == modifiers
    }

    var displayString: String {
        let flags = CGEventFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    // ANSI layout virtual key codes.
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 118: "F4",
        120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var hotkey: Hotkey {
        get {
            guard let data = defaults.data(forKey: "hotkey"),
                  let hk = try? JSONDecoder().decode(Hotkey.self, from: data) else { return .default }
            return hk
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "hotkey") }
    }

    static var pairingCode: String {
        get { defaults.string(forKey: "pairingCode") ?? "" }
        set { defaults.set(newValue, forKey: "pairingCode") }
    }

    /// Whether the mouse follows the keyboard to the other Mac. Off: keyboard only.
    static var forwardMouse: Bool {
        get { defaults.bool(forKey: "forwardMouse") }
        set { defaults.set(newValue, forKey: "forwardMouse") }
    }

    /// Stable random identifier for this Mac; also used as its Bonjour service name.
    static var instanceID: String {
        if let env = ProcessInfo.processInfo.environment["SINGLEKEY_ID"] { return env }
        if let id = defaults.string(forKey: "instanceID") { return id }
        let id = String(UUID().uuidString.prefix(12))
        defaults.set(id, forKey: "instanceID")
        return id
    }
}
