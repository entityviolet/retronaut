import UIKit

/// Invisible text-input responder. While it is first responder iOS shows its keyboard; what the person types arrives in
/// `insertText` / `deleteBackward` and is turned into DOS key events by CoreHost (see `typeText`). The bar above the
/// keyboard carries the keys iOS lacks: Esc, Tab, arrows, Enter, Ctrl / Alt / Shift (sticky) and F1-F12.
final class SoftKeyCatcher: UIView, UIKeyInput {
  var onType: ((String) -> Void)?
  var onBackspace: (() -> Void)?
  var onKey: ((UInt32, Bool) -> Void)?         // bar key: (RETROK code, down)
  var onModifier: ((UInt32, Bool) -> Void)?    // sticky Ctrl / Alt / Shift: (RETROK code, on)
  var onHide: (() -> Void)?
  var onMouse: ((Bool, Bool) -> Void)?         // mouse button of the bar: (right?, down)

  // UITextInputTraits: plain ASCII typing, nothing "helpful".
  var keyboardType: UIKeyboardType = .asciiCapable
  var autocorrectionType: UITextAutocorrectionType = .no
  var autocapitalizationType: UITextAutocapitalizationType = .none
  var spellCheckingType: UITextSpellCheckingType = .no
  var smartQuotesType: UITextSmartQuotesType = .no
  var smartDashesType: UITextSmartDashesType = .no
  var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
  var returnKeyType: UIReturnKeyType = .default
  var enablesReturnKeyAutomatically = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    alpha = 0.01
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var canBecomeFirstResponder: Bool { true }
  var hasText: Bool { true }                       // always true so Backspace is always delivered
  func insertText(_ text: String) { onType?(text) }
  func deleteBackward() { onBackspace?() }

  override var inputAccessoryView: UIView? { bar }
  private lazy var bar: UIInputView = makeBar()
  private var stickyButtons: [UInt32: UIButton] = [:]
  private var stickyOn = Set<UInt32>()

  /// Release sticky modifiers (the keyboard was closed).
  func clearModifiers() {
    for code in stickyOn { onModifier?(code, false) }
    stickyOn.removeAll()
    for b in stickyButtons.values { style(b, on: false) }
  }

  private func style(_ b: UIButton, on: Bool) {
    b.backgroundColor = on ? UIColor(red: 0.36, green: 1.0, blue: 0.55, alpha: 1) : UIColor(white: 1, alpha: 0.12)
    b.setTitleColor(on ? .black : .white, for: .normal)
  }

  private func makeButton(_ title: String) -> UIButton {
    let b = UIButton(type: .system)
    b.setTitle(title, for: .normal)
    b.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
    b.layer.cornerRadius = 8
    b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    b.translatesAutoresizingMaskIntoConstraints = false
    b.heightAnchor.constraint(equalToConstant: 34).isActive = true
    b.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
    style(b, on: false)
    return b
  }

  private func makeBar() -> UIInputView {
    let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
    bar.allowsSelfSizing = true

    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = false
    bar.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: bar.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
      bar.heightAnchor.constraint(equalToConstant: 46),
    ])

    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 6
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])

    // Hide
    let hide = makeButton("")
    hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
    hide.addAction(UIAction { [weak self] _ in self?.onHide?() }, for: .touchUpInside)
    stack.addArrangedSubview(hide)

    // Mouse buttons (held while pressed)
    for (title, right) in [("L-CLICK", false), ("R-CLICK", true)] {
      let b = makeButton(title)
      b.addAction(UIAction { [weak self] _ in self?.onMouse?(right, true) }, for: .touchDown)
      b.addAction(UIAction { [weak self] _ in self?.onMouse?(right, false) }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
      stack.addArrangedSubview(b)
    }

    // Sticky modifiers
    for (title, code) in [("CTRL", UInt32(306)), ("ALT", 308), ("SHIFT", 304)] {
      let b = makeButton(title)
      stickyButtons[code] = b
      b.addAction(UIAction { [weak self, weak b] _ in
        guard let self, let b else { return }
        let on = !self.stickyOn.contains(code)
        if on { self.stickyOn.insert(code) } else { self.stickyOn.remove(code) }
        self.style(b, on: on)
        self.onModifier?(code, on)
      }, for: .touchUpInside)
      stack.addArrangedSubview(b)
    }

    // Plain keys (down on touch, up on release)
    var keys: [(String, UInt32)] = [("ESC", 27), ("TAB", 9), ("ENTER", 13), ("\u{2190}", 276), ("\u{2191}", 273),
                                    ("\u{2193}", 274), ("\u{2192}", 275), ("DEL", 127), ("INS", 277),
                                    ("HOME", 278), ("END", 279), ("PGUP", 280), ("PGDN", 281)]
    for i in 1...12 { keys.append(("F\(i)", UInt32(281 + i))) }
    for (title, code) in keys {
      let b = makeButton(title)
      b.addAction(UIAction { [weak self] _ in self?.onKey?(code, true) }, for: .touchDown)
      b.addAction(UIAction { [weak self] _ in self?.onKey?(code, false) }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
      stack.addArrangedSubview(b)
    }
    return bar
  }
}

