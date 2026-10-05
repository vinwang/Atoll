# Atoll — Menu Bar Drawer / Codex Task

> **Repository:** `vinwang/Atoll`  
> **Base branch:** `dev`  
> **Working branch:** `feature/menu-bar-drawer`  
> **Platform:** macOS / Swift / SwiftUI / AppKit  
> **Scope:** **Phase 1 only**  
> **Definition of done:** Discover → Select → Render → Click

---

## 1. Mission

Implement a new **Menu Bar Drawer** feature in Atoll.

The user should be able to select real macOS menu bar/status items and display them inside an Atoll tab.

When the user clicks an item inside Atoll, Atoll should trigger the **original menu bar item** so the original application opens its own menu/popover.

Phase 1 must support:

```text
macOS Menu Bar
      ↓
Discover real status items
      ↓
Settings: choose items
      ↓
Atoll: Menu Bar tab
      ↓
Render selected status item images
      ↓
Left / right click
      ↓
Original status item handles interaction
```

---

# 2. Hard scope boundary

## Implement in Phase 1

- Discover menu bar/status items.
- Resolve owner PID/application/bundle ID/title/frame.
- Create stable item identity independent of PID/window ID.
- Persist selected items.
- Capture the real current status item image when possible.
- Fall back to application icon if capture is unavailable.
- Add `Settings → Menu Bar`.
- Add a `Menu Bar` Atoll tab.
- Render selected items in that tab.
- Forward left click to the original status item.
- Forward right click where supported.
- Recover selected items after third-party app restart.
- Refresh after app launch/quit, Space changes, screen changes, and wake.
- Add tests for pure logic.
- Build and test the project.
- Update GPL attribution / `NOTICE`.

## Do NOT implement in Phase 1

- Hide original menu bar items.
- Move menu bar items.
- Hidden section.
- Always-hidden section.
- `tempShowItem`.
- Automatic re-hide.
- Menu bar item drag/reorder.
- Ice Bar UI.
- Ice search.
- Ice appearance/theme system.
- Multi-display independent drawers.

**Stop after Phase 1 passes build/tests. Do not continue to Phase 2.**

---

# 3. Existing Atoll code to reuse

Read these files before implementing anything:

```text
DynamicIsland/helpers/AccessibilityPermissionStore.swift
DynamicIsland/managers/MenuBarLayout.swift
DynamicIsland/helpers/AppIcons.swift
DynamicIsland/components/Tabs/TabSelectionView.swift
DynamicIsland/components/Settings/SettingsView.swift
DynamicIsland/DynamicIslandViewCoordinator.swift
DynamicIsland/ContentView.swift
DynamicIsland/enums/generic.swift
```

Also locate the project's existing `Defaults.Key` declarations and follow the current conventions.

### Important responsibility split

Keep the existing `MenuBarLayout.swift` responsibility unchanged:

```text
MenuBarLayout
→ frontmost app menus such as File/Edit/View/Window/Help
```

The new module handles:

```text
Menu Bar Drawer
→ right-side status items/menu extras such as VPN/Docker/OneDrive/Wi-Fi/etc.
```

Do not merge these managers.

---

# 4. Technical reference: Ice

Use `jordanbaird/Ice` as the reference implementation for low-level menu bar behavior.

Inspect these files:

```text
Ice/MenuBar/MenuBarItems/MenuBarItem.swift
Ice/MenuBar/MenuBarItems/MenuBarItemImageCache.swift
Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift
Ice/Bridging/Bridging.swift
Ice/Utilities/WindowInfo.swift
Ice/Utilities/ScreenCapture.swift
Ice/UI/IceBar/IceBar.swift
```

Only adapt the minimal functionality needed by Atoll.

Do **not** port Ice's overall architecture.

---

# 5. Required module structure

Prefer the following structure:

```text
DynamicIsland/
└── MenuBar/
    ├── Models/
    │   ├── MenuBarItemIdentity.swift
    │   └── ManagedMenuBarItem.swift
    │
    ├── Core/
    │   ├── MenuBarWindowBridge.swift
    │   ├── MenuBarWindowInfo.swift
    │   ├── MenuBarItemScanner.swift
    │   ├── MenuBarItemImageCache.swift
    │   └── MenuBarItemInteractionService.swift
    │
    ├── Managers/
    │   └── MenuBarItemManager.swift
    │
    └── Views/
        ├── MenuBarDrawerView.swift
        ├── MenuBarDrawerItemView.swift
        └── MenuBarItemPickerView.swift

DynamicIsland/components/Settings/
└── MenuBarSettingsView.swift
```

