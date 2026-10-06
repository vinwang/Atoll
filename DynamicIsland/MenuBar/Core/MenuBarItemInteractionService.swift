/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Portions adapted from Ice
 * https://github.com/jordanbaird/Ice
 *
 * Ice is licensed under GPL-3.0.
 * Modified for Atoll Menu Bar Drawer.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum MenuBarItemInteractionError: LocalizedError {
    case accessibilityRequired
    case itemUnavailable
    case eventCreationFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: return "Accessibility permission is required."
        case .itemUnavailable: return "The menu bar item is no longer available."
        case .eventCreationFailed: return "The menu bar click event could not be created."
        case .timedOut: return "The menu bar click timed out."
        }
    }
}

final class MenuBarItemInteractionService: @unchecked Sendable {
    static let shared = MenuBarItemInteractionService()

    private let scanner = MenuBarItemScanner()
    @MainActor private var releaseDrag: (() -> Void)?

    private init() {}

    func leftClick(_ item: ManagedMenuBarItem, targetDisplay: CGRect? = nil) async throws {
        if try await Self.openApplication(for: item) { return }
        try await click(item, button: .left, targetDisplay: targetDisplay)
    }

    func rightClick(_ item: ManagedMenuBarItem, targetDisplay: CGRect? = nil) async throws {
        try await click(item, button: .right, targetDisplay: targetDisplay)
    }

    @MainActor static func openApplication(for item: ManagedMenuBarItem) async throws -> Bool {
        try Task.checkCancellation()
        guard let application = NSRunningApplication(processIdentifier: item.ownerPID),
              !application.isTerminated,
              application.bundleIdentifier == item.bundleIdentifier,
              let url = application.bundleURL,
              let bundle = Bundle(url: url) else { return false }
        // Some ordinary apps switch to accessory mode while their window is closed.
        let menuBarOnly = bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false
        guard application.activationPolicy == .regular || !menuBarOnly else { return false }
        // Opening sends the native reopen request, including when all windows were closed.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        Logger.log("[MenuBar] application reopened name=\(item.displayName)", category: .debug)
        return true
    }

    /// Command-drag is the native menu bar reorder gesture. Callers verify the final layout.
    @MainActor func move(_ item: ManagedMenuBarItem, to destination: CGPoint) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw MenuBarItemInteractionError.accessibilityRequired }
        let frame = item.windowID == kCGNullWindowID ? item.frame : MenuBarWindowBridge.windowFrame(item.windowID)
        guard let frame, frame.width > 0, frame.height > 0,
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right) else {
            throw MenuBarItemInteractionError.itemUnavailable
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = Self.makeEvent(type: .leftMouseDown, button: .left,
                  point: CGPoint(x: frame.midX, y: frame.midY), item: item, source: source),
              let drag = Self.makeEvent(type: .leftMouseDragged, button: .left,
                  point: destination, item: item, source: source),
              let up = Self.makeEvent(type: .leftMouseUp, button: .left,
                  point: destination, item: item, source: source) else {
            throw MenuBarItemInteractionError.eventCreationFailed
        }
        let location = CGEvent(source: nil)?.location
        // The posted events carry menu bar coordinates and drag the real
        // pointer along; keep it out of sight until it is put back.
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let location { CGWarpMouseCursorPosition(location) }
            CGDisplayShowCursor(CGMainDisplayID())
        }
        down.flags = .maskCommand
        drag.flags = .maskCommand
        up.flags = .maskCommand
        releaseDrag = {
            up.post(tap: .cgSessionEventTap)
            if let location { CGWarpMouseCursorPosition(location) }
        }
        down.post(tap: .cgSessionEventTap)
        do {
            defer { cancelPendingMove() }
            try await Task.sleep(for: .milliseconds(50))
            drag.post(tap: .cgSessionEventTap)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    @MainActor func cancelPendingMove() {
        releaseDrag?()
        releaseDrag = nil
    }

    private func click(_ item: ManagedMenuBarItem, button: CGMouseButton, targetDisplay: CGRect?) async throws {
        guard AXIsProcessTrusted() else {
            throw MenuBarItemInteractionError.accessibilityRequired
        }

        var current = await scanner.scan(targetDisplay: targetDisplay).first(where: { $0.id == item.id })
        if current == nil, targetDisplay != nil {
            // The system can reveal the item on a different display from the drawer.
            current = await scanner.scan(allDisplays: true).first(where: { $0.id == item.id })
        }
        guard let latest = current else {
            throw MenuBarItemInteractionError.itemUnavailable
        }
        try Task.checkCancellation()
        Logger.log("[MenuBar] click target name=\(latest.displayName) frame=\(latest.frame) display=\(String(describing: targetDisplay))", category: .debug)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                if button == .left,
                   MenuBarAccessibilityBridge.press(latest) {
                    Logger.log("[MenuBar] accessibility press succeeded name=\(latest.displayName)", category: .debug)
                    return
                }
                try Task.checkCancellation()
                try await Self.postClick(for: latest, button: button)
            }
            group.addTask {
                // An accessibility press walks the owner's items, each with its
                // own messaging timeout, so an app that answers slowly can take
                // a couple of seconds. The budget only bounds the wait; the
                // click itself has already been posted by then.
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw MenuBarItemInteractionError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    @MainActor private static func postClick(
        for item: ManagedMenuBarItem,
        button: CGMouseButton
    ) async throws {
        try Task.checkCancellation()
        guard let source = CGEventSource(stateID: .privateState) else {
            throw MenuBarItemInteractionError.eventCreationFailed
        }

        let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let originalLocation = CGEvent(source: nil)?.location
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        guard
            let mouseDown = CGEvent(mouseEventSource: source, mouseType: downType,
                mouseCursorPosition: point, mouseButton: button),
            let mouseUp = CGEvent(mouseEventSource: source, mouseType: upType,
                mouseCursorPosition: point, mouseButton: button)
        else {
            throw MenuBarItemInteractionError.eventCreationFailed
        }

        var released = false
        // The notch panel sits above the menu bar and can cover the target icon.
        let overlays = NSApp.windows.filter { $0 is DynamicIslandWindow && !$0.ignoresMouseEvents }
        for window in overlays { window.ignoresMouseEvents = true }
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            // Always release the injected button, including cancellation.
            if !released { mouseUp.post(tap: .cgSessionEventTap) }
            if let originalLocation {
                CGWarpMouseCursorPosition(originalLocation)
            }
            CGDisplayShowCursor(CGMainDisplayID())
            for window in overlays { window.ignoresMouseEvents = false }
        }

        mouseDown.flags = []
        mouseUp.flags = []
        mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseDown.post(tap: .cgSessionEventTap)
        try await Task.sleep(for: .milliseconds(50))
        mouseUp.post(tap: .cgSessionEventTap)
        released = true
        try await Task.sleep(for: .milliseconds(50))
        Logger.log("[MenuBar] \(button == .right ? "right" : "left") click: \(item.displayName) point=\(point) scannedWindow=\(item.windowID)", category: .debug)
    }

    private static func makeEvent(
        type: CGEventType,
        button: CGMouseButton,
        point: CGPoint,
        item: ManagedMenuBarItem,
        source: CGEventSource
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            return nil
        }

        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(item.ownerPID))
        event.setIntegerValueField(.eventSourceUserData, value: Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event))))
        if item.windowID != kCGNullWindowID {
            let windowID = Int64(item.windowID)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)
            event.setIntegerValueField(CGEventField(rawValue: 0x33)!, value: windowID)
        }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }
}
