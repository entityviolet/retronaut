import SwiftUI

/// Multiplayer lobby, shown inside the pause menu (so it needs no modal presentation over the game).
/// Everyone starts the same game first; then one player hosts and the others pick the lobby from the list.
struct LobbyView: View {
    @ObservedObject private var net = NetSession.shared
    let gameTitle: String
    let onBack: () -> Void

    @State private var address = ""

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if net.role == .idle { idleContent } else { sessionContent }
                if !net.status.isEmpty {
                    Text(net.status)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Needs a game with network support (IPX, modem or null-modem). Everyone must run the same game and the same version. DOS games only; Windows packs have no network adapter.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .onAppear { if net.role == .idle { net.startBrowsing() } }
        .onDisappear { net.stopBrowsing() }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .center) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    Text("BACK").font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("MULTIPLAYER").font(Theme.mono).foregroundStyle(Theme.accent)
                Text(gameTitle.isEmpty ? "DOS game" : gameTitle)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var idleContent: some View {
        card("YOUR NAME") {
            TextField("Player", text: $net.playerName)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
        }

        bigButton("HOST A LOBBY", icon: "antenna.radiowaves.left.and.right", primary: true) { net.host() }

        card("LOBBIES NEARBY") {
            if net.lobbies.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Looking for lobbies on this network…")
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                }
            } else {
                ForEach(net.lobbies) { l in
                    let same = sameGame(l.title)
                    Button { net.join(l) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.host.isEmpty ? "Lobby" : l.host)
                                    .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                                Text(same ? l.title : "\(l.title): different game")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(same ? Theme.accent : .white.opacity(0.4))
                            }
                            Spacer()
                            Text("JOIN").font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .foregroundStyle(same ? Color.black : .white.opacity(0.4))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(same ? Theme.accent : Theme.card))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!same)
                }
            }
        }

        card("JOIN BY ADDRESS") {
            Text("For a VPN or when the list stays empty: type the host's address (shown in its lobby).")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 8) {
                TextField("192.168.1.20", text: $address)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
                Button { net.join(address: address) } label: {
                    Text("JOIN").font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    @ViewBuilder private var sessionContent: some View {
        card(net.role == .host ? "YOU ARE HOSTING" : "YOU ARE IN A LOBBY") {
            HStack(spacing: 8) {
                Circle().fill(net.live ? Theme.accent : Theme.amber).frame(width: 8, height: 8)
                Text(net.live ? "Connected. Start the game's multiplayer (IPX / modem) menu." : "Connecting…")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
            ForEach(net.players) { p in
                HStack {
                    Image(systemName: p.id == 0 ? "crown.fill" : "person.fill")
                        .font(.system(size: 11)).foregroundStyle(p.id == 0 ? Theme.amber : Theme.accent)
                    Text(p.name + (p.id == net.myId ? "  (you)" : ""))
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    Spacer()
                    Text("#\(p.id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
                }
            }
            if net.role == .host, !net.addresses.isEmpty {
                Text("Address for “Join by address”: " + net.addresses.joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                    .textSelection(.enabled)
            }
        }
        Text("Resume the game, then pick the network option in the game itself. Save states are off while connected.")
            .font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
        bigButton(net.role == .host ? "CLOSE LOBBY" : "LEAVE LOBBY", icon: "xmark", primary: false) { net.leave() }
    }

    // MARK: Helpers

    private func sameGame(_ hostTitle: String) -> Bool {
        let mine = NetSession.key(gameTitle), theirs = NetSession.key(hostTitle)
        return !theirs.isEmpty && (mine == theirs || mine.hasPrefix(theirs))     // Bonjour truncates long titles
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.mono).foregroundStyle(.white.opacity(0.5))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    private func bigButton(_ title: String, icon: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
                Text(title).font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(1)
            }
            .foregroundStyle(primary ? Color.black : .white.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(primary ? Theme.accent : Theme.card))
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: primary ? 0 : 1))
        }
        .buttonStyle(PressableStyle())
    }
}