Names may be adjusted to current project conventions, but responsibilities must stay separated.

---

# 6. Architecture rule

Keep dependencies in this direction:

```text
MenuBarWindowBridge
        ↓
MenuBarWindowInfo
        ↓
MenuBarItemScanner
        ↓
ManagedMenuBarItem
        ↓
MenuBarItemManager
       ↙       ↘
ImageCache   InteractionService
       \       /
        Atoll UI
```

### Private API rule

All private WindowServer/CGS calls must be isolated in:

```text
MenuBarWindowBridge.swift
```

No SwiftUI view or settings view may call private CGS APIs directly.

---

# 7. Stable identity

PID and `CGWindowID` are runtime-only and change when apps restart.

Create a stable identity similar to:

```swift
struct MenuBarItemIdentity: Codable, Hashable, Identifiable {
    let bundleIdentifier: String?
    let title: String
    let ownerName: String?

    var id: String {
        [
            bundleIdentifier ?? "",
            title,
            ownerName ?? ""
        ].joined(separator: "::")
    }
}
```

Examples:

```text
com.microsoft.OneDrive::OneDrive::OneDrive
com.apple.controlcenter::WiFi::Control Center
```

Persist this identity, not PID/window ID.

---

# 8. Runtime model

Create a runtime model similar to:

```swift
struct ManagedMenuBarItem: Identifiable, Hashable {
    let identity: MenuBarItemIdentity

    let windowID: CGWindowID
    let ownerPID: pid_t
    let frame: CGRect

    let displayName: String
    let bundleIdentifier: String?
    let ownerName: String?

    let isOnScreen: Bool

    var id: String { identity.id }
}
```

Runtime-only fields must never be stored in preferences:

```text
windowID
ownerPID
frame
isOnScreen
```

---

# 9. WindowServer bridge

Create:

```text
DynamicIsland/MenuBar/Core/MenuBarWindowBridge.swift
```

Expose only safe wrappers such as:

```swift
enum MenuBarWindowBridge {
    static func menuBarWindows() -> [CGWindowID]
    static func onScreenMenuBarWindows() -> [CGWindowID]
    static func windowFrame(_ windowID: CGWindowID) -> CGRect?
    static func isWindowOnActiveSpace(_ windowID: CGWindowID) -> Bool
}
```

Likely underlying APIs include:

```text
CGSMainConnectionID
CGSGetProcessMenuBarWindowList
CGSGetOnScreenWindowList
CGSGetScreenRectForWindow
CGSCopySpacesForWindows
CGSGetActiveSpace
```

Use only what Phase 1 requires.

---

# 10. Window metadata

`MenuBarWindowInfo` should resolve at minimum:

```text
windowID
frame
ownerPID
ownerName
NSRunningApplication
bundleIdentifier
title
isOnScreen
```

Keep it minimal. Do not import Ice's full `WindowInfo` unless necessary.

---

# 11. Scanner

Create:

```text
MenuBarItemScanner.swift
```

Main API:

```swift
func scan() async -> [ManagedMenuBarItem]
```

Flow:

```text
WindowServer
  ↓
menu bar window IDs
  ↓
window metadata
  ↓
owner application / bundle ID
  ↓
stable identity
  ↓
ManagedMenuBarItem
```

Filter:

- Invalid windows.
- Invalid/zero frames.
- Duplicate items.
- Atoll's own menu item where appropriate.
- Windows that clearly are not menu bar items.

Do **not** automatically remove Apple Control Center items.

Potential valid items include:

```text
Wi-Fi
Bluetooth
Battery
Volume
Now Playing
Focus
```

---

# 12. Concurrency

WindowServer, screen capture, and cross-process calls must not block `MainActor`.

Use background execution such as:

```swift
Task.detached(priority: .utility) {
    ...
}
```

Publish final observable state back on `MainActor`.

Follow the safety pattern already used in:

```text
DynamicIsland/managers/MenuBarLayout.swift
```

Never perform potentially blocking IPC inside SwiftUI `body`.

---

# 13. Central manager

Create:

```swift
@MainActor
final class MenuBarItemManager: ObservableObject {
    static let shared = MenuBarItemManager()

    @Published private(set) var items: [ManagedMenuBarItem] = []
    @Published private(set) var selectedItems: [ManagedMenuBarItem] = []
    @Published private(set) var isScanning = false
}
```

Responsibilities:

```text
scan
runtime cache
selection matching
app restart matching
refresh scheduling
image refresh coordination
```

Do not allow concurrent scans.

Use a low-frequency polling fallback around:

