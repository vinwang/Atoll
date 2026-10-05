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

struct MenuBarWindowInfo: Hashable {
    let windowID: CGWindowID
    let frame: CGRect
    let ownerPID: pid_t
    let ownerName: String?
    let bundleIdentifier: String?
    let title: String?
    let isOnScreen: Bool
    let layer: Int

    var isStatusWindow: Bool {
        layer == Int(CGWindowLevelForKey(.statusWindow))
    }

    var displayName: String {
        if bundleIdentifier == "com.apple.controlcenter" || bundleIdentifier == "com.apple.MenuBarAgent" {
            switch title {
            case "WiFi": return "Wi-Fi"
            case "FocusModes": return "Focus"
            case "NowPlaying": return "Now Playing"
            case "ScreenMirroring": return "Screen Mirroring"
            case let title?: return title
            default: break
            }
        }

        return ownerName ?? title ?? bundleIdentifier ?? "Unknown"
    }

    init(
        windowID: CGWindowID,
        frame: CGRect,
        ownerPID: pid_t,
        ownerName: String?,
        bundleIdentifier: String?,
        title: String?,
        isOnScreen: Bool,
        layer: Int = Int(CGWindowLevelForKey(.statusWindow))
    ) {
        self.windowID = windowID
        self.frame = frame
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.isOnScreen = isOnScreen
        self.layer = layer
    }

    init?(windowID: CGWindowID) {
        guard
            let dictionaries = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
            let dictionary = dictionaries.first,
            let ownerPIDNumber = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
            let layerNumber = dictionary[kCGWindowLayer as String] as? NSNumber,
            let bounds = dictionary[kCGWindowBounds as String] as? NSDictionary,
            let dictionaryFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else {
            return nil
        }

        let frame = MenuBarWindowBridge.windowFrame(windowID) ?? dictionaryFrame

        let ownerPID = ownerPIDNumber.int32Value
        let application = NSRunningApplication(processIdentifier: ownerPID)
        let ownerName = (dictionary[kCGWindowOwnerName as String] as? String)
            ?? application?.localizedName
        let bundleIdentifier = application?.bundleIdentifier
        let title = (dictionary[kCGWindowName as String] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalizedTitle = title?.isEmpty == true ? nil : title
        let isOnScreen = (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let layer = layerNumber.intValue

        self.init(
            windowID: windowID,
            frame: frame,
            ownerPID: ownerPID,
            ownerName: ownerName,
            bundleIdentifier: bundleIdentifier,
            title: normalizedTitle,
            isOnScreen: isOnScreen,
            layer: layer
        )
    }
}
