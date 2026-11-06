#!/bin/bash
# Local development: builds SimBar.app, then installs ~/.claude/bin/sim-lease (a copy) and
# ~/Applications/SimBar.app, quitting the running SimBar first. Relaunch it with:
#   open ~/Applications/SimBar.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./build.sh

# a real copy (not a symlink into ~/Documents), so SimBar never triggers the Documents privacy prompt
mkdir -p "$HOME/.claude/bin"
rm -f "$HOME/.claude/bin/sim-lease"
install -m 755 bin/sim-lease "$HOME/.claude/bin/sim-lease"
echo "Installed $HOME/.claude/bin/sim-lease"

mkdir -p "$HOME/Applications"
pkill -x SimBar 2>/dev/null || true
rm -rf "$HOME/Applications/SimBar.app"
ditto build/SimBar.app "$HOME/Applications/SimBar.app"
echo "Installed $HOME/Applications/SimBar.app"