```text
3 seconds
```

No high-frequency polling.

---

# 14. Refresh triggers

Observe at minimum:

```text
NSWorkspace.didLaunchApplicationNotification
NSWorkspace.didTerminateApplicationNotification
NSWorkspace.activeSpaceDidChangeNotification
NSApplication.didChangeScreenParametersNotification
NSWorkspace.didWakeNotification
```

Debounce/coalesce bursts where appropriate.

After wake, use a short delay (~1 second) before rescanning.

---

# 15. Preferences

Add using the existing Defaults system:

```text
enableMenuBarDrawer
selectedMenuBarItems
menuBarDrawerShowLabels
menuBarDrawerShowTooltips
```

Selections should persist as:

```swift
[MenuBarItemIdentity]
```

If the current Defaults library integration makes this awkward, persist:

```swift
[String]
```

using `identity.id`.

Do not implement menu bar hiding behavior in Phase 1.

---

# 16. Status item image capture

Create:

```text
MenuBarItemImageCache.swift
```

Preferred result:

> Atoll displays the menu bar item's **actual current status image**, not merely the application's Dock icon.

Flow:

```text
CGWindowID
  ↓
current frame
  ↓
capture
  ↓
crop item bounds
  ↓
CGImage
  ↓
NSImage
```

Reference Ice's image cache and screen capture code.

### Fallback order

```text
1. Real captured status item image
2. App icon via DynamicIsland/helpers/AppIcons.swift
3. Generic SF Symbol
4. Generic placeholder
```

Image capture failure must never make the item disappear.

---

# 17. Screen Recording permission fallback

If Screen Recording permission is unavailable:

- Keep the drawer enabled.
- Keep discovery when possible.
- Keep click forwarding when possible.
- Fall back to application icons.
- Show a concise explanation in settings.

Do not make Screen Recording permission an all-or-nothing dependency.

---

# 18. Image refresh strategy

Do not capture every item continuously.

Refresh selected/visible item images when:

```text
first discovered
window ID changes
frame changes
active Space changes
screen configuration changes
manual refresh
```

For dynamic icons, a low-frequency 2–3 second refresh is acceptable only for selected/visible items.

---

# 19. Interaction service

Create:

```text
MenuBarItemInteractionService.swift
```

API:

```swift
func leftClick(_ item: ManagedMenuBarItem) async throws
func rightClick(_ item: ManagedMenuBarItem) async throws
```

Do not recreate another app's menu.

Click the original menu bar item.

Expected flow:

```text
Atoll click
  ↓
resolve latest original item/frame
  ↓
point = frame midpoint
  ↓
CGEvent mouseDown
  ↓
CGEvent mouseUp
  ↓
original app opens native menu/popover
```

Reference Ice's `click(item:with:)` implementation.

---

# 20. Cursor safety

Prefer click delivery without visibly moving the cursor.

If temporary pointer manipulation is required:

```text
save cursor position
hide cursor if necessary
perform event
restore cursor
show cursor
```

Cleanup must run even when an error occurs.

Use `defer` or equivalent guaranteed cleanup.

---

# 21. Timeout/error policy

One broken or frozen third-party application must never freeze Atoll.

Use reasonable timeout/error boundaries around cross-process operations.

Guideline:

```text
single cross-process operation: ~250–500 ms
complete click/interaction: ~1–2 seconds
```

On failure:

- Keep Atoll responsive.
- Log in Debug.
- Avoid modal alerts for routine failures.
- Keep the item visible when possible.

---

# 22. Logging

Use prefix:

```text
[MenuBar]
```

Examples:

```text
[MenuBar] discovered item: Clash Verge
[MenuBar] matched selected item: OneDrive
[MenuBar] image updated: Docker
[MenuBar] left click: Wi-Fi
[MenuBar] interaction failed: ...
```

Do not spam Release logs.

---

# 23. Add new Atoll view type

Update:

```text
DynamicIsland/enums/generic.swift
```

Add:

```swift
case menuBar
```

to `NotchViews`.

Update all exhaustive switches.

---

# 24. Coordinator integration

Update:

```text
DynamicIsland/DynamicIslandViewCoordinator.swift
```

Add `.menuBar` to the tab order.

Suggested placement:

```text
home
menuBar
shelf
...
```

Ensure tab transition direction logic continues to work.

---

# 25. TabSelectionView integration

Update:

```text
DynamicIsland/components/Tabs/TabSelectionView.swift
```

Add only when enabled:

```swift
if Defaults[.enableMenuBarDrawer] {
    tabsArray.append(
        TabModel(
            label: "Menu Bar",
            icon: "menubar.rectangle",
            view: .menuBar
        )
    )
}
```

