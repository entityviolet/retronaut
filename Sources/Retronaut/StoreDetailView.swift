import SwiftUI

/// Store counterpart of the shelf's GameDetailView: floppy hero, chips, stat tiles, blurb — with a big INSTALL bar
/// whose fill follows the download. Same portrait / landscape split as the shelf.
struct StoreDetailView: View {
    @ObservedObject var model: StoreModel
    @ObservedObject private var library = Library.shared
    @State private var pack: StorePack
    let onClose: () -> Void

    init(pack: StorePack, model: StoreModel, onClose: @escaping () -> Void) {
        _pack = State(initialValue: pack)
        self.model = model
        self.onClose = onClose
    }

    private var installed: Bool { StoreInstalls.isInstalled(pack, games: library.games) }
    private var cover: URL? { model.coverURL(pack) }

    private var related: [StorePack] {
        var scored: [(pack: StorePack, score: Int)] = []
        for p in model.packs where p.id != pack.id {
            let score = relatedScore(p)
            if score > 0 { scored.append((p, score)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return abs(a.pack.year - pack.year) < abs(b.pack.year - pack.year)
        }
        return scored.prefix(10).map { $0.pack }
    }

    private func firstWord(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
    }

    private func relatedScore(_ p: StorePack) -> Int {
        var score = 0
        let a = firstWord(pack.genreText), b = firstWord(p.genreText)
        if !a.isEmpty && a == b { score += 4 }
        if p.systemText == pack.systemText { score += 1 }
        if abs(p.year - pack.year) <= 2 { score += 1 }
        return score
    }

    var body: some View {
        ZStack {
            AppBackground()
            GeometryReader { geo in
                if geo.size.width > geo.size.height { landscape(geo) } else { portrait(geo) }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Layouts

    private func portrait(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            topBar.padding(.horizontal, 20).padding(.top, 8)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 22) {
                        Color.clear.frame(height: 0).id("top")
                        hero.frame(maxWidth: min(geo.size.width - 80, 340)).padding(.top, 8)
                        info
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: pack.id) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
            }
            installBar.padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity)
    }

    private func landscape(_ geo: GeometryProxy) -> some View {
        HStack(spacing: 28) {
            hero
                .frame(maxWidth: geo.size.width * 0.38, maxHeight: geo.size.height - 40)
                .frame(maxWidth: geo.size.width * 0.40, maxHeight: .infinity)
            VStack(spacing: 0) {
                topBar.padding(.top, 8)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 0).id("top")
                            info.padding(.vertical, 8)
                        }
                    }
                    .onChange(of: pack.id) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
                }
                installBar.padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
    }

    private var hero: some View {
        StoreFloppy(cover: cover)
            .shadow(color: Theme.accent.opacity(0.25), radius: 30, y: 6)
            .shadow(color: .black.opacity(0.6), radius: 18, y: 12)
            .id(pack.id)
            .transition(.opacity)
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    Text("STORE").font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            Spacer()
            ShareLink(item: "\(pack.title) (\(pack.yearText))\(pack.genreText.isEmpty ? "" : " — \(pack.genreText)") · Retronaut") {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .accessibilityLabel("Share")
        }
    }

    // MARK: Info

    private var info: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pack.title)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let t = pack.tagline, !t.isEmpty {
                Text(t)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            FlowRow(spacing: 8) {
                chip(pack.yearText, color: Theme.amber)
                if !pack.genreText.isEmpty { chip(pack.genreText, color: .white) }
                chip(pack.systemText, color: Theme.accent)
                if pack.isNew() { chip("NEW", color: Theme.amber) }
            }

            HStack(spacing: 10) {
                statTile("DOWNLOAD", pack.sizeText)
                statTile("SYSTEM", pack.systemText)
                statTile("PLAYERS", (pack.players?.isEmpty == false ? pack.players! : "—"))
            }

            if !pack.story.isEmpty {
                Text(pack.story)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let d = pack.developer, !d.isEmpty {
                HStack(spacing: 8) {
                    Text("DEVELOPER").font(Theme.mono).foregroundStyle(.white.opacity(0.4))
                    Text(d)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            if let tags = pack.tags, !tags.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(tags, id: \.self) { t in
                        Text("#\(t.lowercased())")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.card))
                    }
                }
            }

            if cover != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ARTWORK").font(Theme.mono).foregroundStyle(.white.opacity(0.4))
                    StorePoster(cover: cover, radius: 20)
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                }
                .padding(.top, 4)
            }

            let more = related
            if !more.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("YOU MAY ALSO LIKE").font(Theme.mono).foregroundStyle(.white.opacity(0.4))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(more) { p in
                                Button { withAnimation(.snappy) { pack = p } } label: {
                                    VStack(spacing: 6) {
                                        StoreFloppy(cover: model.coverURL(p))
                                            .frame(width: 104)
                                            .shadow(color: .black.opacity(0.5), radius: 8, y: 5)
                                        Text(p.title)
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.85))
                                            .lineLimit(1)
                                            .frame(width: 104)
                                    }
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.top, 4)
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

    // MARK: Install bar

    private var installBar: some View {
        let busy = model.isInstalling(pack)
        return VStack(spacing: 8) {
            InstallButton(installed: installed, busy: busy, progress: model.progress, phase: model.phase,
                          locked: model.isBusy && !busy, large: true, sizeText: pack.sizeText,
                          onInstall: { model.install(pack) }, onCancel: { model.cancel() })
            Text(hint(busy: busy))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
    }

    private func hint(busy: Bool) -> String {
        if installed { return "In your library — find it on the shelf" }
        if busy { return model.phase == .downloading ? "Tap to cancel" : "Almost there — don't close the app" }
        if model.isBusy { return "Another game is installing" }
        return "Adds \(pack.title) to your library"
    }
}
