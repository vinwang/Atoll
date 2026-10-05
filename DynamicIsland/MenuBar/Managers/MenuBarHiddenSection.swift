/*
 * Atoll (DynamicIsland), Copyright (C) 2024-2026 Atoll Contributors
 * GPL-3.0. Section expansion and Command-drag behavior inspired by Ice:
 * https://github.com/jordanbaird/Ice (GPL-3.0). The macOS 27 path follows
 * Ice pull request #980 (MacOS27NativeMenuBarHiding): an Atoll-owned spacer
 * that fills the status region pushes its left neighbours into the system's
 * own overflow, and nothing else is moved.
 */

import AppKit
import Defaults

/// Fail open: uncertain placement or menu lifetime must never hide an item.
@MainActor
final class MenuBarHiddenSection: NSObject, ObservableObject {
    static let shared = MenuBarHiddenSection()
    static let controlAutosaveName = "Atoll.MenuBarDrawer.Control"
    static let boundaryAutosaveName = "Atoll.MenuBarDrawer.Boundary"

    enum LayoutChange {
        case application
        case space
        case display
        case wake
    }

    @Published private(set) var isHidden = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    /// Items on the concealed side of the divider. Only meaningful on macOS 27,
    /// where the side an item sits on is what decides whether it is hidden.
    @Published private(set) var hiddenSideItems: [ManagedMenuBarItem] = []
    private var divider: NSStatusItem?
    private var recoveryItem: NSStatusItem?
    /// Popped up on a right click of the control; the left click toggles hiding.
    private var controlMenu: NSMenu?
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var sessionItems: [ManagedMenuBarItem] = []
    private var hiddenDisplaySignature: String?
    /// Last scan, kept only for the temporary state dump.
    private var scanSnapshot: [ManagedMenuBarItem] = []
    /// Last scan before the on-bar filter, for the same reason.
    private var scanSnapshotRaw: [ManagedMenuBarItem] = []
    private let scanner = MenuBarItemScanner()
    private var ownStatusItems: [MenuBarAccessibilityBridge.OwnStatusItem] = []
    private var ownStatusRequest = 0

    private struct OwnPlacement {
        let boundary: CGRect
        let control: CGRect
        let screen: NSScreen
        let display: CGRect
    }

    func prepareForLaunch() {
        // On macOS 27 nothing outlives the process: the spacer vanishes with it
        // and the overflowed items return on their own.
        if Defaults[.menuBarHiddenSessionActive], !MenuBarOverflowBoundary.isNativeOverflowSystem {
            Defaults[.menuBarHideSelectedItems] = false
            message = "上次隐藏会话未正常结束，已停用自动隐藏。所有项目保持可见。"
        }
        Defaults[.menuBarHiddenSessionActive] = false
        // The preference publishers only fire on a change, so a launch with the
        // setting already on would otherwise never create the divider or hide
        // anything. macOS 27 moves nothing, so hiding here is safe to do at
        // launch; earlier systems wait to be asked, as they always have.
        if MenuBarOverflowBoundary.isNativeOverflowSystem,
           Defaults[.enableMenuBarDrawer], Defaults[.menuBarHideSelectedItems] {
            configure()
        }
    }

    func configure() {
        Logger.log(
            "[MenuBar] configure enabled=\(Defaults[.enableMenuBarDrawer]) selectedOnly=\(Defaults[.menuBarHideSelectedItems]) hidden=\(isHidden) busy=\(isBusy)",
            category: .debug
        )
        guard Defaults[.enableMenuBarDrawer], Defaults[.menuBarHideSelectedItems] else {
            restoreAll()
            return
        }
        guard !isBusy else { return }
        operation = Task {
            if MenuBarOverflowBoundary.isNativeOverflowSystem {
                await concealNatively()
            } else {
                await arrangeAndHide()
            }
        }
    }

    /// Collapse is permitted only if every item left of the divider was selected.
    static func canCollapse(items: [ManagedMenuBarItem], selectedIDs: Set<String>, divider: CGRect) -> Bool {
        guard !items.isEmpty, divider.width > 0, divider.height > 0,
              items.allSatisfy({ $0.frame.width > 0 && $0.frame.height > 0 }) else { return false }
        let left = items.filter { $0.frame.midX < divider.midX }
        return !left.isEmpty && left.allSatisfy { selectedIDs.contains($0.id) }
    }

