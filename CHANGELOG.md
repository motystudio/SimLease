# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-11-06

Initial public release.

### Added

- `sim-lease` script: Claude Code sessions lease an iOS simulator or Android emulator instead of booting their own. A session gets the device it already holds, otherwise an idle booted one, otherwise a new one under a per-platform cap (`acquire` exits with code 3 when every device is in use; `--wait` retries).
- Leases follow session activity (the transcript's modification time): idle or released devices stay warm for reuse during a grace period, then are shut down.
- Pinned devices are never shut down automatically.
- Devices started by hand are left alone by default; `SIM_LEASE_ADOPT_UNMANAGED=1` shuts them down after a grace period.
- `sim-lease config`, `config json`, `config set KEY VALUE` and `config reset [KEY]` to read and change the settings in `~/.claude/sim-lease.conf`; `sim-lease version`.
- SimBar menu bar app: booted devices with RAM and CPU per device, the session holding each one with a click to open it, show the device, pin, shut down, and a cleanup every 5 minutes. English and French interface.
- Setup assistant on first launch: checks requirements, installs the script into `~/.claude/bin`, adds the `<simulators>` rule to `~/.claude/CLAUDE.md` and the `SessionEnd` hook to `~/.claude/settings.json` (with a backup), and offers launch at login, automatic updates and adoption of hand-started devices.
- Settings window (⌘,) for the sim-lease configuration.
- Automatic updates with Sparkle.
- Homebrew cask (`brew install --cask motystudio/tap/simlease`), signed and notarized universal build (Apple silicon and Intel).

[Unreleased]: https://github.com/motystudio/SimLease/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/motystudio/SimLease/releases/tag/v1.0.0
