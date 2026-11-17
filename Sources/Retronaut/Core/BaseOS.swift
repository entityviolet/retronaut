import Foundation

/// The app's shared operating systems: Windows 98 SE and Windows 3.1 (3.11). Game packs that declare `"baseos": "win98"`
/// or `"baseos": "win31"` boot the matching disk as C: and mount their own game drive next to it.
///
///   Documents/os/<os>/<os>.img        the working disk: a raw (sparse) hard-disk image with the OS and anything installed in it
///   Documents/os/<os>/<os>.geometry   "sectors,heads,cylinders" the disk must be mounted with
///   Documents/os/<os>/install/        the OS setup image used for setup (win98se.iso / win31.iso)
///
/// Windows 98: the core's own installer runs Windows 98 Setup from the CD image and writes a dynamic VHD; `adopt` then
/// turns that into the raw working disk. Windows 3.1: the app ships (or the user imports) a bootable DOS disk; Setup runs
/// from the setup image straight INTO that working disk, so there is nothing to adopt afterwards.
/// Removing a game never touches a disk. Settings can export (compacted + zipped) or reset each OS.
enum BaseOS {
    struct OSError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Geometry {
        var spt: Int, heads: Int, cyl: Int
        var args: String { " -size 512,\(spt),\(heads),\(cyl)" }
        var text: String { "\(spt),\(heads),\(cyl)" }
    }

    // MARK: Profiles

    /// One shared OS disk the packs can boot. Both operating systems use the same life cycle: a working raw disk in
    /// Documents, a geometry file next to it, import/export as a zip, reset, and a fixed hardware profile.
    struct Profile {
        let id: String
        let title: String
        let folderName: String
        let imageName: String
        let geometryName: String
        let startKey: String
        let isoName: String
        /// Lower-case fragments that mark a loose .iso in Documents as this OS's setup image.
        let mediaHints: [String]
        let coreOptions: [String: String]
        /// Lower-case spellings a pack may use in `baseos` (spaces are ignored).
        let names: Set<String>
        /// True when setup writes a separate VHD that must be adopted (Windows 98). False when Setup installs straight
        /// into the working disk (Windows 3.1).
        let usesInstallerDisk: Bool
        /// RAM sizes (MB) a pack's `dosbox.memsize` may pick.
        let memorySizes: [Int]
        /// DOS letter the mounted disc claims (the core takes it before DOS scans the BIOS disks).
        let discLetter: String
        /// BIOS disk slot the pack's game drive goes to when a disc is present (2 = first disk = C:).
        let gameDiskSlotWithDisc: Int
        /// When set, the game drive is mounted straight on this DOS letter instead of a BIOS slot. Needed when a disc
        /// must keep a fixed letter that DOS would otherwise hand to the second hard disk (Windows 3.1: CD on D:).
        let gameDriveLetter: String?
        /// Optional second hard disk shipped with the app (drivers / installers for maintenance boots). Mounted as a
        /// plain FAT disk, not a CD: these images have no CD driver, so a disc would not get a letter.
        let toolsImageName: String? = nil
    }

    /// The emulated PC. Windows 98 registers this hardware while it installs, so setup, maintenance and every game
    /// must use exactly these options or Windows asks for "new hardware" again. A pack's `dosbox` block is applied on
    /// top (use it for `cycles` / `memsize` only; changing the video or 3D card changes the hardware).
    ///   S3 Trio64 SVGA, 3dfx Voodoo (12 MB, dual texture), Sound Blaster 16, Pentium (586) CPU, 128 MB RAM.
    static let win98 = Profile(
        id: "win98", title: "Windows 98",
        folderName: "os/win98", imageName: "win98.img", geometryName: "win98.geometry",
        startKey: "win98.installStarted",
        isoName: "win98se.iso",
        mediaHints: ["98"],
        coreOptions: [
            // Only keys/values that exist in the core. ("svga_s3" was never valid: the core answers "svga" = S3 Trio64.)
            "dosbox_pure_machine": "svga",
            "dosbox_pure_svga": "svga_s3",    // S3 Trio64 (core default), keeps the hardware Windows 98 already registered
            "dosbox_pure_svgamem": "4",       // 4 MB = the real Trio64's maximum: 1024x768x32 and 800x600x32 fit; Windows' driver re-reads it every boot
            "dosbox_pure_memory_size": "128",
            "dosbox_pure_cpu_type": "pentium_slow",   // the core's own pick for Windows 9x / 3.x (memory privilege checks)
            "dosbox_pure_cpu_core": "normal",         // "dynamic" needs RWX pages = JIT, which iOS refuses
            "dosbox_pure_cycles": "max",
            "dosbox_pure_sblaster_type": "sb16",
            "dosbox_pure_sblaster_conf": "A220 I5 D1 H5",
            "dosbox_pure_voodoo": "12mb",
            "dosbox_pure_voodoo_perf": "auto",  // OpenGL when the frontend has it, else the multithreaded software rasteriser
        ],
        names: ["win98", "windows98", "win98se", "windows98se", "w98"],
        usesInstallerDisk: true,
        memorySizes: [16, 24, 32, 48, 64, 96, 128, 224, 256, 512],
        discLetter: "d",
        gameDiskSlotWithDisc: 4,
        gameDriveLetter: nil)

