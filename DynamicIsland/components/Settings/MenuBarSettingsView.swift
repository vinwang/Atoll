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
import Defaults
import SwiftUI

struct MenuBarSettingsView: View {
    @ObservedObject private var manager = MenuBarItemManager.shared
    @ObservedObject private var accessibility = AccessibilityPermissionStore.shared
    @ObservedObject private var hiddenSection = MenuBarHiddenSection.shared
    @Default(.enableMenuBarDrawer) private var drawerEnabled
    @Default(.menuBarHideSelectedItems) private var hideSelected

    /// macOS 27 hides whatever sits left of the divider; earlier systems move
    /// the selected items there.
    private let nativeOverflow = MenuBarOverflowBoundary.isNativeOverflowSystem

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableMenuBarDrawer) {
                    Text("Enable Menu Bar Drawer")
                }
                .settingsHighlight(id: highlightID("Enable Menu Bar Drawer"))
            } header: {
                Text("Menu Bar Drawer")
            } footer: {
                Text("所选项目会显示在抽屉中；可选择隐藏原状态栏图标。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(nativeOverflow ? "隐藏「│」左侧的状态栏图标（实验性）" : "隐藏原状态栏图标（实验性）", isOn: $hideSelected)
                    .disabled(!drawerEnabled || !accessibility.isAuthorized || hiddenSection.isBusy)
                HStack {
                    Button("重新隐藏") { hiddenSection.configure() }
                        .disabled(!hideSelected || hiddenSection.isBusy)
                    Button("恢复全部") {
                        hideSelected = false
                        hiddenSection.restoreAll()
                    }
                }
                if nativeOverflow, hideSelected {
                    hiddenSideList
                }
                if let message = hiddenSection.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("隐藏区域")
            } footer: {
                Text(nativeOverflow
                    ? "菜单栏上的 👁 点一下即隐藏（再点一下显示，图标会变成斜杠眼睛）；右键点 👁 打开菜单：恢复全部、设置、退出。抽屉里左键点击会唤起对应 app，右键点是原状态栏项目自己的菜单。按住 ⌘ 把「│」拖到你想隐藏的位置，它左侧的图标会进入系统的隐藏区（无刘海显示器不支持隐藏）。"
                    : "菜单栏上的 👁 点一下即隐藏（再点一下显示）；右键点 👁 打开菜单。抽屉里左键点击会唤起对应 app，右键点是原状态栏项目自己的菜单。仅处理当前主显示器。恢复全部会显示所有项目，但不恢复原来的排列顺序。异常退出后自动停用隐藏。")
            }

            MenuBarItemPickerView(manager: manager)

            Section {
                Defaults.Toggle(key: .menuBarDrawerShowTooltips) {
                    Text("Show tooltips")
                }
                Defaults.Toggle(key: .menuBarDrawerShowLabels) {
                    Text("Show item names")
                }
            } header: {
                Text("Appearance")
            }

            Section {
                permissionRow(
                    title: "Accessibility",
                    granted: accessibility.isAuthorized,
                    action: openAccessibilitySettings
                )
            } header: {
                Text("Permissions")
            }

            Section {
                Button("Refresh") {
                    accessibility.refreshStatus()
                    manager.refreshNow()
                }
            }
        }
        .navigationTitle("Menu Bar")
        .onAppear {
            manager.refreshNow()
            accessibility.refreshStatus()
        }
        .onChange(of: accessibility.isAuthorized) { _, granted in
            if granted {
                manager.refreshNow()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibility.refreshStatus()
            manager.refreshNow()
        }
    }

    @ViewBuilder
    private var hiddenSideList: some View {
        if hiddenSection.hiddenSideItems.isEmpty {
            Text("当前隐藏区为空。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(hiddenSection.hiddenSideItems) { item in
                HStack {
                    Text(item.displayName)
                    Spacer()
                    if !manager.isSelected(item) {
                        Text("未勾选，抽屉中不显示")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted ? "Granted" : "Not Granted")
                .foregroundStyle(granted ? .green : .secondary)
            if !granted {
                Button("Open Settings", action: action)
                    .buttonStyle(.link)
            }
        }
    }

    private func openAccessibilitySettings() {
        accessibility.requestAuthorizationPrompt()
        accessibility.openSystemSettings()
    }

    private func highlightID(_ title: String) -> String {
        "menuBar-\(title)"
    }
}
