import AppKit
import Foundation

/// Configurable keyboard actions. The order in `allCases` drives the order in
/// the Preferences table.
enum KeyboardAction: String, CaseIterable, Codable, Sendable {
    case playPause
    case stop
    case goToStart
    case seekBack2_5
    case seekForward2_5
    case seekBack5
    case seekForward5
    case seekBack10
    case seekForward10
    case seekBack30
    case seekForward30
    case addBookmark
    case nextBookmark
    case previousBookmark
    case lastBookmark
    case firstBookmark

    var displayName: String {
        switch self {
        case .playPause:        return "Play / Pause"
        case .stop:             return "Stop"
        case .goToStart:        return "Go to Start"
        case .seekBack2_5:      return "Skip Back 2.5 s"
        case .seekForward2_5:   return "Skip Forward 2.5 s"
        case .seekBack5:        return "Skip Back 5 s"
        case .seekForward5:     return "Skip Forward 5 s"
        case .seekBack10:       return "Skip Back 10 s"
        case .seekForward10:    return "Skip Forward 10 s"
        case .seekBack30:       return "Skip Back 30 s"
        case .seekForward30:    return "Skip Forward 30 s"
        case .addBookmark:      return "Add Bookmark"
        case .nextBookmark:     return "Next Bookmark"
        case .previousBookmark: return "Previous Bookmark"
        case .lastBookmark:     return "Last Bookmark"
        case .firstBookmark:    return "First Bookmark"
        }
    }
}

/// A platform-stable shortcut: virtual key code plus the relevant modifier
/// mask. We mask down to {Cmd, Option, Control, Shift} so things like
/// caps-lock or the device-independent flag bits don't confuse matching.
struct KeyShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// Stored as raw value so we can keep the struct trivially Codable.
    var modifierFlagsRaw: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifierFlagsRaw = modifiers.rawValue
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
    }

    var displayString: String {
        var s = ""
        let m = modifiers
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        s += Self.keySymbol(for: keyCode)
        return s
    }

    static func keySymbol(for code: UInt16) -> String {
        switch code {
        case 49:  return "Space"
        case 48:  return "⇥"
        case 36:  return "↩"
        case 53:  return "⎋"
        case 51:  return "⌫"
        case 47:  return "."
        case 43:  return ","
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 0:   return "A"
        case 1:   return "S"
        case 2:   return "D"
        case 3:   return "F"
        case 4:   return "H"
        case 5:   return "G"
        case 6:   return "Z"
        case 7:   return "X"
        case 8:   return "C"
        case 9:   return "V"
        case 11:  return "B"
        case 12:  return "Q"
        case 13:  return "W"
        case 14:  return "E"
        case 15:  return "R"
        case 16:  return "Y"
        case 17:  return "T"
        case 31:  return "O"
        case 32:  return "U"
        case 34:  return "I"
        case 35:  return "P"
        case 37:  return "L"
        case 38:  return "J"
        case 40:  return "K"
        case 45:  return "N"
        case 46:  return "M"
        case 18:  return "1"
        case 19:  return "2"
        case 20:  return "3"
        case 21:  return "4"
        case 22:  return "6"
        case 23:  return "5"
        case 25:  return "9"
        case 26:  return "7"
        case 28:  return "8"
        case 29:  return "0"
        default:  return "key \(code)"
        }
    }
}

extension Notification.Name {
    static let keyBindingsChanged = Notification.Name("AudioLensKeyBindingsChanged")
}

@MainActor
final class KeyBindings {
    static let shared = KeyBindings()

    private let storageKey = "AudioLens.KeyBindings.v1"
    private var bindings: [KeyboardAction: KeyShortcut]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let raw = try? JSONDecoder().decode([String: KeyShortcut].self, from: data) {
            var m: [KeyboardAction: KeyShortcut] = [:]
            for (k, v) in raw {
                if let action = KeyboardAction(rawValue: k) { m[action] = v }
            }
            bindings = m
        } else {
            bindings = [:]
        }
    }

    func shortcut(for action: KeyboardAction) -> KeyShortcut {
        bindings[action] ?? Self.defaultShortcut(for: action)
    }

    func setShortcut(_ shortcut: KeyShortcut, for action: KeyboardAction) {
        bindings[action] = shortcut
        save()
        NotificationCenter.default.post(name: .keyBindingsChanged, object: nil)
    }

    func restoreDefaults() {
        bindings = [:]
        UserDefaults.standard.removeObject(forKey: storageKey)
        NotificationCenter.default.post(name: .keyBindingsChanged, object: nil)
    }

    func action(for event: NSEvent) -> KeyboardAction? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        for action in KeyboardAction.allCases {
            let s = shortcut(for: action)
            if s.keyCode == event.keyCode && s.modifiers == mods {
                return action
            }
        }
        return nil
    }

    private func save() {
        var raw: [String: KeyShortcut] = [:]
        for (k, v) in bindings { raw[k.rawValue] = v }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Per-action defaults. The arrow-key modifiers use Option/Cmd/Option+Cmd
    /// (Control is reserved by macOS for Mission Control / Spaces).
    static func defaultShortcut(for action: KeyboardAction) -> KeyShortcut {
        switch action {
        case .playPause:        return KeyShortcut(keyCode: 49)                          // Space
        case .stop:             return KeyShortcut(keyCode: 47)                          // .
        case .goToStart:        return KeyShortcut(keyCode: 48)                          // Tab
        case .seekBack2_5:      return KeyShortcut(keyCode: 123)                         // ←
        case .seekForward2_5:   return KeyShortcut(keyCode: 124)                         // →
        case .seekBack5:        return KeyShortcut(keyCode: 123, modifiers: .option)     // ⌥←
        case .seekForward5:     return KeyShortcut(keyCode: 124, modifiers: .option)     // ⌥→
        case .seekBack10:       return KeyShortcut(keyCode: 123, modifiers: .command)    // ⌘←
        case .seekForward10:    return KeyShortcut(keyCode: 124, modifiers: .command)    // ⌘→
        case .seekBack30:       return KeyShortcut(keyCode: 123, modifiers: [.option, .command]) // ⌥⌘←
        case .seekForward30:    return KeyShortcut(keyCode: 124, modifiers: [.option, .command]) // ⌥⌘→
        case .addBookmark:      return KeyShortcut(keyCode: 11, modifiers: .command)        // ⌘B
        case .nextBookmark:     return KeyShortcut(keyCode: 126)                            // ↑
        case .previousBookmark: return KeyShortcut(keyCode: 125)                            // ↓
        case .lastBookmark:     return KeyShortcut(keyCode: 126, modifiers: .option)        // ⌥↑
        case .firstBookmark:    return KeyShortcut(keyCode: 125, modifiers: .option)        // ⌥↓
        }
    }
}
