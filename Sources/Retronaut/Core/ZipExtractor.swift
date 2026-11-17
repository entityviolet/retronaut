import Foundation
import Compression

/// Minimal ZIP reader (stored + deflate) built on the system Compression framework, so imported
/// games can be added as a .zip. Streams entry by entry, so big games don't need big memory.
/// Not supported: encrypted archives, ZIP64 (> 4 GB), multi-disk archives.
enum ZipExtractor {
    struct ZipError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Entry {
        let name: String
        let method: UInt16
        let compSize: UInt64
        let localOffset: UInt64
        let isDir: Bool
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8
    }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16
    }

    /// Unpacks `zip` into `dest` (created if needed). When the archive has a single top-level
    /// folder and `stripSingleRoot` is set, that folder's contents go straight into `dest`.
    /// Returns the number of files written.
    @discardableResult
    static func extract(_ zip: URL, to dest: URL, stripSingleRoot: Bool) throws -> Int {
        let fm = FileManager.default
        let fh = try FileHandle(forReadingFrom: zip)
        defer { try? fh.close() }

        // 1. End of central directory record.
        let fileSize = try fh.seekToEnd()
        guard fileSize >= 22 else { throw ZipError(message: "That doesn't look like a zip file.") }
        let tailLen = Int(min(fileSize, 66_000))
        try fh.seek(toOffset: fileSize - UInt64(tailLen))
        guard let tail = try fh.read(upToCount: tailLen), tail.count == tailLen else {
            throw ZipError(message: "Couldn't read the zip file.")
        }
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if u32(tail, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError(message: "That doesn't look like a zip file.") }
        let total = Int(u16(tail, eocd + 10))
        let cdSize = u32(tail, eocd + 12)
        let cdOffset = u32(tail, eocd + 16)
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw ZipError(message: "Zip64 archives (over 4 GB) aren't supported. Unzip it in Files and add the folder.")
        }

        // 2. Central directory.
        try fh.seek(toOffset: UInt64(cdOffset))
        guard let cd = try fh.read(upToCount: Int(cdSize)), cd.count == Int(cdSize) else {
            throw ZipError(message: "The zip file is damaged.")
        }
        var entries: [Entry] = []
        var p = 0
        while p + 46 <= cd.count, u32(cd, p) == 0x0201_4b50 {
            let flags = u16(cd, p + 8)
            let method = u16(cd, p + 10)
            let compSize = u32(cd, p + 20)
            let nameLen = Int(u16(cd, p + 28))
            let extraLen = Int(u16(cd, p + 30))
            let commentLen = Int(u16(cd, p + 32))
            let offset = u32(cd, p + 42)
            guard p + 46 + nameLen <= cd.count else { break }
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            if flags & 1 != 0 { throw ZipError(message: "Password-protected zips aren't supported.") }
            entries.append(Entry(name: name.replacingOccurrences(of: "\\", with: "/"),
                                 method: method, compSize: UInt64(compSize),
                                 localOffset: UInt64(offset), isDir: name.hasSuffix("/")))
            p += 46 + nameLen + extraLen + commentLen
        }
        guard !entries.isEmpty else { throw ZipError(message: "The zip file is empty.") }

        // 3. Clean names (no path escapes, no macOS junk) and optionally drop a single root folder.
        func parts(_ e: Entry) -> [String]? {
            let comps = e.name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if comps.isEmpty || comps.contains("..") || comps.contains(".") { return nil }
            if comps[0] == "__MACOSX" || comps.last == ".DS_Store" { return nil }
            return comps
        }
        let usable = entries.compactMap { e -> (Entry, [String])? in
            guard let c = parts(e) else { return nil }
            return (e, c)
        }
        var strip = false
        if stripSingleRoot {
            let roots = Set(usable.map { $0.1[0] })
            strip = roots.count == 1 && usable.allSatisfy { $0.0.isDir || $0.1.count >= 2 }
        }

        // 4. Extract.
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var written = 0
        for (e, comps) in usable {
            let rel = strip ? Array(comps.dropFirst()) : comps
            if rel.isEmpty { continue }
            var target = dest
            for c in rel { target.appendPathComponent(c) }
            if e.isDir {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            guard fm.createFile(atPath: target.path, contents: nil) else {
                throw ZipError(message: "Couldn't create \(rel.joined(separator: "/")).")
            }
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }

            // Local header gives the real start of the data.
            try fh.seek(toOffset: e.localOffset)
            guard let lh = try fh.read(upToCount: 30), lh.count == 30, u32(lh, 0) == 0x0403_4b50 else {
                throw ZipError(message: "The zip file is damaged.")
            }
            let dataStart = e.localOffset + 30 + UInt64(u16(lh, 26)) + UInt64(u16(lh, 28))
            try fh.seek(toOffset: dataStart)

            switch e.method {
            case 0: try copy(from: fh, count: e.compSize, to: out)
            case 8: try inflate(from: fh, compressedSize: e.compSize, to: out)
            default: throw ZipError(message: "Unsupported compression in \(rel.joined(separator: "/")).")
            }
            written += 1
        }
        return written
    }

    private static func copy(from fh: FileHandle, count: UInt64, to out: FileHandle) throws {
        var left = count
        while left > 0 {
            guard let d = try fh.read(upToCount: Int(min(left, 256 * 1024))), !d.isEmpty else {
                throw ZipError(message: "The zip file is damaged.")
            }
            try out.write(contentsOf: d)
            left -= UInt64(d.count)
        }
    }

    private static func inflate(from fh: FileHandle, compressedSize: UInt64, to out: FileHandle) throws {
        if compressedSize == 0 { return }
        let dstSize = 128 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }

        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError(message: "Couldn't start decompression.")
        }
        defer { compression_stream_destroy(&stream) }

        var remaining = compressedSize
        var finished = false
        var stalls = 0

        while !finished {
            var chunk = Data()
            if remaining > 0 {
                guard let d = try fh.read(upToCount: Int(min(remaining, 128 * 1024))), !d.isEmpty else {
                    throw ZipError(message: "The zip file is damaged.")
                }
                chunk = d
                remaining -= UInt64(d.count)
            }
            let finalize = remaining == 0
            let flags: Int32 = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
                stream.src_size = chunk.count
                while true {
                    stream.dst_ptr = dst
                    stream.dst_size = dstSize
                    let status = compression_stream_process(&stream, flags)
                    let produced = dstSize - stream.dst_size
                    if produced > 0 {
                        try out.write(contentsOf: Data(bytes: dst, count: produced))
                        stalls = 0
                    }
                    if status == COMPRESSION_STATUS_END { finished = true; return }
                    if status == COMPRESSION_STATUS_ERROR { throw ZipError(message: "The zip file is damaged.") }
                    if stream.src_size == 0 && produced < dstSize && !finalize { return }   // wants more input
                    if produced == 0 {
                        stalls += 1
                        if stalls > 3 { throw ZipError(message: "The zip file is damaged.") }
                    }
                }
            }
        }
    }
}
