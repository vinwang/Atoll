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

import AppKit

@MainActor
final class MenuBarItemImageCache: ObservableObject {
    static let shared = MenuBarItemImageCache()

    @Published private(set) var images: [String: NSImage] = [:]

    func image(for item: ManagedMenuBarItem) -> NSImage? {
        images[item.id]
    }

    func refresh(for items: [ManagedMenuBarItem]) {
        var refreshed: [String: NSImage] = [:]
        for item in items {
            if let cached = images[item.id] {
                refreshed[item.id] = cached
            } else if let bundleIdentifier = item.bundleIdentifier,
               let icon = AppIconAsNSImage(for: bundleIdentifier) {
                refreshed[item.id] = icon
            } else {
                refreshed[item.id] = Self.placeholder(for: item.displayName)
            }
        }
        images = refreshed
    }

    private static func placeholder(for description: String) -> NSImage {
        NSImage(
            systemSymbolName: "menubar.rectangle",
            accessibilityDescription: description
        ) ?? NSImage(size: NSSize(width: 20, height: 20))
    }
}
