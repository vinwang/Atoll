# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Atoll is a macOS menu-bar/notch app (SwiftUI + AppKit, GPL-3.0, forked from boring.notch). Naming is
inconsistent and intentional: the Xcode project, scheme, target and source folder are `DynamicIsland`,
but the product is `Atoll.app` and the Swift module is `Atoll` (tests use `@testable import Atoll`).
The app is an `LSUIElement` (no Dock icon); everything lives in floating notch windows plus a
Settings window.

## Build, run, test

Requirements: an Xcode whose Swift compiler is 6.1+ (Xcode 16.3 or newer; CI notes that Xcode 16.2
cannot build the sources). Language mode is Swift 5 (`SWIFT_VERSION = 5.0`); app deployment target
is macOS 14.6.

```bash
open DynamicIsland.xcodeproj                      # Cmd+R runs Atoll.app

# Debug build from the CLI (Release uses manual Developer ID signing, team 9Y64TRM77N,
# so build Debug or disable signing locally)
xcodebuild build -project DynamicIsland.xcodeproj -scheme DynamicIsland \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# XCTest unit tests (target DynamicIslandTests; the scheme also contains
# DynamicIslandUITests, which launches the app with --uitesting, so filter)
xcodebuild test -project DynamicIsland.xcodeproj -scheme DynamicIsland \
  -destination 'platform=macOS' -only-testing:DynamicIslandTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO

# Single test class / method
xcodebuild test ... -only-testing:DynamicIslandTests/LRCParserTests
xcodebuild test ... -only-testing:DynamicIslandTests/LRCParserTests/testName

# Python checks that CI runs (from repo root)
python3 -m unittest tests.test_privacy_configuration   # entitlements / usage strings / release.yml
python3 -m unittest tests.test_timer_lifecycle         # swiftc-compiles TimerLifecycle + a regression main
```

Gotchas:
- On Xcode 26 the Metal toolchain must be installed (`sudo xcodebuild -downloadComponent MetalToolchain`)
  because `DynamicIsland/metal/visualizer.metal` is compiled.
- CI (`.github/workflows/ci.yml`) only *builds* — headless runners cannot drive a notch app, so no
  XCTest runs there. It strips the `com.apple.security.mach-services` entitlement first because
  amfid kills an ad-hoc-signed app that carries it; do not commit that change.
- `DynamicIsland/` and `Contents/` are Xcode 16 *synchronized folders*: new app source files are
  picked up automatically. `DynamicIslandTests/` and `DynamicIslandUITests/` are classic groups: a
  new test file must be added to `project.pbxproj` (PBXFileReference, PBXBuildFile, group children,
  Sources phase) or it will silently not compile.
- Usage-description strings are build settings (`INFOPLIST_KEY_*`) duplicated in the Debug and
  Release configs of `project.pbxproj`; `tests/test_privacy_configuration.py` asserts exact text
  and counts, so edit both copies.

### Standalone regression scripts (`tests/*.swift`)

Besides XCTest, several checks are plain `swiftc` programs with `@main`, compiled together with the
specific production files they exercise and with stubs for everything else. Each file's header
comment says what to compile it with (some need the built `Defaults` module). Pattern:

```bash
swiftc DynamicIsland/managers/TimerLifecycle.swift tests/TimerLifecycleRegression.swift -o /tmp/t && /tmp/t
scripts/test_claude_keychain.sh      # same pattern for the Keychain reader (needs unlocked login keychain)
ruby scripts/check_lyrics_metadata_order.rb   # asserts statement order inside MusicManager.updateFromPlaybackState
```

Only the two Python-wrapped ones run in CI. The other `scripts/*.rb` files are one-off
`project.pbxproj` surgery scripts, not part of any workflow.

## Repo conventions and CI gates

