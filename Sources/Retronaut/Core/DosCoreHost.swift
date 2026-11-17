import UIKit
import QuartzCore
import Foundation
import GameController

// libretro ABI (minimal subset)
typealias EnvCB = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
typealias VideoCB = @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void
typealias AudioBatchCB = @convention(c) (UnsafePointer<Int16>?, Int) -> Int
typealias KbEventCB = @convention(c) (Bool, UInt32, UInt32, UInt16) -> Void
struct RetroVariable {
  var key: UnsafePointer<CChar>?
  var value: UnsafePointer<CChar>?
}

struct RetroKbCallback { var keyboard_event: KbEventCB? }
typealias InputPollCB = @convention(c) () -> Void
typealias InputStateCB = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16
typealias InitCB = @convention(c) () -> Void
typealias KeyboardEventCB = @convention(c) (Bool, UInt32, UInt16) -> Void
typealias DeinitCB = @convention(c) () -> Void
typealias ApiVersionCB = @convention(c) () -> UInt32
typealias GetSystemInfoCB = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias GetAvInfoCB = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias SetEnvCB = @convention(c) (EnvCB?) -> Void
typealias SetVideoCB = @convention(c) (VideoCB?) -> Void
typealias SetAudioBatchCB = @convention(c) (AudioBatchCB?) -> Void
typealias SetInputPollCB = @convention(c) (InputPollCB?) -> Void
typealias SetInputStateCB = @convention(c) (InputStateCB?) -> Void
typealias LoadGameCB = @convention(c) (UnsafeRawPointer?) -> Bool
typealias RunCB = @convention(c) () -> Void
typealias UnloadCB = @convention(c) () -> Void
typealias SerializeSizeCB = @convention(c) () -> Int
typealias SerializeCB = @convention(c) (UnsafeMutableRawPointer?, Int) -> Bool

struct RetroGameInfo {
  var path: UnsafePointer<CChar>?
  var data: UnsafeRawPointer?
  var size: Int
  var meta: UnsafePointer<CChar>?
}

var gHost: CoreHost?

/// Single active core session (one game at a time).
final class CoreHost: NSObject {
  var handle: UnsafeMutableRawPointer?
  var run: RunCB?
  var load: LoadGameCB?
  var unload: UnloadCB?
  var deinitCore: DeinitCB?
  var setEnv: SetEnvCB?
  var setVideo: SetVideoCB?
  var initCore: InitCB?
  var setAudio: SetAudioBatchCB?
  var setInputPoll: SetInputPollCB?
  var setInputState: SetInputStateCB?

  var serializeSize: SerializeSizeCB?
  var serializeFn: SerializeCB?
  var unserializeFn: SerializeCB?
  var resetFn: UnloadCB?
  var gameId = ""
  var gameTitle = ""

  // Runtime / UI state
  weak var gameVC: GameViewController?
  var pauseHost: UIViewController?
  var paused = false
  var framesRun = 0
  var pendingLoadSlot: Int?
  var onPauseRequest: (() -> Void)?
  var resignObserver: NSObjectProtocol?

  // Gamepad
  var padKeys = Set<UInt32>()
  var padLeft = false
  var padRight = false
  var padObservers: [NSObjectProtocol] = []

  var getAvInfo: GetAvInfoCB?
  var fps: Double = 60
  var sampleRate: Double = 48000

  var pixelW = 320
  var pixelH = 200
  var fmt: UInt32 = 0

  var touchX: Int16 = 160

  /// Hardware keyboard state (index = RETROK code).
  var keyState = [Bool](repeating: false, count: 512)
  var keyboardCb: KeyboardEventCB?

