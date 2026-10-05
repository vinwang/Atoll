/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Defaults
import SwiftUI

/// Duration picker for the notch's caffeinate button.
///
/// Tapping a duration while a session is already running re-asserts with the
/// new duration rather than stacking a second one, so the list doubles as the
/// "extend this" control.
struct CaffeinatePopover: View {
    @ObservedObject private var caffeinateManager = CaffeinateManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()
                .padding(.horizontal, -8)

            VStack(spacing: 2) {
                ForEach(CaffeinateDuration.allCases) { duration in
                    durationRow(duration)
                }
            }

            if caffeinateManager.isActive {
                Divider()
                    .padding(.horizontal, -8)

                Button {
                    withAnimation(.smooth) {
                        caffeinateManager.deactivate()
                    }
                    dismiss()
                } label: {
                    Text("Turn Off")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
        .padding(14)
        .frame(width: 280)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.white)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.26), .white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var background: some View {
        if reduceTransparency {
            Color(white: 0.12)
        } else {
            Rectangle().fill(.regularMaterial)
                .overlay(Color.black.opacity(0.35))
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: caffeinateManager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(caffeinateManager.isActive ? Color.yellow : Color.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep Awake")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    // A countdown that reflows the popover every second is
                    // distracting, so the row keeps a fixed baseline.
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    private var statusText: String {
        guard caffeinateManager.isActive else {
            return String(localized: "Off")
        }
        if let remaining = caffeinateManager.remainingTime {
            return String(localized: "\(CaffeinateManager.remainingLabel(remaining)) left")
        }
        return String(localized: "On until turned off")
    }

    private func durationRow(_ duration: CaffeinateDuration) -> some View {
        let isRunning = caffeinateManager.isActive && caffeinateManager.activeDuration == duration

        return Button {
            withAnimation(.smooth) {
                caffeinateManager.activate(for: duration)
            }
            dismiss()
        } label: {
            HStack {
                Text(duration.displayName)
                    .foregroundStyle(.white)
                Spacer()
                if isRunning {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.yellow)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isRunning ? Color.white.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    CaffeinatePopover()
}
