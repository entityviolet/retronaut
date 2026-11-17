import UIKit
import GameController

/// Maps hardware (HID) key usages to libretro RETROK_* codes.
///
/// Uses the physical key (HID usage) instead of the typed character, so Shift/Ctrl/Alt
/// combos, punctuation, the numpad and key releases are always matched correctly.
enum RetroKeys {
    /// A key named in a pack's game.json ("ESC", "ENTER", "CTRL", "F1", "PGUP", "A" ...) -> (button label, RETROK code).
    static func named(_ raw: String) -> (String, UInt32)? {
        let n = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let table: [String: (String, UInt32)] = [
            "ESC": ("ESC", 27), "ESCAPE": ("ESC", 27), "ENTER": ("ENT", 13), "RETURN": ("ENT", 13), "ENT": ("ENT", 13),
            "SPACE": ("SPC", 32), "SPC": ("SPC", 32), "TAB": ("TAB", 9),
            "BACKSPACE": ("BKSP", 8), "BKSP": ("BKSP", 8), "DEL": ("DEL", 127), "DELETE": ("DEL", 127),
            "INS": ("INS", 277), "INSERT": ("INS", 277),
            "HOME": ("HOME", 278), "END": ("END", 279),
            "PGUP": ("PGUP", 280), "PAGEUP": ("PGUP", 280), "PGDN": ("PGDN", 281), "PAGEDOWN": ("PGDN", 281),
            "UP": ("\u{2191}", 273), "DOWN": ("\u{2193}", 274), "LEFT": ("\u{2190}", 276), "RIGHT": ("\u{2192}", 275),
            "CTRL": ("CTRL", 306), "CONTROL": ("CTRL", 306), "ALT": ("ALT", 308), "SHIFT": ("SHIFT", 304),
            "PAUSE": ("PAUSE", 19),
        ]
        if let t = table[n] { return t }
        if n.hasPrefix("F"), let i = Int(n.dropFirst()), (1...12).contains(i) { return (n, UInt32(281 + i)) }
        if n.count == 1, let a = n.unicodeScalars.first?.value, a >= 32, a < 127 {
            return (n, a >= 65 && a <= 90 ? a + 32 : a)
        }
        return nil
    }

    static func retro(_ key: UIKey) -> UInt32? {
        // macOS-style combos: ⌘+arrows = Home / End / PageUp / PageDown
        if key.modifierFlags.contains(.command) {
            switch key.keyCode {
            case .keyboardLeftArrow:  return 278
            case .keyboardRightArrow: return 279
            case .keyboardUpArrow:    return 280
            case .keyboardDownArrow:  return 281
            default: break
            }
        }

        let raw = key.keyCode.rawValue
        switch raw {
        case 0x04...0x1D: return UInt32(97 + raw - 0x04)      // A-Z -> 'a'-'z'
        case 0x1E...0x26: return UInt32(49 + raw - 0x1E)      // 1-9
        case 0x27:        return 48                           // 0
        case 0x3A...0x45: return UInt32(282 + raw - 0x3A)     // F1-F12
        case 0x68...0x6A: return UInt32(294 + raw - 0x68)     // F13-F15
        case 0x59...0x61: return UInt32(257 + raw - 0x59)     // keypad 1-9
        default: break
        }
        switch key.keyCode {
        case .keyboardReturnOrEnter: return 13
        case .keyboardEscape: return 27
        case .keyboardDeleteOrBackspace: return 8
        case .keyboardTab: return 9
        case .keyboardSpacebar: return 32
        case .keyboardHyphen: return 45
        case .keyboardEqualSign: return 61
        case .keyboardOpenBracket: return 91
        case .keyboardCloseBracket: return 93
        case .keyboardBackslash, .keyboardNonUSPound, .keyboardNonUSBackslash: return 92
        case .keyboardSemicolon: return 59
        case .keyboardQuote: return 39
        case .keyboardGraveAccentAndTilde: return 96
        case .keyboardComma: return 44
        case .keyboardPeriod: return 46
        case .keyboardSlash: return 47
        case .keyboardCapsLock: return 301
        case .keyboardPrintScreen: return 316
        case .keyboardScrollLock: return 302
        case .keyboardPause: return 19
        case .keyboardInsert: return 277
        case .keyboardHome: return 278
        case .keyboardPageUp: return 280
        case .keyboardDeleteForward: return 127
        case .keyboardEnd: return 279
        case .keyboardPageDown: return 281
        case .keyboardRightArrow: return 275
        case .keyboardLeftArrow: return 276
        case .keyboardDownArrow: return 274
        case .keyboardUpArrow: return 273
        case .keypadNumLock: return 300
        case .keypadSlash: return 267
        case .keypadAsterisk: return 268
        case .keypadHyphen: return 269
        case .keypadPlus: return 270
        case .keypadEnter: return 271
        case .keypad0: return 256
        case .keypadPeriod: return 266
        case .keypadEqualSign: return 272
        case .keyboardLeftControl: return 306
        case .keyboardLeftShift: return 304
        case .keyboardLeftAlt: return 308
        case .keyboardRightControl: return 305
        case .keyboardRightShift: return 303
        case .keyboardRightAlt: return 307
        default: break
        }
        // Unknown usage: fall back to the typed character (ASCII only).
        if let ch = key.charactersIgnoringModifiers.first, let a = ch.asciiValue, a >= 32, a < 127 {
            if (65...90).contains(a) { return UInt32(a + 32) }
            return UInt32(a)
        }
        return nil
    }
}

