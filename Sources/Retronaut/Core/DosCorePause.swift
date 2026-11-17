import UIKit
import SwiftUI

/// Pause menu: freezes the core, shows a glass panel with resume / save slots / restart / quit.
extension CoreHost {
  func togglePause() {
    if paused { hidePause() } else { showPause() }
  }

  func showPause() {
    guard !paused, let vc = gameVC else { return }
    paused = true
    link?.isPaused = true
    vc.inputBlocked = true
    vc.setSoftKeyboard(false)
    releaseAllKeys()
    releasePad()

    let id = gameId
    let model = PauseModel(title: gameTitle.isEmpty ? "DOS Game" : gameTitle) { StateStore.info(id) }
    model.multiplayerAvailable = NetSession.shared.available && GameRunner.shared.osSession == nil && !GameRunner.isWindowsPack(id)
    model.lobbyGameTitle = gameTitle
    model.onResume = { [weak self] in self?.hidePause() }
    model.onSave = { [weak self] slot in
      guard let self else { return "" }
      switch self.saveState(slot: slot) {
      case .ok: return "Saved to Slot \(slot)"
      case .failed: return "Couldn't write the save"
      case .multiplayer: return "Saving is off during multiplayer"
      default: return "Save states aren't available for this game"
      }
    }
    model.onLoad = { [weak self] slot in
      guard let self else { return nil }
      switch self.loadState(slot: slot) {
      case .ok: self.hidePause(); return nil
      case .noSave: return "Nothing saved there yet"
      case .multiplayer: return "Loading is off during multiplayer"
      default: return "Couldn't load that save"
      }
    }
    model.onReset = { [weak self] in
      guard let self else { return }
      self.resetFn?()
      self.framesRun = 0
      self.hidePause()
    }
    model.onQuit = {
      DispatchQueue.main.async { GameRunner.shared.stop(autosave: true) }
    }

    let hc = UIHostingController(rootView: PauseMenuView(model: model))
    hc.view.backgroundColor = .clear
    hc.view.translatesAutoresizingMaskIntoConstraints = false
    vc.addChild(hc)
    vc.view.addSubview(hc.view)
    NSLayoutConstraint.activate([
      hc.view.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
      hc.view.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
      hc.view.topAnchor.constraint(equalTo: vc.view.topAnchor),
      hc.view.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
    ])
    hc.didMove(toParent: vc)
    pauseHost = hc
  }

  func hidePause() {
    guard paused else { return }
    removePauseUI()
    paused = false
    link?.isPaused = false
    gameVC?.inputBlocked = false
    // drop any movement that piled up while the menu was open
    pendDX = 0; pendDY = 0; pendWheel = 0
    gameVC?.focusInput()
  }

  func removePauseUI() {
    guard let hc = pauseHost else { return }
    hc.willMove(toParent: nil)
    hc.view.removeFromSuperview()
    hc.removeFromParent()
    pauseHost = nil
  }
}