    /// Windows 3.1 / 3.11 is a DOS program, not a protected-mode OS: no PnP, no Voodoo, a small machine.
    static let win31 = Profile(
        id: "win31", title: "Windows 3.1",
        folderName: "os/win31", imageName: "win31.img", geometryName: "win31.geometry",
        startKey: "win31.installStarted",
        isoName: "win31.iso",
        mediaHints: ["win31", "win3.1", "win311", "win3.11", "w31", "wfw", "windows3", "windows 3"],
        coreOptions: [
            "dosbox_pure_machine": "svga",
            "dosbox_pure_svga": "svga_s3",
            "dosbox_pure_sblaster_type": "sb16",
            "dosbox_pure_sblaster_conf": "A220 I5 D1 H5",
            "dosbox_pure_voodoo": "off",           // Windows 3.x has no 3dfx support; one less device to emulate
            "dosbox_pure_memory_size": "32",       // plenty for Windows 3.x enhanced mode; more only slows HIMEM/SMARTDRV
            "dosbox_pure_cpu_type": "pentium_slow",
            "dosbox_pure_cpu_core": "normal",
            "dosbox_pure_cycles": "max",
        ],
        names: ["win31", "windows31", "win3.1", "windows3.1", "w31", "wfw31", "wfw311", "wfw3.11", "wfw",
                "win311", "windows311", "win3.11", "windows3.11", "win3x", "windows3x", "windowsforworkgroups",
                "windowsforworkgroups3.11"],
        usesInstallerDisk: false,
        memorySizes: [8, 16, 24, 32, 48, 64],
        discLetter: "e",
        gameDiskSlotWithDisc: 3,
        gameDriveLetter: nil)

    /// Windows 95: same idea as Windows 98 (a bootable disk image shipped with the app), lighter machine.
    /// Preinstalled image, so no installer disc; a game pack declares `"baseos": "win95"`.
    static let win95 = Profile(
        id: "win95", title: "Windows 95",
        folderName: "os/win95", imageName: "win95.img", geometryName: "win95.geometry",
        startKey: "win95.installStarted",
        isoName: "win95.iso",
        mediaHints: ["win95", "windows95", "w95", "win95osr", "windows 95"],
        coreOptions: [
            "dosbox_pure_machine": "svga",
            "dosbox_pure_svga": "svga_s3",
            "dosbox_pure_svgamem": "4",       // see Windows 98
            "dosbox_pure_sblaster_type": "sb16",
            "dosbox_pure_sblaster_conf": "A220 I5 D1 H5",
            // Windows 95 retail misbehaves above ~64 MB (VCACHE / "insufficient memory" at boot), so 64 MB is the ceiling.
            "dosbox_pure_memory_size": "64",
            // The core's own advice for "Windows 95 / Windows 3.x games" is Pentium (slow). Valid cpu_type values are
            // auto/386/386_slow/386_prefetch/486/486_slow/486_prefetch/pentium/pentium_slow, and "dynamic" needs JIT
            // pages that iOS refuses, so interpreter + pentium_slow is the combination that always runs.
            "dosbox_pure_cpu_type": "pentium_slow",
            "dosbox_pure_cpu_core": "normal",
            // "max" adapts to what the device can deliver; a fixed 200000 cps overshoots the interpreter and stutters audio.
            "dosbox_pure_cycles": "max",
            // Voodoo card for Glide/Direct3D packs. 8 MB, perf auto = OpenGL when the frontend has it, else the
            // multithreaded software rasteriser.
            "dosbox_pure_voodoo": "8mb",
            "dosbox_pure_voodoo_perf": "auto",
        ],
        names: ["win95", "windows95", "w95", "win95osr2", "windows95osr2", "win9x"],
        usesInstallerDisk: false,
        memorySizes: [16, 24, 32, 48, 64],
        // Exactly how Windows 98 packs mount their media: the disc claims D: and the game drive sits on BIOS disk 4,
        // so it lands on E: without fighting the CD for a letter.
        discLetter: "d",
        // Same layout as Windows 98: disc on the primary slave (slot 3), game drive on the secondary master (slot 4).
        // The "serious disk error" on D: during installs came from the game drive's boot sector / geometry (see
        // GameRunner.normalizeVolume), not from the channel.
        gameDiskSlotWithDisc: 4,
        gameDriveLetter: nil)

    static let all: [Profile] = [win98, win31, win95]

    /// Every `baseos` value the app understands (the profile ids).
    static var known: Set<String> { Set(all.map { $0.id }) }

    /// The profile a pack's `baseos` value refers to, if any.
    static func profile(_ name: String) -> Profile? {
        let l = name.lowercased().filter { !$0.isWhitespace }
        guard !l.isEmpty else { return nil }
        return all.first { $0.id == l || $0.names.contains(l) }
    }

    /// Canonical `baseos` id ("win98" / "win31") for any accepted spelling; other text is returned lower-cased, trimmed.
    static func normalized(_ s: String) -> String {
        let l = s.lowercased().filter { !$0.isWhitespace }
        return profile(l)?.id ?? l
    }

    static func displayName(_ name: String) -> String { profile(name)?.title ?? name }

    /// Hardware profile for a pack that boots the given OS.
    static func coreOptions(_ p: Profile) -> [String: String] { p.coreOptions }

    // MARK: Paths

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func root(_ p: Profile) -> URL { documents.appendingPathComponent(p.folderName, isDirectory: true) }
    static func imageURL(_ p: Profile) -> URL { root(p).appendingPathComponent(p.imageName) }
    static func geometryURL(_ p: Profile) -> URL { root(p).appendingPathComponent(p.geometryName) }
    static func installDir(_ p: Profile) -> URL { root(p).appendingPathComponent("install", isDirectory: true) }
    static func isInstalled(_ p: Profile) -> Bool { FileManager.default.fileExists(atPath: imageURL(p).path) }

