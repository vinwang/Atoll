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

import CoreGraphics
import Foundation

private typealias CGSConnectionID = Int32
private typealias CGSSpaceID = size_t
private let nullConnection: CGSConnectionID = 0

private struct CGSSpaceMask: OptionSet {
    let rawValue: UInt32

    static let allSpaces = CGSSpaceMask(rawValue: 1 << 0 | 1 << 1 | 1 << 2)
}

@_silgen_name("CGSMainConnectionID")
private func cgsMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
private func cgsGetWindowCount(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ count: inout Int32
) -> CGError

@_silgen_name("CGSGetOnScreenWindowCount")
private func cgsGetOnScreenWindowCount(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ count: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func cgsGetProcessMenuBarWindowList(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetOnScreenWindowList")
private func cgsGetOnScreenWindowList(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
private func cgsGetScreenRectForWindow(
    _ connection: CGSConnectionID,
    _ windowID: CGWindowID,
    _ rect: inout CGRect
) -> CGError

@_silgen_name("CGSCopySpacesForWindows")
private func cgsCopySpacesForWindows(
    _ connection: CGSConnectionID,
    _ mask: CGSSpaceMask,
    _ windowIDs: CFArray
) -> Unmanaged<CFArray>?

@_silgen_name("CGSGetActiveSpace")
private func cgsGetActiveSpace(_ connection: CGSConnectionID) -> CGSSpaceID

enum MenuBarWindowBridge {
    static func menuBarWindows() -> [CGWindowID] {
        windowList(count: cgsGetWindowCount) { count, list, outCount in
            cgsGetProcessMenuBarWindowList(
                cgsMainConnectionID(),
                nullConnection,
                count,
                list,
                &outCount
            )
        }
    }

    static func onScreenMenuBarWindows() -> [CGWindowID] {
        let onScreen = Set(windowList(count: cgsGetOnScreenWindowCount) { count, list, outCount in
            cgsGetOnScreenWindowList(
                cgsMainConnectionID(),
                nullConnection,
                count,
                list,
                &outCount
            )
        })
        return menuBarWindows().filter(onScreen.contains)
    }

    static func windowFrame(_ windowID: CGWindowID) -> CGRect? {
        var frame = CGRect.zero
        guard cgsGetScreenRectForWindow(cgsMainConnectionID(), windowID, &frame) == .success else {
            return nil
        }
        return frame
    }

    static func isWindowOnActiveSpace(_ windowID: CGWindowID) -> Bool {
        guard let spaces = cgsCopySpacesForWindows(
            cgsMainConnectionID(),
            .allSpaces,
            [windowID] as CFArray
        )?.takeRetainedValue() as? [CGSSpaceID] else {
            return false
        }
        return spaces.contains(cgsGetActiveSpace(cgsMainConnectionID()))
    }

    private static func windowList(
        count countCall: (
            CGSConnectionID,
            CGSConnectionID,
            inout Int32
        ) -> CGError,
        _ call: (
            Int32,
            UnsafeMutablePointer<CGWindowID>,
            inout Int32
        ) -> CGError
    ) -> [CGWindowID] {
        var count: Int32 = 0
        guard countCall(cgsMainConnectionID(), nullConnection, &count) == .success,
              count > 0 else {
            return []
        }

        var list = [CGWindowID](repeating: 0, count: Int(count))
        var outCount: Int32 = 0
        let result = list.withUnsafeMutableBufferPointer { buffer in
            call(count, buffer.baseAddress!, &outCount)
        }
        guard result == .success, outCount > 0 else { return [] }
        return Array(list.prefix(Int(outCount)))
    }
}
