//
//  LCBackupView.swift
//  LiveContainerSwiftUI
//
//  Backup creation, listing and restore.
//

import SwiftUI
import UniformTypeIdentifiers

struct LCBackupView: View {
    // ObservedObject, not StateObject: this view observes the shared manager, it doesn't own it.
    @ObservedObject private var manager = LCBackupManager.shared
    @EnvironmentObject private var sharedModel: SharedModel

    @State private var scope: LCBackupScope = .appData
    @State private var selectedAppPaths: Set<String> = []
    @State private var includeTweaks = true

    @State private var errorShow = false
    @State private var errorInfo = ""

    @State private var restorePlan: LCBackupManager.LCRestorePlan?
    @State private var restoreSheetShown = false

    @State private var pendingDeletion: LCBackupFile?
    @State private var exportedBackup: LCBackupFile?

    private var candidateApps: [LCAppModel] {
        // Hidden apps are only offered once unlocked; otherwise a backup listing would
        // disclose that they exist.
        sharedModel.isHiddenAppUnlocked ? sharedModel.apps + sharedModel.hiddenApps : sharedModel.apps
    }

    private var selectedApps: [LCAppModel] {
        candidateApps.filter { app in
            guard let path = app.appInfo.relativeBundlePath else { return false }
            return selectedAppPaths.contains(path)
        }
    }

    private var estimatedSizeText: String {
        let bytes = manager.estimatedSize(apps: selectedApps, scope: scope)
        return ByteCountFormatter().string(fromByteCount: bytes)
    }

    /// Tweak folders are read from disk rather than passed in, so this screen can be
    /// pushed from anywhere without threading the app list's state through.
    private var tweakFolderNames: [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: LCPath.tweakPath,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
    }

    var body: some View {
        List {
            if manager.isBusy {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(manager.progressText).font(.footnote)
                        ProgressView(value: manager.progressFraction)
                    }
                }
            }

