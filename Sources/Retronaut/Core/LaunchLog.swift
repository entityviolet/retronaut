import Foundation
import SwiftUI

/// Plain-text activity log written to Documents/retronaut.log.
/// Visible in the Files app and inside Settings → "Launch log", so a pack that closes by itself can be diagnosed
/// without Xcode: the exact DOS script, the mounted media and every note the launcher produced are in there.
enum LaunchLog {
    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("retronaut.log")
    }

    static func write(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        existing += "[\(stamp)] \(text)\n"
        if existing.count > 200_000 { existing = String(existing.suffix(150_000)) }
        try? existing.write(to: url, atomically: true, encoding: .utf8)
    }

    static func read() -> String {
        let s = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return s.isEmpty ? "Nothing logged yet. Open a pack, then come back." : s
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

struct LaunchLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = LaunchLog.read()

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.black)
            .foregroundStyle(Color.green)
            .navigationTitle("Launch log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button("Clear", role: .destructive) { LaunchLog.clear(); text = LaunchLog.read() }
                        ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
    }
}
