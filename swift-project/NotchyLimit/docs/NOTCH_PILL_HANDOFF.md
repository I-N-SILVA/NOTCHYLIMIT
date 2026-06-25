# Notch Pill UI Handoff

## Context

This handoff covers the Notchy Limit notch pill interaction polish currently
prepared in PR #26:

https://github.com/I-N-SILVA/NOTCHYLIMIT/pull/26

Branch:

```bash
codex-notchy-pill-ui-polish
```

Commit:

```bash
458d1fe Polish notch pill interaction
```

The work addresses three product issues:

1. The expanded notch panel content started too close to the MacBook notch.
2. The expanded panel used a fixed size and could clip content when extra
   messages or sections were visible.
3. The notch pill opened on hover by default, which is disruptive when an
   external display is positioned above the MacBook display.

## Final Behavior

- The notch pill defaults to click-to-open.
- Users can choose whether the notch pill opens on click or hover in
  Settings -> Display.
- The expanded panel has an explicit close button in the top-right corner.
- Opening Settings, Cookie setup, Alerts, or Diagnostics collapses the expanded
  notch panel first so the new window is usable immediately.
- The compact and expanded notch panel are clipped to their intended rounded
  shape so no green rectangular corners leak onto the desktop.
- The expanded panel height adapts to visible content, including provider
  switcher, active incidents, and extra usage windows.

## Files Changed

- `Sources/Core/State/AppState.swift`
  - Adds persisted `NotchOpenBehavior` with `.click` and `.hover`.
  - Default behavior is `.click`.

- `Sources/UI/Settings/SettingsView.swift`
  - Adds the click/hover setting in the Display tab when the notch pill is
    available.

- `Sources/UI/NotchWindowController.swift`
  - Centralizes compact/expanded sizing in `NotchPanelLayout`.
  - Applies dynamic expanded height.
  - Ignores hover expansion unless the user selected hover behavior.
  - Resizes an already-expanded panel when relevant app state changes.

- `Sources/UI/Compact/CompactView.swift`
  - Clips the compact pill to the intended notch pill shape to prevent visible
    rectangular corner artifacts.

- `Sources/UI/Expanded/ExpandedPanelView.swift`
  - Adds the close button.
  - Adds top clearance below the notch area.
  - Uses the dynamic visible height.
  - Clips the expanded panel background to the intended rounded shape.

- `Sources/UI/Expanded/HeaderRow.swift`
  - Collapses the notch panel before opening Settings.

- `Sources/UI/Expanded/ActionsRow.swift`
  - Collapses the notch panel before opening Cookie setup, Alerts, or
    Diagnostics.

## Relevant Design Decisions

- The click/hover preference is stored in `AppState`, matching the existing
  persisted settings pattern.
- The default is click because hover is disruptive for setups where the pointer
  frequently crosses the MacBook notch area while moving between displays.
- The expanded panel is not recreated to close or resize it. The existing
  `NotchWindowController` state transition methods are used.
- No monitor-specific logic or pixel-offset workaround was added.

## Local Verification

Build command:

```bash
cd /Users/pedroahlers/Development/NOTCHY/swift-project/NotchyLimit
xcodebuild -project NotchyLimit.xcodeproj -scheme NotchyLimit -configuration Debug -derivedDataPath build/DerivedData build
```

Start the exact debug build:

```bash
open /Users/pedroahlers/Development/NOTCHY/swift-project/NotchyLimit/build/DerivedData/Build/Products/Debug/NotchyLimit.app
```

Do not use Spotlight for this verification while multiple `NotchyLimit` app
bundles are indexed. Spotlight may open an older release or cached build.

Manual checks performed:

1. The app builds successfully with `xcodebuild`.
2. The compact pill no longer shows green corner artifacts.
3. The expanded panel no longer shows green lower-corner artifacts.
4. Click-to-open can be selected in Settings -> Display.
5. Hover no longer opens the pill when click mode is selected.
6. The close button collapses the expanded panel.
7. Opening Settings from the expanded panel collapses Notchy first.

## Known Local Build Note

During development, multiple app bundles can exist at the same time, for
example:

```text
swift-project/NotchyLimit/build/Build/Products/Release/NotchyLimit.app
swift-project/NotchyLimit/build/DerivedData/Build/Products/Debug/NotchyLimit.app
```

If the wrong UI appears, quit Notchy Limit and start the exact Debug path shown
above.
