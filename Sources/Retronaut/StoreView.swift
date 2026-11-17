import SwiftUI

// MARK: - Store screen
//
// Data lives in StoreModel.swift, tiles / banners / install button in StoreComponents.swift,
// the per-game modal in StoreDetailView.swift. The backend is a plain static folder:
//   store.json + covers/<file> + packs/<pack>.zip

struct StoreView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StoreLink.key) private var storeURL = ""
    @AppStorage("libraryColumns") private var columnsPref: Int = 0      // shared with the shelf: Auto / 2 / 4 / 6
    @AppStorage("storeSort") private var sort = "default"               // default | yearDesc | title | size
    @StateObject private var model = StoreModel()
    @ObservedObject private var library = Library.shared

    @State private var editing = false
    @State private var selected: StorePack?
    @State private var query = ""
    @State private var filter = "All"
    @State private var heroID: String?
    @FocusState private var searchFocused: Bool

    private var baseURL: URL? { StoreLink.normalize(storeURL) }

    /// Read from the library on every change: deleting a game on the shelf makes its floppy installable again,
    /// and installing one flips its tile to INSTALLED without restarting anything.
    private var installedIDs: Set<String> {
        Set(model.packs.filter { StoreInstalls.isInstalled($0, games: library.games) }.map { $0.id })
    }

    private var isFiltering: Bool { filter != "All" || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var filters: [String] {
        let systems = Array(Set(model.packs.map { $0.systemText })).sorted()
        return ["All", "Available", "Installed"] + systems
    }

    private func visible(_ installed: Set<String>) -> [StorePack] {
        var list = model.packs
        switch filter {
        case "All": break
        case "Available": list = list.filter { !installed.contains($0.id) }
        case "Installed": list = list.filter { installed.contains($0.id) }
        default: list = list.filter { $0.systemText == filter }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                "\($0.title) \($0.developer ?? "") \($0.genreText) \($0.year) \($0.systemText) \(($0.tags ?? []).joined(separator: " "))"
                    .lowercased().contains(q)
            }
        }
        switch sort {
        case "yearDesc": list.sort { ($0.year, $0.title) > ($1.year, $1.title) }
        case "title": list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "size": list.sort { ($0.size_mb ?? 0) < ($1.size_mb ?? 0) }
        default: break
        }
        return list
    }

    var body: some View {
        ZStack {
            AppBackground()
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                VStack(spacing: 0) {
                    topBar
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            if let base = baseURL {
                                catalogue(width: geo.size.width - 40, landscape: landscape, base: base)
                            } else {
                                setupCard
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 30)
                        .frame(width: geo.size.width, alignment: .leading)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable { if let b = baseURL { await model.load(baseURL: b) } }
                }
            }
            toastView
        }
        .preferredColorScheme(.dark)
        .task(id: storeURL) {
            heroID = nil
            if let b = baseURL { await model.load(baseURL: b) }
        }
        .sheet(isPresented: $editing) { linkSheet }
        .fullScreenCover(item: $selected) { p in
            StoreDetailView(pack: p, model: model) { selected = nil }
        }
        .alert("Store", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .onChange(of: model.toast) { _, new in
            guard new != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                withAnimation(.easeOut(duration: 0.25)) { model.toast = nil }
            }
        }
    }

    // MARK: Catalogue

    @ViewBuilder
    private func catalogue(width: CGFloat, landscape: Bool, base: URL) -> some View {
        let installed = installedIDs
        if model.packs.isEmpty {
            if model.loading { skeleton(width: width, landscape: landscape) } else { emptyState }
        } else {
            if !isFiltering && !model.featured.isEmpty {
                featuredSection(width: width, installed: installed)
            }
            searchRow
            filterBar
            let list = visible(installed)
            sectionHeader(count: list.count, installedCount: installed.count)
            if list.isEmpty {
                noResults
            } else {
                grid(list, width: width, landscape: landscape, installed: installed)
            }
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("C:\\> STORE")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.accent)
                Text("Game Store")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 10)

            if model.loading {
                ProgressView().tint(Theme.accent).frame(width: 38, height: 38)
            } else if baseURL != nil {
                roundButton("arrow.clockwise", label: "Refresh") {
                    if let b = baseURL { Task { await model.load(baseURL: b) } }
                }
            }
            roundButton("link", label: "Store link") { editing = true }
            roundButton("xmark", label: "Close", weight: .heavy) { dismiss() }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
    }

    private var subtitle: String {
        guard baseURL != nil else { return "Connect a store to browse games" }
        if model.loading && model.packs.isEmpty { return "Loading…" }
        if model.packs.isEmpty { return model.loadFailed ? "Couldn't reach the store" : "Empty" }
        var s = model.storeName.isEmpty ? "" : model.storeName + " · "
        s += "\(model.packs.count) games"
        return s
    }

    private func roundButton(_ icon: String, label: String, weight: Font.Weight = .bold, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: weight))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.card))
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private var linkSheet: some View {
        NavigationStack {
            ScrollView {
                StoreLinkEditor(current: storeURL,
                                onSave: { v in storeURL = v; editing = false },
                                onRemove: { storeURL = ""; editing = false })
                    .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Store link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { editing = false } } }
            .preferredColorScheme(.dark)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Featured carousel

    private func featuredSection(width: CGFloat, installed: Set<String>) -> some View {
        let spacing: CGFloat = 14
        let perPage: CGFloat = width > 940 ? 3 : (width > 620 ? 2 : 1)
        let cardW = perPage == 1 ? (width - 20) * 0.9 : (width - spacing * (perPage - 1)) / perPage
        let items = model.featured
        let paged = items.count > Int(perPage)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FEATURED").font(Theme.mono).foregroundStyle(.white.opacity(0.45))
                Spacer()
                if paged {
                    HStack(spacing: 5) {
                        ForEach(items) { p in
                            Capsule()
                                .fill(p.id == (heroID ?? items.first?.id) ? Theme.accent : Color.white.opacity(0.25))
                                .frame(width: p.id == (heroID ?? items.first?.id) ? 16 : 6, height: 6)
                        }
                    }
                    .animation(.snappy, value: heroID)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(items) { p in
                        StoreBanner(pack: p,
                                    cover: model.coverURL(p),
                                    installed: installed.contains(p.id),
                                    busy: model.isInstalling(p),
                                    progress: model.progress,
                                    phase: model.phase,
                                    locked: model.isBusy && !model.isInstalling(p),
                                    onOpen: { selected = p },
                                    onInstall: { model.install(p) },
                                    onCancel: { model.cancel() })
                            .frame(width: cardW)
                            .id(p.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 8)
            }
            .scrollPosition(id: $heroID)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .padding(.horizontal, -20)
        }
    }

    // MARK: Search / filter

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Search the store", text: $query)
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
                menuIcon("square.grid.2x2", active: columnsPref != 0)
            }
            .accessibilityLabel("Tiles per row")

            Menu {
                Picker("Sort", selection: $sort) {
                    Label("Oldest first", systemImage: "calendar").tag("default")
                    Label("Newest first", systemImage: "calendar.badge.clock").tag("yearDesc")
                    Label("Title A–Z", systemImage: "textformat").tag("title")
                    Label("Smallest download", systemImage: "arrow.down.circle").tag("size")
                }
            } label: {
                menuIcon("arrow.up.arrow.down", active: sort != "default")
            }
            .accessibilityLabel("Sort")
        }
    }

    private func menuIcon(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? Theme.accent : .white.opacity(0.8))
            .frame(width: 40, height: 40)
            .background(Circle().fill(Theme.card))
            .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { f in
                    Button { withAnimation(.snappy) { filter = f } } label: {
                        Text(f.uppercased())
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

    private func sectionHeader(count: Int, installedCount: Int) -> some View {
        HStack {
            Text(isFiltering ? "RESULTS" : "ALL GAMES").font(Theme.mono).foregroundStyle(.white.opacity(0.45))
            Text("\(count)").font(Theme.mono).foregroundStyle(Theme.accent)
            Spacer()
            if installedCount > 0 {
                Text("\(installedCount) INSTALLED").font(Theme.mono).foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    // MARK: Grid — the shelf's exact maths + its Auto / 2 / 4 / 6 preference

    private func columnCount(width: CGFloat, landscape: Bool) -> Int {
        let spacing: CGFloat = 16
        let auto = max(2, Int((width + spacing) / (landscape ? 190 : 170)))
        return columnsPref == 0 ? auto : min(max(2, columnsPref), max(2, auto))
    }

    private func grid(_ list: [StorePack], width: CGFloat, landscape: Bool, installed: Set<String>) -> some View {
        let cols = columnCount(width: width, landscape: landscape)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: cols)
        return LazyVGrid(columns: columns, spacing: 18) {
            ForEach(list) { p in
                StoreTile(pack: p,
                          cover: model.coverURL(p),
                          installed: installed.contains(p.id),
                          busy: model.isInstalling(p),
                          progress: model.progress,
                          phase: model.phase,
                          locked: model.isBusy && !model.isInstalling(p),
                          onOpen: { selected = p },
                          onInstall: { model.install(p) },
                          onCancel: { model.cancel() })
            }
        }
    }

    private func skeleton(width: CGFloat, landscape: Bool) -> some View {
        let cols = columnCount(width: width, landscape: landscape)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: cols)
        return LazyVGrid(columns: columns, spacing: 18) {
            ForEach(0..<(cols * 2), id: \.self) { _ in StoreSkeletonTile() }
        }
    }

    // MARK: States

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white.opacity(0.3))
            Text("No games found")
                .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
            Text("Try a different search or filter.")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.loadFailed ? "wifi.exclamationmark" : "tray")
                .font(.system(size: 36, weight: .bold)).foregroundStyle(Theme.accent.opacity(0.7))
            Text(model.loadFailed ? "Can't reach the store" : "Nothing on the shelf")
                .font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            Text("Check the link — it must point at the folder that holds store.json.")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            if let b = baseURL {
                Text(b.absoluteString)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 10) {
                Button { if let b = baseURL { Task { await model.load(baseURL: b) } } } label: {
                    Text("TRY AGAIN")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(1)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(PressableStyle())
                Button { editing = true } label: {
                    Text("EDIT LINK")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(1)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(Capsule().fill(Theme.card))
                        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var setupCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "bag.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 84, height: 84)
                .background(Circle().fill(Theme.accent))
                .shadow(color: Theme.accent.opacity(0.45), radius: 18, y: 6)
            Text("Connect your store")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            StoreLinkEditor(current: "", onSave: { storeURL = $0 })
        }
        .padding(24)
        .frame(maxWidth: 520)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    @ViewBuilder private var toastView: some View {
        if let t = model.toast {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    Text(t).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .padding(.bottom, 24)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }
}