- **PRs target `dev`** (CI and changelog validation run on PRs to `dev`; CONTRIBUTING.md's mention
  of `main` is stale). `dev` is auto-merged into `nightly` daily; pushes to `nightly`/`alpha`/
  `beta`/`main` trigger `release.yml`, which derives the channel from the branch name, builds,
  notarizes, publishes a DMG and rewrites `Updates/appcast*.xml` (Sparkle).
- **`CHANGELOG.md` must change in every PR to `dev`** (`validate-changelog.yml`): add `- ` bullets
  under `## [Unreleased]` in a `### Added` / `### Changed` / `### Fixed` / `### Removed` /
  `### Deprecated` / `### Security` heading (Keep a Changelog). Entries reference the PR like
  `(#827)`. The release job turns `[Unreleased]` into release notes and archives it.
- `VERSION` holds the base version (e.g. `2.3.3`); the release job computes channel suffixes and
  build numbers with `agvtool`. Do not hand-bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`.
- Bot commits to leave alone: `chore: update llm pricing data [skip ci]` regenerates
  `DynamicIsland/managers/LLMUsage/pricing.json` daily from OpenRouter; `ci: update appcast` /
  `ci: archive changelog` come from the release job.
- `.gitignore` ignores `*.py`, `*.sh`, `*.txt` and many `*.md` scratch names globally (the two CI
  Python tests are whitelisted with `!`). A new script needs its own `!` exception.
- Code comments, commit messages and `CHANGELOG.md` entries are written in English, matching the
  existing codebase and the upstream project.
- Most Swift files start with the GPL-3.0 header block; keep it on new files. Code adapted from
  other GPL projects (boring.notch, Ice) keeps a "Portions adapted from …" note and an entry in
  `NOTICE`.
- `*.gif`, `*.mov`, `*.mp4` are Git LFS.

## Architecture

### Entry point and windows — `DynamicIsland/DynamicIslandApp.swift`

`DynamicNotchApp` (`@main`) only declares the `MenuBarExtra` menu and the Sparkle
`SPUStandardUpdaterController`. Real setup is in `AppDelegate`: it creates one `DynamicIslandWindow`
(borderless, non-activating panel hosting `ContentView` through `FirstMouseHostingView`) per screen
when `showOnAllDisplays` is on, otherwise a single window on the preferred screen; hides/restores
them on lock/unlock and screen changes; keeps them in a CGS space via `NotchSpaceManager`; and
resizes them from `calculateRequiredNotchSize()` whenever the tab, a HUD, stats rows or lyrics
change the required geometry. It also eagerly instantiates the long-lived managers and starts the
extension servers. `open -a Atoll <file>` lands in `application(_:open:)` and goes to the Shelf.

### Two state objects

- `DynamicIslandViewCoordinator.shared` (`DynamicIslandViewCoordinator.swift`, `ObservableObject`)
  is app-wide UI state: `currentView: NotchViews` (the active tab; `tabOrder` drives slide
  direction; minimalistic mode forces `.home`), `sneakPeek` and `expandingView` (the closed-notch
  HUD / live-activity overlays, see below), selected screen, and a handful of legacy `@AppStorage`
  flags. Its `init` subscribes to every tab-affecting `Defaults` key to enforce a minimum notch
  width — add new tab toggles to that `Publishers.MergeMany` list.
- `DynamicIslandViewModel` (`models/DynamicIslandViewModel.swift`, `@MainActor`) is per-window:
  `notchState` (`.closed`/`.open`), hover/drag/drop flags, popover-active flags (token-based
  registration so several presenters do not clobber each other), notch sizes. Injected into views
  as `@EnvironmentObject var vm`.

### Notch UI

`ContentView.swift` (~3.3k lines) is the root: computes `dynamicNotchSize`, renders the closed
notch (idle animation, live activities, inline HUDs) or the open notch, and routes
`coordinator.currentView` to a tab view. Tabs are assembled in
`components/Tabs/TabSelectionView.swift` from feature-flag `Defaults` (`TabModel`), plus extension
tabs. `components/` is grouped by feature (`Notch/`, `Settings/`, `LockScreen/`, `Calendar/`,
`Tabs/`, …). Adding a tab means: a `NotchViews` case (`enums/generic.swift`), a slot in
`tabOrder`, a `TabModel` in `TabSelectionView`, routing in `ContentView`, a `Defaults` toggle and a
settings page — the Menu Bar tab is the most recent complete example.

### Live activities and HUDs

Closed-notch overlays are typed by `SneakContentType` (volume, brightness, music, battery,
download, timer, reminder, recording, focus, Bluetooth audio, privacy, lock, Caps Lock, extension
payloads). Producers call `coordinator.toggleSneakPeek(status:type:value:icon:title:…)` (auto-hides
after a per-type duration; most types are gated by `enableSystemHUD`) or
`coordinator.toggleExpandingView(status:type:…)` for wider expansions (battery, downloads). Volume/
brightness/keyboard-backlight replace the system OSD; the project references private frameworks
(CoreBrightness, OSD, DisplayServices) and private CGS symbols via `@_silgen_name`. Keep any
private-API access isolated in a single bridge file per feature (`MenuBar/Core/MenuBarWindowBridge.swift`
is the model) and never call it from SwiftUI `body`.

### Managers (`managers/`, ~100 files)

Uniform shape: `final class X: ObservableObject { static let shared = X() }`, `@Published` state,
usually `@MainActor`, Combine subscriptions to `Defaults.publisher(.key)` for settings reactions,
and NSWorkspace/NotificationCenter observers. Blocking IPC (Accessibility, WindowServer,
AppleScript, network) runs off the main actor (`Task.detached`, background queues) and publishes
back on main; `managers/MenuBarLayout.swift` is the reference implementation of that pattern
(refcounted `startTracking`/`stopTracking`, slow poll only while someone is listening).
Central ones: `MusicManager` (playback state, artwork colours, lyrics, favouriting), `StatsManager`,
`TimerManager` + `TimerLifecycle` (pure session-token logic, standalone-testable),
`DownloadManager`, `BatteryStatusViewModel`/`BatteryActivityManager`, `ScreenRecordingManager`,
`PrivacyIndicatorManager`, `DoNotDisturbManager`, `BluetoothAudioManager`,
`NetworkConnectivityManager`, `CapsLockManager`, `CalendarManager`, `ReminderLiveActivityManager`,
`WebcamManager`, `LockScreenManager` (lock state) and `LockScreenPanelManager`, `AudioTap`
(CoreAudio process taps for the waveform and per-app volume), `ShelfStateViewModel`/`TrayDrop`,
`SettingsWindowController`, and `LLMUsage/` (Claude/Codex/Cursor/Antigravity/New API usage
readers, Keychain access, `pricing.json`).

### Media layer (`MediaControllers/`)

`MediaControllerProtocol` (`playbackStatePublisher: AnyPublisher<PlaybackState, Never>`, play/pause/
seek/next/previous/shuffle/repeat, plus favouriting hooks with default no-op implementations).
Implementations: `NowPlayingController` (system Now Playing through the bundled
`mediaremote-adapter/mediaremote-adapter.pl` Perl script + prebuilt `MediaRemoteAdapter.framework`
and the `Contents/Helpers/NowPlayingTestClient` helper, all copied into the app bundle),
`AppleMusicController` and `SpotifyController` (AppleScript), `YouTubeMusicController` (auto-selected
while Pear Desktop runs), `AmazonMusicController`, `TidalController`, `CiderController`.
`MusicManager.createController(for:)` swaps the active one from `Defaults[.mediaController]`
(`MediaControllerType`); when `NowPlayingController` is unavailable on the running macOS it falls
back to Apple Music, and the default itself depends on the OS version (`defaultMediaController`).
Lyrics come from LRCLIB first, then NetEase, parsed from LRC and cached in `MusicManager`.

### Settings and persistence

The [Defaults](https://github.com/sindresorhus/Defaults) package is the store. **All keys live in
`extension Defaults.Keys` at the bottom of `models/Constants.swift`** (from ~line 984), grouped by
`// MARK: <feature>`; value enums conform to `Defaults.Serializable` and sit in the same file or
`enums/generic.swift`. Use `@Default(.key)` in views, `Defaults[.key]` elsewhere,
`Defaults.publisher(.key)` to react. One-off migrations are `static func migrate…()` in that same
extension, guarded by `didMigrate…` keys and called at launch. Secrets (Spotify/Cider tokens, New
API keys) go to the Keychain, not Defaults. The Settings window is
`components/Settings/SettingsView.swift` (~9.7k lines): `SettingsTab` enumerates pages with
group/title/icon/tint/search entries; page bodies are partly inline in that file and partly
separate views in the same folder (e.g. `MenuBarSettingsView.swift`).

