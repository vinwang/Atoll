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
        guard Set(images.keys) != Set(items.map(\.id)) else { return }
        var refreshed: [String: NSImage] = [:]
        for item in items {
            if let cached = images[item.id] {
                refreshed[item.id] = cached
            } else if let bundleIdentifier = item.bundleIdentifier,
               let icon = AppIconAsNSImage(for: bundleIdentifier) {
                refreshed[item.id] = Self.drawerIcon(icon)
            } else {
                refreshed[item.id] = Self.placeholder(for: item.displayName)
            }
        }
        images = refreshed
    }

    private static func drawerIcon(_ source: NSImage) -> NSImage {
        // The drawer renders at 24 points; keep one 48-pixel Retina representation.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 24, height: 24))
        bitmap.size = image.size
        image.addRepresentation(bitmap)
        return image
    }

    private static func placeholder(for description: String) -> NSImage {
        NSImage(
            systemSymbolName: "menubar.rectangle",
            accessibilityDescription: description
        ) ?? NSImage(size: NSSize(width: 20, height: 20))
    }
}
