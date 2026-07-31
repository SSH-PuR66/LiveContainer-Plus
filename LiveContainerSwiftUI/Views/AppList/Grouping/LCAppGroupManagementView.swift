//
//  LCAppGroupManagementView.swift
//  LiveContainerSwiftUI
//
//  Create, edit, reorder and delete app groups.
//

import SwiftUI

struct LCAppGroupManagementView: View {
    @ObservedObject var groupManager: LCAppGroupManager
    var apps: [LCAppModel]

    @Environment(\.presentationMode) private var presentationMode

    @State private var editingGroup: LCAppGroup?
    @State private var isCreating = false

    var body: some View {
        NavigationView {
            List {
                if groupManager.groups.isEmpty {
                    Section {
                        Text("lc.appGroup.emptyTip".loc)
                            .foregroundStyle(.gray)
                    }
                }

                Section {
                    ForEach(groupManager.groups) { group in
                        Button {
                            editingGroup = group
                        } label: {
                            HStack {
                                Image(systemName: group.symbolName)
                                    .foregroundStyle(group.tint.color)
                                    .frame(width: 24)
                                Text(group.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("lc.appGroup.appCount %lld".localizeWithFormat(groupManager.memberCount(of: group, in: apps)))
                                    .foregroundStyle(.gray)
                                    .font(.footnote)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color(.tertiaryLabel))
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            groupManager.deleteGroup(id: groupManager.groups[index].id)
                        }
                    }
                    .onMove { source, destination in
                        groupManager.moveGroups(fromOffsets: source, toOffset: destination)
                    }
                }

                Section {
                    Button {
                        isCreating = true
                    } label: {
                        Label("lc.appGroup.new".loc, systemImage: "plus")
                    }
                }
            }
            .navigationTitle("lc.appGroup.manage".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.done".loc) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(item: $editingGroup) { group in
                LCAppGroupEditorView(groupManager: groupManager, apps: apps, group: group)
            }
            .sheet(isPresented: $isCreating) {
                LCAppGroupEditorView(groupManager: groupManager, apps: apps, group: nil)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

/// Editor for a single group. `group == nil` creates a new one.
struct LCAppGroupEditorView: View {
    @ObservedObject var groupManager: LCAppGroupManager
    var apps: [LCAppModel]
    var group: LCAppGroup?

    @Environment(\.presentationMode) private var presentationMode

    @State private var name: String
    @State private var symbolName: String
    @State private var tint: LCAppGroupTint
    @State private var memberIds: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 12)]

    init(groupManager: LCAppGroupManager, apps: [LCAppModel], group: LCAppGroup?) {
        self.groupManager = groupManager
        self.apps = apps
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _symbolName = State(initialValue: group?.symbolName ?? "folder")
        _tint = State(initialValue: group?.tint ?? .blue)
        _memberIds = State(initialValue: Set(group?.memberIds ?? []))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Image(systemName: symbolName)
                            .foregroundStyle(tint.color)
                            .frame(width: 24)
                        TextField("lc.appGroup.namePlaceholder".loc, text: $name)
                    }
                }

                Section("lc.appGroup.icon".loc) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(LCAppGroupManager.symbolChoices, id: \.self) { choice in
                            Button {
                                symbolName = choice
                            } label: {
                                Image(systemName: choice)
                                    .font(.body)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(symbolName == choice ? tint.color.opacity(0.25) : Color(.secondarySystemBackground))
                                    )
                                    .foregroundStyle(symbolName == choice ? tint.color : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("lc.appGroup.color".loc) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(LCAppGroupTint.allCases) { choice in
                            Button {
                                tint = choice
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.primary, lineWidth: tint == choice ? 2 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("lc.appGroup.members".loc) {
                    ForEach(apps, id: \.self) { app in
                        if let identifier = LCAppGroupManager.identifier(for: app) {
                            Button {
                                if memberIds.contains(identifier) {
                                    memberIds.remove(identifier)
                                } else {
                                    memberIds.insert(identifier)
                                }
                            } label: {
                                HStack {
                                    Text(app.appInfo.displayName() ?? identifier)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if memberIds.contains(identifier) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(tint.color)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(group == nil ? "lc.appGroup.new".loc : "lc.appGroup.edit".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.save".loc) {
                        save()
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func save() {
        // Preserve the stored order of existing members and append newly checked ones,
        // so editing a group doesn't shuffle it.
        let existingOrder = group?.memberIds ?? []
        var ordered = existingOrder.filter { memberIds.contains($0) }
        ordered.append(contentsOf: memberIds.filter { !ordered.contains($0) })

        if var group {
            group.name = trimmedName
            group.symbolName = symbolName
            group.tint = tint
            group.memberIds = ordered
            groupManager.updateGroup(group)
        } else {
            var created = groupManager.createGroup(name: trimmedName, symbolName: symbolName, tint: tint)
            created.memberIds = ordered
            groupManager.updateGroup(created)
        }
    }
}
