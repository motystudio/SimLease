# Sourced by build.sh and scripts/release.sh: the pinned Sparkle release and how to fetch it.
# To upgrade: change both values (sha256 of Sparkle-<ver>.tar.xz from the GitHub release page).
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

# Expects ROOT (repo root). Sets SPARKLE_DIR to vendor/Sparkle-<ver>, downloading and checking it once.
fetch_sparkle() {
  SPARKLE_DIR="$ROOT/vendor/Sparkle-$SPARKLE_VERSION"
  [[ -d "$SPARKLE_DIR/Sparkle.framework" ]] && return 0

  local url="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  local tmp
  tmp=$(mktemp -d)
  echo "Downloading Sparkle $SPARKLE_VERSION..."
  curl -fsSL --retry 3 -o "$tmp/sparkle.tar.xz" "$url"
  local got
  got=$(shasum -a 256 "$tmp/sparkle.tar.xz" | awk '{print $1}')
  if [[ "$got" != "$SPARKLE_SHA256" ]]; then
    echo "error: Sparkle checksum mismatch (expected $SPARKLE_SHA256, got $got)" >&2
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$tmp/x"
  tar -xJf "$tmp/sparkle.tar.xz" -C "$tmp/x"
  mkdir -p "$ROOT/vendor"
  rm -rf "$SPARKLE_DIR"
  mv "$tmp/x" "$SPARKLE_DIR"
  rm -rf "$tmp"
}
