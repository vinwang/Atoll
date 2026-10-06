// Standalone click-lock regression. Run with
// tests/run-menu-bar-hidden-section-click-lock-regression.sh. The generated
// source copy adds only test accessors; interaction and scanner stubs prevent
// real menu-item clicks, moves, or hiding.
import AppKit
import Defaults

@_cdecl("AXIsProcessTrusted") private func testAXIsProcessTrusted() -> Bool { true }

enum Logger {
    enum Category { case error, debug, lifecycle }
    static func log(_ message: String, category: Category) {}
}

private let hiddenTestSuite = UserDefaults(suiteName: "Atoll.HiddenClickTests.\(UUID())")!
extension Defaults.Keys {
    static let enableMenuBarDrawer = Key<Bool>("enableMenuBarDrawer", default: false, suite: hiddenTestSuite)
    static let menuBarHideSelectedItems = Key<Bool>("menuBarHideSelectedItems", default: false, suite: hiddenTestSuite)
    static let menuBarHiddenSessionActive = Key<Bool>("menuBarHiddenSessionActive", default: false, suite: hiddenTestSuite)
    static let selectedMenuBarItems = Key<[String]>("selectedMenuBarItems", default: [], suite: hiddenTestSuite)
}

struct MenuBarItemScanner {
    func scan(targetDisplay: CGRect? = nil) async -> [ManagedMenuBarItem] { [] }
}

enum MenuBarAccessibilityBridge {
    struct OwnStatusItem: Equatable, Sendable {
        let identifier: String?
        let frame: CGRect
    }
    static func ownStatusItems() -> [OwnStatusItem] { [] }
}

enum MenuBarWindowBridge {
    static func windowFrame(_ id: CGWindowID) -> CGRect? { nil }
}

enum MenuBarLayout {
    nonisolated static func menusRightEdge(pid: pid_t) -> CGFloat? { nil }
}

enum MenuBarItemInteractionError: Error { case itemUnavailable }

@MainActor final class MenuBarItemInteractionService {
    static let shared = MenuBarItemInteractionService()
    static var deliveredLeftClicks: [String] = []
    static var deliveredRightClicks: [String] = []
    static var nativeOpenIDs: Set<String> = []
    static var delayedNativeOpenID: String?
    static var nativeOpenRequests: [String] = []
    static var pendingNativeOpen: CheckedContinuation<Void, Never>?

    var clickCount: Int {
        Self.deliveredLeftClicks.count + Self.deliveredRightClicks.count
    }

    static func reset() {
        deliveredLeftClicks = []
        deliveredRightClicks = []
        nativeOpenIDs = []
        delayedNativeOpenID = nil
        nativeOpenRequests = []
        pendingNativeOpen?.resume()
        pendingNativeOpen = nil
    }

    static func configureNativeOpen(ids: Set<String>, delayedID: String? = nil) {
        nativeOpenIDs = ids
        delayedNativeOpenID = delayedID
        nativeOpenRequests = []
    }

    static func openApplication(for item: ManagedMenuBarItem) async throws -> Bool {
        nativeOpenRequests.append(item.id)
        guard nativeOpenIDs.contains(item.id) else { return false }
        if item.id == delayedNativeOpenID {
            await withCheckedContinuation { pendingNativeOpen = $0 }
        }
        return true
    }

    static func releasePendingOpen() {
        pendingNativeOpen?.resume()
        pendingNativeOpen = nil
    }

    func cancelPendingMove() {}
    func move(_ item: ManagedMenuBarItem, to point: CGPoint) async throws { fatalError("Unexpected move") }
    func leftClick(_ item: ManagedMenuBarItem, targetDisplay: CGRect? = nil) async throws { Self.deliveredLeftClicks.append(item.id) }
    func rightClick(_ item: ManagedMenuBarItem, targetDisplay: CGRect? = nil) async throws { Self.deliveredRightClicks.append(item.id) }
}

@MainActor final class MenuBarItemManager {
    static let shared = MenuBarItemManager()
    func refreshNow() {}
}

@MainActor final class SettingsWindowController {
    static let shared = SettingsWindowController()
    func showWindow() {}
}

@main struct MenuBarHiddenSectionClickLockRegression {
    static func item(_ title: String = "click-target", ownerPID: pid_t = .max) -> ManagedMenuBarItem {
        .init(identity: .init(bundleIdentifier: "test.\(title)", title: title, ownerName: "test"),
              windowID: 1, ownerPID: ownerPID, frame: CGRect(x: 40, y: 0, width: 20, height: 24),
              displayName: title, bundleIdentifier: "test.\(title)", ownerName: "test", isOnScreen: true)
    }

