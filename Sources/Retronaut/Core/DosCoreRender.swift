import QuartzCore
import Foundation
import UIKit
import AVFoundation
import GameController

final class PaddedLabel: UILabel {
  override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14))) }
  override var intrinsicContentSize: CGSize {
    let s = super.intrinsicContentSize
    return CGSize(width: s.width + 28, height: s.height + 14)
  }
}

/// Pull-based audio: libretro pushes S16 stereo frames into a ring buffer,
/// AVAudioSourceNode pulls them on the audio thread.
final class RingBuffer {
  private var buf: [Float]
  private var readIdx = 0, writeIdx = 0, count = 0
  private let lock = NSLock()
  // Last delivered stereo frame: on underrun it is repeated with a decay instead of jumping to 0.0,
  // which is what produced an audible click every time the buffer ran dry.
  private var lastL: Float = 0, lastR: Float = 0
  private let decay: Float = 0.995
  private let capacity: Int

  init(sampleRate: Double, seconds: Double = 1.5) {
    capacity = max(2048, Int(sampleRate * seconds) * 2)
    buf = [Float](repeating: 0, count: capacity)
  }

  func write(_ p: UnsafePointer<Int16>, frames: Int) {
    AudioOut.totalSamples += frames
    lock.lock()
    var w = writeIdx
    for i in 0..<(frames * 2) {
      buf[w] = Float(p[i]) / 32768.0
      w = (w + 1) % capacity
      if count < capacity { count += 1 } else { readIdx = (readIdx + 1) % capacity }
    }
    writeIdx = w
    lock.unlock()
  }

  func read(left: UnsafeMutablePointer<Float32>, right: UnsafeMutablePointer<Float32>, frames: Int) {
    lock.lock()
    for i in 0..<frames {
      if count >= 2 {
        left[i] = buf[readIdx]; readIdx = (readIdx + 1) % capacity
        right[i] = buf[readIdx]; readIdx = (readIdx + 1) % capacity
        count -= 2
        lastL = left[i]; lastR = right[i]
      } else {
        lastL *= decay; lastR *= decay
        left[i] = lastL; right[i] = lastR
      }
    }
    lock.unlock()
  }

  func read(into out: UnsafeMutablePointer<Float32>, samples: Int) {
    lock.lock()
    var r = readIdx
    for i in 0..<samples {
      if count > 0 {
        out[i] = buf[r]; r = (r + 1) % capacity; count -= 1
        if i % 2 == 0 { lastL = out[i] } else { lastR = out[i] }
      } else {
        if i % 2 == 0 { lastL *= decay; out[i] = lastL } else { lastR *= decay; out[i] = lastR }
      }
    }
    readIdx = r
    lock.unlock()
  }
}

final class AudioOut {
  private let engine = AVAudioEngine()
  private var sourceNode: AVAudioSourceNode?
  private let ring: RingBuffer
  private var format: AVAudioFormat?
  private(set) var started = false
  static var lastError: String?
  static var totalSamples = 0
  static weak var current: AudioOut?

  init(sampleRate: Double) {
    ring = RingBuffer(sampleRate: sampleRate)
    // Interleaved float stereo, filled by the render callback from the ring buffer.
    let rate = (sampleRate.isFinite && sampleRate >= 8000 && sampleRate <= 48000) ? sampleRate : 44100
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
    format = fmt
    let ring = self.ring
    let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
      let list = UnsafeMutableAudioBufferListPointer(abl)
      let n = Int(frameCount)
      if list.count >= 2,
         let l = list[0].mData?.assumingMemoryBound(to: Float32.self),
         let r = list[1].mData?.assumingMemoryBound(to: Float32.self) {
        ring.read(left: l, right: r, frames: n)
      } else if let data = list.first?.mData?.assumingMemoryBound(to: Float32.self) {
        ring.read(into: data, samples: n * 2)
      }
      return noErr
    }
    sourceNode = node
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: fmt)
    engine.mainMixerNode.outputVolume = 1.0
    AudioOut.current = self

    NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                           object: nil, queue: .main) { [weak self] n in
      guard let self,
            let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: v) == .ended else { return }
      self.started = false
      self.start()
    }
    NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                           object: engine, queue: .main) { [weak self] _ in
      self?.started = false
      self?.start()
    }
  }

  func shutdown() {
    NotificationCenter.default.removeObserver(self)
    engine.stop()
    started = false
  }

  static func report() {
    let state = "engine=\(current?.started == true ? "on" : "off") samples=\(totalSamples) rate=\(Int(current?.format?.sampleRate ?? 0)) err=\(lastError ?? "-")"
    UserDefaults.standard.set(state, forKey: "audioDiag")
    NSLog("AUDIODIAG %@", state)
  }

  func start() {
    if started { return }
    let work: () -> Void = { [weak self] in
      guard let self, let fmt = self.format else { return }
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
      } catch {
        AudioOut.lastError = "session:\(error.localizedDescription)"
      }
      if self.engine.isRunning { self.started = true; return }
      self.engine.prepare()
      do {
        try self.engine.start()
        self.started = true
      } catch {
        AudioOut.lastError = "engine:\(error.localizedDescription)"
      }
      _ = fmt
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  func push(_ p: UnsafePointer<Int16>, frames: Int) {
    guard frames > 0 else { return }
    ring.write(p, frames: frames)
  }
}


