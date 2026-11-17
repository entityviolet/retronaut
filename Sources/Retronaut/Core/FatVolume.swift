import Foundation

/// Minimal read/write access to the first FAT16 / FAT32 partition of a raw MBR disk image: find files and folders
/// (short and long names), create a small file, overwrite a file. Just enough to put the autorun hook and the fast-boot
/// settings into the shared Windows 98 disk from the app, with no step to perform inside Windows.
/// Call it while the core is NOT running.
final class FatVolume {
    struct Region { let offset: UInt64; let length: Int }

    struct Entry {
        let offset: UInt64          // where the 32-byte directory entry lives
        let name: String            // 8.3 name, "NAME.EXT"
        let longName: String?
        let attr: UInt8
        let first: UInt32           // first cluster
        let size: UInt32
        var isDirectory: Bool { attr & 0x10 != 0 }
    }

    private let fh: FileHandle
    private let f: BaseOS.Fat
    private var fat: [UInt8]
    private let width: Int
    private let clusterBytes: Int
    private let rootCluster: UInt32
    private let rootFixed: UInt64
    private let rootSectors: UInt64
    private let eoc: UInt32
    private let fsInfoOffset: UInt64?

    init?(url: URL) {
        guard let h = try? FileHandle(forUpdating: url) else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        guard let layout = BaseOS.fatLayout(h, fileSize: size),
              layout.fat32 || layout.clusters >= 4085,          // FAT12 (12-bit entries) isn't supported

              let bs = BaseOS.readAt(h, layout.start * 512, 512),
              let table = BaseOS.readAt(h, (layout.start + layout.reserved) * 512, Int(layout.fatSectors * 512)) else {
            try? h.close()
            return nil
        }
        fh = h
        f = layout
        fat = table
        width = layout.fat32 ? 4 : 2
        clusterBytes = Int(layout.spc * 512)
        rootCluster = layout.fat32 ? UInt32(BaseOS.le(bs, 44, 4)) : 0
        rootSectors = (BaseOS.le(bs, 17, 2) * 32 + 511) / 512
        rootFixed = (layout.start + layout.reserved + layout.copies * layout.fatSectors) * 512
        eoc = layout.fat32 ? 0x0FFF_FFFF : 0xFFFF
        if layout.fat32 {
            let info = UInt64(BaseOS.le(bs, 48, 2))
            fsInfoOffset = info > 0 ? (layout.start + info) * 512 : nil
        } else {
            fsInfoOffset = nil
        }
    }

    func close() { try? fh.close() }

    // MARK: FAT

    private func entry(_ n: Int) -> UInt32 {
        let o = n * width
        guard o >= 0, o + width <= fat.count else { return 1 }
        if f.fat32 {
            return (UInt32(fat[o]) | UInt32(fat[o + 1]) << 8 | UInt32(fat[o + 2]) << 16 | UInt32(fat[o + 3]) << 24) & 0x0FFF_FFFF
        }
        return UInt32(fat[o]) | UInt32(fat[o + 1]) << 8
    }

    private func setEntry(_ n: Int, _ v: UInt32) {
        let o = n * width
        guard o >= 0, o + width <= fat.count else { return }
        fat[o] = UInt8(v & 0xFF)
        fat[o + 1] = UInt8((v >> 8) & 0xFF)
        if f.fat32 {
            // keep the top 4 bits of the 32-bit entry as they were
            fat[o + 2] = UInt8((v >> 16) & 0xFF)
            fat[o + 3] = (fat[o + 3] & 0xF0) | UInt8((v >> 24) & 0x0F)
        }
    }

    private func isEnd(_ v: UInt32) -> Bool { v >= (f.fat32 ? 0x0FFF_FFF8 : 0xFFF8) }
    private func offset(of cluster: Int) -> UInt64 { (f.dataStart + UInt64(cluster - 2) * f.spc) * 512 }
    private var lastCluster: Int { Int(f.clusters) + 1 }

    private func chain(_ first: UInt32) -> [Int] {
        var out: [Int] = []
        var n = Int(first)
        while n >= 2, n <= lastCluster, out.count <= Int(f.clusters) {
            out.append(n)
            let v = entry(n)
            if isEnd(v) || v < 2 { break }
            n = Int(v)
        }
        return out
    }

    private func flushFAT() {
        for k in 0..<f.copies {
            try? fh.seek(toOffset: (f.start + f.reserved + k * f.fatSectors) * 512)
            try? fh.write(contentsOf: Data(fat))
        }
    }

