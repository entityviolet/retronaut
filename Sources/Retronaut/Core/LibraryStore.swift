import SwiftUI

struct GameStats: Codable {
    var lastPlayed: Date?
    var seconds: Double = 0
    var plays: Int = 0
}

/// Favorites and play statistics, persisted in UserDefaults.
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var stats: [String: GameStats] = [:]
    @Published private(set) var favorites: Set<String> = []

    private let statsKey = "library.stats"
    private let favKey = "library.favorites"

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: statsKey),
           let s = try? JSONDecoder().decode([String: GameStats].self, from: data) { stats = s }
        favorites = Set(d.stringArray(forKey: favKey) ?? [])
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(stats) { d.set(data, forKey: statsKey) }
        d.set(Array(favorites), forKey: favKey)
    }

    func stat(_ id: String) -> GameStats { stats[id] ?? GameStats() }
    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        save()
    }

    /// Forgets a removed game's favourite flag and play statistics.
    func forget(_ id: String) {
        stats[id] = nil
        favorites.remove(id)
        save()
    }

    /// A session started.
    func began(_ id: String) {
        var s = stat(id)
        s.lastPlayed = Date()
        s.plays += 1
        stats[id] = s
        save()
    }

    /// A session ended after `seconds`.
    func ended(_ id: String, seconds: Double) {
        var s = stat(id)
        s.lastPlayed = Date()
        s.seconds += max(0, seconds)
        stats[id] = s
        save()
    }

    // MARK: Formatting

    static func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return seconds >= 10 ? "<1m" : "0m" }
        if m < 60 { return "\(m)m" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }

    static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
