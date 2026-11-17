import SwiftUI

// MARK: - Library

struct ContentView: View {
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var library = Library.shared
    @State private var pendingRemove: Game?
    @State private var filter = "All"
    @State private var query = ""
    @AppStorage("librarySort") private var sort = "default"     // default | title | recent | year
    @State private var selected: Game?
    @State private var showSettings = false
    @State private var showStore = false
    @AppStorage("libraryColumns") private var columnsPref: Int = 0
    @State private var importTarget: ImportTarget?
    @ObservedObject private var win98 = Win98Setup.shared
    @ObservedObject private var win31 = Win98Setup.shared31
    @ObservedObject private var win95 = Win98Setup.shared95
    @FocusState private var searchFocused: Bool

    private var games: [Game] { library.games }
    private var filters: [String] {
        let order = ["DOS", "Windows 3.1", "Windows 95", "Windows 98", "ScummVM"]
        let present = Set(games.map { library.platform($0.id) })
        let known = order.filter { present.contains($0) }
        return ["All", "Favorites"] + known + present.subtracting(order).sorted()
    }

    private var isFiltering: Bool { filter != "All" || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var visible: [Game] {
        var list = games
        if filter == "Favorites" { list = list.filter { store.isFavorite($0.id) } }
        else if filter != "All" { list = list.filter { library.platform($0.id) == filter } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { "\($0.title) \($0.developer) \($0.genre) \($0.year)".lowercased().contains(q) }
        }
        switch sort {
        case "title": list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "year": list.sort { $0.year < $1.year }
        case "recent":
            list.sort { (store.stats[$0.id]?.lastPlayed ?? .distantPast) > (store.stats[$1.id]?.lastPlayed ?? .distantPast) }
        default: break
        }
        return list
    }

    private var recent: Game? {
        games.filter { store.stats[$0.id]?.lastPlayed != nil }
            .max { (store.stats[$0.id]?.lastPlayed ?? .distantPast) < (store.stats[$1.id]?.lastPlayed ?? .distantPast) }
    }

    var body: some View {
        ZStack {
            AppBackground()
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if let g = recent, !isFiltering {
                            ContinueCard(game: g, stats: store.stat(g.id),
                                         onResume: { resume(g) }, onOpen: { selected = g })
                        }
                        if games.isEmpty {
                            noGamesState
                        } else {
                            searchRow
                            filterBar
                            if visible.isEmpty {
                                emptyState
                            } else {
                                grid(width: geo.size.width - 40, landscape: landscape)
                            }
                        }
                        footer
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(width: geo.size.width, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $selected) { game in
            GameDetailView(game: game) { selected = nil }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showStore) { StoreView() }
        .sheet(isPresented: $win98.showSheet) { Win98SetupView(win98) }
        .sheet(isPresented: $win31.showSheet) { Win98SetupView(win31) }
        .sheet(isPresented: $win95.showSheet) { Win98SetupView(win95) }
        .sheet(item: $win98.shareItem) { ShareSheet(url: $0.url) }
        .sheet(item: $win31.shareItem) { ShareSheet(url: $0.url) }
        .sheet(item: $win95.shareItem) { ShareSheet(url: $0.url) }
        .onAppear { win98.launchCheck(); win31.refresh(); win95.refresh() }
        .sheet(item: $importTarget) { t in ImportGameView(editId: t.editId) }
        .confirmationDialog("Remove \(pendingRemove?.title ?? "game")?",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove game and its saves", role: .destructive) {
                if let g = pendingRemove { ImportedStore.delete(g.id) }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("This deletes the imported files, save states and play history. It can't be undone.")
        }
    }

    private func resume(_ g: Game) {
        let hasAuto = StateStore.hasAuto(g.id)
        if GameRunner.shared.start(gameId: g.id, resume: hasAuto) != nil { selected = g }   // detail view shows the error
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("C:\\> GAMES")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.accent)
                Text("Retronaut")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(games.isEmpty ? "No games yet" : "\(games.count) games · pick a floppy to play")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 12)
            Button { showStore = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bag.fill").font(.system(size: 12, weight: .heavy))
                    Text("STORE").font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(1)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(Capsule().fill(Theme.accent))
                .shadow(color: Theme.accent.opacity(0.45), radius: 10, y: 3)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Store")

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Settings")
        }
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Search games", text: $query)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(searchFocused ? Theme.accent.opacity(0.6) : Theme.stroke, lineWidth: 1))

            Menu {
                Picker("Columns", selection: $columnsPref) {
                    Label("Automatic", systemImage: "wand.and.stars").tag(0)
                    Label("2 per row", systemImage: "square.grid.2x2").tag(2)
                    Label("4 per row", systemImage: "square.grid.3x3").tag(4)
                    Label("6 per row", systemImage: "square.grid.3x3.fill").tag(6)
                }
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(columnsPref == 0 ? .white.opacity(0.8) : Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .accessibilityLabel("Tiles per row")

            Menu {
                Picker("Sort", selection: $sort) {
                    Label("Default order", systemImage: "list.bullet").tag("default")
                    Label("Title A–Z", systemImage: "textformat").tag("title")
                    Label("Recently played", systemImage: "clock").tag("recent")
                    Label("Year", systemImage: "calendar").tag("year")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(sort == "default" ? .white.opacity(0.8) : Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .accessibilityLabel("Sort")
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { f in
                    Button { withAnimation(.snappy) { filter = f } } label: {
                        HStack(spacing: 5) {
                            if f == "Favorites" { Image(systemName: "heart.fill").font(.system(size: 9, weight: .bold)) }
                            Text(f.uppercased())
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(filter == f ? Color.black : .white.opacity(0.8))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(filter == f ? Theme.accent : Theme.card))
                        .overlay(Capsule().stroke(Theme.stroke, lineWidth: filter == f ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Shown when the library has no games at all (nothing bundled, nothing imported).
    private var noGamesState: some View {
        VStack(spacing: 14) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.accent.opacity(0.8))
            Text("No games available")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("Your library is empty. Would you like to import a game? Add your own files, or pick a ready-made pack (.zip).")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button { importTarget = ImportTarget(editId: nil) } label: {
                Text("IMPORT A GAME")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == "Favorites" && query.isEmpty ? "heart" : "magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
            Text(filter == "Favorites" && query.isEmpty ? "No favorites yet" : "No games found")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Text(filter == "Favorites" && query.isEmpty
                 ? "Touch and hold a floppy, or use the heart on its page."
                 : "Try a different search or filter.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private func grid(width: CGFloat, landscape: Bool) -> some View {
        let spacing: CGFloat = 16
        let auto = max(2, Int((width + spacing) / (landscape ? 190 : 170)))
        let cols = columnsPref == 0 ? auto : min(max(2, columnsPref), max(2, auto))
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: cols)
        return LazyVGrid(columns: columns, spacing: 22) {
            ForEach(visible) { g in
                Button { selected = g } label: { LibraryTile(game: g) }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
                        Button { resume(g) } label: {
                            Label(StateStore.hasAuto(g.id) ? "Continue" : "Play", systemImage: "play.fill")
                        }
                        Button { store.toggleFavorite(g.id) } label: {
                            Label(store.isFavorite(g.id) ? "Remove from favorites" : "Add to favorites",
                                  systemImage: store.isFavorite(g.id) ? "heart.slash" : "heart")
                        }
                        if g.isImported {
                            Button(role: .destructive) { pendingRemove = g } label: {
                                Label("Remove game", systemImage: "trash")
                            }
                        }
                    }
            }
        }
    }

    private var footer: some View {
        Group {
            if let d = UserDefaults.standard.string(forKey: "audioDiag") {
                Text(d).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3)).lineLimit(2)
            }
        }
    }
}

// MARK: - Continue card

struct ContinueCard: View {
    let game: Game
    let stats: GameStats
    let onResume: () -> Void
    let onOpen: () -> Void

    private var hasAuto: Bool { StateStore.hasAuto(game.id) }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let cover = resourceImage(game.id, "jpg", subdir: "posters") {
                    Image(uiImage: CoverTrim.trimmed(cover, key: game.id))
                        .resizable().scaledToFill()
                        .scaleEffect(1.18)                  // overfills the circle: white sticker edges stay outside the mask
                        .frame(width: 72, height: 72)
                        .clipped()
                } else {
                    Theme.card
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                Text(hasAuto ? "CONTINUE WHERE YOU LEFT OFF" : "JUMP BACK IN")
                    .font(Theme.mono).foregroundStyle(Theme.accent)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(game.title)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            Button(action: onResume) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: Theme.accent.opacity(0.45), radius: 14, y: 4)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(hasAuto ? "Continue" : "Play")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.14), Theme.card],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture(perform: onOpen)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = stats.lastPlayed { parts.append("Played \(LibraryStore.ago(d))") }
        if stats.seconds >= 60 { parts.append("\(LibraryStore.duration(stats.seconds)) total") }
        return parts.joined(separator: " · ")
    }
}
