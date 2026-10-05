import AppKit
import XCTest
@testable import Atoll

final class MenuBarItemTests: XCTestCase {
    private let statusWindowLayer = Int(CGWindowLevelForKey(.statusWindow))

    func testIdentityIgnoresWindowInstanceChanges() {
        let identity = MenuBarItemIdentity(
            bundleIdentifier: "com.example.clash",
            title: "Clash",
            ownerName: "Clash"
        )
        let first = ManagedMenuBarItem(
            identity: identity,
            windowID: 1,
            ownerPID: 10,
            frame: CGRect(x: 1, y: 1, width: 20, height: 20),
            displayName: "Clash",
            bundleIdentifier: identity.bundleIdentifier,
            ownerName: identity.ownerName,
            isOnScreen: true
        )
        let second = ManagedMenuBarItem(
            identity: identity,
            windowID: 2,
            ownerPID: 11,
            frame: CGRect(x: 2, y: 2, width: 20, height: 20),
            displayName: "Clash",
            bundleIdentifier: identity.bundleIdentifier,
            ownerName: identity.ownerName,
            isOnScreen: true
        )

        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(first.windowID, second.windowID)
    }

    func testFilteringRejectsInvalidDuplicateAndSelfItems() {
        let valid = info(
            id: 1,
            bundleIdentifier: "com.example.clash",
            ownerName: "Clash",
            title: "Clash"
        )
        let duplicate = info(
            id: 2,
            bundleIdentifier: "com.example.clash",
            ownerName: "Clash",
            title: "Clash"
        )
        let invalidFrame = info(
            id: 3,
            bundleIdentifier: "com.example.invalid",
            ownerName: "Invalid",
            title: "Invalid",
            frame: .zero
        )
        let selfItem = info(
            id: 4,
            bundleIdentifier: "com.atoll",
            ownerName: "Atoll",
            title: "Atoll"
        )
        let controlCenter = info(
            id: 5,
            bundleIdentifier: "com.apple.controlcenter",
            ownerName: "Control Center",
            title: "WiFi"
        )

        let result = MenuBarItemScanner.filteredItems(
            from: [valid, duplicate, invalidFrame, selfItem, controlCenter],
            excludedBundleIdentifier: "com.atoll",
            excludedPID: 999
        )

        XCTAssertEqual(result.map(\.windowID), [1, 5])
    }

    func testSelectionMatchesReorderedResultsAndKeepsMissingIDsPersistable() {
        let clash = item(bundleIdentifier: "com.example.clash", title: "Clash", ownerName: "Clash")
        let docker = item(bundleIdentifier: "com.docker.docker", title: "Docker", ownerName: "Docker")
        let selectedIDs = [clash.id, docker.id]

        let reordered = MenuBarItemSelection.matching([docker, clash], selectedIDs: selectedIDs)
        XCTAssertEqual(Set(reordered.map(\.id)), Set(selectedIDs))

        let afterDockerQuit = MenuBarItemSelection.matching([clash], selectedIDs: selectedIDs)
        XCTAssertEqual(afterDockerQuit.map(\.id), [clash.id])
        XCTAssertEqual(selectedIDs, [clash.id, docker.id])
    }

    func testFilteringAcceptsAccessibilityItemWithoutWindowID() {
        let item = info(
            id: kCGNullWindowID,
            bundleIdentifier: "com.example.clash",
            ownerName: "Clash",
            title: "Clash"
        )

        XCTAssertEqual(MenuBarItemScanner.filteredItems(from: [item]).map(\.displayName), ["Clash"])
    }

    func testMergingKeepsRealWindowsAndAddsAccessibilityOnlyItems() {
        let windowItem = item(bundleIdentifier: "com.example.work", title: "Work", ownerName: "Work")
        let duplicate = ManagedMenuBarItem(
            identity: windowItem.identity,
            windowID: kCGNullWindowID,
            ownerPID: windowItem.ownerPID,
            frame: windowItem.frame,
            displayName: windowItem.displayName,
            bundleIdentifier: windowItem.bundleIdentifier,
            ownerName: windowItem.ownerName,
            isOnScreen: true
        )
        let accessibilityOnly = item(bundleIdentifier: "com.example.wechat", title: "WeChat", ownerName: "WeChat")

        XCTAssertEqual(MenuBarItemScanner.merged([windowItem], [duplicate, accessibilityOnly]), [windowItem, accessibilityOnly])
    }

