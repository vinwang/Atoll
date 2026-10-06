// Standalone checks for the production click service. Run with
// tests/run-menu-bar-item-interaction-service-regression.sh. Its temporary
// source copy redirects event posting and cursor calls to spies, so real input
// events are never posted and the real cursor is never moved.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@_cdecl("AXIsProcessTrusted") private func testAXIsProcessTrusted() -> Bool { true }

enum Logger {
    enum Category { case error, debug, lifecycle }
    static func log(_ message: String, category: Category) {}
}

struct MenuBarItemScanner {
    @MainActor static var result: [ManagedMenuBarItem] = []
    @MainActor static var resultsByDisplay: [CGRect: [ManagedMenuBarItem]] = [:]
    @MainActor static var requestedDisplays: [CGRect?] = []
    @MainActor static var requestedAllDisplays: [Bool] = []
    @MainActor func scan(targetDisplay: CGRect? = nil, allDisplays: Bool = false) async -> [ManagedMenuBarItem] {
        Self.requestedDisplays.append(targetDisplay)
        Self.requestedAllDisplays.append(allDisplays)
        if allDisplays { return Self.result }
        if let targetDisplay, let result = Self.resultsByDisplay[targetDisplay] { return result }
        if targetDisplay == nil, !Self.resultsByDisplay.isEmpty { return [] }
        return Self.result
    }
}

@MainActor struct TestRunningApplication {
    let activationPolicy: NSApplication.ActivationPolicy
    let bundleIdentifier: String?
    let bundleURL: URL?
    let menuBarOnly: Bool

    var isTerminated: Bool { false }
}

struct TestApplicationBundle {
    let menuBarOnly: Bool

    func object(forInfoDictionaryKey key: String) -> Any? {
        key == "LSUIElement" ? menuBarOnly : nil
    }
}

struct OpenApplicationRequest {
    let url: URL
    let activates: Bool
}

@MainActor enum TestApplicationProbe {
    static var applications: [pid_t: TestRunningApplication] = [:]
    static var openRequests: [OpenApplicationRequest] = []
    static var bundleLookups: [URL] = []

    static func reset() {
        applications = [:]
        openRequests = []
        bundleLookups = []
    }

    static func application(for processIdentifier: pid_t) -> TestRunningApplication? {
        applications[processIdentifier]
    }

    static func bundle(for url: URL) -> TestApplicationBundle? {
        bundleLookups.append(url)
        guard let application = applications.values.first(where: { $0.bundleURL == url }) else { return nil }
        return TestApplicationBundle(menuBarOnly: application.menuBarOnly)
    }

    static func openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration) async throws {
        openRequests.append(.init(url: url, activates: configuration.activates))
    }
}

enum MenuBarAccessibilityBridge {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pressResult = false
    nonisolated(unsafe) private static var pressedItems: [ManagedMenuBarItem] = []

    static func configure(result: Bool) {
        lock.lock()
        defer { lock.unlock() }
        pressResult = result
        pressedItems = []
    }

    static func press(_ item: ManagedMenuBarItem) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pressedItems.append(item)
        return pressResult
    }

    static var presses: [ManagedMenuBarItem] {
        lock.lock()
        defer { lock.unlock() }
        return pressedItems
    }
}

enum MenuBarWindowBridge {
    static func windowFrame(_ windowID: CGWindowID) -> CGRect? { nil }
}

enum MenuBarOverflowBoundary {
    static func isOnBar(_ frame: CGRect, strips: [CGRect]) -> Bool {
        strips.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }
}

struct PostedEvent {
    let type: CGEventType
    let flags: CGEventFlags
    let timestamp: UInt64
    let windowUnderPointer: Int64
    let windowUnderPointerThatCanHandle: Int64
    let privateWindowField: Int64
    let overlayIgnoresMouseEvents: [Bool]
}

@MainActor enum TestOverlayProbe {
    static var panels: [NSPanel] = []
}

class DynamicIslandWindow: NSPanel {}

