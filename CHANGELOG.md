# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-11-17

First public release.

### Added

- The DOSBox Pure and ScummVM cores ship with the app: they are stored in
  `Sources/Retronaut/Resources/Cores/` (tracked with Git LFS) and copied into the
  app bundle at build time.
- Initial public snapshot: SwiftUI library, DOSBox Pure and ScummVM core hosting,
  pack import/export, Windows disk-image packs, CD mounting, local store,
  LAN lobby.
