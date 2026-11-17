import SwiftUI
import UIKit
import AVFoundation

func configureAppAudio() {
    let s = AVAudioSession.sharedInstance()
    try? s.setCategory(.playback, mode: .default)
    try? s.setActive(true)
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .all
    }
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureAppAudio()
        Prefs.register()
        return true
    }
}

// MARK: - Model

struct Game: Identifiable, Decodable {
    let id: String
    let title: String
    let year: Int
    let tag: String?
    // Descriptive metadata: from meta.json (imported games) or games.json (bundled games).
    let devOverride: String?
    let genreOverride: String?
    let blurbOverride: String?
    let source: String?             // nil = bundled, "imported" = added by the user

    init(id: String, title: String, year: Int, tag: String?,
         developer: String? = nil, genre: String? = nil, blurb: String? = nil, source: String? = nil) {
        self.id = id; self.title = title; self.year = year; self.tag = tag
        self.devOverride = developer; self.genreOverride = genre; self.blurbOverride = blurb
        self.source = source
    }

    var isImported: Bool { source == "imported" }

    /// games.json (bundled games) and meta.json use the plain names.
    enum CodingKeys: String, CodingKey {
        case id, title, year, tag, source
        case devOverride = "developer", genreOverride = "genre", blurbOverride = "blurb"
    }

    var developer: String { devOverride ?? "" }
    var genre: String { genreOverride ?? "" }
    var blurb: String { blurbOverride ?? "" }
    var engine: String { tag ?? "DOSBox" }
}

/// Bundled games followed by the user's imported ones. Observable so the grid updates after an import/removal.
final class Library: ObservableObject {
    static let shared = Library()
    @Published private(set) var games: [Game] = []
    /// game id -> "DOS" | "Windows 95" | "Windows 98" | "Windows 3.1" | "ScummVM" (rebuilt on every reload).
    private(set) var platforms: [String: String] = [:]
    private let bundled: [Game]

    private init() {
        if let url = resURL("games.json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Game].self, from: data) {
            bundled = list
        } else {
            bundled = []
        }
        ImportedStore.cleanupOrphans()
        reload()
    }

    func reload() {
        let imported = ImportedStore.all().map { $0.game }
        let ids = Set(bundled.map { $0.id })
        games = bundled + imported.filter { !ids.contains($0.id) }
        var map: [String: String] = [:]
        for g in games {
            if g.engine == "ScummVM" { map[g.id] = "ScummVM"; continue }
            let os = g.isImported ? ImportedStore.config(g.id).baseos.lowercased().replacingOccurrences(of: " ", with: "") : ""
            if let p = BaseOS.all.first(where: { $0.names.contains(os) }) { map[g.id] = p.title }
            else { map[g.id] = "DOS" }
        }
        platforms = map
    }

    func platform(_ id: String) -> String { platforms[id] ?? "DOS" }
}

func resURL(_ relative: String) -> URL? {
    let comps = relative.components(separatedBy: "/")
    let name = comps.last ?? relative
    let subdir = comps.dropLast().joined(separator: "/")
    if subdir.isEmpty {
        if let u = Bundle.module.url(forResource: name, withExtension: nil) { return u }
    } else {
        if let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: subdir) { return u }
        if let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/" + subdir) { return u }
    }
    return Res.url(relative)
}

func resourceImage(_ name: String, _ ext: String, subdir: String? = nil) -> UIImage? {
    // Posters come only from packs (cover.jpg inside the game's own folder); the app bundle holds none.
    if subdir == "posters" {
        guard ext == "jpg", let u = ImportedStore.coverURL(name) else { return nil }
        return UIImage(contentsOfFile: u.path)
    }
    let rel = subdir == nil ? "\(name).\(ext)" : "\(subdir!)/\(name).\(ext)"
    guard let url = resURL(rel) else { return nil }
    return UIImage(contentsOfFile: url.path)
}

