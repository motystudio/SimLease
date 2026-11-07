<simulators>
## Simulators & emulators (shared across all sessions)

Test on a simulator or emulator as often as you otherwise would: whenever running the app would verify your work, run it. This rule only changes how you get a device, never whether to use one, and getting one usually takes seconds. Don't skip or shorten a test because of it.

Several Claude sessions run in parallel on this Mac, so get every device from `~/.claude/bin/sim-lease` instead of booting it directly (`xcrun simctl boot`, `emulator -avd`, `open -a Simulator`, `flutter emulators --launch`, a tool's "boot" action…). It reuses an idle booted device, boots a new one when needed up to a cap, and lets idle ones get shut down automatically.

- Get a device: `ID=$(~/.claude/bin/sim-lease acquire ios)` or `acquire android`. Without `--name`, iOS gives an iPhone; add `--name "iPad Air 11-inch (M3)"` / `--name Pixel_9_API_35` if the project needs a specific device. It prints the UDID / adb serial. A cold boot can take a few minutes: run it with a long tool timeout (up to 10 minutes), not the default. Use **only that ID** for everything: `flutter run -d $ID`, `xcrun simctl install $ID …`, `adb -s $ID …`, Maestro/mobile-mcp `device_id`, the desktop iOS Simulator tool's `device`.
- Call `acquire` again later in the session: it returns the same device you already hold (it is idempotent) and refreshes your lease, so also re-run it before a long build or test run. Don't switch to another booted device that isn't yours: another session may be using it.
- Exit code 3 = no device is free. Retry with `--wait 300` and a long tool timeout. If that fails too, or `acquire` fails for another reason, tell the user the test is blocked and why (they can raise the cap or shut a device down): don't drop the test silently, and don't bypass the cap.
- When you are done with the device, run `~/.claude/bin/sim-lease release`, unless the user may want to look at the app or ask for a follow-up: then keep it, the lease expires on its own once the session goes idle. A released device stays warm for a while (`SIM_LEASE_GRACE_MIN`, 10 min by default) for another session, then is shut down.
- Never shut down a device you didn't lease, and never touch physical devices.
- `~/.claude/bin/sim-lease status` shows who holds what.
</simulators>
