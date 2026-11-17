import SwiftUI
import UIKit

// MARK: - Install button with a fill that follows the download

/// One button for every state: INSTALL → live fill (download %, then UNPACKING) → INSTALLED.
/// The label is drawn twice (light on the dark track, black on the green fill) and the black copy is masked to the
/// filled part, so the text stays readable while the fill sweeps across it.
struct InstallButton: View {
    let installed: Bool
    let busy: Bool
    let progress: Double
    let phase: StoreModel.Phase
    let locked: Bool                 // another pack is installing
    var large = false
    var sizeText: String? = nil
    let onInstall: () -> Void
    let onCancel: () -> Void

    private var height: CGFloat { large ? 54 : 36 }
    private var fontSize: CGFloat { large ? 14 : 11 }

    var body: some View {
        Button {
            if busy { if phase == .downloading { onCancel() } }
            else if !installed && !locked {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onInstall()
            }
        } label: {
            GeometryReader { g in
                let fill = g.size.width * CGFloat(min(1, max(0, progress)))
                ZStack(alignment: .leading) {
                    track
                    if busy {
                        Rectangle().fill(Theme.accent).frame(width: fill)
                    }
                    label(color: labelColor)
                        .frame(width: g.size.width, height: g.size.height)
                    if busy {
                        label(color: .black)
                            .frame(width: g.size.width, height: g.size.height)
                            .mask(alignment: .leading) { Rectangle().frame(width: fill) }
                    }
                }
                .animation(.linear(duration: 0.3), value: progress)
            }
            .frame(height: height)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(installed || busy ? Theme.stroke : Color.clear, lineWidth: 1))
            .shadow(color: (!installed && !busy && !locked) ? Theme.accent.opacity(large ? 0.45 : 0.25) : .clear,
                    radius: large ? 16 : 8, y: 3)
        }
        .buttonStyle(PressableStyle())
        .disabled(installed || (locked && !busy))
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder private var track: some View {
        if installed { Capsule().fill(Theme.card) }
        else if busy { Capsule().fill(Color.white.opacity(0.10)) }
        else { Capsule().fill(Theme.accent.opacity(locked ? 0.30 : 1)) }
    }

    private var labelColor: Color {
        if installed { return .white.opacity(0.6) }
        if busy { return .white.opacity(0.92) }
        return .black
    }

    private var accessibility: String {
        if installed { return "Installed" }
        if busy { return phase == .downloading ? "Downloading, \(Int(progress * 100)) percent. Tap to cancel" : "Installing" }
        return "Install"
    }

    private func label(color: Color) -> some View {
        HStack(spacing: 7) {
            if installed {
                Image(systemName: "checkmark").font(.system(size: fontSize, weight: .heavy))
                Text("INSTALLED")
            } else if busy {
                if phase == .downloading {
                    Image(systemName: "xmark").font(.system(size: fontSize - 2, weight: .heavy))
                    Text(large ? "DOWNLOADING \(Int(progress / 0.85 * 100).clamped(0, 100))%" : "\(Int(progress / 0.85 * 100).clamped(0, 100))%")
                } else {
                    Image(systemName: "gearshape.2.fill").font(.system(size: fontSize, weight: .bold))
                    Text(large ? "UNPACKING…" : "UNPACKING")
                }
            } else {
                Image(systemName: "arrow.down.to.line.compact").font(.system(size: fontSize, weight: .heavy))
                Text(large && sizeText != nil ? "INSTALL · \(sizeText!.uppercased())" : "INSTALL")
            }
        }
        .font(.system(size: fontSize, weight: .heavy, design: .monospaced))
        .tracking(1)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(color)
        .padding(.horizontal, 10)
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(hi, Swift.max(lo, self)) }
}

// MARK: - Floppy — byte-for-byte the shelf's FloppyCard geometry

struct StoreFloppy: View {
    let cover: URL?
    private static let disk: UIImage? = resourceImage("floppy", "png")

    var body: some View {
        Group {
            if let disk = Self.disk {
                Image(uiImage: disk)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            RemoteImage(url: cover) { img in
                                Group {
                                    if let img {
                                        // Same 1.22 zoom as FloppyCard: the window crops the sticker's white edges away.
                                        Image(uiImage: img)
                                            .resizable()
                                            .interpolation(.high)
                                            .scaledToFill()
                                            .scaleEffect(1.22)
                                    } else {
                                        Color.black.opacity(0.18)
                                    }
                                }
                                .frame(width: geo.size.width * 0.6456, height: geo.size.height * 0.4429)
                                .clipped()
                                .position(x: geo.size.width * 0.5065, y: geo.size.height * 0.6010)
                            }
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1))
            }
        }
        .aspectRatio(866.0 / 900.0, contentMode: .fit)
    }
}

/// Wide poster with the sticker's grey / outline / white band removed, clipped to rounded corners.
struct StorePoster: View {
    let cover: URL?
    var radius: CGFloat = 20

    var body: some View {
        RemoteImage(url: cover, trimmed: true) { img in
            Color.clear
                .overlay {
                    if let img {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .scaleEffect(1.03)         // pushes the frame's rounded-corner wedges out of the clip
                    } else {
                        Rectangle().fill(Theme.card)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .aspectRatio(1.6, contentMode: .fit)
    }
}

// MARK: - Badges

struct StoreBadge: View {
    let text: String
    var color: Color = Theme.accent
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy, design: .monospaced)).tracking(1)
            .foregroundStyle(color == Theme.accent || color == Theme.amber ? Color.black : .white)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(color))
    }
}

// MARK: - Featured banner

