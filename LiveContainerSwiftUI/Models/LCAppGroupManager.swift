//
//  LCAppGroupManager.swift
//  LiveContainerSwiftUI
//
//  User-defined app groups (folders). Resolves LiveContainer/LiveContainer#283.
//

import Foundation
import SwiftUI
import Combine

/// The tint applied to a group's chip and badge.
///
/// A fixed palette rather than free-form hex: it keeps the persisted payload tiny,
/// renders correctly in both light and dark mode without contrast math, and gives the
/// picker a finite set to lay out.
enum LCAppGroupTint: String, Codable, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue:   return .blue
        case .purple: return .purple
        case .pink:   return .pink
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .teal:   return .teal
        case .gray:   return .gray
        }
    }
}

/// A user-defined collection of apps.
///
/// Membership is stored as `bundleId:relativeBundlePath` — the same identity
/// `LCAppSortManager` uses — so a group keeps two installs of the same app distinct and
/// survives display-name changes.
struct LCAppGroup: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var symbolName: String
    var tint: LCAppGroupTint
    /// Ordered so the group management UI can present a stable list.
    var memberIds: [String]

    init(id: String = UUID().uuidString,
         name: String,
         symbolName: String = "folder",
         tint: LCAppGroupTint = .blue,
         memberIds: [String] = []) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.tint = tint
        self.memberIds = memberIds
    }
}

/// The currently applied app-list filter.
enum LCAppGroupFilter: Hashable {
    case all
    case ungrouped
    case group(String)

    var groupId: String? {
        if case .group(let id) = self { return id }
        return nil
    }
}

/// Owns group definitions, membership, and the active filter.
///
/// Persisted as JSON in the shared app group suite so every LiveContainer instance on the
/// device sees the same grouping.
class LCAppGroupManager: ObservableObject {

    static let shared = LCAppGroupManager()

    private static let groupsKey = "LCAppGroups"
    private static let filterKey = "LCAppGroupSelectedFilter"

    /// SF Symbols offered when creating or editing a group. All exist on iOS 15.
    static let symbolChoices = [
        "folder", "star", "heart", "bolt", "gamecontroller", "music.note",
        "play.rectangle", "message", "cart", "briefcase", "book", "camera",
        "paintbrush", "wrench.and.screwdriver", "lock", "flask", "airplane", "creditcard"
    ]

    @Published private(set) var groups: [LCAppGroup] = [] {
        didSet { persistGroups() }
    }

    /// Not persisted as an enum — `filterKey` stores either `""` (all), `"~ungrouped"`, or a group id.
    @Published var filter: LCAppGroupFilter = .all {
        didSet { persistFilter() }
    }

    private var isLoading = false

    private init() {
        load()
    }

    // MARK: - Identity

    /// The stable identity used for membership. Mirrors `LCAppSortManager.getUniqueIdentifier`.
    static func identifier(for app: LCAppModel) -> String? {
        guard let bundleId = app.appInfo.bundleIdentifier(),
              let relativePath = app.appInfo.relativeBundlePath else {
            return nil
        }
        return "\(bundleId):\(relativePath)"
    }

    // MARK: - Persistence

    private func load() {
        isLoading = true
        defer { isLoading = false }

        if let data = LCUtils.appGroupUserDefault.data(forKey: Self.groupsKey),
           let decoded = try? JSONDecoder().decode([LCAppGroup].self, from: data) {
            groups = decoded
        } else {
            groups = []
        }

        switch LCUtils.appGroupUserDefault.string(forKey: Self.filterKey) {
        case .none, .some(""):
            filter = .all
        case .some("~ungrouped"):
            filter = .ungrouped
        case .some(let id):
            // A group deleted on another LiveContainer instance must not strand the filter.
            filter = groups.contains(where: { $0.id == id }) ? .group(id) : .all
        }
    }

    private func persistGroups() {
        guard !isLoading else { return }
        guard let data = try? JSONEncoder().encode(groups) else { return }
        LCUtils.appGroupUserDefault.set(data, forKey: Self.groupsKey)
    }

