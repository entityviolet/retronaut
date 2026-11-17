import SwiftUI
import UniformTypeIdentifiers

/// Mouse, keyboard and in-game overlay settings. Values live in UserDefaults (see Prefs)
/// and are read by the emulator layer when a game starts.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Prefs.Key.mouseSpeed) private var mouseSpeed = 1.5
    @AppStorage(Prefs.Key.swapButtons) private var swapButtons = false
    @AppStorage(Prefs.Key.scrollWheel) private var scrollWheel = true
    @AppStorage(Prefs.Key.lockPointer) private var lockPointer = true
    @AppStorage(Prefs.Key.cmdFKeys) private var cmdFKeys = true
    @AppStorage(Prefs.Key.keyboardLayout) private var layout = "us"
    @AppStorage(Prefs.Key.escShortcut) private var escShortcut = true
    @AppStorage(Prefs.Key.tildeEsc) private var tildeEsc = false
    @AppStorage(Prefs.Key.touchMode) private var touchMode = "direct"
    @AppStorage(Prefs.Key.pointerInput) private var pointerInput = "both"
    @AppStorage(Prefs.Key.overlayEnabled) private var overlayEnabled = true
    @AppStorage(Prefs.Key.overlayCorner) private var overlayCorner = "tr"
    @AppStorage(Prefs.Key.keyboardButton) private var keyboardButton = true
    @AppStorage(Prefs.Key.padEnabled) private var padEnabled = true
    @AppStorage(Prefs.Key.padStickMouse) private var padStickMouse = true
    @AppStorage(Prefs.Key.padLayout) private var padLayout = "classic"

    @ObservedObject private var library = Library.shared
    @State private var importTarget: ImportTarget?
    @State private var removing: Game?
    @ObservedObject private var win98 = Win98Setup.shared
    @ObservedObject private var win31 = Win98Setup.shared31
    @ObservedObject private var win95 = Win98Setup.shared95
    @State private var confirmOSReset = false
    @State private var pickImage = false
    @State private var confirmOSReset31 = false
    @State private var pickImage31 = false
    @State private var importedPage = 0
    @State private var confirmOSReset95 = false
    @State private var pickImage95 = false
    @State private var showLog = false

    private var importedGames: [Game] { library.games.filter { $0.isImported } }

    /// Imported games are listed 10 per page: with 40+ packs the settings sheet became one endless scroll.
    private static let importedPageSize = 10
    private var importedPageCount: Int { max(1, (importedGames.count + Self.importedPageSize - 1) / Self.importedPageSize) }
    private var importedPageItems: [Game] {
        let start = min(importedPage, importedPageCount - 1) * Self.importedPageSize
        return Array(importedGames.dropFirst(start).prefix(Self.importedPageSize))
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                topBar.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        gamesCard
                        windowsCard
                        win95Card
                        win31Card
                        card("DIAGNOSTICS", icon: "doc.text.magnifyingglass") {
                            Text("Every launch (pack, Windows 95/98/3.1) is written to Documents/retronaut.log with the exact DOS script and the mounted drives.")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                            Button {
                                showLog = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "list.bullet.rectangle").font(.system(size: 13, weight: .heavy))
                                    Text("LAUNCH LOG").font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(1)
                                }
                                .foregroundStyle(.black)
                                .padding(.vertical, 13).frame(maxWidth: .infinity)
                                .background(Capsule().fill(Theme.accent))
                            }
                            .buttonStyle(PressableStyle())
                        }
                        mouseCard
                        keyboardCard
                        gamepadCard
                        overlayCard
                        Button(role: .destructive) { Prefs.reset() } label: {
                            Text("RESET TO DEFAULTS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.vertical, 12).frame(maxWidth: .infinity)
                        }
                        Text("Changes apply the next time you start a game.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 20).padding(.bottom, 30)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { win98.applyHooks(); win31.applyHooks() }
        .sheet(item: $importTarget) { t in ImportGameView(editId: t.editId) }
        .sheet(isPresented: $showLog) { LaunchLogView() }
        .confirmationDialog("Remove \(removing?.title ?? "game")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove game and its saves", role: .destructive) {
                if let g = removing { ImportedStore.delete(g.id) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Deletes the files, save states and play history. This can't be undone.")
        }
    }

    // MARK: My games

    private var gamesCard: some View {
        card("MY GAMES", icon: "plus.rectangle.on.folder.fill") {
            Button { importTarget = ImportTarget(editId: nil) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .heavy))
                    Text("IMPORT A GAME").font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(1)
                }
                .foregroundStyle(.black)
                .padding(.vertical, 13).frame(maxWidth: .infinity)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(PressableStyle())

            if importedGames.isEmpty {
                Text("Add your own DOS games: pick the files, set how to launch them, add a cover. They appear in the library with save states and the pause menu.")
                    .font(subFont).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(importedPageItems) { g in
                    divider
                    HStack(spacing: 12) {
                        Group {
                            if let c = resourceImage(g.id, "jpg", subdir: "posters") {
                                Image(uiImage: c).resizable().scaledToFill().scaleEffect(1.18).clipped()
                            } else { Theme.card }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.title).font(rowFont).foregroundStyle(.white).lineLimit(1)
                            Text("\(String(g.year)) · \(g.engine)").font(subFont).foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        Button { importTarget = ImportTarget(editId: g.id) } label: {
                            Image(systemName: "pencil").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 34, height: 34).background(Circle().fill(Theme.card))
                        }.buttonStyle(.plain).accessibilityLabel("Edit \(g.title)")
                        Button { removing = g } label: {
                            Image(systemName: "trash").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                                .frame(width: 34, height: 34).background(Circle().fill(Theme.card))
                        }.buttonStyle(.plain).accessibilityLabel("Remove \(g.title)")
                    }
                }
                if importedPageCount > 1 {
                    pager
                }
            }
        }
    }

    // MARK: Pager

    private var pager: some View {
        HStack(spacing: 14) {
            pagerButton("chevron.left", label: "Previous page", enabled: importedPage > 0) {
                importedPage = max(0, importedPage - 1)
            }
            Text("\(min(importedPage + 1, importedPageCount)) / \(importedPageCount)")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: 52)
            pagerButton("chevron.right", label: "Next page", enabled: importedPage < importedPageCount - 1) {
                importedPage = min(importedPageCount - 1, importedPage + 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private func pagerButton(_ icon: String, label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.25))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.card))
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Windows 98

    private var windowsCard: some View {
        card("WINDOWS 98", icon: "macwindow") {
            Text(win98.installed
                 ? "All Windows games share one Windows 98 disk (S3 Trio64, 3dfx Voodoo, Sound Blaster 16, Pentium, 128 MB). Removing a game never removes it."
                 : "Windows 98 isn't set up yet. Setup runs once, from your Windows 98 CD image, then every Windows pack can use it.")
                .font(subFont).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            if win98.installed {
                if !win98.hookStatus.isEmpty {
                    Text(win98.hookStatus).font(Theme.mono).foregroundStyle(win98.hookStatus.contains("FAILED") || win98.hookStatus.contains("not found") ? Color(red: 1, green: 0.45, blue: 0.4) : Theme.accent)
                }
                osButton("OPEN WINDOWS 98 (DRIVERS & TWEAKS)", primary: true) { viaLibrary { win98.openDesktop() } }
                osButton("EXPORT WINDOWS 98 IMAGE (AIRDROP)", primary: false) { viaLibrary { win98.export() } }
                osButton("IMPORT WINDOWS 98 IMAGE", primary: false) { pickImage = true }
                osButton("RESET WINDOWS 98", primary: false, destructive: true) { confirmOSReset = true }
            } else {
                osButton("SET UP WINDOWS 98", primary: true) { viaLibrary { win98.present() } }
                osButton("IMPORT WINDOWS 98 IMAGE", primary: false) { pickImage = true }
            }
        }
        // Each OS card owns its dialog / picker: stacking several of these modifiers on one view makes SwiftUI drop all but one.
        .confirmationDialog("Reset Windows 98?", isPresented: $confirmOSReset, titleVisibility: .visible) {
            Button("Reset Windows 98", role: .destructive) { viaLibrary { win98.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the Windows 98 disk, including every driver and program installed in it, and starts again from scratch (or from the disk that ships with the app). Your games stay. Export a backup first if you want to keep it.")
        }
        .fileImporter(isPresented: $pickImage, allowedContentTypes: [.data]) { r in
            if case .success(let u) = r { viaLibrary { win98.importDisk(u) } }
        }
    }


    // MARK: Windows 3.1

    private var win31Card: some View {
        card("WINDOWS 3.1", icon: "macwindow") {
            Text(win31.installed
                 ? "Windows 3.1 games share one Windows 3.1 disk (SVGA, Sound Blaster 16, 486, 16 MB RAM). Removing a game never removes it."
                 : "Windows 3.1 isn't set up yet. Set it up once from your Windows 3.1 setup image, then every Windows 3.1 pack can use it.")
                .font(subFont).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            if win31.installed {
                if !win31.hookStatus.isEmpty {
                    Text(win31.hookStatus).font(Theme.mono).foregroundStyle(win31.hookStatus.contains("FAILED") || win31.hookStatus.contains("not found") ? Color(red: 1, green: 0.45, blue: 0.4) : Theme.accent)
                }
                osButton("OPEN WINDOWS 3.1", primary: true) { viaLibrary { win31.openDesktop() } }
                osButton("EXPORT WINDOWS 3.1 IMAGE (AIRDROP)", primary: false) { viaLibrary { win31.export() } }
                osButton("IMPORT WINDOWS 3.1 IMAGE", primary: false) { pickImage31 = true }
                osButton("RESET WINDOWS 3.1", primary: false, destructive: true) { confirmOSReset31 = true }
            } else {
                osButton("SET UP WINDOWS 3.1", primary: true) { viaLibrary { win31.present() } }
                osButton("IMPORT WINDOWS 3.1 IMAGE", primary: false) { pickImage31 = true }
            }
        }
        .confirmationDialog("Reset Windows 3.1?", isPresented: $confirmOSReset31, titleVisibility: .visible) {
            Button("Reset Windows 3.1", role: .destructive) { viaLibrary { win31.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the Windows 3.1 disk, including Windows and every program installed in it, and starts again from scratch (or from the disk that ships with the app). Your games stay. Export a backup first if you want to keep it.")
        }
        .fileImporter(isPresented: $pickImage31, allowedContentTypes: [.data]) { r in
            if case .success(let u) = r { viaLibrary { win31.importDisk(u) } }
        }
    }

    // MARK: Windows 95

    private var win95Card: some View {
        card("WINDOWS 95", icon: "macwindow") {
            Text(win95.installed
                 ? "Windows 95 games share one Windows 95 disk (S3 Trio64, 3dfx Voodoo, Sound Blaster 16, Pentium, 64 MB, 512 MB disk). Removing a game never removes it."
                 : "The Windows 95 disk isn't available yet. Import a Windows 95 image, or reset it to the disk that ships with the app.")
                .font(subFont).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            if win95.installed {
                if !win95.hookStatus.isEmpty {
                    Text(win95.hookStatus).font(Theme.mono).foregroundStyle(win95.hookStatus.contains("FAILED") || win95.hookStatus.contains("not found") ? Color(red: 1, green: 0.45, blue: 0.4) : Theme.accent)
                }
                osButton("OPEN WINDOWS 95", primary: true) { viaLibrary { win95.openDesktop() } }
                osButton("EXPORT WINDOWS 95 IMAGE (AIRDROP)", primary: false) { viaLibrary { win95.export() } }
                osButton("IMPORT WINDOWS 95 IMAGE", primary: false) { pickImage95 = true }
                osButton("RESET WINDOWS 95", primary: false, destructive: true) { confirmOSReset95 = true }
            } else {
                osButton("SET UP WINDOWS 95", primary: true) { viaLibrary { win95.present() } }
                osButton("IMPORT WINDOWS 95 IMAGE", primary: false) { pickImage95 = true }
            }
        }
        .confirmationDialog("Reset Windows 95?", isPresented: $confirmOSReset95, titleVisibility: .visible) {
            Button("Reset Windows 95", role: .destructive) { viaLibrary { win95.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the Windows 95 disk, including every driver and program installed in it, and starts again from the disk that ships with the app. Your games stay. Export a backup first if you want to keep it.")
        }
        .fileImporter(isPresented: $pickImage95, allowedContentTypes: [.data]) { r in
            if case .success(let u) = r { viaLibrary { win95.importDisk(u) } }
        }
    }

    /// The Windows 98 sheets belong to the library screen: close Settings first, then show them.
    private func viaLibrary(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: action)
    }

    private func osButton(_ title: String, primary: Bool, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(1)
                .foregroundStyle(primary ? Color.black : destructive ? Color(red: 1, green: 0.45, blue: 0.4) : .white.opacity(0.85))
                .padding(.vertical, 13).frame(maxWidth: .infinity)
                .background(Capsule().fill(primary ? Theme.accent : Theme.card))
        }
        .buttonStyle(PressableStyle())
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("C:\\> CONFIG").font(Theme.mono).foregroundStyle(Theme.accent)
                Text("Settings").font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            }
            Spacer()
            Button { dismiss() } label: {
                Text("DONE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(PressableStyle())
        }
    }

    // MARK: Cards

    private var mouseCard: some View {
        card("MOUSE & TOUCH", icon: "computermouse.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pointer input").font(rowFont).foregroundStyle(.white)
                Picker("Pointer input", selection: $pointerInput) {
                    Text("Both").tag("both")
                    Text("Touch only").tag("touch")
                    Text("Mouse only").tag("mouse")
                }
                .pickerStyle(.segmented)
                Text("Both: the last-used device wins. If one ever misbehaves, pick the other.")
                    .font(subFont).foregroundStyle(.white.opacity(0.45))
            }
            divider
            VStack(alignment: .leading, spacing: 10) {
                Text("Touch style").font(rowFont).foregroundStyle(.white)
                Picker("Touch style", selection: $touchMode) {
                    Text("Tap where you want").tag("direct")
                    Text("Touchpad").tag("pad")
                }
                .pickerStyle(.segmented)
                Text("Works like a trackpad: slide to move, tap = click, two-finger tap or press-and-hold = right click, tap then touch and drag = hold the left button, two-finger drag = scroll wheel. \"Tap where you want\" applies to ScummVM; DOSBox always uses the trackpad style.")
                    .font(subFont).foregroundStyle(.white.opacity(0.45))
            }
            divider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cursor speed").font(rowFont).foregroundStyle(.white)
                    Spacer()
                    Text(String(format: "%.1f×", mouseSpeed)).font(Theme.mono).foregroundStyle(Theme.accent)
                }
                Slider(value: $mouseSpeed, in: 0.5...4, step: 0.1).tint(Theme.accent)
            }
            divider
            toggle("Swap left / right buttons", "For left-handed use.", $swapButtons)
            divider
            toggle("Scroll wheel", "Two-finger scroll sends wheel up/down to the game.", $scrollWheel)
            divider
            toggle("Hide system cursor", "Locks the iPad pointer inside the game. Turn off if you want to click the on-screen overlay with the trackpad.", $lockPointer)
        }
    }

    private var keyboardCard: some View {
        card("KEYBOARD", icon: "keyboard.fill") {
            toggle("⌘ + number row = F-keys",
                   "For keyboards without a function row (Magic Keyboard): ⌘1 = F1, ⌘2 = F2, ⌘3 = F3 … ⌘0 = F10, ⌘- = F11, ⌘= = F12. The on-screen keyboard button also has F1–F12.", $cmdFKeys)
            divider
            toggle("⌘ + . = Esc",
                   "For keyboards without an Esc key (iPad Air Magic Keyboard). Hold ⌘ and press the period key. The on-screen keyboard button also has an ESC key.", $escShortcut)
            divider
            toggle("` key = Esc",
                   "Also use the top-left ` / ~ key as Esc. Turn off if a game needs that key.", $tildeEsc)
            divider
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard layout").font(rowFont).foregroundStyle(.white)
                    Text("Layout the DOS game sees.").font(subFont).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Picker("Layout", selection: $layout) {
                    ForEach(Prefs.layouts) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
            }
        }
    }

    private var gamepadCard: some View {
        card("GAMEPAD", icon: "gamecontroller.fill") {
            toggle("Use game controller", "Xbox, PlayStation, Switch Pro and MFi pads. D-pad / left stick = arrow keys, L1 = Esc, R1 = Tab.", $padEnabled)
            if padEnabled {
                divider
                VStack(alignment: .leading, spacing: 10) {
                    Text("Button layout").font(rowFont).foregroundStyle(.white)
                    Picker("Button layout", selection: $padLayout) {
                        Text("Classic").tag("classic")
                        Text("Action").tag("action")
                        Text("Menu").tag("menu")
                    }
                    .pickerStyle(.segmented)
                    Text(layoutHelp).font(subFont).foregroundStyle(.white.opacity(0.45))
                }
                divider
                toggle("Right stick moves the mouse", "R2 = left click, L2 = right click. Uses the cursor speed above.", $padStickMouse)
            }
        }
    }

    private var layoutHelp: String {
        switch padLayout {
        case "action": return "A = Space · B = Ctrl · X = Alt · Y = Enter"
        case "menu": return "A = Enter · B = Esc · X = Space · Y = Tab"
        default: return "A = Ctrl · B = Alt · X = Space · Y = Enter (Keen, Dangerous Dave…)"
        }
    }

    private var overlayCard: some View {
        card("IN-GAME BUTTONS", icon: "pause.circle.fill") {
            toggle("Show pause button", "A small button over the game that opens the pause menu: resume, save slots, restart and quit. ⌘P and the controller Menu button always work.", $overlayEnabled)
            divider
            toggle("Show keyboard button", "A button next to it that opens the iOS keyboard (with Esc, Tab, arrows, Ctrl, Alt and F-keys above it) so you can type in any game.", $keyboardButton)
            if overlayEnabled || keyboardButton {
                divider
                VStack(alignment: .leading, spacing: 10) {
                    Text("Button position").font(rowFont).foregroundStyle(.white)
                    cornerPicker
                }
            }
        }
    }

    private var cornerPicker: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            VStack {
                HStack { dot("tl"); Spacer(); dot("tr") }
                Spacer()
                HStack { dot("bl"); Spacer(); dot("br") }
            }
            .padding(10)
        }
        .frame(height: 110)
    }

    private func dot(_ id: String) -> some View {
        let on = overlayCorner == id
        return Button { withAnimation(.snappy) { overlayCorner = id } } label: {
            Image(systemName: on ? "xmark" : "circle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(on ? Color.black : .white.opacity(0.5))
                .frame(width: 34, height: 34)
                .background(Circle().fill(on ? Theme.accent : Theme.card))
        }
        .buttonStyle(.plain)
    }

    // MARK: Building blocks

    private var rowFont: Font { .system(size: 15, weight: .semibold, design: .rounded) }
    private var subFont: Font { .system(size: 12, weight: .regular, design: .rounded) }
    private var divider: some View { Divider().overlay(Theme.stroke) }

    private func toggle(_ title: String, _ sub: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(rowFont).foregroundStyle(.white)
                Text(sub).font(subFont).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.accent)
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                Text(title).font(Theme.mono)
            }
            .foregroundStyle(Theme.accent)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}
