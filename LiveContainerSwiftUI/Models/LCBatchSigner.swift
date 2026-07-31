//
//  LCBatchSigner.swift
//  LiveContainerSwiftUI
//
//  Re-signs every installed app in one pass.
//
//  A certificate's validity window cannot be extended -- it is signed by Apple's CA and
//  verified by iOS at launch. What *can* be removed is the cost of a renewal: by default
//  each app re-signs lazily the first time it is launched, so the day after a refresh every
//  app stalls once, with no explanation. Doing the whole set up front, with progress, turns
//  a week of small surprises into one visible operation.
//

import Foundation
import Combine

@MainActor
final class LCBatchSigner: ObservableObject {

    static let shared = LCBatchSigner()

    @Published private(set) var isRunning = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var currentAppName: String = ""
    /// Display name -> error, for apps that could not be signed.
    @Published private(set) var failures: [(name: String, reason: String)] = []

    private init() {}

    var progressFraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    /// Force-re-signs every app supplied.
    ///
    /// Signing is sequential on purpose: ZSign is CPU- and IO-heavy, and running several at
    /// once on a phone starves the UI without finishing sooner.
    func resignAll(apps: [LCAppModel]) async {
        guard !isRunning, !apps.isEmpty else { return }

        isRunning = true
        completed = 0
        total = apps.count
        failures = []
        defer {
            isRunning = false
            currentAppName = ""
        }

        for app in apps {
            currentAppName = app.displayName
            do {
                try await app.forceResign()
            } catch {
                // One bad app must not abort the batch -- the rest still need signing.
                failures.append((name: app.displayName, reason: error.localizedDescription))
            }
            completed += 1
        }

        // Only a fully clean pass clears the pending flag; otherwise the prompt stays so
        // the user can retry the ones that failed.
        if failures.isEmpty {
            LCCertificateMonitor.shared.clearPendingBatchResign()
        }
    }
}
