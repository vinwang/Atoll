// Standalone safety checks. Compile with MenuBar/Managers/MenuBarHiddenSection.swift,
// MenuBar/Core/MenuBarOverflowBoundary.swift, the two MenuBar/Models files, and the
// built Defaults module/object (-profile-generate). Stubs isolate OS movement:
// these tests never move, hide or click the user's menu items.
import AppKit
import Defaults

@_cdecl("AXIsProcessTrusted") private func testAXIsProcessTrusted() -> Bool { true }

enum Logger {
    enum Category { case error, debug, lifecycle }
    static func log(_ message: String, category: Category) {}
}

private final class OwnStatusItemProbe: @unchecked Sendable {
    static let shared = OwnStatusItemProbe()

    private let lock = NSLock()
    private var requestStart: UInt64?
    private var requestEnd: UInt64?
    private var heartbeatTimes: [UInt64] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        requestStart = nil
        requestEnd = nil
        heartbeatTimes = []
    }

    func beginRequest() {
        lock.lock()
        defer { lock.unlock() }
        requestStart = DispatchTime.now().uptimeNanoseconds
    }

    func endRequest() {
        lock.lock()
        defer { lock.unlock() }
        requestEnd = DispatchTime.now().uptimeNanoseconds
    }

    func recordHeartbeat() {
        lock.lock()
        defer { lock.unlock() }
        heartbeatTimes.append(DispatchTime.now().uptimeNanoseconds)
    }

    var completedWithMainHeartbeat: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let requestStart, let requestEnd else { return false }
        return heartbeatTimes.contains { $0 >= requestStart && $0 <= requestEnd }
    }

    var requestCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestStart != nil && requestEnd != nil
    }
}

private let hiddenTestSuite = UserDefaults(suiteName: "Atoll.HiddenSectionTests.\(UUID())")!
extension Defaults.Keys {
    static let enableMenuBarDrawer = Key<Bool>("enableMenuBarDrawer", default: false, suite: hiddenTestSuite)
    static let menuBarHideSelectedItems = Key<Bool>("menuBarHideSelectedItems", default: false, suite: hiddenTestSuite)
    static let menuBarHiddenSessionActive = Key<Bool>("menuBarHiddenSessionActive", default: false, suite: hiddenTestSuite)
    static let selectedMenuBarItems = Key<[String]>("selectedMenuBarItems", default: [], suite: hiddenTestSuite)
}
struct MenuBarItemScanner {
    func scan() async -> [ManagedMenuBarItem] { [] }
}
enum MenuBarAccessibilityBridge {
    struct OwnStatusItem: Equatable, Sendable {
        let identifier: String?
        let frame: CGRect
    }
    static func ownStatusItems() -> [OwnStatusItem] {
        precondition(!Thread.isMainThread, "AX requests must not block the main run loop")
        OwnStatusItemProbe.shared.beginRequest()
        Thread.sleep(forTimeInterval: 1.2)
        OwnStatusItemProbe.shared.endRequest()
        guard let screen = NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return []
        }
        let display = CGDisplayBounds(number.uint32Value)
        let y = display.minY + 8
        return [
            .init(identifier: "Atoll.MenuBarDrawer.Boundary",
                  frame: CGRect(x: display.minX + 140, y: y, width: 18, height: 22)),
            .init(identifier: "Atoll.MenuBarDrawer.Control",
                  frame: CGRect(x: display.minX + 110, y: y, width: 22, height: 22)),
        ]
    }
}
enum MenuBarWindowBridge {
    static func windowFrame(_ id: CGWindowID) -> CGRect? { nil }
}
enum MenuBarLayout {
    nonisolated static func menusRightEdge(pid: pid_t) -> CGFloat? { nil }
}
enum MenuBarItemInteractionError: Error { case itemUnavailable }
final class MenuBarItemInteractionService {
    static let shared = MenuBarItemInteractionService()
    func cancelPendingMove() {}
    func move(_ item: ManagedMenuBarItem, to point: CGPoint) async throws { fatalError("Unexpected move") }
    func leftClick(_ item: ManagedMenuBarItem) async throws { fatalError("Unexpected click") }
    func rightClick(_ item: ManagedMenuBarItem) async throws { fatalError("Unexpected click") }
}
@MainActor final class MenuBarItemManager {
    static let shared = MenuBarItemManager()
    func refreshNow() {}
}
@MainActor final class SettingsWindowController {
    static let shared = SettingsWindowController()
    func showWindow() {}
}

@main struct MenuBarHiddenSectionRegression {
    static func item(_ name: String, x: CGFloat, windowID: CGWindowID = 1) -> ManagedMenuBarItem {
        .init(identity: .init(bundleIdentifier: name, title: name, ownerName: name),
              windowID: windowID, ownerPID: 1, frame: CGRect(x: x, y: 0, width: 20, height: 24),
              displayName: name, bundleIdentifier: name, ownerName: name, isOnScreen: true)
    }