struct StoreBanner: View {
    let pack: StorePack
    let cover: URL?
    let installed: Bool
    let busy: Bool
    let progress: Double
    let phase: StoreModel.Phase
    let locked: Bool
    let onOpen: () -> Void
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            StorePoster(cover: cover, radius: 26)

            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.88)],
                           startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        StoreBadge(text: "FEATURED")
                        if pack.isNew() { StoreBadge(text: "NEW", color: Theme.amber) }
                    }
                    Text(pack.title)
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                InstallButton(installed: installed, busy: busy, progress: progress, phase: phase, locked: locked,
                              onInstall: onInstall, onCancel: onCancel)
                    .frame(width: 124)
            }
            .padding(14)
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture(perform: onOpen)
    }

    private var subtitle: String {
        if let t = pack.tagline, !t.isEmpty { return t }
        return [pack.yearText, pack.genreText, pack.systemText].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Grid tile

struct StoreTile: View {
    let pack: StorePack
    let cover: URL?
    let installed: Bool
    let busy: Bool
    let progress: Double
    let phase: StoreModel.Phase
    let locked: Bool
    let onOpen: () -> Void
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: onOpen) {
                VStack(spacing: 10) {
                    StoreFloppy(cover: cover)
                        .shadow(color: .black.opacity(0.55), radius: 12, y: 8)
                        .overlay(alignment: .topLeading) {
                            if pack.isNew() { StoreBadge(text: "NEW", color: Theme.amber).padding(4) }
                        }
                        .overlay(alignment: .topTrailing) {
                            if installed {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Theme.accent))
                                    .padding(4)
                            }
                        }
                    VStack(spacing: 3) {
                        Text(pack.title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Text("\(pack.yearText) · \(pack.systemText)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            .buttonStyle(PressableStyle())

            InstallButton(installed: installed, busy: busy, progress: progress, phase: phase, locked: locked,
                          onInstall: onInstall, onCancel: onCancel)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

/// Loading placeholder tile.
struct StoreSkeletonTile: View {
    @State private var on = false
    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)).aspectRatio(866.0 / 900.0, contentMode: .fit)
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)).frame(height: 14)
            Capsule().fill(Color.white.opacity(0.07)).frame(height: 36)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .opacity(on ? 0.5 : 1)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } }
    }
}

// MARK: - Link editor (used in the sheet and on the first-run card)

struct StoreLinkEditor: View {
    let current: String
    let onSave: (String) -> Void
    var onRemove: (() -> Void)? = nil

    @State private var draft: String
    @State private var testState: TestState = .idle
    @State private var history: [String] = StoreLink.history
    @FocusState private var focused: Bool

    enum TestState: Equatable { case idle, testing, ok(String), fail(String) }

    init(current: String, onSave: @escaping (String) -> Void, onRemove: (() -> Void)? = nil) {
        self.current = current
        self.onSave = onSave
        self.onRemove = onRemove
        _draft = State(initialValue: current)
    }

    private var url: URL? { StoreLink.normalize(draft) }
    private var changed: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines) != current }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The address of the folder that holds store.json, covers/ and packs/ — any static web server works, no API needed.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                TextField("http://127.0.0.1:8087/", text: $draft)
                    .focused($focused)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .foregroundStyle(.white)
                    .onChange(of: draft) { _, _ in testState = .idle }
                if !draft.isEmpty {
                    Button { draft = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(focused ? Theme.accent.opacity(0.6) : Theme.stroke, lineWidth: 1))

            HStack(spacing: 8) {
                smallButton("PASTE", icon: "doc.on.clipboard") {
                    if let s = UIPasteboard.general.string { draft = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                smallButton("TEST", icon: "bolt.horizontal", enabled: url != nil && testState != .testing) { test() }
                if changed && !current.isEmpty {
                    smallButton("REVERT", icon: "arrow.uturn.backward") { draft = current }
                }
                Spacer(minLength: 0)
            }

            switch testState {
            case .idle: EmptyView()
            case .testing:
                HStack(spacing: 8) { ProgressView().tint(Theme.accent).scaleEffect(0.8); Text("Checking…") }
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            case .ok(let s):
                Label(s, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.accent)
            case .fail(let s):
                Label(s, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                focused = false
                onSave(draft.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Text(current.isEmpty ? "CONNECT" : "SAVE LINK")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(1.5)
                    .foregroundStyle(.black)
                    .padding(.vertical, 15).frame(maxWidth: .infinity)
                    .background(Capsule().fill(Theme.accent.opacity(url == nil ? 0.3 : 1)))
                    .shadow(color: Theme.accent.opacity(url == nil ? 0 : 0.4), radius: 14, y: 4)
            }
            .buttonStyle(PressableStyle())
            .disabled(url == nil)

            let others = history.filter { $0 != draft.trimmingCharacters(in: .whitespacesAndNewlines) }
            if !others.isEmpty {
                Text("RECENT").font(Theme.mono).foregroundStyle(.white.opacity(0.4)).padding(.top, 4)
                VStack(spacing: 8) {
                    ForEach(others, id: \.self) { h in
                        HStack(spacing: 10) {
                            Button { draft = h } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                                    Text(h).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                            Button {
                                StoreLink.forget(h)
                                history = StoreLink.history
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                    }
                }
            }

            if let onRemove, !current.isEmpty {
                Button(role: .destructive) { onRemove() } label: {
                    Text("REMOVE LINK")
                        .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1)
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func smallButton(_ title: String, icon: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(1)
            }
            .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.35))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }

    private func test() {
        guard let u = url else { return }
        testState = .testing
        Task {
            let r = await StoreLink.probe(u)
            switch r {
            case .success(let s): testState = .ok("\(s.name) · \(s.count) games")
            case .failure(let e): testState = .fail(e.localizedDescription)
            }
        }
    }
}
