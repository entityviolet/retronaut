# Troubleshooting

## The app launches but a game says the core is missing

`Resources/Cores/*.dylib` are Git LFS pointers (~130 bytes), not binaries.

```bash
git lfs install && git lfs pull
xtool dev build -c release --sign --ipa
```

Check the built bundle: `find Payload -name '*.dylib' -size +1M` should list both.

## Release build fails on Linux

```
strip -D -S -no_atom_info …/dosbox_pure.dylib -> exit 1
```

GNU `strip` cannot read Mach-O. SwiftPM strips resource files in release mode.
Use a `strip` shim that copies Mach-O files verbatim (see
[BUILDING.md](BUILDING.md#6-linux-note-strip-and-macho)), or build with
`-c debug`, which does not strip.

## `opTimeout` while installing

Developer Mode off, screen locked, or the trust prompt was dismissed. See
[INSTALL.md](INSTALL.md#usb-xtool).

## The profile does not include the device

Free accounts cap at 3 devices; paid at 100. Register the UDID, then let xtool
regenerate the profile (`xtool auth logout && xtool auth login`, then rebuild).

## A Windows pack shows “serious disk error” or no `D:` drive

The game image must be **MBR-partitioned FAT16**, with the partition starting at
LBA 63 and geometry matching the boot sector. A plain FAT image without an MBR
mounts but is not addressable as a drive. See
[GAME_JSON.md](GAME_JSON.md) for the expected layout.

## A CD-based game cannot find its disc

The `.iso` must sit inside the pack and be declared as `"cd": "<name>.iso"` in
`game.json`. The app mounts it as a CD-ROM; nothing is read from the host.

## Black screen or instant exit

Open the launch log: Settings → Diagnostics → **Launch log**. It records the
exact DOS script, the mounted drives and the last line the core logged.

## Where are saves and imported packs kept?

Inside the app's container (`Documents/`), so they travel with the app and are
removed with it. A reinstall over the same bundle id keeps them; a different
bundle id starts empty.
