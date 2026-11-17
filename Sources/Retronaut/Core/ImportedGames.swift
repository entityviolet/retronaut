import UIKit
import Foundation

/// User-imported games live next to the materialised bundled ones:
///
///   Documents/games/<id>/data/        the game's files (mounted as C:)
///   Documents/games/<id>/game.json    launch configuration (same keys the bundled games use, plus a few extras)
///   Documents/games/<id>/meta.json    title, year, genre ... (its presence is what marks a game as imported)
///   Documents/games/<id>/cover.jpg    optional cover picture
///
/// Bundled games are never touched by anything in this file.

struct ImportedMeta: Codable, Identifiable {
    var id: String
    var title: String
    var year: Int
    var genre: String
    var developer: String
    var blurb: String
    var engine: String          // "DOSBox" | "ScummVM"

    var game: Game {
        Game(id: id, title: title, year: year, tag: engine,
             developer: developer, genre: genre, blurb: blurb, source: "imported")
    }
}

/// game.json. Keys core / exe / args / cd / pre match the bundled games; the rest are optional extras.
struct ImportedConfig: Codable {
    var core = "dosbox"        // "dosbox" | "scummvm"
    var exe = ""               // program to run, e.g. DAVE.EXE
    var args = ""              // its command-line arguments
    var dir = ""               // folder inside C: to cd into before running (e.g. KEEPER)
    var cd = ""                // CD image inside the game files, mounted as D:
    var pre: [String] = []     // DOS commands run after `c:` and before the exe
    var mounts: [String] = []  // extra DOS lines run before `c:` (mount / imgmount ...)
    var autoexec = ""          // if set, replaces the whole generated script
    var sblaster = ""          // Sound Blaster config, e.g. "A220 I5 D1 H5"
    var mouse = ""             // "absolute" | "relative" ("" = use the Settings default)
    var keys: [String] = []    // keys the game needs, e.g. ["ESC", "F1", "PGUP"]: made reachable on keyboards that lack them
    var dosbox: [String: String] = [:]   // machine / memsize / sound / cycles
    var files: [String: String] = [:]   // text files created on C: when missing: path -> contents (config / ini / cfg the game expects)
    var baseos = ""            // "win98": boot the app's shared Windows 98 disk as C:; the pack's `drive` image becomes D:, `cd` a CD-ROM
    var drive = ""             // baseos only: game-drive image inside the pack ("" = auto-pick the largest .img/.vhd)

    init() {}

    enum CodingKeys: String, CodingKey { case core, exe, args, dir, cd, pre, mounts, autoexec, sblaster, mouse, keys, dosbox, files, baseos, drive }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        core = try c.decodeIfPresent(String.self, forKey: .core) ?? "dosbox"
        exe = try c.decodeIfPresent(String.self, forKey: .exe) ?? ""
        args = try c.decodeIfPresent(String.self, forKey: .args) ?? ""
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        cd = try c.decodeIfPresent(String.self, forKey: .cd) ?? ""
        pre = try c.decodeIfPresent([String].self, forKey: .pre) ?? []
        mounts = try c.decodeIfPresent([String].self, forKey: .mounts) ?? []
        autoexec = try c.decodeIfPresent(String.self, forKey: .autoexec) ?? ""
        sblaster = try c.decodeIfPresent(String.self, forKey: .sblaster) ?? ""
        mouse = try c.decodeIfPresent(String.self, forKey: .mouse) ?? ""
        keys = try c.decodeIfPresent([String].self, forKey: .keys) ?? []
        dosbox = try c.decodeIfPresent([String: String].self, forKey: .dosbox) ?? [:]
        files = try c.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
        baseos = try c.decodeIfPresent(String.self, forKey: .baseos) ?? ""
        drive = try c.decodeIfPresent(String.self, forKey: .drive) ?? ""
    }
}

enum ImportedStore {
    // MARK: Paths

