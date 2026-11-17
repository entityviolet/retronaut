import Foundation

/// User settings. Stored in UserDefaults so SwiftUI (@AppStorage) and the emulator
/// layer read the very same values.
enum Prefs {
    enum Key {
        static let overlayEnabled = "overlayEnabled"        // Bool
        static let overlayCorner = "overlayCorner"          // "tl" | "tr" | "bl" | "br"
        static let padEnabled = "padEnabled"                // Bool
        static let padStickMouse = "padStickMouse"          // Bool
        static let padLayout = "padLayout"                  // "classic" | "action" | "menu"
        static let mouseSpeed = "mouseSpeed"                // Double
        static let swapButtons = "swapMouseButtons"         // Bool
        static let scrollWheel = "scrollWheelEnabled"       // Bool
        static let lockPointer = "lockPointer"              // Bool
        static let cmdFKeys = "cmdFKeys"              // Bool
        static let keyboardLayout = "keyboardLayout"        // DOSBox Pure layout id
        static let escShortcut = "escShortcut"              // Bool: ⌘ + . = Esc
        static let tildeEsc = "tildeEsc"                    // Bool: ` / ~ key = Esc
        static let touchMode = "touchMode"                  // "direct" | "pad"
        static let pointerInput = "pointerInput"            // "both" | "touch" | "mouse"
        static let keyboardButton = "keyboardButton"        // Bool: on-screen button that opens the iOS keyboard
    }

    static let defaults: [String: Any] = [
        Key.overlayEnabled: true,
        Key.overlayCorner: "tr",
        Key.padEnabled: true,
        Key.padStickMouse: true,
        Key.padLayout: "classic",
        Key.mouseSpeed: 1.5,
        Key.swapButtons: false,
        Key.scrollWheel: true,
        Key.lockPointer: true,
        Key.cmdFKeys: true,
        Key.keyboardLayout: "us",
        Key.escShortcut: true,
        Key.tildeEsc: false,
        Key.touchMode: "direct",
        Key.pointerInput: "both",
        Key.keyboardButton: true,
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    static func reset() {
        for k in defaults.keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    private static var d: UserDefaults { UserDefaults.standard }

    static var overlayEnabled: Bool { register(); return d.bool(forKey: Key.overlayEnabled) }
    static var overlayCorner: String { register(); return d.string(forKey: Key.overlayCorner) ?? "tr" }
    static var padEnabled: Bool { register(); return d.bool(forKey: Key.padEnabled) }
    static var padStickMouse: Bool { register(); return d.bool(forKey: Key.padStickMouse) }
    static var padLayout: String { register(); return d.string(forKey: Key.padLayout) ?? "classic" }
    static var mouseSpeed: Double { register(); return max(0.2, d.double(forKey: Key.mouseSpeed)) }
    static var swapButtons: Bool { register(); return d.bool(forKey: Key.swapButtons) }
    static var scrollWheel: Bool { register(); return d.bool(forKey: Key.scrollWheel) }
    static var lockPointer: Bool { register(); return d.bool(forKey: Key.lockPointer) }
    static var cmdFKeys: Bool { register(); return d.bool(forKey: Key.cmdFKeys) }
    static var keyboardLayout: String { register(); return d.string(forKey: Key.keyboardLayout) ?? "us" }
    static var escShortcut: Bool { register(); return d.bool(forKey: Key.escShortcut) }
    static var tildeEsc: Bool { register(); return d.bool(forKey: Key.tildeEsc) }
    static var pointerInput: String { register(); return d.string(forKey: Key.pointerInput) ?? "both" }
    static var keyboardButton: Bool { register(); return d.bool(forKey: Key.keyboardButton) }
    static var touchEnabled: Bool { pointerInput != "mouse" }
    static var mouseEnabled: Bool { pointerInput != "touch" }
    static var touchMode: String {
        register()
        let m = d.string(forKey: Key.touchMode) ?? "direct"
        return m == "pad" ? "pad" : "direct"
    }

    /// DOSBox Pure keyboard layouts (id, display name).
    static let layouts: [KeyboardLayout] = [
        KeyboardLayout(id: "us", name: "US (default)"), KeyboardLayout(id: "uk", name: "UK"), KeyboardLayout(id: "gk", name: "Greece"), KeyboardLayout(id: "gr", name: "Germany"),
        KeyboardLayout(id: "fr", name: "France"), KeyboardLayout(id: "it", name: "Italy"), KeyboardLayout(id: "sp", name: "Spain"), KeyboardLayout(id: "po", name: "Portugal"),
        KeyboardLayout(id: "be", name: "Belgium"), KeyboardLayout(id: "br", name: "Brazil"), KeyboardLayout(id: "hr", name: "Croatia"), KeyboardLayout(id: "cz243", name: "Czech Republic"),
        KeyboardLayout(id: "dk", name: "Denmark"), KeyboardLayout(id: "su", name: "Finland"), KeyboardLayout(id: "hu", name: "Hungary"), KeyboardLayout(id: "is161", name: "Iceland"),
        KeyboardLayout(id: "nl", name: "Netherlands"), KeyboardLayout(id: "no", name: "Norway"), KeyboardLayout(id: "pl", name: "Poland"), KeyboardLayout(id: "ru", name: "Russia"),
        KeyboardLayout(id: "sk", name: "Slovakia"), KeyboardLayout(id: "si", name: "Slovenia"), KeyboardLayout(id: "sv", name: "Sweden"),
        KeyboardLayout(id: "sg", name: "Switzerland (German)"), KeyboardLayout(id: "sf", name: "Switzerland (French)"), KeyboardLayout(id: "tr", name: "Turkey"),
    ]
}

struct KeyboardLayout: Identifiable {
    let id: String
    let name: String
}
