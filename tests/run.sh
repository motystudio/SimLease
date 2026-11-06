#!/bin/bash
# Regression tests for bin/sim-lease. Self-contained: a sandboxed HOME and stub xcrun /
# xcode-select / adb / emulator that serve canned device lists and only log what they're
# asked to do. Never touches a real simulator or emulator. Usage: tests/run.sh
cd "$(dirname "$0")/.." || exit 1
SCRIPT=${SIM_LEASE:-$PWD/bin/sim-lease}   # SIM_LEASE=path: test another copy
T=$(mktemp -d); trap 'pkill -P $$ 2>/dev/null; rm -rf "$T"' EXIT
S=$T/state H=$T/home ME=me-session X=""
D=$H/.claude/sim-leases LOCK=$H/.claude/sim-leases/.lock
mkdir -p "$T/bin" "$T/sdk/platform-tools" "$T/sdk/emulator" "$S/Xcode/Contents/Developer/Platforms/iPhoneSimulator.platform"
U1=11111111-1111-1111-1111-111111111111 U2=22222222-2222-2222-2222-222222222222

cat > "$T/bin/xcode-select" <<'EOF'
#!/bin/bash
[ -f "$SL_STATE/noxcode" ] && exit 2; echo "$SL_STATE/Xcode/Contents/Developer"
EOF
cat > "$T/bin/xcrun" <<'EOF'
#!/bin/bash
S=$SL_STATE; echo "xcrun $*" >> "$S/calls"
[ "$1" = -f ] && { echo /stub/simctl; exit 0; }
[ "$1" = simctl ] && shift
set_state() { awk -F'\t' -v OFS='\t' -v u="$1" -v st="$2" '$1==u{$3=st}1' "$S/ios" > "$S/ios.t"; mv "$S/ios.t" "$S/ios"; }
case "$1 $2" in
  "list devices") /usr/bin/jq -Rn --arg b "$3" '[inputs | split("\t") | {udid:.[0], name:.[1], state:.[2], isAvailable:true}]
      | (if $b == "booted" then map(select(.state == "Booted")) else . end) | {devices: {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": .}}' < "$S/ios" ;;
  "boot "*) set_state "$2" Booted ;;
  "bootstatus "*) while [ -f "$S/hang" ]; do sleep 0.2; done ;;
  "shutdown "*) set_state "$2" Shutdown ;;
esac
EOF
cat > "$T/sdk/platform-tools/adb" <<'EOF'
#!/bin/bash
S=$SL_STATE; echo "adb $*" >> "$S/calls"
if [ "$1" = devices ]; then echo "List of devices attached"; awk -F'\t' 'NF {print $1 "\tdevice"}' "$S/android"; exit 0; fi
s=$2; shift 2
case "$*" in
  "emu avd name") awk -F'\t' -v s="$s" '$1==s {print $2; print "OK"}' "$S/android" ;;
  "emu kill") grep -v "^$s	" "$S/android" > "$S/a.t"; mv "$S/a.t" "$S/android" ;;
  "shell getprop sys.boot_completed") echo 1 ;;
esac
EOF
cat > "$T/sdk/emulator/emulator" <<'EOF'
#!/bin/bash
S=$SL_STATE; echo "emulator $*" >> "$S/calls"
[ "$1" = -list-avds ] && cat "$S/avds"
[ "$1" = -avd ] && printf 'emulator-%s\t%s\n' $((5554 + 2 * $(grep -c . "$S/android"))) "$2" >> "$S/android"
EOF
chmod +x "$T/bin/"* "$T/sdk/platform-tools/adb" "$T/sdk/emulator/emulator"

