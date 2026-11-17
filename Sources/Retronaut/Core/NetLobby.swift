import Foundation
import Network
import UIKit

// MARK: - libretro "netpacket" ABI (RETRO_ENVIRONMENT_SET_NETPACKET_INTERFACE = 78)
//
// A core that supports multiplayer (DOSBox Pure: IPX and the COM1 modem / null-modem) hands the frontend this table. The
// frontend provides the transport: it calls `start` once the session exists, `receive` for every packet that arrives,
// `poll` once per frame and `stop` at the end. The core sends through the `send` function it receives in `start`.

typealias NPSendFn = @convention(c) (Int32, UnsafeRawPointer?, Int, UInt16) -> Void
typealias NPPollReceiveFn = @convention(c) () -> Void
typealias NPStartFn = @convention(c) (UInt16, NPSendFn?, NPPollReceiveFn?) -> Void
typealias NPReceiveFn = @convention(c) (UnsafeRawPointer?, Int, UInt16) -> Void
typealias NPStopFn = @convention(c) () -> Void
typealias NPPollFn = @convention(c) () -> Void
typealias NPConnectedFn = @convention(c) (UInt16) -> Bool
typealias NPDisconnectedFn = @convention(c) (UInt16) -> Void

/// struct retro_netpacket_callback (field order matters).
struct RetroNetpacketCallback {
  var start: NPStartFn?
  var receive: NPReceiveFn?
  var stop: NPStopFn?
  var poll: NPPollFn?
  var connected: NPConnectedFn?
  var disconnected: NPDisconnectedFn?
  var protocolVersion: UnsafePointer<CChar>?
}

// Top-level C callbacks (no captures): they reach the session through the singleton.
private let npSend: NPSendFn = { _, buf, len, dst in
  NetSession.shared.coreSend(buf, len, dst)
}
private let npPollReceive: NPPollReceiveFn = {
  NetSession.shared.drainIncoming()
}

// MARK: - Session

/// Local-network multiplayer lobby for any core that offers the netpacket interface.
///
/// How it works: every player starts the same game, opens the pause menu → Multiplayer, and either hosts or joins a lobby
/// (found automatically over Bonjour, or by typing the host's address). The host is client 0, joiners get 1, 2, ...
/// Topology is a star over TCP: joiners connect to the host, the host relays packets between players. The core never knows
/// about any of this: it only sees client ids and packets.
///
/// Threading: network state lives on `net` (a serial queue). Everything that touches the core (`start`, `receive`, `poll`,
/// `stop`, `send`) runs on the main thread, the same thread that runs `retro_run`, so the core is never entered twice.
final class NetSession: ObservableObject {
  static let shared = NetSession()

  static let serviceType = "_retronaut._tcp"
  static let defaultPort: UInt16 = 36500
  static let maxPlayers = 8                        // host + 7
  private static let wireVersion: UInt8 = 1
  private static let broadcast: UInt16 = 0xFFFF    // RETRO_NETPACKET_BROADCAST

  enum Role { case idle, host, client }

  struct Player: Identifiable, Equatable {
    let id: Int
    let name: String
  }

  struct Lobby: Identifiable, Equatable {
    let id: String              // Bonjour service name
    let title: String           // the host's game
    let host: String            // the host's player name
    let endpoint: NWEndpoint
  }

  // Shown by the UI (always mutated on the main thread).
  @Published private(set) var available = false     // the running core offers a netpacket interface
  @Published private(set) var role: Role = .idle
  @Published private(set) var status = ""
  @Published private(set) var players: [Player] = []
  @Published private(set) var lobbies: [Lobby] = []
  @Published private(set) var live = false          // the core's session is running
  @Published private(set) var addresses: [String] = []
  @Published var playerName: String {
    didSet { UserDefaults.standard.set(playerName, forKey: "mp.name") }
  }
  @Published private(set) var myId = 0

  // Core side (main thread only).
  private var cb: RetroNetpacketCallback?
  private var coreStarted = false
  private var generation = 0
  private(set) var gameTitle = ""
  private var gameKey = ""

  /// True while a multiplayer session runs (readable from any thread): save states are off then.
  var sessionActive: Bool { flagLock.lock(); defer { flagLock.unlock() }; return _sessionActive }
  private let flagLock = NSLock()
  private var _sessionActive = false
  private func setActive(_ v: Bool) { flagLock.lock(); _sessionActive = v; flagLock.unlock() }

  // Packets waiting for the core.
  private let inLock = NSLock()
  private var incoming: [(UInt16, Data)] = []
  private var drainPending = false

