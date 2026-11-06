#!/bin/bash
# Builds, signs, notarizes and packages a SimBar release; optionally publishes it.
#
#   scripts/release.sh --dry-run              ad-hoc build, zip, cask; prints what it would notarize/publish
#   scripts/release.sh                        Developer ID build, notarize, staple, zip, appcast, cask in dist/
#   scripts/release.sh --publish              ...then tag v<version>, create the GitHub release, commit the cask in TAP_DIR
#   scripts/release.sh --publish --push-tap   ...and push the tap
#
# Environment:
#   SIMBAR_SIGN_IDENTITY  "Developer ID Application: Name (TEAMID)" (default: the first one in the keychain)
#   NOTARY_PROFILE        notarytool keychain profile (default: motystudio-notary, shared by every Moty Studio app)
#   SPARKLE_KEY_ACCOUNT   keychain account of the Sparkle EdDSA key (default: simlease)
#   SPARKLE_ED_KEY_FILE   use this private key file instead of the keychain
#   TAP_DIR               local checkout of motystudio/homebrew-tap (needed for --publish)
#
# The version comes from VERSION and the build number from BUILD_NUMBER (raise it for every
# release: Sparkle only offers higher builds). Optional release notes: packaging/release-notes/<version>.md
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/sparkle.sh

REPO=motystudio/SimLease
DRY_RUN=0 PUBLISH=0 PUSH_TAP=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --publish) PUBLISH=1 ;;
    --push-tap) PUSH_TAP=1 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option $arg (see --help)" >&2; exit 2 ;;
  esac
done
if [[ $PUSH_TAP == 1 && $PUBLISH == 0 ]]; then
  echo "error: --push-tap only makes sense with --publish" >&2; exit 2
fi

VERSION=$(tr -d '[:space:]' < VERSION)
TAG="v$VERSION"
ZIP_NAME="SimBar-$VERSION.zip"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"
NOTARY_PROFILE=${NOTARY_PROFILE:-motystudio-notary}
SPARKLE_KEY_ACCOUNT=${SPARKLE_KEY_ACCOUNT:-simlease}
PUBLIC_KEY_FILE=packaging/sparkle-public-key.txt
DIST="$ROOT/dist"

step() { printf '\n==> %s\n' "$*"; }
would() { printf '    [dry-run] would run: %s\n' "$*"; }

fetch_sparkle
GENERATE_KEYS="$SPARKLE_DIR/bin/generate_keys"
GK="${GENERATE_KEYS#"$ROOT"/}"   # as shown in messages, to run from the repo root

# --- preflight: report every missing prerequisite at once ------------------------------------
problems=()
add_problem() { problems+=("$1"); }

if [[ -z "${SIMBAR_SIGN_IDENTITY:-}" ]]; then
  SIMBAR_SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)
fi