func backgroundImage() -> UIImage? { resourceImage("bg", "jpg") }

// MARK: - Theme

enum Theme {
    static let bgTop = Color(red: 0.04, green: 0.06, blue: 0.11)
    static let bgBottom = Color(red: 0.01, green: 0.015, blue: 0.03)
    static let accent = Color(red: 0.36, green: 1.0, blue: 0.55)      // phosphor green
    static let amber = Color(red: 1.0, green: 0.74, blue: 0.25)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.10)
    static let mono = Font.system(size: 11, weight: .semibold, design: .monospaced)
}

/// Full-bleed background that never influences layout size.
struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            if let ui = backgroundImage() {
                GeometryReader { geo in
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(0.22)
                        .blur(radius: 6)
                }
            }
            RadialGradient(colors: [Theme.accent.opacity(0.10), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Floppy

struct FloppyCard: View {
    let game: Game

    var body: some View {
        Group {
            if let disk = resourceImage("floppy", "png") {
                Image(uiImage: disk)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            if let cover = resourceImage(game.id, "jpg", subdir: "posters") {
                                Image(uiImage: cover)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFill()
                                    .scaleEffect(1.22)
                                    .frame(width: geo.size.width * 0.6456,
                                           height: geo.size.height * 0.4429)
                                    .clipped()
                                    .position(x: geo.size.width * 0.5065,
                                              y: geo.size.height * 0.6010)
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

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct LibraryTile: View {
    let game: Game
    @ObservedObject private var store = LibraryStore.shared
    var body: some View {
        VStack(spacing: 10) {
            FloppyCard(game: game)
                .shadow(color: .black.opacity(0.55), radius: 12, y: 8)
                .overlay(alignment: .topTrailing) {
                    if store.isFavorite(game.id) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.45))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.black.opacity(0.65)))
                            .padding(4)
                    }
                }
            VStack(spacing: 3) {
                Text(game.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text("\(String(game.year)) · \(game.engine)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                if store.stat(game.id).seconds >= 60 {
                    Text("PLAYED \(LibraryStore.duration(store.stat(game.id).seconds).uppercased())")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent.opacity(0.8))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

// MARK: - Detail

struct GameDetailView: View {
    @State private var exportURL: URL?
    @State private var exporting = false
    let game: Game
    let onClose: () -> Void
    @ObservedObject private var store = LibraryStore.shared
    @State private var errorText: String?

    var body: some View {
        ZStack {
            AppBackground()
            GeometryReader { geo in
                if geo.size.width > geo.size.height {
                    landscape(geo)
                } else {
                    portrait(geo)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // Portrait: hero on top, info below, Play pinned to the bottom edge.
    private func portrait(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            topBar.padding(.horizontal, 20).padding(.top, 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 22) {
                    FloppyCard(game: game)
                        .frame(maxWidth: min(geo.size.width - 80, 340))
                        .shadow(color: Theme.accent.opacity(0.25), radius: 30, y: 6)
                        .shadow(color: .black.opacity(0.6), radius: 18, y: 12)
                        .padding(.top, 8)
                    info
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            playBar.padding(.horizontal, 24).padding(.vertical, 12)
        }
    }

    // Landscape: floppy on the left, scrollable info + Play on the right.
    private func landscape(_ geo: GeometryProxy) -> some View {
        HStack(spacing: 28) {
            FloppyCard(game: game)
                .frame(maxWidth: geo.size.width * 0.38, maxHeight: geo.size.height - 40)
                .shadow(color: Theme.accent.opacity(0.25), radius: 30, y: 6)
                .shadow(color: .black.opacity(0.6), radius: 18, y: 12)
                .frame(maxWidth: geo.size.width * 0.40, maxHeight: .infinity)
            VStack(spacing: 0) {
                topBar.padding(.top, 8)
                ScrollView(.vertical, showsIndicators: false) {
                    info.padding(.vertical, 8)
                }
                playBar.padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    Text("LIBRARY").font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            Spacer()
            let fav = store.isFavorite(game.id)
            Button { withAnimation(.snappy) { store.toggleFavorite(game.id) } } label: {
                Image(systemName: fav ? "heart.fill" : "heart")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(fav ? Color(red: 1, green: 0.35, blue: 0.45) : .white.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(fav ? "Remove from favorites" : "Add to favorites")

            if ImportedStore.isImported(game.id) {
                Button { exportPack() } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.card))
                        .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .disabled(exporting)
                .accessibilityLabel("Export pack")
            }
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let u = exportURL { ShareSheet(url: u) }
        }
    }

    private func exportPack() {
        guard !exporting else { return }
        exporting = true
        let id = game.id, title = game.title
        DispatchQueue.global(qos: .userInitiated).async {
            let url = try? PackExport.export(id, title: title)
            DispatchQueue.main.async {
                exporting = false
                exportURL = url
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(game.title)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            FlowRow(spacing: 8) {
                chip(String(game.year), color: Theme.amber)
                if !game.genre.isEmpty { chip(game.genre, color: .white) }
                chip(game.engine, color: Theme.accent)
            }

            statsRow

            if !game.blurb.isEmpty {
                Text(game.blurb)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !game.developer.isEmpty {
                HStack(spacing: 8) {
                    Text("DEVELOPER").font(Theme.mono).foregroundStyle(.white.opacity(0.4))
                    Text(game.developer)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            if let e = errorText {
                Text(e)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.75)))
                    .onTapGesture { errorText = nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ s: String, color: Color) -> some View {
        Text(s.uppercased())
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }

    private var statsRow: some View {
        let st = store.stat(game.id)
        let saves = StateStore.savedCount(game.id)
        return HStack(spacing: 10) {
            statTile("LAST PLAYED", st.lastPlayed.map { LibraryStore.ago($0) } ?? "Never")
            statTile("PLAY TIME", st.seconds >= 60 ? LibraryStore.duration(st.seconds) : "—")
            statTile("SAVES", "\(saves) / \(StateStore.slotCount)")
        }
    }

    private func statTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    private var playBar: some View {
        let _ = store.stats          // refresh when a session ends (auto-save may have just been written)
        let hasAuto = StateStore.hasAuto(game.id)
        return VStack(spacing: 10) {
            if hasAuto {
                bigButton("CONTINUE", icon: "play.fill", primary: true) { play(resume: true) }
                if let d = StateStore.autoDate(game.id) {
                    Text("Auto-saved \(LibraryStore.ago(d))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                bigButton("START FROM BEGINNING", icon: "arrow.counterclockwise", primary: false) { play(resume: false) }
            } else {
                bigButton("PLAY", icon: "play.fill", primary: true) { play(resume: false) }
            }
        }
    }

    private func bigButton(_ title: String, icon: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: primary ? 16 : 12, weight: .bold))
                Text(title)
                    .font(.system(size: primary ? 17 : 11, weight: primary ? .heavy : .bold, design: primary ? .rounded : .monospaced))
                    .tracking(primary ? 3 : 1)
            }
            .foregroundStyle(primary ? Color.black : .white.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, primary ? 16 : 12)
            .background(Capsule().fill(primary ? Theme.accent : Theme.card))
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: primary ? 0 : 1))
            .shadow(color: primary ? Theme.accent.opacity(0.45) : .clear, radius: 16, y: 4)
        }
        .buttonStyle(PressableStyle())
    }

    private func play(resume: Bool) {
        errorText = nil
        if let failure = GameRunner.shared.start(gameId: game.id, resume: resume) {
            errorText = GameRunner.message(for: failure)
        }
    }
}

/// Simple wrapping row for chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, p) in r.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ maxW: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        var pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x - spacing)
        }
        return (CGSize(width: width, height: y + rowH), pts)
    }
}

@main
struct RetronautApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