If the symbol is unavailable on the deployment target, use a suitable fallback.

---

# 26. ContentView integration

Update:

```text
DynamicIsland/ContentView.swift
```

Route:

```swift
coordinator.currentView == .menuBar
```

to:

```swift
MenuBarDrawerView()
```

Do not perform unrelated ContentView refactors.

---

# 27. Drawer UI

Create:

```text
MenuBarDrawerView.swift
MenuBarDrawerItemView.swift
```

Recommended layout:

```swift
ScrollView(.horizontal) {
    HStack(spacing: 6) {
        ...
    }
}
```

Design requirements:

- Compact.
- Native-looking.
- Status icons around 18–22 pt high.
- No oversized Dock-style application icons unless used as fallback.
- Labels off by default.
- Tooltips/accessibility names enabled.

Each item:

```text
render image
left click → original left click
right click → original right click
```

---

# 28. Settings integration

Add a new settings page:

```text
Settings → Menu Bar
```

Suggested section:

```text
Utilities
```

Add the necessary enum case/title/icon/tint/search entries following existing `SettingsView.swift` conventions.

Suggested icon:

```text
menubar.rectangle
```

---

# 29. Settings UI

Create:

```text
DynamicIsland/components/Settings/MenuBarSettingsView.swift
```

Recommended UI:

```text
Menu Bar Drawer

[✓] Enable Menu Bar Drawer

Items
--------------------------------
[✓] Clash Verge
[✓] Docker
[✓] OneDrive
[ ] Wi-Fi
[ ] Bluetooth
[ ] Battery

Appearance
--------------------------------
[✓] Show tooltips
[ ] Show item names

Permissions
--------------------------------
Accessibility       Granted
Screen Recording    Granted

[ Refresh ]
```

If discovery returns no items:

```text
No menu bar items found.
```

---

# 30. Item picker

Create:

```text
MenuBarItemPickerView.swift
```

Requirements:

- Show current discovered items.
- Show icon if available.
- Show a useful display name.
- Toggle selection.
- Persist immediately.
- Preserve selected identity if the application quits temporarily.

When a selected app restarts:

```text
new PID
new window ID
same stable identity
```

The item must automatically return to the Atoll drawer.

---

# 31. Multi-display scope

Phase 1 should target the main active menu bar only.

Use current Atoll screen conventions and prefer `NSScreen.main` where appropriate.

Do not build independent status item management for every display yet.

Document this as a known Phase 1 limitation.

---

# 32. Menu bar auto-hide

macOS menu bar auto-hide can affect WindowServer behavior.

Phase 1 requirement:

- Best effort only.
- Never crash.
- Document limitations.

Do not implement advanced auto-hide workarounds yet.

---

# 33. Tests

Add pure logic tests.

Suggested files:

```text
DynamicIslandTests/MenuBarItemIdentityTests.swift
DynamicIslandTests/MenuBarItemFilteringTests.swift
DynamicIslandTests/MenuBarSelectionTests.swift
```

### Identity tests

Verify:

```text
same bundle ID/title/owner
→ same identity

PID changes
→ identity unchanged

window ID changes
→ identity unchanged
```

### Filtering tests

Test:

```text
invalid frame rejected
duplicate rejected
Atoll self-item filtered where appropriate
normal third-party item accepted
valid Control Center item accepted
```

### Selection tests

Persist:

```text
Clash
Docker
```

Return runtime scan results in another order.

Expected:

```text
selectedItems still resolves Clash + Docker
```

A temporarily missing selected app must not erase its persisted selection.

---

# 34. Licensing

Atoll and Ice are GPL-3.0.

For files substantially adapted from Ice, add attribution such as:

```swift
/*
 * Portions adapted from Ice
 * https://github.com/jordanbaird/Ice
 *
 * Ice is licensed under GPL-3.0.
 *
 * Modified for Atoll Menu Bar Drawer.
 */
```

Update `NOTICE` with a concise attribution for menu bar discovery/image capture/interaction logic.

Do not remove existing Atoll license headers.

---

# 35. Implementation order

Follow this order exactly unless the existing architecture requires a small adjustment.

### Step 1 — Inspect

Understand current:

```text
Defaults definitions
Settings routing
Notch tab routing
ContentView view switching
Accessibility permission flow
```

### Step 2 — Models

Implement:

```text
MenuBarItemIdentity
ManagedMenuBarItem
```

### Step 3 — Window bridge

Implement minimal private API wrapper.

### Step 4 — Scanner

