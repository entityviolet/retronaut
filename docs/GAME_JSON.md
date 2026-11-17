# game.json manual

**Rule: the app contains no game-specific code.** Everything a game needs (folders, config files, commands, hardware options,
drives, discs) is declared in the game's own pack: `game.json`, `meta.json`, cover, and the files/disk images in the zip.
If a game needs something the schema can't say, extend the schema (all four places listed in PACK_README.md section 3), never add `if gameId == ...`.

A pack = a zip with `game.json` (+ optional `meta.json`, `cover.jpg`) + the game's files or disk images. Details of the zip: PACK_README.md.

---

## 1. Keys

### Identity (`meta.json`, or the same keys inside `game.json`; meta.json wins)

| Key | Type | Meaning |
|---|---|---|
| `title` | string | Name in the library |
| `year`, `genre`, `developer`, `blurb` | | Shown on the detail screen |
| `engine` | string | `DOSBox` or `ScummVM` label (derived from `core` if missing) |

Bundled games (inside the app, `Resources/Games/<id>/`) are described the same way: `game.json` there, and one entry per game in
`Resources/games.json`: `{ "id": "keen4", "title": "…", "year": 1991, "tag": "DOSBox", "developer": "…", "genre": "…", "blurb": "…" }`.

### Launch: DOS games (kind A)

C: is the pack's files (the zip folder, or only `dataSubdir`). The generated script, in this exact order:

```
mount c "<C: folder>"
<mounts...>                                  each line as written
imgmount d "<cd>" -t iso [-fs iso]           only if `cd` is set and found
c:
cd <dir>                                     only if `dir` is set
<pre...>                                     each line as written
<exe> <args>
```

| Key | Type | Meaning |
|---|---|---|
| `core` | `"dosbox"` \| `"scummvm"` | Default `dosbox`. ScummVM starts the folder directly. |
| `exe` | string | Program to run. `SUB/GAME.EXE` is split into folder + file. Missing → importer guesses a launcher. |
| `dir` | string | Folder on C: to `cd` into before `pre` and `exe`. |
| `args` | string | Arguments for `exe`. |
| `pre` | string[] | DOS lines after `cd`, before `exe`. For sound-card setup, TSRs, drivers, `set` lines. |
| `mounts` | string[] | DOS lines before `c:` (extra `mount` / `imgmount`). |
| `cd` | string | CD image mounted as D:. A `.cue`/`.ins` next to a raw image is preferred. |
| `autoexec` | string or string[] | **Replaces the whole script above.** `{data}` expands to the C: folder path. Use when the order or mounts differ completely. |
| `files` | object | Text files created on C: when missing (never overwritten): `{ "KEEPER/KEEPER.CFG": ["line", "line"] }`. String or line array; written with CRLF. For config / ini / cfg files that the game or its installer would normally create. |
| `dataSubdir` | string | Only this subfolder of the pack becomes C: (aliases `dataDir`, `dataFolder`). |
| `sblaster` | string | Sound Blaster settings, e.g. `"A220 I5 D1 H5"`. |
| `dosbox` | object | `memsize`, `cycles`, `sound`, `machine` (PACK_README.md section 6). |
| `mouse` | `"absolute"` \| `"relative"` | Finger points / finger drags. |
| `keys` | string[] | Keys to make reachable, e.g. `["ESC","F1"]`. |

### Launch: Windows 98 games (kind B)

| Key | Type | Meaning |
|---|---|---|
| `baseos` | `"win98"` \| `"win31"` | Boot the shared Windows 98 / Windows 3.1 as C: (aliases: `windows31`, `win3.1`, `win311`, `win3.11`, `wfw311`, `w31`) |
| `drive` | string | Disk image in the pack = D: (game preinstalled, `AUTORUN.BAT` in its root). Default: largest `.img/.vhd/.ima` that is not the disc. |
| `cd` | string | Disc image (`.iso`, or `.cue` + `.bin`) attached as the CD-ROM. Windows picks its letter: the game drive is D:, the disc comes after it (E:). A `.cue` whose `.bin` is missing is skipped. |
| `dosbox` | object | `memsize` (16–512 MB) and `cycles` (`max` or ≥ 20000) only; machine/video/sound and `cycles: "auto"` are ignored (changing the hardware makes Windows re-detect it, `auto` makes the boot crawl). |
| `mouse`, `keys` | | As above |

`exe`, `dir`, `pre`, `mounts`, `autoexec` are ignored for kind B. What runs inside Windows is `AUTORUN.BAT` on the drive image (started by `GAMEAUTO.BAT`, which the app puts in the Windows 98 Startup folder; the drive letter arrives as `%1`).
Everything else the game needs on Windows (config files, shortcuts, command lines) lives **inside the drive image** and is prepared when you build it.

---

## 2. Recipes

### Plain DOS game
```json
{ "core": "dosbox", "exe": "KEEN4E.EXE", "sblaster": "A220 I5 D1 H5" }
```

### Game that needs a setup command first (Pizza Tycoon: sound driver)
It used to be hardcoded. Now:
```json
{ "core": "dosbox", "exe": "PIZZA.EXE", "pre": ["sound\\sound.com > nul"], "mouse": "absolute" }
```
`pre` runs after `c:` and `cd`, right before `exe`. `\\` is a JSON-escaped backslash.

