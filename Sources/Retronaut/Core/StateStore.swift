import UIKit

/// One save slot as shown in the pause menu. `id` 0 is the automatic save.
struct SlotInfo: Identifiable {
    let id: Int
    let date: Date?
    let thumb: UIImage?
    var isEmpty: Bool { date == nil }
    var isAuto: Bool { id == 0 }
    var name: String { isAuto ? "Auto-save" : "Slot \(id)" }
}

/// Save-state files on disk: Documents/states/<game>/{auto,slot1…slot4}.state + .jpg thumbnail.
enum StateStore {
    static let slotCount = 4

    static func dir(_ gameId: String) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("states", isDirectory: true)
            .appendingPathComponent(gameId.isEmpty ? "game" : gameId, isDirectory: true)
        return base
    }

    /// Call before writing; reads never create folders.
    static func ensureDir(_ gameId: String) {
        try? FileManager.default.createDirectory(at: dir(gameId), withIntermediateDirectories: true)
    }

    private static func name(_ slot: Int) -> String { slot == 0 ? "auto" : "slot\(slot)" }
    static func stateURL(_ g: String, _ slot: Int) -> URL { dir(g).appendingPathComponent(name(slot) + ".state") }
    static func thumbURL(_ g: String, _ slot: Int) -> URL { dir(g).appendingPathComponent(name(slot) + ".jpg") }

    /// Older builds had a single "quick.state"; keep it as slot 1.
    static func migrate(_ g: String) {
        let fm = FileManager.default
        let old = dir(g).appendingPathComponent("quick.state")
        let new = stateURL(g, 1)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
    }

    static func date(_ g: String, _ slot: Int) -> Date? {
        let url = stateURL(g, slot)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? Int ?? 0) > 0 else { return nil }
        return attrs[.modificationDate] as? Date
    }

    static func info(_ g: String) -> [SlotInfo] {
        migrate(g)
        return (0...slotCount).map { s in
            let d = date(g, s)
            let thumb = d == nil ? nil : UIImage(contentsOfFile: thumbURL(g, s).path)
            return SlotInfo(id: s, date: d, thumb: thumb)
        }
    }

    static func hasAuto(_ g: String) -> Bool { date(g, 0) != nil }
    static func autoDate(_ g: String) -> Date? { date(g, 0) }
    static func savedCount(_ g: String) -> Int { migrate(g); return (1...slotCount).filter { date(g, $0) != nil }.count }
}