  // Network side (the `net` queue only).
  private let net = DispatchQueue(label: "retronaut.net")
  private var listener: NWListener?
  private var browser: NWBrowser?
  private var wantBrowse = false
  private var netRole: Role = .idle
  private var peers: [Int: Peer] = [:]      // host: accepted players by id
  private var pending: [Peer] = []          // host: connected, no HELLO yet
  private var upstream: Peer?               // client: the host
  private var netId = 0
  private var hostKey = ""
  private var hostName = ""
  private var epoch = 0                     // bumped per session so stale callbacks are ignored

  private final class Peer {
    let conn: NWConnection
    var id = -1
    var name = ""
    var buffer = Data()
    var ready = false
    var closed = false
    init(_ c: NWConnection) { conn = c }
  }

  private init() {
    let saved = UserDefaults.standard.string(forKey: "mp.name") ?? ""
    playerName = saved.isEmpty ? String(UIDevice.current.name.prefix(18)) : saved
  }

  private func onMain(_ f: @escaping () -> Void) {
    if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
  }

  static func key(_ title: String) -> String { title.lowercased().filter { $0.isLetter || $0.isNumber } }

  // MARK: Core attach / detach (called by CoreHost)

  /// The core registered its netpacket table (during `retro_set_environment`).
  func attach(_ callbacks: RetroNetpacketCallback, gameTitle: String) {
    onMain {
      self.teardownAll(message: "")
      self.cb = callbacks
      self.generation &+= 1
      self.gameTitle = gameTitle
      self.gameKey = Self.key(gameTitle)
      self.available = callbacks.start != nil
    }
  }

  /// The core is about to be unloaded: end any session first, never call into it afterwards.
  func coreEnded() {
    onMain {
      self.teardownAll(message: "")
      self.cb = nil
      self.coreStarted = false
      self.generation &+= 1
      self.available = false
    }
  }

  /// Once per frame, before `retro_run`.
  func framePoll() {
    guard coreStarted, let poll = cb?.poll else { return }
    drainIncoming()
    poll()
  }

  // MARK: Core calls (main thread)

  private func startCore(_ id: Int, generation g: Int) {
    guard g == generation, !coreStarted, let start = cb?.start else { return }
    coreStarted = true
    setActive(true)
    live = true
    start(UInt16(truncatingIfNeeded: id), npSend, npPollReceive)
  }

  private func stopCore() {
    guard coreStarted else { return }
    coreStarted = false
    setActive(false)
    live = false
    inLock.lock(); incoming.removeAll(); inLock.unlock()
    cb?.stop?()
  }

  /// The core's `send` function: forward to the network.
  func coreSend(_ buf: UnsafeRawPointer?, _ len: Int, _ dst: UInt16) {
    guard let buf, len > 0, len <= 8192 else { return }
    let data = Data(bytes: buf, count: len)
    net.async { self.route(data, dst: dst) }
  }

  /// Hands queued packets to the core (also the core's own `poll_receive` function).
  func drainIncoming() {
    inLock.lock()
    let batch = incoming
    incoming.removeAll(keepingCapacity: true)
    drainPending = false
    inLock.unlock()
    guard coreStarted, let receive = cb?.receive else { return }
    for (src, data) in batch where !data.isEmpty {
      data.withUnsafeBytes { raw in receive(raw.baseAddress, data.count, src) }
    }
  }

  private func deliver(_ src: UInt16, _ data: Data) {
    inLock.lock()
    if incoming.count > 4000 { incoming.removeFirst(1000) }     // nobody is draining (paused): bound the memory
    incoming.append((src, data))
    let schedule = !drainPending
    drainPending = true
    inLock.unlock()
    if schedule { DispatchQueue.main.async { self.drainIncoming() } }
  }

  // MARK: UI actions (main thread)

  func startBrowsing() {
    net.async {
      self.wantBrowse = true
      self.beginBrowse()
    }
  }

  func stopBrowsing() {
    net.async {
      self.wantBrowse = false
      self.endBrowse()
      DispatchQueue.main.async { if self.role == .idle { self.lobbies = [] } }
    }
  }

  func host() {
    guard available, role == .idle else { return }
    let title = gameTitle, name = cleanName(), g = generation
    setActive(true)                       // save states are off from here until the lobby is left
    status = "Starting the lobby…"
    net.async { self.beginHost(title: title, player: name, generation: g) }
  }