/// Game picture. Receives raw finger touches (multi-touch) and hands them to the host, which
/// turns them into the libretro pointer. Mouse/trackpad touches (.indirectPointer) are ignored
/// here: they arrive via GCMouse or the UIKit recognizers below.
final class TouchSurface: UIImageView {
  weak var host: CoreHost?
  private var active: [UITouch] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = true
    isMultipleTouchEnabled = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func isFinger(_ t: UITouch) -> Bool { t.type == .direct || t.type == .pencil }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches where isFinger(t) && !active.contains(where: { $0 === t }) { active.append(t) }
    host?.fingersChanged(active, in: self, began: true)
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard touches.contains(where: isFinger) else { return }
    host?.fingersChanged(active, in: self, began: false)
  }
  private func finish(_ touches: Set<UITouch>) {
    guard touches.contains(where: isFinger) else { return }
    active.removeAll { t in touches.contains { $0 === t } }
    host?.fingersChanged(active, in: self, began: false)
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
}

extension CoreHost: UIGestureRecognizerDelegate {
  func attach(in vc: UIViewController) {
    let iv = TouchSurface(frame: .zero)
    iv.host = self
    iv.contentMode = .scaleAspectFit
    iv.backgroundColor = .black
    iv.translatesAutoresizingMaskIntoConstraints = false
    iv.isUserInteractionEnabled = true
    vc.view.addSubview(iv)
    let bottom = iv.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor)
    NSLayoutConstraint.activate([
      iv.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
      iv.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
      iv.topAnchor.constraint(equalTo: vc.view.topAnchor),
      bottom,
    ])
    imageBottom = bottom
    imageView = iv

