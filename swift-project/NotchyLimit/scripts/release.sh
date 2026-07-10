#!/usr/bin/env bash
#
# release.sh — cut a new release of an unsigned macOS app and ship it via a
# Homebrew cask, in one command. Build → ad-hoc sign → DMG → GitHub release →
# update the tap cask (version + sha256).
#
# Usage:
#   release.sh <version> [--notes-file FILE | --notes "text"] [--dry-run]
#   release.sh 0.5.1 --notes "Bug fixes"
#   release.sh 0.6.0 --dry-run            # build + sha locally, publish nothing
#
# Config (env vars; defaults are for Notchy — override for another app):
#   PROJECT_DIR  Swift project dir holding scripts/build.sh + Info.plist
#   APP_NAME     .app bundle name        (default NotchyLimit)
#   DMG_NAME     DMG basename            (default NotchyLimit-Installer)
#   REPO         owner/name for releases (default I-N-SILVA/NOTCHYLIMIT)
#   TAP_REPO     owner/homebrew-name     (default I-N-SILVA/homebrew-notchy)
#   CASK         cask file basename      (default notchy)
#
# Requirements: macOS, gh (authenticated), git. No Apple Developer ID needed —
# the app is ad-hoc signed so a quarantined download opens via right-click,
# and the cask clears quarantine on install.
set -euo pipefail

# ── args ──────────────────────────────────────────────────────────────────
VERSION="${1:-}"
[[ -z "$VERSION" || "$VERSION" == -* ]] && { echo "usage: release.sh <version> [--notes-file F | --notes T] [--dry-run]" >&2; exit 1; }
shift
NOTES=""; NOTES_FILE=""; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2;;
    --notes-file) NOTES_FILE="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z (got '$VERSION')" >&2; exit 1; }

# ── config ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
APP_NAME="${APP_NAME:-NotchyLimit}"
DMG_NAME="${DMG_NAME:-NotchyLimit-Installer}"
REPO="${REPO:-I-N-SILVA/NOTCHYLIMIT}"
TAP_REPO="${TAP_REPO:-I-N-SILVA/homebrew-notchy}"
CASK="${CASK:-notchy}"
INFO_PLIST="$PROJECT_DIR/Sources/Resources/Info.plist"
DMG_PATH="$PROJECT_DIR/build/$DMG_NAME.dmg"
TAG="v$VERSION"

say() { printf "\n\033[1m==> %s\033[0m\n" "$*"; }
[[ $DRY == 1 ]] && say "DRY RUN — will build locally but publish nothing"

command -v gh >/dev/null || { echo "gh not found" >&2; exit 1; }
[[ -f "$INFO_PLIST" ]] || { echo "Info.plist not found at $INFO_PLIST" >&2; exit 1; }

# ── 1. bump version ──────────────────────────────────────────────────────────
say "Bumping version → $VERSION (CFBundleShortVersionString) + build number"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
CUR_BUILD=$("$PB" -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo 0)
"$PB" -c "Set :CFBundleVersion $((CUR_BUILD + 1))" "$INFO_PLIST"

# ── 2. build + ad-hoc sign + DMG ─────────────────────────────────────────────
say "Building (ad-hoc signed) + DMG"
( cd "$PROJECT_DIR" && bash scripts/build.sh >/dev/null && bash scripts/create_dmg.sh >/dev/null )
codesign --verify --strict "$PROJECT_DIR/build/$APP_NAME.app" \
  && echo "   codesign --verify: OK" \
  || echo "   WARNING: bundle failed codesign --verify (check build.sh ad-hoc signing)"
[[ -f "$DMG_PATH" ]] || { echo "DMG not produced at $DMG_PATH" >&2; exit 1; }
SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "   DMG: $DMG_PATH"
echo "   sha256: $SHA"

if [[ $DRY == 1 ]]; then
  say "DRY RUN complete. Restoring Info.plist."
  ( cd "$PROJECT_DIR" && git checkout -- "$INFO_PLIST" 2>/dev/null || true )
  echo "Would: commit bump, tag $TAG, gh release create, bump cask $CASK to $VERSION/$SHA."
  exit 0
fi

# ── 3. commit version bump + tag + push ──────────────────────────────────────
say "Committing version bump + tagging $TAG"
( cd "$PROJECT_DIR" && git add "$INFO_PLIST" \
  && git commit -m "chore: release $TAG

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" >/dev/null )
BRANCH=$(cd "$PROJECT_DIR" && git rev-parse --abbrev-ref HEAD)
( cd "$PROJECT_DIR" && git push origin "$BRANCH" && git tag "$TAG" && git push origin "$TAG" )

# ── 4. GitHub release ────────────────────────────────────────────────────────
say "Publishing GitHub release $TAG"
NOTE_ARGS=()
if [[ -n "$NOTES_FILE" ]]; then NOTE_ARGS=(--notes-file "$NOTES_FILE")
elif [[ -n "$NOTES" ]]; then NOTE_ARGS=(--notes "$NOTES")
else NOTE_ARGS=(--generate-notes); fi
gh release create "$TAG" \
  "$DMG_PATH#$DMG_NAME.dmg (unsigned, ad-hoc)" \
  --repo "$REPO" --target "$BRANCH" --title "$TAG" "${NOTE_ARGS[@]}"

# ── 5. update Homebrew cask ──────────────────────────────────────────────────
say "Updating Homebrew cask $CASK → $VERSION"
TAP_TMP=$(mktemp -d)
gh repo clone "$TAP_REPO" "$TAP_TMP" -- -q
CASK_FILE="$TAP_TMP/Casks/$CASK.rb"
[[ -f "$CASK_FILE" ]] || { echo "cask not found: $CASK_FILE" >&2; exit 1; }
/usr/bin/sed -i '' -E "s/version \"[^\"]+\"/version \"$VERSION\"/" "$CASK_FILE"
/usr/bin/sed -i '' -E "s/sha256 \"[^\"]+\"/sha256 \"$SHA\"/" "$CASK_FILE"
( cd "$TAP_TMP" && git add "Casks/$CASK.rb" \
  && git commit -m "$CASK $VERSION" >/dev/null && git push -q origin HEAD )
rm -rf "$TAP_TMP"

TAP_OWNER="${TAP_REPO%%/*}"
TAP_NAME="${TAP_REPO##*/homebrew-}"
say "Released $TAG"
echo "  Release: https://github.com/$REPO/releases/tag/$TAG"
echo "  Install: brew install --cask $TAP_OWNER/$TAP_NAME/$CASK"
echo "  Upgrade: brew upgrade --cask $CASK"