final class GameViewController: GCEventViewController {
    var onKey: ((UInt32, Bool, UInt16, UInt32) -> Void)?
    var onSecondaryClick: (() -> Void)?
    var onReleaseAll: (() -> Void)?
    /// RETROK codes the running game needs (from its game.json). Missing physical keys get stand-ins automatically.
    var gameKeys: Set<UInt32> = []
    var onPauseToggle: (() -> Void)?

    /// True while the pause menu is open: keys and the pointer belong to the menu, not the game.
    var inputBlocked = false {
        didSet {
            guard inputBlocked != oldValue else { return }
            setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    // MARK: Software keyboard (iOS keyboard on demand)

    /// Invisible responder that owns the iOS keyboard; set up by CoreHost.present().
    var softCatcher: SoftKeyCatcher?
    var onSoftKeyboardChange: ((Bool) -> Void)?
    var softKeyboardOn: Bool { softCatcher?.isFirstResponder ?? false }

    func setSoftKeyboard(_ on: Bool) {
        guard let c = softCatcher else { return }
        if on { c.becomeFirstResponder() }
        else if c.isFirstResponder { c.resignFirstResponder(); becomeFirstResponder() }
        onSoftKeyboardChange?(softKeyboardOn)
    }

    func toggleSoftKeyboard() { setSoftKeyboard(!softKeyboardOn) }

    /// Gives keyboard focus back to the game, but never takes it from the open software keyboard.
    func focusInput() {
        if softKeyboardOn { return }
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    /// Hide the iPadOS cursor and use raw trackpad/mouse movement (delivered via GCMouse).
    override var prefersPointerLocked: Bool { Prefs.lockPointer && !inputBlocked }

    /// Keys we translated or swallowed, remembered so the matching release is handled the same way.
    /// Value 0 = swallowed (no key sent to the game).
    private var heldSpecial: [Int: UInt32] = [:]

    /// ⌘ + arrows = Home / End / PageUp / PageDown for keyboards that lack those keys
    /// (←Home →End ↑PageUp ↓PageDown). Real Home/End/PageUp/PageDown keys keep working as they are.
    private func navKey(for key: UIKey) -> UInt32? {
        let f = key.modifierFlags
        guard f.contains(.command), !f.contains(.control), !f.contains(.alternate) else { return nil }
        switch key.keyCode {
        case .keyboardLeftArrow:  return 278
        case .keyboardRightArrow: return 279
        case .keyboardUpArrow:    return 280
        case .keyboardDownArrow:  return 281
        default: return nil
        }
    }

    /// ⌘ + number row = F-keys for keyboards without a function row.
    private func fKey(for key: UIKey) -> UInt32? {
        let needsF = gameKeys.contains { (282...293).contains($0) }
        guard Prefs.cmdFKeys || needsF, key.modifierFlags.contains(.command) else { return nil }
        let raw = key.keyCode.rawValue
        switch raw {
        case 0x1E...0x26: return UInt32(282 + raw - 0x1E)   // 1-9 -> F1-F9
        case 0x27: return 291                               // 0 -> F10
        case 0x2D: return 292                               // - -> F11
        case 0x2E: return 293                               // = -> F12
        default: return nil
        }
    }

    /// Esc stand-ins for keyboards without an Esc key (iPad Air Magic Keyboard), switchable in Settings:
    /// ⌘ + .  (Cmd-Period, the Apple "cancel" shortcut) and, optionally, the ` / ~ key.
    private func isEscCombo(_ key: UIKey) -> Bool {
        let f = key.modifierFlags
        let needsEsc = gameKeys.contains(27)
        if Prefs.escShortcut || needsEsc, key.keyCode == .keyboardPeriod, f.contains(.command) { return true }
        if Prefs.tildeEsc || needsEsc, key.keyCode == .keyboardGraveAccentAndTilde,
           !f.contains(.command), !f.contains(.control), !f.contains(.alternate) { return true }
        return false
    }

    /// The character a key types (printable only, ⌘ / ⌃ combos type nothing). ScummVM uses it for text entry.
    private func typed(_ key: UIKey) -> UInt32 {
        let f = key.modifierFlags
        if f.contains(.command) || f.contains(.control) { return 0 }
        guard let u = key.characters.unicodeScalars.first, key.characters.unicodeScalars.count == 1 else { return 0 }
        let v = u.value
        return (v >= 32 && v != 127 && !(0x80...0x9F).contains(v) && !(0xF700...0xF8FF).contains(v)) ? v : 0
    }

    /// RETROKMOD_* bits (shift 1, ctrl 2, alt 4, meta 8, numlock 16, caps 32).
    private func mods(_ key: UIKey) -> UInt16 {
        let f = key.modifierFlags
        var m: UInt16 = 16                       // NumLock assumed on (DOS default)
        if f.contains(.shift) { m |= 1 }
        if f.contains(.control) { m |= 2 }
        if f.contains(.alternate) { m |= 4 }
        if f.contains(.command) { m |= 8 }
        if f.contains(.alphaShift) { m |= 32 }
        return m
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        controllerUserInteractionEnabled = false     // controller buttons belong to the game, not UIKit focus
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onReleaseAll?()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.focusInput()
            self?.setNeedsUpdateOfPrefersPointerLocked()
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        focusInput()
        setNeedsUpdateOfPrefersPointerLocked()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onReleaseAll?()
    }

    private var observers: [NSObjectProtocol] = []
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func isPauseShortcut(_ key: UIKey) -> Bool {
        key.keyCode == .keyboardP && key.modifierFlags.contains(.command)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            if isPauseShortcut(key) {                              // ⌘P toggles the pause menu
                heldSpecial[key.keyCode.rawValue] = 0
                onPauseToggle?()
            } else if inputBlocked {
                if key.keyCode == .keyboardEscape || isEscCombo(key) {   // Esc closes the pause menu
                    heldSpecial[key.keyCode.rawValue] = 0
                    onPauseToggle?()
                }
            } else if isEscCombo(key) {
                heldSpecial[key.keyCode.rawValue] = 27
                onKey?(27, true, mods(key) & ~(8 | 1 | 2 | 4), 0)     // plain Esc: drop the modifiers used for the combo
            } else if let n = navKey(for: key) {
                heldSpecial[key.keyCode.rawValue] = n          // remembered so the release matches even if ⌘ is let go first
                onKey?(n, true, mods(key) & ~8, 0)
            } else if let f = fKey(for: key) {
                heldSpecial[key.keyCode.rawValue] = f
                onKey?(f, true, mods(key) & ~8, 0)
            } else if let code = RetroKeys.retro(key) {
                onKey?(code, true, mods(key), typed(key))
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            if let f = heldSpecial.removeValue(forKey: key.keyCode.rawValue) {
                if f != 0 { onKey?(f, false, f == 27 ? 16 : mods(key) & ~8, 0) }
            } else if inputBlocked {
                continue
            } else if let code = RetroKeys.retro(key) {
                onKey?(code, false, mods(key), typed(key))
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if let f = heldSpecial.removeValue(forKey: key.keyCode.rawValue) {
                if f != 0 { onKey?(f, false, 0, 0) }
            } else if let code = RetroKeys.retro(key) {
                onKey?(code, false, mods(key), typed(key))
            }
        }
        super.pressesCancelled(presses, with: event)
    }
}
