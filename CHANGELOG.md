# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.1] - 2026-11-07

### Changed

- The default device limits now follow the Mac's memory instead of a fixed 3 iOS and 2 Android: 2 and 1 up to 36 GB, 5 and 2 with 64 GB, 10 and 4 with 128 GB. The setup assistant and Settings show the suggestion, and a value you set yourself always wins.

### Added

- `acquire --name` makes another simulator with that name when all of them are taken and a slot is free or can be freed. It starts empty, `acquire` says so, and it stays available for later sessions.
- Installing from the gear menu opens a window that shows each step with a check mark once it is done, and the error of a step that failed.

### Fixed

- Opening Settings no longer crashes SimBar.
- `sim-lease version` reported 1.0.0 in the 1.1.0 release. The tests and the release script now check that it matches `VERSION`.

## [1.1.0] - 2026-11-07

### Changed

- The `<simulators>` rule now opens by saying it never reduces how often to test, tells sessions to report a blocked test instead of dropping it, and lets them keep a device the user may want to look at. An unedited rule is updated by SimBar.
- A boot no longer holds up other sessions' `acquire`: a session refreshing its lease or reusing an idle device gets an answer right away.
- `acquire --name` shuts down a released device kept warm when it fills the last slot under the cap, instead of exiting with code 3. Pinned devices, hand-started devices and those of idle sessions are left alone.

### Fixed

- `acquire` without `--name` no longer hands back an idle iPad or Apple Watch for iOS.
- The exit code 3 message no longer claims that idle devices are in use by other sessions.
- `acquire --name` with a device that doesn't exist fails with an error saying so, instead of exit code 3 when the cap is reached.
- `acquire` with every device busy under the cap exits with code 3 and honours `--wait`, instead of failing with an error.
- `acquire` no longer hands back a simulator that was shut down during its boot.
- Android: when two emulators boot at once, `acquire` returns the one it started.

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

[Unreleased]: https://github.com/motystudio/SimLease/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/motystudio/SimLease/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/motystudio/SimLease/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/motystudio/SimLease/releases/tag/v1.0.0
