# Contributing

Thanks for taking a look. A few ground rules keep this repository clean.

## Never commit

- game data, box art, ROMs, `.iso`, `.img`, `.zip` packs
- emulator binaries (`.dylib`) or Apple SDKs
- signing material (`.p12`, `.mobileprovision`) or credentials
- personal IPs, tunnel URLs or tokens

The `.gitignore` enforces most of this; do not bypass it.

## Pull requests

1. One topic per PR, small and reviewable.
2. Swift code: `swift build` must pass; keep the existing style, no new
   dependencies without discussion.
3. Update `CHANGELOG.md` under *Unreleased*.
4. Describe **what you changed and how you verified it** — "it compiles" is not
   verification for a change that touches core loading or disk images.

## Bug reports

Include: device model, iOS version, core and version, the pack's `game.json`
(with any personal paths removed), and what the app did versus what you expected.

## Licence of contributions

Retronaut is GPL-3.0-or-later. By opening a pull request you agree that your
contribution is licensed under the same terms. Only submit code you have the
right to license that way.