    private static func geometry(from text: String) -> Geometry? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").compactMap { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 > 0 }) else { return nil }
        return Geometry(spt: parts[0], heads: parts[1], cyl: parts[2])
    }

    /// Mount geometry of the given OS disk.
    static func geometry(_ p: Profile) -> Geometry? {
        if let s = try? String(contentsOf: geometryURL(p), encoding: .utf8), let g = geometry(from: s) { return g }
        let img = imageURL(p)
        return FileManager.default.fileExists(atPath: img.path) ? (bpbGeometry(img) ?? mbrGeometry(img)) : nil
    }

    // MARK: Setup media

    /// The setup image of the given OS: copied into the app (install dir), dropped into Documents, or bundled.
    /// The extra FAT disk with drivers / installers for this OS, when the profile ships one.
    static func toolsMedia(_ p: Profile) -> URL? {
        guard let name = p.toolsImageName else { return nil }
        let fm = FileManager.default
        let own = installDir(p).appendingPathComponent(name)
        if fm.fileExists(atPath: own.path) { return own }
        if let u = Bundle.module.resourceURL?.appendingPathComponent("OS/\(name)"), fm.fileExists(atPath: u.path) { return u }
        return Res.url("OS/\(name)")
    }

    static func installMedia(_ p: Profile) -> URL? {
        let fm = FileManager.default
        func isos(in dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "iso" }
        }
        let own = installDir(p).appendingPathComponent(p.isoName)
        if fm.fileExists(atPath: own.path) { return own }
        if let hit = isos(in: installDir(p)).first { return hit }
        if let hit = isos(in: documents).first(where: { u in
            let n = u.lastPathComponent.lowercased()
            return p.mediaHints.contains { n.contains($0) }
        }) { return hit }
        if let u = Bundle.module.resourceURL?.appendingPathComponent("OS/\(p.isoName)"), fm.fileExists(atPath: u.path) { return u }
        return Res.url("OS/\(p.isoName)")
    }

    /// Copies a user-chosen setup image into the app's install folder for that OS.
    static func importMedia(_ src: URL, into p: Profile) throws {
        let fm = FileManager.default
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let dir = installDir(p)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(p.isoName)
        let tmp = dir.appendingPathComponent(p.isoName + ".part")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
    }

    // MARK: Autorun and fast boot, written into the disk by the app

    /// Windows 98: runs at every Windows start (Startup folder): the first `AUTORUN.BAT` found on drives D: to S: is called
    /// with its drive letter as `%1`. Drive letters can shift (Windows keeps the CD-ROM's letter), so no letter is assumed.
    static let autorunBat = "@echo off\r\nfor %%d in (D E F G H I J K L M N O P Q R S) do if exist %%d:\\AUTORUN.BAT call %%d:\\AUTORUN.BAT %%d:\r\n"

    /// MSDOS.SYS [Options]: no logo, no boot delay, no F8 menu, ScanDisk never, no boot log.
    private static let bootOptions: [(String, String)] = [("Logo", "0"), ("BootDelay", "0"), ("BootKeys", "0"), ("AutoScan", "0"), ("DisableLog", "1")]

    private static func patchedMsdosSys(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var header = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[options]" }
        if header == nil { lines.append("[Options]"); header = lines.count - 1 }
        let h = header!
        for (key, value) in bootOptions {
            var end = lines.count
            for j in (h + 1)..<lines.count where lines[j].hasPrefix("[") { end = j; break }
            if let j = ((h + 1)..<end).first(where: { lines[$0].lowercased().hasPrefix(key.lowercased() + "=") }) {
                lines[j] = "\(key)=\(value)"
            } else {
                lines.insert("\(key)=\(value)", at: h + 1)
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // Windows 3.1 has no Startup folder that runs batch files before Windows, so its hook is DOS-side: a managed block at
    // the end of the boot batch file (AUTOEXEC.BAT, and FDAUTO.BAT on FreeDOS disks) calls C:\GAMEAUTO.BAT, which runs the
    // first AUTORUN.BAT found on D: to S: (drive letter as %1) and then starts Windows. The pack's AUTORUN.BAT may set
    // `GAMEWIN` (e.g. `set GAMEWIN=%1\GAME\GAME.EXE`): Windows is then started with that program (`WIN <program>`).
    private static let dosBegin = "REM DOSCLASSICS-BEGIN"
    private static let dosEnd = "REM DOSCLASSICS-END"

    /// GAMEAUTO.BAT for Windows 3.1. `windowsDir` is the 8.3 name of the folder that holds WIN.COM.
    static func win31AutoBat(windowsDir: String) -> String {
        let letters = "DEFGHIJKLMNOPQRS".map { String($0) }
        var l = ["@echo off",
                 "if \"%DCRAN%\"==\"1\" goto end",       // already ran in this DOS session (AUTOEXEC.BAT and FDAUTO.BAT both patched)
                 "set DCRAN=1",
                 "set GAMEWIN=",
                 "path C:\\\(windowsDir);%path%"]
        for d in letters { l.append("if exist \(d):\\AUTORUN.BAT goto d\(d)") }
        l.append("goto launch")
        for d in letters {
            l.append(":d\(d)")
            l.append("call \(d):\\AUTORUN.BAT \(d):")
            l.append("goto launch")
        }
        l.append(":launch")
        l.append("if \"%GAMEWIN%\"==\"\" C:\\\(windowsDir)\\WIN.COM")
        l.append("if not \"%GAMEWIN%\"==\"\" C:\\\(windowsDir)\\WIN.COM %GAMEWIN%")
        l.append(":end")
        return l.joined(separator: "\r\n") + "\r\n"
    }

    /// AUTOEXEC.BAT / FDAUTO.BAT with the managed block at the end. Idempotent. A bare `WIN` line is commented out
    /// (GAMEAUTO.BAT starts Windows itself, so it would otherwise start twice).
    static func patchedAutoexec(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\u{1A}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        var inBlock = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces).uppercased()
            if t == dosBegin { inBlock = true; continue }
            if t == dosEnd { inBlock = false; continue }
            if inBlock { continue }
            let bare = String(line.trimmingCharacters(in: .whitespaces).lowercased().drop(while: { $0 == "@" }))
            let first = bare.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
            let isLauncher = first == "win" || first == "win.com" || first.hasSuffix("\\win") || first.hasSuffix("\\win.com")
            out.append(isLauncher ? "REM " + line : line)
        }
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        out += [dosBegin, "CALL C:\\GAMEAUTO.BAT", dosEnd]
        return out.joined(separator: "\r\n") + "\r\n"
    }

    /// 8.3 name of the root folder that holds WIN.COM ("WINDOWS" preferred), nil when Windows 3.1 isn't installed.
    private static func win31Directory(_ v: FatVolume) -> String? {
        let root = v.rootRegions()
        let dirs = v.entries(in: root).filter { $0.isDirectory && !$0.name.hasPrefix(".") }
        for d in dirs.sorted(by: { ($0.name.uppercased() == "WINDOWS" ? 0 : 1) < ($1.name.uppercased() == "WINDOWS" ? 0 : 1) }) {
            if v.find("WIN.COM", in: v.directory([d.name]) ?? []) != nil { return d.name }
        }
        return nil
    }

    private static let hookLock = NSLock()

    /// Makes the OS disk start silently and run the game drive's AUTORUN.BAT. Idempotent, called before every OS start
    /// (and from Settings), so there is nothing to do inside the OS. Returns a status line for Settings.
    @discardableResult
    static func applyHooks(_ p: Profile) -> String {
        hookLock.lock()
        defer { hookLock.unlock() }
        guard isInstalled(p) else { return "\(p.title) isn't set up." }
        guard let v = FatVolume(url: imageURL(p)) else { return "Couldn't open the \(p.title) disk (not a FAT16/FAT32 MBR image)." }
        defer { v.close() }
        // Windows 95 is not Windows 98: the 98 hooks rewrite registry keys that do not exist there. A pack on
        // win95 boots the disk as-is, so leave the disk untouched instead of corrupting it on every boot/quit.
        let status: String
        switch p.id {
        case win31.id: status = win31Hooks(v)
        case win95.id: status = win95Hooks(v)
        default: status = win98Hooks(v)
        }
        NSLog("%@ hooks: %@", p.title, status)
        return status
    }

    private static func win98Hooks(_ v: FatVolume) -> String {
        var parts: [String] = []
        if let e = v.find("MSDOS.SYS", in: v.rootRegions()),
           let old = String(bytes: v.read(e), encoding: .isoLatin1) {
            let new = patchedMsdosSys(old)
            if new == old { parts.append("fast boot on") }
            else if let d = new.data(using: .isoLatin1), v.overwrite(e, with: [UInt8](d)) { parts.append("fast boot applied") }
            else { parts.append("fast boot FAILED") }
        } else {
            parts.append("MSDOS.SYS not found")
        }

        if let startup = v.directory(["Windows", "Start Menu", "Programs", "StartUp"]) {
            parts.append(writeHookFile("GAMEAUTO.BAT", in: startup, data: [UInt8](autorunBat.utf8), on: v))
        } else {
            parts.append("autorun hook FAILED: no C:\\WINDOWS\\Start Menu\\Programs\\StartUp folder")
        }
        return parts.joined(separator: " · ")
    }

    /// Launcher for a Windows 95 pack. Windows 95 runs GUI apps, so there is no AUTOEXEC`WIN` hand-off like Windows
    /// 3.1: the pack drops AUTORUN.BAT on its game drive and this batch (placed in StartUp) calls it once the desktop
    /// is up. Same drive scan and same AUTORUN.BAT contract as Windows 3.1, only without the WIN.COM launch.
    static func win95AutoBat() -> String {
        let letters = "DEFGHIJKLMNOPQRS".map { String($0) }
        var l = ["@echo off",
                 "if \"%DCRAN%\"==\"1\" goto end",
                 "set DCRAN=1"]
        for d in letters { l.append("if exist \(d):\\AUTORUN.BAT goto d\(d)") }
        l.append("goto end")
        for d in letters {
            l.append(":d\(d)")
            l.append("call \(d):\\AUTORUN.BAT \(d):")
            l.append("goto end")
        }
        l.append(":end")
        return l.joined(separator: "\r\n") + "\r\n"
    }

    /// WIN.INI `run=` line: Windows 95 launches it through the shell once the desktop is up, so the pack's batch never
    /// sits in a full-screen DOS box (that is what looked like a freeze). The line runs C:\GAMEAUTO.BAT, which scans
    /// D: to S: for the pack's AUTORUN.BAT: no hard-coded game-drive letter (the CD may be D: or E:) and no "cannot
    /// find D:\AUTORUN.BAT" dialog while the game drive is still empty (install).
    private static let win95RunLine = "C:\\GAMEAUTO.BAT"
    private static func patchedWinIni(_ text: String, runLine: String? = win95RunLine) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        var inWindows = false
        var inserted = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                if inWindows && !inserted { if let runLine { out.append("run=\(runLine)") }; inserted = true }
                inWindows = t.lowercased() == "[windows]"
                out.append(line)
                continue
            }
            if inWindows && t.lowercased().hasPrefix("run=") { continue }
            out.append(line)
        }
        if inWindows && !inserted { if let runLine { out.append("run=\(runLine)") }; inserted = true }
        if !inserted { out.insert(contentsOf: ["[windows]", "run=\(runLine ?? "")"], at: 0) }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    private static func win95Hooks(_ v: FatVolume) -> String {
        guard let winDir = win31Directory(v) else { return "autorun hook FAILED: Windows 95 (WIN.COM) isn't installed on the disk yet" }
        let root = v.rootRegions()
        var parts: [String] = []
        parts.append(writeHookFile("GAMEAUTO.BAT", in: root, data: [UInt8](win95AutoBat().utf8), on: v))
        let winRegions = v.directory([winDir]) ?? []
        if let e = v.find("WIN.INI", in: winRegions) {
            let old = String(bytes: v.read(e), encoding: .isoLatin1) ?? ""
            let new = patchedWinIni(old)
            if new == old { parts.append("WIN.INI run=\(win95RunLine)") }
            else if let d = new.data(using: .isoLatin1), v.overwrite(e, with: [UInt8](d)) { parts.append("WIN.INI run=\(win95RunLine)") }
            else { parts.append("WIN.INI FAILED") }
        } else {
            parts.append("WIN.INI missing")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Opens the bare Windows 95 (Settings → Open): any `run=` line left by a pack would make Windows complain about a
    /// missing D:\\AUTORUN.BAT, so the hook line is removed instead of applied.
    static func clearWin95RunLine(_ p: Profile) -> String {
        guard let v = FatVolume(url: imageURL(p)) else { return "no disk" }
        defer { v.close() }
        guard let winDir = win31Directory(v), let e = v.find("WIN.INI", in: v.directory([winDir]) ?? []) else { return "no WIN.INI" }
        let old = String(bytes: v.read(e), encoding: .isoLatin1) ?? ""
        let new = patchedWinIni(old, runLine: nil)
        guard new != old else { return "run= already clear" }
        guard let d = new.data(using: .isoLatin1) else { return "WIN.INI encode failed" }
        return v.overwrite(e, with: [UInt8](d)) ? "run= cleared" : "WIN.INI FAILED"
    }

    private static func win31Hooks(_ v: FatVolume) -> String {
        guard let winDir = win31Directory(v) else { return "autorun hook FAILED: Windows 3.1 (WIN.COM) isn't installed on the disk yet" }
        var parts: [String] = []
        let root = v.rootRegions()
        parts.append(writeHookFile("GAMEAUTO.BAT", in: root, data: [UInt8](win31AutoBat(windowsDir: winDir).utf8), on: v))

        var patched: [String] = [], failed: [String] = []
        for name in ["AUTOEXEC.BAT", "FDAUTO.BAT"] {
            guard let e = v.find(name, in: root) else { continue }
            let old = String(bytes: v.read(e), encoding: .isoLatin1) ?? ""
            let new = patchedAutoexec(old)
            if new == old { patched.append(name) }
            else if let d = new.data(using: .isoLatin1), v.overwrite(e, with: [UInt8](d)) { patched.append(name) }
            else { failed.append(name) }
        }
        if patched.isEmpty && failed.isEmpty {
            // Neither boot batch exists yet (fresh DOS disk): create one.
            let d = patchedAutoexec("@echo off\r\n")
            if let data = d.data(using: .isoLatin1), v.create("AUTOEXEC.BAT", in: root, data: [UInt8](data)) { patched.append("AUTOEXEC.BAT (new)") }
            else { failed.append("AUTOEXEC.BAT") }
        }
        if !patched.isEmpty { parts.append("boot hook in " + patched.joined(separator: ", ")) }
        if !failed.isEmpty { parts.append("boot hook FAILED in " + failed.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Creates or refreshes one small hook file; returns the status fragment.
    private static func writeHookFile(_ name: String, in dir: [FatVolume.Region], data: [UInt8], on v: FatVolume) -> String {
        if let e = v.find(name, in: dir) {
            if v.read(e) == data { return "autorun hook installed" }
            return v.overwrite(e, with: data) ? "autorun hook updated" : "autorun hook FAILED"
        }
        return v.create(name, in: dir, data: data) ? "autorun hook installed" : "autorun hook FAILED (disk or folder full)"
    }

    // MARK: Pre-built disk shipped inside the app

    /// A pre-built disk of the OS placed in the project (Sources/Retronaut/Resources/OS/<imageName>, plus the
    /// <geometryName> file from the export zip). When present the app uses it instead of asking for a setup from scratch.
    static func bundledImageURL(_ p: Profile) -> URL? {
        // SwiftPM can nest resources directly in the bundle or one level down in
        // a copied `Resources` folder — probe both, then the resolved root.
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resourceURL = Bundle.module.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("OS/\(p.imageName)"))
            candidates.append(resourceURL.appendingPathComponent("Resources/OS/\(p.imageName)"))
        }
        for relative in ["OS/\(p.imageName)", "Resources/OS/\(p.imageName)"] {
            if let path = Res.path(relative) { candidates.append(URL(fileURLWithPath: path)) }
        }
        for candidate in candidates where fm.fileExists(atPath: candidate.path) { return candidate }
        return nil
    }

    /// True when the OS can actually be started: the disk exists and, for Windows 3.1 (whose disk may be just a bare DOS
    /// disk before Setup has run), Windows is really on it.
    static func isReady(_ p: Profile) -> Bool {
        guard isInstalled(p) else { return false }
        if p.usesInstallerDisk { return true }
        guard let v = FatVolume(url: imageURL(p)) else { return false }
        defer { v.close() }
        return win31Directory(v) != nil
    }

    /// Copies the bundled disk to the working location. No-op when a working disk exists (an app update never replaces
    /// the user's disk: Reset or Import does). True when the OS is ready.
    @discardableResult
    static func provision(_ p: Profile) -> Bool {
        if isInstalled(p) { return true }
        guard let img = bundledImageURL(p) else { return false }
        var hint: Geometry?
        let side = img.deletingLastPathComponent().appendingPathComponent(p.geometryName)
        if let s = try? String(contentsOf: side, encoding: .utf8) { hint = geometry(from: s) }
        return (try? adopt(img, into: p, geometryHint: hint, deleteSource: false)) != nil
    }

    // MARK: Setup → working disk

    /// Disks (.vhd / .img) the installer wrote since setup of that OS began (Windows 98 only: its installer saves a VHD in
    /// Documents or next to the CD image; Windows 3.1 installs straight into the working disk).
    static func installerDisks(_ p: Profile) -> [URL] {
        guard p.usesInstallerDisk,
              let since = (UserDefaults.standard.object(forKey: p.startKey) as? Date)?.addingTimeInterval(-60) else { return [] }
        let fm = FileManager.default
        var out: [(URL, Date)] = []
        for dir in [documents, installDir(p)] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
            for u in items where ["vhd", "img"].contains(u.pathExtension.lowercased()) {
                let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                if v?.isDirectory == true { continue }
                if let m = v?.contentModificationDate, m >= since { out.append((u, m)) }
            }
        }
        return out.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// True while a setup of that OS was started and not yet confirmed.
    static func setupPending(_ p: Profile) -> Bool {
        if p.usesInstallerDisk { return !installerDisks(p).isEmpty }
        return isInstalled(p) && !isReady(p) && UserDefaults.standard.object(forKey: p.startKey) != nil
    }

    /// "Yes, it reached the desktop": Windows 98 turns the installer's disk into the working disk; Windows 3.1 checks that
    /// Setup really put Windows on the working disk (it was installed in place).
    @discardableResult
    static func finishInstall(_ p: Profile) throws -> Geometry {
        if !p.usesInstallerDisk {
            guard isInstalled(p), let g = geometry(p) else {
                throw OSError(message: "No \(p.title) disk was found. Start setup again.")
            }
            if let v = FatVolume(url: imageURL(p)) {
                defer { v.close() }
                if win31Directory(v) == nil {
                    throw OSError(message: "\(p.title) isn't on the disk yet (no WIN.COM found). Run SETUP from the setup disc and let it finish, then quit.")
                }
            }
            UserDefaults.standard.removeObject(forKey: p.startKey)
            return g
        }
        guard let disk = installerDisks(p).first else {
            throw OSError(message: "No \(p.title) disk was found. In the setup menu choose “Boot and Install New Operating System” and let it finish.")
        }
        let g = try adopt(disk, into: p, deleteSource: true)
        UserDefaults.standard.removeObject(forKey: p.startKey)
        return g
    }

    /// Makes `src` (raw image, fixed or dynamic VHD) the working disk of that OS. A dynamic VHD is expanded into a raw
    /// sparse image: only the blocks really written take space, and the core's `imgmount` handles raw disks reliably.
    @discardableResult
    static func adopt(_ src: URL, into p: Profile, geometryHint: Geometry? = nil, deleteSource: Bool = true) throws -> Geometry {
        let fm = FileManager.default
        try fm.createDirectory(at: root(p), withIntermediateDirectories: true)
        let tmp = root(p).appendingPathComponent(p.imageName + ".part")
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }
        var footerGeo: Geometry?
        if let g = try vhdToRaw(src, to: tmp) { footerGeo = g } else { try fm.copyItem(at: src, to: tmp) }
        let size = fileSize(tmp)
        guard size >= 8 * 1024 * 1024, let mbr = readBytes(tmp, 0, 512), mbr[510] == 0x55, mbr[511] == 0xAA else {
            throw OSError(message: "That file isn't a bootable hard-disk image.")
        }
        // The boot sector records the geometry the OS was installed with: trust it first, then the VHD footer, then the MBR.
        guard var geo = geometryHint ?? bpbGeometry(tmp) ?? footerGeo ?? mbrGeometry(tmp) else {
            throw OSError(message: "Couldn't work out the disk geometry.")
        }
        geo.cyl = max(1, Int(size / 512) / (geo.heads * geo.spt))
        try? fm.removeItem(at: imageURL(p))
        try fm.moveItem(at: tmp, to: imageURL(p))
        try geo.text.write(to: geometryURL(p), atomically: true, encoding: .utf8)
        if deleteSource { try? fm.removeItem(at: src) }
        return geo
    }

    /// Deletes the working disk of the given OS (and any half-finished setup disk). Packs are never touched.
    static func reset(_ p: Profile) throws {
        let fm = FileManager.default
        for u in installerDisks(p) { try? fm.removeItem(at: u) }
        try? fm.removeItem(at: imageURL(p))
        try? fm.removeItem(at: geometryURL(p))
        UserDefaults.standard.removeObject(forKey: p.startKey)
        if isInstalled(p) { throw OSError(message: "Couldn't delete the \(p.title) disk.") }
    }

    // MARK: Export / import

    /// A zip holding a compacted copy of the OS disk (free space zeroed, so it compresses to about the size of what is
    /// really installed), its geometry and a README for the Mac. Share it with AirDrop / Files.
    static func prepareExport(_ p: Profile) throws -> URL {
        let fm = FileManager.default
        guard isInstalled(p), let geo = geometry(p) else { throw OSError(message: "\(p.title) isn't set up yet.") }
        let base = fm.temporaryDirectory.appendingPathComponent("\(p.id)-export", isDirectory: true)
        try? fm.removeItem(at: base)
        let title = p.title.replacingOccurrences(of: " ", with: "")
        let folder = base.appendingPathComponent("\(title)-Retronaut", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let img = folder.appendingPathComponent(p.imageName)
        try fm.copyItem(at: imageURL(p), to: img)          // APFS clone: no extra space until it is modified
        markClean(img)
        zeroFreeSpace(img)
        try geo.text.write(to: folder.appendingPathComponent(p.geometryName), atomically: true, encoding: .utf8)
        var readme = """
        \(p.title) disk exported from Retronaut.

        \(p.imageName)       raw hard-disk image (MBR + one FAT partition), geometry \(geo.spt) sectors/track, \(geo.heads) heads, \(geo.cyl) cylinders
        \(p.geometryName)  the same numbers, read back by Retronaut when you import this zip

        Restore in Retronaut: Settings → \(p.title) → Import \(p.title) image (pick this zip or \(p.imageName)).
        DOSBox-X / DOSBox Pure: imgmount c \(p.imageName) -t hdd -fs none -size 512,\(geo.spt),\(geo.heads),\(geo.cyl)
        """
        if p.id == win98.id {
            readme += """

            QEMU / UTM:             qemu-img convert -f raw -O qcow2 \(p.imageName) win98.qcow2
            VirtualBox:             VBoxManage convertfromraw \(p.imageName) win98.vdi
            """
        }
        try readme.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        var coordError: NSError?
        var result: URL?
        var moveError: Error?
        let dst = base.appendingPathComponent("\(title)-Retronaut.zip")
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { zipURL in
            do { try? fm.removeItem(at: dst); try fm.moveItem(at: zipURL, to: dst); result = dst } catch { moveError = error }
        }
        try? fm.removeItem(at: img)
        if let e = coordError { throw e }
        if let e = moveError { throw e }
        guard let result else { throw OSError(message: "Couldn't create the zip.") }
        return result
    }

    /// Replaces the working disk of an OS with a disk image or an exported zip.
    @discardableResult
    static func importImage(_ url: URL, into p: Profile) throws -> Geometry {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "zip" else { return try adopt(url, into: p, deleteSource: false) }
        let tmp = fm.temporaryDirectory.appendingPathComponent("\(p.id)-import", isDirectory: true)
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }
        try ZipExtractor.extract(url, to: tmp, stripSingleRoot: false)
        var disk: URL?, hint: Geometry?
        if let en = fm.enumerator(at: tmp, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            var best = -1
            for case let u as URL in en {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if v?.isDirectory == true { continue }
                if u.lastPathComponent.hasPrefix("._") || u.pathComponents.contains("__MACOSX") { continue }   // macOS zip resource forks
                let ext = u.pathExtension.lowercased()
                if ext == "geometry", let t = try? String(contentsOf: u, encoding: .utf8), let g = geometry(from: t) { hint = g }
                if ["img", "vhd", "ima"].contains(ext), (v?.fileSize ?? 0) > best { best = v?.fileSize ?? 0; disk = u }
            }
        }
        guard let disk else { throw OSError(message: "No disk image (.img / .vhd) found in that zip.") }
        return try adopt(disk, into: p, geometryHint: hint, deleteSource: false)
    }

    // MARK: VHD → raw

    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(b[o + $1]) }
    }
    private static func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(b[o + $1]) }
    }

    private static func isZero(_ d: Data) -> Bool {
        d.withUnsafeBytes { raw -> Bool in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 0 else { return true }
            return p[0] == 0 && memcmp(p, p + 1, raw.count - 1) == 0
        }
    }

    /// Expands a fixed or dynamic VHD into a raw image at `dst` (only non-zero data is written, so the file stays sparse).
    /// Returns the VHD's geometry, or nil when `src` isn't a VHD at all.
    static func vhdToRaw(_ src: URL, to dst: URL) throws -> Geometry? {
        let fm = FileManager.default
        guard let fh = try? FileHandle(forReadingFrom: src) else { throw OSError(message: "Couldn't open the disk image.") }
        defer { try? fh.close() }
        let fileLen = try fh.seekToEnd()
        guard fileLen >= 1024 else { return nil }

        func read(_ off: UInt64, _ n: Int) throws -> Data {
            try fh.seek(toOffset: off)
            guard let d = try fh.read(upToCount: n), d.count == n else { throw OSError(message: "The VHD is truncated or damaged.") }
            return d
        }
        let footer = [UInt8](try read(fileLen - 512, 512))
        guard String(bytes: footer[0..<8], encoding: .ascii) == "conectix" else { return nil }

        let current = be64(footer, 48)
        let type = be32(footer, 60)
        var geo = Geometry(spt: Int(footer[59]), heads: Int(footer[58]), cyl: Int(footer[56]) << 8 | Int(footer[57]))
        if geo.spt == 0 || geo.heads == 0 { geo = Geometry(spt: 63, heads: 16, cyl: 1) }
        guard current >= 8 * 1024 * 1024 else { throw OSError(message: "The VHD is too small to be a Windows disk.") }

        fm.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        try out.truncate(atOffset: current)

        func put(_ d: Data, at off: UInt64) throws {
            if isZero(d) { return }
            try out.seek(toOffset: off)
            try out.write(contentsOf: d)
        }

        if type == 2 {                                   // fixed: the data is the file minus the footer
            let chunk = 1 << 20
            var pos: UInt64 = 0
            while pos < current {
                try autoreleasepool {
                    let n = Int(min(UInt64(chunk), current - pos))
                    try put(try read(pos, n), at: pos)
                    pos += UInt64(n)
                }
            }
        } else if type == 3 {                            // dynamic: header + block allocation table
            let hdrOff = be64(footer, 16)
            let hdr = [UInt8](try read(hdrOff, 1024))
            guard String(bytes: hdr[0..<8], encoding: .ascii) == "cxsparse" else { throw OSError(message: "Unsupported VHD header.") }
            let tableOff = be64(hdr, 16)
            let entries = Int(be32(hdr, 28))
            let blockSize = Int(be32(hdr, 32))
            guard entries > 0, blockSize >= 512, blockSize <= 64 << 20 else { throw OSError(message: "Unsupported VHD block size.") }
            let bat = [UInt8](try read(tableOff, entries * 4))
            let bitmapBytes = (((blockSize / 512) + 7) / 8 + 511) / 512 * 512
            for i in 0..<entries {
                let sector = be32(bat, i * 4)
                if sector == 0xFFFF_FFFF { continue }
                let diskOff = UInt64(i) * UInt64(blockSize)
                if diskOff >= current { break }
                try autoreleasepool {
                    let data = try read(UInt64(sector) * 512 + UInt64(bitmapBytes), blockSize)
                    let n = Int(min(UInt64(blockSize), current - diskOff))
                    try put(n == blockSize ? data : data.prefix(n), at: diskOff)
                }
            }
        } else {
            throw OSError(message: "Differencing VHDs aren't supported.")
        }
        return geo
    }

    /// VHD disk type from the footer (2 = fixed, 3 = dynamic, 4 = differencing); nil when `url` isn't a VHD.
    static func vhdType(_ url: URL) -> UInt32? {
        let size = fileSize(url)
        guard size >= 1024, let f = readBytes(url, size - 512, 512),
              String(bytes: f[0..<8], encoding: .ascii) == "conectix" else { return nil }
        return be32(f, 60)
    }

    // MARK: Disk helpers

    static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func readBytes(_ url: URL, _ off: UInt64, _ n: Int) -> [UInt8]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        return readAt(fh, off, n)
    }

    static func readAt(_ fh: FileHandle, _ off: UInt64, _ n: Int) -> [UInt8]? {
        guard (try? fh.seek(toOffset: off)) != nil, let d = try? fh.read(upToCount: n), d.count == n else { return nil }
        return [UInt8](d)
    }

    static func le(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 {
        (0..<n).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << UInt64(8 * $1) }
    }

    /// Heads / sectors-per-track from the first partition's end CHS (end head, end sector).
    static func mbrGeometry(_ url: URL) -> Geometry? {
        guard let mbr = readBytes(url, 0, 512), mbr[510] == 0x55, mbr[511] == 0xAA else { return nil }
        var heads = 16, spt = 63
        for o in stride(from: 446, to: 510, by: 16) where mbr[o + 4] != 0 {
            // End head 0 (mtools / Mac tools) would read as "1 head": only believe plausible values.
            let h = Int(mbr[o + 5]) + 1, s = Int(mbr[o + 6] & 0x3F)
            if h > 1, h <= 255, s > 0 { heads = h; spt = s }
            break
        }
        return Geometry(spt: spt, heads: heads, cyl: max(1, Int(fileSize(url) / 512) / (heads * spt)))
    }

    /// Heads / sectors-per-track Windows formatted the partition with (BIOS parameter block).
    private static func bpbGeometry(_ url: URL) -> Geometry? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let f = fatLayout(fh, fileSize: fileSize(url)), let bs = readAt(fh, f.start * 512, 512) else { return nil }
        let spt = Int(le(bs, 24, 2)), heads = Int(le(bs, 26, 2))
        guard spt > 0, spt <= 63, heads > 0, heads <= 255 else { return nil }
        return Geometry(spt: spt, heads: heads, cyl: max(1, Int(fileSize(url) / 512) / (heads * spt)))
    }

    // MARK: FAT

    struct Fat {
        var fat32: Bool
        var spc: UInt64, reserved: UInt64, copies: UInt64, fatSectors: UInt64
        var start: UInt64          // partition start sector
        var dataStart: UInt64      // first data sector (absolute)
        var clusters: UInt64
    }

    /// Reads the first partition's FAT16 / FAT32 layout. nil for anything else.
    static func fatLayout(_ fh: FileHandle, fileSize: UInt64) -> Fat? {
        guard let mbr = readAt(fh, 0, 512), mbr[510] == 0x55, mbr[511] == 0xAA else { return nil }
        var start: UInt64 = 0
        for o in stride(from: 446, to: 510, by: 16) where mbr[o + 4] != 0 {
            start = le(mbr, o + 8, 4)
            break
        }
        guard start > 0, let bs = readAt(fh, start * 512, 512) else { return nil }
        let bps = le(bs, 11, 2), spc = UInt64(bs[13]), reserved = le(bs, 14, 2), copies = UInt64(bs[16])
        guard bps == 512, spc > 0, copies >= 1, copies <= 2 else { return nil }
        let fat32 = Array(bs[82..<87]) == Array("FAT32".utf8)
        let rootSectors = (le(bs, 17, 2) * 32 + 511) / 512
        let fatSectors = fat32 ? le(bs, 36, 4) : le(bs, 22, 2)
        let total16 = le(bs, 19, 2)
        let total = total16 != 0 ? total16 : le(bs, 32, 4)
        let dataStart = start + reserved + copies * fatSectors + rootSectors
        let partEnd = min(start + total, fileSize / 512)
        guard partEnd > dataStart else { return nil }
        return Fat(fat32: fat32, spc: spc, reserved: reserved, copies: copies, fatSectors: fatSectors,
                   start: start, dataStart: dataStart, clusters: (partEnd - dataStart) / spc)
    }

    // MARK: No ScanDisk

    /// Sets the FAT "shut down cleanly" flag on a raw MBR disk image (FAT16 or FAT32), in both FAT copies.
    ///
    /// Windows 98 runs ScanDisk at boot whenever that flag is clear, which happens every time the app is closed or the
    /// emulator stopped without Start → Shut Down (always, on a phone). Setting the flag before the core starts means
    /// ScanDisk never runs. Trade-off: real corruption is no longer announced; Settings → Windows 98 → Reset is the cure.
    /// Only touches a few bytes per FAT copy, only when the flag is clear. Call it while the core is NOT running.
    static func markClean(_ url: URL) {
        guard url.pathExtension.lowercased() != "vhd", let fh = try? FileHandle(forUpdating: url) else { return }
        defer { try? fh.close() }
        guard let f = fatLayout(fh, fileSize: fileSize(url)), f.fat32 || f.clusters >= 4085 else { return }   // never touch FAT12 (12-bit entries)
        let width = f.fat32 ? 4 : 2                    // FAT[1] is 2 bytes in FAT16, 4 in FAT32
        let highByte = width - 1
        let cleanBit: UInt8 = f.fat32 ? 0x08 : 0x80    // FAT16: 0x8000, FAT32: 0x08000000
        for k in 0..<f.copies {
            let off = (f.start + f.reserved + k * f.fatSectors) * 512 + UInt64(width)   // entry 1
            guard var entry = readAt(fh, off, width), entry[highByte] & cleanBit == 0 else { continue }
            entry[highByte] |= cleanBit
            try? fh.seek(toOffset: off)
            try? fh.write(contentsOf: Data(entry))
        }
    }

    // MARK: Compact

    /// Writes zeros over every unused cluster (only where something non-zero is there). Free space then compresses to
    /// nothing in the export zip, and a sparse file stays sparse. Windows doesn't care: free clusters are free.
    @discardableResult
    static func zeroFreeSpace(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forUpdating: url) else { return false }
        defer { try? fh.close() }
        guard let f = fatLayout(fh, fileSize: fileSize(url)), f.clusters >= 4085 else { return false }
        let fatBytes = Int(f.fatSectors * 512)
        guard let fat = readAt(fh, (f.start + f.reserved) * 512, fatBytes) else { return false }
        let width = f.fat32 ? 4 : 2
        func entry(_ n: Int) -> UInt32 {
            let o = n * width
            guard o + width <= fat.count else { return 1 }          // outside the FAT: treat as used
            if f.fat32 {
                return (UInt32(fat[o]) | UInt32(fat[o + 1]) << 8 | UInt32(fat[o + 2]) << 16 | UInt32(fat[o + 3]) << 24) & 0x0FFF_FFFF
            }
            return UInt32(fat[o]) | UInt32(fat[o + 1]) << 8
        }
        let clusterBytes = Int(f.spc * 512)
        let maxRun = max(1, (1 << 20) / clusterBytes)
        let last = Int(f.clusters) + 1
        var n = 2
        while n <= last {
            if entry(n) != 0 { n += 1; continue }
            var run = 1
            while n + run <= last, run < maxRun, entry(n + run) == 0 { run += 1 }
            let off = (f.dataStart + UInt64(n - 2) * f.spc) * 512
            let len = run * clusterBytes
            if let d = readAt(fh, off, len), !isZero(Data(d)) {
                try? fh.seek(toOffset: off)
                try? fh.write(contentsOf: Data(count: len))
            }
            n += run
        }
        return true
    }
}