### Game that insists on a folder name and a config (Dungeon Keeper 1)
It used to be hardcoded. Now the pack just lays the files out the way the game wants, and says so:
```
DungeonKeeper.zip
└── DungeonKeeper/
    ├── game.json
    └── KEEPER/               ← all game files here, so the game sees C:\KEEPER\
```
```json
{
  "core": "dosbox",
  "dir": "KEEPER",
  "exe": "KEEPER.EXE",
  "files": {
    "KEEPER/KEEPER.CFG": ["INSTALL_PATH=C:\\KEEPER\\", "INSTALL_TYPE=MAX", "LANGUAGE=ENG"]
  }
}
```
(If `KEEPER.CFG` is already in the folder, drop `files`.)

### DOS game with a disc (copy protection, CD music)
Put the `.cue` + `.bin`/`.iso` in the pack:
```json
{ "core": "dosbox", "cd": "disc/GAME.cue", "dir": "GAME", "exe": "GAME.EXE" }
```
It is mounted as D:. Games that look for D: just work.

### Completely custom start (several mounts, a menu, a batch)
```json
{ "core": "dosbox", "autoexec": ["mount c \"{data}\"", "mount d \"{data}/cd\" -t cdrom", "c:", "cd game", "setup.bat"] }
```
`autoexec` replaces everything, including `exe`, `cd`, `pre`.

### ScummVM game
```json
{ "core": "scummvm" }
```
ScummVM gets one file from the game folder (`exe` if you name one, else a `*.scummvm` hook, else a file of the folder with the most files) and autodetects the game from its parent folder, so keep all data files together in one folder. Needs the optional `scummvm.dylib`. See SCUMMVM_CORE_NOTES.md.

### Windows 98 game, installed to its own drive (Dungeon Keeper 2 style)
Dungeon Keeper 2 is a Windows game. It needs its installer run once, and wants its disc in the drive.

1. Build the drive **once, on the Mac**: boot the exported `win98.img` (README.md section 3) in QEMU/UTM/VirtualBox with a blank raw disk as the second disk and the game's disc as CD-ROM. Install the game to `D:\DK2`. Install DirectX / patches there if needed. Add `D:\AUTORUN.BAT`:
   ```
   @echo off
   start D:\DK2\DK2.EXE
   exit
   ```
   (The game was installed to `D:`, so the game drive must be D:, which it is: Windows puts the game drive at D: and the disc at E:.)
   Copy the disk out as `game.img`. (Anything the installer put on C: — registry, system DLLs — stays on your Mac's copy of C:; if the game needs it, install it on the device's shared C: through Settings → Windows 98 → Open Windows 98, with the disc attached.)
2. Zip:
   ```
   DK2.zip
   └── DK2/
       ├── game.json
       ├── meta.json
       ├── game.img          ← D: with the installed game and AUTORUN.BAT
       └── disc/DK2.cue (+ .bin)
   ```
   ```json
   { "core": "dosbox", "baseos": "win98", "drive": "game.img", "cd": "disc/DK2.cue", "mouse": "relative" }
   ```
Result at launch: C: shared Windows 98, D: preinstalled game, E: the disc, autorun starts the game.
Every launch logs the final mount script and anything skipped (Xcode console, `Win98 launch:`; `GameRunner.lastLaunchLog`).

### Windows 98 tools pack (drivers, DirectX, Voodoo/Glide, tweaks for the shared C:)
A normal pack: the drive holds the installers, the disc is optional (put the Windows 98 CD here when an installer asks for the CABs).
```json
{ "core": "dosbox", "baseos": "win98", "drive": "drivers.img", "cd": "win98se.iso", "mouse": "relative" }
```
Result: C: shared Windows 98, D: drivers disk, E: the Windows 98 CD (its CABs are at `E:\WIN98`, the install source Windows has stored).
Leave out `AUTORUN.BAT` for a plain desktop, or add one that starts a setup. Everything installed lands on C: and persists for all packs.
_Create the image on your build host with any MBR-partitioned FAT16 tool — the geometry matters, the tool does not (see the specs below)._

### Windows 3.1 game (drive with the game preinstalled)
```json
{ "core": "dosbox", "baseos": "win31", "drive": "game.img", "cd": "disc.iso", "mouse": "relative" }
```
C: shared Windows 3.1, D: the game drive (8.3 names). `AUTORUN.BAT` in its root runs in DOS before Windows starts (drive letter in `%1`) and must not
start Windows; set `GAMEWIN` to the program Windows should open: `set GAMEWIN=%1\\GAME\\GAME.EXE`. `dosbox`: only `memsize` (8-64) and `cycles`.
Details: PACK_README.md 5.6.

### Windows 98 game that needs no installer
_Create the image on your build host with any MBR-partitioned FAT16 tool — the geometry matters, the tool does not (see the specs below)._

---

## 3. What the schema can't express (so far)

- Anything that must happen **inside Windows** at start other than running `D:\AUTORUN.BAT`: put it in that batch.
- Files on the shared Windows 98 C: (the pack can't write there on purpose: it is shared by all games).
- Binary config files: ship them in the pack (`files` is text only).