    let pan = UIPanGestureRecognizer(target: self, action: #selector(onTouch(_:)))
    let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
    let two = UITapGestureRecognizer(target: self, action: #selector(onRight(_:)))
    two.numberOfTouchesRequired = 2

    // These recognizers are only the UIKit fallback for a mouse/trackpad that GCMouse hasn't
    // reported yet. Fingers are handled by TouchSurface (raw multi-touch), so they must not
    // compete with these recognizers.
    let indirect = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
    pan.allowedTouchTypes = [indirect]
    tap.allowedTouchTypes = [indirect]
    tap.cancelsTouchesInView = false
    tap.delaysTouchesEnded = false
    two.allowedTouchTypes = [indirect]

    let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
    hover.allowedTouchTypes = [indirect]

    iv.addGestureRecognizer(pan)
    iv.addGestureRecognizer(tap)
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(onRight(_:)))
    hold.minimumPressDuration = 0.55
    hold.allowedTouchTypes = [indirect]
    iv.addGestureRecognizer(hold)
    iv.addGestureRecognizer(two)
    iv.addGestureRecognizer(hover)

    // Two-finger drag = mouse wheel (feed the latch the core already reads, ids 4/5).
    let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScrollWheel(_:)))
    scroll.minimumNumberOfTouches = 2
    scroll.maximumNumberOfTouches = 2
    scroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    scroll.cancelsTouchesInView = false
    scroll.allowedScrollTypesMask = .all          // mouse wheel / trackpad scroll when UIKit (not GCMouse) delivers it
    iv.addGestureRecognizer(scroll)
    for g in [pan, tap, two, hold, hover, scroll] as [UIGestureRecognizer] { g.delegate = self }
  }

  // MARK: Finger touches

  /// Called by TouchSurface with every finger currently down (in order of arrival).
  func fingersChanged(_ list: [UITouch], in view: UIView, began: Bool) {
    if !isScummVM { dosTouchChanged(Prefs.touchEnabled ? list : [], in: view); return }
    let n = Prefs.touchEnabled ? list.count : 0
    guard n > 0, let first = list.first else {
      fingerCount = 0
      leftSuppressed = false
      longPress?.cancel(); longPress = nil
      return
    }
    let p = first.location(in: view)
    let wasIdle = fingerCount == 0
    fingerCount = n
    updatePointer(p)
    if n >= 2 { updatePointer2(list[1].location(in: view)) }
    let synthGestures = baseTouchMode != "pad" && !isScummVM     // DOSBox Pure (touchpad) and ScummVM (pointer) handle tap / long-press themselves

    if wasIdle && n == 1 {
      // A finger is now the active pointing device: leave "virtual" (mouse) mode.
      inputIsMouse = false
      setMouseMode(baseTouchMode)
      pendDX = 0; pendDY = 0
      touchOrigin = p
      leftSuppressed = false
      pressUntil = CACurrentMediaTime() + 0.09        // short taps stay "pressed" for a few frames
      if synthGestures { scheduleLongPress() }
    } else if n >= 2 {
      // Two fingers = right click (left press is withdrawn first).
      if synthGestures && !leftSuppressed {
        leftSuppressed = true
        longPress?.cancel(); longPress = nil
        pulseRight()
      }
    } else if hypot(p.x - touchOrigin.x, p.y - touchOrigin.y) > 12 {
      longPress?.cancel(); longPress = nil              // dragging, not holding
    }
  }

  // MARK: DOSBox touch: fingers as a trackpad

  /// Trackpad behaviour on the relative mouse (the path a real trackpad uses):
  ///  - one finger moves the cursor, from wherever it is (no jumping), with a little acceleration for precision/reach;
  ///  - a quick tap = left click at the cursor; a small wobble while tapping never moves the cursor;
  ///  - two-finger tap or press-and-hold = right click; two-finger drag = scroll wheel (scroll recognizer);
  ///  - tap, then touch again and move = left button held (drag, drag-select, move windows);
  /// Distances are in points, so it behaves the same in landscape and portrait.
  func dosTouchChanged(_ list: [UITouch], in view: UIView) {
    let now = CACurrentMediaTime()
    let n = list.count
    fingerCount = 0                              // the core's own pointer stays idle in this mode
    if n > 0 {
      inputIsMouse = false
      setMouseMode("virtual")                    // relative mouse while fingers drive the cursor
    }

    guard n > 0, let first = list.first else {
      if padFingers > 0 { dosTouchEnded(now) }
      padFingers = 0; padPeak = 0
      longPress?.cancel(); longPress = nil
      return
    }
    let p = first.location(in: view)
    if padFingers == 0 {
      padDown = now; padMoved = 0; padPeak = n; padLast = p; padLongFired = false
      padHold = .zero; padArmed = false
      if now - padTapEndedAt < 0.3 {
        padDragging = true; hwLeft = true        // tap, then touch and move: left button held
      }
      longPress?.cancel()
      let w = DispatchWorkItem { [weak self] in
        guard let self, self.padFingers == 1, !self.padDragging, self.padMoved < 10 else { return }
        self.padLongFired = true
        self.hwRightUntil = CACurrentMediaTime() + 0.12
      }
      longPress = w
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: w)
    } else {
      padPeak = max(padPeak, n)
      let dx = p.x - padLast.x, dy = p.y - padLast.y
      padLast = p
      padMoved += hypot(dx, dy)
      if n == 1 && padPeak == 1 {                // two fingers = scroll, never cursor movement
        if padArmed || padDragging {
          emitMove(dx, dy)
        } else {
          padHold.x += dx; padHold.y += dy       // inside the tap slop: hold the cursor still
          if hypot(padHold.x, padHold.y) > 6 {
            padArmed = true
            emitMove(padHold.x, padHold.y)
            padHold = .zero
          }
        }
      }
    }
    padFingers = n
  }

  /// Finger movement in points -> relative mouse units, with gentle acceleration (slow = precise, fast = far).
  private func emitMove(_ dx: CGFloat, _ dy: CGFloat) {
    let v = hypot(dx, dy)
    let gain = 1 + min(v / 25, 1.6)
    pendDX += dx * deltaScale * gain
    pendDY += dy * deltaScale * gain
  }

  private func dosTouchEnded(_ now: CFTimeInterval) {
    if padDragging {
      hwLeft = false; hwLeftUntil = now + 0.05
      padDragging = false; padTapEndedAt = 0
      return
    }
    let dur = now - padDown
    if padPeak >= 2 {
      if padMoved < 30 && dur < 0.45 { hwRightUntil = now + 0.12 }
    } else if !padLongFired && padMoved < 14 && dur < 0.35 {
      hwLeftUntil = now + 0.1                    // a click that lasts a few frames, so no game misses it
      padTapEndedAt = now
    }
  }

  private func scheduleLongPress() {
    longPress?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self, self.fingerCount == 1, !self.leftSuppressed else { return }
      self.leftSuppressed = true
      self.pulseRight()
    }
    longPress = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: w)
  }

  private func pulseRight() {
    rightHeld = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.rightHeld = false }
  }

  // MARK: Hardware mouse / trackpad (GameController)

  func setupMouse() {
    let nc = NotificationCenter.default
    mouseObservers.append(nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
      if let m = n.object as? GCMouse { self?.bind(m) }
    })
    mouseObservers.append(nc.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] n in
      guard let self else { return }
      if let m = n.object as? GCMouse { self.unbind(m) }
      if GCMouse.mice().isEmpty {
        self.mouseBound = false
        self.inputIsMouse = false
        self.setMouseMode(baseTouchMode)
      }
      self.hwLeft = false; self.hwRight = false; self.hwMiddle = false
    })
    GCMouse.mice().forEach { bind($0) }
  }

  func setMouseMode(_ mode: String) {
    if mouseMode != mode { mouseMode = mode; variablesDirty = true }
  }

  /// Called on every real event from a GCMouse (or the pad's right stick). Until the first one,
  /// the UIKit pointer path stays active as a fallback, so a mouse that never reports can't
  /// leave you with no cursor. The core goes to "virtual" (relative mouse) mode only while a
  /// mouse is the last-used device; the next finger touch switches back (see fingersChanged).
  func noteMouse() {
    guard Prefs.mouseEnabled else { return }
    mouseBound = true
    guard fingerCount == 0 else { return }     // a stray trackpad event must not steal an active touch
    inputIsMouse = true
    setMouseMode("virtual")
  }

  /// DOS pixels per screen point, so the DOS cursor follows the finger/trackpad visually.
  fileprivate var deltaScale: CGFloat {
    guard let iv = imageView, iv.bounds.width > 0, iv.bounds.height > 0 else { return 1 }
    let s = min(iv.bounds.width / CGFloat(pixelW), iv.bounds.height / CGFloat(pixelH))
    return s > 0 ? CGFloat(Prefs.mouseSpeed) / s : 1
  }

  private func bind(_ m: GCMouse) {
    guard let mi = m.mouseInput else { return }
    mi.mouseMovedHandler = { [weak self] _, dx, dy in
      guard let self, Prefs.mouseEnabled else { return }
      self.noteMouse()
      self.pendDX += CGFloat(dx) * self.deltaScale
      self.pendDY -= CGFloat(dy) * self.deltaScale   // GameController: +Y is up, DOS: +Y is down
    }
    mi.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
      guard let self, Prefs.mouseEnabled else { return }
      self.noteMouse(); self.hwLeft = pressed
      if pressed { self.hwLeftUntil = CACurrentMediaTime() + 0.06 }
    }
    mi.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
      guard let self, Prefs.mouseEnabled else { return }
      self.noteMouse(); self.hwRight = pressed
      if pressed { self.hwRightUntil = CACurrentMediaTime() + 0.06 }
    }
    mi.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
      guard let self, Prefs.mouseEnabled else { return }
      self.noteMouse(); self.hwMiddle = pressed
      if pressed { self.hwMiddleUntil = CACurrentMediaTime() + 0.06 }
    }
    mi.scroll.valueChangedHandler = { [weak self] _, _, y in
      guard let self, Prefs.mouseEnabled else { return }
      self.noteMouse(); self.pendWheel += CGFloat(y)
    }
  }

  private func unbind(_ m: GCMouse) {
    guard let mi = m.mouseInput else { return }
    mi.mouseMovedHandler = nil
    mi.leftButton.pressedChangedHandler = nil
    mi.rightButton?.pressedChangedHandler = nil
    mi.middleButton?.pressedChangedHandler = nil
    mi.scroll.valueChangedHandler = nil
  }

  func teardownMouse() {
    mouseObservers.forEach { NotificationCenter.default.removeObserver($0) }
    mouseObservers.removeAll()
    GCMouse.mice().forEach { unbind($0) }
    mouseBound = false
  }

  /// When a real mouse/trackpad is bound, GCMouse drives the cursor; ignore the same
  /// device arriving as UIKit "indirect pointer" touches so it doesn't move twice.
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if touch.type == .indirectPointer { return Prefs.mouseEnabled && !mouseBound }
    return true
  }

  @objc private func onScrollWheel(_ g: UIPanGestureRecognizer) {
    guard let host = gHost, Prefs.scrollWheel else { return }
    let dy = g.translation(in: imageView).y
    g.setTranslation(.zero, in: imageView)
    if g.numberOfTouches == 0 && mouseBound { return }   // a bound GCMouse already reports its wheel
    host.pendWheel += -dy / 24.0
  }

  @objc func onTouch(_ g: UIPanGestureRecognizer) {
    if !mouseBound { setMouseMode(baseTouchMode) }
    if mouseBound {
      // Core is in relative-mouse mode (it ignores the touch pointer): act like a touchpad.
      if g.state == .began { g.setTranslation(.zero, in: imageView) }
      let t = g.translation(in: imageView)
      g.setTranslation(.zero, in: imageView)
      pendDX += t.x * deltaScale
      pendDY += t.y * deltaScale
      // Also feed the absolute pointer, so cores in pointer/pad mode still see the finger.
      updatePointer(g.location(in: imageView))
      if g.state == .ended || g.state == .cancelled || g.state == .failed { touched = false }
      return
    }
    updatePointer(g.location(in: imageView))
    switch g.state {
    case .began, .changed: clicked = true
    case .ended, .cancelled, .failed: clicked = false
    default: break
    }
  }

  @objc func onHover(_ g: UIHoverGestureRecognizer) {
    if mouseBound { return }
    setMouseMode(baseTouchMode)
    // trackpad / mouse movement moves the DOS cursor without pressing a button
    updatePointer(g.location(in: imageView))
    hovering = (g.state == .began || g.state == .changed)
    if g.state == .ended { clicked = false }
  }

  @objc func onTap(_ g: UITapGestureRecognizer) {
    if !mouseBound { setMouseMode(baseTouchMode) }
    updatePointer(g.location(in: imageView))
    clicked = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.clicked = false }
  }

  @objc func onRight(_ g: UIGestureRecognizer) {
    updatePointer(g.location(in: imageView))
    rightHeld = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.rightHeld = false }
  }

  private func pointerCoords(_ p: CGPoint) -> (Int16, Int16)? {
    guard let iv = imageView, iv.bounds.width > 0, iv.bounds.height > 0 else { return nil }
    let vw = iv.bounds.width, vh = iv.bounds.height
    let scale = min(vw / CGFloat(pixelW), vh / CGFloat(pixelH))
    let dw = CGFloat(pixelW) * scale, dh = CGFloat(pixelH) * scale
    let ox = (vw - dw) / 2, oy = (vh - dh) / 2
    let x = max(0, min(1, (p.x - ox) / dw))
    let y = max(0, min(1, (p.y - oy) / dh))
    return (Int16(x * 65535 - 32768), Int16(y * 65535 - 32768))
  }

  func updatePointer2(_ p: CGPoint) {
    if let c = pointerCoords(p) { touchX2 = c.0; touchY2 = c.1 }
  }

  func updatePointer(_ p: CGPoint) {
    guard let iv = imageView, iv.bounds.width > 0, iv.bounds.height > 0 else { return }
    // Map into the aspect-fit rectangle the game is actually drawn in.
    let vw = iv.bounds.width, vh = iv.bounds.height
    let scale = min(vw / CGFloat(pixelW), vh / CGFloat(pixelH))
    let dw = CGFloat(pixelW) * scale, dh = CGFloat(pixelH) * scale
    let ox = (vw - dw) / 2, oy = (vh - dh) / 2
    let x = max(0, min(1, (p.x - ox) / dw))
    let y = max(0, min(1, (p.y - oy) / dh))
    touchX = Int16(x * 65535 - 32768)
    touchY = Int16(y * 65535 - 32768)
    touched = true
  }

  @objc func tick() {
    NetSession.shared.framePoll()      // multiplayer: deliver packets, let the core poll (no-op without a session)
    // CADisplayLink cannot produce 70.086 Hz: at 60 Hz the core would run 60/70.086 = 14.4 % too slow (flat,
    // slightly low pitch) and at 120 Hz twice too fast. Carry the fractional frame so the average over time is
    // exactly av_info.timing.fps, and keep running the core on the main thread as before (no extra thread).
    let displayHz = max(1.0, 1.0 / (link?.duration ?? (1.0 / 60.0)))
    paceAccum += fps / displayHz
    var budget = 0
    while paceAccum >= 1.0 - 1e-9, budget < 4 {
      runFn?()
      framesRun += 1
      paceAccum -= 1.0
      budget += 1
    }
    if paceAccum > 4 { paceAccum = 4 }   // never let a backlog build up
    // "Continue": restore the auto-save once the DOS session has booted a few frames.
    if let slot = pendingLoadSlot, framesRun >= 45 {
      pendingLoadSlot = nil
      _ = loadState(slot: slot)
    }
  }

  func begin() {
    let l = CADisplayLink(target: self, selector: #selector(tick))
    // Run the link as fast as the panel allows (60 or 120); tick() converts that into the core's exact rate.
    l.preferredFramesPerSecond = 0
    l.add(to: .main, forMode: .common)
    link = l
    paceAccum = 0
  }

  func stop() {
    NetSession.shared.coreEnded()      // never call into the core after it is unloaded
    link?.invalidate()
    link = nil
    teardownMouse()
    teardownPad()
    releaseAllKeys()
    if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
    removePauseUI()
    removeSoftKeyboard()
    longPress?.cancel(); longPress = nil
    unload?()
    deinitCore?()
    if let h = handle { dlclose(h) }
    handle = nil
    imageView?.removeFromSuperview()
    imageView = nil
    audio?.shutdown()
    audio = nil
    window?.isHidden = true
    window = nil
    gHost = nil
  }

  func present() {
    if audio == nil {
      audio = AudioOut(sampleRate: (sampleRate >= 8000 && sampleRate <= 192000) ? sampleRate : 44100)
    }
    audio?.start()
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    let w = UIWindow(windowScene: scene)
    let vc = GameViewController()
    vc.gameKeys = gameKeys
    vc.view.backgroundColor = .black
    vc.onKey = { code, down, mods, character in
      gHost?.sendKey(code, down: down, mods: mods, character: character)
    }
    vc.onReleaseAll = { [weak self] in self?.releaseAllKeys() }
    setupMouse()
    vc.onSecondaryClick = { [weak self] in
      self?.clicked = true
      self?.rightHeld = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        self?.rightHeld = false
        self?.clicked = false
      }
    }
    w.rootViewController = vc
    w.makeKeyAndVisible()
    window = w
    attach(in: vc)
    gameVC = vc
    vc.onPauseToggle = { [weak self] in self?.togglePause() }
    onPauseRequest = { [weak self] in self?.togglePause() }
    setupPad()
    installSoftKeyboard(in: vc)
    resignObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.autoSave()
    }
    installOverlay(in: vc)
    vc.focusInput()
  }

  func onVideo(_ data: UnsafeRawPointer?, _ w: UInt32, _ h: UInt32, _ pitch: Int) {
    guard let data = data, w > 0, h > 0 else { return }
    // RETRO_HW_FRAME_BUFFER_VALID ((void *)-1): the core rendered with OpenGL into a context this host doesn't have.
    // There are no pixels to read; dereferencing it crashes. (Cores are told to render in software, see GameRunner.)
    if Int(bitPattern: data) == -1 { return }
    pixelW = Int(w)
    pixelH = Int(h)
    let W = Int(w), H = Int(h)
    var pixels = [UInt8](repeating: 0, count: W * H * 4)
    if fmt == 2 {
      // RETRO_PIXEL_FORMAT_RGB565 (ScummVM's software mode): expand to the 32-bit layout used below (B, G, R, x).
      guard pitch >= W * 2 else { return }
      pixels.withUnsafeMutableBytes { dst in
        guard let out = dst.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
        for y in 0..<H {
          let row = (data + y * pitch).assumingMemoryBound(to: UInt16.self)
          let o = out + y * W
          for x in 0..<W {
            let p = UInt32(row[x])
            let r = (p >> 11) & 0x1F, g = (p >> 5) & 0x3F, b = p & 0x1F
            o[x] = ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2)
          }
        }
      }
    } else {
      pixels.withUnsafeMutableBufferPointer { dst in
        guard let base = dst.baseAddress else { return }
        let rowBytes = min(W * 4, max(pitch, 0))      // never read past a row the core says is shorter
        for y in 0..<H {
          memcpy(base + y * W * 4, data + y * pitch, rowBytes)
        }
      }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: W * 4, space: cs,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent) else { return }
    let img = UIImage(cgImage: cg)
    DispatchQueue.main.async { self.imageView?.image = img }
  }

  func onAudio(_ p: UnsafePointer<Int16>?, _ frames: Int) -> Int {
    guard let p = p, frames > 0 else { return 0 }
    // The rate the core reported (DOSBox Pure: 48000 via its option; ScummVM may use another one).
    if audio == nil { audio = AudioOut(sampleRate: (sampleRate >= 8000 && sampleRate <= 192000) ? sampleRate : 44100) }
    if audio?.started != true { audio?.start() }
    audio?.push(p, frames: frames)
    return frames
  }

  func handleEnv(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
    switch cmd {
    case 10: // SET_PIXEL_FORMAT
      if let p = data { fmt = UInt32(bitPattern: p.assumingMemoryBound(to: Int32.self).pointee) }
      return true
    case 9, 31: // SYSTEM/SAVE DIRECTORY
      if let p = data {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        p.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self).pointee = strdup(dir)
      }
      return true
    case 12: // SET_KEYBOARD_CALLBACK
      if let p = data { kb = p.assumingMemoryBound(to: RetroKbCallback.self).pointee }
      return true
    case 15: // GET_VARIABLE — answer core options we care about
      guard let p = data else { return false }
      let rv = p.assumingMemoryBound(to: RetroVariable.self)
      guard let keyPtr = rv.pointee.key else { return false }
      let key = String(cString: keyPtr)
      if key == "dosbox_pure_audiorate" {
        rv.pointee.value = UnsafePointer(strdup("44100"))
        return true
      }
      if key == "dosbox_pure_aspect_correction" {
        rv.pointee.value = UnsafePointer(strdup("true"))
        return true
      }
      if key == "dosbox_pure_force60fps" || key == "dosbox_pure_forcefps" {
        rv.pointee.value = UnsafePointer(strdup("false"))
        return true
      }
      if key == "dosbox_pure_sblaster_conf" {
        rv.pointee.value = UnsafePointer(strdup(coreOptions[key] ?? sblasterConf))
        return true
      }
      if key == "dosbox_pure_keyboard_layout" {
        rv.pointee.value = UnsafePointer(strdup(Prefs.keyboardLayout))
        return true
      }
      if key == "scummvm_pointer_device" {
        // Trackpad / mouse: relative RetroMouse. Fingers: absolute pointer (tap where you want).
        rv.pointee.value = UnsafePointer(strdup(mouseMode == "virtual" ? "mouse" : "pointer"))
        return true
      }
      if key == "dosbox_pure_mouse_input" {
        // Same rule as before: the Settings style (or the pack's) by default, "virtual" (relative) while a mouse /
        // trackpad / stick is in use, and now also while a finger is the device (see dosTouchChanged).
        rv.pointee.value = UnsafePointer(strdup(mouseMode))
        return true
      }
      if let v = coreOptions[key] {
        rv.pointee.value = UnsafePointer(strdup(v))
        return true
      }
      // Windows 98 setup (the core's "Boot and Install New Operating System"):
      // keep disk changes on the disk image (drivers persist), normal core for stability inside the OS.
      if key == "dosbox_pure_bootos_ramdisk" {
        rv.pointee.value = UnsafePointer(strdup("false"))
        return true
      }
      if key == "dosbox_pure_bootos_dfreespace" {
        rv.pointee.value = UnsafePointer(strdup("1024"))
        return true
      }
      if key == "dosbox_pure_bootos_forcenormal" {
        rv.pointee.value = UnsafePointer(strdup("true"))
        return true
      }
      return false
    case 17: // GET_VARIABLE_UPDATE
      data?.assumingMemoryBound(to: Bool.self).pointee = variablesDirty
      variablesDirty = false
      return true
    case 78: // SET_NETPACKET_INTERFACE: the core's multiplayer transport hook (IPX / modem). NetSession (NetLobby.swift) provides the lobby.
      guard let p = data else { return false }
      NetSession.shared.attach(p.assumingMemoryBound(to: RetroNetpacketCallback.self).pointee, gameTitle: gameTitle)
      return true
    case 27: // GET_LOG_INTERFACE — fill the struct (one function pointer) or say "unsupported"; never claim without filling.
      // Only for cores that need it (ScummVM calls its log callback unchecked); DOSBox Pure works without and stays quiet.
      guard provideLogInterface, let p = data else { return false }
      p.assumingMemoryBound(to: (@convention(c) (Int32, UnsafePointer<CChar>?) -> Void)?.self).pointee = cbLog
      return true
    case 16, 8, 7:
      return true
    default:
      return false
    }
  }
}