enum TestCoreGraphicsSpy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var postedEvents: [PostedEvent] = []
    nonisolated(unsafe) private static var hideCount = 0
    nonisolated(unsafe) private static var warpCount = 0
    nonisolated(unsafe) private static var showCount = 0
    nonisolated(unsafe) private static var actions: [String] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        postedEvents = []
        hideCount = 0
        warpCount = 0
        showCount = 0
        actions = []
    }

    @MainActor static func post(_ event: CGEvent, tap: CGEventTapLocation) {
        lock.lock()
        defer { lock.unlock() }
        postedEvents.append(.init(
            type: event.type,
            flags: event.flags,
            timestamp: DispatchTime.now().uptimeNanoseconds,
            windowUnderPointer: event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
            windowUnderPointerThatCanHandle: event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent),
            privateWindowField: event.getIntegerValueField(CGEventField(rawValue: 0x33)!),
            overlayIgnoresMouseEvents: TestOverlayProbe.panels.map(\.ignoresMouseEvents)
        ))
        switch event.type {
        case .leftMouseDown: actions.append("leftMouseDown")
        case .leftMouseUp: actions.append("leftMouseUp")
        case .rightMouseDown: actions.append("rightMouseDown")
        case .rightMouseUp: actions.append("rightMouseUp")
        default: actions.append("other")
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            Task { @MainActor in
                TestOverlayProbe.panels[2].ignoresMouseEvents = true
            }
        }
    }

    static func hideCursor() {
        lock.lock()
        defer { lock.unlock() }
        hideCount += 1
        actions.append("hide")
    }

    static func warpCursor(_ point: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        warpCount += 1
        actions.append("warp")
    }

    static func showCursor() {
        lock.lock()
        defer { lock.unlock() }
        showCount += 1
        actions.append("show")
    }

    static var events: [PostedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return postedEvents
    }

    static var cursorCounts: (hide: Int, warp: Int, show: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hideCount, warpCount, showCount)
    }

    static var actionOrder: [String] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }
}

@main struct MenuBarItemInteractionServiceRegression {
    @MainActor private static func item(
        windowID: CGWindowID = 77,
        frame: CGRect = CGRect(x: 30, y: 10, width: 20, height: 20)
    ) -> ManagedMenuBarItem {
        .init(identity: .init(bundleIdentifier: "test.interaction", title: "test-item", ownerName: "test"),
              windowID: windowID, ownerPID: 4242, frame: frame,
              displayName: "test-item", bundleIdentifier: "test.interaction", ownerName: "test", isOnScreen: true)
    }

    private static func window(_ id: CGWindowID, frame: CGRect) -> MenuBarWindowInfo {
        .init(windowID: id, frame: frame, ownerPID: 4242, ownerName: "Music",
              bundleIdentifier: "com.example.music", title: "Music", isOnScreen: true)
    }

    private static func verifyDisplayFilterRunsBeforeIdentityDeduplication() {
        let external = window(101, frame: CGRect(x: 2200, y: 0, width: 24, height: 24))
        let builtIn = window(102, frame: CGRect(x: 400, y: 0, width: 24, height: 24))
        let builtInDisplay = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let selectedDisplayItems = MenuBarItemScanner.filteredItems(
            from: [external, builtIn], targetScreenFrame: builtInDisplay
        )
        assert(selectedDisplayItems.count == 1 && selectedDisplayItems[0].windowID == 102,
               "Filtering to the built-in display must discard the external duplicate before deduplication")
        assert(selectedDisplayItems[0].frame == builtIn.frame,
               "The retained menu item must use the built-in display frame")

        let unfilteredItems = MenuBarItemScanner.filteredItems(from: [external, builtIn])
        assert(unfilteredItems.count == 1 && unfilteredItems[0].windowID == 101,
               "Without a target display, the first duplicate remains selected")
    }