### Lock screen

`LockScreenManager` tracks lock state; `LockScreenPanelManager` shows a separate window on the lock
screen via the `SkyLightWindow` package. Widgets are in `components/LockScreen/` (music panel with
fullscreen artwork, weather via Open-Meteo or wttr.in, timer, reminders/calendar, battery and
Bluetooth). Notch windows are hidden while locked.

### Menu Bar drawer (`MenuBar/`, current feature work)

Lets users show real third-party status items inside a notch tab and optionally hide them from the
menu bar. Layering (dependencies only point down): `Models/` (`MenuBarItemIdentity` — stable
`bundleID::title::owner` id that survives app restarts; `ManagedMenuBarItem` — runtime window/PID/
frame, never persisted) → `Core/` (`MenuBarWindowBridge` is the *only* file with private CGS calls;
`MenuBarWindowInfo`, `MenuBarItemScanner`, `MenuBarItemImageCache`, `MenuBarItemInteractionService`
for click forwarding) → `Managers/MenuBarItemManager` → `Views/`. `MenuBarHiddenSection` implements
the optional hidden section with fail-open recovery (`menuBarHiddenSessionActive` marker, Restore
All). Design and status docs: `docs/CODEX_MENU_BAR_DRAWER_TASK.md`, `docs/MENU_BAR_PHASE_2_STATUS.md`.
This is unrelated to `managers/MenuBarLayout.swift` (frontmost-app menu geometry) — keep them
separate. Adapted from Ice (GPL) — attribution is in `NOTICE`.

