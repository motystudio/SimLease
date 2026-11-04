<simulators>
## Simulators & emulators (shared across all sessions)

Several Claude sessions run in parallel on this Mac. Never boot an iOS simulator or Android emulator yourself (`xcrun simctl boot`, `emulator -avd`, `open -a Simulator`, `flutter emulators --launch`, a tool's "boot" action…). Always go through `~/.claude/bin/sim-lease`, which reuses an idle booted device, boots one only under the cap, and lets idle ones get shut down automatically.

- Get a device: `ID=$(~/.claude/bin/sim-lease acquire ios)` or `acquire android` (add `--name "iPhone 17 Pro"` / `--name Calqo_Phone` if the project needs a specific one). It prints the UDID / adb serial. Use **only that ID** for everything: `flutter run -d $ID`, `xcrun simctl install $ID …`, `adb -s $ID …`, Maestro/mobile-mcp `device_id`, the desktop iOS Simulator tool's `device`.
- Call `acquire` again later in the session: it returns the same device you already hold (it is idempotent). Don't switch to another booted device that isn't yours — another session may be using it.
- Exit code 3 = every device is busy. Retry with `--wait 300`, don't bypass the cap.
- When you are done with the device (task finished, before your final message), run `~/.claude/bin/sim-lease release`. It stays warm 10 min for another session, then is shut down.
- Never shut down a device you didn't lease, and never touch physical devices.
- `~/.claude/bin/sim-lease status` shows who holds what.
</simulators>