    /// Takes `count` free clusters off the FAT (not yet linked). nil when the disk is full.
    private func allocate(_ count: Int) -> [Int]? {
        var got: [Int] = []
        var n = 2
        while got.count < count, n <= lastCluster {
            if entry(n) == 0 { got.append(n) }
            n += 1
        }
        return got.count == count ? got : nil
    }

    private func link(_ clusters: [Int]) {
        for (a, b) in zip(clusters, clusters.dropFirst()) { setEntry(a, UInt32(b)) }
        if let last = clusters.last { setEntry(last, eoc) }
    }

    /// FAT32 only: keep the "free clusters" hint right (Windows trusts it for the free-space display).
    private func adjustFreeCount(by delta: Int) {
        guard let o = fsInfoOffset, let info = BaseOS.readAt(fh, o, 512),
              BaseOS.le(info, 0, 4) == 0x4161_5252, BaseOS.le(info, 484, 4) == 0x6141_7272 else { return }
        let free = BaseOS.le(info, 488, 4)
        guard free != 0xFFFF_FFFF else { return }
        let new = UInt32(clamping: max(0, Int(free) + delta))
        try? fh.seek(toOffset: o + 488)
        try? fh.write(contentsOf: Data([UInt8(new & 0xFF), UInt8((new >> 8) & 0xFF), UInt8((new >> 16) & 0xFF), UInt8((new >> 24) & 0xFF)]))
    }

    // MARK: Directories

    func rootRegions() -> [Region] {
        if f.fat32 { return chain(rootCluster).map { Region(offset: offset(of: $0), length: clusterBytes) } }
        return [Region(offset: rootFixed, length: Int(rootSectors) * 512)]
    }

    private func regions(of dirCluster: UInt32) -> [Region] {
        chain(dirCluster).map { Region(offset: offset(of: $0), length: clusterBytes) }
    }

    /// Every live entry of a directory, in order (long names are folded into their short entry).
    func entries(in regions: [Region]) -> [Entry] {
        var out: [Entry] = []
        var lfn: [Int: [UInt16]] = [:]
        for r in regions {
            guard let raw = BaseOS.readAt(fh, r.offset, r.length) else { continue }
            var i = 0
            while i + 32 <= raw.count {
                let e = Array(raw[i..<(i + 32)])
                defer { i += 32 }
                if e[0] == 0 { return out }
                if e[0] == 0xE5 { lfn = [:]; continue }
                if e[11] == 0x0F {
                    var chars: [UInt16] = []
                    for p in [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30] { chars.append(UInt16(e[p]) | UInt16(e[p + 1]) << 8) }
                    lfn[Int(e[0] & 0x1F)] = chars
                    continue
                }
                var long: String?
                if !lfn.isEmpty {
                    var units: [UInt16] = []
                    for k in lfn.keys.sorted() { units += lfn[k] ?? [] }
                    if let end = units.firstIndex(where: { $0 == 0 || $0 == 0xFFFF }) { units = Array(units[..<end]) }
                    long = String(decoding: units, as: UTF16.self)
                }
                lfn = [:]
                if e[11] & 0x08 != 0 { continue }          // volume label
                let base = String(decoding: e[0..<8], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                let ext = String(decoding: e[8..<11], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                let hi = f.fat32 ? UInt32(e[20]) | UInt32(e[21]) << 8 : 0
                let first = (UInt32(e[26]) | UInt32(e[27]) << 8) | hi << 16
                let size = UInt32(e[28]) | UInt32(e[29]) << 8 | UInt32(e[30]) << 16 | UInt32(e[31]) << 24
                out.append(Entry(offset: r.offset + UInt64(i), name: ext.isEmpty ? base : base + "." + ext,
                                 longName: long, attr: e[11], first: first, size: size))
            }
        }
        return out
    }

    func find(_ name: String, in regions: [Region]) -> Entry? {
        let n = name.lowercased()
        return entries(in: regions).first { $0.name.lowercased() == n || $0.longName?.lowercased() == n }
    }

    /// Folder by path, e.g. ["Windows", "Start Menu", "Programs", "StartUp"] (long or short names, any case).
    func directory(_ path: [String]) -> [Region]? {
        var regs = rootRegions()
        for p in path {
            guard let e = find(p, in: regs), e.isDirectory else { return nil }
            regs = regions(of: e.first)
        }
        return regs
    }

    // MARK: Files

    func read(_ e: Entry) -> [UInt8] {
        var out: [UInt8] = []
        for c in chain(e.first) {
            guard let d = BaseOS.readAt(fh, offset(of: c), clusterBytes) else { break }
            out += d
            if out.count >= Int(e.size) { break }
        }
        return Array(out.prefix(Int(e.size)))
    }

    private func write(_ data: [UInt8], to clusters: [Int]) {
        for (i, c) in clusters.enumerated() {
            let lo = i * clusterBytes
            var block = [UInt8](repeating: 0, count: clusterBytes)
            if lo < data.count {
                let part = data[lo..<min(data.count, lo + clusterBytes)]
                block.replaceSubrange(0..<part.count, with: part)
            }
            try? fh.seek(toOffset: offset(of: c))
            try? fh.write(contentsOf: Data(block))
        }
    }

    private func put32(_ v: UInt32, at off: UInt64) {
        try? fh.seek(toOffset: off)
        try? fh.write(contentsOf: Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]))
    }

