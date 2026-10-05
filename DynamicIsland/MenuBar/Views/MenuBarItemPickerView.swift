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
import SwiftUI

struct MenuBarItemPickerView: View {
    @ObservedObject var manager: MenuBarItemManager
    @ObservedObject private var imageCache = MenuBarItemImageCache.shared
    @ObservedObject private var accessibility = AccessibilityPermissionStore.shared

    var body: some View {
        Section {
            if manager.items.isEmpty {
                if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
                   !accessibility.isAuthorized {
                    Text("Grant Accessibility permission to discover menu bar items.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No menu bar items found.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(manager.items) { item in
                    Toggle(
                        isOn: Binding(
                            get: { manager.isSelected(item) },
                            set: { manager.setSelected(item, selected: $0) }
                        )
                    ) {
                        HStack(spacing: 8) {
                            itemImage(for: item)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                if let ownerName = item.ownerName, ownerName != item.displayName {
                                    Text(ownerName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        } header: {
            Text("Items")
        }
        .onAppear {
            imageCache.refresh(for: manager.items)
        }
        .onChange(of: manager.items) { _, items in
            imageCache.refresh(for: items)
        }
    }

    @ViewBuilder
    private func itemImage(for item: ManagedMenuBarItem) -> some View {
        if let image = imageCache.image(for: item) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "menubar.rectangle")
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
        }
    }
}