    private func createControls() {
        guard divider == nil else { return }
        // New status items are inserted at the left of the existing ones, so
        // the control goes first and the divider lands immediately left of it.
        let recovery = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        recovery.autosaveName = Self.controlAutosaveName
        recovery.button?.image = Self.controlImage(hidden: false)
        recovery.button?.setAccessibilityIdentifier(Self.controlAutosaveName)
        // The button toggles hiding itself: with a menu attached the first
        // click only opened the menu, so hiding took two. The menu is kept for
        // the right button, where it still holds Restore All, Settings, Quit.
        recovery.button?.target = self
        recovery.button?.action = #selector(controlButtonClicked)
        recovery.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        recovery.button?.toolTip = "点按隐藏或显示；右键更多选项"
        let menu = NSMenu()
        menu.delegate = self
        let restore = NSMenuItem(title: "恢复全部菜单栏项目", action: #selector(restoreFromMenu), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        // The app's own menu bar icon can end up in the hidden section, so the
        // control has to carry the same actions.
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "退出 Atoll", action: #selector(quitFromMenu), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        controlMenu = menu
        recoveryItem = recovery

        let item = NSStatusBar.system.statusItem(withLength: MenuBarOverflowBoundary.revealedLength)
        item.autosaveName = Self.boundaryAutosaveName
        item.button?.title = "│"
        item.button?.toolTip = "Atoll 隐藏区域分隔线"
        item.button?.setAccessibilityIdentifier(Self.boundaryAutosaveName)
        // Never a click target on macOS 27: widened, it spans the whole status region.
        if MenuBarOverflowBoundary.isNativeOverflowSystem {
            item.button?.isEnabled = false
        }
        divider = item

        // Visibility is persisted per autosave name, so a saved "not visible"
        // from an earlier run would otherwise create both items hidden.
        item.isVisible = true
        recovery.isVisible = true
    }

    private static func controlImage(hidden: Bool) -> NSImage? {
        NSImage(
            systemSymbolName: hidden ? "eye.slash" : "eye",
            accessibilityDescription: hidden ? "显示隐藏的项目" : "隐藏菜单栏项目"
        )
    }

    /// Left click toggles hiding; right click (or control-click) opens the menu.
    @objc private func controlButtonClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        Logger.log(
            "[MenuBar] eye clicked secondary=\(isSecondary) hidden=\(isHidden) busy=\(isBusy) dividerVisible=\(divider?.isVisible ?? false)",
            category: .lifecycle
        )
        guard isSecondary, let button = recoveryItem?.button, let controlMenu else {
            toggleHidingFromControl()
            return
        }
        controlMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func toggleHidingFromControl() {
        if isBusy {
            // Startup can begin an automatic hide before the status item is
            // ready for input. Treat a click during that window as cancel.
            generation += 1
            operation?.cancel()
            operation = nil
            reveal()
            return
        }
        if isHidden {
            generation += 1
            operation?.cancel()
            operation = nil
            message = nil
            reveal()
            return
        }
        if Defaults[.menuBarHideSelectedItems] {
            configure()
        } else {
            // The preference publisher runs configure() for us.
            Defaults[.menuBarHideSelectedItems] = true
        }
    }

    /// Menu items act on `menuDidClose`: removing a status item, or resizing the
    /// bar, while its own menu is still tracking re-enters AppKit's menu
    /// bookkeeping and trips its assertions.
    private var pendingMenuAction: (() -> Void)?

    @objc private func restoreFromMenu() {
        pendingMenuAction = { [weak self] in
            Defaults[.menuBarHideSelectedItems] = false
            self?.restoreAll()
        }
    }

    @objc private func openSettingsFromMenu() {
        pendingMenuAction = {
            SettingsWindowController.shared.showWindow()
        }
    }

    @objc private func quitFromMenu() {
        pendingMenuAction = {
            NSApplication.shared.terminate(nil)
        }
    }

    func restoreAll() {
        let hadControls = divider != nil
        Logger.log(
            "[MenuBar] restore all hadControls=\(hadControls) hidden=\(isHidden) sessionItems=\(sessionItems.count) generation=\(generation)",
            category: .lifecycle
        )
        generation += 1
        operation?.cancel()
        operation = nil
        MenuBarItemInteractionService.shared.cancelPendingMove()
        reveal()
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        if let recoveryItem { NSStatusBar.system.removeStatusItem(recoveryItem) }
        divider = nil
        recoveryItem = nil
        controlMenu = nil
        sessionItems = []
        hiddenDisplaySignature = nil
        ownStatusItems = []
        hiddenSideItems = []
        Defaults[.menuBarHiddenSessionActive] = false
        if hadControls { MenuBarItemManager.shared.refreshNow() }
    }

    func layoutDidChange(_ change: LayoutChange) {
        guard divider != nil else { return }
        Logger.log(
            "[MenuBar] layout changed=\(String(describing: change)) hidden=\(isHidden) busy=\(isBusy) native=\(MenuBarOverflowBoundary.isNativeOverflowSystem)",
            category: .lifecycle
        )
        // Opening an app or switching Spaces does not invalidate the hidden
        // section. Restoring here makes every article/app transition flash the
        // whole bar and, on a second display, leaves the items visible.
        guard change == .display, isHidden, !isBusy else { return }

        let signature = currentDisplaySignature()
        guard signature != hiddenDisplaySignature else {
            Logger.log("[MenuBar] ignored display notification without geometry change", category: .debug)
            return
        }

        if MenuBarOverflowBoundary.isNativeOverflowSystem {
            // The native overflow width can change with a real display change;
            // remeasure it from a revealed bar, then record the new signature.
            reveal()
            configure()
            return
        }

        Defaults[.menuBarHideSelectedItems] = false
        restoreAll()
        message = "菜单栏布局发生变化，已恢复可见；检查后可重新启用隐藏。"
    }

    private func reveal() {
        divider?.button?.title = "│"
        divider?.length = MenuBarOverflowBoundary.revealedLength
        divider?.isVisible = true
        isHidden = false
        recoveryItem?.button?.image = Self.controlImage(hidden: false)
        Defaults[.menuBarHiddenSessionActive] = false
    }

    private func currentDisplaySignature() -> String {
        NSScreen.screens
            .map { "\($0.localizedName)=\($0.frame)" }
            .sorted()
            .joined(separator: "|")
    }

    // MARK: - Temporary diagnostics
    // TODO: remove once the macOS 27 hidden section is confirmed on real
    // hardware. Writes what the section sees to
    // ~/Library/Caches/Atoll/menubar-hidden-state.txt on every attempt, so a
    // machine that cannot show the divider can be diagnosed without the UI.
    private func dumpState(_ stage: String) {
        var lines = [
            "stage: \(stage)",
            "axTrusted: \(AXIsProcessTrusted())",
            "isHidden: \(isHidden) isBusy: \(isBusy)",
            "message: \(message ?? "nil")",
            "divider: \(divider == nil ? "nil" : "visible=\(divider!.isVisible) length=\(divider!.length) enabled=\(divider!.button?.isEnabled ?? false) title=\(divider!.button?.title ?? "")")",
            "control: \(recoveryItem == nil ? "nil" : "visible=\(recoveryItem!.isVisible)")",
        ]
        for screen in NSScreen.screens {
            lines.append("screen \(screen.localizedName) frame=\(screen.frame) auxTopRight=\(String(describing: screen.auxiliaryTopRightArea))")
        }
        if let placement = ownPlacement() {
            lines.append("placement: boundary=\(placement.boundary) control=\(placement.control) display=\(placement.display)")
        } else {
            lines.append("placement: nil")
            lines.append("dividerFrame: \(String(describing: dividerFrame()))")
            lines.append("appKitBoundary: \(String(describing: appKitFrame(of: divider)?.frame))")
            lines.append("appKitControl: \(String(describing: appKitFrame(of: recoveryItem)?.frame))")
        }
        lines.append("ownAXItems: \(ownStatusItems.map { "\($0.identifier ?? "nil")@\($0.frame)" })")
        lines.append("rawScanned: \(scanSnapshotRaw.count)")
        for item in scanSnapshotRaw.prefix(14) {
            lines.append("   \(item.displayName) pid=\(item.ownerPID) frame=\(item.frame) onBar=\(MenuBarOverflowBoundary.isOnBar(item.frame, strips: NSScreen.screens.compactMap { screen in (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { MenuBarOverflowBoundary.menuBarStrip(of: CGDisplayBounds($0.uint32Value)) } }))")
        }
        if AXIsProcessTrusted() {
            let stripDisplay = ownPlacement()?.display
            let strip = stripDisplay.map(MenuBarOverflowBoundary.menuBarStrip(of:)) ?? .zero
            let items = scanSnapshotRaw.filter { MenuBarOverflowBoundary.isOnBar($0.frame, strips: [strip]) }
            lines.append("withPlacementStrip: \(items.count)")
            lines.append("hiddenSide: \(MenuBarOverflowBoundary.hiddenSide(of: items, boundary: ownPlacement()?.boundary ?? .zero).count)")
            lines.append("itemFrames: \(items.sorted { $0.frame.minX < $1.frame.minX }.map { "\($0.displayName)@\($0.frame.minX)" })")
        }
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atoll/menubar-hidden-state.txt")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        Logger.log(
            "[MenuBar] \(stage) hidden=\(isHidden) busy=\(isBusy) selected=\(Defaults[.selectedMenuBarItems].count) session=\(sessionItems.count) hiddenSide=\(hiddenSideItems.count) placement=\(ownPlacement()?.display ?? .zero)",
            category: .debug
        )
    }

