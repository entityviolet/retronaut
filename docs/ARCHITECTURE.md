# Architecture

```
 SwiftUI views  ─────────────┐
   LibraryView, StoreView    │
                             v
                     GameRunner  ──────►  disk images (FAT16), mounts, launch log
                             │
                     DosCoreHost  ──────►  libretro-style core (dlopen)
                             │                     │
                     DosCoreRender  ◄──────────────┘  video frames
                             │
                        Metal / CALayer
```

## Layers

- **Views** — library, import, store, settings, pause menu. No emulation logic.
- **GameRunner** — decides which core a pack needs, prepares the working
  directory, mounts the game drive and the optional CD image, and starts the
  core with the right environment.
- **DosCoreHost / DosCoreCallbacks** — the libretro ABI: environment callbacks,
  video/audio/input plumbing, save states.
- **DosCoreRender** — converts the core's pixel formats (16-bit 555/565, 32-bit)
  into a texture without extra copies.
- **GameLibrary / LibraryStore / StateStore** — library model, persisted to disk.
- **NetLobby** — small LAN lobby on top of Network.framework for IPX-era
  multiplayer.

## Design rules

1. **Cores are replaceable artefacts.** The app must never require a specific
   core build; it probes capabilities through the environment callback.
2. **No game data in the binary.** Everything the emulator needs comes from the
   pack the user imported.
3. **The host stays alive.** A crashing core must not take the app down; the
   host guards unload paths and logs to `retronaut.log`.