  /// DOSBox Pure registers a keyboard callback (SET_KEYBOARD_CALLBACK) and only registers
  /// key-DOWN events through it; polling input_state is used just to detect releases.
  /// So every key must be pushed through that callback, and mirrored into keyState.
  /// `character` = the typed Unicode character (ScummVM needs it for text entry; DOSBox Pure ignores it).
  func sendKey(_ code: UInt32, down: Bool, mods: UInt16 = 0, character: UInt32 = 0) {
    var sent = code, mods = mods
    if isScummVM {
      // ScummVM's libretro backend takes the typed character from the key code itself (ascii = keycode, shift only
      // upper-cases a-z). So a shifted symbol ("!" = Shift+1) is sent as that symbol's own code. The mapping is
      // remembered per physical key so the release matches even if Shift is let go first.
      if down {
        let isLetter = (65...90).contains(character) || (97...122).contains(character)
        if character >= 33, character < 127, !isLetter, character != code { sent = character; mods &= ~1 }
        scummKeyMap[code] = sent
      } else {
        sent = scummKeyMap.removeValue(forKey: code) ?? code
      }
    }
    keyState[Int(sent) & 511] = down
    kb?.keyboard_event?(down, sent, character, mods)
  }
  func releaseAllKeys() {
    for i in 0..<keyState.count where keyState[i] {
      keyState[i] = false
      kb?.keyboard_event?(false, UInt32(i), 0, 0)
    }
    scummKeyMap.removeAll()
    hwLeft = false; hwRight = false; hwMiddle = false
  }

  /// DOSBox Pure ignores relative mouse movement in "pad" (touchpad) mode, which is the
  /// touch-friendly default. With a real mouse/trackpad we switch to "virtual".
  /// Starts in the touch mode from Settings; flips to "virtual" while a mouse/trackpad/stick
  /// is the last-used device and back as soon as a finger touches the screen.
  var mouseMode = Prefs.touchMode   // GameRunner may switch it via baseTouchMode before the core opens
  var variablesDirty = false

  // Direct finger touches (raw UITouch, see TouchSurface).
  var inputIsMouse = false                 // last-used pointing device: mouse/trackpad/stick vs finger
  var fingerCount = 0
  var pressUntil: CFTimeInterval = 0       // keeps very short taps visible to the core for a few frames
  var leftSuppressed = false               // right-click gesture in progress: no left press
  var touchOrigin = CGPoint.zero
  var longPress: DispatchWorkItem?

  /// Left button / pointer "pressed" coming from fingers or UIKit pointer taps.
  var touchPressed: Bool {
    if leftSuppressed { return false }
    return fingerCount > 0 || clicked || CACurrentMediaTime() < pressUntil
  }

  /// libretro pointer 0. In touchpad mode the core does the gestures itself (drag, tap, two-finger tap, press-and-hold),
  /// so it must see the raw finger, not our synthesised click handling.
  var pointer0Pressed: Bool {
    if mouseMode == "pad" || isScummVM { return fingerCount > 0 || clicked || CACurrentMediaTime() < pressUntil }
    return touchPressed
  }
  /// libretro pointer 1: a real second finger, or a synthesised right click.
  var pointer1Pressed: Bool { fingerCount >= 2 || rightHeld }
  var pointerCount: Int16 { pointer1Pressed ? 2 : (pointer0Pressed ? 1 : 0) }

  // Hardware mouse / trackpad (GCMouse): relative movement, buttons, wheel.
  var pendDX: CGFloat = 0
  var pendDY: CGFloat = 0
  var pendWheel: CGFloat = 0
  var latchDX: Int16 = 0
  var latchDY: Int16 = 0
  var latchWheelUp = false
  var latchWheelDown = false
  var hwLeft = false
  var hwRight = false
  var hwMiddle = false
  // Tap-to-click presses can be released before the next emulated frame; keep them visible briefly.
  var hwLeftUntil: CFTimeInterval = 0
  var hwRightUntil: CFTimeInterval = 0
  var hwMiddleUntil: CFTimeInterval = 0
  var hwLeftDown: Bool { hwLeft || CACurrentMediaTime() < hwLeftUntil }
  var hwRightDown: Bool { hwRight || CACurrentMediaTime() < hwRightUntil }
  var hwMiddleDown: Bool { hwMiddle || CACurrentMediaTime() < hwMiddleUntil }
  var mouseBound = false
  var mouseObservers: [NSObjectProtocol] = []

