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

struct ManagedMenuBarItem: Identifiable, Hashable {
    let identity: MenuBarItemIdentity

    let windowID: CGWindowID
    let ownerPID: pid_t
    let frame: CGRect

    let displayName: String
    let bundleIdentifier: String?
    let ownerName: String?

    let isOnScreen: Bool

    var id: String { identity.id }
}

enum MenuBarItemSelection {
    static func matching<C: Collection>(
        _ items: [ManagedMenuBarItem],
        selectedIDs: C
    ) -> [ManagedMenuBarItem] where C.Element == String {
        let selectedIDs = Set(selectedIDs)
        return items.filter { selectedIDs.contains($0.id) }
    }
}
