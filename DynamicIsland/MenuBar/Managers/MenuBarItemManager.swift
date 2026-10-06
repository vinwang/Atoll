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
import Combine
import Defaults
import Foundation

@MainActor
final class MenuBarItemManager: ObservableObject {
    static let shared = MenuBarItemManager()

    @Published private(set) var items: [ManagedMenuBarItem] = []
    @Published private(set) var selectedItems: [ManagedMenuBarItem] = []
    private var isScanning = false

    private let scanner: MenuBarItemScanner
    private var selectedIdentityIDs: [String]
    private var observers = [NSObjectProtocol]()
    private var pollTimer: Timer?
    private var scanTask: Task<Void, Never>?
    private var pendingScanTask: Task<Void, Never>?
    private var rescanRequested = false
    private var started = false

    init(scanner: MenuBarItemScanner = .init()) {
        self.scanner = scanner
        self.selectedIdentityIDs = Defaults[.selectedMenuBarItems]
        updateSelectedItems()
    }

    deinit {
        scanTask?.cancel()
        pendingScanTask?.cancel()
        pollTimer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func start() {
        guard !started else {
            refreshNow()
            return
        }
        started = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        addObserver(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    Logger.log(
                        "[MenuBar] app launched name=\(application.localizedName ?? "unknown") bundle=\(application.bundleIdentifier ?? "unknown")",
                        category: .debug
                    )
                }
                Task { @MainActor in
                    MenuBarHiddenSection.shared.layoutDidChange(.application)
                    self?.scheduleScan(after: 0.25)
                }
            }
        )
        addObserver(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    Logger.log(
                        "[MenuBar] app terminated name=\(application.localizedName ?? "unknown") bundle=\(application.bundleIdentifier ?? "unknown")",
                        category: .debug
                    )
                }
                Task { @MainActor in
                    MenuBarHiddenSection.shared.layoutDidChange(.application)
                    self?.scheduleScan(after: 0.25)
                }
            }
        )
        addObserver(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Logger.log("[MenuBar] active Space changed", category: .debug)
                Task { @MainActor in
                    MenuBarHiddenSection.shared.layoutDidChange(.space)
                    self?.scheduleScan(after: 0.15)
                }
            }
        )
        addObserver(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Logger.log("[MenuBar] system woke", category: .debug)
                Task { @MainActor in
                    MenuBarHiddenSection.shared.layoutDidChange(.wake)
                    self?.scheduleScan(after: 1)
                }
            }
        )
        addObserver(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Logger.log(
                    "[MenuBar] screen parameters changed screens=\(NSScreen.screens.map { "\($0.localizedName)=\($0.frame)" }.joined(separator: ", "))",
                    category: .debug
                )
                Task { @MainActor in
                    MenuBarHiddenSection.shared.layoutDidChange(.display)
                    self?.scheduleScan(after: 0.15)
                }
            }
        )

        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refreshNow()
    }

    func stop() {
        guard started else { return }
        started = false
        scanTask?.cancel()
        scanTask = nil
        pendingScanTask?.cancel()
        pendingScanTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        rescanRequested = false
        isScanning = false
    }

    func refreshNow() {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        let scanner = scanner
        scanTask = Task { [weak self] in
            let result = await scanner.scan()
            guard !Task.isCancelled, let self else { return }
            await self.finishScan(result)
            guard !Task.isCancelled else { return }
            self.scanTask = nil
        }
    }

    func scheduleScan(after delay: TimeInterval = 0.15) {
        pendingScanTask?.cancel()
        pendingScanTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    func isSelected(_ item: ManagedMenuBarItem) -> Bool {
        selectedIdentityIDs.contains(item.id)
    }

    func setSelected(_ item: ManagedMenuBarItem, selected: Bool) {
        // On macOS 27 the divider's position decides what is hidden, not the
        // selection, so there is nothing to rearrange.
        let shouldRehide = Defaults[.menuBarHideSelectedItems] && !MenuBarOverflowBoundary.isNativeOverflowSystem
        if shouldRehide { MenuBarHiddenSection.shared.restoreAll() }
        if selected {
            if !selectedIdentityIDs.contains(item.id) {
                selectedIdentityIDs.append(item.id)
            }
        } else {
            selectedIdentityIDs.removeAll { $0 == item.id }
        }
        Defaults[.selectedMenuBarItems] = selectedIdentityIDs
        updateSelectedItems()
        MenuBarItemImageCache.shared.refresh(for: items)
        if shouldRehide { MenuBarHiddenSection.shared.configure() }
    }

    private func finishScan(_ result: [ManagedMenuBarItem]) async {
        let previousSelectedItems = selectedItems
        let refreshedItems = MenuBarHiddenSection.shared.retainedItems(among: result)
        if items != refreshedItems { items = refreshedItems }
        await MenuBarHiddenSection.shared.updateHiddenSide(with: items)
        guard !Task.isCancelled else { return }
        updateSelectedItems()
        isScanning = false
        if selectedItems != previousSelectedItems {
            MenuBarItemImageCache.shared.refresh(for: items)
        }

        guard rescanRequested else { return }
        rescanRequested = false
        scheduleScan(after: 0.15)
    }

    private func updateSelectedItems() {
        let matched = MenuBarItemSelection.matching(items, selectedIDs: selectedIdentityIDs)
        guard selectedItems != matched else { return }
        selectedItems = matched
        for item in selectedItems {
            Logger.log("[MenuBar] matched selected item: \(item.displayName)", category: .debug)
        }
    }

    private func addObserver(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }
}
