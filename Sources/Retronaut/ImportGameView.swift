import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// What the import screen was opened for: a new game (editId == nil) or an existing imported one.
struct ImportTarget: Identifiable {
    let id = UUID()
    let editId: String?
}

private enum PickerKind { case folder, files, cover, pack }

/// Add or edit a game: everything the library, the detail page and the launcher need
/// (title, year, genre, developer, description, cover, files, launch script, sound).
struct ImportGameView: View {
    @Environment(\.dismiss) private var dismiss
    let editId: String?

    // Identity & library info
    @State private var gameId = ""
    @State private var title = ""
    @State private var year = "1995"
    @State private var developer = ""
    @State private var genre = ""
    @State private var blurb = ""
    @State private var engine = "DOSBox"

    // Launch
    @State private var exe = ""
    @State private var args = ""
    @State private var dir = ""
    @State private var cd = ""
    @State private var preText = ""
    @State private var mountsText = ""
    @State private var autoexec = ""
    @State private var customAutoexec = false
    @State private var sblaster = ""

    // Cover
    @State private var cover: UIImage?
    @State private var coverChanged = false
    @State private var photo: PhotosPickerItem?

    // Files
    @State private var scanResult = ImportedStore.Scan()
    @State private var keepFolder = false
    @State private var busy = false
    @State private var busyText = "Copying game files…"
    @State private var packName = ""
    @State private var packNotes: [String] = []
    @State private var extras = ImportedConfig()      // mouse / keys / dosbox from game.json, carried through unchanged

    // UI state
    @State private var picker: PickerKind = .folder
    @State private var showPicker = false
    @State private var showAdvanced = false
    @State private var confirmClear = false
    @State private var confirmRemove = false
    @State private var errorText: String?
    @State private var loaded = false