    private func put16(_ v: UInt32, at off: UInt64) {
        try? fh.seek(toOffset: off)
        try? fh.write(contentsOf: Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]))
    }

    /// Replaces the contents of an existing file (grows its cluster chain when needed).
    @discardableResult
    func overwrite(_ e: Entry, with data: [UInt8]) -> Bool {
        var clusters = e.first >= 2 ? chain(e.first) : []
        let need = max(1, (data.count + clusterBytes - 1) / clusterBytes)
        var added = 0
        if clusters.count < need {
            guard let extra = allocate(need - clusters.count) else { return false }
            clusters += extra
            link(clusters)
            added = extra.count
        }
        write(data, to: Array(clusters.prefix(need)))
        put32(UInt32(data.count), at: e.offset + 28)
        if e.first < 2 {
            put16(UInt32(clusters[0] & 0xFFFF), at: e.offset + 26)
            if f.fat32 { put16(UInt32(clusters[0] >> 16), at: e.offset + 20) }
        }
        flushFAT()
        if added > 0, f.fat32 { adjustFreeCount(by: -added) }
        return true
    }

    /// Creates `name` (plain upper-case 8.3, no long name) in a directory. False when the directory is full or the disk is.
    @discardableResult
    func create(_ name: String, in regions: [Region], data: [UInt8], attr: UInt8 = 0x20) -> Bool {
        let parts = name.uppercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let base = String((parts[0] + "        ").prefix(8))
        let ext = String(((parts.count > 1 ? parts[1] : "") + "   ").prefix(3))

        var slot: UInt64?
        outer: for r in regions {
            guard let raw = BaseOS.readAt(fh, r.offset, r.length) else { continue }
            var i = 0
            while i + 32 <= raw.count {
                if raw[i] == 0 || raw[i] == 0xE5 { slot = r.offset + UInt64(i); break outer }
                i += 32
            }
        }
        guard let slot else { return false }
        let need = max(1, (data.count + clusterBytes - 1) / clusterBytes)
        guard let clusters = allocate(need) else { return false }
        link(clusters)
        write(data, to: clusters)

        let date: UInt32 = (UInt32(2026 - 1980) << 9) | (1 << 5) | 1
        var e = [UInt8](repeating: 0, count: 32)
        for (i, b) in (base + ext).utf8.enumerated() where i < 11 { e[i] = b }
        e[11] = attr
        e[16] = UInt8(date & 0xFF); e[17] = UInt8(date >> 8)        // created
        e[24] = UInt8(date & 0xFF); e[25] = UInt8(date >> 8)        // modified
        if f.fat32 { e[20] = UInt8((clusters[0] >> 16) & 0xFF); e[21] = UInt8((clusters[0] >> 24) & 0xFF) }
        e[26] = UInt8(clusters[0] & 0xFF); e[27] = UInt8((clusters[0] >> 8) & 0xFF)
        let size = UInt32(data.count)
        e[28] = UInt8(size & 0xFF); e[29] = UInt8((size >> 8) & 0xFF); e[30] = UInt8((size >> 16) & 0xFF); e[31] = UInt8(size >> 24)
        try? fh.seek(toOffset: slot)
        try? fh.write(contentsOf: Data(e))
        flushFAT()
        if f.fat32 { adjustFreeCount(by: -clusters.count) }
        return true
    }
}