extension CoreHost {
  /// Small round buttons in the corner chosen in Settings: pause menu (resume, save slots, restart, quit) and the iOS keyboard.
  func installOverlay(in vc: GameViewController) {
    let showPause = Prefs.overlayEnabled, showKeys = Prefs.keyboardButton
    guard showPause || showKeys else { return }
    let view: UIView = vc.view
    let g = view.safeAreaLayoutGuide
    let corner = Prefs.overlayCorner
    let right = !corner.hasSuffix("l"), top = corner.hasPrefix("t")

    func make(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
      var cfg = UIButton.Configuration.filled()
      cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
      cfg.cornerStyle = .capsule
      cfg.baseBackgroundColor = UIColor(white: 0.04, alpha: 0.6)
      cfg.baseForegroundColor = .white
      let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
      b.alpha = 0.75
      b.translatesAutoresizingMaskIntoConstraints = false
      b.accessibilityLabel = label
      view.addSubview(b)
      NSLayoutConstraint.activate([
        b.widthAnchor.constraint(equalToConstant: 40),
        b.heightAnchor.constraint(equalToConstant: 40),
        top ? b.topAnchor.constraint(equalTo: g.topAnchor, constant: 12)
            : b.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
      ])
      return b
    }

    var previous: UIButton?
    func place(_ b: UIButton) {
      if let p = previous {
        b.trailingAnchor.constraint(equalTo: p.leadingAnchor, constant: -8).isActive = right
        b.leadingAnchor.constraint(equalTo: p.trailingAnchor, constant: 8).isActive = !right
      } else if right {
        b.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12).isActive = true
      } else {
        b.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12).isActive = true
      }
      previous = b
    }

    if showPause { place(make("pause.fill", "Pause menu") { [weak self] in self?.togglePause() }) }
    if showKeys { place(make("keyboard", "Keyboard") { [weak vc] in vc?.toggleSoftKeyboard() }) }
  }

  func toast(_ text: String, in vc: UIViewController, seconds: Double = 1.4) {
    let l = PaddedLabel()
    l.text = text
    l.numberOfLines = 0
    l.textAlignment = .center
    l.textColor = .white
    l.font = .systemFont(ofSize: 13, weight: .semibold)
    l.backgroundColor = UIColor(white: 0.04, alpha: 0.8)
    l.layer.cornerRadius = 12
    l.clipsToBounds = true
    l.translatesAutoresizingMaskIntoConstraints = false
    vc.view.addSubview(l)
    NSLayoutConstraint.activate([
      l.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
      l.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 16),
    ])
    l.widthAnchor.constraint(lessThanOrEqualTo: vc.view.widthAnchor, constant: -32).isActive = true
    UIView.animate(withDuration: 0.25, delay: seconds, options: []) { l.alpha = 0 } completion: { _ in l.removeFromSuperview() }
  }

  func installControls(in view: UIView) {
    let keys: [(String, UInt32)] = [
      ("ESC", 27), ("TAB", 9), ("ENT", 13), ("SPC", 32),
      ("\u{2190}", 276), ("\u{2191}", 273), ("\u{2193}", 274), ("\u{2192}", 275),
    ]
    let bar = UIStackView()
    bar.axis = .horizontal
    bar.spacing = 6
    bar.distribution = .fillEqually
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.backgroundColor = UIColor(white: 0.05, alpha: 0.72)
    bar.layer.cornerRadius = 14
    bar.isLayoutMarginsRelativeArrangement = true
    bar.layoutMargins = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

    for (title, code) in keys {
      let b = UIButton(type: .system)
      b.setTitle(title, for: .normal)
      b.setTitleColor(.white, for: .normal)
      b.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
      b.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
      b.addTarget(self, action: #selector(keyUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
      b.accessibilityIdentifier = String(code)
      bar.addArrangedSubview(b)
    }

    let right = UIButton(type: .system)
    right.setTitle("R", for: .normal)
    right.setTitleColor(.white, for: .normal)
    right.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
    right.addTarget(self, action: #selector(rightDown), for: .touchDown)
    right.addTarget(self, action: #selector(rightUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    bar.addArrangedSubview(right)

    let exit = UIButton(type: .system)
    exit.setTitle("\u{2715}", for: .normal)
    exit.setTitleColor(UIColor(red: 1, green: 0.45, blue: 0.4, alpha: 1), for: .normal)
    exit.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
    exit.addTarget(self, action: #selector(exitGame), for: .touchUpInside)
    bar.addArrangedSubview(exit)

    view.addSubview(bar)
    var constraints = [
      bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
      bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
      bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
      bar.heightAnchor.constraint(equalToConstant: 40),
    ]
    // Game picture sits above the control bar instead of underneath it.
    if let iv = imageView {
      constraints += [
        iv.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
        iv.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        iv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        iv.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
      ]
    }
    NSLayoutConstraint.activate(constraints)
  }

  @objc func exitGame() {
    DispatchQueue.main.async { GameRunner.shared.stop() }
  }

  @objc func keyDown(_ sender: UIButton) {
    if let c = UInt32(sender.accessibilityIdentifier ?? "") { sendKey(c, down: true) }
  }

  @objc func keyUp(_ sender: UIButton) {
    if let c = UInt32(sender.accessibilityIdentifier ?? "") { sendKey(c, down: false) }
  }

  @objc func rightDown() { rightHeld = true }
  @objc func rightUp() { rightHeld = false }
}