    static func validWindowID(_ windowNumber: Int) -> CGWindowID? {
        guard let id = CGWindowID(exactly: windowNumber), id != kCGNullWindowID else { return nil }
        return id
    }

    private func dividerWindowID() -> CGWindowID? {
        guard let windowNumber = divider?.button?.window?.windowNumber else { return nil }
        return Self.validWindowID(windowNumber)
    }

    static func coreGraphicsFrame(_ appKitFrame: CGRect, screenFrame: CGRect, displayBounds: CGRect) -> CGRect {
        CGRect(
            x: displayBounds.minX + appKitFrame.minX - screenFrame.minX,
            y: displayBounds.minY + screenFrame.maxY - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }

    private static func displayBounds(of screen: NSScreen) -> CGRect? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDisplayBounds(number.uint32Value)
    }

    private func dividerScreenFrames() -> (appKit: CGRect, coreGraphics: CGRect)? {
        guard let screen = divider?.button?.window?.screen,
              let displayBounds = Self.displayBounds(of: screen) else {
            return nil
        }
        return (screen.frame, displayBounds)
    }

    /// The button's frame in CoreGraphics coordinates, from AppKit's own window
    /// for it. The status item windows have no CGWindowID on macOS 27.
    private func appKitFrame(of item: NSStatusItem?) -> (frame: CGRect, screen: NSScreen)? {
        guard let button = item?.button, let window = button.window, let screen = window.screen,
              let displayBounds = Self.displayBounds(of: screen) else {
            return nil
        }
        let appKitFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return (Self.coreGraphicsFrame(appKitFrame, screenFrame: screen.frame, displayBounds: displayBounds), screen)
    }

