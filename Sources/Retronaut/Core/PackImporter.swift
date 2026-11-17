import UIKit
import Foundation

/// Ready-made pack import. A pack is a .zip holding the game plus its description:
///
///   <any folder>/            (or the zip root)
///       game.json            launch rules (core, exe, args, dir, cd, pre, mounts, autoexec, sblaster, dataSubdir ...)
///       meta.json            optional: id, title, year, genre, developer, blurb, engine
///       cover.jpg | .png     optional cover
///       ...game files...     become drive C: (or the `dataSubdir` folder only, when game.json names one)
///
/// The importer unpacks into the game's staging folder and returns everything the import screen
/// needs; paths in game.json are matched case-insensitively and repaired when they don't line up.
enum PackImporter {
    struct Result {
        var title = ""
        var year = 1990
        var genre = ""
        var developer = ""
        var blurb = ""
        var engine = "DOSBox"
        var config = ImportedConfig()
        var cover: UIImage?
        var notes: [String] = []
    }

    struct PackError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let metaNames: Set<String> = ["game.json", "meta.json", "dk-entry.json"]
    private static let coverNames: Set<String> = ["cover.jpg", "cover.jpeg", "cover.png"]

    // MARK: Entry point

    /// Unpacks `zip` into the data folder of game `id` (replacing whatever was there).
    static func importPack(_ zip: URL, into id: String) throws -> Result {
        let fm = FileManager.default
        let scoped = zip.startAccessingSecurityScopedResource()
        defer { if scoped { zip.stopAccessingSecurityScopedResource() } }

        ImportedStore.stage(id)
        let stage = ImportedStore.dir(id).appendingPathComponent("pack_tmp", isDirectory: true)
        try? fm.removeItem(at: stage)
        defer { try? fm.removeItem(at: stage) }
        try ZipExtractor.extract(zip, to: stage, stripSingleRoot: false)

        // A pack normally carries game.json. A plain zip of game files (no game.json) is accepted too:
        // everything lands on C: and the launcher / boot disk is guessed.
        let declared = findRoot(stage)
        guard let root = declared ?? looseRoot(stage) else {
            throw PackError(message: "The zip is empty.")
        }

        var game = readJSON(root.appendingPathComponent(actualName("game.json", in: root) ?? "game.json"))
        let meta = readJSON(root.appendingPathComponent(actualName("meta.json", in: root) ?? "meta.json"))
        if declared != nil && game.isEmpty && meta.isEmpty { throw PackError(message: "game.json couldn't be read.") }
        // game.json may carry the meta keys itself (id/title/year/tag); meta.json wins when both exist.
        for (k, v) in meta { game[k] = v }

        var r = Result()
        r.title = str(game["title"]).trimmingCharacters(in: .whitespaces)
        if r.title.isEmpty { r.title = str(game["name"]) }
        if r.title.isEmpty { r.title = root == stage ? zip.deletingPathExtension().lastPathComponent : root.lastPathComponent }
        r.year = Int(str(game["year"])) ?? 1990
        r.genre = str(game["genre"])
        r.developer = str(game["developer"])
        if r.developer.isEmpty { r.developer = str(game["publisher"]) }
        r.blurb = str(game["blurb"])
        if r.blurb.isEmpty { r.blurb = str(game["description"]) }

        var core = str(game["core"]).lowercased()
        let engineHint = (str(game["engine"]) + " " + str(game["tag"])).lowercased()
        if core.isEmpty { core = engineHint.contains("scumm") ? "scummvm" : "dosbox" }
        r.engine = core == "scummvm" ? "ScummVM" : "DOSBox"

        // Which folder becomes drive C:
        var source = root
        for key in ["dataSubdir", "dataDir", "dataFolder"] {
            let sub = str(game[key]).trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
            if !sub.isEmpty, let real = find(sub, in: root) {
                source = root.appendingPathComponent(real, isDirectory: true)
                break
            }
        }

        // Cover: next to game.json (also inside the data folder).
        for base in [root, source] {
            if let items = try? fm.contentsOfDirectory(atPath: base.path),
               let hit = items.first(where: { coverNames.contains($0.lowercased()) }),
               let img = UIImage(contentsOfFile: base.appendingPathComponent(hit).path) {
                r.cover = img
                break
            }
        }

        // Move the game files into C:.
        let data = ImportedStore.dataDir(id)
        try? fm.removeItem(at: data)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        let skip: (String) -> Bool = { name in
            if name.hasPrefix(".") { return true }
            let l = name.lowercased()
            return source == root && (metaNames.contains(l) || coverNames.contains(l))
        }
        for name in try fm.contentsOfDirectory(atPath: source.path) where !skip(name) {
            let src = source.appendingPathComponent(name)
            let dst = data.appendingPathComponent(name)
            do { try fm.moveItem(at: src, to: dst) } catch { try fm.copyItem(at: src, to: dst) }
        }

        // Launch configuration.
        var c = ImportedConfig()
        c.core = core == "scummvm" ? "scummvm" : "dosbox"
        c.args = str(game["args"]).trimmingCharacters(in: .whitespaces)
        c.pre = lines(game["pre"])
        c.mounts = lines(game["mounts"])
        c.autoexec = lines(game["autoexec"]).joined(separator: "\n")
        c.sblaster = str(game["sblaster"]).trimmingCharacters(in: .whitespaces)
        c.mouse = str(game["mouse"]).lowercased()
        c.keys = (game["keys"] as? [Any])?.map { str($0) } ?? lines(game["keys"])
        if let d = game["dosbox"] as? [String: Any] { c.dosbox = d.mapValues { str($0) } }   // incl. "vram" (video MB) for Windows packs
        if let f = game["files"] as? [String: Any] {
            for (path, v) in f {
                if let t = v as? String { c.files[path] = t }
                else if let a = v as? [Any] { c.files[path] = a.map { str($0) }.joined(separator: "\n") }
            }
        }

        var dir = clean(str(game["dir"]))
        var exe = clean(str(game["exe"]))

        // dir: must exist inside C: (fix case); otherwise drop it.
        if !dir.isEmpty {
            if let real = find(dir, in: data) { dir = real } else { r.notes.append("Folder “\(dir)” not found; ignored."); dir = "" }
        }
        // exe: "SUB/GAME.EXE" is split into dir + file; a bare name is looked up in dir, then anywhere.
        if !exe.isEmpty {
            let comps = exe.split(separator: "/").map(String.init)
            var name = comps.last ?? exe
            var base = dir
            if comps.count > 1 { base = ((dir.isEmpty ? [] : [dir]) + comps.dropLast()).joined(separator: "/") }
            if let real = find((base.isEmpty ? "" : base + "/") + name, in: data) {
                let rc = real.split(separator: "/").map(String.init)
                name = rc.last ?? name
                dir = rc.dropLast().joined(separator: "/")
                exe = name
            } else if let real = findAnywhere(name, in: data) {
                let rc = real.split(separator: "/").map(String.init)
                dir = rc.dropLast().joined(separator: "/")
                exe = rc.last ?? name
                r.notes.append("Program found in \(dir.isEmpty ? "C:\\" : dir).")
            } else {
                r.notes.append("Program “\(exe)” not found in the pack.")
                exe = ""
            }
        }
        c.dir = dir.replacingOccurrences(of: "/", with: "\\")
        c.exe = exe

        // CD image (mounted as D:): fix case, search by name, prefer a .cue/.ins sheet next to a raw image.
        let cd = clean(str(game["cd"]))
        if !cd.isEmpty {
            var real = find(cd, in: data) ?? findAnywhere((cd as NSString).lastPathComponent, in: data)
            if let r0 = real {
                let ext = (r0 as NSString).pathExtension.lowercased()
                if ["gog", "bin", "mdf", "img"].contains(ext) {
                    let stem = (r0 as NSString).deletingPathExtension
                    for sheet in ["cue", "ins"] {
                        if let s = find(stem + "." + sheet, in: data) { real = s; break }
                    }
                }
            }
            if let real { c.cd = real } else { r.notes.append("CD image “\(cd)” not found.") }
        }
        // Game pack on a shared OS ("baseos": "win98" or "win31"): the pack carries the game drive (an .img/.vhd that becomes D:,
        // usually with the game preinstalled), optionally a CD image (`cd`, mounted as a CD-ROM) and config. The app's
        // own Windows disk is C:. Nothing else in the pack is ever run.
        let baseos = BaseOS.normalized(str(game["baseos"]))
        if !baseos.isEmpty, c.core != "dosbox" {
            r.notes.append("“baseos” needs the DOSBox core; ignored for \(c.core).")
        }
        if !baseos.isEmpty, c.core == "dosbox" {
            if let osProfile = BaseOS.profile(baseos) {
                c.baseos = osProfile.id
                let wanted = clean(str(game["drive"]))
                var drive: String?
                if !wanted.isEmpty { drive = find(wanted, in: data) ?? findAnywhere((wanted as NSString).lastPathComponent, in: data) }
                if drive == nil { drive = largestDiskRel(in: data, excluding: c.cd) }
                if let drive {
                    c.drive = drive
                    if !wanted.isEmpty, (drive as NSString).lastPathComponent.lowercased() != (wanted as NSString).lastPathComponent.lowercased() {
                        r.notes.append("Game drive “\(wanted)” not found; using \(drive).")
                    }
                } else {
                    r.notes.append("No game drive image (.img / .vhd) found in the pack; Windows will start without it.")
                }
                _ = BaseOS.provision(osProfile)     // a disk shipped with the app counts
                if !BaseOS.isReady(osProfile) {
                    r.notes.append("\(osProfile.title) isn't set up yet; this game can't start until it is (Settings → \(osProfile.title)).")
                }
                c.exe = ""; c.dir = ""; c.pre = []; c.mounts = []; c.autoexec = ""
            } else {
                r.notes.append("Unknown base OS “\(baseos)”. Supported: Windows 98 (\"baseos\": \"win98\"), Windows 95 (\"baseos\": \"win95\") and Windows 3.1 (\"baseos\": \"win31\").")
            }
        }
        // No usable program named: pick the most likely launcher so the game starts without any editing.
        if c.exe.isEmpty, c.autoexec.isEmpty, c.core == "dosbox", c.baseos.isEmpty {
            let scan = ImportedStore.scan(id)
            if let first = scan.exes.first {
                let comps = first.split(separator: "/").map(String.init)
                c.exe = comps.last ?? first
                c.dir = comps.dropLast().joined(separator: "\\")
            }
        }
        r.config = c
        return r
    }