sl() { env -i HOME="$H" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" ANDROID_HOME="$T/sdk" SL_STATE="$S" \
  CLAUDE_CODE_SESSION_ID="$ME" SIM_LEASE_ADOPT_UNMANAGED=0 $X /bin/bash "$SCRIPT" "$@"; }
run_to() { # secs cmd... -> runs sl in the background, 124 if still running after secs (then killed)
  local s=$1 p i; shift; sl "$@" > "$T/out" 2> "$T/err" & p=$!
  for ((i = 0; i < s * 10; i++)); do kill -0 $p 2>/dev/null || break; sleep 0.1; done
  if kill -0 $p 2>/dev/null; then pkill -P $p; kill $p; wait $p 2>/dev/null; return 124; fi
  wait $p
}
reset() { # ios lines "udid name state", android lines "serial avd"
  rm -rf "$D" "$H/.claude/projects" "$S/hang" "$S/noxcode"; mkdir -p "$D" "$H/.claude/projects/p"; X=""; : > "$S/calls"
  printf '%s\n' "$U1	iPhone 17 Pro	Booted" "$U2	iPhone 17	Shutdown" > "$S/ios"; : > "$S/android"; printf 'Pixel_A\nPixel_B\n' > "$S/avds"
}
ago() { local m=$1; shift; touch -t "$(date -r $(( $(date +%s) - m * 60 )) +%Y%m%d%H%M.%S)" "$@"; }   # minutes file...
lease() { # id platform name session [minutes ago] [released_at]
  printf 'platform=%s\nname=%s\nsession=%s\nsince=%s\nreleased_at=%s\nhost=\n' "$2" "$3" "$4" $(( $(date +%s) - ${5:-0} * 60 )) "${6:-}" > "$D/$1"
  ago "${5:-0}" "$D/$1"
}
transcript() { mkdir -p "$(dirname "$H/.claude/projects/p/$1")"; touch "$H/.claude/projects/p/$1"; ago "${2:-0}" "$H/.claude/projects/p/$1"; }   # path [minutes ago]
jf() { sl json | /usr/bin/jq -r "$1"; }   # json field query
pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

echo "== syntax"; check "bash -n" "bash -n '$SCRIPT'"

echo "== 1. activity: transcript, subagents, lease since/mtime, acquire refresh"
reset; lease $U1 ios "iPhone 17 Pro" other 0
check "lease without transcript is live right after acquire" '[ "$(jf ".[0].live")" = true ] && [ "$(jf ".[0].shutdownInMin")" = -1 ]'
X=SIM_LEASE_MAX_IOS=1; run_to 5 acquire ios; rc=$?
check "another session can't take it (cap reached -> exit 3)" '[ $rc = 3 ] && grep -q "session=other" "$D/$U1"'
X=""; sl reap; check "reap keeps it" '! grep -q "shutdown $U1" "$S/calls"'
reset; lease $U1 ios "iPhone 17 Pro" other 25; sl reap
check "25 min idle, no transcript: not live, not shut down yet" '[ "$(jf ".[0].live")" = false ] && ! grep -q "shutdown $U1" "$S/calls"'
reset; lease $U1 ios "iPhone 17 Pro" other 31; sl reap
check "31 min idle (stale 20 + grace 10): shut down" 'grep -q "shutdown $U1" "$S/calls"'
reset; lease $U1 ios "iPhone 17 Pro" other 40; transcript other.jsonl 40; transcript other/subagents/agent-a1.jsonl 1
check "fresh subagent transcript keeps the lease live" '[ "$(jf ".[0].live")" = true ]'
reset; lease $U1 ios "iPhone 17 Pro" other 40; transcript other/subagents/agent-a1.jsonl 1
check "subagent transcript found without a main transcript" '[ "$(jf ".[0].live")" = true ]'
reset; lease $U1 ios "iPhone 17 Pro" $ME 15; transcript $ME.jsonl 15
out=$(sl acquire ios 2>/dev/null)
check "re-acquire returns the held device and touches the lease" '[ "$out" = $U1 ] && [ $(( $(date +%s) - $(stat -f %m "$D/$U1") )) -lt 5 ]'
reset; sl acquire ios > /dev/null 2> "$T/err1"; sl acquire ios > /dev/null 2> "$T/err2"
check "missing transcript: one warning, once" 'grep -q "transcript wasn.t found" "$T/err1" && ! grep -q warning "$T/err2"'
reset; transcript $ME.jsonl 0; sl acquire ios > /dev/null 2> "$T/err1"
check "no warning when the transcript exists" '! grep -q warning "$T/err1"'

echo "== 2. stale leases: serial/UDID now runs another device, device gone"
reset; printf 'emulator-5554\tPixel_B\n' > "$S/android"; lease emulator-5554 android Pixel_A other 0; transcript other.jsonl 0
check "json: lease of another AVD on the same serial is ignored" '[ "$(jf ".[] | select(.id==\"emulator-5554\") | .session")" = "" ]'
check "json dropped that lease" '[ ! -f "$D/emulator-5554" ]'
lease emulator-5554 android Pixel_A none 60 1; sl reap
check "reap (adopt off) doesn't kill a hand-started emulator" '! grep -q "emu kill" "$S/calls" && [ ! -f "$D/emulator-5554" ]'
lease emulator-5554 android Pixel_A other 0; out=$(sl acquire android 2>/dev/null)
check "acquire takes the hand-started emulator, leased under its real AVD" '[ "$out" = emulator-5554 ] && grep -q "name=Pixel_B" "$D/emulator-5554"'
reset; lease $U1 ios "iPhone 15" other 0; lease $U2 ios "iPhone 17" other 0; sl json > /dev/null
check "json drops iOS lease with another name and leases of shut down devices" '[ ! -f "$D/$U1" ] && [ ! -f "$D/$U2" ]'
reset; lease $U1 ios "iPhone 15" other 0; lease $U2 ios "iPhone 17" other 0; sleep 300 & L=$!; mkdir "$LOCK"; echo $L > "$LOCK/pid"
run_to 5 json; rc=$?
check "json doesn't wait for a busy lock, nor clean up, nor touch the lock" '[ $rc = 0 ] && [ -f "$D/$U1" ] && [ "$(cat "$LOCK/pid")" = $L ]'
check "json still ignores the mismatched lease" '[ "$(/usr/bin/jq -r ".[0].session" "$T/out")" = "" ]'
kill $L; wait $L 2>/dev/null; rm -rf "$LOCK"
reset; lease $U1 ios "iPhone 17 Pro" other 0; transcript other.jsonl 0
check "json keys unchanged" '[ "$(jf ".[0] | keys | join(\",\")")" = "host,id,lastActive,live,name,pinned,platform,session,shutdownInMin" ]'

echo "== 3. acquire --name of a device held by another live session"
reset; lease $U1 ios "iPhone 17 Pro" other 0; transcript other.jsonl 0
run_to 5 acquire ios --name "iPhone 17 Pro"; rc=$?
check "iOS: exit 3, nothing booted" '[ $rc = 3 ] && grep -q "is in use" "$T/err" && ! grep -q "simctl boot" "$S/calls"'
printf '%s\n' "$U2	iPhone 17 Pro	Shutdown" >> "$S/ios"; sed -i '' "/^$U2	iPhone 17	/d" "$S/ios"
out=$(sl acquire ios --name "iPhone 17 Pro" 2>/dev/null)
check "iOS: boots another shutdown simulator with that name" '[ "$out" = $U2 ] && grep -q "simctl boot $U2" "$S/calls"'
reset; printf 'emulator-5554\tPixel_A\n' > "$S/android"; lease emulator-5554 android Pixel_A other 0; transcript other.jsonl 0
run_to 5 acquire android --name Pixel_A; rc=$?
check "Android: exit 3, no boot" '[ $rc = 3 ] && ! grep -q "emulator -avd" "$S/calls"'
run_to 15 acquire android --name Pixel_A --wait 5; rc=$?
check "--wait is honoured, then exit 3" '[ $rc = 3 ]'

echo "== 4. lock ownership, boot timeout"
reset; bash -c 'exit 0' & d=$!; wait $d; mkdir "$LOCK"; echo $d > "$LOCK/pid"
run_to 5 reap; rc=$?; check "lock of a dead PID is broken" '[ $rc = 0 ] && [ ! -d "$LOCK" ]'
reset; sleep 300 & L=$!; mkdir "$LOCK"; ago 30 "$LOCK"; echo $L > "$LOCK/pid"; ago 30 "$LOCK"
run_to 3 reap; rc=$?; check "old lock of a live PID is not broken" '[ $rc = 124 ] && [ "$(cat "$LOCK/pid")" = $L ]'
kill $L; wait $L 2>/dev/null; rm -rf "$LOCK"
reset; mkdir "$LOCK"; ago 11 "$LOCK"; run_to 5 reap; rc=$?; check "PID-less lock older than 10 min is broken" '[ $rc = 0 ] && [ ! -d "$LOCK" ]'
reset; mkdir "$LOCK"; run_to 2 reap; rc=$?; check "fresh PID-less lock is kept" '[ $rc = 124 ] && [ -d "$LOCK" ]'
reset; sed -i '' "s/	Booted$/	Shutdown/" "$S/ios"; transcript $ME.jsonl 0; touch "$S/hang"
sl acquire ios > "$T/out" 2>&1 & A=$!
for i in $(seq 50); do grep -q bootstatus "$S/calls" && break; sleep 0.1; done
sleep 300 & L=$!; echo $L > "$LOCK/pid"; rm "$S/hang"; wait $A
check "EXIT trap leaves a lock that isn't ours" '[ "$(cat "$LOCK/pid" 2>/dev/null)" = $L ]'
kill $L; wait $L 2>/dev/null; rm -rf "$LOCK"
reset; sed -i '' "s/	Booted$/	Shutdown/" "$S/ios"; transcript $ME.jsonl 0; touch "$S/hang"; X=SIM_LEASE_BOOT_TIMEOUT_SEC=2
run_to 10 acquire ios; rc=$?
check "iOS boot wait times out with a clear message, lock released" '[ $rc = 1 ] && grep -q "did not finish booting" "$T/err" && [ ! -d "$LOCK" ]'

echo "== 5. lowercase UDID, no Xcode, SDK paths"
reset; U3=ABCDEF01-2345-6789-ABCD-EF0123456789; printf '%s\tiPad\tBooted\n' $U3 >> "$S/ios"; sl kill $(echo $U3 | tr A-F a-f) > /dev/null
check "kill with a lowercase UDID goes to simctl" 'grep -q "simctl shutdown $U3" "$S/calls" && ! grep -q "^adb -s" "$S/calls"'
reset; sl pin "aaaaaaaa-1111-1111-1111-111111111111" > /dev/null
check "pin with a lowercase UDID is an iOS pin (uppercased)" 'grep -qx "AAAAAAAA-1111-1111-1111-111111111111" "$D/.pinned"'
reset; touch "$S/noxcode"; printf 'emulator-5554\tPixel_A\n' > "$S/android"; sl json > "$T/out"; sl status > /dev/null; sl reap
check "no Xcode: json/status/reap never run xcrun" '! grep -q xcrun "$S/calls" && [ "$(/usr/bin/jq -r "map(.platform) | join(\",\")" "$T/out")" = android ]'
check "Intel Homebrew Android SDK is searched" 'grep -q /usr/local/share/android-commandlinetools "$SCRIPT"'

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