    private func dividerFrame() -> CGRect? {
        if let windowID = dividerWindowID(), let frame = MenuBarWindowBridge.windowFrame(windowID) {
            return frame
        }
        return appKitFrame(of: divider)?.frame
    }

    /// Both Atoll-owned items, on the same display's menu bar strip.
    ///
    /// On macOS 27 MenuBarAgent draws the items and the app's own window for a
    /// status item is a placeholder with a meaningless frame, so the frames are
    /// read from Accessibility instead. Earlier systems place the windows
    /// themselves and AppKit's own geometry is the right source.
    private func ownPlacement() -> OwnPlacement? {
        if MenuBarOverflowBoundary.isNativeOverflowSystem {
            return accessibilityPlacement()
        }
        guard let boundary = appKitFrame(of: divider), let control = appKitFrame(of: recoveryItem),
              let display = Self.displayBounds(of: boundary.screen),
              display == Self.displayBounds(of: control.screen) else {
            return nil
        }
        let strip = MenuBarOverflowBoundary.menuBarStrip(of: display)
        guard MenuBarOverflowBoundary.isOnBar(boundary.frame, strips: [strip]),
              MenuBarOverflowBoundary.isOnBar(control.frame, strips: [strip]) else {
            return nil
        }
        return OwnPlacement(boundary: boundary.frame, control: control.frame, screen: boundary.screen, display: display)
    }

