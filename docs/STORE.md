# Store and pack hosting

The store is a **static folder** with a JSON catalogue. Any web server can host
it — a laptop on the same Wi-Fi, a NAS, Nginx, an S3/R2 bucket, GitHub Pages. The
app downloads `store.json`, shows the shelf, and installs a pack by downloading
its zip and importing it like a local pack.

```
<root>/
  store.json          catalogue
  packs/<name>.zip    one zip per game (same format as an imported pack)
  covers/<id>.jpg     optional box art, referenced from store.json
```

## Linking the app

Store screen → **Store link** (the button with the chain icon) → paste → **Test
link**. Accepted forms:

| You paste | The app uses |
|---|---|
| `192.168.1.20:8087` | `http://192.168.1.20:8087/` |
| `192.168.1.20:8087/store.json` | `http://192.168.1.20:8087/` |
| `https://packs.example.com/retro/` | unchanged |

The last six links are kept as history, so switching between a home server and a
remote one is two taps. Plain **HTTP is allowed** — the app sets
`NSAllowsArbitraryLoads`, so a LAN URL without TLS works. HTTPS works too, and is
what you want the moment the server is not on your own network.

## store.json

```json
{
  "name": "Home Shelf",
  "updated": "2026-11-17",
  "featured": ["doom", "monkey1"],
  "packs": [
    {
      "id": "doom",
      "title": "DOOM",
      "year": 1993,
      "genre": "Shooter",
      "developer": "id Software",
      "system": "DOS",
      "tagline": "Rip and tear, at 35 fps.",
      "blurb": "Short line for the card.",
      "details": "Longer text for the detail screen.",
      "size_mb": 12,
      "cover": "covers/doom.jpg",
      "pack": "packs/doom.zip",
      "added": "2026-11-01",
      "players": "1",
      "tags": ["fps", "classic"]
    }
  ]
}
```

Required per pack: `id`, `title`, `year`, `pack`. Everything else is optional.

- `pack` and `cover` are **relative to the store root** (see the example) — or
  absolute URLs if you host them elsewhere.
- `size_mb` is only a hint for the progress bar; the real size is whatever the
  download returns.
- `featured` (top-level) or `"featured": true` (per pack) picks the hero banner;
  with neither, the richest entries are used.
- `added` shows a NEW badge for 30 days.

The zip must be a valid pack — `game.json` plus the game files, the same thing
the importer accepts locally. Keep each zip under 4 GB unless you also make it a
ZIP64 archive, and never password-protect it.

## Serving it

### Laptop or NAS on the LAN

```bash
python3 -m http.server 8087 --directory /path/to/store
```

Then in the app: `192.168.1.20:8087`. This serves everything a download needs;
it does not support HTTP Range, so an interrupted download restarts from zero.

### Nginx (LAN or public)

```nginx
server {
    listen 8443 ssl;
    server_name packs.example.com;
    root /srv/retronaut-store;

    location / {
        autoindex off;
        gzip off;              # zips are already compressed
        add_header Accept-Ranges bytes;
    }
}
```

Range support matters for large packs: without it a dropped connection means the
whole download again.

### Remote

- **Cloudflare R2 / S3 / Backblaze** — upload the folder, make it public (or put
  it behind a signed URL prefix), point the app at the bucket URL. Cheapest way to
  serve 500 MB packs to other people.
- **GitHub Releases** — attach each zip as a release asset and use the asset URL
  in `pack`. Free, but not built for hotlinking and no directory listing.
- **GitHub Pages** — fine for `store.json` and covers; **not** for the zips,
  because of the 100 MB per-file limit.
- **Cloudflare Tunnel** — exposes a home server without opening ports:
  `cloudflared tunnel --url http://127.0.0.1:8087` gives you an HTTPS hostname you
  can paste in the app.

## Installing from the store

Tap a title → **Install**. The app downloads to a temp file, shows progress (and
can cancel), then unpacks it with the same importer used for local packs, so the
result appears in the library like anything else. The store remembers which pack
became which library game, which is why an installed title shows INSTALLED even
if its `meta.json` renames it.

## Verifying before you publish

```bash
curl -s http://192.168.1.20:8087/store.json | python3 -m json.tool | head -20
curl -sI http://192.168.1.20:8087/packs/doom.zip | head -3
curl -sI http://192.168.1.20:8087/covers/doom.jpg | head -3
```

All three should answer `200`. Then use **Test link** in the app: it reports the
store's `name` and how many packs it found.

## Common problems

| Symptom | Cause |
|---|---|
| Test link: “store.json answered 404” | the URL points one level too high or too low — it must be the folder that holds `store.json` |
| Catalogue loads, covers blank | `cover` paths are wrong, or the images are not `.jpg`/`.png` |
| Install fails immediately | `pack` path wrong, or the zip is not a valid pack (no `game.json`) |
| Install crawls on a big pack | no Range support on the server, or a slow uplink |
| Everything works on Wi-Fi, not on cellular | the URL is a LAN address — use a tunnel or a public host |