    private func persistFilter() {
        guard !isLoading else { return }
        let raw: String
        switch filter {
        case .all: raw = ""
        case .ungrouped: raw = "~ungrouped"
        case .group(let id): raw = id
        }
        LCUtils.appGroupUserDefault.set(raw, forKey: Self.filterKey)
    }

    // MARK: - Group CRUD

    @discardableResult
    func createGroup(name: String,
                     symbolName: String = "folder",
                     tint: LCAppGroupTint = .blue) -> LCAppGroup {
        let group = LCAppGroup(name: name, symbolName: symbolName, tint: tint)
        groups.append(group)
        return group
    }

    func updateGroup(_ group: LCAppGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
    }

    func deleteGroup(id: String) {
        groups.removeAll { $0.id == id }
        if filter.groupId == id {
            filter = .all
        }
    }

    func moveGroups(fromOffsets: IndexSet, toOffset: Int) {
        groups.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func group(withId id: String) -> LCAppGroup? {
        groups.first { $0.id == id }
    }

    // MARK: - Membership

    func groups(containing app: LCAppModel) -> [LCAppGroup] {
        guard let identifier = Self.identifier(for: app) else { return [] }
        return groups.filter { $0.memberIds.contains(identifier) }
    }

    func isMember(_ app: LCAppModel, ofGroup groupId: String) -> Bool {
        guard let identifier = Self.identifier(for: app),
              let group = group(withId: groupId) else { return false }
        return group.memberIds.contains(identifier)
    }

    /// An app may belong to several groups, so this toggles one membership rather than
    /// reassigning the app wholesale.
    func setMembership(_ app: LCAppModel, groupId: String, isMember: Bool) {
        guard let identifier = Self.identifier(for: app),
              let index = groups.firstIndex(where: { $0.id == groupId }) else { return }

        if isMember {
            guard !groups[index].memberIds.contains(identifier) else { return }
            groups[index].memberIds.append(identifier)
        } else {
            groups[index].memberIds.removeAll { $0 == identifier }
        }
    }

    func removeFromAllGroups(_ app: LCAppModel) {
        guard let identifier = Self.identifier(for: app) else { return }
        for index in groups.indices {
            groups[index].memberIds.removeAll { $0 == identifier }
        }
    }

    /// Drops membership entries whose app no longer exists.
    ///
    /// Uninstalling an app leaves its identifier behind; without this the group counts
    /// drift upward forever and "Ungrouped" silently under-reports.
    func pruneMissingApps(knownApps: [LCAppModel]) {
        let live = Set(knownApps.compactMap { Self.identifier(for: $0) })
        guard !live.isEmpty else { return }

        var changed = false
        var updated = groups
        for index in updated.indices {
            let filtered = updated[index].memberIds.filter { live.contains($0) }
            if filtered.count != updated[index].memberIds.count {
                updated[index].memberIds = filtered
                changed = true
            }
        }
        if changed {
            groups = updated
        }
    }

    // MARK: - Filtering

    func apply(_ filter: LCAppGroupFilter, to apps: [LCAppModel]) -> [LCAppModel] {
        switch filter {
        case .all:
            return apps
        case .ungrouped:
            let grouped = Set(groups.flatMap { $0.memberIds })
            return apps.filter { app in
                guard let identifier = Self.identifier(for: app) else { return true }
                return !grouped.contains(identifier)
            }
        case .group(let id):
            guard let group = group(withId: id) else { return apps }
            let members = Set(group.memberIds)
            return apps.filter { app in
                guard let identifier = Self.identifier(for: app) else { return false }
                return members.contains(identifier)
            }
        }
    }

    /// Live member count, ignoring identifiers whose app is gone.
    func memberCount(of group: LCAppGroup, in apps: [LCAppModel]) -> Int {
        let members = Set(group.memberIds)
        return apps.reduce(into: 0) { total, app in
            if let identifier = Self.identifier(for: app), members.contains(identifier) {
                total += 1
            }
        }
    }

    func ungroupedCount(in apps: [LCAppModel]) -> Int {
        let grouped = Set(groups.flatMap { $0.memberIds })
        return apps.reduce(into: 0) { total, app in
            if let identifier = Self.identifier(for: app), !grouped.contains(identifier) {
                total += 1
            }
        }
    }
}