    /// AX requests can wait on MenuBarAgent or our own accessibility server.
    /// Never issue them on the main run loop, which also services input events.
    @discardableResult
    private func refreshOwnStatusItems() async -> Bool {
        guard divider != nil else { return false }
        let currentGeneration = generation
        ownStatusRequest += 1
        let request = ownStatusRequest
        let own = await Task.detached(priority: .utility) {
            MenuBarAccessibilityBridge.ownStatusItems()
        }.value
        guard !Task.isCancelled, generation == currentGeneration,
              divider != nil, request == ownStatusRequest else { return false }
        ownStatusItems = own
        return true
    }

    /// Atoll's own items as the menu bar reports them: identifiers and frames
    /// in global display coordinates.
    private func accessibilityPlacement() -> OwnPlacement? {
        let own = ownStatusItems
        guard let boundary = own.first(where: { $0.identifier == Self.boundaryAutosaveName }),
              let control = own.first(where: { $0.identifier == Self.controlAutosaveName }) else {
            return nil
        }
        // The divider and recovery control can briefly be rebuilt on a
        // different display from the user's Atoll icon. Hiding there has no
        // useful meaning, so only accept a placement on the icon's display.
        let iconFrames = own
            .filter { $0.identifier != Self.boundaryAutosaveName && $0.identifier != Self.controlAutosaveName }
            .map(\.frame)
        for screen in NSScreen.screens {
            guard let display = Self.displayBounds(of: screen) else { continue }
            let strip = MenuBarOverflowBoundary.menuBarStrip(of: display)
            guard MenuBarOverflowBoundary.isOnBar(boundary.frame, strips: [strip]),
                  MenuBarOverflowBoundary.isOnBar(control.frame, strips: [strip]) else { continue }
            if !iconFrames.isEmpty,
               !iconFrames.contains(where: { MenuBarOverflowBoundary.isOnBar($0, strips: [strip]) }) {
                continue
            }
            return OwnPlacement(boundary: boundary.frame, control: control.frame, screen: screen, display: display)
        }
        return nil
    }

    /// Whether the control — the way back to showing the items again — sits
    /// left of the divider. Atoll's own menu bar icon is not part of this: it
    /// goes into the hidden section with everything else, and the control's
    /// menu carries the same Settings and Quit actions.
    private func controlIsLeftOfBoundary(_ boundary: CGRect) -> Bool {
        guard let control = ownStatusItems
            .first(where: { $0.identifier == Self.controlAutosaveName }) else {
            return true
        }
        return MenuBarOverflowBoundary.side(of: control.frame, relativeTo: boundary) == .left
    }

    // MARK: - macOS 27: native overflow

