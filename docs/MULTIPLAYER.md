# Multiplayer lobby

Works with any game whose core offers libretro's netpacket interface. Today that is **DOSBox Pure** (IPX, and the COM1 modem /
null-modem). ScummVM and Windows 98 / 3.1 packs don't use it (the shared Windows disks have no network adapter).

## How players use it

1. Every player starts the **same game** (same title, same files) on their device.
2. Pause menu → **Multiplayer**.
3. One player taps **Host a lobby**. The others see it under **Lobbies nearby** and tap **Join** (or type the host's address under
   **Join by address**, e.g. over a VPN such as Tailscale).
4. Resume the game and use its own network option (IPX, or modem / serial). Dungeon Keeper 1: multiplayer → IPX.

Save, load and auto-save are blocked from the moment you host or join until you leave the lobby (code guard in `CoreHost.saveState/loadState/autoSave` plus a locked pause-menu page), because a networked game can't be rewound. Up to 8 players.

## How it works

- `Core/NetLobby.swift`: `NetSession`. The core registers its netpacket table (env command 78, answered in `DosCoreRender.handleEnv`).
  Hosting / joining calls the core's `start(clientId)`; the host is client 0, joiners 1..7. The core then sends through our `send`
  function and gets packets through `receive`. `poll` runs once per frame (`CoreHost.tick`).
- Transport: TCP (Network.framework) in a star: joiners connect to the host, the host relays (unicast and broadcast). No Nagle delay.
  Discovery: Bonjour `_retronaut._tcp`, service name `"<game> | <player>"`; a lobby of a different game can't be joined (the host
  also rejects a different game key or app version).
- Threading: network state on one serial queue; every call into the core happens on the main thread (the thread that runs
  `retro_run`), so the core is never re-entered. `CoreHost.stop()` ends the session before the core is unloaded.
- `LobbyView.swift`: the lobby screen, shown inside the pause menu (no modal sheet over the game).

## Requirements

- `Info.plist` keys `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_retronaut._tcp`); the file is merged by xtool via
  `infoPath: Info.plist` in `xtool.yml`. iOS asks the user for Local Network access the first time.
- `Network` framework (linked in `Package.swift`).

## Limits / unverified

- Local network or VPN only. Play over the internet without a VPN needs a relay server (not included).
- Not run on a device. The netpacket function signatures follow libretro.h; the core side was checked by disassembling
  `dosbox_pure.dylib` (its table is `start, receive, stop, poll`, no `connected` / `disconnected`).
- If a game finds no other player, check both devices run the same game and that IPX (not modem) is chosen in the game.
