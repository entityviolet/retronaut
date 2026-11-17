import UIKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Materialises the bundled library into Documents without duplicating bytes:
/// APFS clone (copy-on-write) when available, hardlink next, copy last.
final class GameLibrary {
  static let shared = GameLibrary()

  func documents() -> URL {
    let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("games", isDirectory: true)
  }

  func bundled() -> URL? {
    let fm = FileManager.default
    var dir: URL? = Bundle.module.resourceURL?.appendingPathComponent("Games", isDirectory: true)
    if let d = dir, !fm.fileExists(atPath: d.path) { dir = nil }
    if dir == nil { dir = Res.url("Games") }
    guard let dir else { return nil }
    return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
  }

  /// Makes `gameId` available in Documents. Idempotent.
  @discardableResult
  func materialize(gameId: String) -> URL? {
    let dst = documents().appendingPathComponent(gameId, isDirectory: true)
    if FileManager.default.fileExists(atPath: dst.path) { return dst }   // already there (also covers imported games)
    guard let src = bundled()?.appendingPathComponent(gameId, isDirectory: true) else { return nil }
    try? FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
    cloneTree(from: src, to: dst)
    return dst
  }

  func gameData(gameId: String) -> URL? {
    guard let root = materialize(gameId: gameId) else { return nil }
    return root.appendingPathComponent("data", isDirectory: true)
  }

  private func cloneTree(from src: URL, to dst: URL) {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
    for item in items {
      let target = dst.appendingPathComponent(item.lastPathComponent)
      let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDir {
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        cloneTree(from: item, to: target)
      } else {
        place(from: item, to: target)
      }
    }
  }

  private func place(from src: URL, to dst: URL) {
    let fm = FileManager.default
    if fm.fileExists(atPath: dst.path) { return }
    do {
      try fm.copyItem(at: src, to: dst)
    } catch {
      NSLog("DosCore copy failed \(src.lastPathComponent): \(error.localizedDescription)")
    }
  }
}
