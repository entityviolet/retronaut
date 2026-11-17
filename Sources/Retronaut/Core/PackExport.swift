import Foundation

/// Exports an imported pack back into the zip the importer understands: `game.json` plus every file of the pack's data
/// folder (disk images, disc images, saves) at the archive root. Stored (no compression) so a 400 MB pack exports fast
/// and never needs extra memory.
enum PackExport {

    private struct CRC {
        static let table: [UInt32] = (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            return c
        }
        static func of(_ data: Data) -> UInt32 {
            var c: UInt32 = 0xFFFFFFFF
            for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            return c ^ 0xFFFFFFFF
        }
        static func of(file url: URL) -> (UInt32, UInt64) {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return (0, 0) }
            defer { try? fh.close() }
            var c: UInt32 = 0xFFFFFFFF
            var total: UInt64 = 0
            while true {
                let chunk = (try? fh.read(upToCount: 1 << 20)) ?? nil
                guard let d = chunk, !d.isEmpty else { break }
                total += UInt64(d.count)
                for b in d { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
            return (c ^ 0xFFFFFFFF, total)
        }
    }

    /// Builds `<Documents>/exports/<name>.zip` for the pack and returns its URL.
    static func export(_ id: String, title: String) throws -> URL {
        let fm = FileManager.default
        let data = ImportedStore.dataDir(id)
        guard fm.fileExists(atPath: data.path) else { throw BaseOS.OSError(message: "This pack has no files to export.") }

        let outDir = ImportedStore.dir(id).deletingLastPathComponent().appendingPathComponent("exports", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let out = outDir.appendingPathComponent("\(safe).zip")
        try? fm.removeItem(at: out)
        guard fm.createFile(atPath: out.path, contents: nil),
              let fh = try? FileHandle(forWritingTo: out) else {
            throw BaseOS.OSError(message: "Couldn't create the export file.")
        }
        defer { try? fh.close() }

        var central = Data()
        var offset: UInt64 = 0
        var entries = 0

        func write(_ d: Data) { fh.write(d); offset += UInt64(d.count) }

        func add(name: String, file: URL) throws {
            let (crc, size) = CRC.of(file: file)
            guard let fhIn = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? fhIn.close() }
            let nameData = Data(name.utf8)
            let localOffset = offset

            var local = Data()
            local.append(le32(0x04034b50))              // local file header
            local.append(le16(10))                      // version needed
            local.append(le16(0))                       // flags
            local.append(le16(0))                       // stored
            local.append(le16(0))                       // time
            local.append(le16(0))                       // date
            local.append(le32(crc))
            local.append(le32(UInt32(size)))
            local.append(le32(UInt32(size)))
            local.append(le16(UInt16(nameData.count)))
            local.append(le16(0))
            local.append(nameData)
            write(local)

            while true {
                let chunk = (try? fhIn.read(upToCount: 1 << 22)) ?? nil
                guard let c = chunk, !c.isEmpty else { break }
                write(c)
            }

            var cent = Data()
            cent.append(le32(0x02014b50))               // central directory header
            cent.append(le16(10))
            cent.append(le16(10))
            cent.append(le16(0))
            cent.append(le16(0))
            cent.append(le16(0))
            cent.append(le16(0))
            cent.append(le32(crc))
            cent.append(le32(UInt32(size)))
            cent.append(le32(UInt32(size)))
            cent.append(le16(UInt16(nameData.count)))
            cent.append(le16(0))
            cent.append(le16(0))
            cent.append(le16(0))
            cent.append(le16(0))
            cent.append(le32(0))
            cent.append(le32(UInt32(localOffset)))
            cent.append(nameData)
            central.append(cent)
            entries += 1
        }

        // game.json first, then the poster, then every file of the pack folder.
        let cfg = ImportedStore.configURL(id)
        if fm.fileExists(atPath: cfg.path) { try add(name: "game.json", file: cfg) }
        let ownCover = ImportedStore.dir(id).appendingPathComponent("cover.jpg")
        if fm.fileExists(atPath: ownCover.path), !fm.fileExists(atPath: data.appendingPathComponent("cover.jpg").path) {
            try add(name: "cover.jpg", file: ownCover)
        }
        if let en = fm.enumerator(at: data, includingPropertiesForKeys: [.isRegularFileKey]) {
            let basePath = data.resolvingSymlinksInPath().path
            for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                // Relative to the pack folder, without any leading slash: iOS reports /private/var/... while the stored URL
                // may be /var/..., so a naive prefix strip produced names like "/privategame.img" and the re-imported pack
                // lost its disc.
                let full = u.resolvingSymlinksInPath().path
                var rel = full.hasPrefix(basePath) ? String(full.dropFirst(basePath.count)) : u.lastPathComponent
                rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if rel.isEmpty || rel == "game.json" { continue }
                try add(name: rel, file: u)
            }
        }

        let cdOffset = offset
        write(central)
        var end = Data()
        end.append(le32(0x06054b50))
        end.append(le16(0))
        end.append(le16(0))
        end.append(le16(UInt16(entries)))
        end.append(le16(UInt16(entries)))
        end.append(le32(UInt32(central.count)))
        end.append(le32(UInt32(cdOffset)))
        end.append(le16(0))
        write(end)
        return out
    }

    private static func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
    private static func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
}
