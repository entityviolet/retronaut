import Foundation
import UIKit

/// Runs a DOS/ScummVM game through the bundled libretro core.
final class GameRunner {
    static let shared = GameRunner()

    private var host: CoreHost?
    private var sessionId: String?
    private var sessionStart: Date?

    /// Non-game sessions on the shared OS (they have no library entry, save states or play statistics).
    enum OSSession: String {
        case install = "setup"        // Windows 98: the core's installer running Setup from the CD image. Windows 3.1: DOS disk + setup disc
        case maintenance = "desktop"  // the OS desktop with the setup disc attached, for drivers and tweaks
    }
    private(set) var osSession: OSSession?
    /// Which shared OS the running `osSession` belongs to.
    private var osSessionProfile: BaseOS.Profile?

    /// Human-readable text for the failure codes `start` returns.
    static func message(for code: String) -> String {
        if code.hasPrefix("core-missing:") {
            return "The emulator core is missing from this build. If you built the app from a fresh clone, run `git lfs install && git lfs pull` — the cores are stored with Git LFS, and without them the files in Resources/Cores are placeholders."
        }
        if code.hasPrefix("os-missing:") {
            let p = BaseOS.profile(String(code.dropFirst("os-missing:".count))) ?? BaseOS.win98
            return "\(p.title) isn't set up yet. Open Settings → \(p.title)."
        }
        if code == "scummvm-no-files" { return "This ScummVM pack has no game files." }
        if code.hasPrefix("load-failed:scummvm") { return "ScummVM couldn't start this game" + String(code.dropFirst("load-failed:scummvm".count)) + ". Check that the pack holds the game's data files (they must sit together in one folder)." }
        if code.hasPrefix("os-unsupported:") { return "This pack needs an operating system the app doesn't support. Supported: Windows 98 (\"baseos\": \"win98\"), Windows 95 (\"baseos\": \"win95\") and Windows 3.1 (\"baseos\": \"win31\")." }
        return code
    }

    private func coreFile(_ name: String) -> String {
        name == "scummvm" ? "scummvm.dylib" : "dosbox_pure.dylib"
    }