    private static func verifyDrawerScreenUsesWindowCenterWhenWindowScreenIsNil() {
        let builtIn = ProbeScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let external = ProbeScreen(id: 2, frame: CGRect(x: -808, y: 982, width: 3440, height: 1440))
        let window = ProbeWindow(frame: CGRect(x: 411, y: 764, width: 690, height: 222), screen: nil)
        let probe = DrawerScreenProbe(window: window, screens: [external, builtIn])

        assert(CGPoint(x: window.frame.midX, y: window.frame.midY) == CGPoint(x: 756, y: 875))
        assert(probe.drawerScreen == builtIn,
               "The drawer click should use the built-in display containing the window center when window.screen is nil")
    }

    @MainActor private static func installOverlayPanels() {
        let rect = CGRect(x: 30, y: 10, width: 20, height: 20)
        let acceptsClicks = DynamicIslandWindow(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let initiallyIgnoresClicks = DynamicIslandWindow(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let hud = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .screenSaver
        acceptsClicks.level = .mainMenu + 3
        initiallyIgnoresClicks.level = .mainMenu + 3
        acceptsClicks.ignoresMouseEvents = false
        initiallyIgnoresClicks.ignoresMouseEvents = true
        TestOverlayProbe.panels = [acceptsClicks, initiallyIgnoresClicks, hud]
        let appWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        assert(TestOverlayProbe.panels.allSatisfy { appWindows.contains(ObjectIdentifier($0)) },
               "Both overlay panels must be registered with the app")
    }

    @MainActor private static func assertFallback(
        button: CGMouseButton,
        expectedTypes: [CGEventType],
        cancelAfterDown: Bool = false,
        targetDisplay: CGRect? = nil
    ) async throws {
        let target = item()
        TestOverlayProbe.panels[2].ignoresMouseEvents = false
        TestApplicationProbe.reset()
        if button == .right {
            TestApplicationProbe.applications[target.ownerPID] = .init(
                activationPolicy: .regular,
                bundleIdentifier: target.bundleIdentifier,
                bundleURL: URL(fileURLWithPath: "/Applications/Test Interaction.app"),
                menuBarOnly: false
            )
        }
        MenuBarItemScanner.result = [target]
        MenuBarItemScanner.resultsByDisplay = [:]
        MenuBarItemScanner.requestedDisplays = []
        MenuBarAccessibilityBridge.configure(result: false)
        TestCoreGraphicsSpy.reset()

        if cancelAfterDown {
            let click = Task { try await MenuBarItemInteractionService.shared.leftClick(target) }
            let deadline = ContinuousClock.now + .seconds(2)
            while TestCoreGraphicsSpy.events.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            assert(TestCoreGraphicsSpy.events.map(\.type) == [.leftMouseDown], "The injected down event should be observed before cancellation")
            click.cancel()
            do {
                try await click.value
                assertionFailure("Cancellation should propagate from the click")
            } catch is CancellationError {
                // Expected; the service's defer must still release the button.
            }
        } else if button == .left {
            try await MenuBarItemInteractionService.shared.leftClick(target, targetDisplay: targetDisplay)
        } else {
            try await MenuBarItemInteractionService.shared.rightClick(target, targetDisplay: targetDisplay)
        }

        assert(MenuBarItemScanner.requestedDisplays.count == 1 && MenuBarItemScanner.requestedDisplays[0] == targetDisplay,
               "The service must pass its target display through to the scanner")
        assert(TestApplicationProbe.openRequests.isEmpty,
               "Right clicks and non-regular left-click targets must not request native reopen")

        let events = TestCoreGraphicsSpy.events
        assert(events.map(\.type) == expectedTypes, "Expected event order \(expectedTypes), got \(events.map(\.type))")
        assert(events.allSatisfy { $0.flags.rawValue == 0 }, "Synthetic click events must use neutral flags")
        assert(events.allSatisfy {
            $0.windowUnderPointer == 0 && $0.windowUnderPointerThatCanHandle == 0 && $0.privateWindowField == 0
        }, "Fallback click events must not retain the stale scanned window ID")
        assert(events.filter { $0.type == (button == .right ? .rightMouseUp : .leftMouseUp) }.count == 1,
               "Every synthetic click must release its button exactly once")
        if events.count == 2 && !cancelAfterDown {
            let delay = events[1].timestamp - events[0].timestamp
            assert(delay >= 40_000_000, "Mouse up should follow down after about 50ms (observed \(delay)ns)")
        }
        let cursor = TestCoreGraphicsSpy.cursorCounts
        assert(cursor.hide == 1 && cursor.warp == 1 && cursor.show == 1,
               "Cursor cleanup should hide, restore, and show exactly once: \(cursor)")
        let prefix = button == .right ? "rightMouse" : "leftMouse"
        assert(TestCoreGraphicsSpy.actionOrder == ["hide", "\(prefix)Down", "\(prefix)Up", "warp", "show"],
               "Input and cursor cleanup order should be stable: \(TestCoreGraphicsSpy.actionOrder)")
        assert(events.allSatisfy { Array($0.overlayIgnoresMouseEvents.prefix(2)) == [true, true] },
               "Notch panels must ignore mouse input while click events are posted")
        assert(events.first?.overlayIgnoresMouseEvents == [true, true, false],
               "The click override must not affect the independent HUD")
        assert(TestOverlayProbe.panels.map(\.ignoresMouseEvents) == [false, true, true],
               "Cleanup must preserve the HUD's interactivity update during the click")
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        verifyDisplayFilterRunsBeforeIdentityDeduplication()
        verifyDrawerScreenUsesWindowCenterWhenWindowScreenIsNil()
        let requestedBuiltInDisplay = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let appURL = URL(fileURLWithPath: "/Applications/Test Interaction.app")

        let regularTarget = item(windowID: 70)
        TestApplicationProbe.reset()
        TestApplicationProbe.applications[regularTarget.ownerPID] = .init(
            activationPolicy: .regular,
            bundleIdentifier: regularTarget.bundleIdentifier,
            bundleURL: appURL,
            menuBarOnly: false
        )
        MenuBarItemScanner.result = []
        MenuBarItemScanner.resultsByDisplay = [:]
        MenuBarItemScanner.requestedDisplays = []
        MenuBarAccessibilityBridge.configure(result: true)
        TestCoreGraphicsSpy.reset()
        try await MenuBarItemInteractionService.shared.leftClick(regularTarget, targetDisplay: requestedBuiltInDisplay)
        assert(TestApplicationProbe.openRequests.count == 1
                && TestApplicationProbe.openRequests[0].url == appURL
                && TestApplicationProbe.openRequests[0].activates,
               "A matching regular app left click should request native reopen with activation")
        assert(TestApplicationProbe.bundleLookups == [appURL],
               "Native reopen eligibility must inspect the matched app's bundle metadata")
        assert(MenuBarItemScanner.requestedDisplays.isEmpty && MenuBarAccessibilityBridge.presses.isEmpty,
               "Native reopen should return before scanning or AX pressing")
        assert(TestCoreGraphicsSpy.events.isEmpty, "Native reopen should not synthesize mouse events")

        let accessoryOrdinaryTarget = item(windowID: 71)
        TestApplicationProbe.reset()
        TestApplicationProbe.applications[accessoryOrdinaryTarget.ownerPID] = .init(
            activationPolicy: .accessory,
            bundleIdentifier: accessoryOrdinaryTarget.bundleIdentifier,
            bundleURL: appURL,
            menuBarOnly: false
        )
        MenuBarItemScanner.result = []
        MenuBarItemScanner.requestedDisplays = []
        MenuBarAccessibilityBridge.configure(result: true)
        TestCoreGraphicsSpy.reset()
        try await MenuBarItemInteractionService.shared.leftClick(accessoryOrdinaryTarget)
        assert(TestApplicationProbe.openRequests.count == 1
                && TestApplicationProbe.openRequests[0].url == appURL
                && TestApplicationProbe.openRequests[0].activates,
               "An accessory process with an ordinary app bundle should request native reopen")
        assert(TestApplicationProbe.bundleLookups == [appURL],
               "Accessory reopen eligibility must inspect the app bundle metadata")
        assert(MenuBarItemScanner.requestedDisplays.isEmpty && MenuBarAccessibilityBridge.presses.isEmpty
                && TestCoreGraphicsSpy.events.isEmpty,
               "An ordinary accessory app should reopen before scanner, AX, or synthetic input")

        let nonzeroWindowItem = item(windowID: 77)
        TestApplicationProbe.reset()
        TestApplicationProbe.applications[nonzeroWindowItem.ownerPID] = .init(
            activationPolicy: .accessory,
            bundleIdentifier: nonzeroWindowItem.bundleIdentifier,
            bundleURL: appURL,
            menuBarOnly: true
        )
        MenuBarItemScanner.result = [nonzeroWindowItem]
        MenuBarItemScanner.resultsByDisplay = [:]
        MenuBarItemScanner.requestedDisplays = []
        MenuBarAccessibilityBridge.configure(result: true)
        TestCoreGraphicsSpy.reset()
        try await MenuBarItemInteractionService.shared.leftClick(nonzeroWindowItem, targetDisplay: requestedBuiltInDisplay)
        assert(MenuBarItemScanner.requestedDisplays.count == 1 && MenuBarItemScanner.requestedDisplays[0] == requestedBuiltInDisplay,
               "An explicit target display must be passed unchanged to scanner.scan")
        assert(MenuBarAccessibilityBridge.presses.map(\.windowID) == [77], "AX press must receive the nonzero window ID")
        assert(TestCoreGraphicsSpy.events.isEmpty, "A successful AX press must not synthesize mouse events")
        assert(TestCoreGraphicsSpy.cursorCounts.hide == 0 && TestCoreGraphicsSpy.cursorCounts.show == 0,
               "AX success must not touch cursor visibility")
        assert(TestApplicationProbe.openRequests.isEmpty,
               "An LSUIElement accessory app must keep using scanner and AX press")
        assert(TestApplicationProbe.bundleLookups == [appURL],
               "The LSUIElement fallback must come from the app bundle metadata")

        TestApplicationProbe.reset()
        TestApplicationProbe.applications[nonzeroWindowItem.ownerPID] = .init(
            activationPolicy: .regular,
            bundleIdentifier: "test.different.bundle",
            bundleURL: appURL,
            menuBarOnly: false
        )
        MenuBarItemScanner.result = [nonzeroWindowItem]
        MenuBarItemScanner.resultsByDisplay = [:]
        MenuBarItemScanner.requestedDisplays = []
        MenuBarAccessibilityBridge.configure(result: true)
        TestCoreGraphicsSpy.reset()
        try await MenuBarItemInteractionService.shared.leftClick(nonzeroWindowItem)
        assert(TestApplicationProbe.openRequests.isEmpty,
               "A bundle identifier mismatch must not request native reopen")
        assert(MenuBarItemScanner.requestedDisplays == [nil] && MenuBarAccessibilityBridge.presses.count == 1,
               "A bundle mismatch should continue through the normal scanner and AX path")

        TestApplicationProbe.reset()
        TestApplicationProbe.applications[nonzeroWindowItem.ownerPID] = .init(
            activationPolicy: .regular,
            bundleIdentifier: nonzeroWindowItem.bundleIdentifier,
            bundleURL: appURL,
            menuBarOnly: false
        )
        MenuBarItemScanner.requestedDisplays = []
        MenuBarAccessibilityBridge.configure(result: true)
        TestCoreGraphicsSpy.reset()
        let canceledOpen = Task.detached {
            try await MenuBarItemInteractionService.shared.leftClick(nonzeroWindowItem)
        }
        canceledOpen.cancel()
        var canceledBeforeReopen = false
        do {
            try await canceledOpen.value
        } catch is CancellationError {
            canceledBeforeReopen = true
        }
        assert(canceledBeforeReopen, "Cancellation should stop the pending native reopen")
        assert(TestApplicationProbe.openRequests.isEmpty && MenuBarItemScanner.requestedDisplays.isEmpty,
               "A canceled left click must not open or fall through to scanning")
        assert(MenuBarAccessibilityBridge.presses.isEmpty && TestCoreGraphicsSpy.events.isEmpty,
               "Cancellation must not produce AX or synthetic input")
        TestApplicationProbe.reset()

        let originalTarget = item(frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let globalLatest = item(windowID: 145, frame: CGRect(x: 812, y: 40, width: 24, height: 24))
        MenuBarItemScanner.result = [globalLatest]
        MenuBarItemScanner.resultsByDisplay = [requestedBuiltInDisplay: []]
        MenuBarItemScanner.requestedDisplays = []
        MenuBarItemScanner.requestedAllDisplays = []
        MenuBarAccessibilityBridge.configure(result: true)
        TestCoreGraphicsSpy.reset()
        try await MenuBarItemInteractionService.shared.leftClick(originalTarget, targetDisplay: requestedBuiltInDisplay)
        assert(MenuBarItemScanner.requestedDisplays.count == 2
                && MenuBarItemScanner.requestedDisplays[0] == requestedBuiltInDisplay
                && MenuBarItemScanner.requestedDisplays[1] == nil,
               "A target-display miss should retry the global scan exactly once")
        assert(MenuBarItemScanner.requestedAllDisplays == [false, true],
               "Fallback must explicitly request all displays, not the default main-display scan")
        assert(MenuBarAccessibilityBridge.presses.count == 1
                && MenuBarAccessibilityBridge.presses[0].frame == globalLatest.frame
                && MenuBarAccessibilityBridge.presses[0].windowID == globalLatest.windowID,
               "AX press must receive the current global item frame and window ID")
        assert(TestCoreGraphicsSpy.events.isEmpty, "The fallback AX match must not send synthetic input")

        let unrelated = ManagedMenuBarItem(
            identity: .init(bundleIdentifier: "test.other", title: "other-item", ownerName: "test"),
            windowID: 146, ownerPID: 4242, frame: CGRect(x: 900, y: 40, width: 24, height: 24),
            displayName: "other-item", bundleIdentifier: "test.other", ownerName: "test", isOnScreen: true
        )
        MenuBarItemScanner.result = [unrelated]
        MenuBarItemScanner.resultsByDisplay = [requestedBuiltInDisplay: []]
        MenuBarItemScanner.requestedDisplays = []
        MenuBarItemScanner.requestedAllDisplays = []
        MenuBarAccessibilityBridge.configure(result: true)
        TestCoreGraphicsSpy.reset()
        var missingItemThrowsUnavailable = false
        do {
            try await MenuBarItemInteractionService.shared.leftClick(originalTarget, targetDisplay: requestedBuiltInDisplay)
        } catch MenuBarItemInteractionError.itemUnavailable {
            missingItemThrowsUnavailable = true
        }
        assert(missingItemThrowsUnavailable, "An item absent from both scans must report itemUnavailable")
        assert(MenuBarItemScanner.requestedDisplays.count == 2
                && MenuBarItemScanner.requestedDisplays[0] == requestedBuiltInDisplay
                && MenuBarItemScanner.requestedDisplays[1] == nil,
               "A failed targeted lookup should make one global fallback scan")
        assert(MenuBarItemScanner.requestedAllDisplays == [false, true],
               "The missing-item fallback must explicitly scan all displays")
        assert(MenuBarAccessibilityBridge.presses.isEmpty && TestCoreGraphicsSpy.events.isEmpty,
               "A missing item must not issue AX presses or mouse events")

        installOverlayPanels()
        try await assertFallback(button: .left, expectedTypes: [.leftMouseDown, .leftMouseUp])
        try await assertFallback(button: .right, expectedTypes: [.rightMouseDown, .rightMouseUp])
        try await assertFallback(button: .left, expectedTypes: [.leftMouseDown, .leftMouseUp], cancelAfterDown: true)
        for panel in TestOverlayProbe.panels { panel.close() }
        print("PASS: native reopen eligibility for regular and accessory apps, LSUIElement fallback and cancellation; display fallback; AX success; neutral down/up, overlay, cursor and click-lock regressions")
    }
}
