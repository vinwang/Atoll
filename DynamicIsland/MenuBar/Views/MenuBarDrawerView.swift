/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Defaults
import SwiftUI

struct MenuBarDrawerView: View {
    @ObservedObject private var manager = MenuBarItemManager.shared
    @Default(.menuBarDrawerShowLabels) private var showLabels
    @Default(.menuBarDrawerShowTooltips) private var showTooltips

    var body: some View {
        Group {
            if manager.selectedItems.isEmpty {
                Text("Select menu bar items in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: showLabels ? 120 : 44), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(manager.selectedItems) { item in
                            MenuBarDrawerItemView(
                                item: item,
                                showLabel: showLabels,
                                showTooltip: showTooltips
                            )
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .onAppear {
            manager.start()
        }
    }
}
