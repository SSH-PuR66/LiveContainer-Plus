//
//  LCBackupManager.swift
//  LiveContainerSwiftUI
//
//  Backup and restore of app data, tweaks and LiveContainer settings.
//  Resolves LiveContainer/LiveContainer#1353.
//

import Foundation
import Combine
import UIKit

/// What a backup archive carries.
///
/// App bundles dominate the size of a full backup (hundreds of MB each) while contributing
/// nothing that can't be reinstalled from an IPA, so they're opt-in rather than default.
enum LCBackupScope: String, Codable, CaseIterable, Identifiable {
    /// LiveContainer's own preferences and app groups only. Tiny, always safe.
    case settingsOnly
    /// Preferences plus every selected app's containers and tweaks.
    case appData
    /// Everything above plus the app bundles themselves.
    case everything

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .settingsOnly: return "lc.backup.scope.settingsOnly".loc
        case .appData:      return "lc.backup.scope.appData".loc
        case .everything:   return "lc.backup.scope.everything".loc
        }
    }

    var includesAppData: Bool { self != .settingsOnly }
    var includesBundles: Bool { self == .everything }
}

/// One app as recorded in a backup manifest.
struct LCBackupAppRecord: Codable, Identifiable, Hashable {
    var bundleIdentifier: String
    var displayName: String
    var version: String
    /// Folder name under `Applications/`, which is also this record's identity.
    var relativeBundlePath: String
    var isShared: Bool
    /// Container folder names captured for this app.
    var containerFolderNames: [String]
    var bundleIncluded: Bool
    var byteSize: Int64

    var id: String { relativeBundlePath }
}

/// The `manifest.json` at the root of every backup archive.
struct LCBackupManifest: Codable {
    /// Bumped when the on-disk layout changes incompatibly. Restore refuses anything higher.
    static let currentFormatVersion = 1

    var formatVersion: Int
    var createdAt: Date
    var liveContainerVersion: String
    var deviceName: String
    var systemVersion: String
    var scope: LCBackupScope
    var apps: [LCBackupAppRecord]
    var tweakFolderNames: [String]
    var includesPreferences: Bool
    /// Uncompressed total of everything staged, used for the free-space check on restore.
    var uncompressedByteSize: Int64
}

/// A backup file discovered on disk.
struct LCBackupFile: Identifiable, Hashable {
    var url: URL
    var byteSize: Int64
    var createdAt: Date
    /// Nil until the manifest has been read; unreadable archives keep it nil.
    var manifest: LCBackupManifest?

    var id: URL { url }

    var displayName: String { url.deletingPathExtension().lastPathComponent }
}

enum LCBackupError: LocalizedError {
    case noAppsSelected
    case insufficientSpace(needed: Int64, available: Int64)
    case manifestMissing
    case manifestUnreadable
    case unsupportedFormat(Int)
    case archiveFailed(String)
    case extractionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .noAppsSelected:
            return "lc.backup.error.noAppsSelected".loc
        case .insufficientSpace(let needed, let available):
            let formatter = ByteCountFormatter()
            return "lc.backup.error.insufficientSpace %@ %@".localizeWithFormat(
                formatter.string(fromByteCount: needed),
                formatter.string(fromByteCount: available))
        case .manifestMissing:
            return "lc.backup.error.manifestMissing".loc
        case .manifestUnreadable:
            return "lc.backup.error.manifestUnreadable".loc
        case .unsupportedFormat(let version):
            return "lc.backup.error.unsupportedFormat %lld".localizeWithFormat(version)
        case .archiveFailed(let detail):
            return "lc.backup.error.archiveFailed".loc + "\n" + detail
        case .extractionFailed(let code):
            return "lc.backup.error.extractionFailed %lld".localizeWithFormat(Int(code))
        }
    }
}

// File-scope rather than static members of the @MainActor class below: the nonisolated
// helpers need them, and actor-isolated statics aren't reachable from those.
fileprivate let lcBackupManifestFileName = "manifest.json"
fileprivate let lcBackupPreferencesFileName = "preferences.json"
fileprivate let lcBackupFileExtension = "lcbackup"

/// Creates, lists, prunes and restores backups.
///
/// Staging copies files before zipping, so a backup transiently needs roughly its own
/// uncompressed size in free space. `estimatedSize` and the pre-flight check in
/// `createBackup` exist so that cost is visible before the user commits to it.
@MainActor
class LCBackupManager: ObservableObject {

    static let shared = LCBackupManager()

