# Windows disk images

Games that declare `"baseos": "win95"` or `"baseos": "win31"` boot a Windows disk
as `C:` and mount the game drive next to it. That disk is not in this repository
(Windows is not redistributable), so you supply it once.

## Where the app looks at runtime

```
Documents/os/win95/win95.img        working disk  (C:)
Documents/os/win95/win95.geometry   "sectors,heads,cylinders"
Documents/os/win95/install/         setup media (ISO, floppies), if any

Documents/os/win31/win31.img
Documents/os/win31/win31.geometry
```

If no working disk exists, the app **provisions** one from a disk bundled inside
the app bundle (`Resources/OS/<name>.img`). Only when neither exists does it ask
the user to import one.

## Ship it with your build

Put the images here before building:

```
Sources/Retronaut/Resources/OS/win95.img
Sources/Retronaut/Resources/OS/win95.geometry
Sources/Retronaut/Resources/OS/win31.img
Sources/Retronaut/Resources/OS/win31.geometry
```

They are copied into the app bundle and are **git-ignored** (`OS/`, `*.img`), so
your repository stays small and the images never become a download for others.

Sizes for reference: `win95.img` 512 MB, `win31.img` 128 MB. Both are raw
(sparse) MBR discs; the geometry sidecar is a single line:

```
63,16,1040      # sectors per track, heads, cylinders
```

If the sidecar is missing the app derives the geometry from the partition table
and BPB, so it still works — the sidecar just removes any ambiguity.

## Import on the device

Two ways, once the app is installed:

1. **In-app picker** — Settings → Windows 95 / Windows 3.1 → *Import image*.
   Accepts `.img`, `.vhd`, `.ima`, or a `.zip` holding a disk plus an optional
   `.geometry`. The file is copied into the right folder, so nothing has to be
   named or placed by hand.
2. **Files app** — because the app declares `UIFileSharingEnabled` and
   `LSSupportsOpeningDocumentsInPlace`, *On My iPhone → Retronaut* shows the
   Documents folder. Drop the image into `os/win95/` (create the folder if it is
   not there) using exactly the names above.

Either route ends in the same place; the in-app picker is just harder to get
wrong.

## Verification

After setting a disk up, Settings shows the OS as ready. If a pack boots to a
DOS prompt instead of Windows, the disk is a bare DOS disk — Windows 3.1 in that
state still needs its Setup run from `install/`.

The app writes a launch log for every start: Settings → Diagnostics → *Launch
log*. It records the mounted drives and the exact script the emulated machine ran.