    @MainActor private static func clickCompletesWithinTwoSeconds(
        _ section: MenuBarHiddenSection,
        item: ManagedMenuBarItem
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await section.click(item, button: .left)
                    return !Task.isCancelled
                } catch {
                    return false
                }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(2)) } catch { return true }
                return false
            }
            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
    }

    @MainActor static func main() async {
        _ = NSApplication.shared
        let section = MenuBarHiddenSection.shared
        let item = item()
        Defaults[.enableMenuBarDrawer] = true
        assert(DrawerFirstMouseProbe(frame: .zero).acceptsFirstMouse(for: nil),
               "The real drawer view implementation must accept a click as the first mouse event")

        section.testSeedHidden()
        let firstCompleted = await clickCompletesWithinTwoSeconds(section, item: item)
        assert(firstCompleted, "A hidden drawer click must return before the 2-second deadline")
        assert(!section.isBusy, "The normal click delivery must release the busy lock")
        assert(MenuBarItemInteractionService.shared.clickCount == 1, "The first click must reach the interaction stub")
        let firstMonitor = section.testClickMonitorHandle()
        assert(firstMonitor != nil, "A hidden click should start a close monitor")

        try? await section.click(item, button: .left)
        assert(MenuBarItemInteractionService.shared.clickCount == 2,
               "The next app click must reach the interaction stub while the close monitor exists")
        assert(!section.isBusy, "The second click must leave the section unlocked")
        assert(firstMonitor?.isCancelled == true, "A new click must cancel the previous close monitor")
        let restoreMonitor = section.testClickMonitorHandle()
        assert(restoreMonitor != nil, "The second click should start a replacement close monitor")
        section.restoreAll()
        assert(restoreMonitor?.isCancelled == true, "Restore All must cancel the active close monitor")
        assert(!section.isHidden && !section.isBusy)

        let busyNative = Self.item("busy-native", ownerPID: 101)
        MenuBarItemInteractionService.reset()
        MenuBarItemInteractionService.configureNativeOpen(ids: [busyNative.id])
        section.testSeedState(hidden: true, busy: true)
        try? await section.click(busyNative, button: .left)
        assert(MenuBarItemInteractionService.nativeOpenRequests == [busyNative.id],
               "A regular app's first left click must open even while the drawer is busy")
        assert(section.isHidden && section.isBusy,
               "A native reopen while another drawer operation is busy must preserve both states")
        assert(MenuBarItemInteractionService.shared.clickCount == 0,
               "Native reopen should return before the menu-item interaction service")

        let accessory = Self.item("accessory", ownerPID: 102)
        let rightClick = Self.item("right", ownerPID: 103)
        MenuBarItemInteractionService.configureNativeOpen(ids: [rightClick.id])
        try? await section.click(accessory, button: .left)
        try? await section.click(rightClick, button: .right)
        assert(section.isHidden && section.isBusy && MenuBarItemInteractionService.shared.clickCount == 0,
               "Accessory left clicks and right clicks must remain blocked by the existing busy guard")
        assert(!MenuBarItemInteractionService.nativeOpenRequests.contains(rightClick.id),
               "Right clicks must not enter native reopen")

        let pendingFirst = Self.item("pending-first", ownerPID: 104)
        let pendingSecond = Self.item("pending-second", ownerPID: 105)
        MenuBarItemInteractionService.reset()
        MenuBarItemInteractionService.configureNativeOpen(ids: [pendingFirst.id, pendingSecond.id], delayedID: pendingFirst.id)
        section.testSeedState(hidden: true, busy: false)
        let firstOpen = Task<Void, Never> { try? await section.click(pendingFirst, button: .left) }
        let deadline = ContinuousClock.now + .seconds(2)
        while MenuBarItemInteractionService.nativeOpenRequests.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        assert(MenuBarItemInteractionService.nativeOpenRequests == [pendingFirst.id],
               "The first native open should remain suspended in the probe")
        assert(section.isHidden && !section.isBusy,
               "A pending native open must not change hidden state or acquire the drawer lock")
        try? await section.click(pendingSecond, button: .left)
        assert(MenuBarItemInteractionService.nativeOpenRequests == [pendingFirst.id, pendingSecond.id],
               "A second app click must be delivered while the first native open is pending")
        assert(section.isHidden && !section.isBusy,
               "Concurrent native opens must leave drawer state unchanged")
        MenuBarItemInteractionService.releasePendingOpen()
        await firstOpen.value
        assert(section.isHidden && !section.isBusy,
               "Completing the pending native open must leave drawer state unchanged")
        print("PASS: hidden click returns within 2s, second click reaches stub, replaces prior monitor, Restore All cancels active monitor")
    }
}
