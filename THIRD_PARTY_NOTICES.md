# Third-party notices

This repository ships two emulator binaries in
`Sources/Retronaut/Resources/Cores/` (tracked with Git LFS). Both are
**unmodified upstream builds** — no local patches. The app's own source is
GPL-3.0-or-later; the cores remain under their own licences.

| File | Upstream | License | Size | MD5 |
|---|---|---|---|---|
| `dosbox_pure.dylib` | <https://github.com/schellingb/dosbox-pure> | GPL v2 | 2,500,720 | `3bf0ce2bcd946ea510180efa5e88adfb` |
| `scummvm.dylib` | <https://github.com/scummvm/scummvm> | GPL v2 | 143,883,680 | `80fa61376a7c022ee1b323992c6fc321` |

Both are built from upstream as libretro-style dynamic libraries. Compatibility
work lives in the app, not in the cores: the host answers the core's
`GET_LOG_INTERFACE` environment call and hands ScummVM a game file rather than a
folder. Nothing in the binary is modified.

## If you redistribute

These binaries are GPLv2. Publishing a build that contains them means you must,
for each core:

1. **Make the complete corresponding source available** by the same means
   (upstream repositories above satisfy this as long as your binaries are
   unmodified builds of them), and
2. **Keep this notice and the licence** with the distribution.

If you ever modify a core, publish the patches alongside the binary — a
binary-only redistribution of a modified GPL core is a licence violation.

## Apple toolchain

The Darwin Swift SDK, iOS frameworks and other Apple-provided binaries are Apple
property under the Apple Developer Program License Agreement. They are not
redistributed here; `xtool` fetches them on your machine.

## Games

Game titles, trademarks, box art and game data belong to their publishers.
Retronaut does not include, host or link to any of them.