    /// Preference keys copied into a backup. Deliberately excludes anything secret:
    /// the signing certificate and its password stay out of archives that users share.
    private static let preferenceKeysToBackUp = [
        "LCAppGroups",
        "LCAppGroupSelectedFilter",
        "LCAppSortType",
        "LCCustomSortOrder",
        "LCMultitaskMode",
        "LCLaunchInMultitaskMode",
        "LCStrictHiding",
        "dynamicColors",
        "darkModeIcon",
        "LCAltStoreSources",
        "LCBackupAutoEnabled",
        "LCBackupIntervalDays",
        "LCBackupRetentionCount",
        "LCBackupScope"
    ]

    @Published private(set) var backups: [LCBackupFile] = []
    @Published private(set) var isBusy = false
    @Published private(set) var progressText: String = ""
    @Published private(set) var progressFraction: Double = 0

    // MARK: - Auto-backup preferences

    var autoBackupEnabled: Bool {
        get { LCUtils.appGroupUserDefault.bool(forKey: "LCBackupAutoEnabled") }
        set { LCUtils.appGroupUserDefault.set(newValue, forKey: "LCBackupAutoEnabled") }
    }

    var autoBackupIntervalDays: Int {
        get {
            let stored = LCUtils.appGroupUserDefault.integer(forKey: "LCBackupIntervalDays")
            return stored > 0 ? stored : 1
        }
        set { LCUtils.appGroupUserDefault.set(max(1, newValue), forKey: "LCBackupIntervalDays") }
    }

    var retentionCount: Int {
        get {
            let stored = LCUtils.appGroupUserDefault.integer(forKey: "LCBackupRetentionCount")
            return stored > 0 ? stored : 5
        }
        set { LCUtils.appGroupUserDefault.set(max(1, newValue), forKey: "LCBackupRetentionCount") }
    }

    var autoBackupScope: LCBackupScope {
        get {
            guard let raw = LCUtils.appGroupUserDefault.string(forKey: "LCBackupScope"),
                  let scope = LCBackupScope(rawValue: raw) else {
                // App bundles are re-downloadable; data is not. Default accordingly.
                return .appData
            }
            return scope
        }
        set { LCUtils.appGroupUserDefault.set(newValue.rawValue, forKey: "LCBackupScope") }
    }

    private(set) var lastAutoBackupDate: Date? {
        get { LCUtils.appGroupUserDefault.object(forKey: "LCBackupLastAutoDate") as? Date }
        set { LCUtils.appGroupUserDefault.set(newValue, forKey: "LCBackupLastAutoDate") }
    }

    // MARK: - Locations

    static var backupDirectory: URL {
        LCPath.docPath.appendingPathComponent("Backups")
    }