### Extensions

`AtollExtensionKit` (SPM) defines the wire types; `ExtensionRPCServer` and `ExtensionXPCServiceHost`
let third-party apps contribute live activities, lock-screen widgets and notch "experiences"
(tabs), gated by the `enableThirdPartyExtensions*` keys with per-app authorization entries and
rate-limit records stored in Defaults.

### Native code and other packages

`audio/AudioProcessor.cpp` + `AudioBridge.mm/.h` (exposed via `DynamicIsland-Bridging-Header.h`) do
the C++ audio analysis for the real-time visualizer; `metal/visualizer.metal` is its shader. The
terminal tab is SwiftTerm; idle animations are Lottie (`LottieAnimations/`); global hotkeys use
KeyboardShortcuts; updates use Sparkle with the feed URL chosen at runtime by update channel.

### Logging and localization

- `utils/Logger.swift` defines a project `struct Logger` (shadows OSLog's) —
  `Logger.log("…", category: .ui)` — filtered by `Defaults[.logLevel]`, mirrored to `print` in
  DEBUG. The same file overrides global `print`/`NSLog` to respect the level. Bracketed tags like
  `[MenuBar]`, `[AudioTap]` prefix messages.
- Strings: `DynamicIsland/Localizable.xcstrings` is the string catalog (string-catalog
  localization with `SWIFT_EMIT_LOC_STRINGS`). Use `String(localized:)` / `Text("literal")` for
  anything user-facing; brand names, model ids, SF Symbol names and log labels stay untranslated.
  The root-level `Localizable.xcstrings` is not referenced by the Xcode project.
