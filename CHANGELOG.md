# Changelog

All notable changes to the packaging (not to Factorio itself) are recorded here.
Image tags track upstream Factorio versions; this file tracks the image.

## [Unreleased]

### Added
- Initial release: multi-arch (`linux/amd64`, `linux/arm64`) headless server images.
- Automatic builds on every upstream stable and experimental release.
- Per-release architecture probing, so a channel without an arm64 build publishes
  an amd64-only manifest instead of failing.
- Environment-driven `server-settings.json`, map-gen and player-list rendering.
- Dependency-free healthcheck that verifies the server is bound to the game port.
- SBOM and signed build provenance on published images.