    // MARK: Helpers

    private static func readJSON(_ url: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        // dk-entry style: an array with one object
        if let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]], let f = a.first { return f }
        return [:]
    }

    private static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    /// String or array of strings -> trimmed non-empty lines.
    private static func lines(_ v: Any?) -> [String] {
        var out: [String] = []
        if let s = v as? String { out = s.components(separatedBy: .newlines) }
        else if let a = v as? [Any] { out = a.map { str($0) } }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").filter { $0 != "." && $0 != ".." }.joined(separator: "/")
    }

    private static func actualName(_ name: String, in dir: URL) -> String? {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first { $0.lowercased() == name }
    }

    /// Root for a zip without game.json: the single top-level folder if that is all there is, else the zip root.
    private static func looseRoot(_ base: URL) -> URL? {
        let fm = FileManager.default
        let items = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        guard !items.isEmpty else { return nil }
        if items.count == 1 {
            let u = base.appendingPathComponent(items[0])
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return u }
        }
        return base
    }

    /// Largest .img / .vhd / .ima of any size under `base` (a game drive may be tiny), skipping `excluding`
    /// (the pack's CD image, a relative path). Relative path.
    private static func largestDiskRel(in base: URL, excluding: String = "") -> String? {
        guard let en = FileManager.default.enumerator(atPath: base.path) else { return nil }
        var best: (path: String, size: Int64)?
        while let rel = en.nextObject() as? String {
            let attrs = en.fileAttributes
            if (attrs?[.type] as? FileAttributeType) == .typeDirectory { continue }
            guard ["img", "vhd", "ima"].contains((rel as NSString).pathExtension.lowercased()) else { continue }
            // the CD image, or the raw .img/.bin that a .cue / .ins sheet points at
            if !excluding.isEmpty, (rel as NSString).deletingPathExtension.lowercased() == (excluding as NSString).deletingPathExtension.lowercased() { continue }
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if best == nil || size > best!.size { best = (rel, size) }
        }
        return best?.path
    }

    /// Shallowest folder (max depth 3) that holds a game.json.
    private static func findRoot(_ base: URL) -> URL? {
        let fm = FileManager.default
        var level = [base]
        for _ in 0...3 {
            var next: [URL] = []
            for d in level {
                guard let items = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
                if items.contains(where: { $0.lowercased() == "game.json" }) { return d }
                for n in items.sorted() where !n.hasPrefix(".") && n != "__MACOSX" {
                    let u = d.appendingPathComponent(n)
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { next.append(u) }
                }
            }
            level = next
        }
        return nil
    }

    /// Case-insensitive path lookup; returns the path with its real casing, or nil.
    private static func find(_ rel: String, in base: URL) -> String? {
        let fm = FileManager.default
        var cur = base
        var out: [String] = []
        for comp in rel.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init) where comp != "." {
            guard let items = try? fm.contentsOfDirectory(atPath: cur.path),
                  let hit = items.first(where: { $0 == comp }) ?? items.first(where: { $0.lowercased() == comp.lowercased() })
            else { return nil }
            out.append(hit)
            cur.appendPathComponent(hit)
        }
        return out.isEmpty ? nil : out.joined(separator: "/")
    }

    /// Shallowest file called `name` (any case) anywhere under `base`.
    private static func findAnywhere(_ name: String, in base: URL) -> String? {
        guard let en = FileManager.default.enumerator(atPath: base.path) else { return nil }
        var best: String?
        while let rel = en.nextObject() as? String {
            guard (rel as NSString).lastPathComponent.lowercased() == name.lowercased() else { continue }
            if (en.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory { continue }
            if best == nil || rel.split(separator: "/").count < best!.split(separator: "/").count { best = rel }
        }
        return best
    }
}