preflight() {
  if [[ -n "$(git status --porcelain)" ]]; then
    add_problem "The working tree has uncommitted changes. Commit or stash them, so the release matches a commit."
  fi

  if [[ -z "$SIMBAR_SIGN_IDENTITY" ]]; then
    add_problem "No \"Developer ID Application\" signing certificate in your keychain.
     Create one (needs a paid Apple Developer Program membership, as Account Holder):
       Xcode > Settings > Accounts > select your Apple ID and team > Manage Certificates... > + > Developer ID Application
     Check with: security find-identity -v -p codesigning
     (If you have several, pick one with SIMBAR_SIGN_IDENTITY=\"Developer ID Application: Name (TEAMID)\".)"
  elif ! security find-identity -v -p codesigning | grep -qF "\"$SIMBAR_SIGN_IDENTITY\""; then
    add_problem "SIMBAR_SIGN_IDENTITY is not a valid signing identity in your keychain: $SIMBAR_SIGN_IDENTITY"
  fi

  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    add_problem "No working notarytool credentials profile named \"$NOTARY_PROFILE\".
     1. Create an app-specific password: https://account.apple.com > Sign-In and Security > App-Specific Passwords
     2. Store it (it prompts for that password):
          xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id you@example.com --team-id TEAMID
     (Use NOTARY_PROFILE=... to pick another profile name.)"
  fi

  local public_key="" keychain_key=""
  [[ -f "$PUBLIC_KEY_FILE" ]] && public_key=$(tr -d '[:space:]' < "$PUBLIC_KEY_FILE")
  if [[ -z "${SPARKLE_ED_KEY_FILE:-}" ]]; then
    keychain_key=$("$GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -p 2>/dev/null | tr -d '[:space:]' || true)
  fi
  if [[ -z "$public_key" ]]; then
    add_problem "No Sparkle public key in $PUBLIC_KEY_FILE (updates must be signed with an EdDSA key).
     1. Generate the key pair; the private key goes into your login keychain:
          $GK --account $SPARKLE_KEY_ACCOUNT
     2. Save the public key in the repo and commit it:
          $GK --account $SPARKLE_KEY_ACCOUNT -p > $PUBLIC_KEY_FILE
     3. Back up the private key somewhere safe, never in the repo (losing it means existing users stop getting updates):
          $GK --account $SPARKLE_KEY_ACCOUNT -x ~/sparkle-simlease-private-key.txt"
  elif [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
    [[ -r "$SPARKLE_ED_KEY_FILE" ]] || add_problem "SPARKLE_ED_KEY_FILE is not readable: $SPARKLE_ED_KEY_FILE"
  elif [[ -z "$keychain_key" ]]; then
    add_problem "No Sparkle private key in your keychain for account \"$SPARKLE_KEY_ACCOUNT\".
     Import your backup with: $GK --account $SPARKLE_KEY_ACCOUNT -f <private-key-file>
     (or set SPARKLE_ED_KEY_FILE, or SPARKLE_KEY_ACCOUNT if you used another account name)."
  elif [[ "$keychain_key" != "$public_key" ]]; then
    add_problem "The Sparkle key in your keychain (account \"$SPARKLE_KEY_ACCOUNT\") does not match $PUBLIC_KEY_FILE.
     keychain: $keychain_key
     file:     $public_key"
  fi

  if [[ $PUBLISH == 1 ]]; then
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
      add_problem "Tag $TAG already exists. Bump VERSION (and BUILD_NUMBER) first."
    fi
    if ! gh auth status >/dev/null 2>&1; then
      add_problem "The GitHub CLI is not logged in. Run: gh auth login"
    fi
    # Sparkle only offers an update whose build number is higher than the installed one
    local build last
    build=$(tr -d '[:space:]' < BUILD_NUMBER)
    last=$(curl -fsL "https://github.com/$REPO/releases/latest/download/appcast.xml" 2>/dev/null \
      | sed -n 's/.*<sparkle:version>\([0-9]*\)<\/sparkle:version>.*/\1/p' | sort -n | tail -1 || true)   # no release yet
    if [[ -n "$last" ]] && (( build <= last )); then
      add_problem "BUILD_NUMBER is $build but the last release is build $last. Raise BUILD_NUMBER above $last."
    fi
    # release assets of a private repo can't be downloaded by Sparkle or Homebrew
    for r in "$REPO" "${REPO%%/*}/homebrew-tap"; do
      if [[ "$(gh repo view "$r" --json visibility --jq .visibility 2>/dev/null)" != PUBLIC ]]; then
        add_problem "$r is not public: users could not download the release. Make it public first."
      fi
    done
    if [[ -z "${TAP_DIR:-}" ]]; then
      add_problem "TAP_DIR is not set. Clone the tap and point to it:
          git clone https://github.com/motystudio/homebrew-tap ~/Documents/Projects/homebrew-tap
          export TAP_DIR=~/Documents/Projects/homebrew-tap"
    elif ! git -C "$TAP_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      add_problem "TAP_DIR is not a git checkout: $TAP_DIR"
    elif [[ -n "$(git -C "$TAP_DIR" status --porcelain)" ]]; then
      add_problem "TAP_DIR has uncommitted changes: $TAP_DIR"
    fi
  fi
}

if [[ $DRY_RUN == 1 ]]; then
  step "Dry run of SimBar $VERSION: ad-hoc signed, nothing is notarized or published"
  IDENTITY="-"
else
  step "Checking release prerequisites for SimBar $VERSION"
  preflight
  if (( ${#problems[@]} )); then
    echo "Cannot release yet. Fix the following, then run this script again:" >&2
    for p in "${problems[@]}"; do printf '\n  - %s\n' "$p" >&2; done
    exit 1
  fi
  IDENTITY="$SIMBAR_SIGN_IDENTITY"
  echo "All set: $IDENTITY, notary profile $NOTARY_PROFILE"
fi

# --- build ------------------------------------------------------------------------------------
step "Building"
SIMBAR_SIGN_IDENTITY="$IDENTITY" ./build.sh
APP="$ROOT/build/SimBar.app"
if [[ $DRY_RUN == 0 ]] && ! /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "error: the built app has no SUPublicEDKey" >&2; exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"

# --- notarize and staple ----------------------------------------------------------------------
step "Notarizing"
NOTARY_ZIP="$ROOT/build/SimBar-notarize.zip"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
if [[ $DRY_RUN == 1 ]]; then
  would "xcrun notarytool submit $NOTARY_ZIP --keychain-profile $NOTARY_PROFILE --wait"
  would "xcrun stapler staple $APP"
else
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi
rm -f "$NOTARY_ZIP"

# --- archive ----------------------------------------------------------------------------------
step "Archiving"
ditto -c -k --keepParent "$APP" "$DIST/$ZIP_NAME"
SHA256=$(shasum -a 256 "$DIST/$ZIP_NAME" | awk '{print $1}')
echo "$DIST/$ZIP_NAME"
echo "sha256 $SHA256"

# --- appcast ----------------------------------------------------------------------------------
step "Generating the appcast"
NOTES="packaging/release-notes/$VERSION.md"
[[ -f "$NOTES" ]] && cp "$NOTES" "$DIST/SimBar-$VERSION.md"
APPCAST_ARGS=(--download-url-prefix "$DOWNLOAD_PREFIX"
  --link "https://github.com/$REPO"
  --full-release-notes-url "https://github.com/$REPO/releases"
  --embed-release-notes)
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  APPCAST_ARGS+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
else
  APPCAST_ARGS+=(--account "$SPARKLE_KEY_ACCOUNT")
fi
if [[ $DRY_RUN == 1 && -z "${SPARKLE_ED_KEY_FILE:-}" ]] \
   && ! "$GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -p >/dev/null 2>&1; then
  would "$SPARKLE_DIR/bin/generate_appcast ${APPCAST_ARGS[*]} $DIST"
  echo "    (skipped: no Sparkle private key for account \"$SPARKLE_KEY_ACCOUNT\" yet)"
else
  "$SPARKLE_DIR/bin/generate_appcast" "${APPCAST_ARGS[@]}" "$DIST"
  echo "$DIST/appcast.xml"
fi

# --- Homebrew cask ----------------------------------------------------------------------------
step "Filling the Homebrew cask"
# drop the template's header comment, fill the placeholders
sed -e '1,/^cask /{/^#/d;}' -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$SHA256/g" \
  packaging/homebrew/simlease.rb > "$DIST/simlease.rb"
ruby -c "$DIST/simlease.rb" >/dev/null
if grep -q '@[A-Z0-9]*@' "$DIST/simlease.rb"; then
  echo "error: unfilled placeholder in $DIST/simlease.rb" >&2; exit 1
fi
echo "$DIST/simlease.rb"

# --- publish ----------------------------------------------------------------------------------
if [[ $PUBLISH == 0 ]]; then
  step "Done. Nothing was published (add --publish to tag, release and update the tap)."
  exit 0
fi

step "Publishing $TAG"
RELEASE_ASSETS=("$DIST/$ZIP_NAME" "$DIST/appcast.xml")
CASK_DEST="${TAP_DIR:-\$TAP_DIR}/Casks/simlease.rb"
if [[ $DRY_RUN == 1 ]]; then
  would "git tag -a $TAG -m 'SimBar $VERSION' && git push origin $TAG"
  would "gh release create $TAG --repo $REPO --verify-tag --title 'SimBar $VERSION' ${RELEASE_ASSETS[*]}"
  would "cp $DIST/simlease.rb $CASK_DEST && git -C ${TAP_DIR:-\$TAP_DIR} commit -m 'simlease $VERSION'"
  [[ $PUSH_TAP == 1 ]] && would "git -C ${TAP_DIR:-\$TAP_DIR} push"
  exit 0
fi

git tag -a "$TAG" -m "SimBar $VERSION"
git push origin "$TAG"
NOTES_ARGS=(--generate-notes)
[[ -f "$NOTES" ]] && NOTES_ARGS=(--notes-file "$NOTES")
gh release create "$TAG" --repo "$REPO" --verify-tag --title "SimBar $VERSION" "${NOTES_ARGS[@]}" "${RELEASE_ASSETS[@]}"

mkdir -p "$TAP_DIR/Casks"
cp "$DIST/simlease.rb" "$CASK_DEST"
git -C "$TAP_DIR" add Casks/simlease.rb
git -C "$TAP_DIR" commit -m "simlease $VERSION"
if [[ $PUSH_TAP == 1 ]]; then
  git -C "$TAP_DIR" push
else
  echo "Cask committed in $TAP_DIR (not pushed; run: git -C $TAP_DIR push)"
fi
step "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
