import UIKit
import Foundation

// Top-level C callbacks. They touch the single active host through gHost,
// which keeps them free of captures and safe for @convention(c).

/// libretro log callback (`retro_log_printf_t` is C-variadic: `void (*)(level, fmt, ...)`). Only the two fixed arguments are
/// read: on arm64 they arrive in x0 / x1 exactly as for a non-variadic function, the variadic ones sit on the stack and are
/// ignored, so `fmt` is logged un-expanded. Cores such as ScummVM call their log callback WITHOUT a nil check in error
/// paths (game not found, bad path, ...): answering GET_LOG_INTERFACE with "unsupported" makes those paths jump to address 0.
let cbLog: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { level, fmt in
  guard let fmt else { return }
  let text = String(cString: fmt).trimmingCharacters(in: .whitespacesAndNewlines)
  CoreHost.lastCoreLog = text
  NSLog("core[%d]: %@", level, text)
}

func cbEnv(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
  guard let host = gHost else { return false }
  return host.handleEnv(cmd, data)
}

func cbVideo(_ data: UnsafeRawPointer?, _ w: UInt32, _ h: UInt32, _ pitch: Int) {
  gHost?.onVideo(data, w, h, pitch)
}

func cbAudioBatch(_ data: UnsafePointer<Int16>?, _ frames: Int) -> Int {
  guard let host = gHost else { return 0 }
  return host.onAudio(data, frames)
}

func cbInputPoll() {
  // Once per frame: freeze the relative mouse movement / wheel accumulated since last frame.
  gHost?.latchInput()
}

func cbInputState(_ port: UInt32, _ device: UInt32, _ index: UInt32, _ id: UInt32) -> Int16 {
  guard let host = gHost else { return 0 }
  if device == 3 { // RETRO_DEVICE_KEYBOARD
    let i = Int(id) & 511
    return host.keyState[i] ? 1 : 0
  }
  if device == 2 { // RETRO_DEVICE_MOUSE
    switch id {
    case 0: return host.latchDX                                        // X (relative)
    case 1: return host.latchDY                                        // Y (relative)
    case 2: // left (or right when buttons are swapped)
      // A finger is a mouse button only in "direct" mode. In touchpad mode the core reads the pointer itself (a finger-down
      // "button" there would turn every drag into a drag-select); in "virtual" mode the finger is not a button at all.
      let t = host.mouseMode == "direct" && host.touchPressed
      let l = host.hwLeftDown || t || host.padLeft, r = host.hwRightDown || host.rightHeld || host.padRight
      return (Prefs.swapButtons ? r : l) ? 1 : 0
    case 3:
      let t = host.mouseMode == "direct" && host.touchPressed
      let l = host.hwLeftDown || t || host.padLeft, r = host.hwRightDown || host.rightHeld || host.padRight
      return (Prefs.swapButtons ? l : r) ? 1 : 0
    case 4: return host.latchWheelUp ? 1 : 0                           // wheel up
    case 5: return host.latchWheelDown ? 1 : 0                         // wheel down
    case 6: return host.hwMiddleDown ? 1 : 0                              // middle
    default: return 0
    }
  }
  if device == 6 { // RETRO_DEVICE_POINTER (index = finger number)
    // Like RetroArch: while nothing touches the screen, X, Y and PRESSED are all 0. DOSBox Pure treats any non-zero
    // X / Y / PRESSED on pointer 0 as "a finger is down", so reporting the last position (as before) meant a finger
    // that never lifted: no tap, no drag, nothing.
    let idx = Int(index)
    let down0 = host.pointer0Pressed
    let down1 = host.pointer1Pressed
    switch id {
    case 0: return idx == 0 ? (down0 || host.hovering ? host.touchX : 0) : (idx == 1 && down1 ? host.touchX2 : 0)   // X
    case 1: return idx == 0 ? (down0 || host.hovering ? host.touchY : 0) : (idx == 1 && down1 ? host.touchY2 : 0)   // Y
    case 2: return (idx == 0 ? down0 : (idx == 1 && down1)) ? 1 : 0                                  // PRESSED
    case 3: return host.pointerCount                                                                  // COUNT
    default: return 0
    }
  }
  return 0
}