            Section {
                Picker("lc.backup.scope".loc, selection: $scope) {
                    ForEach(LCBackupScope.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                if scope.includesAppData {
                    Toggle("lc.backup.includeTweaks".loc, isOn: $includeTweaks)
                }

                HStack {
                    Text("lc.backup.estimatedSize".loc)
                    Spacer()
                    Text(estimatedSizeText).foregroundStyle(.gray)
                }
            } header: {
                Text("lc.backup.newBackup".loc)
            } footer: {
                Text(scope.includesBundles
                     ? "lc.backup.scope.everythingTip".loc
                     : "lc.backup.scope.appDataTip".loc)
            }

            if scope.includesAppData {
                Section {
                    HStack {
                        Button("lc.backup.selectAll".loc) {
                            selectedAppPaths = Set(candidateApps.compactMap { $0.appInfo.relativeBundlePath })
                        }
                        Spacer()
                        Button("lc.backup.selectNone".loc) {
                            selectedAppPaths.removeAll()
                        }
                    }
                    .font(.footnote)

                    ForEach(candidateApps, id: \.self) { app in
                        if let path = app.appInfo.relativeBundlePath {
                            Button {
                                if selectedAppPaths.contains(path) {
                                    selectedAppPaths.remove(path)
                                } else {
                                    selectedAppPaths.insert(path)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(app.displayName).foregroundStyle(.primary)
                                        Text(app.bundleIdentifier)
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }
                                    Spacer()
                                    if selectedAppPaths.contains(path) {
                                        Image(systemName: "checkmark").foregroundStyle(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("lc.backup.appsToInclude".loc)
                }
            }

            Section {
                Button {
                    Task { await createBackup() }
                } label: {
                    Label("lc.backup.createNow".loc, systemImage: "externaldrive.badge.plus")
                }
                .disabled(manager.isBusy || (scope.includesAppData && selectedAppPaths.isEmpty))
            }

            Section {
                Toggle("lc.backup.auto.enabled".loc, isOn: Binding(
                    get: { manager.autoBackupEnabled },
                    set: { manager.autoBackupEnabled = $0 }
                ))

                if manager.autoBackupEnabled {
                    Stepper(value: Binding(
                        get: { manager.autoBackupIntervalDays },
                        set: { manager.autoBackupIntervalDays = $0 }
                    ), in: 1...30) {
                        Text("lc.backup.auto.interval %lld".localizeWithFormat(manager.autoBackupIntervalDays))
                    }

                    Stepper(value: Binding(
                        get: { manager.retentionCount },
                        set: { manager.retentionCount = $0 }
                    ), in: 1...20) {
                        Text("lc.backup.auto.retention %lld".localizeWithFormat(manager.retentionCount))
                    }

                    Picker("lc.backup.auto.scope".loc, selection: Binding(
                        get: { manager.autoBackupScope },
                        set: { manager.autoBackupScope = $0 }
                    )) {
                        ForEach(LCBackupScope.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }
            } header: {
                Text("lc.backup.auto".loc)
            } footer: {
                Text("lc.backup.auto.tip".loc)
            }

            Section {
                if manager.backups.isEmpty {
                    Text("lc.backup.noBackups".loc).foregroundStyle(.gray)
                } else {
                    ForEach(manager.backups) { backup in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.displayName).font(.callout)
                            Text("\(backup.createdAt.formatted()) · \(ByteCountFormatter().string(fromByteCount: backup.byteSize))")
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }
                        .contextMenu {
                            Button {
                                Task { await beginRestore(backup) }
                            } label: {
                                Label("lc.backup.restore".loc, systemImage: "arrow.clockwise")
                            }
                            Button {
                                exportedBackup = backup
                            } label: {
                                Label("lc.backup.share".loc, systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                pendingDeletion = backup
                            } label: {
                                Label("lc.common.delete".loc, systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("lc.backup.existing".loc)
            }
        }
        .navigationTitle("lc.backup.title".loc)
        .onAppear {
            manager.refreshBackupList()
            if selectedAppPaths.isEmpty {
                selectedAppPaths = Set(candidateApps.compactMap { $0.appInfo.relativeBundlePath })
            }
        }
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, action: {})
        } message: {
            Text(errorInfo)
        }
        .alert("lc.backup.confirmDelete".loc, isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("lc.common.delete".loc, role: .destructive) {
                if let pendingDeletion {
                    manager.deleteBackup(pendingDeletion)
                }
                pendingDeletion = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pendingDeletion = nil
            }
        }
        .sheet(isPresented: $restoreSheetShown, onDismiss: {
            // Dismissing without committing must not leak the extracted staging directory.
            if let restorePlan {
                manager.discardRestore(restorePlan)
                self.restorePlan = nil
            }
        }) {
            if let restorePlan {
                LCRestoreSheet(plan: restorePlan) { selection, restorePreferences in
                    Task { await applyRestore(plan: restorePlan,
                                              selection: selection,
                                              restorePreferences: restorePreferences) }
                }
            }
        }
        .sheet(item: $exportedBackup) { backup in
            ActivityViewController(activityItems: [backup.url])
        }
    }

    private func createBackup() async {
        do {
            try await manager.createBackup(
                apps: selectedApps,
                scope: scope,
                tweakFolderNames: includeTweaks && scope.includesAppData ? tweakFolderNames : [])
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    private func beginRestore(_ backup: LCBackupFile) async {
        do {
            restorePlan = try await manager.prepareRestore(from: backup)
            restoreSheetShown = true
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    private func applyRestore(plan: LCBackupManager.LCRestorePlan,
                              selection: Set<String>,
                              restorePreferences: Bool) async {
        do {
            try await manager.applyRestore(plan,
                                           selectedApps: selection,
                                           restorePreferences: restorePreferences)
            // applyRestore consumes the plan, so clear it before the sheet's onDismiss runs.
            restorePlan = nil
            restoreSheetShown = false
        } catch {
            restorePlan = nil
            restoreSheetShown = false
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
}

/// Confirmation step for a restore: shows what the archive holds and what will be overwritten.
struct LCRestoreSheet: View {
    let plan: LCBackupManager.LCRestorePlan
    /// Called with the chosen relative bundle paths and whether to reapply preferences.
    let onConfirm: (Set<String>, Bool) -> Void

    @Environment(\.presentationMode) private var presentationMode

    @State private var selection: Set<String> = []
    @State private var restorePreferences = true

    private var conflictingPaths: Set<String> {
        Set(plan.conflictingApps.map { $0.relativeBundlePath })
    }

    private var missingPaths: Set<String> {
        Set(plan.missingApps.map { $0.relativeBundlePath })
    }

    @ViewBuilder
    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.gray)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    // Plain HStacks rather than LabeledContent: LiveContainer targets iOS 15.
                    detailRow("lc.backup.createdAt".loc, plan.manifest.createdAt.formatted())
                    detailRow("lc.backup.scope".loc, plan.manifest.scope.displayName)
                    detailRow("lc.backup.sourceVersion".loc, plan.manifest.liveContainerVersion)
                }

                if !plan.missingApps.isEmpty {
                    Section {
                        Text("lc.backup.restore.missingTip".loc)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("lc.backup.restore.chooseApps".loc) {
                    ForEach(plan.manifest.apps) { record in
                        Button {
                            if selection.contains(record.relativeBundlePath) {
                                selection.remove(record.relativeBundlePath)
                            } else {
                                selection.insert(record.relativeBundlePath)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.displayName).foregroundStyle(.primary)
                                    if conflictingPaths.contains(record.relativeBundlePath) {
                                        Text("lc.backup.restore.willOverwrite".loc)
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    } else if missingPaths.contains(record.relativeBundlePath) {
                                        Text("lc.backup.restore.notInstalled".loc)
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }
                                }
                                Spacer()
                                if selection.contains(record.relativeBundlePath) {
                                    Image(systemName: "checkmark").foregroundStyle(.accentColor)
                                }
                            }
                        }
                        // An app whose bundle is neither installed nor in the archive has
                        // nowhere to restore into.
                        .disabled(missingPaths.contains(record.relativeBundlePath))
                    }
                }

                if plan.manifest.includesPreferences {
                    Section {
                        Toggle("lc.backup.restore.preferences".loc, isOn: $restorePreferences)
                    }
                }
            }
            .navigationTitle("lc.backup.restore".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.backup.restore".loc) {
                        onConfirm(selection, restorePreferences)
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .onAppear {
                // Preselect everything restorable.
                selection = Set(plan.manifest.apps
                    .map { $0.relativeBundlePath }
                    .filter { !missingPaths.contains($0) })
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
