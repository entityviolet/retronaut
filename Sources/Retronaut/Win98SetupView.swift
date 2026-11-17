import SwiftUI
import UniformTypeIdentifiers

/// The Windows 98 sheet: first-run offer, "did setup finish?", progress and result.
struct Win98SetupView: View {
    @ObservedObject private var setup: Win98Setup
    @State private var pickMedia = false

    init(_ controller: Win98Setup = .shared) { _setup = ObservedObject(wrappedValue: controller) }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("C:\\> " + setup.profile.title.uppercased()).font(Theme.mono).foregroundStyle(Theme.accent)
                    content
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isBusy)
        .fileImporter(isPresented: $pickMedia, allowedContentTypes: [.data]) { r in
            if case .success(let u) = r { setup.chooseMedia(u) }
        }
    }

    private var isBusy: Bool { if case .working = setup.phase { return true } else { return false } }

    @ViewBuilder private var content: some View {
        switch setup.phase {
        case .intro: intro
        case .review: review
        case .working(let t):
            title("Please wait")
            HStack(spacing: 12) { ProgressView().tint(Theme.accent); Text(t).font(bodyFont).foregroundStyle(.white.opacity(0.8)) }
        case .done(let t):
            title("All set")
            Text(t).font(bodyFont).foregroundStyle(.white.opacity(0.8))
            Text(hookNote)
                .font(small).foregroundStyle(.white.opacity(0.55))
            button(is31 ? "OPEN WINDOWS 3.1" : (is95 ? "OPEN WINDOWS 95" : "OPEN WINDOWS 98 (DRIVERS)"), primary: true) { setup.openDesktop() }
            button("EXPORT A BACKUP (AIRDROP)", primary: false) { setup.export() }
            button("DONE", primary: false) { setup.showSheet = false }
        case .failed(let t):
            title("Something went wrong")
            Text(t).font(bodyFont).foregroundStyle(Color(red: 1, green: 0.5, blue: 0.45))
            button("BACK", primary: false) { setup.phase = .intro }
            button("CLOSE", primary: false) { setup.showSheet = false }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Set up \(setup.profile.title)?")
            Text(introText)
                .font(bodyFont).foregroundStyle(.white.opacity(0.8))
            Text(machineText)
                .font(small).foregroundStyle(.white.opacity(0.55))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(introSteps.enumerated()), id: \.offset) { item in step(item.element.0, item.element.1) }
                
                
                
            }
            if setup.hasMedia {
                button("SET UP " + setup.profile.title.uppercased(), primary: true) { setup.startSetup() }
            } else {
                Text(noMediaText)
                    .font(small).foregroundStyle(Theme.amber)
                button(is31 ? "CHOOSE WIN31 SETUP IMAGE…" : (is95 ? "IMPORT WINDOWS 95 IMAGE…" : "CHOOSE WINDOWS 98 CD IMAGE…"), primary: true) { pickMedia = true }
            }
            button("NOT NOW", primary: false) { setup.notNow() }
            Text("You can do this later in Settings → " + setup.profile.title + ".").font(small).foregroundStyle(.white.opacity(0.4))
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Did \(setup.profile.title) finish installing?")
            Text("Only say yes if " + setup.profile.title + " reached its desktop. Otherwise continue: Setup resumes where it stopped.")
                .font(bodyFont).foregroundStyle(.white.opacity(0.8))
            button("YES, SAVE THIS " + setup.profile.title.uppercased(), primary: true) { setup.finishSetup() }
            button("NO, CONTINUE SETUP", primary: false) { setup.startSetup() }
            button("CLOSE", primary: false) { setup.showSheet = false }
        }
    }

    // MARK: Pieces


    // MARK: Profile-dependent copy (Windows 98 / Windows 3.1)

    private var is31: Bool { setup.profile.id == BaseOS.win31.id }
    private var is95: Bool { setup.profile.id == BaseOS.win95.id }
    private var osName: String { setup.profile.title }
    private var introText: String {
        if is31 { return "Windows 3.1 runs 16-bit Windows games. It is installed once on its own disk and shared by every Windows 3.1 pack. DOSBox boots the built-in DOS disk, you run SETUP from the setup disc, and that disk stays ready for the packs." }
        if is95 { return "Windows 95 runs the early Windows games that need 32-bit Windows (DirectX, 3D). It ships as one ready disk and is shared by every Windows 95 pack — nothing to install." }
        return "Windows 98 SE runs retro 3D games and Windows packs. It is installed once and shared by every Windows game. DOSBox starts and runs Windows 98 Setup from your CD image."
    }
    private var machineText: String {
        if is31 { return "Emulated PC: 486 CPU, 16 MB RAM, SVGA video, Sound Blaster 16." }
        if is95 { return "Emulated PC: Pentium CPU, 32 MB RAM, S3 Trio64 video, Sound Blaster 16." }
        return "Emulated PC: Pentium CPU, 128 MB RAM, S3 Trio64 video, 3dfx Voodoo, Sound Blaster 16."
    }
    private var introSteps: [(String, String)] {
        if is95 { return [
            ("1", "The Windows 95 disk ships with the app — it is already installed and ready. Press OPEN WINDOWS 95 to boot it."),
            ("2", "Use it for drivers, DirectX or installing a game by hand; packs mount their own game drive automatically."),
            ("3", "Quit from the pause button when you are done — the disk keeps whatever you changed."),
        ] }
        if is31 { return [
            ("1", "The built-in FreeDOS disk is C: (already formatted). The setup disc is R:."),
            ("2", "Type R: and then SETUP, and follow Windows 3.1 Setup (Express is fine)."),
            ("3", "When Setup finishes choose “Return to DOS” (or let it restart). Then open the pause button → Quit and answer “Yes”."),
        ] }
        return [
            ("1", "In the DOSBox menu pick “Boot and Install New Operating System”."),
            ("2", "Hard disk size: 2 GB. The saved disk only takes the space Windows really uses."),
            ("3", "Follow Windows 98 Setup. Reboots are normal. Use the on-screen ENT / arrow keys or a keyboard."),
            ("4", "When Windows reaches the desktop, open the pause button → Quit, and answer “Yes”."),
        ]
    }
    private var noMediaText: String {
        if is31 { return "The Windows 3.1 setup image (win31.iso) wasn't found. Choose it, or copy it into the app's Documents folder with Files / Finder." }
        if is95 { return "The Windows 95 disk (win95.img) wasn't found. Import a Windows 95 image, or copy it into the app's Documents folder with Files / Finder." }
        return "No Windows 98 CD image found. Choose your win98se.iso, or copy it into the app's Documents folder with Files / Finder."
    }
    private var hookNote: String {
        if is31 { return "The app has set Windows 3.1 up to start by itself and to run the game drive's AUTORUN.BAT first. Nothing to do inside Windows." }
        if is95 { return "The app boots Windows 95 by itself and runs the game drive's AUTORUN.BAT first. Nothing to do inside Windows." }
        return "The app has already set Windows 98 up for silent boot, no ScanDisk and automatic start of game drives. Nothing to do inside Windows."
    }

    private var bodyFont: Font { .system(size: 15, design: .rounded) }
    private var small: Font { .system(size: 12, design: .rounded) }

    private func title(_ s: String) -> some View {
        Text(s).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(.white)
    }

    private func step(_ n: String, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(Theme.mono).foregroundStyle(Theme.accent).frame(width: 16)
            Text(s).font(small).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func button(_ t: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(1)
                .foregroundStyle(primary ? Color.black : .white.opacity(0.85))
                .padding(.vertical, 13).frame(maxWidth: .infinity)
                .background(Capsule().fill(primary ? Theme.accent : Theme.card))
        }
        .buttonStyle(PressableStyle())
    }
}

/// System share sheet (AirDrop, Save to Files, ...).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