extension CoreHost {
  /// Connects the keyboard responder to the core and keeps the game picture above the keyboard.
  func installSoftKeyboard(in vc: GameViewController) {
    let c = SoftKeyCatcher(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    vc.view.addSubview(c)
    vc.softCatcher = c

    c.onType = { [weak self] text in self?.typeText(text) }
    c.onBackspace = { [weak self] in self?.tapKey(8) }
    c.onKey = { [weak self] code, down in
      guard let self else { return }
      self.sendKey(code, down: down, mods: 16 | self.softMods)
    }
    c.onModifier = { [weak self] code, on in
      guard let self else { return }
      let bit: UInt16 = code == 304 ? 1 : (code == 306 ? 2 : 4)
      if on { self.softMods |= bit } else { self.softMods &= ~bit }
      self.sendKey(code, down: on, mods: 16 | self.softMods)
    }
    c.onHide = { [weak vc] in vc?.setSoftKeyboard(false) }
    c.onMouse = { [weak self] right, down in
      guard let self else { return }
      // ScummVM reads the mouse buttons only in its mouse mode (fingers use its pointer mode): switch while clicking.
      if self.isScummVM, down { self.inputIsMouse = true; self.setMouseMode("virtual") }
      let now = CACurrentMediaTime()
      if right { self.hwRight = down; if !down { self.hwRightUntil = now + 0.06 } }
      else { self.hwLeft = down; if !down { self.hwLeftUntil = now + 0.06 } }
    }

    // Picture above the keyboard (the frame includes the bar; with a hardware keyboard it is just a thin bar).
    kbObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                                        object: nil, queue: .main) { [weak self, weak vc] n in
      guard let self, let vc, let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
      let local = vc.view.convert(end, from: nil)
      let covered = vc.softKeyboardOn ? max(0, vc.view.bounds.maxY - local.minY) : 0
      self.imageBottom?.constant = -covered
      let d = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
      UIView.animate(withDuration: d) { vc.view.layoutIfNeeded() }
    }
    vc.onSoftKeyboardChange = { [weak self, weak vc] on in
      if !on {
        vc?.softCatcher?.clearModifiers()
        self?.imageBottom?.constant = 0
        UIView.animate(withDuration: 0.25) { vc?.view.layoutIfNeeded() }
      }
    }
  }

  func removeSoftKeyboard() {
    if let o = kbObserver { NotificationCenter.default.removeObserver(o); kbObserver = nil }
    gameVC?.softCatcher?.clearModifiers()
    gameVC?.softCatcher?.resignFirstResponder()
    gameVC?.softCatcher?.removeFromSuperview()
    gameVC?.softCatcher = nil
    softMods = 0
  }

  // MARK: Typing

  /// US layout: character -> (RETROK code, needs Shift).
  private static func softKey(for ch: Character) -> (code: UInt32, shift: Bool)? {
    guard let a = ch.asciiValue else { return nil }
    let s = UInt32(a)
    switch ch {
    case "a"..."z", "0"..."9": return (s, false)
    case "A"..."Z": return (s + 32, true)
    case " ": return (32, false)
    case "\n", "\r": return (13, false)
    case "\t": return (9, false)
    default: break
    }
    let plain = Array("-=[]\\;',./`".unicodeScalars)
    if plain.contains(where: { $0.value == s }) { return (s, false) }
    let shifted = Array("!@#$%^&*()_+{}|:\"<>?~")
    let base = Array("1234567890-=[]\\;',./`")
    if let i = shifted.firstIndex(of: ch) { return (base[i].asciiValue.map { UInt32($0) } ?? 0, true) }
    return nil
  }

  /// Types text one key at a time (a few frames per key so the core sees every press).
  func typeText(_ text: String) {
    for ch in text {
      guard let k = Self.softKey(for: ch) else { continue }
      press(k.code, shift: k.shift, character: ch.asciiValue.map { UInt32($0) } ?? 0)
    }
  }

  func tapKey(_ code: UInt32) { press(code, shift: false, character: 0) }

  private func press(_ code: UInt32, shift: Bool, character: UInt32) {
    let now = CACurrentMediaTime()
    let start = max(now, kbQueueTime)
    kbQueueTime = start + 0.09
    let wait = start - now
    let needShift = shift && (softMods & 1) == 0
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
      guard let self, gHost === self else { return }
      let mods: UInt16 = 16 | self.softMods | (shift ? 1 : 0)
      if needShift { self.sendKey(304, down: true, mods: mods) }
      self.sendKey(code, down: true, mods: mods, character: character)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.045) { [weak self] in
      guard let self, gHost === self else { return }
      let mods: UInt16 = 16 | self.softMods | (shift ? 1 : 0)
      self.sendKey(code, down: false, mods: mods, character: character)
      if needShift { self.sendKey(304, down: false, mods: 16 | self.softMods) }
    }
  }
}
