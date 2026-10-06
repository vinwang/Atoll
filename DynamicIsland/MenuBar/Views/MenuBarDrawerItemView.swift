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
import CoreGraphics
import SwiftUI

struct MenuBarDrawerItemView: View {
    let item: ManagedMenuBarItem
    let showLabel: Bool
    let showTooltip: Bool

    @ObservedObject private var imageCache = MenuBarItemImageCache.shared

    var body: some View {
        HStack(spacing: 4) {
            if let image = imageCache.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 20, height: 20)
            }

            if showLabel {
                Text(item.displayName)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            MenuBarDrawerClickView(
                onLeftClick: { click(.left, on: $0) },
                onRightClick: { click(.right, on: $0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .help(showTooltip ? item.displayName : "")
        .accessibilityLabel(item.displayName)
        .accessibilityHint("Activates the original menu bar item")
    }

    private func click(_ button: CGMouseButton, on screen: NSScreen?) {
        Task {
            do {
                try await MenuBarHiddenSection.shared.click(item, button: button, on: screen)
            } catch {
                Logger.log("[MenuBar] interaction failed: \(error.localizedDescription)", category: .warning)
            }
        }
    }
}

private struct MenuBarDrawerClickView: NSViewRepresentable {
    final class RepresentedView: NSView {
        var onLeftClick: (NSScreen?) -> Void
        var onRightClick: (NSScreen?) -> Void
        private var leftMouseDownDate = Date.distantPast
        private var rightMouseDownDate = Date.distantPast
        private var leftMouseDownLocation = CGPoint.zero
        private var rightMouseDownLocation = CGPoint.zero

        init(onLeftClick: @escaping (NSScreen?) -> Void, onRightClick: @escaping (NSScreen?) -> Void) {
            self.onLeftClick = onLeftClick
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            leftMouseDownDate = .now
            leftMouseDownLocation = NSEvent.mouseLocation
        }

        override func mouseUp(with event: NSEvent) {
            guard Date.now.timeIntervalSince(leftMouseDownDate) < 0.5,
                  distance(from: leftMouseDownLocation, to: NSEvent.mouseLocation) < 5 else {
                return
            }
            onLeftClick(drawerScreen)
        }

        override func rightMouseDown(with event: NSEvent) {
            rightMouseDownDate = .now
            rightMouseDownLocation = NSEvent.mouseLocation
        }

        override func rightMouseUp(with event: NSEvent) {
            guard Date.now.timeIntervalSince(rightMouseDownDate) < 0.5,
                  distance(from: rightMouseDownLocation, to: NSEvent.mouseLocation) < 5 else {
                return
            }
            onRightClick(drawerScreen)
        }

        private var drawerScreen: NSScreen? {
            guard let window else { return nil }
            // A window in the notch's custom Space can report a nil screen.
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            return NSScreen.screens.first { $0.frame.contains(center) } ?? window.screen
        }

        private func distance(from first: CGPoint, to second: CGPoint) -> CGFloat {
            hypot(first.x - second.x, first.y - second.y)
        }
    }

    let onLeftClick: (NSScreen?) -> Void
    let onRightClick: (NSScreen?) -> Void

    func makeNSView(context: Context) -> RepresentedView {
        RepresentedView(onLeftClick: onLeftClick, onRightClick: onRightClick)
    }

    func updateNSView(_ nsView: RepresentedView, context: Context) {
        nsView.onLeftClick = onLeftClick
        nsView.onRightClick = onRightClick
    }
}