  func join(_ lobby: Lobby) {
    guard available, role == .idle else { return }
    let name = cleanName(), key = gameKey, g = generation
    setActive(true)
    status = "Connecting to \(lobby.host)…"
    net.async { self.beginJoin(endpoint: lobby.endpoint, player: name, key: key, generation: g) }
  }

  func join(address text: String) {
    guard available, role == .idle else { return }
    var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var port = Self.defaultPort
    if host.filter({ $0 == ":" }).count == 1, let i = host.lastIndex(of: ":") {
      if let p = UInt16(host[host.index(after: i)...]) { port = p }
      host = String(host[..<i])
    }
    guard !host.isEmpty, let p = NWEndpoint.Port(rawValue: port) else { status = "Type the host's address, e.g. 192.168.1.20"; return }
    let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: p)
    let name = cleanName(), key = gameKey, g = generation
    setActive(true)
    status = "Connecting to \(host)…"
    net.async { self.beginJoin(endpoint: ep, player: name, key: key, generation: g) }
  }

  /// Leave the lobby / stop hosting.
  func leave() {
    teardownAll(message: "")
  }

  private func cleanName() -> String {
    let n = playerName.replacingOccurrences(of: " | ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return n.isEmpty ? "Player" : n
  }

  /// Everything back to idle: network first (on `net`), then the core session and the UI (main thread).
  private func teardownAll(message: String) {
    net.async { self.teardownNet(sendBye: true) }
    finishLeave(message)
  }

  private func finishLeave(_ message: String) {
    onMain {
      self.stopCore()
      self.setActive(false)
      self.role = .idle
      self.players = []
      self.addresses = []
      self.myId = 0
      self.status = message
    }
  }

  // MARK: Wire format
  //
  //   frame   = u32 length (type + payload) | u8 type | payload          (big endian)
  //   HELLO 1 = u8 version | u8 nameLen | name | game key (rest)         client -> host
  //   WELCOME 2 = u16 yourId | roster                                    host -> client
  //   REJECT 3 = utf8 reason                                              host -> client
  //   ROSTER 4 = roster                                                   host -> clients
  //   PACKET 5 = u16 src | u16 dst | data                                 both ways (host relays)
  //   BYE 6                                                                either way
  //   roster  = u8 count | (u16 id | u8 nameLen | name) ...

  private enum Msg: UInt8 { case hello = 1, welcome, reject, roster, packet, bye }

  private func frame(_ type: Msg, _ payload: Data = Data()) -> Data {
    var d = Data()
    var len = UInt32(payload.count + 1).bigEndian
    withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
    d.append(type.rawValue)
    d.append(payload)
    return d
  }

  private func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }

  private struct Reader {
    let d: Data
    var i = 0
    init(_ d: Data) { self.d = d }
    mutating func u8() -> Int? { guard i < d.count else { return nil }; defer { i += 1 }; return Int(d[d.startIndex + i]) }
    mutating func u16() -> Int? { guard let a = u8(), let b = u8() else { return nil }; return a << 8 | b }
    mutating func bytes(_ n: Int) -> Data? {
      guard n >= 0, i + n <= d.count else { return nil }
      defer { i += n }
      return d.subdata(in: (d.startIndex + i)..<(d.startIndex + i + n))
    }
    mutating func rest() -> Data { let r = d.subdata(in: (d.startIndex + i)..<d.endIndex); i = d.count; return r }
  }

  private func encodeRoster(_ list: [Player]) -> Data {
    var d = Data([UInt8(min(list.count, 255))])
    for p in list.prefix(255) {
      let name = Data(p.name.utf8.prefix(40))
      d.append(be16(UInt16(p.id)))
      d.append(UInt8(name.count))
      d.append(name)
    }
    return d
  }

  private func decodeRoster(_ r: inout Reader) -> [Player] {
    guard let n = r.u8() else { return [] }
    var out: [Player] = []
    for _ in 0..<n {
      guard let id = r.u16(), let len = r.u8(), let nameData = r.bytes(len) else { break }
      out.append(Player(id: id, name: String(decoding: nameData, as: UTF8.self)))
    }
    return out
  }

  private static func params() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true                    // IPX games exchange tiny packets every frame: no Nagle delay
    let p = NWParameters(tls: nil, tcp: tcp)
    p.includePeerToPeer = true            // nearby Apple devices can also find each other without a shared Wi-Fi network
    return p
  }

  // MARK: Discovery (net queue)

  private static func serviceName(title: String, player: String) -> String {
    func fit(_ s: String, bytes: Int) -> String {
      var out = s
      while out.utf8.count > bytes, !out.isEmpty { out.removeLast() }
      return out
    }
    return fit(title, bytes: 30) + " | " + fit(player, bytes: 24)      // Bonjour names are limited to 63 bytes
  }

  private func beginBrowse() {
    guard wantBrowse, browser == nil, netRole == .idle else { return }
    let p = NWParameters.tcp
    p.includePeerToPeer = true
    let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: p)
    b.stateUpdateHandler = { [weak self] st in
      guard let self else { return }
      switch st {
      case .failed(let e):
        DispatchQueue.main.async { if self.role == .idle { self.status = "Can't search the network: \(e.localizedDescription)" } }
      case .waiting:
        DispatchQueue.main.async {
          if self.role == .idle && self.status.isEmpty {
            self.status = "Searching… if asked, allow Local Network access (Settings → Privacy → Local Network)."
          }
        }
      default: break
      }
    }
    b.browseResultsChangedHandler = { [weak self] results, _ in
      var list: [Lobby] = []
      for r in results {
        guard case let .service(name, _, _, _) = r.endpoint else { continue }
        let parts = name.components(separatedBy: " | ")
        list.append(Lobby(id: name, title: parts.first ?? name, host: parts.count > 1 ? parts[1] : "", endpoint: r.endpoint))
      }
      list.sort { $0.id < $1.id }
      DispatchQueue.main.async { if self?.role == .idle { self?.lobbies = list } }
    }
    browser = b
    b.start(queue: net)
  }

  private func endBrowse() {
    browser?.cancel()
    browser = nil
  }

  // MARK: Host (net queue)

  private func beginHost(title: String, player: String, generation g: Int) {
    guard netRole == .idle else { return }
    endBrowse()
    epoch += 1
    let ep = epoch
    netRole = .host
    netId = 0
    hostKey = Self.key(title)
    hostName = player

    let params = Self.params()
    var made: NWListener?
    if let port = NWEndpoint.Port(rawValue: Self.defaultPort), let l = try? NWListener(using: params, on: port) { made = l }
    else { made = try? NWListener(using: params) }
    guard let l = made else {
      netRole = .idle
      finishLeave("Couldn't open a network port for the lobby.")
      beginBrowse()
      return
    }
    l.service = NWListener.Service(name: Self.serviceName(title: title, player: player), type: Self.serviceType)
    l.stateUpdateHandler = { [weak self] st in self?.listenerState(st, epoch: ep, generation: g, player: player) }
    l.newConnectionHandler = { [weak self] c in self?.accept(c, epoch: ep) }
    listener = l
    l.start(queue: net)
  }

  private func listenerState(_ st: NWListener.State, epoch ep: Int, generation g: Int, player: String) {
    guard ep == epoch, netRole == .host else { return }
    switch st {
    case .ready:
      let port = listener?.port?.rawValue ?? Self.defaultPort
      let addrs = Self.localAddresses().map { port == Self.defaultPort ? $0 : "\($0):\(port)" }
      DispatchQueue.main.async {
        guard g == self.generation else { return }
        self.role = .host
        self.myId = 0
        self.players = [Player(id: 0, name: player)]
        self.addresses = addrs
        self.status = "Lobby open. Others can join from the list, or by typing your address."
        self.startCore(0, generation: g)
      }
    case .failed(let e):
      teardownNet(sendBye: false)
      finishLeave("The lobby stopped: \(e.localizedDescription)")
    default: break
    }
  }

  private func accept(_ conn: NWConnection, epoch ep: Int) {
    guard ep == epoch, netRole == .host, peers.count + pending.count < Self.maxPlayers - 1 else { conn.cancel(); return }
    let p = Peer(conn)
    pending.append(p)
    conn.stateUpdateHandler = { [weak self, weak p] st in
      guard let self, let p else { return }
      switch st {
      case .failed, .cancelled: self.net.async { self.dropPeer(p) }
      default: break
      }
    }
    conn.start(queue: net)
    receive(p)
    net.asyncAfter(deadline: .now() + 6) { [weak self, weak p] in      // a connection that never says HELLO is not a player
      guard let self, let p, !p.ready else { return }
      self.dropPeer(p)
    }
  }

  private func firstFreeId() -> Int? {
    (1..<Self.maxPlayers).first { peers[$0] == nil }
  }

  private func hostRoster() -> [Player] {
    [Player(id: 0, name: hostName)] + peers.values.filter { $0.ready }.sorted { $0.id < $1.id }.map { Player(id: $0.id, name: $0.name) }
  }

  private func publishRoster() {
    let r = hostRoster()
    let data = frame(.roster, encodeRoster(r))
    for p in peers.values where p.ready { send(data, to: p) }
    DispatchQueue.main.async { self.players = r }
  }

  private func dropPeer(_ p: Peer) {
    guard !p.closed else { return }
    p.closed = true
    p.conn.cancel()
    pending.removeAll { $0 === p }
    if p.id > 0, peers[p.id] === p {
      peers[p.id] = nil
      if netRole == .host { publishRoster() }
    }
  }

  // MARK: Client (net queue)

  private func beginJoin(endpoint: NWEndpoint, player: String, key: String, generation g: Int) {
    guard netRole == .idle else { return }
    endBrowse()
    epoch += 1
    let ep = epoch
    netRole = .client
    let conn = NWConnection(to: endpoint, using: Self.params())
    let p = Peer(conn)
    upstream = p
    conn.stateUpdateHandler = { [weak self, weak p] st in
      guard let self, let p, ep == self.epoch else { return }
      switch st {
      case .ready:
        var d = Data([Self.wireVersion])
        let name = Data(player.utf8.prefix(40))
        d.append(UInt8(name.count)); d.append(name); d.append(Data(key.utf8))
        self.send(self.frame(.hello, d), to: p)
      case .waiting:
        DispatchQueue.main.async {
          if self.role != .client { self.status = "Can't reach the host yet… (check Local Network access in Settings → Privacy)" }
        }
      case .failed(let e):
        self.clientLost("Couldn't connect: \(e.localizedDescription)", epoch: ep)
      case .cancelled:
        self.clientLost("", epoch: ep)
      default: break
      }
    }
    conn.start(queue: net)
    receive(p)
    net.asyncAfter(deadline: .now() + 10) { [weak self, weak p] in
      guard let self, let p, ep == self.epoch, !p.ready else { return }
      self.clientLost("No answer from the host. Same Wi-Fi? Same game started on both devices?", epoch: ep)
    }
    self.pendingGeneration = g
  }

  private var pendingGeneration = 0

  private func clientLost(_ message: String, epoch ep: Int) {
    guard ep == epoch, netRole == .client else { return }
    teardownNet(sendBye: false)
    finishLeave(message)
  }

  // MARK: Shared receive / send (net queue)

  private func send(_ data: Data, to p: Peer) {
    guard !p.closed else { return }
    p.conn.send(content: data, completion: .contentProcessed { _ in })
  }

  private func sendPacket(_ p: Peer, src: UInt16, dst: UInt16, _ data: Data) {
    send(frame(.packet, be16(src) + be16(dst) + data), to: p)
  }

  private func receive(_ p: Peer) {
    p.conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self, weak p] data, _, complete, error in
      guard let self, let p, !p.closed else { return }
      if let data, !data.isEmpty {
        p.buffer.append(data)
        self.parse(p)
      }
      if error != nil || complete {
        if self.netRole == .host { self.dropPeer(p) }
        else if self.upstream === p { self.clientLost("The host closed the lobby.", epoch: self.epoch) }
        return
      }
      if !p.closed { self.receive(p) }
    }
  }

  private func parse(_ p: Peer) {
    while p.buffer.count >= 5 {
      let len = p.buffer.prefix(4).reduce(0) { Int($0) << 8 | Int($1) }
      guard len >= 1, len <= 16384 else { dropOrLose(p); return }          // not our protocol
      guard p.buffer.count >= 4 + len else { return }
      let typeByte = p.buffer[p.buffer.startIndex + 4]
      let payload = p.buffer.subdata(in: (p.buffer.startIndex + 5)..<(p.buffer.startIndex + 4 + len))
      p.buffer = Data(p.buffer.dropFirst(4 + len))
      guard let type = Msg(rawValue: typeByte) else { continue }
      if netRole == .host { hostHandle(p, type, payload) } else { clientHandle(p, type, payload) }
      if p.closed { return }
    }
  }

  private func dropOrLose(_ p: Peer) {
    if netRole == .host { dropPeer(p) } else { clientLost("The host speaks a different protocol.", epoch: epoch) }
  }

  private func hostHandle(_ p: Peer, _ type: Msg, _ payload: Data) {
    switch type {
    case .hello:
      guard !p.ready else { return }
      var r = Reader(payload)
      guard let ver = r.u8(), let nameLen = r.u8(), let nameData = r.bytes(nameLen) else { dropPeer(p); return }
      let key = String(decoding: r.rest(), as: UTF8.self)
      func reject(_ why: String) {
        send(frame(.reject, Data(why.utf8)), to: p)
        net.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.dropPeer(p) }
      }
      guard ver == Int(Self.wireVersion) else { reject("Different app version. Update both devices."); return }
      guard key == hostKey else { reject("This lobby is playing a different game."); return }
      guard let id = firstFreeId() else { reject("The lobby is full."); return }
      p.id = id
      p.name = String(decoding: nameData, as: UTF8.self)
      p.ready = true
      pending.removeAll { $0 === p }
      peers[id] = p
      send(frame(.welcome, be16(UInt16(id)) + encodeRoster(hostRoster())), to: p)
      publishRoster()
    case .packet:
      guard p.ready else { return }
      var r = Reader(payload)
      guard r.u16() != nil, let dst = r.u16() else { return }               // the claimed source is ignored: it is the connection's id
      let data = r.rest()
      let src = UInt16(p.id)
      if dst == Int(Self.broadcast) {
        for q in peers.values where q !== p && q.ready { sendPacket(q, src: src, dst: Self.broadcast, data) }
        deliver(src, data)
      } else if dst == 0 {
        deliver(src, data)
      } else if let q = peers[dst], q.ready {
        sendPacket(q, src: src, dst: UInt16(dst), data)
      }
    case .bye:
      dropPeer(p)
    default:
      break
    }
  }

  private func clientHandle(_ p: Peer, _ type: Msg, _ payload: Data) {
    switch type {
    case .welcome:
      var r = Reader(payload)
      guard let id = r.u16() else { return }
      let roster = decodeRoster(&r)
      p.ready = true
      netId = id
      let g = pendingGeneration
      DispatchQueue.main.async {
        guard g == self.generation, self.role == .idle else { return }
        self.role = .client
        self.myId = id
        self.players = roster
        self.status = "Joined the lobby."
        self.startCore(id, generation: g)
      }
    case .roster:
      var r = Reader(payload)
      let roster = decodeRoster(&r)
      DispatchQueue.main.async { if self.role == .client { self.players = roster } }
    case .reject:
      let why = String(decoding: payload, as: UTF8.self)
      clientLost(why.isEmpty ? "The host refused the connection." : why, epoch: epoch)
    case .packet:
      var r = Reader(payload)
      guard let src = r.u16(), r.u16() != nil, p.ready else { return }
      deliver(UInt16(src), r.rest())
    case .bye:
      clientLost("The host closed the lobby.", epoch: epoch)
    default:
      break
    }
  }

  /// Routes a packet the core sent.
  private func route(_ data: Data, dst: UInt16) {
    switch netRole {
    case .host:
      if dst == Self.broadcast {
        for p in peers.values where p.ready { sendPacket(p, src: 0, dst: dst, data) }
      } else if let p = peers[Int(dst)], p.ready {
        sendPacket(p, src: 0, dst: dst, data)
      }
    case .client:
      if let u = upstream, u.ready { sendPacket(u, src: UInt16(truncatingIfNeeded: netId), dst: dst, data) }
    case .idle:
      break
    }
  }

  /// Closes every connection and the listener (net queue). The browser is restarted when the lobby list is on screen.
  private func teardownNet(sendBye: Bool) {
    epoch += 1
    let bye = frame(.bye)
    var all = Array(peers.values) + pending
    if let u = upstream { all.append(u) }
    for p in all where !p.closed {
      p.closed = true
      if sendBye && p.ready {
        p.conn.send(content: bye, completion: .contentProcessed { _ in p.conn.cancel() })
      } else {
        p.conn.cancel()
      }
    }
    peers = [:]
    pending = []
    upstream = nil
    listener?.cancel()
    listener = nil
    netRole = .idle
    if wantBrowse { beginBrowse() }
  }

  // MARK: Addresses

  /// IPv4 addresses of this device (Wi-Fi, hotspot / bridge), so others can type one to join.
  static func localAddresses() -> [String] {
    var out: [String] = []
    var ifa: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifa) == 0, let first = ifa else { return out }
    defer { freeifaddrs(ifa) }
    var cur: UnsafeMutablePointer<ifaddrs>? = first
    while let c = cur {
      let i = c.pointee
      if let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
         (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
        let name = String(cString: i.ifa_name)
        if name.hasPrefix("en") || name.hasPrefix("bridge") {
          var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
          if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            out.append(String(cString: host))
          }
        }
      }
      cur = i.ifa_next
    }
    return out
  }
}