  func latchInput() {
    pollPad()
    if !pendDX.isFinite { pendDX = 0 }
    if !pendDY.isFinite { pendDY = 0 }
    let ix = max(-32000, min(32000, pendDX.rounded(.towardZero)))
    let iy = max(-32000, min(32000, pendDY.rounded(.towardZero)))
    pendDX -= ix; pendDY -= iy
    latchDX = Int16(ix)
    latchDY = Int16(iy)
    latchWheelUp = false; latchWheelDown = false
    if !Prefs.scrollWheel { pendWheel = 0 }
    else if pendWheel >= 1 { latchWheelUp = true; pendWheel -= 1 }
    else if pendWheel <= -1 { latchWheelDown = true; pendWheel += 1 }
    pendWheel = max(-8, min(8, pendWheel))
  }
  func setKey(_ code: UInt32, down: Bool) {
    let i = Int(code) & 511
    keyState[i] = down
  }
  var touchY: Int16 = 100
  // Second finger (libretro pointer index 1). The core reads each pointer by index: without this a single finger
  // looked like two (a permanent ghost right-click), which is what broke touch on iPhone.
  // Software (iOS) keyboard
  var softMods: UInt16 = 0                 // sticky Ctrl / Alt / Shift from the keyboard bar (RETROKMOD bits)
  // DOSBox touch (finger -> relative mouse, see dosTouchChanged)
  var hovering = false                      // iPadOS pointer hovering over the picture (UIKit fallback, no GCMouse)
  var padFingers = 0
  var padPeak = 0
  var padDown: CFTimeInterval = 0
  var padMoved: CGFloat = 0
  var padLast = CGPoint.zero
  var padLongFired = false
  var padDragging = false
  var padTapEndedAt: CFTimeInterval = 0
  var padHold = CGPoint.zero                // movement inside the tap slop, not yet applied
  var padArmed = false                      // the finger left the tap slop: cursor follows it
  var scummKeyMap: [UInt32: UInt32] = [:]   // ScummVM: physical key -> code actually sent (see sendKey)
  var kbQueueTime: CFTimeInterval = 0      // when the next typed character may start
  var kbObserver: NSObjectProtocol?
  var imageBottom: NSLayoutConstraint?     // game picture bottom edge: moves up when the keyboard is shown
  var touchX2: Int16 = 0
  var touchY2: Int16 = 0
  var touched = false
  var clicked = false
  var rightHeld = false
  var sblasterConf = "A220 I5 D1 H5"
  /// Per-game settings from game.json (imported packs): on-screen key bar, touch mode, DOSBox Pure options.
  var gameKeys: Set<UInt32> = []        // keys the game needs (game.json "keys"): always reachable from a hardware keyboard
  var touchModeOverride: String?
  var coreOptions: [String: String] = [:]
  /// Answer RETRO_ENVIRONMENT_GET_LOG_INTERFACE (ScummVM needs it; it calls the callback without a nil check).
  var provideLogInterface = false
  /// ScummVM: pointer device is chosen by input source, keys carry their character, touchpad style is not used.
  var isScummVM = false
  /// Last line a core logged (shown in launch errors).
  static var lastCoreLog = ""
  var baseTouchMode: String { touchModeOverride ?? Prefs.touchMode }

  var kb: RetroKbCallback?
  var link: CADisplayLink?
  /// Fractional frame carried between display callbacks so the core averages exactly 1/fps.
  var paceAccum: Double = 0
  var imageView: UIImageView?
  var window: UIWindow?
  var audio: AudioOut?

