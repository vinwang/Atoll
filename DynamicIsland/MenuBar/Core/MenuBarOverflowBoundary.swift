/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Portions adapted from Ice, pull request #980
 * (MacOS27NativeMenuBarHiding and MacOS27NativeBoundary)
 * https://github.com/jordanbaird/Ice/pull/980
 *
 * Ice is licensed under GPL-3.0.
 * Modified for Atoll Menu Bar Drawer.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import CoreGraphics
import Foundation

/// Pure decisions for the hidden section on macOS 27.
///
/// macOS 27 draws every status item inside MenuBarAgent, discards an
/// oversized item instead of letting it push its neighbours off screen, and
/// folds whatever no longer fits into its own overflow control. An
/// Atoll-owned spacer sized to the status region therefore pushes every item
/// on its left into that overflow, and nothing else has to be moved. Kept free
/// of AppKit so the rules can be checked without a menu bar.
enum MenuBarOverflowBoundary {
    enum Side: Equatable {
        case left
        case right
    }

    /// Width of the divider while items are shown ("│").
    static let revealedLength: CGFloat = 18

    /// Room kept for the control item so widening never pushes it off the bar.
    static let controlReserve: CGFloat = 32

    /// Height of the strip a status item must sit in to count as on the bar.
    static let stripHeight: CGFloat = 40

    /// Whether this system lays the menu bar out itself and honours only widths
    /// that fit its status region.
    static var isNativeOverflowSystem: Bool {
        if #available(macOS 27, *) {
            return true
        }
        return false
    }

    /// Anything wider than the status region is discarded by macOS 27; a width
    /// inside it makes the spacer's left neighbours overflow.
    static func concealingLength(regionWidth: CGFloat) -> CGFloat {
        max(controlReserve, regionWidth - controlReserve)
    }

    /// Top strip of a display, in CoreGraphics coordinates.
    static func menuBarStrip(of display: CGRect) -> CGRect {
        CGRect(x: display.minX, y: display.minY, width: display.width, height: stripHeight)
    }

    /// Overflowed items keep stale frames, sometimes below the display. Only a
    /// positive frame whose centre lies inside a menu bar strip is on the bar.
    static func isOnBar(_ frame: CGRect, strips: [CGRect]) -> Bool {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return strips.contains { $0.contains(center) }
    }

    /// Which side of the boundary a frame is on. Order is decided by origins:
    /// hosted hit areas may touch or overlap at their edges after a drop.
    /// `nil` for a different row or a coincident origin.
    static func side(of frame: CGRect, relativeTo boundary: CGRect) -> Side? {
        guard frame.width > 0, frame.height > 0, boundary.width > 0, boundary.height > 0,
              abs(frame.midY - boundary.midY) < min(frame.height, boundary.height) / 2,
              frame.minX != boundary.minX else { return nil }
        return frame.minX < boundary.minX ? .left : .right
    }

    /// Items left of the divider: the ones a widened spacer pushes into the
    /// system overflow.
    static func hiddenSide(of items: [ManagedMenuBarItem], boundary: CGRect) -> [ManagedMenuBarItem] {
        items.filter { side(of: $0.frame, relativeTo: boundary) == .left }
    }

    /// Items that may be concealed without touching Atoll's own status icon.
    static func hideableSide(
        of items: [ManagedMenuBarItem],
        boundary: CGRect,
        ownFrames: [CGRect],
        ownBundleIdentifier: String?
    ) -> [ManagedMenuBarItem] {
        hiddenSide(of: items, boundary: boundary).filter { item in
            let foreignBundle = ownBundleIdentifier.map { item.bundleIdentifier != $0 } ?? true
            return foreignBundle && !ownFrames.contains { $0.intersects(item.frame) }
        }
    }
}
