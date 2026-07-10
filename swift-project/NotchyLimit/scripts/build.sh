#!/usr/bin/env bash
set -euo pipefail

# Build script for Notchy Limit.
# Mode A (default): swiftc — no Xcode required, works with CLI tools only.
# Mode B: xcodebuild — set USE_XCODEBUILD=1 if Xcode is installed.
#   Requires: Xcode 15+ and `brew install xcodegen` for Mode B.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="NotchyLimit"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
SOURCES_DIR="$PROJECT_DIR/Sources"
ASSETS_DIR="$SOURCES_DIR/Resources/Assets.xcassets/AppIcon.appiconset"
SDK=$(xcrun --show-sdk-path --sdk macosx)

echo "==> Cleaning previous build artifacts"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"

# ── Mode B: xcodebuild ──────────────────────────────────────────────────────
if [[ "${USE_XCODEBUILD:-0}" == "1" ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found. Install with: brew install xcodegen" >&2; exit 1
  fi
  DERIVED_DATA="$PROJECT_DIR/.derived-data"
  CONFIGURATION="${CONFIGURATION:-Release}"
  echo "==> Generating Xcode project (XcodeGen)"
  xcodegen generate
  echo "==> Building $APP_NAME ($CONFIGURATION) via xcodebuild"
  xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build
  APP_BUILT_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
  if [ ! -d "$APP_BUILT_PATH" ]; then
    echo "Build failed: $APP_BUILT_PATH not found" >&2; exit 1
  fi
  cp -R "$APP_BUILT_PATH" "$BUILD_DIR/"
  echo "==> Built (xcodebuild): $BUILD_DIR/$APP_NAME.app"
  echo "Run with: open $BUILD_DIR/$APP_NAME.app"
  exit 0
fi

# ── Mode A: swiftc (no Xcode required) ─────────────────────────────────────
echo ""
echo "  NOTE: Mode A produces an UNSIGNED binary for local use only."
echo "  Do not distribute this build. For a distributable binary, use"
echo "  Mode B (USE_XCODEBUILD=1) with a Developer ID and scripts/sign_and_notarize.sh."
echo ""
echo "==> Compiling $APP_NAME with swiftc (no Xcode required)"
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx12.0 \
  -O \
  -module-name "$APP_NAME" \
  -o "$APP_CONTENTS/MacOS/$APP_NAME" \
  "$SOURCES_DIR/App/NotchyLimitApp.swift" \
  "$SOURCES_DIR/App/AppDelegate.swift" \
  "$SOURCES_DIR/Core/Domain/ProviderId.swift" \
  "$SOURCES_DIR/Core/Domain/Status.swift" \
  "$SOURCES_DIR/Core/Domain/UsageWindow.swift" \
  "$SOURCES_DIR/Core/Domain/ServiceUsageSnapshot.swift" \
  "$SOURCES_DIR/Core/State/AppState.swift" \
  "$SOURCES_DIR/Core/State/NotchState.swift" \
  "$SOURCES_DIR/Platform/KeychainStore.swift" \
  "$SOURCES_DIR/Platform/SQLiteReader.swift" \
  "$SOURCES_DIR/Platform/FormURLEncoding.swift" \
  "$SOURCES_DIR/Platform/NotchDetector.swift" \
  "$SOURCES_DIR/Platform/ScreenUtils.swift" \
  "$SOURCES_DIR/Platform/DisplayMode.swift" \
  "$SOURCES_DIR/Providers/UsageProvider.swift" \
  "$SOURCES_DIR/Providers/ProviderRegistry.swift" \
  "$SOURCES_DIR/Providers/Claude/ClaudeCredential.swift" \
  "$SOURCES_DIR/Providers/Claude/ClaudeEndpoint.swift" \
  "$SOURCES_DIR/Providers/Claude/ClaudeUsageDTO.swift" \
  "$SOURCES_DIR/Providers/Claude/ClaudeOAuthCredential.swift" \
  "$SOURCES_DIR/Providers/Claude/ClaudeProvider.swift" \
  "$SOURCES_DIR/Providers/Codex/CodexProvider.swift" \
  "$SOURCES_DIR/Providers/Gemini/GeminiProvider.swift" \
  "$SOURCES_DIR/Providers/Perplexity/PerplexityProvider.swift" \
  "$SOURCES_DIR/Providers/DeepSeek/DeepSeekProvider.swift" \
  "$SOURCES_DIR/Providers/ElevenLabs/ElevenLabsProvider.swift" \
  "$SOURCES_DIR/Providers/OpenRouter/OpenRouterProvider.swift" \
  "$SOURCES_DIR/Providers/OpenAI/OpenAICredential.swift" \
  "$SOURCES_DIR/Providers/OpenAI/OpenAIEndpoint.swift" \
  "$SOURCES_DIR/Providers/OpenAI/OpenAIProvider.swift" \
  "$SOURCES_DIR/Services/AuthService.swift" \
  "$SOURCES_DIR/Services/IncidentMonitor.swift" \
  "$SOURCES_DIR/Services/NotificationService.swift" \
  "$SOURCES_DIR/Services/UsageCoordinator.swift" \
  "$SOURCES_DIR/Services/UsageService.swift" \
  "$SOURCES_DIR/Services/UsageHistoryStore.swift" \
  "$SOURCES_DIR/UI/Theme/Theme.swift" \
  "$SOURCES_DIR/UI/Theme/BrandIcon.swift" \
  "$SOURCES_DIR/UI/Theme/GlassBackground.swift" \
  "$SOURCES_DIR/UI/Theme/RetroMascot.swift" \
  "$SOURCES_DIR/UI/Theme/StatusRingView.swift" \
  "$SOURCES_DIR/UI/Compact/StatusDot.swift" \
  "$SOURCES_DIR/UI/Compact/CompactProgressBar.swift" \
  "$SOURCES_DIR/UI/Compact/CompactView.swift" \
  "$SOURCES_DIR/UI/Compact/ConstellationView.swift" \
  "$SOURCES_DIR/UI/MenuBar/MenuBarController.swift" \
  "$SOURCES_DIR/UI/NotchWindowController.swift" \
  "$SOURCES_DIR/UI/Expanded/HeaderRow.swift" \
  "$SOURCES_DIR/UI/Expanded/SessionCard.swift" \
  "$SOURCES_DIR/UI/Expanded/PaceRow.swift" \
  "$SOURCES_DIR/UI/Expanded/WeeklyCard.swift" \
  "$SOURCES_DIR/UI/Expanded/ActionsRow.swift" \
  "$SOURCES_DIR/UI/Expanded/FooterRow.swift" \
  "$SOURCES_DIR/UI/Expanded/ProviderSwitcherRow.swift" \
  "$SOURCES_DIR/UI/Expanded/Sparkline.swift" \
  "$SOURCES_DIR/UI/Expanded/ExpandedPanelView.swift" \
  "$SOURCES_DIR/UI/Onboarding/OnboardingView.swift" \
  "$SOURCES_DIR/UI/Settings/SettingsView.swift" \
  "$SOURCES_DIR/UI/Diagnostics/DiagnosticsView.swift" \
  "$SOURCES_DIR/UI/NotificationBanner.swift"

echo "==> Assembling .app bundle"

# Info.plist — resolve Xcode build variables to literal values
cp "$SOURCES_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME"                     "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.notchylimit.NotchyLimit"   "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_CONTENTS/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_CONTENTS/Info.plist"

# App icon — build .icns from the PNG set using iconutil
ICONSET="/tmp/$APP_NAME.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
sips -z 16   16   "$ASSETS_DIR/AppIcon-16.png"   --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32   32   "$ASSETS_DIR/AppIcon-32.png"   --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$ASSETS_DIR/AppIcon-32.png"   --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64   64   "$ASSETS_DIR/AppIcon-64.png"   --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$ASSETS_DIR/AppIcon-128.png"  --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$ASSETS_DIR/AppIcon-256.png"  --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$ASSETS_DIR/AppIcon-256.png"  --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$ASSETS_DIR/AppIcon-512.png"  --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$ASSETS_DIR/AppIcon-512.png"  --out "$ICONSET/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$ASSETS_DIR/AppIcon-1024.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP_CONTENTS/Resources/AppIcon.icns"

# Brand provider logos (loaded at runtime via Bundle.main → BrandIcon)
if [ -d "$SOURCES_DIR/Resources/BrandIcons" ]; then
  cp "$SOURCES_DIR/Resources/BrandIcons/"*.png "$APP_CONTENTS/Resources/" 2>/dev/null || true
fi

# Strip quarantine attribute so macOS doesn't block launch
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Ad-hoc sign the whole bundle (no Developer ID needed). This seals the
# Info.plist + resources so a downloaded/quarantined copy shows the mild
# "unidentified developer" prompt (right-click → Open) instead of the scary
# "app is damaged" error you get from a half-signed bundle.
echo "==> Ad-hoc signing the bundle (codesign --sign -)"
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null \
  && codesign --verify --strict "$APP_BUNDLE" 2>/dev/null \
  && echo "    ad-hoc signature OK" \
  || echo "    (ad-hoc signing skipped/failed — app still runs locally)"

echo ""
echo "==> Built (unsigned, local use only): $APP_BUNDLE"
echo "    Run with: open $APP_BUNDLE"
echo ""
echo "  This binary is unsigned. Do not share or distribute it."
echo "  For distribution use: USE_XCODEBUILD=1 bash scripts/build.sh"