    @MainActor
    func testIconCacheReusesCurrentItemsAndDropsRemovedItems() {
        let cache = MenuBarItemImageCache()
        let first = item(bundleIdentifier: "com.example.first", title: "First", ownerName: "First")
        let second = item(bundleIdentifier: "com.example.second", title: "Second", ownerName: "Second")
        cache.refresh(for: [first, second])
        let original = cache.image(for: first)
        cache.refresh(for: [first])
        XCTAssertTrue(cache.image(for: first) === original)
        XCTAssertNil(cache.image(for: second))
        cache.refresh(for: [])
        XCTAssertTrue(cache.images.isEmpty)
    }

    @MainActor
    func testSettingsContentIsReleasedAndRecreated() {
        let controller = SettingsWindowController.shared
        weak var content: NSView?
        autoreleasepool {
            controller.showWindow()
            content = controller.window?.contentView
            XCTAssertNotNil(content)
            controller.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(controller.window?.contentView)
        XCTAssertNil(content)
        controller.showWindow()
        XCTAssertNotNil(controller.window?.contentView)
        controller.close()
    }

    func testMediaRemoteAdapterExitsWhenParentIsGone() throws {
        let scriptURL = try XCTUnwrap(
            Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
        )
        let frameworkPath = try XCTUnwrap(
            Bundle.main.resourceURL?
                .appendingPathComponent("MediaRemoteAdapter.framework")
                .path
        )
        let process = MediaRemoteAdapterProcess.stream(
            scriptURL: scriptURL,
            frameworkPath: frameworkPath,
            parentProcessIdentifier: Int32.max
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = expectation(description: "adapter watchdog exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        wait(for: [exited], timeout: 3)

        if process.isRunning {
            process.terminate()
        }
        XCTAssertFalse(process.isRunning)
    }

    // MARK: - macOS 27 native overflow boundary

    func testOverflowBoundaryConcealingLengthStaysInsideRegion() {
        XCTAssertEqual(MenuBarOverflowBoundary.concealingLength(regionWidth: 700), 668)
        XCTAssertEqual(MenuBarOverflowBoundary.concealingLength(regionWidth: 40), 32)
    }

    func testOverflowBoundarySideFollowsOriginsOnTheSameRow() {
        let divider = CGRect(x: 300, y: 4, width: 18, height: 24)
        XCTAssertEqual(MenuBarOverflowBoundary.side(of: CGRect(x: 270, y: 4, width: 28, height: 24), relativeTo: divider), .left)
        XCTAssertEqual(MenuBarOverflowBoundary.side(of: CGRect(x: 334, y: 4, width: 28, height: 24), relativeTo: divider), .right)
        // Hosted hit areas may overlap at their edges after a drop.
        XCTAssertEqual(MenuBarOverflowBoundary.side(of: CGRect(x: 312, y: 4, width: 28, height: 24), relativeTo: divider), .right)
        // Overflowed frames below the bar and coincident transient frames decide nothing.
        XCTAssertNil(MenuBarOverflowBoundary.side(of: CGRect(x: 7, y: 1121, width: 28, height: 24), relativeTo: divider))
        XCTAssertNil(MenuBarOverflowBoundary.side(of: divider, relativeTo: divider))
    }

    func testOverflowBoundaryFindsTheHiddenSide() {
        let divider = CGRect(x: 300, y: 4, width: 18, height: 24)
        let hidden = item(
            bundleIdentifier: "com.example.hidden", title: "Hidden", ownerName: "Hidden",
            frame: CGRect(x: 240, y: 4, width: 28, height: 24)
        )
        let visible = item(
            bundleIdentifier: "com.example.visible", title: "Visible", ownerName: "Visible",
            frame: CGRect(x: 400, y: 4, width: 28, height: 24)
        )

        XCTAssertEqual(
            MenuBarOverflowBoundary.hiddenSide(of: [hidden, visible], boundary: divider).map(\.id),
            [hidden.id]
        )
        XCTAssertEqual(
            MenuBarOverflowBoundary.side(of: CGRect(x: 360, y: 4, width: 22, height: 24), relativeTo: divider),
            .right,
            "the control must sit right of the divider, or hiding would conceal it too"
        )
    }

    func testOverflowBoundaryLeavesAtollOnlySideVisible() {
        let divider = CGRect(x: 300, y: 4, width: 18, height: 24)
        let own = item(
            bundleIdentifier: "com.atoll", title: "Atoll", ownerName: "Atoll",
            frame: CGRect(x: 240, y: 4, width: 28, height: 24)
        )
        let thirdParty = item(
            bundleIdentifier: "com.example.hidden", title: "Hidden", ownerName: "Hidden",
            frame: CGRect(x: 200, y: 4, width: 28, height: 24)
        )

        XCTAssertTrue(MenuBarOverflowBoundary.hideableSide(
            of: [own], boundary: divider, ownFrames: [own.frame], ownBundleIdentifier: "com.atoll"
        ).isEmpty)
        XCTAssertEqual(MenuBarOverflowBoundary.hideableSide(
            of: [own, thirdParty], boundary: divider, ownFrames: [own.frame], ownBundleIdentifier: "com.atoll"
        ).map(\.id), [thirdParty.id])
    }

    func testOverflowBoundaryRejectsOffBarFrames() {
        let strip = MenuBarOverflowBoundary.menuBarStrip(of: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        XCTAssertTrue(MenuBarOverflowBoundary.isOnBar(CGRect(x: 100, y: 4, width: 28, height: 24), strips: [strip]))
        XCTAssertFalse(MenuBarOverflowBoundary.isOnBar(CGRect(x: -1, y: 1105, width: 40, height: 24), strips: [strip]))
        XCTAssertFalse(MenuBarOverflowBoundary.isOnBar(CGRect(x: 100, y: 4, width: 0, height: 24), strips: [strip]))
        XCTAssertFalse(MenuBarOverflowBoundary.isOnBar(CGRect(x: CGFloat.nan, y: 4, width: 28, height: 24), strips: [strip]))
    }

    func testFilteringExcludesNativeOverflowOwnersAndOffBarFrames() {
        let strip = MenuBarOverflowBoundary.menuBarStrip(of: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        let third = info(
            id: kCGNullWindowID, bundleIdentifier: "com.example.clash", ownerName: "Clash", title: "Clash",
            frame: CGRect(x: 100, y: 4, width: 28, height: 24)
        )
        let overflowControl = info(
            id: kCGNullWindowID, bundleIdentifier: "com.apple.MenuBarAgent", ownerName: "MenuBarAgent",
            title: "Show hidden menu bar items", frame: CGRect(x: 140, y: 4, width: 28, height: 24)
        )
        let ghost = info(
            id: kCGNullWindowID, bundleIdentifier: "com.example.ghost", ownerName: "Ghost", title: "Ghost",
            frame: CGRect(x: -1, y: 1105, width: 40, height: 24)
        )

        let result = MenuBarItemScanner.filteredItems(
            from: [third, overflowControl, ghost],
            menuBarStrips: [strip],
            excludedOwners: MenuBarItemScanner.nativeOverflowExcludedOwners
        )

        XCTAssertEqual(result.map(\.displayName), ["Clash"])
    }

    private func info(
        id: CGWindowID,
        bundleIdentifier: String,
        ownerName: String,
        title: String,
        frame: CGRect = CGRect(x: 1, y: 1, width: 20, height: 20)
    ) -> MenuBarWindowInfo {
        MenuBarWindowInfo(
            windowID: id,
            frame: frame,
            ownerPID: 100,
            ownerName: ownerName,
            bundleIdentifier: bundleIdentifier,
            title: title,
            isOnScreen: true,
            layer: statusWindowLayer
        )
    }

    private func item(
        bundleIdentifier: String,
        title: String,
        ownerName: String,
        frame: CGRect = CGRect(x: 1, y: 1, width: 20, height: 20)
    ) -> ManagedMenuBarItem {
        let identity = MenuBarItemIdentity(
            bundleIdentifier: bundleIdentifier,
            title: title,
            ownerName: ownerName
        )
        return ManagedMenuBarItem(
            identity: identity,
            windowID: 1,
            ownerPID: 100,
            frame: frame,
            displayName: title,
            bundleIdentifier: bundleIdentifier,
            ownerName: ownerName,
            isOnScreen: true
        )
    }
}
