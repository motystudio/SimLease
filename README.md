# SimLease

Share iOS simulators and Android emulators between parallel Claude Code sessions, without them piling up.

- **`bin/sim-lease`**: each session "leases" a device instead of booting a new one. The script reuses an idle booted device, boots a new one only under a cap, and shuts down devices nobody is using.
- **`app/SimBar.swift`**: a menu bar app (in English, or French if that is the system's first language) that shows:
  - the booted devices, with the RAM and CPU of each one;
  - which session is using them: clicking the name and description opens that session;
  - clicking the phone icon shows the simulator (Android: the emulator's window; iOS: Simulator.app, or DeviceHub since Xcode 27, which can't be told which device to show);
  - a button to shut a device down, and a pin to **keep a device alive**: it is then never shut down automatically.

  It also runs the cleanup every 5 minutes. If its icon is hidden in the menu bar, launching the app again opens the panel in a window.

## Installation

```bash
./build.sh          # installs ~/.claude/bin/sim-lease (a copy) and ~/Applications/SimBar.app
open ~/Applications/SimBar.app
```

Then, in SimBar, **⚙ → Setup** lists whichever of these is missing or out of date, and installs it in one click: the script, the `<simulators>` rule in `~/.claude/CLAUDE.md`, and the `SessionEnd` hook. An orange dot on the gear means something is missing; the section is hidden when everything is in place. The app bundles its own copy of `bin/sim-lease` and `CLAUDE.snippet.md`. The hook is added with `jq`, leaving the rest of `settings.json` untouched, and a backup is saved as `settings.json.backup-simbar`.

To add the hook by hand, append this to `hooks.SessionEnd`:

```json
{ "hooks": [{ "type": "command", "command": "$HOME/.claude/bin/sim-lease release-session", "timeout": 30 }] }
```

Run `./build.sh` again after every change to `bin/sim-lease`. The installed script is a copy rather than a symlink because a link into `~/Documents` makes macOS ask SimBar for access to the Documents folder.

## How it works

| Situation | What happens |
|---|---|
| A session calls `sim-lease acquire ios` | It gets the device it already holds, otherwise an idle booted device, otherwise a new one (if under the cap) |
| The session is active | Its device stays reserved for it (activity = last modification of the session's transcript) |
| The session has been idle for 20 min, or calls `release` | The device stays on for 10 min so another session can reuse it, then it is shut down |
| A device was booted outside sim-lease | It is shut down after 30 min unless a session leases it |
| A device is pinned (`sim-lease pin ID`) | It is never shut down automatically, only by hand |
| Every device is busy | `acquire` exits with code 3; retry with `--wait 300` |

Physical devices are never touched.

## Settings

In `~/.claude/sim-lease.conf`:

```bash
SIM_LEASE_MAX_IOS=3
SIM_LEASE_MAX_ANDROID=2
SIM_LEASE_STALE_MIN=20
SIM_LEASE_GRACE_MIN=10
SIM_LEASE_ADOPT_UNMANAGED=1        # 0 = never shut down devices started by hand
SIM_LEASE_UNMANAGED_GRACE_MIN=30
```

## Commands

```
sim-lease acquire ios|android [--name NAME] [--wait SECS]
sim-lease release [ID]
sim-lease status | json
sim-lease kill ID
sim-lease pin|unpin ID
sim-lease shutdown-idle
sim-lease reap
```

App debugging: `SimBar --setup DIR` tests the installation against a stand-in for `~/.claude`, and `build/SimBar.app/Contents/MacOS/SimBar --snapshot out.png` renders the panel with live data (some buttons show up as yellow squares, which is an `ImageRenderer` limitation).