    @MainActor static func main() async {
        _ = NSApplication.shared
        let nativeOverflow = MenuBarOverflowBoundary.isNativeOverflowSystem
        assert(MenuBarHiddenSection.validWindowID(-1) == nil)
        assert(MenuBarHiddenSection.validWindowID(0) == nil)
        assert(MenuBarHiddenSection.validWindowID(Int(UInt32.max) + 1) == nil)
        assert(MenuBarHiddenSection.validWindowID(1) == 1)
        assert(MenuBarHiddenSection.coreGraphicsFrame(
            CGRect(x: 100, y: 1056, width: 18, height: 24),
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        ) == CGRect(x: 100, y: 0, width: 18, height: 24))
        assert(MenuBarHiddenSection.coreGraphicsFrame(
            CGRect(x: -1820, y: 2136, width: 18, height: 24),
            screenFrame: CGRect(x: -1920, y: 1080, width: 1920, height: 1080),
            displayBounds: CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        ) == CGRect(x: -1820, y: -1080, width: 18, height: 24))

        let selected = item("selected", x: 40)
        let other = item("other", x: 100)
        let divider = CGRect(x: 70, y: 0, width: 18, height: 24)
        let ids: Set<String> = [selected.id]
        assert(MenuBarHiddenSection.canCollapse(items: [selected, other], selectedIDs: ids, divider: divider))
        assert(!MenuBarHiddenSection.canCollapse(items: [selected, item("unselected", x: 10)], selectedIDs: ids, divider: divider))
        assert(!MenuBarHiddenSection.canCollapse(items: [], selectedIDs: ids, divider: divider))
        assert(!MenuBarHiddenSection.canCollapse(items: [other], selectedIDs: ids, divider: divider))
        assert(!MenuBarHiddenSection.canCollapse(items: [selected], selectedIDs: ids, divider: .zero))
        assert(MenuBarHiddenSection.canCollapse(items: [item("selected", x: 40, windowID: 0)], selectedIDs: ids, divider: divider))

        // macOS 27 decides by the side of the divider, never by moving items.
        let control = CGRect(x: 130, y: 0, width: 22, height: 24)
        assert(MenuBarOverflowBoundary.hiddenSide(of: [selected, other], boundary: divider).map(\.id) == [selected.id])
        assert(MenuBarOverflowBoundary.side(of: control, relativeTo: divider) == .right)
        assert(MenuBarOverflowBoundary.concealingLength(regionWidth: 700) == 668)

        let section = MenuBarHiddenSection.shared
        Defaults[.menuBarHideSelectedItems] = true
        Defaults[.menuBarHiddenSessionActive] = true
        section.prepareForLaunch()
        // Nothing outlives the process on macOS 27, so a stale marker is harmless there.
        assert(Defaults[.menuBarHideSelectedItems] == nativeOverflow, "Unclean exit must disable hiding before macOS 27")
        assert(!Defaults[.menuBarHiddenSessionActive])
        Defaults[.menuBarHideSelectedItems] = true
        section.prepareForLaunch()
        assert(Defaults[.menuBarHideSelectedItems], "Clean launch preserves preference")
        section.restoreAll()
        section.restoreAll()
        assert(!section.isHidden)
        assert(section.hiddenSideItems.isEmpty)
        assert(!Defaults[.menuBarHiddenSessionActive])
        await section.updateHiddenSide(with: [selected, other])
        assert(section.hiddenSideItems.isEmpty, "No divider means no hidden side")
        section.layoutDidChange(.application)
        assert(Defaults[.menuBarHideSelectedItems], "Layout changes without controls change nothing")
        Defaults[.enableMenuBarDrawer] = true
        OwnStatusItemProbe.shared.reset()
        let heartbeat = Timer(timeInterval: 0.02, repeats: true) { _ in
            OwnStatusItemProbe.shared.recordHeartbeat()
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        section.configure()
        let deadline = ContinuousClock.now + .seconds(4)
        while !OwnStatusItemProbe.shared.requestCompleted, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        heartbeat.invalidate()
        assert(OwnStatusItemProbe.shared.requestCompleted, "The delayed own-item AX probe should run")
        assert(OwnStatusItemProbe.shared.completedWithMainHeartbeat,
               "The main run loop must keep processing timer heartbeats during the delayed AX probe")
        assert(!section.isHidden)
        assert(!Defaults[.menuBarHiddenSessionActive], "Failed preparation must not mark a hidden session")
        section.restoreAll()
        print("PASS: collapse safety, invalid window IDs, multi-display coordinates, overflow-side decisions, delayed AX off main thread with live main heartbeat, failed preparation, crash recovery, repeated restore")
    }
}