    private func locateCore(_ name: String) -> String? {
        let file = coreFile(name)
        // SwiftPM can nest resources either directly in the resource bundle or one
        // level down in a copied `Resources` folder, depending on the layout, so
        // probe every plausible spot instead of assuming one.
        var candidates: [URL] = []
        if let resourceURL = Bundle.module.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Cores/\(file)"))
            candidates.append(resourceURL.appendingPathComponent("Resources/Cores/\(file)"))
            candidates.append(resourceURL.deletingLastPathComponent()
                .appendingPathComponent("Resources/Cores/\(file)"))
        }
        for relative in ["Cores/\(file)", "Resources/Cores/\(file)"] {
            if let path = Res.path(relative) { candidates.append(URL(fileURLWithPath: path)) }
        }
        // A clone without `git lfs pull` leaves ~130-byte pointer files behind.
        // Those must never be handed to dlopen as if they were cores.
        return candidates.first { candidate in
            guard let size = try? FileManager.default
                .attributesOfItem(atPath: candidate.path)[.size] as? Int, size > 1_000_000 else { return false }
            return true
        }?.path
    }

    /// game.json `files`: { "relative/path.ext": "text" | ["line", ...] }. Text files the game needs (config, ini, cfg)
    /// that the pack wants created on C: when missing. Never overwrites: the game may have changed them. CRLF line ends.
    static func writeFiles(_ spec: Any?, into dataDir: URL) {
        guard let files = spec as? [String: Any] else { return }
        let fm = FileManager.default
        for (rel, v) in files {
            let parts = rel.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." }
            guard !parts.isEmpty else { continue }
            let url = parts.reduce(dataDir) { $0.appendingPathComponent($1) }
            if fm.fileExists(atPath: url.path) { continue }
            let text: String
            if let s = v as? String { text = s } else if let a = v as? [Any] { text = a.map { "\($0)" }.joined(separator: "\n") } else { continue }
            let crlf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (crlf.hasSuffix("\r\n") ? crlf : crlf + "\r\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Writes the generated DOS startup script and returns its path (the core's content file).
    private func writeRunConf(gameDir: URL, _ lines: [String]) -> String {
        let fm = FileManager.default
        for stale in [gameDir.appendingPathComponent("run.conf"), gameDir.appendingPathComponent("dosbox.conf")] {
            try? fm.removeItem(at: stale)
        }
        let url = gameDir.appendingPathComponent("run.conf")
        try? ("[autoexec]\n" + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// The generated DOS script. It depends only on the game's `game.json` (no game is special-cased in code).
    /// Also used for the live preview in the import screen.
    static func standardScript(dataDir: URL, cfg: [String: Any]) -> [String] {
        let dp = dataDir.path
        func sub(_ s: String) -> String { s.replacingOccurrences(of: "{data}", with: dp) }
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if let custom = cfg["autoexec"] as? String, !blank(custom) {
            return sub(custom).components(separatedBy: .newlines)
        }

        var lines: [String] = []
        lines.append("mount c \"\(dp)\"")

        if let mounts = cfg["mounts"] as? [String] {
            lines.append(contentsOf: mounts.filter { !blank($0) }.map(sub))
        }

        if let cd = cfg["cd"] as? String, !cd.isEmpty,
           FileManager.default.fileExists(atPath: dataDir.appendingPathComponent(cd).path) {
            let ext = (cd as NSString).pathExtension.lowercased()
            let fsFlag = ["img", "ima", "vhd"].contains(ext) ? "" : " -fs iso"
            lines.append("imgmount d \"\(dataDir.appendingPathComponent(cd).path)\" -t iso\(fsFlag)")
        }

        lines.append("c:")

        if let dir = cfg["dir"] as? String, !blank(dir) {
            lines.append("cd \(dir.replacingOccurrences(of: "/", with: "\\"))")
        }
        if let pre = cfg["pre"] as? [String] {
            lines.append(contentsOf: pre.filter { !blank($0) }.map(sub))
        }
        if let exe = cfg["exe"] as? String, !blank(exe) {
            let args = (cfg["args"] as? String) ?? ""
            let e = exe.replacingOccurrences(of: "/", with: "\\")
            lines.append(blank(args) ? e : "\(e) \(args)")
        }
        return lines
    }

    /// The file handed to the ScummVM core as "the game": `exe` from game.json when it names a file, else a `.scummvm` hook
    /// file, else a file from the folder that holds the most files (the game's data folder, searched 3 levels deep).
    static func scummvmContent(dataDir: URL, cfg: [String: Any]) -> URL? {
        let fm = FileManager.default
        func isFile(_ u: URL) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: u.path, isDirectory: &d) && !d.boolValue
        }
        if let exe = (cfg["exe"] as? String)?.trimmingCharacters(in: .whitespaces), !exe.isEmpty,
           let u = resolve(exe, in: dataDir), isFile(u) { return u }

        var best: (dir: URL, files: [URL], depth: Int)?
        var hook: URL?
        var level: [URL] = [dataDir]
        for depth in 0...3 {
            var next: [URL] = []
            for dir in level {
                let items = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
                    .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                var files: [URL] = []
                for u in items {
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { next.append(u) }
                    else {
                        files.append(u)
                        if u.pathExtension.lowercased() == "scummvm", hook == nil { hook = u }
                    }
                }
                if !files.isEmpty, best == nil || files.count > best!.files.count { best = (dir, files, depth) }
            }
            level = next
        }
        if let hook { return hook }
        return best?.files.first
    }

    /// Largest .img / .vhd / .ima anywhere under `dir` (a game drive when the pack doesn't name one).
    /// `excluding` is a path relative to `dir` (the pack's CD image) that must not be mistaken for the drive.
    static func largestDisk(in dir: URL, excluding: String = "") -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return nil }
        let skip = (excluding as NSString).deletingPathExtension.lowercased()
        var best: (url: URL, size: Int)?
        for case let u as URL in en where ["img", "vhd", "ima"].contains(u.pathExtension.lowercased()) {
            if !excluding.isEmpty {
                // the CD image, or the raw .img/.bin that a .cue / .ins sheet points at
                let full = u.standardizedFileURL.path, base = dir.standardizedFileURL.path + "/"
                let rel = full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full
                if (rel as NSString).deletingPathExtension.lowercased() == skip { continue }
            }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if v?.isDirectory == true { continue }
            let size = v?.fileSize ?? 0
            if best == nil || size > best!.size { best = (u, size) }
        }
        return best?.url
    }

    /// Windows 98 startup script: the shared OS disk is the first hard disk (C:, boots), the pack's game drive the
    /// second (D:), the pack's CD image a CD-ROM (the next letter, D: when there is no game drive).
    ///
    /// Letters here are DOS-side only: `imgmount 2` / `3` are BIOS hard disks 0x80 / 0x81 (no DOS letter at all), the
    /// CD gets the DOS letter `cdLetter`. Windows 98 ignores all of that and assigns its own letters: the disk's
    /// partitions first (C:, then the game drive D:), the CD-ROM after them.
    static let cdLetter = "d"

    static func bootScript(os: URL, osGeometry: BaseOS.Geometry?, drive: URL?, cd: URL?, profile: BaseOS.Profile = BaseOS.win98) -> [String] {
        var lines = [diskLine(number: 2, image: os, geometry: osGeometry)]
        // The core puts a mounted disc on the first IDE slot that holds no hard disk (slots = disks 2, 3, 4, 5:
        // primary master / slave, secondary master / slave). The installed Windows 98 only knows the PRIMARY channel (its
        // CD-ROM is registered at SCSI target 1 = primary slave), so a disc on the secondary channel is invisible to it.
        // With a disc the game drive therefore goes to disk 4 and leaves slot 3 free for the disc, which is the layout
        // the core's own "run installed OS" uses. Without a disc the game drive stays disk 3.
        // Windows 3.1 runs on plain DOS (BIOS disks, no IDE driver): the BIOS only counts consecutive hard disks, so the
        // game drive must be disk 3 (D:) even with a disc, or DOS would not see it.
        if let drive {
            if let letter = profile.gameDriveLetter {
                // A profile can pin the game drive to a fixed DOS letter; DOS then never competes with the disc for it.
                lines.append("imgmount \(letter) \"\(drive.path)\" -t hdd -fs fat")
            } else {
                let driveSlot = cd != nil ? profile.gameDiskSlotWithDisc : 3
                lines.append(diskLine(number: driveSlot, image: drive, geometry: nil))
            }
        }
        // `-t iso` alone is the canonical form for a disc (ISO, CUE/BIN, CHS); the filesystem is implied.
        // The disc claims the profile's DOS letter before DOS scans the BIOS disks. Windows 3.1 packs expect the
        // disc on D: (that is where the era's installers recorded it) and the game drive therefore lands on E:.
        if let cd { lines.append("imgmount \(profile.discLetter) \"\(cd.path)\" -t iso") }
        lines.append("boot -l c")
        return lines
    }

    // MARK: Windows 98 media (game drive + disc)

    /// What a Windows 98 pack mounts, after every file has been checked. `notes` explain anything that was skipped.
    struct WinMedia {
        var drive: URL?
        var cd: URL?
        var notes: [String] = []
    }

    /// Case-insensitive path lookup under `base` (`\` and `/` both accepted). nil when it doesn't exist.
    static func resolve(_ rel: String, in base: URL) -> URL? {
        let fm = FileManager.default
        var cur = base
        let comps = rel.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." }
        guard !comps.isEmpty else { return nil }
        for c in comps {
            guard let items = try? fm.contentsOfDirectory(atPath: cur.path),
                  let hit = items.first(where: { $0 == c }) ?? items.first(where: { $0.lowercased() == c.lowercased() }) else { return nil }
            cur.appendPathComponent(hit)
        }
        return cur
    }

    /// First sector looks like a partitioned (or boot-sector) disk: 55 AA at 510.
    private static func isDiskImage(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let s = BaseOS.readAt(fh, 0, 512) else { return false }
        return s[510] == 0x55 && s[511] == 0xAA
    }

    /// The disk the core can mount for `url`: raw / fixed VHD as is, a dynamic VHD expanded once into a sparse raw copy
    /// next to it (imgmount can't mount dynamic VHDs and without a working mount Windows starts with no game drive).
    private static func mountableDisk(_ url: URL, notes: inout [String]) -> URL? {
        let fm = FileManager.default
        var disk = url
        if let t = BaseOS.vhdType(url), t != 2 {
            guard t == 3 else { notes.append("Game drive \(url.lastPathComponent) is a differencing VHD; not supported."); return nil }
            let raw = url.deletingPathExtension().appendingPathExtension("expanded.img")
            let srcDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let rawDate = (try? fm.attributesOfItem(atPath: raw.path))?[.modificationDate] as? Date
            if rawDate == nil || (srcDate ?? .distantPast) > rawDate! {
                let tmp = raw.appendingPathExtension("part")
                try? fm.removeItem(at: tmp)
                do {
                    guard try BaseOS.vhdToRaw(url, to: tmp) != nil else { return nil }
                    try? fm.removeItem(at: raw)
                    try fm.moveItem(at: tmp, to: raw)
                } catch {
                    try? fm.removeItem(at: tmp)
                    notes.append("Couldn't expand \(url.lastPathComponent): \(error.localizedDescription)")
                    return nil
                }
            }
            disk = raw
        }
        guard BaseOS.fileSize(disk) >= 1 << 20 else { notes.append("Game drive \(url.lastPathComponent) is too small to be a disk."); return nil }
        guard isDiskImage(disk) else {
            notes.append("Game drive \(url.lastPathComponent) isn't a disk image (no MBR / boot signature).")
            return nil
        }
        ensureWritable(disk, notes: &notes)
        normalizeVolume(disk, notes: &notes)
        return disk
    }

    /// ISO 9660 signature "CD001" in sector 16 (2048-byte, raw 2352 mode 1 or mode 2 sectors). Not a gate: a disc that
    /// fails this is still mounted, but the launch report says so.
    private static func looksLikeISO(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        for off in [16 * 2048 + 1, 16 * 2352 + 16 + 1, 16 * 2352 + 24 + 1] as [UInt64] {
            if let b = BaseOS.readAt(fh, off, 5), b == Array("CD001".utf8) { return true }
        }
        return false
    }

    /// The core opens a hard-disk image read/write and, when that fails, silently falls back to read-only, which shows
    /// up in Windows as a drive that can't be written to. Make sure the host file really is writable (clears an
    /// immutable flag / read-only mode, else replaces it with a writable clone) and say what was done.
    static func ensureWritable(_ url: URL, notes: inout [String]) {
        let fm = FileManager.default
        if fm.isWritableFile(atPath: url.path) { return }
        try? fm.setAttributes([.immutable: false, .posixPermissions: 0o644], ofItemAtPath: url.path)
        if fm.isWritableFile(atPath: url.path) { notes.append("\(url.lastPathComponent) was read-only; made writable."); return }
        let tmp = url.appendingPathExtension("rw")
        try? fm.removeItem(at: tmp)
        do {
            try fm.copyItem(at: url, to: tmp)            // APFS clone: no extra space
            try? fm.setAttributes([.immutable: false, .posixPermissions: 0o644], ofItemAtPath: tmp.path)
            try fm.removeItem(at: url)
            try fm.moveItem(at: tmp, to: url)
            notes.append("\(url.lastPathComponent) was read-only; replaced by a writable copy.")
        } catch {
            try? fm.removeItem(at: tmp)
            notes.append("WARNING: \(url.lastPathComponent) is read-only and couldn't be fixed (\(error.localizedDescription)); the drive will be write-protected in Windows.")
        }
    }

    /// Makes the game drive's FAT boot sector agree with its partition table and with the geometry it is mounted with.
    /// Images built with mtools / some Mac tools carry "hidden sectors = 0" although the partition starts at sector 63.
    /// DOS-style block drivers address the volume as hidden sectors + sector, so Windows 98 reads the wrong place
    /// ("unreadable / not writable D:", or no D: at all once an IDE CD-ROM is present and the stricter driver is used).
    /// Only these three BPB fields are rewritten (sectors/track, heads, hidden sectors), only when they differ.
    static func normalizeVolume(_ url: URL, notes: inout [String]) {
        guard url.pathExtension.lowercased() != "vhd", let fh = try? FileHandle(forUpdating: url) else { return }
        defer { try? fh.close() }
        guard var mbr = BaseOS.readAt(fh, 0, 512), mbr[510] == 0x55, mbr[511] == 0xAA else { return }
        var entry = -1
        for off in stride(from: 446, to: 510, by: 16) where mbr[off + 4] != 0 { entry = off; break }
        guard entry >= 0 else { return }
        let start = BaseOS.le(mbr, entry + 8, 4), partSectors = BaseOS.le(mbr, entry + 12, 4)
        guard start > 0, var bs = BaseOS.readAt(fh, start * 512, 512), BaseOS.le(bs, 11, 2) == 512 else { return }
        let fat32 = Array(bs[82..<87]) == Array("FAT32".utf8)
        let fat16 = Array(bs[54..<57]) == Array("FAT".utf8)
        guard fat32 || fat16 else { return }
        // Geometry: the boot sector's own values when they are sane, else 16/63. The MBR end-CHS is NOT used: images
        // made by mtools / Mac tools carry end head 0 there, which used to turn into "1 head" and a corrupt volume.
        var heads = 16, spt = 63
        let bh = Int(BaseOS.le(bs, 26, 2)), bsp = Int(BaseOS.le(bs, 24, 2))
        if bh > 0, bh <= 255, bsp > 0, bsp <= 63 { heads = bh; spt = bsp }
        var changed: [String] = []
        var changedBS = false
        func put(_ v: UInt64, _ o: Int, _ n: Int) { for i in 0..<n { bs[o + i] = UInt8((v >> UInt64(8 * i)) & 0xFF) }; changedBS = true }
        if BaseOS.le(bs, 28, 4) != start { changed.append("hidden sectors \(BaseOS.le(bs, 28, 4)) → \(start)"); put(start, 28, 4) }
        if bsp != spt || bh != heads { put(UInt64(spt), 24, 2); put(UInt64(heads), 26, 2) }
        // A hard-disk volume is media 0xF8 with BIOS drive 0x80. mtools writes 0xF0 (floppy) / drive 0; Windows 95's
        // protected-mode FAT driver then treats the volume as removable and fails writes with "serious disk error".
        let mediaOff = 21, driveOff = fat32 ? 64 : 36
        if bs[mediaOff] != 0xF8 { changed.append("media \(String(bs[mediaOff], radix: 16)) → f8"); bs[mediaOff] = 0xF8; changedBS = true }
        if bs[driveOff] != 0x80 { changed.append("drive number \(bs[driveOff]) → 80"); bs[driveOff] = 0x80; changedBS = true }
        var targets = [start]
        if fat32 { let backup = BaseOS.le(bs, 50, 2); if backup > 0 { targets.append(start + backup) } }
        if changedBS {
            for t in targets {
                try? fh.seek(toOffset: t * 512)
                try? fh.write(contentsOf: Data(bs))
            }
        }
        // FAT[0] low byte repeats the media descriptor in every FAT copy.
        let reserved = UInt64(BaseOS.le(bs, 14, 2)), nFats = Int(bs[16])
        let fatSectors = fat32 ? BaseOS.le(bs, 36, 4) : BaseOS.le(bs, 22, 2)
        if nFats > 0, fatSectors > 0 {
            for i in 0..<nFats {
                let pos = (start + reserved + UInt64(i) * fatSectors) * 512
                if let b = BaseOS.readAt(fh, pos, 1), b[0] != 0xF8 {
                    try? fh.seek(toOffset: pos)
                    try? fh.write(contentsOf: Data([0xF8]))
                    if !changed.contains("FAT[0]") { changed.append("FAT[0]") }
                }
            }
        }
        // The core mounts the disk as floor(size / (heads*spt)) cylinders. When the partition ends beyond that (the
        // image is not a whole number of cylinders), the last sectors lie outside the disk: harmless while the drive is
        // empty, "serious disk error" the moment an installer fills it. Grow the file (sparse) to whole cylinders.
        let cylSectors = UInt64(heads * spt)
        let needSectors = start + partSectors
        let wantSectors = (needSectors + cylSectors - 1) / cylSectors * cylSectors
        if let size = try? fh.seekToEnd(), size < wantSectors * 512 {
            try? fh.truncate(atOffset: wantSectors * 512)
            changed.append("size → \(wantSectors / cylSectors) cylinders")
        }
        // MBR end-CHS of the partition: derive from the geometry (clamped at cylinder 1023 like every BIOS does).
        let last = needSectors - 1
        let cyl = min(1023, Int(last / cylSectors))
        let rem = Int(last % cylSectors)
        let ch = rem / spt, cs = rem % spt + 1
        let wantEnd: [UInt8] = [UInt8(ch), UInt8((cs & 0x3F) | ((cyl >> 2) & 0xC0)), UInt8(cyl & 0xFF)]
        if Array(mbr[(entry + 5)...(entry + 7)]) != wantEnd {
            mbr.replaceSubrange((entry + 5)...(entry + 7), with: wantEnd)
            try? fh.seek(toOffset: 0)
            try? fh.write(contentsOf: Data(mbr))
            changed.append("MBR end CHS")
        }
        if !changed.isEmpty {
            notes.append("Fixed \(url.lastPathComponent) (\(changed.joined(separator: ", ")); geometry \(spt)/\(heads)).")
        }
    }

    /// Files a `.cue` sheet points at; relative names resolved next to the sheet (any case).
    private static func cueTracks(_ cue: URL) -> (found: [URL], missing: [String]) {
        guard let text = (try? String(contentsOf: cue, encoding: .utf8)) ?? (try? String(contentsOf: cue, encoding: .isoLatin1)) else { return ([], []) }
        var found: [URL] = [], missing: [String] = []
        let dir = cue.deletingLastPathComponent()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("FILE") else { continue }
            var name = ""
            if let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b {
                name = String(line[line.index(after: a)..<b])
            } else {
                let parts = line.split(separator: " ").map(String.init)
                if parts.count >= 2 { name = parts[1] }
            }
            guard !name.isEmpty else { continue }
            let leaf = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? name
            if let u = resolve(leaf, in: dir) { found.append(u) } else { missing.append(leaf) }
        }
        return (found, missing)
    }

    /// Checks the pack's game drive and disc before anything is mounted. A bad file is skipped (with a note) instead of
    /// handing the core an `imgmount` that fails, which leaves it at a DOS prompt that looks like a freeze.
    static func windowsMedia(dataDir: URL, cfg: [String: Any]) -> WinMedia {
        var m = WinMedia()
        func name(_ k: String) -> String { ((cfg[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        // Disc
        let cdName = name("cd")
        if !cdName.isEmpty {
            // Named disc missing (wrong name / folder in game.json): fall back to the only disc image in the pack.
            var found = resolve(cdName, in: dataDir)
            if found == nil {
                let leaf = (cdName as NSString).lastPathComponent
                var discs: [URL] = []
                if let en = FileManager.default.enumerator(at: dataDir, includingPropertiesForKeys: nil) {
                    for case let u as URL in en {
                        let e = u.pathExtension.lowercased()
                        if u.lastPathComponent.lowercased() == leaf.lowercased() { discs = [u]; break }
                        if ["iso", "cue", "ins", "chd", "mdf"].contains(e) { discs.append(u) }
                    }
                }
                if discs.count == 1 {
                    found = discs[0]
                    m.notes.append("Disc “\(cdName)” not found; using \(discs[0].lastPathComponent).")
                }
            }
            if var cd = found {
                // A raw image next to its .cue / .ins sheet: the sheet is the right thing to mount.
                let ext = cd.pathExtension.lowercased()
                if ["bin", "img", "mdf", "gog", "iso"].contains(ext) {
                    for sheet in ["cue", "ins"] {
                        let s = cd.deletingPathExtension().appendingPathExtension(sheet)
                        if FileManager.default.fileExists(atPath: s.path) { cd = s; break }
                    }
                }
                if cd.pathExtension.lowercased() == "cue" {
                    let t = cueTracks(cd)
                    if !t.missing.isEmpty {
                        m.notes.append("Disc sheet \(cd.lastPathComponent) names \(t.missing.joined(separator: ", ")), which isn't in the pack.")
                        // fall back to the data file with the same name, if there is one
                        let stem = cd.deletingPathExtension()
                        let alt = ["iso", "bin", "img"].map { stem.appendingPathExtension($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
                        if let alt { m.cd = alt; m.notes.append("Using \(alt.lastPathComponent) instead.") }
                    } else {
                        m.cd = cd
                    }
                } else if BaseOS.fileSize(cd) >= 2048 {
                    m.cd = cd
                    if !looksLikeISO(cd) { m.notes.append("Disc \(cd.lastPathComponent) has no ISO 9660 header; mounted anyway.") }
                } else {
                    m.notes.append("Disc image \(cd.lastPathComponent) is empty or truncated.")
                }
            } else {
                m.notes.append("Disc image “\(cdName)” not found in the pack.")
            }
        }

        // Game drive: the named image, else the largest disk image that isn't the disc.
        var candidate: URL?
        let driveName = name("drive")
        if !driveName.isEmpty { candidate = resolve(driveName, in: dataDir) }
        if candidate == nil {
            if !driveName.isEmpty { m.notes.append("Game drive “\(driveName)” not found in the pack.") }
            candidate = largestDisk(in: dataDir, excluding: cdName)
        }
        if let c = candidate {
            if let cd = m.cd, cd.standardizedFileURL.path == c.standardizedFileURL.path {
                m.notes.append("The game drive and the disc are the same file; no separate game drive.")
            } else {
                m.drive = mountableDisk(c, notes: &m.notes)
            }
        }
        return m
    }

    /// Core options for a Windows 98 session: the hardware profile, plus only the pack options that can't change what
    /// Windows registered (memory size, CPU speed). Machine / video / sound overrides are ignored, and `cycles: auto`
    /// is too: "auto" runs real-mode code (which is all of Windows' boot) at a few thousand cycles, so boot crawls.
    static func windowsOptions(from cfg: [String: Any], profile: BaseOS.Profile = BaseOS.win98) -> [String: String] {
        var o = BaseOS.coreOptions(profile)
        let p = coreOptions(from: cfg)
        if let c = p["dosbox_pure_cycles"]?.lowercased() {
            if c == "max" { o["dosbox_pure_cycles"] = "max" }
            else if let n = Int(c), n >= 20_000 { o["dosbox_pure_cycles"] = String(n) }
        }
        // Video memory is read from the card by Windows' driver at every boot, so it may differ from setup; only sane sizes.
        if let v = p["dosbox_pure_svgamem"], ["1", "2", "3", "4", "8"].contains(v) { o["dosbox_pure_svgamem"] = v }
        if let m = p["dosbox_pure_memory_size"], let n = Int(m), profile.memorySizes.contains(n) {
            o["dosbox_pure_memory_size"] = String(n)
        }
        return o
    }

    /// game.json as a dictionary (imported, bundled in the app, or from the dev resources folder).
    static func loadConfig(gameId: String) -> [String: Any] {
        if ImportedStore.isImported(gameId) { return ImportedStore.rawConfig(gameId) ?? [:] }
        var urls: [URL] = []
        if let u = Bundle.module.resourceURL?.appendingPathComponent("Games/\(gameId)/game.json") { urls.append(u) }
        if let u = Res.url("Games/\(gameId)/game.json") { urls.append(u) }
        for u in urls where FileManager.default.fileExists(atPath: u.path) {
            if let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        }
        return [:]
    }

    static func isWindowsPack(_ gameId: String) -> Bool {
        !BaseOS.normalized(((loadConfig(gameId: gameId)["baseos"] as? String) ?? "")).isEmpty
    }

    /// The last Windows 98 launch: script, mounted media and anything that was skipped (shown in Settings).
    private(set) static var lastLaunchLog = ""

    private static func diskLine(number: Int, image: URL, geometry: BaseOS.Geometry?) -> String {
        "imgmount \(number) \"\(image.path)\" -t hdd -fs none\(geometry?.args ?? geometryArgs(image))"
    }

    /// ` -size bps,spt,heads,cyl` for a raw (or fixed-VHD) disk, read from its MBR; "" when it can't be worked out.
    /// Geometry is read from the MBR's first partition entry (end head / sector / total size).
    private static func geometryArgs(_ image: URL) -> String {
        var geometry = ""
        if let fileSize = (try? FileManager.default.attributesOfItem(atPath: image.path))?[.size] as? NSNumber,
           let fh = try? FileHandle(forReadingFrom: image) {
            defer { try? fh.close() }
            var size = fileSize
            var raw = true
            if image.pathExtension.lowercased() == "vhd" {
                // Fixed VHD = raw disk + 512-byte "conectix" footer. The core's imgmount wants the geometry spelled
                // out for it (without -size it fails), so treat the data part as a raw disk. Dynamic VHDs can't be.
                raw = false
                if fileSize.intValue > 1024,
                   (try? fh.seek(toOffset: UInt64(fileSize.intValue - 512))) != nil,
                   let tail = try? fh.read(upToCount: 8), String(data: tail, encoding: .ascii) == "conectix",
                   (try? fh.seek(toOffset: 0)) != nil,
                   let head = try? fh.read(upToCount: 8), String(data: head, encoding: .ascii) != "conectix" {
                    size = NSNumber(value: fileSize.intValue - 512)
                    raw = true
                }
                try? fh.seek(toOffset: 0)
            }
            var heads = 16, spt = 63
            if raw, let mbr = try? fh.read(upToCount: 512), mbr.count == 512 {
                let b = [UInt8](mbr)
                // The partition's own boot sector is the only trustworthy source: the MBR end-CHS is off by one
                // disk head whenever the partition does not start on a cylinder boundary (start LBA 63), which made
                // this read "1 head" and Windows refused to mount the volume.
                var startLBA = 0
                for off in stride(from: 446, to: 510, by: 16) where b[off + 4] != 0 {
                    startLBA = Int(b[off + 8]) | Int(b[off + 9]) << 8 | Int(b[off + 10]) << 16 | Int(b[off + 11]) << 24
                    break
                }
                if startLBA > 0, (try? fh.seek(toOffset: UInt64(startLBA) * 512)) != nil,
                   let bs = try? fh.read(upToCount: 512), bs.count == 512 {
                    let s = [UInt8](bs)
                    let bps = Int(s[11]) | Int(s[12]) << 8
                    let h = Int(s[26]) | Int(s[27]) << 8
                    let sp = Int(s[24]) | Int(s[25]) << 8
                    if bps == 512, h > 0, h <= 255, sp > 0, sp <= 63 { heads = h; spt = sp }
                }
                if heads == 16 && spt == 63 {
                    // Fall back to the end-CHS only when the boot sector is unreadable.
                    for off in stride(from: 446, to: 510, by: 16) where b[off + 4] != 0 {
                        let h = Int(b[off + 5]) + 1, s = Int(b[off + 6] & 0x3F)
                        if h > 0, h <= 255, s > 0 { heads = h; spt = s }
                        break
                    }
                }
            }
            if raw {
                let cyl = max(1, size.intValue / 512 / (heads * spt))
                geometry = " -size 512,\(spt),\(heads),\(cyl)"
            }
        }
        return geometry
    }

    static func stringList(_ v: Any?) -> [String] {
        if let a = v as? [Any] { return a.map { "\($0)" } }
        if let s = v as? String { return s.split(whereSeparator: { ", ".contains($0) }).map(String.init) }
        return []
    }

    /// game.json "dosbox": { machine, memsize, sound, cycles } -> DOSBox Pure core options.
    static func coreOptions(from cfg: [String: Any]) -> [String: String] {
        guard let d = cfg["dosbox"] as? [String: Any] else { return [:] }
        func s(_ k: String) -> String? {
            guard let v = d[k] else { return nil }
            let t = "\(v)".trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        var o: [String: String] = [:]
        if let v = s("machine") {
            // DOSBox Pure's graphics option is `machine` = svga | vga | ega | cga | hercules | tandy | pcjr, and the SVGA
            // flavour is a second option. Accept the older / friendlier spellings pack authors tend to use.
            switch v.lowercased() {
            case "vgaonly", "vga", "generic_vga": o["dosbox_pure_machine"] = "vga"
            case "svga", "svga_s3", "s3", "generic_svga": o["dosbox_pure_machine"] = "svga"
            case "vesa_nolfb", "vesa_oldvbe": o["dosbox_pure_machine"] = "svga"; o["dosbox_pure_svga"] = v.lowercased()
            default: o["dosbox_pure_machine"] = v
            }
        }
        if let v = s("vram") ?? s("svgamem") { o["dosbox_pure_svgamem"] = v }   // video memory in MB: 1 2 3 4 8 (core default 2)
        if let v = s("memsize") { o["dosbox_pure_memory_size"] = v }
        if let v = s("sound") { o["dosbox_pure_sblaster_type"] = v }
        if let v = s("cycles") { o["dosbox_pure_cycles"] = v }
        return o
    }

    /// `resume`: restore the auto-save once the game has booted.
    func start(gameId: String, resume: Bool = false) -> String? {
        stop()

        let fm = FileManager.default
        guard let gameDir = GameLibrary.shared.materialize(gameId: gameId) else {
            return "library-missing:\(gameId)"
        }

        let cfg = Self.loadConfig(gameId: gameId)

        let dataDir = gameDir.appendingPathComponent("data")

        guard fm.fileExists(atPath: dataDir.path) else {
            return "data-missing:\(dataDir.path)"
        }

        let core = (cfg["core"] as? String) ?? "dosbox"
        let baseOSName = BaseOS.normalized((cfg["baseos"] as? String) ?? "")
        let osProfile = BaseOS.profile(baseOSName) ?? BaseOS.win98
        guard let corePath = locateCore(core) else {
            return "core-missing:\(coreFile(core)) [root=\(Res.root.lastPathComponent)]"
        }

        var contentPath = ""
        var launchReport: String?
        if core == "scummvm" {
            // ScummVM's libretro core wants a FILE inside the game folder (it autodetects from the file's parent directory:
            // `-p "<parent>" --auto-detect`), or a `.scummvm` hook file holding a target id. Passing the folder itself makes
            // the parent the pack folder, so detection fails ("Game not found").
            guard let file = Self.scummvmContent(dataDir: dataDir, cfg: cfg) else { return "scummvm-no-files" }
            contentPath = file.path
        } else if !baseOSName.isEmpty {
            // Game pack on the shared OS: C: = the app's Windows 98 disk, D: = the pack's game drive,
            // CD-ROM = the pack's CD image. Windows starts and its autorun hook runs D:\AUTORUN.BAT.
            guard BaseOS.profile(baseOSName) != nil else { return "os-unsupported:\(baseOSName)" }
            guard BaseOS.isReady(osProfile) || (BaseOS.provision(osProfile) && BaseOS.isReady(osProfile)) else { return "os-missing:\(osProfile.id)" }
            // Autorun hook + fast boot (Windows 98: StartUp folder + MSDOS.SYS; Windows 3.1: AUTOEXEC.BAT block + GAMEAUTO.BAT).
            var media = Self.windowsMedia(dataDir: dataDir, cfg: cfg)
            Self.ensureWritable(BaseOS.imageURL(osProfile), notes: &media.notes)   // before anything writes to it
            let hookStatus = BaseOS.applyHooks(osProfile)
            BaseOS.markClean(BaseOS.imageURL(osProfile))   // never let the OS run ScanDisk after an unclean exit
            // Same as the OS disk: a game drive left "dirty" by an unclean exit makes Windows run ScanDisk on it at boot.
            if let d = media.drive { BaseOS.markClean(d) }
            if hookStatus.contains("FAILED") { media.notes.append("\(osProfile.title) autorun: \(hookStatus)") }
            let script = Self.bootScript(os: BaseOS.imageURL(osProfile), osGeometry: BaseOS.geometry(osProfile), drive: media.drive, cd: media.cd, profile: osProfile)
            contentPath = writeRunConf(gameDir: gameDir, script)
            Self.lastLaunchLog = (["\(osProfile.title) launch: \(gameId)",
                                   "drive: \(media.drive?.lastPathComponent ?? "none")",
                                   "disc: \(media.cd?.lastPathComponent ?? "none")"] + media.notes.map { "note: \($0)" } + script).joined(separator: "\n")
            NSLog("%@", Self.lastLaunchLog)
            LaunchLog.write(Self.lastLaunchLog)
            launchReport = (["Game drive: \(media.drive?.lastPathComponent ?? "NOT mounted")",
                             "CD: \(media.cd?.lastPathComponent ?? "NOT mounted")"] + media.notes).joined(separator: "\n")
        } else {
            Self.writeFiles(cfg["files"], into: dataDir)
            let body = Self.standardScript(dataDir: dataDir, cfg: cfg).joined(separator: "\n")
            let confURL = gameDir.appendingPathComponent("run.conf")
            try? ("[autoexec]\n" + body).write(to: confURL, atomically: true, encoding: .utf8)
            contentPath = confURL.path
            LaunchLog.write("DOS launch: \(gameId)\n\(body)")
        }

        let h = CoreHost()
        h.gameId = gameId
        h.provideLogInterface = (core == "scummvm")
        h.isScummVM = (core == "scummvm")
        CoreHost.lastCoreLog = ""
        if let sb = cfg["sblaster"] as? String, !sb.trimmingCharacters(in: .whitespaces).isEmpty { h.sblasterConf = sb }
        h.gameKeys = Set(Self.stringList(cfg["keys"]).compactMap { RetroKeys.named($0)?.1 })
        if let m = (cfg["mouse"] as? String)?.lowercased() {
            // "absolute"/"direct": finger points at the screen; "relative"/"pad"/"touchpad": finger drags the cursor
            if ["absolute", "direct", "touch"].contains(m) { h.touchModeOverride = "direct"; h.mouseMode = "direct" }
            else if ["relative", "pad", "touchpad"].contains(m) { h.touchModeOverride = "pad"; h.mouseMode = "pad" }
        }
        h.coreOptions = Self.coreOptions(from: cfg)
        if core == "scummvm" {
            // The core defaults to OpenGL rendering when its option isn't answered (its frames are then the "hardware
            // frame" marker -1, which this host cannot display). Software rendering = anything but "enabled".
            h.coreOptions["scummvm_video_hw_acceleration"] = "disabled"
        }
        if !baseOSName.isEmpty {
            // The emulated PC Windows 98 was installed on; only memory size / cycles of the pack's `dosbox` block apply.
            h.coreOptions = Self.windowsOptions(from: cfg, profile: osProfile)
        }
        h.gameTitle = Library.shared.games.first { $0.id == gameId }?.title ?? ""
        if resume, StateStore.hasAuto(gameId) { h.pendingLoadSlot = 0 }
        guard h.open(corePath: corePath, contentPath: contentPath) else {
            let why = CoreHost.lastCoreLog.isEmpty ? "" : " (\(CoreHost.lastCoreLog))"
            return "load-failed:\(core)\(why)"
        }
        host = h
        sessionId = gameId
        sessionStart = Date()
        LibraryStore.shared.began(gameId)
        let report = launchReport
        DispatchQueue.main.async {
            h.present()
            h.begin()
            // Windows packs: show what was really mounted, so a missing disc / drive is visible without a console.
            if let report, let vc = h.gameVC { h.toast(report, in: vc, seconds: 6) }
        }
        return nil
    }

    // MARK: OS sessions (Windows 98 / Windows 3.1)

    /// First-run setup. Windows 98: the core's own installer (Start menu → "Boot and Install New Operating System") on the
    /// Windows 98 CD image, with the same emulated PC every game will use later. Windows 3.1: the DOS disk boots with the
    /// setup disc attached and Setup installs straight into that disk.
    func startInstall(profile: BaseOS.Profile = BaseOS.win98) -> String? {
        guard let iso = BaseOS.installMedia(profile) else { return "\(profile.title) install image not found." }
        // Remember when setup began (only the first time: "continue setup" must still find the disk written earlier).
        if UserDefaults.standard.object(forKey: profile.startKey) == nil { UserDefaults.standard.set(Date(), forKey: profile.startKey) }
        try? FileManager.default.createDirectory(at: BaseOS.installDir(profile), withIntermediateDirectories: true)

        // Windows 98 has a bootable CD and the core's own OS installer. Windows 3.1 does not: its disc only holds
        // SETUP.EXE, so C: must already boot DOS. The bundled win31.img is a ready FreeDOS disk (verified bootable),
        // so setup is just: boot that disk with the setup disc in R: and run SETUP.
        if !profile.usesInstallerDisk {
            let img = BaseOS.imageURL(profile)
            guard BaseOS.isInstalled(profile) || BaseOS.provision(profile), let geo = BaseOS.geometry(profile) else {
                return "\(profile.title) needs a bootable DOS disk to install onto and none is available (Settings → \(profile.title) → Import \(profile.title) image)."
            }
            var notes: [String] = []
            Self.ensureWritable(img, notes: &notes)
            let script = [Self.diskLine(number: 2, image: img, geometry: geo),
                          "imgmount r \"\(iso.path)\" -t iso",
                          "boot -l c"]
            let conf = BaseOS.root(profile).appendingPathComponent("install.conf")
            try? ("[autoexec]\n" + script.joined(separator: "\n")).write(to: conf, atomically: true, encoding: .utf8)
            return startOS(.install, profile: profile, title: "\(profile.title) Setup", contentPath: conf.path)
        }
        return startOS(.install, profile: profile, title: "\(profile.title) Setup", contentPath: iso.path)
    }

    /// The OS desktop with its setup disc attached (for drivers and tweaks).
    func startMaintenance(profile: BaseOS.Profile = BaseOS.win98) -> String? {
        guard BaseOS.isReady(profile) else { return "os-missing:\(profile.id)" }
        var notes: [String] = []
        Self.ensureWritable(BaseOS.imageURL(profile), notes: &notes)
        // Windows 95's hook is a WIN.INI run= line that expects a pack's AUTORUN.BAT on D:; opening the bare OS from
        // Settings has no such pack, so the hook is only applied when a pack launches.
        if profile.id == BaseOS.win95.id { _ = BaseOS.clearWin95RunLine(profile) } else { BaseOS.applyHooks(profile) }
        BaseOS.markClean(BaseOS.imageURL(profile))
        let conf = BaseOS.root(profile).appendingPathComponent("maintenance.conf")
        // Windows 95 mounts only the OS disk: the pack supplies its own media, the app's tools disc stays out.
        let cd = profile.id == BaseOS.win95.id ? nil : BaseOS.installMedia(profile)
        let script = Self.bootScript(os: BaseOS.imageURL(profile), osGeometry: BaseOS.geometry(profile), drive: nil, cd: cd, profile: profile)
        try? ("[autoexec]\n" + script.joined(separator: "\n")).write(to: conf, atomically: true, encoding: .utf8)
        return startOS(.maintenance, profile: profile, title: profile.title, contentPath: conf.path)
    }

    private func startOS(_ kind: OSSession, profile: BaseOS.Profile, title: String, contentPath: String) -> String? {
        stop()
        guard let corePath = locateCore("dosbox") else { return "core-missing:\(coreFile("dosbox"))" }
        let h = CoreHost()
        h.gameId = "\(profile.id).\(kind.rawValue)"
        h.gameTitle = title
        h.coreOptions = BaseOS.coreOptions(profile)
        h.statesEnabled = false
        guard h.open(corePath: corePath, contentPath: contentPath) else {
            LaunchLog.write("OS launch FAILED: \(title) core=\(corePath) content=\(contentPath)")
            return "load-failed:dosbox"
        }
        LaunchLog.write("OS launch: \(title)\ncontent: \(contentPath)")
        host = h
        osSession = kind
        osSessionProfile = profile
        sessionId = nil
        sessionStart = nil
        DispatchQueue.main.async {
            h.present()
            h.begin()
        }
        return nil
    }

    func stop(autosave: Bool = false) {
        let ended = osSession
        let endedProfile = osSessionProfile
        if autosave, ended == nil { host?.autoSave() }
        host?.stop()
        host = nil
        if let id = sessionId, let t = sessionStart {
            LibraryStore.shared.ended(id, seconds: Date().timeIntervalSince(t))
        }
        sessionId = nil
        sessionStart = nil
        osSession = nil
        osSessionProfile = nil
        if let ended { Win98Setup.controller(for: endedProfile ?? BaseOS.win98).sessionEnded(ended) }
    }
}