    private static var stagingDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LCBackupStaging")
    }

    private init() {}

    // MARK: - Off-main execution

    /// Runs blocking filesystem work off the main actor.
    ///
    /// Zipping, extracting and copying containers take seconds to minutes. Left on the main
    /// actor they would freeze the very progress UI that reports them, so every blocking call
    /// in this file goes through here and the `@Published` progress updates stay on main.
    private nonisolated func runOffMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Copy helper that always runs off-main and uses its own FileManager, which is the
    /// documented way to touch the filesystem from a background queue.
    private nonisolated func copyOffMain(from source: URL, to destination: URL) async throws {
        try await runOffMain {
            try FileManager().copyItem(at: source, to: destination)
        }
    }

    // MARK: - Listing

    func refreshBackupList() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Self.backupDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]) else {
            backups = []
            return
        }

        backups = entries
            .filter { $0.pathExtension == lcBackupFileExtension }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                return LCBackupFile(url: url,
                                    byteSize: Int64(values?.fileSize ?? 0),
                                    createdAt: values?.creationDate ?? .distantPast,
                                    manifest: nil)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Reads a manifest without extracting the whole archive.
    ///
    /// libarchive's `extract` is all-or-nothing here, so this unpacks to a scratch
    /// directory and keeps only the manifest. Fine for a file that is a few KB.
    nonisolated func readManifest(of backup: LCBackupFile) throws -> LCBackupManifest {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LCManifestPeek-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let status = extract(backup.url.path, scratch.path, nil)
        guard status == 0 else { throw LCBackupError.extractionFailed(Int32(status)) }

        let manifestURL = scratch.appendingPathComponent(lcBackupManifestFileName)
        guard fm.fileExists(atPath: manifestURL.path) else { throw LCBackupError.manifestMissing }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(LCBackupManifest.self, from: data) else {
            throw LCBackupError.manifestUnreadable
        }
        return manifest
    }

    // MARK: - Size estimation

    /// Uncompressed size the given selection would occupy while staging.
    nonisolated func estimatedSize(apps: [LCAppModel], scope: LCBackupScope) -> Int64 {
        guard scope.includesAppData else { return 0 }

        var total: Int64 = 0
        for app in apps {
            if scope.includesBundles, let bundlePath = app.appInfo.bundlePath() {
                total += Self.directorySize(at: URL(fileURLWithPath: bundlePath))
            }
            for container in app.appInfo.containers {
                total += Self.directorySize(at: container.containerURL)
            }
        }
        return total
    }

    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: []) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    nonisolated private static func availableCapacity() -> Int64 {
        let values = try? LCPath.docPath.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    // MARK: - Creating a backup

    /// Stages the selection, zips it, and prunes old archives.
    ///
    /// - Parameter name: archive name without extension. A timestamp is used when nil.
    @discardableResult
    func createBackup(apps: [LCAppModel],
                      scope: LCBackupScope,
                      name: String? = nil,
                      tweakFolderNames: [String] = []) async throws -> LCBackupFile {

        if scope.includesAppData && apps.isEmpty {
            throw LCBackupError.noAppsSelected
        }

        isBusy = true
        progressFraction = 0
        progressText = "lc.backup.progress.preparing".loc
        defer {
            isBusy = false
            progressFraction = 0
            progressText = ""
        }

        let needed = estimatedSize(apps: apps, scope: scope)
        let available = Self.availableCapacity()
        // Staging copy + resulting zip both live on disk at the peak, hence the doubling.
        if needed * 2 > available {
            throw LCBackupError.insufficientSpace(needed: needed * 2, available: available)
        }

        let fm = FileManager.default
        let staging = Self.stagingDirectory
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var records: [LCBackupAppRecord] = []
        var stagedBytes: Int64 = 0

        if scope.includesAppData {
            let bundlesRoot = staging.appendingPathComponent("Applications")
            let dataRoot = staging.appendingPathComponent("Data/Application")
            try fm.createDirectory(at: bundlesRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)

            for (index, app) in apps.enumerated() {
                progressText = "lc.backup.progress.copying %@".localizeWithFormat(app.displayName)
                progressFraction = Double(index) / Double(max(apps.count, 1)) * 0.8

                guard let relativeBundlePath = app.appInfo.relativeBundlePath else { continue }

                var recordSize: Int64 = 0

                if scope.includesBundles, let bundlePath = app.appInfo.bundlePath() {
                    let source = URL(fileURLWithPath: bundlePath)
                    let destination = bundlesRoot.appendingPathComponent(relativeBundlePath)
                    try await copyOffMain(from: source, to: destination)
                    recordSize += Self.directorySize(at: destination)
                }

                var containerNames: [String] = []
                for container in app.appInfo.containers {
                    let source = container.containerURL
                    guard fm.fileExists(atPath: source.path) else { continue }
                    let destination = dataRoot.appendingPathComponent(container.folderName)
                    try await copyOffMain(from: source, to: destination)
                    containerNames.append(container.folderName)
                    recordSize += Self.directorySize(at: destination)
                }

                stagedBytes += recordSize
                records.append(LCBackupAppRecord(
                    bundleIdentifier: app.bundleIdentifier,
                    displayName: app.displayName,
                    version: app.version,
                    relativeBundlePath: relativeBundlePath,
                    isShared: app.appInfo.isShared,
                    containerFolderNames: containerNames,
                    bundleIncluded: scope.includesBundles,
                    byteSize: recordSize))
            }

            // Tweaks are small and frequently hand-assembled, so they ride along with app data.
            for folderName in tweakFolderNames {
                let source = LCPath.tweakPath.appendingPathComponent(folderName)
                guard fm.fileExists(atPath: source.path) else { continue }
                let tweaksRoot = staging.appendingPathComponent("Tweaks")
                if !fm.fileExists(atPath: tweaksRoot.path) {
                    try fm.createDirectory(at: tweaksRoot, withIntermediateDirectories: true)
                }
                try await copyOffMain(from: source, to: tweaksRoot.appendingPathComponent(folderName))
                stagedBytes += Self.directorySize(at: tweaksRoot.appendingPathComponent(folderName))
            }
        }

        progressText = "lc.backup.progress.writingManifest".loc
        progressFraction = 0.85

        try writePreferences(to: staging.appendingPathComponent(lcBackupPreferencesFileName))

        let manifest = LCBackupManifest(
            formatVersion: LCBackupManifest.currentFormatVersion,
            createdAt: Date(),
            liveContainerVersion: LCUtils.getVersionInfo(),
            deviceName: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            scope: scope,
            apps: records,
            tweakFolderNames: tweakFolderNames,
            includesPreferences: true,
            uncompressedByteSize: stagedBytes)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(lcBackupManifestFileName))

        progressText = "lc.backup.progress.compressing".loc
        progressFraction = 0.9

        if !fm.fileExists(atPath: Self.backupDirectory.path) {
            try fm.createDirectory(at: Self.backupDirectory, withIntermediateDirectories: true)
        }

        let archiveName = name ?? Self.defaultBackupName()
        let destination = Self.backupDirectory
            .appendingPathComponent(archiveName)
            .appendingPathExtension(lcBackupFileExtension)

        // Compression of a multi-GB staging tree must not run on the main actor.
        let zipFailure: String? = try await runOffMain {
            var zipError: NSError?
            if LCZipDirectory(staging, destination, &zipError) {
                return nil
            }
            return zipError?.localizedDescription ?? "unknown"
        }
        if let zipFailure {
            throw LCBackupError.archiveFailed(zipFailure)
        }

        progressFraction = 1.0
        refreshBackupList()
        pruneOldBackups()

        guard let created = backups.first(where: { $0.url == destination }) else {
            throw LCBackupError.archiveFailed("Backup file missing after write.")
        }
        return created
    }

    private static func defaultBackupName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "LiveContainer-\(formatter.string(from: Date()))"
    }

    private func writePreferences(to url: URL) throws {
        var snapshot: [String: Any] = [:]
        let defaults = LCUtils.appGroupUserDefault
        for key in Self.preferenceKeysToBackUp {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }
        // Property list rather than JSON: the values include Date and Data, which
        // JSONSerialization refuses outright.
        let data = try PropertyListSerialization.data(fromPropertyList: snapshot,
                                                      format: .binary,
                                                      options: 0)
        try data.write(to: url)
    }

    // MARK: - Restoring

    /// What a given archive would change, computed before anything is written.
    struct LCRestorePlan {
        var manifest: LCBackupManifest
        /// Apps in the archive that are not currently installed.
        var missingApps: [LCBackupAppRecord]
        /// Apps whose containers would be overwritten.
        var conflictingApps: [LCBackupAppRecord]
        var extractedRoot: URL
    }

    /// Extracts an archive and reports what restoring it would do, without applying anything.
    ///
    /// Call `applyRestore` to commit, or `discardRestore` to throw the extraction away.
    func prepareRestore(from backup: LCBackupFile) async throws -> LCRestorePlan {
        isBusy = true
        progressText = "lc.backup.progress.extracting".loc
        progressFraction = 0
        defer {
            isBusy = false
            progressText = ""
            progressFraction = 0
        }

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LCRestore-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let archivePath = backup.url.path
        let rootPath = root.path
        let status: Int32 = try await runOffMain {
            extract(archivePath, rootPath, nil)
        }
        guard status == 0 else {
            try? fm.removeItem(at: root)
            throw LCBackupError.extractionFailed(status)
        }

        let manifestURL = root.appendingPathComponent(lcBackupManifestFileName)
        guard fm.fileExists(atPath: manifestURL.path) else {
            try? fm.removeItem(at: root)
            throw LCBackupError.manifestMissing
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(LCBackupManifest.self,
                                                 from: try Data(contentsOf: manifestURL)) else {
            try? fm.removeItem(at: root)
            throw LCBackupError.manifestUnreadable
        }

        guard manifest.formatVersion <= LCBackupManifest.currentFormatVersion else {
            try? fm.removeItem(at: root)
            throw LCBackupError.unsupportedFormat(manifest.formatVersion)
        }

        let installedPaths = Set(DataManager.shared.model.apps.compactMap { $0.appInfo.relativeBundlePath }
            + DataManager.shared.model.hiddenApps.compactMap { $0.appInfo.relativeBundlePath })

        var missing: [LCBackupAppRecord] = []
        var conflicting: [LCBackupAppRecord] = []
        for record in manifest.apps {
            if installedPaths.contains(record.relativeBundlePath) {
                conflicting.append(record)
            } else if !record.bundleIncluded {
                // No bundle in the archive and none installed: its data has nowhere to go.
                missing.append(record)
            }
        }

        return LCRestorePlan(manifest: manifest,
                             missingApps: missing,
                             conflictingApps: conflicting,
                             extractedRoot: root)
    }

    func discardRestore(_ plan: LCRestorePlan) {
        try? FileManager.default.removeItem(at: plan.extractedRoot)
    }

    /// Commits a prepared restore.
    ///
    /// - Parameters:
    ///   - selectedApps: relative bundle paths to restore; others in the archive are skipped.
    ///   - restorePreferences: whether to reapply the archived LiveContainer settings.
    func applyRestore(_ plan: LCRestorePlan,
                      selectedApps: Set<String>,
                      restorePreferences: Bool) async throws {
        isBusy = true
        progressText = "lc.backup.progress.restoring".loc
        progressFraction = 0
        defer {
            isBusy = false
            progressText = ""
            progressFraction = 0
            discardRestore(plan)
        }

        let fm = FileManager.default
        let root = plan.extractedRoot
        let records = plan.manifest.apps.filter { selectedApps.contains($0.relativeBundlePath) }

        for (index, record) in records.enumerated() {
            progressText = "lc.backup.progress.restoringApp %@".localizeWithFormat(record.displayName)
            progressFraction = Double(index) / Double(max(records.count, 1))

            if record.bundleIncluded {
                let source = root.appendingPathComponent("Applications/\(record.relativeBundlePath)")
                if fm.fileExists(atPath: source.path) {
                    let destinationRoot = record.isShared ? LCPath.lcGroupBundlePath : LCPath.bundlePath
                    let destination = destinationRoot.appendingPathComponent(record.relativeBundlePath)
                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: destination)
                    }
                    try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
                    try await copyOffMain(from: source, to: destination)
                }
            }

            for folderName in record.containerFolderNames {
                let source = root.appendingPathComponent("Data/Application/\(folderName)")
                guard fm.fileExists(atPath: source.path) else { continue }
                let destinationRoot = record.isShared ? LCPath.lcGroupDataPath : LCPath.dataPath
                let destination = destinationRoot.appendingPathComponent(folderName)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
                try await copyOffMain(from: source, to: destination)
            }
        }

        let tweaksRoot = root.appendingPathComponent("Tweaks")
        if fm.fileExists(atPath: tweaksRoot.path),
           let tweakFolders = try? fm.contentsOfDirectory(at: tweaksRoot, includingPropertiesForKeys: nil) {
            for folder in tweakFolders {
                let destination = LCPath.tweakPath.appendingPathComponent(folder.lastPathComponent)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try await copyOffMain(from: folder, to: destination)
            }
        }

        if restorePreferences {
            try restorePreferencesFile(at: root.appendingPathComponent(lcBackupPreferencesFileName))
        }

        progressFraction = 1.0
    }

    private func restorePreferencesFile(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard let snapshot = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else { return }

        let defaults = LCUtils.appGroupUserDefault
        for (key, value) in snapshot where Self.preferenceKeysToBackUp.contains(key) {
            defaults.set(value, forKey: key)
        }
    }

    // MARK: - Deletion and retention

    func deleteBackup(_ backup: LCBackupFile) {
        try? FileManager.default.removeItem(at: backup.url)
        refreshBackupList()
    }

    /// Keeps the newest `retentionCount` archives and deletes the rest.
    func pruneOldBackups() {
        let keep = retentionCount
        guard backups.count > keep else { return }
        for backup in backups.dropFirst(keep) {
            try? FileManager.default.removeItem(at: backup.url)
        }
        refreshBackupList()
    }

    // MARK: - Auto-backup

    /// Runs an automatic backup if one is due. Safe to call on every launch.
    func runAutoBackupIfDue(apps: [LCAppModel], tweakFolderNames: [String]) async {
        guard autoBackupEnabled, !isBusy else { return }

        let interval = TimeInterval(autoBackupIntervalDays) * 24 * 60 * 60
        if let last = lastAutoBackupDate, Date().timeIntervalSince(last) < interval {
            return
        }

        do {
            try await createBackup(apps: apps,
                                   scope: autoBackupScope,
                                   name: "Auto-\(Self.defaultBackupName())",
                                   tweakFolderNames: tweakFolderNames)
            lastAutoBackupDate = Date()
        } catch {
            // An auto-backup that fails must never block launch; the manual screen
            // surfaces the same error with full context when the user next opens it.
            NSLog("[LC] automatic backup failed: %@", error.localizedDescription)
        }
    }
}