    private var isEdit: Bool { editId != nil }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                topBar.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // Only ready-made packs: no manual form, no tabs. Editing an imported pack keeps its own
                        // metadata + cover sheet (the pencil in Settings opens exactly this modal in edit mode).
                        if isEdit {
                            coverCard
                            infoCard
                            statusFooter
                            removeButton
                        } else {
                            packCard
                            statusFooter
                        }
                    }
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 20).padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            if busy {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().tint(Theme.accent)
                    Text(busyText).font(Theme.mono).foregroundStyle(.white)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.8)))
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .onAppear(perform: load)
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: picker == .folder ? [.folder] : (picker == .cover ? [.image] : (picker == .pack ? [.zip] : [.item])),
                      allowsMultipleSelection: picker == .files) { result in
            switch result {
            case .failure(let e): errorText = e.localizedDescription
            case .success(let urls):
                if picker == .cover { loadCover(from: urls.first) }
                else if picker == .pack { importPack(urls.first) }
                else { importFiles(urls) }
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    cover = img; coverChanged = true
                }
            }
        }
        .confirmationDialog("Delete all game files?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete files", role: .destructive) {
                ImportedStore.clearFiles(gameId)
                scanResult = ImportedStore.scan(gameId)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saves and settings are kept. You can add the files again.") }
        .confirmationDialog("Remove \(title)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove game and its saves", role: .destructive) {
                ImportedStore.delete(gameId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Deletes the files, save states and play history. This can't be undone.") }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("C:\\> IMPORT").font(Theme.mono).foregroundStyle(Theme.accent)
                Text(isEdit ? "Edit pack" : "Add a game")
                    .font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            }
            Spacer()
            Button(action: cancel) {
                Text("CANCEL")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Theme.card))
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            .disabled(busy)
            Button(action: save) {
                Text("SAVE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(canSave ? Theme.accent : Theme.accent.opacity(0.3)))
            }
            .buttonStyle(PressableStyle())
            .disabled(!canSave)
        }
    }

    // MARK: Cards

    private var coverCard: some View {
        card("COVER", icon: "photo.fill") {
            HStack(spacing: 16) {
                FloppyPreview(cover: cover)
                    .frame(width: 110)
                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $photo, matching: .images) { pill("Choose from Photos", "photo.on.rectangle") }
                    Button { open(.cover) } label: { pill("Choose from Files", "folder") }.buttonStyle(.plain)
                    if cover != nil {
                        Button { cover = nil; coverChanged = true; photo = nil } label: { pill("Remove cover", "xmark") }
                            .buttonStyle(.plain)
                    }
                    Text("Shown on the floppy in the library, the game page and “Continue”. Optional.")
                        .font(subFont).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    private var infoCard: some View {
        card("GAME INFO", icon: "info.circle.fill") {
            field("Title", "Commander Keen 4", $title, required: true)
            divider
            HStack(spacing: 12) {
                field("Year", "1991", $year, keyboard: .numberPad)
                field("Genre", "Platformer", $genre)
            }
            divider
            field("Developer", "id Software", $developer)
            divider
            VStack(alignment: .leading, spacing: 6) {
                Text("Description").font(labelFont).foregroundStyle(.white.opacity(0.6))
                TextEditor(text: $blurb)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
            }
        }
    }

    private var packCard: some View {
        card("READY-MADE PACK", icon: "shippingbox.fill") {
            Text("Pick a pack .zip (game files + game.json + meta.json + cover.jpg or cover.png). It is unpacked, set up and added to your library automatically.")
                .font(subFont).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            Button { open(.pack) } label: { pill("Choose pack (.zip)", "shippingbox") }
                .buttonStyle(.plain)
                .disabled(busy)
            if let e = errorText {
                Text(e).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.7)))
                    .onTapGesture { errorText = nil }
            }
        }
    }

    private var filesCard: some View {
        card("GAME FILES", icon: "externaldrive.fill") {
            Text("Everything you add becomes drive C: inside DOS. Add the game's folder (its contents go to the root of C:) or pick individual files such as .exe, .iso or .cue. A .zip is unpacked automatically (a single top-level folder inside it is flattened).")
                .font(subFont).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { open(.folder) } label: { pill("Add folder", "folder.badge.plus") }.buttonStyle(.plain)
                Button { open(.files) } label: { pill("Add files", "doc.badge.plus") }.buttonStyle(.plain)
            }
            Toggle(isOn: $keepFolder) {
                Text("Keep the folder name as a subfolder of C:").font(subFont).foregroundStyle(.white.opacity(0.7))
            }
            .tint(Theme.accent)
            divider
            HStack {
                Image(systemName: scanResult.files > 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(scanResult.files > 0 ? Theme.accent : Theme.amber)
                Text(scanResult.files > 0
                     ? "\(scanResult.files) files · \(ImportedStore.sizeString(scanResult.bytes))"
                     : "No files added yet")
                    .font(Theme.mono).foregroundStyle(.white)
                Spacer()
                if scanResult.files > 0 {
                    Button { confirmClear = true } label: {
                        Text("CLEAR").font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    }.buttonStyle(.plain)
                }
            }
            if let e = errorText {
                Text(e).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.7)))
                    .onTapGesture { errorText = nil }
            }
        }
    }

    private var launchCard: some View {
        card("LAUNCH", icon: "play.rectangle.fill") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Executable").font(labelFont).foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 8) {
                    textBox("GAME.EXE", $exe, mono: true)
                    if !scanResult.exes.isEmpty {
                        Menu {
                            ForEach(scanResult.exes, id: \.self) { p in
                                Button(p.replacingOccurrences(of: "/", with: "\\")) { pickExe(p) }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 38, height: 38).background(Circle().fill(Theme.accent))
                        }
                    }
                }
                Text(scanResult.exes.isEmpty
                     ? "Leave empty to start at the DOS prompt (C:\\>)."
                     : "Tap the list to choose from \(scanResult.exes.count) program(s) found in your files. Leave empty to start at the DOS prompt.")
                    .font(subFont).foregroundStyle(.white.opacity(0.45))
            }
            divider
            field("Arguments", "e.g. /nosound", $args, mono: true)
            divider
            field("Start in folder", "e.g. KEEPER (folder inside C:)", $dir, mono: true)
        }
    }

    private var advancedCard: some View {
        card("ADVANCED", icon: "slider.horizontal.3") {
            Button { withAnimation(.snappy) { showAdvanced.toggle() } } label: {
                HStack {
                    Text(showAdvanced ? "Hide advanced options" : "Show advanced options")
                        .font(rowFont).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down").foregroundStyle(.white.opacity(0.5))
                }
            }.buttonStyle(.plain)

            if showAdvanced {
                divider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Engine").font(labelFont).foregroundStyle(.white.opacity(0.6))
                    Picker("Engine", selection: $engine) {
                        Text("DOSBox").tag("DOSBox")
                        if ImportedStore.scummvmAvailable || engine == "ScummVM" { Text("ScummVM").tag("ScummVM") }
                    }.pickerStyle(.segmented)
                    Text(ImportedStore.scummvmAvailable
                         ? "ScummVM autodetects the game from its data files (all in one folder); the DOS script below is ignored."
                         : "ScummVM isn't bundled in this build, so only DOSBox is available.")
                        .font(subFont).foregroundStyle(.white.opacity(0.45))
                }
                divider
                VStack(alignment: .leading, spacing: 6) {
                    Text("CD image (mounted as D:)").font(labelFont).foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        textBox("path/inside/game/files.iso", $cd, mono: true)
                        if !scanResult.images.isEmpty {
                            Menu {
                                ForEach(scanResult.images, id: \.self) { p in Button(p) { cd = p } }
                            } label: {
                                Image(systemName: "opticaldisc")
                                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                                    .frame(width: 38, height: 38).background(Circle().fill(Theme.accent))
                            }
                        }
                    }
                }
                divider
                multiline("Commands before the program", "One DOS command per line, run after C: (and after “Start in folder”). Example: cd data",
                          $preText)
                divider
                multiline("Extra mounts", "Run before C: is selected, one per line. Example: imgmount d \"{data}/disc.iso\" -t iso",
                          $mountsText)
                divider
                field("Sound Blaster", "A220 I5 D1 H5 (default)", $sblaster, mono: true)
                divider
                Toggle(isOn: $customAutoexec) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Write the whole DOS script myself").font(rowFont).foregroundStyle(.white)
                        Text("Replaces everything generated above. Start with: mount c \"{data}\"")
                            .font(subFont).foregroundStyle(.white.opacity(0.45))
                    }
                }.tint(Theme.accent)
                if customAutoexec {
                    TextEditor(text: $autoexec)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .foregroundStyle(.white)
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
                }
                Text("{data} stands for the folder holding your game files.")
                    .font(subFont).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var previewCard: some View {
        card("DOS SCRIPT PREVIEW", icon: "terminal.fill") {
            Text(previewText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.accent.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var statusFooter: some View {
        VStack(spacing: 6) {
            if !missing.isEmpty {
                Text("Still needed: " + missing.joined(separator: ", "))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.amber)
            }
            Text("Save states, the pause menu, favourites and play time work for imported games automatically.")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) { confirmRemove = true } label: {
            Text("REMOVE THIS GAME")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                .padding(.vertical, 12).frame(maxWidth: .infinity)
        }
    }

    // MARK: Logic

    private var missing: [String] {
        var m: [String] = []
        if title.trimmingCharacters(in: .whitespaces).isEmpty { m.append("a title") }
        if scanResult.files == 0 { m.append("game files") }
        return m
    }

    private var canSave: Bool { missing.isEmpty && !busy }

    private func config() -> ImportedConfig {
        func lines(_ s: String) -> [String] {
            s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var c = ImportedConfig()
        c.core = engine == "ScummVM" ? "scummvm" : "dosbox"
        c.exe = exe.trimmingCharacters(in: .whitespaces)
        c.args = args.trimmingCharacters(in: .whitespaces)
        c.dir = dir.trimmingCharacters(in: .whitespaces)
        c.cd = cd.trimmingCharacters(in: .whitespaces)
        c.pre = lines(preText)
        c.mounts = lines(mountsText)
        c.autoexec = customAutoexec ? autoexec : ""
        c.sblaster = sblaster.trimmingCharacters(in: .whitespaces)
        c.mouse = extras.mouse; c.keys = extras.keys; c.dosbox = extras.dosbox
        c.baseos = extras.baseos; c.drive = extras.drive; c.files = extras.files
        return c
    }

    private var previewText: String {
        if engine == "ScummVM" { return "ScummVM autodetects the game from a file in its data folder." }
        let c = config()
        if !c.baseos.isEmpty {
            return "Boots the shared \(BaseOS.displayName(c.baseos)) disk as C:, this pack's drive\(c.drive.isEmpty ? "" : " " + c.drive) as the game drive\(c.cd.isEmpty ? "" : " and " + c.cd + " as the CD-ROM"), then runs its AUTORUN.BAT\(c.baseos == BaseOS.win31.id ? " (DOS side) and starts Windows." : ".")"
        }
        guard let data = try? JSONEncoder().encode(c),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let id = gameId.isEmpty ? "preview" : gameId
        let script = GameRunner.standardScript(dataDir: ImportedStore.dataDir(id), cfg: dict)
        let text = script.joined(separator: "\n")
        return c.exe.isEmpty && c.autoexec.isEmpty ? text + "\n(no program: starts at the DOS prompt)" : text
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let id = editId, let m = ImportedStore.meta(id) {
            gameId = id
            title = m.title; year = String(m.year); developer = m.developer; genre = m.genre; blurb = m.blurb
            engine = m.engine
            let c = ImportedStore.config(id)
            exe = c.exe; args = c.args; dir = c.dir; cd = c.cd
            preText = c.pre.joined(separator: "\n"); mountsText = c.mounts.joined(separator: "\n")
            autoexec = c.autoexec; customAutoexec = !c.autoexec.isEmpty
            sblaster = c.sblaster
            extras = c
            if let u = ImportedStore.coverURL(id) { cover = UIImage(contentsOfFile: u.path) }
            scanResult = ImportedStore.scan(id)
            showAdvanced = customAutoexec || !c.pre.isEmpty || !c.mounts.isEmpty || !c.cd.isEmpty || !c.sblaster.isEmpty
        } else {
            gameId = ImportedStore.newId(for: "game")
        }
    }

    private func open(_ kind: PickerKind) {
        picker = kind
        showPicker = true
    }

    private func pickExe(_ path: String) {
        let comps = path.split(separator: "/").map(String.init)
        exe = comps.last ?? path
        dir = comps.dropLast().joined(separator: "\\")
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = true
        errorText = nil
        let id = gameId, keep = keepFolder
        if title.trimmingCharacters(in: .whitespaces).isEmpty, urls.count == 1,
           (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            title = urls[0].lastPathComponent
        }
        Task.detached {
            var err: String?
            do { try ImportedStore.copyIn(urls, into: id, keepFolderName: keep) }
            catch { err = error.localizedDescription }
            let sc = ImportedStore.scan(id)
            await MainActor.run {
                scanResult = sc
                busy = false
                errorText = err
                if exe.trimmingCharacters(in: .whitespaces).isEmpty, !customAutoexec, extras.baseos.isEmpty, let first = sc.exes.first { pickExe(first) }
            }
        }
    }

    private func importPack(_ url: URL?) {
        guard let url else { return }
        busy = true
        busyText = "Unpacking pack…"
        errorText = nil
        let id = gameId
        Task.detached {
            var res: PackImporter.Result?
            var err: String?
            ImportedStore.clearFiles(id)
            do { res = try PackImporter.importPack(url, into: id) }
            catch { err = error.localizedDescription }
            let sc = ImportedStore.scan(id)
            await MainActor.run {
                busy = false
                busyText = "Copying game files…"
                scanResult = sc
                errorText = err
                guard let r = res else { return }
                title = r.title; year = String(r.year); genre = r.genre; developer = r.developer; blurb = r.blurb
                engine = r.engine
                let c = r.config
                exe = c.exe; args = c.args; dir = c.dir; cd = c.cd
                preText = c.pre.joined(separator: "\n"); mountsText = c.mounts.joined(separator: "\n")
                autoexec = c.autoexec; customAutoexec = !c.autoexec.isEmpty
                sblaster = c.sblaster
                cover = r.cover; coverChanged = true; photo = nil
                extras = c
                packName = url.deletingPathExtension().lastPathComponent
                packNotes = r.notes
                if sc.files == 0 {
                    errorText = "The pack contains no game files."
                    return
                }
                save()          // a pack needs no review: add it to the library right away
            }
        }
    }

    private func loadCover(from url: URL?) {
        guard let url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            cover = img; coverChanged = true
        } else {
            errorText = "Couldn't read that image."
        }
    }

    private func cancel() {
        if !isEdit { ImportedStore.discardStaging(gameId) }
        dismiss()
    }

    private func save() {
        guard canSave else { return }
        let y = Int(year.trimmingCharacters(in: .whitespaces)) ?? 1990
        let meta = ImportedMeta(id: gameId,
                                title: title.trimmingCharacters(in: .whitespaces),
                                year: min(max(y, 1970), 2100),
                                genre: genre.trimmingCharacters(in: .whitespaces),
                                developer: developer.trimmingCharacters(in: .whitespaces),
                                blurb: blurb.trimmingCharacters(in: .whitespacesAndNewlines),
                                engine: engine)
        do {
            try ImportedStore.save(meta: meta, config: config())
            if coverChanged {
                if let c = cover { ImportedStore.saveCover(c, id: gameId) } else { ImportedStore.removeCover(gameId) }
            }
            Library.shared.reload()
            dismiss()
        } catch {
            errorText = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: Building blocks

    private var rowFont: Font { .system(size: 15, weight: .semibold, design: .rounded) }
    private var labelFont: Font { .system(size: 12, weight: .semibold, design: .rounded) }
    private var subFont: Font { .system(size: 12, weight: .regular, design: .rounded) }
    private var divider: some View { Divider().overlay(Theme.stroke) }

    private func pill(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
            Text(text).font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    private func textBox(_ placeholder: String, _ text: Binding<String>, mono: Bool = false,
                         keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 14, weight: .medium, design: mono ? .monospaced : .rounded))
            .foregroundStyle(.white)
            .keyboardType(keyboard)
            .textInputAutocapitalization(mono ? .never : .words)
            .autocorrectionDisabled()
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>, mono: Bool = false,
                       required: Bool = false, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label + (required ? " *" : "")).font(labelFont).foregroundStyle(.white.opacity(0.6))
            textBox(placeholder, text, mono: mono, keyboard: keyboard)
        }
    }

    private func multiline(_ label: String, _ hint: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(labelFont).foregroundStyle(.white.opacity(0.6))
            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .font(.system(size: 13, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .foregroundStyle(.white)
                .frame(minHeight: 70)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
            Text(hint).font(subFont).foregroundStyle(.white.opacity(0.45))
        }
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

/// The library's floppy with a chosen cover (or the empty disk) so the cover can be judged before saving.
private struct FloppyPreview: View {
    let cover: UIImage?
    var body: some View {
        Group {
            if let disk = resourceImage("floppy", "png") {
                Image(uiImage: disk).resizable().interpolation(.high).scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            if let cover {
                                Image(uiImage: cover).resizable().interpolation(.high).scaledToFill()
                                    .scaleEffect(1.22)
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