    private func concealNatively() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await concealNativelyCore()
    }

    /// The hide itself, for callers that already hold `isBusy`.
    private func concealNativelyCore() async {
        let currentGeneration = generation
        message = nil
        defer { dumpState("concealNatively") }
        // The divider is the user's drop target, so it exists whether or not
        // Accessibility has been granted; the measurement below needs the
        // permission and says so when it is missing.
        createControls()
        guard AXIsProcessTrusted() else {
            message = "自动隐藏需要辅助功能权限。"
            return
        }
        do {
            // Inserting a status item is a layout transaction: the menu bar
            // places it a moment later, so wait for our own items to appear
            // rather than giving up after one look.
            var placement: OwnPlacement?
            for _ in 0..<12 {
                let refreshed = await refreshOwnStatusItems()
                try Task.checkCancellation()
                if refreshed, let found = ownPlacement() {
                    placement = found
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard let placement else {
                message = "系统没有在菜单栏显示 Atoll 自己的项目（👁 与「│」）。请在「系统设置 → 控制中心」里允许 Atoll 的菜单栏项目显示，或把 app 放到另一个路径后重试。"
                return
            }
            let strip = MenuBarOverflowBoundary.menuBarStrip(of: placement.display)
            let raw = await scanner.scan()
            scanSnapshotRaw = raw
            let items = raw.filter { MenuBarOverflowBoundary.isOnBar($0.frame, strips: [strip]) }
            scanSnapshot = items
            try Task.checkCancellation()
            guard !controlIsLeftOfBoundary(placement.boundary) else {
                message = "加宽「│」会把 👁 一起藏起来；请按住 ⌘ 把「│」拖到 👁 右侧。"
                return
            }
            let hiddenSide = MenuBarOverflowBoundary.hiddenSide(of: items, boundary: placement.boundary)
            let ownFrames = ownStatusItems
                .filter { $0.identifier != Self.boundaryAutosaveName && $0.identifier != Self.controlAutosaveName }
                .map(\.frame)
            // A stale WindowServer record can identify Atoll's own icon as a
            // third-party item. Never widen the divider for an own-only side.
            let hideable = MenuBarOverflowBoundary.hideableSide(
                of: items,
                boundary: placement.boundary,
                ownFrames: ownFrames,
                ownBundleIdentifier: Bundle.main.bundleIdentifier
            )
            guard !hideable.isEmpty else {
                hiddenSideItems = hiddenSide
                message = "「│」左侧没有可隐藏的项目，只有 Atoll 自己的图标。按住 ⌘ 把要隐藏的图标拖到「│」左侧。"
                return
            }
            // The spacer works by filling the notch's own status region: a
            // narrow region leaves no room, and macOS moves the spacer's left
            // neighbours into its overflow. A display without a notch has a
            // status area wide enough to absorb the spacer instead — measured
            // on a 3440 pt display, nothing overflowed and the items were only
            // reflowed — so hiding is not offered there.
            guard let regionWidth = placement.screen.auxiliaryTopRightArea?.width, regionWidth > 200 else {
                message = "这台显示器没有刘海，系统在这里不会把项目收进隐藏区；隐藏暂不支持无刘海显示器。"
                return
            }
            try Task.checkCancellation()
            guard generation == currentGeneration,
                  Defaults[.enableMenuBarDrawer], Defaults[.menuBarHideSelectedItems] else { return }
            let refreshed = await refreshOwnStatusItems()
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            guard refreshed, let latest = ownPlacement(),
                  latest.display == placement.display, latest.boundary == placement.boundary,
                  latest.control == placement.control else {
                reveal()
                message = "隐藏前菜单栏位置发生变化，已保持显示。"
                return
            }
            sessionItems = hiddenSide
            hiddenSideItems = hiddenSide
            Defaults[.menuBarHiddenSessionActive] = true
            divider?.button?.title = ""
            divider?.length = MenuBarOverflowBoundary.concealingLength(regionWidth: regionWidth)
            isHidden = true
            recoveryItem?.button?.image = Self.controlImage(hidden: true)
            hiddenDisplaySignature = currentDisplaySignature()
            Logger.log("[MenuBar] hidden successfully with native overflow; sessionItems=\(sessionItems.count)", category: .lifecycle)

            // Widening must never push Atoll's own items off the bar.
            try await Task.sleep(for: .milliseconds(300))
            let verified = await refreshOwnStatusItems()
            let own = ownStatusItems
            guard generation == currentGeneration else { return }
            let displaced = own.filter {
                $0.identifier != Self.boundaryAutosaveName
                    && !MenuBarOverflowBoundary.isOnBar($0.frame, strips: [strip])
            }
            guard verified, displaced.isEmpty, let verifiedPlacement = ownPlacement(),
                  verifiedPlacement.display == placement.display else {
                reveal()
                message = "加宽分隔线会把 Atoll 自己的图标挤出菜单栏，已恢复显示。"
                return
            }
            MenuBarItemManager.shared.refreshNow()
        } catch is CancellationError {
            reveal()
        } catch {
            reveal()
            message = "未能完成隐藏，项目保持显示：\(error.localizedDescription)"
            Logger.log("[MenuBar] native hide failed: \(error)", category: .error)
        }
    }

    /// Recomputes which items sit left of the divider from a fresh scan.
    func updateHiddenSide(with items: [ManagedMenuBarItem]) async {
        guard MenuBarOverflowBoundary.isNativeOverflowSystem else { return }
        let refreshed = await refreshOwnStatusItems()
        guard refreshed, let placement = ownPlacement() else {
            if divider == nil, !hiddenSideItems.isEmpty { hiddenSideItems = [] }
            return
        }
        // During a status-item rebuild the divider may spend a few seconds on
        // another display. accessibilityPlacement() then returns nil until it
        // rejoins the Atoll icon, so keep the active hide session intact.
        let strip = MenuBarOverflowBoundary.menuBarStrip(of: placement.display)
        let onBar = items.filter { MenuBarOverflowBoundary.isOnBar($0.frame, strips: [strip]) }
        var side = MenuBarOverflowBoundary.hiddenSide(of: onBar, boundary: placement.boundary)
        if isHidden {
            // Overflowed items report stale frames; the snapshot taken before
            // widening is what was actually concealed.
            let ids = Set(side.map(\.id))
            side += sessionItems.filter { !ids.contains($0.id) }
        }
        if side != hiddenSideItems { hiddenSideItems = side }
    }

    // MARK: - macOS 26 and earlier: Command-drag into an oversized divider

    private func arrangeAndHide() async {
        guard !isBusy else { return }
        isBusy = true
        let currentGeneration = generation
        defer { isBusy = false }
        message = nil
        reveal()
        guard AXIsProcessTrusted() else {
            message = "自动隐藏需要辅助功能权限。"
            return
        }
        createControls()
        do {
            try await Task.sleep(for: .milliseconds(200))
            var items = await scanner.scan()
            try Task.checkCancellation()
            let selected = Set(Defaults[.selectedMenuBarItems])
            guard let boundary = dividerFrame(),
                  let screenFrame = dividerScreenFrames()?.coreGraphics else {
                message = "无法确认当前菜单栏所在显示器，项目保持可见。"
                return
            }
            items = items.filter { screenFrame.intersects($0.frame) }
            guard !selected.isEmpty, items.contains(where: { selected.contains($0.id) }) else {
                message = "请先选择当前显示器上可用的菜单栏项目。"
                return
            }
            guard let leftmost = items.min(by: { $0.frame.minX < $1.frame.minX }) else {
                message = "当前显示器没有可移动的菜单栏项目。"
                return
            }
            // Move the divider left of all existing items first, so no unrelated item is hidden.
            let control = ManagedMenuBarItem(
                identity: .init(bundleIdentifier: Bundle.main.bundleIdentifier, title: "AtollDivider", ownerName: "Atoll"),
                windowID: dividerWindowID() ?? kCGNullWindowID, ownerPID: ProcessInfo.processInfo.processIdentifier,
                frame: boundary, displayName: "AtollDivider", bundleIdentifier: Bundle.main.bundleIdentifier,
                ownerName: "Atoll", isOnScreen: true
            )
            try await MenuBarItemInteractionService.shared.move(control, to: CGPoint(x: leftmost.frame.minX, y: leftmost.frame.midY))
            for original in items where selected.contains(original.id) {
                try Task.checkCancellation()
                items = await scanner.scan().filter { screenFrame.intersects($0.frame) }
                try Task.checkCancellation()
                guard let current = items.first(where: { $0.id == original.id }), let frame = dividerFrame() else {
                    throw MenuBarItemInteractionError.itemUnavailable
                }
                try await MenuBarItemInteractionService.shared.move(current, to: CGPoint(x: frame.minX, y: frame.midY))
            }
            try Task.checkCancellation()
            items = await scanner.scan().filter { screenFrame.intersects($0.frame) }
            guard generation == currentGeneration,
                  Defaults[.enableMenuBarDrawer], Defaults[.menuBarHideSelectedItems],
                  let frame = dividerFrame(),
                  Self.canCollapse(items: items, selectedIDs: selected, divider: frame),
                  items.filter({ selected.contains($0.id) }).allSatisfy({ $0.frame.maxX <= frame.minX + 1 }) else {
                throw MenuBarItemInteractionError.itemUnavailable
            }
            sessionItems = items.filter { selected.contains($0.id) }
            Defaults[.menuBarHiddenSessionActive] = true
            divider?.length = 10_000
            isHidden = true
            recoveryItem?.button?.image = Self.controlImage(hidden: true)
            hiddenDisplaySignature = currentDisplaySignature()
            Logger.log("[MenuBar] hidden successfully by arranging selected items; sessionItems=\(sessionItems.count)", category: .lifecycle)
            MenuBarItemManager.shared.refreshNow()
        } catch {
            reveal()
            message = "未能安全完成移动，项目保持展开：\(error.localizedDescription)"
            Logger.log("[MenuBar] hide failed: \(error)", category: .error)
        }
    }

    func retainedItems(among items: [ManagedMenuBarItem]) -> [ManagedMenuBarItem] {
        guard isHidden else { return items }
        let ids = Set(items.map(\.id))
        return items + sessionItems.filter {
            !ids.contains($0.id) && NSRunningApplication(processIdentifier: $0.ownerPID)?.isTerminated == false
        }
    }
    func click(_ item: ManagedMenuBarItem, button: CGMouseButton) async throws {
        Logger.log(
            "[MenuBar] drawer item click name=\(item.displayName) button=\(button == .right ? "right" : "left") hidden=\(isHidden) busy=\(isBusy)",
            category: .debug
        )
        guard !isBusy else { return }
        let wasHidden = isHidden
        let currentGeneration = generation
        let native = MenuBarOverflowBoundary.isNativeOverflowSystem
        isBusy = true
        defer { isBusy = false }

        reveal()
        do {
            // The bar reflows when the spacer shrinks; the item is clicked where
            // it is drawn after that, not where it was before.
            if wasHidden { try await Task.sleep(for: .milliseconds(native ? 300 : 200)) }
            let before = await Task.detached { Self.interfaceWindows(pid: item.ownerPID) }.value
            if button == .right {
                try await MenuBarItemInteractionService.shared.rightClick(item)
            } else {
                try await MenuBarItemInteractionService.shared.leftClick(item)
            }
            guard wasHidden else { return }
            // Only rehide after an observed interface closes. Timeout leaves everything visible.
            var opened = Set<CGWindowID>()
            for _ in 0..<240 {
                try await Task.sleep(for: .milliseconds(250))
                guard generation == currentGeneration, Defaults[.menuBarHideSelectedItems], divider != nil else { return }
                let current = await Task.detached { Self.interfaceWindows(pid: item.ownerPID) }.value
                opened.formUnion(current.subtracting(before))
                if !opened.isEmpty && opened.isDisjoint(with: current) {
                    if native {
                        await concealNativelyCore()
                        return
                    }
                    let items = await scanner.scan()
                    if generation == currentGeneration, let frame = dividerFrame(), Self.canCollapse(items: items, selectedIDs: Set(Defaults[.selectedMenuBarItems]), divider: frame) {
                        sessionItems = items.filter { Defaults[.selectedMenuBarItems].contains($0.id) }
                        Defaults[.menuBarHiddenSessionActive] = true
                        divider?.length = 10_000
                        isHidden = true
                        recoveryItem?.button?.image = Self.controlImage(hidden: true)
                        hiddenDisplaySignature = currentDisplaySignature()
                        Logger.log("[MenuBar] hidden successfully after drawer click; sessionItems=\(sessionItems.count)", category: .lifecycle)
                    }
                    return
                }
            }
            message = "无法确认菜单已关闭，已保持展开。需要时可手动再次隐藏。"
        } catch {
            reveal()
            message = "点击失败，已保持展开：\(error.localizedDescription)"
            throw error
        }
    }

    private nonisolated static func interfaceWindows(pid: pid_t) -> Set<CGWindowID> {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue != Int(CGWindowLevelForKey(.statusWindow)) else { return nil }
            return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
    }
}

extension MenuBarHiddenSection: NSMenuDelegate {
    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            let action = pendingMenuAction
            pendingMenuAction = nil
            action?()
        }
    }
}
