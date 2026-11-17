import UIKit
import GameController

/// Game controller support (MFi / Xbox / PlayStation / Switch Pro). The pad is translated into
/// DOS keyboard keys and mouse movement, sampled once per emulated frame.
///
///  D-pad / left stick  → arrow keys
///  face buttons        → depends on the layout chosen in Settings
///  L1 / R1             → Esc / Tab
///  right stick         → mouse cursor, R2 = left click, L2 = right click
///  Menu / Start        → pause menu
extension CoreHost {
  func setupPad() {
    let nc = NotificationCenter.default
    padObservers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
      guard let self, let c = n.object as? GCController else { return }
      self.bindPad(c)
      if Prefs.padEnabled, let vc = self.gameVC { self.toast("\(c.vendorName ?? "Controller") connected", in: vc) }
    })
    padObservers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
      self?.releasePad()
    })
    GCController.controllers().forEach { bindPad($0) }
  }

  private func bindPad(_ c: GCController) {
    c.extendedGamepad?.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
      if pressed { self?.onPauseRequest?() }
    }
  }

  func teardownPad() {
    padObservers.forEach { NotificationCenter.default.removeObserver($0) }
    padObservers.removeAll()
    GCController.controllers().forEach { $0.extendedGamepad?.buttonMenu.pressedChangedHandler = nil }
    releasePad()
  }

  func releasePad() {
    for k in padKeys { sendKey(k, down: false) }
    padKeys.removeAll()
    padLeft = false
    padRight = false
  }

  /// Face-button key codes for the chosen layout: (A, B, X, Y).
  private func faceKeys() -> (UInt32, UInt32, UInt32, UInt32) {
    switch Prefs.padLayout {
    case "action": return (32, 306, 308, 13)    // Space, Ctrl, Alt, Enter
    case "menu":   return (13, 27, 32, 9)       // Enter, Esc, Space, Tab
    default:       return (306, 308, 32, 13)    // Ctrl, Alt, Space, Enter  (Keen, Dave, most DOS action games)
    }
  }

  func pollPad() {
    guard Prefs.padEnabled,
          let pad = GCController.controllers().compactMap({ $0.extendedGamepad }).first else {
      if !padKeys.isEmpty || padLeft || padRight { releasePad() }
      return
    }

    let dead: Float = 0.45
    let lx = pad.leftThumbstick.xAxis.value, ly = pad.leftThumbstick.yAxis.value
    var want = Set<UInt32>()
    if pad.dpad.left.isPressed || lx < -dead { want.insert(276) }
    if pad.dpad.right.isPressed || lx > dead { want.insert(275) }
    if pad.dpad.up.isPressed || ly > dead { want.insert(273) }
    if pad.dpad.down.isPressed || ly < -dead { want.insert(274) }

    let (a, b, x, y) = faceKeys()
    if pad.buttonA.isPressed { want.insert(a) }
    if pad.buttonB.isPressed { want.insert(b) }
    if pad.buttonX.isPressed { want.insert(x) }
    if pad.buttonY.isPressed { want.insert(y) }
    if pad.leftShoulder.isPressed { want.insert(27) }
    if pad.rightShoulder.isPressed { want.insert(9) }

    for k in want.subtracting(padKeys) { sendKey(k, down: true) }
    for k in padKeys.subtracting(want) { sendKey(k, down: false) }
    padKeys = want

    if Prefs.padStickMouse {
      padLeft = pad.rightTrigger.value > 0.5
      padRight = pad.leftTrigger.value > 0.5
      let rx = pad.rightThumbstick.xAxis.value, ry = pad.rightThumbstick.yAxis.value
      if abs(rx) > 0.15 || abs(ry) > 0.15 {
        noteMouse()
        let speed = CGFloat(Prefs.mouseSpeed) * 5
        pendDX += CGFloat(rx * abs(rx)) * speed
        pendDY -= CGFloat(ry * abs(ry)) * speed     // stick +Y is up, DOS +Y is down
      }
    } else {
      padLeft = false
      padRight = false
    }
  }
}
