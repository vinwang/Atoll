# Menu Bar Drawer — hidden section status

## macOS 27 (native overflow)

macOS 27 draws every status item inside `MenuBarAgent`. There are no
per-item windows (CGS lists none; Atoll's own status item windows report a
`windowNumber` above `CGWindowID` range), and an oversized status item is
discarded instead of pushing its neighbours off screen. The original
Command-drag + 10,000-point divider therefore hid nothing there. The current
implementation follows Ice pull request #980 (`MacOS27NativeMenuBarHiding`,
GPL-3.0). **It only works on a display with a notch** — see the limits below.

- Atoll owns two status items: the control (👁, with a menu) created first
  and the divider ("│", 18 pt) created second. Both have autosave names, so
  their positions persist. Creation order does not decide the final order on
  every display, so the code checks where the control ended up instead of
  assuming.
- Hiding widens the divider to `max(32, regionWidth − 32)`, where
  `regionWidth` is `NSScreen.auxiliaryTopRightArea`. A width inside the
  notch's status region leaves no room there, so macOS moves every item left of
  the divider into the system's own overflow ("Show hidden menu bar items").
  Nothing else is moved; Atoll issues no synthetic drags on macOS 27.
- Revealing restores the 18 pt divider. Keeping it visible avoids Ice's
  withdraw/reinsert/self-drag alignment dance entirely.
- What is hidden is decided by the physical order: the user Command-drags
  items to the left of "│". Settings lists the current hidden side and marks
  items that are not selected for the drawer. Hiding is refused (fail open)
  when the control would be concealed as well.
- A safety check 300 ms after widening reads Atoll's own items through
  Accessibility; if any of them left the menu bar strip, the divider is
  restored.
- Clicking a drawer item reveals, waits 300 ms for the reflow, rescans, clicks
  where MenuBarAgent draws the item (Accessibility press for left clicks;
  CGEvent with the cursor hidden for right clicks), then hides again after the
  owner's interface windows close. A 60-second timeout leaves items visible.
- App launch/termination and Space changes no longer disable the setting.
  An unclean exit needs no recovery: the spacer dies with the process and the
  items return.
- `com.apple.MenuBarAgent` items (the overflow control and the system controls
  it hosts) are excluded from discovery; they can be neither hidden nor moved.
  Items are only accepted when their centre lies in a display's top 40 pt.
- The app's own menu bar icon can end up inside the hidden section; the
  control's menu carries Settings and Quit so nothing is lost with it.

## macOS 26 and earlier

Unchanged: the divider is Command-dragged left of the selected items, each
selected item is dragged left of the divider, and the divider is widened to
10,000 pt. The pointer is now hidden with `CGDisplayHideCursor` while
synthetic mouse events are posted and restored afterwards, which removes the
pointer flicker in the menu bar.

## Limits

- Requires Accessibility permission.
- **macOS 27 hiding needs a display with a notch.** The spacer works by filling
  the notch's own status region, which is narrow enough that nothing else fits;
  macOS then moves the spacer's left neighbours into its overflow. A display
  without a notch has a wide status area that simply absorbs the spacer: on a
  3440 pt display, hiding widened the divider to 2600 pt, every item stayed on
  the bar and only the order changed, checked by hit testing along the whole
  bar. Hiding is therefore refused on such a display with a message saying so.
- Only the divider's display is handled.
- Items in the system overflow show their app icon in the drawer; other apps'
  status images are not available through any API on macOS 27.
- Rapid toggling can leave a fading overflow animation (Ice reports the same).
- Clock and Control Center are fixed by the system and cannot be hidden.
- Identity still comes from the Accessibility title/description, which some
  apps (Clash Verge) change with their state; those selections stop matching
  until re-selected.
- macOS records "menu bar items are not displayed" per app **path**: an app that
  was ever removed from the menu bar by the user (or by a menu bar migration)
  gets its items placed nowhere, which looks exactly like a bug in Atoll. The
  settings page says so, and System Settings → Control Center can allow them
  again; running the app from a different path clears it too.

## Verification

- Debug build and `DynamicIslandTests/MenuBarItemTests` (pure decisions:
  concealing length, region width, side detection, items between the divider
  and control, off-bar frames, MenuBarAgent exclusion).
- `tests/MenuBarHiddenSectionRegression.swift` compiled standalone with
  stubbed OS interaction.
- Manual acceptance on this machine (macOS 27.0, notched built-in display
  plus an external display without a notch) is recorded in the pull request.
