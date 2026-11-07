# Contributing

Issues and pull requests are welcome. Please keep changes small and focused.

## Build

```bash
./build.sh                    # build/SimBar.app, universal, ad-hoc signed
scripts/install-local.sh      # install it locally to try it
```

The app bundles `bin/sim-lease` and `CLAUDE.snippet.md`; rebuild after changing either.

## Testing without touching your real devices

- `SimBar --setup DIR` runs the setup check and install against `DIR` instead of `~/.claude`, so the real `CLAUDE.md` and `settings.json` are never modified.
- `build/SimBar.app/Contents/MacOS/SimBar --snapshot out.png` renders the panel to a PNG and exits.
- `sim-lease status`, `json`, `config` and `version` only read. `acquire`, `reap`, `kill` and `shutdown-idle` act on the simulators and emulators that are really booted, so try them with no other session running, or on a throwaway simulator.
- To simulate a session from a terminal, set a made-up session ID: `CLAUDE_CODE_SESSION_ID=test-1 bin/sim-lease acquire ios`, then `CLAUDE_CODE_SESSION_ID=test-1 bin/sim-lease release`. Environment variables override `~/.claude/sim-lease.conf`, so caps and delays can be set per command without editing your config.
- Never write code that touches physical devices: only simulators and `emulator-*` serials are in scope.

## Style

- `bin/sim-lease` is bash, kept POSIX-ish and compact: no dependencies beyond what macOS ships (`/usr/bin/jq`, `xcrun`) and the Android SDK tools. Short functions, one-line comments where the why is not obvious.
- SimBar is SwiftUI, split by area in `app/`: `SimBar.swift` (app entry), `Model.swift`, `Panel.swift`, `Setup.swift`, `InstallProgress.swift`, `Onboarding.swift`, `SettingsView.swift`, `Config.swift`, `Updater.swift`. `build.sh` compiles every `app/*.swift`.
- Every user-facing string in SimBar is bilingual: `L("English", "Français")`.
- Code, comments, docs and commit messages are in English.
- Add a line to `CHANGELOG.md` under `[Unreleased]` for user-visible changes.
