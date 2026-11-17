import SwiftUI
import UIKit

// MARK: - Catalogue (store.json — plain static file, no API)

/// One game in store.json. Everything except id/title/pack is optional, so older catalogues keep working.
struct StorePack: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let year: Int
    let genre: String?
    let developer: String?
    let system: String?
    let blurb: String?
    let size_mb: Int?
    let cover: String?
    let pack: String
    // Optional extras for the store UI.
    let tagline: String?        // one-liner used on featured banners
    let details: String?        // long description ("description" in the JSON)
    let featured: Bool?         // alternative to the top-level "featured" id list
    let added: String?          // "yyyy-MM-dd" — shows a NEW badge for 30 days
    let players: String?        // e.g. "1", "1–2"
    let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, year, genre, developer, system, blurb, size_mb, cover, pack
        case tagline, details = "description", featured, added, players, tags
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        pack = try c.decode(String.self, forKey: .pack)
        id = (try? c.decode(String.self, forKey: .id)) ?? title.storeKey
        year = (try? c.decode(Int.self, forKey: .year)) ?? 0
        genre = try? c.decode(String.self, forKey: .genre)
        developer = try? c.decode(String.self, forKey: .developer)
        system = try? c.decode(String.self, forKey: .system)
        blurb = try? c.decode(String.self, forKey: .blurb)
        size_mb = try? c.decode(Int.self, forKey: .size_mb)
        cover = try? c.decode(String.self, forKey: .cover)
        tagline = try? c.decode(String.self, forKey: .tagline)
        details = try? c.decode(String.self, forKey: .details)
        featured = try? c.decode(Bool.self, forKey: .featured)
        added = try? c.decode(String.self, forKey: .added)
        players = try? c.decode(String.self, forKey: .players)
        tags = try? c.decode([String].self, forKey: .tags)
    }

    static func == (a: StorePack, b: StorePack) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var systemText: String { (system?.isEmpty ?? true) ? "DOS" : system! }
    var genreText: String { genre ?? "" }
    var yearText: String { year > 0 ? String(year) : "—" }
    var story: String { (details?.isEmpty == false ? details : blurb) ?? "" }

    var sizeText: String {
        let mb = size_mb ?? 0
        if mb <= 0 { return "< 1 MB" }
        if mb >= 1000 { return String(format: "%.1f GB", Double(mb) / 1024) }
        return "\(mb) MB"
    }

    func isNew(reference: Date = Date()) -> Bool {
        guard let a = added else { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: a) else { return false }
        let days = reference.timeIntervalSince(d) / 86_400
        return days >= -1 && days <= 30
    }
}

struct StoreManifest: Decodable {
    let name: String?
    let updated: String?
    let featured: [String]?
    let packs: [StorePack]
}

extension String {
    /// Comparison key for "is this store pack already on the shelf?".
    var storeKey: String { lowercased().filter { $0.isLetter || $0.isNumber } }
}

// MARK: - Store link (editable, saved in UserDefaults "storeURL")

enum StoreLink {
    static let key = "storeURL"
    private static let historyKey = "storeURLHistory"

    /// "192.168.1.5:8087" -> http://192.168.1.5:8087/ ; a pasted ".../store.json" is accepted too.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        if s.lowercased().hasSuffix("store.json") { s = String(s.dropLast("store.json".count)) }
        if !s.hasSuffix("/") { s += "/" }
        guard let u = URL(string: s), u.host != nil else { return nil }
        return u
    }

    static var history: [String] {
        UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    static func remember(_ url: String) {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var h = history.filter { $0 != t }
        h.insert(t, at: 0)
        UserDefaults.standard.set(Array(h.prefix(6)), forKey: historyKey)
    }

    static func forget(_ url: String) {
        UserDefaults.standard.set(history.filter { $0 != url }, forKey: historyKey)
    }

    /// Fetches store.json without touching the main catalogue — used by "Test link".
    static func probe(_ url: URL) async -> Result<(name: String, count: Int), Error> {
        do {
            var req = URLRequest(url: url.appendingPathComponent("store.json"))
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 12
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw StoreModel.StoreError.bad("store.json answered \(code).") }
            let m = try JSONDecoder().decode(StoreManifest.self, from: data)
            return .success((m.name ?? "Store", m.packs.count))
        } catch {
            return .failure(error)
        }
    }
}

