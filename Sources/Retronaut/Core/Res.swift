import Foundation

/// Resolves bundled resources without assuming the exact bundle layout.
/// Finds the directory that actually contains `Games/` and resolves from there.
enum Res {
    static let root: URL = {
        let bundle = Bundle.module.bundleURL
        var candidates: [URL] = [
            bundle,
            bundle.appendingPathComponent("Resources"),
            bundle.deletingLastPathComponent(),
            bundle.deletingLastPathComponent().appendingPathComponent("Resources"),
        ]
        #if DEBUG
        candidates.append(bundle.appendingPathComponent("Retronaut_Retronaut.bundle/Resources"))
        #endif
        let fm = FileManager.default
        for c in candidates {
            if fm.fileExists(atPath: c.appendingPathComponent("Games").path) { return c }
            if fm.fileExists(atPath: c.appendingPathComponent("Cores").path) { return c }
            if fm.fileExists(atPath: c.appendingPathComponent("games.json").path) { return c }
        }
        return bundle
    }()

    static var hasGames: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Games").path)
    }

    static func url(_ relative: String) -> URL? {
        let u = root.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func path(_ relative: String) -> String? { url(relative)?.path }
}
