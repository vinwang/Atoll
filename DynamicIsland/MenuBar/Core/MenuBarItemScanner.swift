/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import ApplicationServices

struct MenuBarAccessibilityHost: Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
}

struct MenuBarItemScanner {
    /// Owners whose items macOS 27 lays out itself: the overflow control and
    /// the system controls it hosts can be neither hidden nor moved.
    static let nativeOverflowExcludedOwners: Set<String> = ["com.apple.MenuBarAgent"]

    @MainActor
    func scan() async -> [ManagedMenuBarItem] {
        let excludedBundleIdentifier = Bundle.main.bundleIdentifier
        let excludedPID = ProcessInfo.processInfo.processIdentifier
        let nativeOverflow = MenuBarOverflowBoundary.isNativeOverflowSystem
        // macOS 27 draws items on the bar of whichever display owns them, not
        // only on the one with the menu bar, so the legacy "same screen as
        // NSScreen.main" filter would drop every item on the other display.
        // The per-display bar strips below are the correct filter there.
        let targetScreenFrame = nativeOverflow ? nil : (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDisplayBounds($0.uint32Value) }
        // Overflowed items keep stale frames, sometimes below the display, so
        // on macOS 27 an item must sit in some display's menu bar strip.
        let menuBarStrips: [CGRect]? = nativeOverflow ? NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { MenuBarOverflowBoundary.menuBarStrip(of: CGDisplayBounds($0.uint32Value)) }
        } : nil
        let excludedOwners = nativeOverflow ? Self.nativeOverflowExcludedOwners : []
        let accessibilityHosts: [MenuBarAccessibilityHost] = NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.isFinishedLaunching,
                  !application.isTerminated,
                  application.activationPolicy != .prohibited,
                  application.processIdentifier != excludedPID,
                  application.bundleIdentifier != excludedBundleIdentifier else {
                return nil
            }
            return MenuBarAccessibilityHost(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName
            )
        }

        return await Task.detached(priority: .utility) {
            Self.scanSynchronously(
                excludedBundleIdentifier: excludedBundleIdentifier,
                excludedPID: excludedPID,
                targetScreenFrame: targetScreenFrame,
                accessibilityHosts: accessibilityHosts,
                menuBarStrips: menuBarStrips,
                excludedOwners: excludedOwners
            )
        }.value
    }

    private static func scanSynchronously(
        excludedBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        excludedPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        targetScreenFrame: CGRect? = nil,
        accessibilityHosts: [MenuBarAccessibilityHost] = [],
        menuBarStrips: [CGRect]? = nil,
        excludedOwners: Set<String> = []
    ) -> [ManagedMenuBarItem] {
        let windows = MenuBarWindowBridge.onScreenMenuBarWindows()
            .filter(MenuBarWindowBridge.isWindowOnActiveSpace)
            .compactMap(MenuBarWindowInfo.init(windowID:))

        let windowItems = filteredItems(
            from: windows,
            excludedBundleIdentifier: excludedBundleIdentifier,
            excludedPID: excludedPID,
            targetScreenFrame: targetScreenFrame,
            menuBarStrips: menuBarStrips,
            excludedOwners: excludedOwners
        )
        var items = windowItems
        if windowItems.isEmpty || ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            let accessibilityItems = filteredItems(
                from: MenuBarAccessibilityBridge.menuBarItems(for: accessibilityHosts),
                excludedBundleIdentifier: excludedBundleIdentifier,
                excludedPID: excludedPID,
                targetScreenFrame: targetScreenFrame,
                menuBarStrips: menuBarStrips,
                excludedOwners: excludedOwners
            )
            items = merged(windowItems, accessibilityItems)
        }
        for item in items {
            Logger.log("[MenuBar] discovered item: \(item.displayName)", category: .debug)
        }
        return items
    }

    static func merged(_ primary: [ManagedMenuBarItem], _ fallback: [ManagedMenuBarItem]) -> [ManagedMenuBarItem] {
        let primaryIDs = Set(primary.map(\.id))
        return primary + fallback.filter { !primaryIDs.contains($0.id) }
    }

    static func filteredItems(
        from windows: [MenuBarWindowInfo],
        excludedBundleIdentifier: String? = nil,
        excludedPID: pid_t? = nil,
        targetScreenFrame: CGRect? = nil,
        menuBarStrips: [CGRect]? = nil,
        excludedOwners: Set<String> = []
    ) -> [ManagedMenuBarItem] {
        var seenIDs = Set<String>()

        return windows.compactMap { window in
            guard window.isStatusWindow,
                  window.isOnScreen,
                  window.frame.width > 0,
                  window.frame.height > 0,
                  targetScreenFrame?.intersects(window.frame) ?? true,
                  menuBarStrips.map({ MenuBarOverflowBoundary.isOnBar(window.frame, strips: $0) }) ?? true,
                  window.bundleIdentifier != excludedBundleIdentifier,
                  window.ownerPID != excludedPID,
                  !excludedOwners.contains(window.bundleIdentifier ?? "") else {
                return nil
            }

            let title = window.title ?? window.displayName
            let identity = MenuBarItemIdentity(
                bundleIdentifier: window.bundleIdentifier,
                title: title,
                ownerName: window.ownerName
            )
            guard seenIDs.insert(identity.id).inserted else { return nil }

            return ManagedMenuBarItem(
                identity: identity,
                windowID: window.windowID,
                ownerPID: window.ownerPID,
                frame: window.frame,
                displayName: window.displayName,
                bundleIdentifier: window.bundleIdentifier,
                ownerName: window.ownerName,
                isOnScreen: window.isOnScreen
            )
        }
    }
}

