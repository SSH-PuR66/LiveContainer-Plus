//
//  LCAppGroupBar.swift
//  LiveContainerSwiftUI
//
//  Horizontal group filter chips shown above the app list.
//

import SwiftUI

struct LCAppGroupBar: View {
    @ObservedObject var groupManager: LCAppGroupManager
    /// Apps used for the live counts. Hidden apps are excluded by the caller unless unlocked.
    var apps: [LCAppModel]
    var onManageTapped: () -> Void

    private var ungroupedCount: Int {
        groupManager.ungroupedCount(in: apps)
    }

    var body: some View {
        // With no groups defined the bar is pure noise, so it stays out of the way until
        // the user creates one from an app's context menu.
        if !groupManager.groups.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: "lc.appGroup.all".loc,
                         symbolName: "square.grid.2x2",
                         tint: .accentColor,
                         count: apps.count,
                         isSelected: groupManager.filter == .all) {
                        groupManager.filter = .all
                    }

                    ForEach(groupManager.groups) { group in
                        chip(title: group.name,
                             symbolName: group.symbolName,
                             tint: group.tint.color,
                             count: groupManager.memberCount(of: group, in: apps),
                             isSelected: groupManager.filter == .group(group.id)) {
                            // Tapping the active chip clears the filter — no dedicated "off" chip.
                            groupManager.filter = groupManager.filter == .group(group.id) ? .all : .group(group.id)
                        }
                    }

                    if ungroupedCount > 0 {
                        chip(title: "lc.appGroup.ungrouped".loc,
                             symbolName: "tray",
                             tint: .gray,
                             count: ungroupedCount,
                             isSelected: groupManager.filter == .ungrouped) {
                            groupManager.filter = groupManager.filter == .ungrouped ? .all : .ungrouped
                        }
                    }

                    Button(action: onManageTapped) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color(.secondarySystemBackground))
                            )
                    }
                    .accessibilityLabel("lc.appGroup.manage".loc)
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
            .animation(.easeInOut, value: groupManager.groups)
        }
    }

    @ViewBuilder
    private func chip(title: String,
                      symbolName: String,
                      tint: Color,
                      count: Int,
                      isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(.footnote.weight(.semibold))
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(isSelected ? Color.white.opacity(0.25) : tint.opacity(0.18))
                    )
            }
            .foregroundStyle(isSelected ? Color.white : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? tint : Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }
}