/// Remembers which store pack became which library game, so INSTALLED stays right even if the pack's own
/// meta.json renames the title. Title matching still applies on top of this.
enum StoreInstalls {
    private static let key = "storeInstalledIDs"
    static func map() -> [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
    static func set(pack: String, game: String) {
        var m = map(); m[pack] = game
        UserDefaults.standard.set(m, forKey: key)
    }
    static func isInstalled(_ p: StorePack, games: [Game]) -> Bool {
        if let gid = map()[p.id], games.contains(where: { $0.id == gid }) { return true }
        let key = p.title.storeKey
        return games.contains { $0.title.storeKey == key }
    }
}

// MARK: - Model

@MainActor
final class StoreModel: ObservableObject {
    enum Phase { case idle, downloading, unpacking }

    @Published private(set) var packs: [StorePack] = []
    @Published private(set) var featured: [StorePack] = []
    @Published private(set) var storeName = ""
    @Published private(set) var updated = ""
    @Published var loading = false
    @Published var loadFailed = false
    @Published var installing: String? = nil
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var toast: String? = nil
    @Published var alert: String? = nil

    private(set) var base: URL?
    private var installTask: Task<Void, Never>?
    private var downloader: StoreDownloader?

    var isBusy: Bool { installing != nil }

    func load(baseURL: URL) async {
        base = baseURL
        loading = true
        loadFailed = false
        defer { loading = false }
        do {
            var req = URLRequest(url: baseURL.appendingPathComponent("store.json"))
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw StoreError.bad("store.json answered \(code).") }
            let m = try JSONDecoder().decode(StoreManifest.self, from: data)
            let all = m.packs.sorted { ($0.year, $0.title) < ($1.year, $1.title) }
            packs = all
            storeName = m.name ?? "Store"
            updated = m.updated ?? ""
            featured = Self.pickFeatured(all, ids: m.featured ?? [])
            StoreLink.remember(baseURL.absoluteString)
        } catch {
            packs = []
            featured = []
            loadFailed = true
            alert = "Couldn't load the store\n\(baseURL.absoluteString)\n\n\(error.localizedDescription)"
        }
    }

    /// Explicit picks first (top-level "featured" id list, then packs flagged "featured": true).
    /// With neither, the richest entries (cover + long blurb) are used so the shelf still opens with a hero.
    private static func pickFeatured(_ all: [StorePack], ids: [String]) -> [StorePack] {
        var out: [StorePack] = []
        for id in ids { if let p = all.first(where: { $0.id == id }), !out.contains(p) { out.append(p) } }
        for p in all where p.featured == true && !out.contains(p) { out.append(p) }
        if out.isEmpty {
            out = all.filter { ($0.cover?.isEmpty == false) && ($0.blurb?.count ?? 0) > 60 }
                .sorted { ($0.blurb?.count ?? 0) > ($1.blurb?.count ?? 0) }
                .prefix(4).map { $0 }
        }
        return out.filter { $0.cover?.isEmpty == false }
    }

    func coverURL(_ p: StorePack) -> URL? {
        guard let c = p.cover, !c.isEmpty, let b = base else { return nil }
        return b.appendingPathComponent(c)
    }

    func isInstalling(_ p: StorePack) -> Bool { installing == p.id }

    // MARK: Install

    func install(_ p: StorePack) {
        guard installing == nil, let b = base else { return }
        installing = p.id
        phase = .downloading
        progress = 0
        installTask = Task { [weak self] in
            await self?.run(p, base: b)
        }
    }

    func cancel() {
        guard phase == .downloading else { return }
        downloader?.cancel()
    }

    private func setDownload(_ f: Double) {
        guard phase == .downloading else { return }
        let v = min(0.85, max(0, f) * 0.85)
        if v - progress >= 0.004 { progress = v }
    }