enum MenuBarAccessibilityBridge {
    /// One of Atoll's own status items, as the menu bar reports it.
    struct OwnStatusItem: Equatable, Sendable {
        let identifier: String?
        let frame: CGRect
    }

    private static let extrasMenuBarAttribute = "AXExtrasMenuBar" as CFString
    private static let messagingTimeout: Float = 0.1

    static func menuBarItems(for hosts: [MenuBarAccessibilityHost]) -> [MenuBarWindowInfo] {
        guard AXIsProcessTrusted() else { return [] }

        return hosts.flatMap { host -> [MenuBarWindowInfo] in
            let application = AXUIElementCreateApplication(host.processIdentifier)
            AXUIElementSetMessagingTimeout(application, messagingTimeout)
            guard let menuBar = elementAttribute(extrasMenuBarAttribute, of: application) else {
                return []
            }
            AXUIElementSetMessagingTimeout(menuBar, messagingTimeout)

            return children(of: menuBar).enumerated().compactMap { index, element in
                guard let frame = frame(of: element) else { return nil }
                let name = firstNonempty(
                    stringAttribute(kAXTitleAttribute as CFString, of: element),
                    stringAttribute(kAXDescriptionAttribute as CFString, of: element),
                    stringAttribute(kAXHelpAttribute as CFString, of: element),
                    stringAttribute(kAXIdentifierAttribute as CFString, of: element),
                    host.localizedName,
                    host.bundleIdentifier,
                    "Item \(index + 1)"
                )
                return MenuBarWindowInfo(
                    windowID: kCGNullWindowID,
                    frame: frame,
                    ownerPID: host.processIdentifier,
                    ownerName: host.localizedName,
                    bundleIdentifier: host.bundleIdentifier,
                    title: name,
                    isOnScreen: true
                )
            }
        }
    }

    /// Atoll's own status items with their accessibility identifiers, so the
    /// hidden section can find its divider and control by name.
    static func ownStatusItems() -> [OwnStatusItem] {
        guard AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        guard let menuBar = elementAttribute(extrasMenuBarAttribute, of: application) else { return [] }
        AXUIElementSetMessagingTimeout(menuBar, messagingTimeout)
        return children(of: menuBar).compactMap { element in
            guard let frame = frame(of: element) else { return nil }
            return OwnStatusItem(
                identifier: stringAttribute(kAXIdentifierAttribute as CFString, of: element),
                frame: frame
            )
        }
    }

    static func press(_ item: ManagedMenuBarItem) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(item.ownerPID)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        guard let menuBar = elementAttribute(extrasMenuBarAttribute, of: application) else {
            return false
        }
        let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        guard let element = children(of: menuBar).first(where: { frame(of: $0)?.contains(center) == true }) else {
            return false
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static func elementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func firstNonempty(_ values: String?...) -> String {
        values.compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first ?? "Unknown"
    }
}
