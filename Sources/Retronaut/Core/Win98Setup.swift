import Foundation
import UIKit

/// Drives the Windows 98 life cycle the UI shows: first-run offer, setup, export, import, reset.
final class Win98Setup: ObservableObject {
    /// Windows 98 (the default shared disk) and Windows 3.1 use the same controller, one per profile.
    static let shared = Win98Setup(profile: BaseOS.win98)
    static let shared31 = Win98Setup(profile: BaseOS.win31)
    static let shared95 = Win98Setup(profile: BaseOS.win95)
    static func controller(for p: BaseOS.Profile) -> Win98Setup {
        switch p.id {
        case BaseOS.win31.id: return shared31
        case BaseOS.win95.id: return shared95
        default: return shared
        }
    }
    let profile: BaseOS.Profile

    enum Phase: Equatable {
        case intro                  // "Set up Windows 98?"
        case review                 // setup was closed: did it finish?
        case working(String)
        case done(String)
        case failed(String)
    }

    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    @Published var showSheet = false
    @Published var phase: Phase = .intro
    @Published private(set) var installed = false
    @Published private(set) var hasMedia = false
    @Published var shareItem: ShareItem?
    @Published private(set) var hookStatus = ""

    private var askedKey: String { "\(profile.id).firstRunAsked" }
    private init(profile: BaseOS.Profile) {
        self.profile = profile
        self.installed = BaseOS.isReady(profile)
        self.hasMedia = BaseOS.installMedia(profile) != nil
    }

    func refresh() {
        // A disk shipped inside the app counts as "installed": copy it into place on first look.
        if !BaseOS.isInstalled(profile) { _ = BaseOS.provision(profile) }
        installed = BaseOS.isReady(profile)
        hasMedia = BaseOS.installMedia(profile) != nil
    }

    /// Writes the autorun hook + fast-boot settings into the disk (idempotent) and remembers the result for Settings.
    func applyHooks() {
        guard BaseOS.isReady(profile), GameRunner.shared.osSession == nil else { return }
        let p = profile
        DispatchQueue.global(qos: .utility).async {
            let status = BaseOS.applyHooks(p)
            DispatchQueue.main.async { self.hookStatus = status }
        }
    }

    // MARK: Entry points

    /// App launch: use the disk shipped with the app if there is one, otherwise offer setup once.
    func launchCheck() {
        if BaseOS.provision(self.profile) { refresh(); return }
        refresh()
        if !installed, !UserDefaults.standard.bool(forKey: askedKey) {
            phase = .intro
            showSheet = true
        }
    }

    func present() {
        refresh()
        phase = BaseOS.setupPending(profile) ? .review : .intro
        showSheet = true
    }

    func notNow() {
        UserDefaults.standard.set(true, forKey: askedKey)
        showSheet = false
    }

    // MARK: Setup

    func chooseMedia(_ url: URL) {
        phase = .working("Copying the \(profile.title) install image…")
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String?
            do { try BaseOS.importMedia(url, into: self.profile) } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                self.refresh()
                self.phase = err.map { Phase.failed($0) } ?? .intro
            }
        }
    }

    /// Opens the emulator on the Windows 98 CD with the Windows 98 hardware profile.
    func startSetup() {
        UserDefaults.standard.set(true, forKey: askedKey)
        showSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let failure = GameRunner.shared.startInstall(profile: self.profile) {
                self.phase = .failed(failure)
                self.showSheet = true
            }
        }
    }

    /// Called by GameRunner when an OS session ends.
    func sessionEnded(_ kind: GameRunner.OSSession) {
        refresh()
        guard kind == .install else { return }
        phase = .review
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showSheet = true }
    }

    /// "Yes, Windows 98 reached the desktop": expand the disk the installer wrote into the working disk.
    func finishSetup() {
        phase = .working("Saving your \(profile.title) disk…")
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String?
            do { try BaseOS.finishInstall(self.profile) } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                self.refresh()
                self.phase = err.map { Phase.failed($0) } ?? .done("\(self.profile.title) is ready. Games on the shared disk start from here.")
            }
        }
    }

    // MARK: Maintenance, export, import, reset

    /// Windows 98 desktop with the Windows 98 CD attached (drivers, tweaks).
    func openDesktop() {
        showSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let failure = GameRunner.shared.startMaintenance(profile: self.profile) {
                self.phase = .failed(failure)
                self.showSheet = true
            }
        }
    }

    func export() {
        phase = .working("Compacting and zipping the disk…")
        showSheet = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try BaseOS.prepareExport(self.profile)
                DispatchQueue.main.async {
                    self.showSheet = false
                    self.shareItem = ShareItem(url: url)
                }
            } catch {
                DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func importDisk(_ url: URL) {
        phase = .working("Importing the \(profile.title) disk…")
        showSheet = true
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String?
            do { try BaseOS.importImage(url, into: self.profile) } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                self.refresh()
                self.phase = err.map { Phase.failed($0) } ?? .done("\(self.profile.title) disk imported.")
            }
        }
    }

    /// Settings → Reset: delete the Windows 98 disk. With a disk shipped inside the app it is restored from there,
    /// otherwise setup starts again from scratch.
    func reset() {
        do {
            try BaseOS.reset(self.profile)
            UserDefaults.standard.removeObject(forKey: askedKey)
            if BaseOS.provision(self.profile), BaseOS.isReady(self.profile) {
                refresh()
                phase = .done("\(self.profile.title) was reset to the disk that ships with the app.")
            } else {
                refresh()
                phase = .intro
            }
        } catch {
            refresh()
            phase = .failed(error.localizedDescription)
        }
        showSheet = true
    }
}