    private func run(_ p: StorePack, base b: URL) async {
        let remote = b.appendingPathComponent(p.pack)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(p.id).zip")
        var creep: Task<Void, Never>?
        defer {
            creep?.cancel()
            try? FileManager.default.removeItem(at: tmp)
            installing = nil
            phase = .idle
        }
        do {
            try? FileManager.default.removeItem(at: tmp)
            let hint = Int64(max(1, p.size_mb ?? 1)) * 1_048_576
            let dl = StoreDownloader(dest: tmp, sizeHint: hint) { [weak self] f in
                Task { @MainActor in self?.setDownload(f) }
            }
            downloader = dl
            let file = try await dl.start(remote)
            downloader = nil

            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { throw StoreError.bad("The downloaded pack is empty.") }

            // Unpacking has no real progress signal, so the bar eases towards 98 % and snaps to 100 % when done.
            phase = .unpacking
            progress = max(progress, 0.85)
            creep = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await MainActor.run {
                        guard let s = self, s.phase == .unpacking else { return }
                        s.progress += (0.98 - s.progress) * 0.05
                    }
                }
            }

            let id = ImportedStore.newId(for: p.title)
            // Unpacking a 300–600 MB pack must not run on the main actor.
            let outcome: (PackImporter.Result?, String?) = await Task.detached(priority: .userInitiated) {
                ImportedStore.clearFiles(id)
                do { return (try PackImporter.importPack(file, into: id), nil) }
                catch { return (nil, error.localizedDescription) }
            }.value

            if let err = outcome.1 { throw StoreError.bad(err) }
            guard let r = outcome.0 else { throw StoreError.bad("The pack couldn't be unpacked.") }

            let meta = ImportedMeta(id: id,
                                    title: r.title.isEmpty ? p.title : r.title,
                                    year: r.year == 0 ? p.year : r.year,
                                    genre: r.genre.isEmpty ? (p.genre ?? "") : r.genre,
                                    developer: r.developer.isEmpty ? (p.developer ?? "") : r.developer,
                                    blurb: r.blurb.isEmpty ? (p.blurb ?? "") : r.blurb,
                                    engine: r.engine)
            try ImportedStore.save(meta: meta, config: r.config)
            if let c = r.cover { ImportedStore.saveCover(c, id: id) }
            StoreInstalls.set(pack: p.id, game: id)
            Library.shared.reload()

            creep?.cancel()
            progress = 1
            try? await Task.sleep(nanoseconds: 450_000_000)
            toast = "\(meta.title) installed"
        } catch {
            downloader = nil
            if (error as? URLError)?.code == .cancelled || error is CancellationError {
                toast = "Download cancelled"
            } else {
                alert = "\(p.title)\n\n\(error.localizedDescription)"
            }
        }
    }

    enum StoreError: LocalizedError {
        case bad(String)
        var errorDescription: String? { switch self { case .bad(let s): return s } }
    }
}

// MARK: - Download with real progress

final class StoreDownloader: NSObject, URLSessionDownloadDelegate {
    private let dest: URL
    private let sizeHint: Int64
    private let onProgress: (Double) -> Void
    private var cont: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let lock = NSLock()

    init(dest: URL, sizeHint: Int64, onProgress: @escaping (Double) -> Void) {
        self.dest = dest
        self.sizeHint = sizeHint
        self.onProgress = onProgress
    }

