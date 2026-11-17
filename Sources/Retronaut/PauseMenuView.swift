import SwiftUI

final class PauseModel: ObservableObject {
    enum Mode { case save, load }

    let title: String
    @Published var slots: [SlotInfo]
    @Published var mode: Mode = .save
    @Published var message: String?
    @Published var showLobby = false
    var multiplayerAvailable = false          // the core offers a netpacket interface (DOS games)
    var lobbyGameTitle = ""

    var onResume: () -> Void = {}
    var onSave: (Int) -> String = { _ in "" }
    var onLoad: (Int) -> String? = { _ in nil }     // nil = loaded, menu closes
    var onReset: () -> Void = {}
    var onQuit: () -> Void = {}

    private let reload: () -> [SlotInfo]

    init(title: String, reload: @escaping () -> [SlotInfo]) {
        self.title = title
        self.reload = reload
        self.slots = reload()
    }

    func flash(_ text: String) {
        withAnimation(.snappy) { message = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard self?.message == text else { return }
            withAnimation(.snappy) { self?.message = nil }
        }
    }

    func tap(_ slot: SlotInfo) {
        switch mode {
        case .save:
            guard !slot.isAuto else { return }
            flash(onSave(slot.id))
            slots = reload()
        case .load:
            guard !slot.isEmpty else { return }
            if let err = onLoad(slot.id) { flash(err) }
        }
    }
}

struct PauseMenuView: View {
    @ObservedObject var model: PauseModel
    @ObservedObject private var net = NetSession.shared
    @State private var appeared = false
    @State private var confirmQuit = false
    @State private var confirmReset = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(appeared ? 0.6 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { model.onResume() }

                panel
                    .frame(maxWidth: min(geo.size.width - 32, 660))
                    .frame(maxHeight: geo.size.height - 32)
                    .scaleEffect(appeared ? 1 : 0.96)
                    .opacity(appeared ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { appeared = true } }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            if model.showLobby {
                LobbyView(gameTitle: model.lobbyGameTitle) { model.showLobby = false }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        if statesLocked {
                            lockedNotice
                        } else {
                            modeSwitch
                            slotGrid
                            autoRow
                        }
                        actions
                        Text("⌘P or the controller Menu button also opens and closes this menu.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.04, opacity: 0.55)))
        )
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
        .overlay(alignment: .top) { toast }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PAUSED").font(Theme.mono).foregroundStyle(Theme.accent)
                Text(model.title)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer()
            Button { model.onResume() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.card))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Resume")
        }
    }

    private var toast: some View {
        Group {
            if let m = model.message {
                Text(m)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Theme.accent))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .padding(.top, -14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: Save / load

    private var modeSwitch: some View {
        HStack(spacing: 4) {
            seg("Save", icon: "square.and.arrow.down", .save)
            seg("Load", icon: "arrow.uturn.backward.circle", .load)
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    private func seg(_ title: String, icon: String, _ m: PauseModel.Mode) -> some View {
        let on = model.mode == m
        return Button { withAnimation(.snappy) { model.mode = m } } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                Text(title.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(on ? Color.black : .white.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Capsule().fill(on ? Theme.accent : .clear))
        }
        .buttonStyle(.plain)
    }

    /// Save / load is off while a multiplayer lobby is open or connected (a networked game can't be rewound).
    private var statesLocked: Bool { net.live || net.role != .idle }

    private var lockedNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text("Save & load are off during multiplayer")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Leave the lobby to use save slots again.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    private var manualSlots: [SlotInfo] { model.slots.filter { !$0.isAuto } }

    private var slotGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 220), spacing: 12)], spacing: 14) {
            ForEach(manualSlots) { s in slotCard(s) }
        }
    }

    private func slotCard(_ s: SlotInfo) -> some View {
        let usable = model.mode == .save || !s.isEmpty
        return Button { model.tap(s) } label: {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail(s)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(dateText(s)).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(!usable)
        .opacity(usable ? 1 : 0.4)
    }

    private func thumbnail(_ s: SlotInfo) -> some View {
        ZStack {
            Color.black.opacity(0.4)
            if let t = s.thumb {
                Image(uiImage: t).resizable().interpolation(.none).scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: model.mode == .save ? "plus" : "tray")
                        .font(.system(size: 18, weight: .semibold))
                    Text(model.mode == .save ? "SAVE HERE" : "EMPTY")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.4))
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(s.isEmpty ? Color.white.opacity(0.18) : Theme.accent.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: s.isEmpty ? [5, 4] : []))
        )
    }

    private var autoRow: some View {
        let a = model.slots.first { $0.isAuto }
        let usable = model.mode == .load && !(a?.isEmpty ?? true)
        return Button { if let a { model.tap(a) } } label: {
            HStack(spacing: 12) {
                Group {
                    if let t = a?.thumb {
                        Image(uiImage: t).resizable().interpolation(.none).scaledToFill()
                    } else {
                        Color.black.opacity(0.4).overlay(Image(systemName: "clock.arrow.circlepath").foregroundStyle(.white.opacity(0.4)))
                    }
                }
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-save").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(a.map(dateText) ?? "—").font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Text(model.mode == .load ? "LOAD" : "AUTOMATIC")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(usable ? Theme.accent : .white.opacity(0.35))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .disabled(!usable)
        .opacity(a?.isEmpty ?? true ? 0.55 : 1)
    }

    private func dateText(_ s: SlotInfo) -> String {
        guard let d = s.date else { return "Empty" }
        return d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button { model.onResume() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                    Text("RESUME").font(.system(size: 16, weight: .heavy, design: .rounded)).tracking(3)
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Capsule().fill(Theme.accent))
                .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 4)
            }
            .buttonStyle(PressableStyle())

            if model.multiplayerAvailable {
                secondary(NetSession.shared.live ? "Multiplayer · connected" : "Multiplayer", icon: "person.2.fill", tint: Theme.accent) {
                    withAnimation(.snappy) { model.showLobby = true }
                }
            }

            HStack(spacing: 10) {
                secondary("Restart DOS", icon: "arrow.counterclockwise", tint: .white) { confirmReset = true }
                    .confirmationDialog("Restart DOS?", isPresented: $confirmReset, titleVisibility: .visible) {
                        Button("Restart", role: .destructive) { model.onReset() }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("The game restarts from the beginning. Saved slots are kept.") }

                secondary("Quit game", icon: "xmark", tint: Color(red: 1, green: 0.45, blue: 0.4)) { confirmQuit = true }
                    .confirmationDialog("Quit game?", isPresented: $confirmQuit, titleVisibility: .visible) {
                        Button("Quit game", role: .destructive) { model.onQuit() }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("Your progress is auto-saved so you can continue later.") }
            }
        }
    }

    private func secondary(_ title: String, icon: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                Text(title.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }
}
