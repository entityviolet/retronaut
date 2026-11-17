# Retronaut

**Run classic DOS and Windows-era games on iPhone and iPad — from the files you own.**

Retronaut is a SwiftUI shell around two proven emulation cores, **DOSBox Pure**
and **ScummVM**. It gives you a library, disk-image handling, save states, an
optional local store and a LAN lobby, so a 1993 adventure plays like an app
instead of a command line.

> **No games are included.** Retronaut ships no game data, box art or ROMs — only
> the app and the emulator cores. You point it at files you already own.

## Features

| | |
|---|---|
| **Library** | Import a pack (`.zip` with a `game.json`) or a plain folder; launches with the right core and options. |
| **Two cores** | DOSBox Pure for DOS titles, ScummVM for point-and-click adventures. |
| **Windows packs** | Windows 95 / 98 / 3.1 titles boot from a disk image you supply; the app mounts the game drive and runs the executable. |
| **CD-based games** | An `.iso` inside the pack is mounted as a CD-ROM — no "insert disc" dead ends. |
| **Save states** | Per game, plus per-launch logs. |
| **Local store** | A JSON catalogue served from your own machine or a static host — see [docs/STORE.md](docs/STORE.md). |
| **LAN lobby** | IPX-era multiplayer between two devices on the same network. |
| **No Xcode** | Built with [xtool](https://xtool.sh) on macOS, Linux or WSL. |

## Requirements

- **iOS / iPadOS 17.0+**, arm64 (iPhone or iPad)
- A build host with **Swift 6.4** and **[xtool](https://xtool.sh) 1.24+**
- Your own **Apple ID** for signing — a free one works, with the usual
  7-day profile expiry; a paid developer account removes that limit

## Quick start

```bash
git clone <repo-url> retronaut && cd retronaut
git lfs install && git lfs pull          # the emulator cores live in Git LFS
xtool sdk install /path/to/Xcode.xip     # once: installs the Darwin SDK
xtool auth login                         # once: your Apple ID
xtool dev build -c release --sign --ipa  # -> xtool/Retronaut.ipa
```

Install it:

```bash
xtool device install xtool/Retronaut.ipa   # USB
```

Full details: [docs/BUILDING.md](docs/BUILDING.md) ·
[docs/INSTALL.md](docs/INSTALL.md) ·
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

## Project layout

```
Sources/Retronaut/              SwiftUI app: library, store, settings, import
Sources/Retronaut/Core/         core bridge, disk images, launcher, netplay
Sources/Retronaut/Resources/    icons, UI art, games.json, Cores/ (Git LFS)
docs/                           build, install, troubleshooting, formats
Package.swift                   SwiftPM manifest (iOS 17, arm64)
xtool.yml                       bundle id, icon, packaging
```

## Packs

A pack is a zip (or folder) holding a `game.json` plus the game's files. The
manifest controls which core runs, which drive is mounted, what the emulated
machine sees, and which files are written before launch. Format reference:
[docs/GAME_JSON.md](docs/GAME_JSON.md). Multiplayer details:
[docs/MULTIPLAYER.md](docs/MULTIPLAYER.md). Internal design:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Windows disk images

Windows 95 / 98 / 3.1 games need a Windows disk that you supply — see
[docs/OS-IMAGES.md](docs/OS-IMAGES.md) for where to put it at build time
(`Sources/Retronaut/Resources/OS/`) and how to import one on the device.

## The cores

DOSBox Pure and ScummVM are **GPLv2** projects. Their binaries live in
`Sources/Retronaut/Resources/Cores/` and are tracked with **Git LFS**; they are
copied into the app bundle at build time. If you redistribute the app you must
also make the corresponding source available — see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Support

Retronaut is free software and stays that way — no licence keys, no tiers, no
paywalled features. If it brought an old game back to life for you and you feel
like saying thanks, a tip is welcome and never expected.

**Bitcoin**

```
bc1q3sskuve9ar66pa0858xhlfxeak3g7659zpvhjj
```

**Litecoin**

```
ltc1q5etc7z2h5j96wwaud7k6q42eazda0rpxdtrpd7
```

**Monero**

```
4AiAw4UJzb6GrEDUvtSMq41War2yKReiP3f9xMV5uCEwRko81s7ofPFSHQGc4JSBpa3aJpqX6z1odh6dBhricYZG4nrHWet
```

Tips don't buy priority support or influence what gets built. Bugs and ideas go
to the issue tracker, where everyone can see them.

## Licence

Retronaut is free software under the **GNU General Public License v3.0 or later**
— see [LICENSE](LICENSE). The two emulator cores it ships are GPL-compatible
third-party works with their own notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Game titles, trademarks, box art and game data belong to their publishers.
Retronaut does not include, host or link to any of them.