    func start(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                lock.lock(); cont = c; lock.unlock()
                let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                session = s
                let t = s.downloadTask(with: url)
                task = t
                t.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() { task?.cancel() }

    private func finish(_ r: Result<URL, Error>) {
        lock.lock()
        let c = cont; cont = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        c?.resume(with: r)
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData bytes: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        let total = expected > 0 ? expected : sizeHint
        onProgress(min(0.99, Double(written) / Double(max(1, total))))
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (t.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            finish(.failure(StoreModel.StoreError.bad("The server answered \(code) for \(t.originalRequest?.url?.lastPathComponent ?? "the pack").")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            onProgress(1)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - Poster artwork

/// Poster assets are "stickers": a grey backdrop, a thin outline, a white band and only then the coloured frame
/// and the art. Banners must not show any of that, so this finds where the coloured frame begins and crops there.
/// Sides that don't look like the template (no coloured frame, over-large trims) fall back to the template inset.
enum StickerCrop {
    static func crop(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let scale = min(1, 1000 / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard w > 40, h > 40 else { return image }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return image }

        func saturated(_ x: Int, _ y: Int) -> Bool {
            let o = (y * w + x) * 4
            let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2]), a = Int(px[o + 3])
            return a >= 200 && max(r, max(g, b)) - min(r, min(g, b)) >= 70
        }
        let x0 = w / 4, x1 = w * 3 / 4, y0 = h / 4, y1 = h * 3 / 4
        func rowIsBorder(_ y: Int) -> Bool {
            var n = 0
            for x in x0..<x1 where saturated(x, y) { n += 1 }
            return Double(n) < Double(x1 - x0) * 0.45
        }
        func colIsBorder(_ x: Int) -> Bool {
            var n = 0
            for y in y0..<y1 where saturated(x, y) { n += 1 }
            return Double(n) < Double(y1 - y0) * 0.45
        }

        // Template insets (fractions of the picture) measured on the sticker artwork.
        let defY = 0.060, defX = 0.024
        let capY = Int(Double(h) * 0.075), capX = Int(Double(w) * 0.034)
        var top = 0; while top < capY && rowIsBorder(top) { top += 1 }
        var bottom = 0; while bottom < capY && rowIsBorder(h - 1 - bottom) { bottom += 1 }
        var left = 0; while left < capX && colIsBorder(left) { left += 1 }
        var right = 0; while right < capX && colIsBorder(w - 1 - right) { right += 1 }
        if top >= capY { top = Int(Double(h) * defY) }
        if bottom >= capY { bottom = Int(Double(h) * defY) }
        if left >= capX { left = Int(Double(w) * defX) }
        if right >= capX { right = Int(Double(w) * defX) }
        // Anti-aliased pixel next to the band.
        let ix = max(1, Int(Double(w) * 0.004)), iy = max(1, Int(Double(h) * 0.004))
        top += iy; bottom += iy; left += ix; right += ix

        let sx = CGFloat(cg.width) / CGFloat(w), sy = CGFloat(cg.height) / CGFloat(h)
        let rect = CGRect(x: CGFloat(left) * sx, y: CGFloat(top) * sy,
                          width: CGFloat(w - left - right) * sx,
                          height: CGFloat(h - top - bottom) * sy).integral
        guard rect.width > 8, rect.height > 8, let out = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// Downloads and caches posters (memory + URLCache on disk). `trimmed` = sticker borders removed, for banners.
final class StoreImages {
    static let shared = StoreImages()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 200 << 20)
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    private func key(_ url: URL, _ trimmed: Bool) -> NSString { ((trimmed ? "t|" : "r|") + url.absoluteString) as NSString }

    func cached(_ url: URL?, trimmed: Bool) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: key(url, trimmed))
    }

    func load(_ url: URL, trimmed: Bool) async -> UIImage? {
        if let hit = cache.object(forKey: key(url, trimmed)) { return hit }
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        let out = trimmed ? StickerCrop.crop(img) : img
        cache.setObject(out, forKey: key(url, trimmed))
        return out
    }
}

/// Async poster view. `content` gets nil while loading / on failure.
struct RemoteImage<Content: View>: View {
    let url: URL?
    let trimmed: Bool
    let content: (UIImage?) -> Content
    @State private var image: UIImage?

    init(url: URL?, trimmed: Bool = false, @ViewBuilder content: @escaping (UIImage?) -> Content) {
        self.url = url
        self.trimmed = trimmed
        self.content = content
        _image = State(initialValue: StoreImages.shared.cached(url, trimmed: trimmed))
    }

    var body: some View {
        content(image)
            .task(id: url) {
                guard let url else { image = nil; return }
                if let hit = StoreImages.shared.cached(url, trimmed: trimmed) { image = hit; return }
                image = await StoreImages.shared.load(url, trimmed: trimmed)
            }
    }
}