Get reliable discovered items and Debug logging.

### Step 5 — Manager/persistence

Implement selection matching and lifecycle refreshes.

### Step 6 — Image cache

Capture real status images with fallbacks.

### Step 7 — Interaction

Implement visible-item left/right click forwarding.

### Step 8 — Settings

Add feature toggle and item picker.

### Step 9 — Atoll tab

Add `.menuBar`, tab button, and drawer rendering.

### Step 10 — Tests/build

Run tests and compile. Fix implementation errors until clean.

Then stop.

---

# 36. Acceptance criteria

Phase 1 is complete only if all required items below are satisfied.

```text
[ ] Real menu bar items can be discovered.
[ ] Third-party status items appear in discovery.
[ ] User can select/unselect items.
[ ] Selection survives Atoll restart.
[ ] Selection survives third-party app restart.
[ ] Real status item image is used when capture succeeds.
[ ] App icon fallback works when capture fails.
[ ] Missing image does not hide the item.
[ ] Settings → Menu Bar exists.
[ ] Menu Bar Atoll tab appears only when enabled.
[ ] Selected items render in Atoll.
[ ] Left click triggers original visible status item.
[ ] Right click is supported where possible.
[ ] Scanner/capture does not block MainActor.
[ ] No overlapping/racing scans.
[ ] No runaway polling.
[ ] Observers/timers/tasks are cleaned up correctly.
[ ] NOTICE attribution is updated.
[ ] Debug build passes.
[ ] Relevant tests pass.
```

---

# 37. Manual validation

On a real Mac, test available examples such as:

```text
Clash / Surge / another VPN client
Docker
OneDrive / Dropbox
WeChat
Wi-Fi
Bluetooth
Volume
Battery
```

For each available item check:

```text
Discovered
Selectable
Rendered
Click works
Restart rematches
```

If a specific application behaves unusually, document it rather than adding unrelated hacks that destabilize the generic architecture.

---

# 38. Expected Phase 1 limitations

It is acceptable to finish Phase 1 with these documented limitations:

```text
Original macOS status items remain visible.
Some private WindowServer behavior may vary by macOS release.
Some items may not expose stable titles.
Some custom status items may not capture correctly.
Menu bar auto-hide may reduce reliability.
Multi-display behavior is intentionally limited.
Hidden/off-screen original items are not handled yet.
```

These are Phase 2+ concerns.

---

# 39. Build verification

First inspect schemes:

```bash
xcodebuild -list -project DynamicIsland.xcodeproj
```

Then build using the actual scheme:

```bash
xcodebuild \
  -project DynamicIsland.xcodeproj \
  -scheme <ACTUAL_SCHEME> \
  -configuration Debug \
  build
```

Run relevant tests using the project's valid test destination/scheme.

Do not finish with known compiler errors introduced by this task.

---

# 40. Git behavior

Work on:

```text
feature/menu-bar-drawer
```

Do not directly develop on `dev`.

Keep the changes scoped to this feature.

Do not refactor unrelated modules such as:

```text
Music
Shelf
Stats
Clipboard
Terminal
HUD
Lock Screen
Extensions
Audio
```

---

# 41. Required final Codex report

At completion, return these exact sections:

```text
## Added files
## Modified files
## Architecture
## Build result
## Test result
## Manual verification status
## Known limitations
## Phase 2 readiness
```

### Build result

Include the exact command and whether it passed.

### Test result

Include the exact command and result.

### Manual verification status

Clearly distinguish what was actually tested on a macOS UI from what was only compiled/unit-tested.

---

# 42. Phase 2 preview — do not implement

Phase 2 will eventually add:

```text
Atoll hidden section
menu bar item movement
temporary reveal
temp click
wait for original menu/popover to close
re-hide
restore-all emergency action
crash recovery
clean shutdown marker
```

Future flow:

```text
selected item
  ↓
hide/move from normal menu bar
  ↓
show in Atoll
  ↓
click Atoll item
  ↓
temporarily reveal original item
  ↓
trigger original click
  ↓
wait for menu/popover to close
  ↓
restore item to hidden section
```

Do not add any of this in the current task.

---

# Final task statement

> Implement **Atoll Menu Bar Drawer Phase 1**: discover real macOS menu bar/status items, create stable identities, persist user selection, display selected items inside a new Atoll `Menu Bar` tab using real captured item images with graceful fallbacks, and forward left/right clicks to the original visible status items. Keep all private WindowServer code isolated, reuse Atoll's existing infrastructure, add tests and attribution, build successfully, and stop before implementing hiding/moving behavior.
