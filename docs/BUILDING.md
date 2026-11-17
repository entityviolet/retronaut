# Building

Retronaut is built **without Xcode**, using [xtool](https://xtool.sh) — a
cross-platform Xcode replacement that cross-compiles SwiftPM packages to iOS.

## 1. Host requirements

- **Linux**, **WSL2 on Windows**, or macOS
- **Swift 6.4** toolchain (`swiftly install 6.4` or your distro's toolchain)
- **xtool 1.24+**
- **Darwin Swift SDK** — `xtool sdk install <Xcode.xip>` or a prebuilt
  `darwin.xtoolsdk` (~3.3 GB)
- For USB installs only: `usbmuxd` and `libimobiledevice-utils`

## 2. Clone with LFS

The two emulation cores are stored with Git LFS:

```bash
git lfs install      # once per machine
git lfs pull         # materialise the cores
```

Without `git lfs pull` the files under `Resources/Cores/` are ~130-byte
pointers. The app still compiles, but at runtime it refuses to start a game and
tells you the core is missing.

## 3. Build

```bash
xtool dev build -c release --sign --ipa
```

Output: `xtool/Retronaut.ipa`.

| Flags | Result |
|---|---|
| *(none)* | `.app` bundle, unsigned, debug |
| `-c release` | optimised build |
| `--sign` | codesign with your Apple identity |
| `--ipa` | pack a `.ipa` instead of a `.app` |

## 4. Signing

```bash
xtool auth login
```

xtool talks to Apple Developer Services directly and creates what it needs — an
App ID (prefixed with your team, e.g. `XTL-XXXXXXXXXX.com.retronaut.app`), a
development certificate if you have none, and a provisioning profile containing
your registered devices.

| | Free Apple ID | Paid developer program |
|---|---|---|
| Sign & sideload | yes | yes |
| Profile lifetime | 7 days, then re-sign | 1 year |
| App IDs | 10 | unlimited |
| Devices | 3 | 100 |
| Entitlements | restricted | full |

You can override the bundle id in `xtool.yml`; keep it unique to your team.

## 5. Verify the artifact

```bash
unzip -l xtool/Retronaut.ipa | head           # Payload/Retronaut.app/…
unzip -p xtool/Retronaut.ipa "Payload/*.app/Info.plist" | plutil -p -   # bundle id, min iOS
unzip -p xtool/Retronaut.ipa "Payload/*.app/embedded.mobileprovision" > /tmp/p.mobileprovision
security cms -D -i /tmp/p.mobileprovision | plutil -p -                  # app id, devices, expiry
```

The two `Cores/*.dylib` entries inside `Payload/…/Resources/Cores/` should be
megabyte-sized — if they are a few hundred bytes, LFS never materialised them.

## 6. Linux note: `strip` and Mach-O

SwiftPM strips files it copies as resources in **release** mode, and GNU `strip`
cannot read Mach-O. On Linux a release build fails with:

```
strip -D -S -no_atom_info …/dosbox_pure.dylib -> exit 1
```

macOS is unaffected. On Linux, make `strip` pass Mach-O through untouched — a
small shim placed ahead of `/usr/bin/strip` that copies the file when `file`
reports `Mach-O`, or replace `/usr/bin/strip` with it (keep the original as
`strip.gnu`). Debug builds (`-c debug`) never strip.

## 7. Rebuilding the cores yourself

Both cores are built from upstream as libretro-style dynamic libraries:

- DOSBox Pure — <https://github.com/schellingb/dosbox-pure> → `dosbox_pure.dylib`
- ScummVM — <https://www.scummvm.org> (libretro target) → `scummvm.dylib`

Place them in `Sources/Retronaut/Resources/Cores/` and rebuild the app. If you
change them, update [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and the
source offer that goes with a redistribution.

## 8. Optional: bundle Windows disk images

Copy `win95.img` / `win31.img` (with their `.geometry` sidecars) into
`Sources/Retronaut/Resources/OS/` before building. They travel inside the app and
are git-ignored. Details: [OS-IMAGES.md](OS-IMAGES.md).

## 9. Where things can go wrong

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 10. Versioning

Two numbers, kept in two places:

| Field | Where | Meaning |
|---|---|---|
| `CFBundleShortVersionString` | `Info.plist` | marketing version, `MAJOR.MINOR.PATCH` |
| `CFBundleVersion` | `xtool.yml` (`version:`) | build number, integer, increments every upload |

Bump both for a release, add a `CHANGELOG.md` entry, and confirm the result:

```bash
unzip -p xtool/Retronaut.ipa "Payload/*.app/Info.plist" | plutil -p - | grep -i version
```