    static var root: URL { GameLibrary.shared.documents() }
    static func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func dataDir(_ id: String) -> URL { dir(id).appendingPathComponent("data", isDirectory: true) }
    static func metaURL(_ id: String) -> URL { dir(id).appendingPathComponent("meta.json") }
    static func configURL(_ id: String) -> URL { dir(id).appendingPathComponent("game.json") }

    static func coverURL(_ id: String) -> URL? {
        let fm = FileManager.default
        // A pack carries its own poster (cover.jpg next to game.json); an imported cover set in the app wins.
        for u in [dir(id).appendingPathComponent("cover.jpg"), dataDir(id).appendingPathComponent("cover.jpg")] {
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func isImported(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: metaURL(id).path)
    }

    /// ScummVM games need the optional scummvm core to be bundled.
    static var scummvmAvailable: Bool {
        if let p = Bundle.module.resourceURL?.appendingPathComponent("Cores/scummvm.dylib").path,
           FileManager.default.fileExists(atPath: p) { return true }
        return Res.path("Cores/scummvm.dylib") != nil
    }

    // MARK: Read

    static func all() -> [ImportedMeta] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { u -> ImportedMeta? in
            guard let d = try? Data(contentsOf: u.appendingPathComponent("meta.json")),
                  var m = try? JSONDecoder().decode(ImportedMeta.self, from: d) else { return nil }
            m.id = u.lastPathComponent
            return m
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func meta(_ id: String) -> ImportedMeta? { all().first { $0.id == id } }

    static func config(_ id: String) -> ImportedConfig {
        guard let d = try? Data(contentsOf: configURL(id)),
              let c = try? JSONDecoder().decode(ImportedConfig.self, from: d) else { return ImportedConfig() }
        return c
    }

    /// Same file as a dictionary, the shape GameRunner reads.
    static func rawConfig(_ id: String) -> [String: Any]? {
        var merged: [String: Any] = [:]
        if let d = try? Data(contentsOf: configURL(id)),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { merged = o }
        // A pack shipped as a folder (game.json next to the disk images) is the source of truth for the fields the
        // stored copy may predate, above all `baseos`: without it a Windows 3.1 / 98 pack is started as plain DOS.
        let onDisk = dataDir(id).appendingPathComponent("game.json")
        if let d = try? Data(contentsOf: onDisk),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in o { merged[k] = v }
        }
        return merged.isEmpty ? nil : merged
    }

    // MARK: Write

    static func newId(for title: String) -> String {
        let slug = String(title.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(16))
        let tag = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
        return "imp_\(slug.isEmpty ? "game" : slug)_\(tag)"
    }

    /// Creates the (still invisible) staging folder for a new game.
    static func stage(_ id: String) {
        try? FileManager.default.createDirectory(at: dataDir(id), withIntermediateDirectories: true)
    }

    /// meta.json is written last: until then the folder is not a game.
    static func save(meta: ImportedMeta, config: ImportedConfig) throws {
        try FileManager.default.createDirectory(at: dataDir(meta.id), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: configURL(meta.id), options: .atomic)
        try enc.encode(meta).write(to: metaURL(meta.id), options: .atomic)
    }

    static func saveCover(_ image: UIImage, id: String) {
        let maxSide: CGFloat = 640
        let s = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * s), height: max(1, image.size.height * s))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        if let jpg = scaled.jpegData(compressionQuality: 0.85) {
            try? jpg.write(to: dir(id).appendingPathComponent("cover.jpg"), options: .atomic)
        }
    }

    static func removeCover(_ id: String) {
        try? FileManager.default.removeItem(at: dir(id).appendingPathComponent("cover.jpg"))
    }

    /// Removes an imported game completely: files, saves, favourite and play statistics.
    /// Does nothing for bundled games.
    static func delete(_ id: String) {
        guard isImported(id) else { return }
        try? FileManager.default.removeItem(at: dir(id))
        try? FileManager.default.removeItem(at: StateStore.dir(id))
        LibraryStore.shared.forget(id)
        Library.shared.reload()
    }

    /// Drops staging folders of imports that were started but never saved. Run once at launch.
    static func cleanupOrphans() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for u in items where u.lastPathComponent.hasPrefix("imp_") && !isImported(u.lastPathComponent) {
            try? fm.removeItem(at: u)
        }
    }

    /// Throws away a staging folder (user cancelled a new import).
    static func discardStaging(_ id: String) {
        guard !isImported(id), id.hasPrefix("imp_") else { return }
        try? FileManager.default.removeItem(at: dir(id))
    }

    // MARK: Copying game files in

    /// Copies picked files/folders into the game's data folder (= drive C:). A picked folder's
    /// *contents* go to the root of C: unless `keepFolderName` is set. Existing files are replaced.
    @discardableResult
    static func copyIn(_ urls: [URL], into id: String, keepFolderName: Bool) throws -> Int {
        let fm = FileManager.default
        let data = dataDir(id)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        var count = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let target = keepFolderName ? data.appendingPathComponent(url.lastPathComponent, isDirectory: true) : data
                count += try copyTree(url, to: target)
            } else if url.pathExtension.lowercased() == "zip" {
                // Unpacked into C:. A single top-level folder inside the zip is flattened unless "keep folder name" is on.
                count += try ZipExtractor.extract(url, to: data, stripSingleRoot: !keepFolderName)
            } else {
                count += try copyFile(url, to: data.appendingPathComponent(url.lastPathComponent))
            }
        }
        return count
    }

    private static func copyFile(_ src: URL, to dst: URL) throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        return 1
    }

    private static func copyTree(_ src: URL, to dst: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var n = 0
        for item in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey]) {
            if item.lastPathComponent.hasPrefix(".") { continue }      // .DS_Store etc.
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let target = dst.appendingPathComponent(item.lastPathComponent, isDirectory: isDir)
            if isDir {
                n += try copyTree(item, to: target)
            } else {
                n += try copyFile(item, to: target)
            }
        }
        return n
    }

    static func clearFiles(_ id: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: dataDir(id))
        try? fm.createDirectory(at: dataDir(id), withIntermediateDirectories: true)
    }

    // MARK: Inspecting the copied files

    struct Scan {
        var files = 0
        var bytes: Int64 = 0
        var exes: [String] = []       // relative paths, "/" separated
        var images: [String] = []     // iso / cue / img / bin / mdf
    }

    static func scan(_ id: String) -> Scan {
        var s = Scan()
        let fm = FileManager.default
        let base = dataDir(id).path
        guard let en = fm.enumerator(atPath: base) else { return s }
        while let rel = en.nextObject() as? String {
            let attrs = en.fileAttributes
            if (attrs?[.type] as? FileAttributeType) == .typeDirectory { continue }
            if (rel as NSString).lastPathComponent.hasPrefix(".") { continue }
            s.files += 1
            s.bytes += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            switch (rel as NSString).pathExtension.lowercased() {
            case "exe", "com", "bat": s.exes.append(rel)
            case "iso", "cue", "img", "bin", "mdf", "ima": s.images.append(rel)
            default: break
            }
            if s.exes.count > 400 { break }
        }
        let junk = ["setup", "install", "uninst", "config", "readme", "unins", "setsound", "sound", "vesa", "univbe"]
        func rank(_ p: String) -> (Int, Int, String) {
            let name = ((p as NSString).lastPathComponent).lowercased()
            let bad = junk.contains { name.contains($0) } ? 1 : 0
            let ext = (name as NSString).pathExtension
            let launcher = ["run", "start", "play", "go"].contains((name as NSString).deletingPathExtension) ? 0 : 1
            return (bad * 4 + launcher + (ext == "bat" ? 0 : 1), p.split(separator: "/").count, name)
        }
        s.exes.sort { rank($0) < rank($1) }
        s.images.sort()
        return s
    }

    static func sizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