  func open(corePath: String, contentPath: String) -> Bool {
    guard let h = dlopen(corePath, RTLD_NOW) else { return false }
    handle = h
    func sym<T>(_ name: String, _ t: T.Type) -> T? {
      guard let s = dlsym(h, name) else { return nil }
      return unsafeBitCast(s, to: T.self)
    }
    load = sym("retro_load_game", LoadGameCB.self)
    run = sym("retro_run", RunCB.self)
    unload = sym("retro_unload_game", UnloadCB.self)
    deinitCore = sym("retro_deinit", DeinitCB.self)
    initCore = sym("retro_init", InitCB.self)
    getAvInfo = sym("retro_get_system_av_info", GetAvInfoCB.self)
    setEnv = sym("retro_set_environment", SetEnvCB.self)
    setVideo = sym("retro_set_video_refresh", SetVideoCB.self)
    setAudio = sym("retro_set_audio_sample_batch", SetAudioBatchCB.self)
    setInputPoll = sym("retro_set_input_poll", SetInputPollCB.self)
    setInputState = sym("retro_set_input_state", SetInputStateCB.self)
    serializeSize = sym("retro_serialize_size", SerializeSizeCB.self)
    serializeFn = sym("retro_serialize", SerializeCB.self)
    unserializeFn = sym("retro_unserialize", SerializeCB.self)
    resetFn = sym("retro_reset", UnloadCB.self)
    guard let loadFn = load, let runFn = run, let envFn = setEnv else { return false }

    gHost = self
    envFn(cbEnv)
    setVideo?(cbVideo)
    setAudio?(cbAudioBatch)
    setInputPoll?(cbInputPoll)
    setInputState?(cbInputState)
    initCore?()

    var ok = false
    contentPath.withCString { cstr in
      var g = RetroGameInfo(path: cstr, data: nil, size: 0, meta: nil)
      withUnsafePointer(to: &g) { p in
        ok = loadFn(UnsafeRawPointer(p))
      }
    }
    guard ok else { return false }

    // retro_system_av_info: geometry (4*u32 + float, padded to 24) then fps, sample_rate (doubles)
    if let getAv = getAvInfo {
      var raw = [UInt8](repeating: 0, count: 64)
      raw.withUnsafeMutableBytes { p in
        getAv(p.baseAddress)
        let f = p.loadUnaligned(fromByteOffset: 24, as: Double.self)
        let sr = p.loadUnaligned(fromByteOffset: 32, as: Double.self)
        if f > 1 && f < 250 { fps = f }
        if sr >= 8000 && sr <= 192000 { sampleRate = sr }
      }
    }
    self.runFn = runFn
    return true
  }

  var runFn: RunCB?

  // MARK: Save states (libretro serialize): 4 slots + auto-save per game

  enum StateResult { case ok, unsupported, noSave, failed, multiplayer }

  /// False for Windows 98 sessions: a whole PC's state can't be saved or restored reliably (see GameRunner.isWindowsPack).
  var statesEnabled = true

  /// Must run on the main thread while the core is not mid-frame (it is paused or between display-link ticks).
  func saveState(slot: Int) -> StateResult {
    if NetSession.shared.sessionActive { return .multiplayer }      // a multiplayer session can't be rewound or forked
    guard statesEnabled else { return .unsupported }
    guard let sizeFn = serializeSize, let ser = serializeFn else { return .unsupported }
    let size = sizeFn()
    guard size > 0 else { return .unsupported }
    var data = Data(count: size)
    let ok = data.withUnsafeMutableBytes { ser($0.baseAddress, size) }
    guard ok else { return .unsupported }
    StateStore.ensureDir(gameId)
    do {
      try data.write(to: StateStore.stateURL(gameId, slot), options: .atomic)
      if let jpg = imageView?.image?.jpegData(compressionQuality: 0.8) {
        try? jpg.write(to: StateStore.thumbURL(gameId, slot), options: .atomic)
      }
      return .ok
    } catch { return .failed }
  }

  func loadState(slot: Int) -> StateResult {
    if NetSession.shared.sessionActive { return .multiplayer }
    guard statesEnabled else { return .unsupported }
    guard let unser = unserializeFn else { return .unsupported }
    guard let data = try? Data(contentsOf: StateStore.stateURL(gameId, slot)), !data.isEmpty else { return .noSave }
    let ok = data.withUnsafeBytes { unser(UnsafeMutableRawPointer(mutating: $0.baseAddress), data.count) }
    releaseAllKeys()
    return ok ? .ok : .failed
  }

  /// Saves the auto slot, but not while the game is still booting (would overwrite a good one).
  func autoSave() {
    guard statesEnabled, !NetSession.shared.sessionActive, framesRun > 180 else { return }
    _ = saveState(slot: 0)
  }
}
