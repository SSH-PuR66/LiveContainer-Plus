//
//  LCCertificateMonitor.swift
//  LiveContainerSwiftUI
//
//  Proactive signing-certificate health tracking.
//
//  Every certificate-based sideloading route fails the same way: the certificate expires or
//  is revoked, apps stop launching, and the user has no idea why. LiveContainer already knows
//  how to answer the question via LCUtils.validateCertificate — this makes it ask on a
//  schedule and warn before the failure instead of after.
//

import Foundation
import Combine
import UserNotifications

@MainActor
class LCCertificateMonitor: ObservableObject {

    static let shared = LCCertificateMonitor()

    /// Thresholds, in days remaining, at which a notification fires. One per threshold per
    /// certificate — tracked by `notifiedThresholdsKey` so a warning isn't repeated on
    /// every launch.
    private static let notificationThresholds = [7, 3, 1]

    private static let lastCheckKey = "LCCertLastHealthCheck"
    private static let notifiedThresholdsKey = "LCCertNotifiedThresholds"
    private static let trackedExpiryKey = "LCCertTrackedExpiry"
    private static let pendingBatchResignKey = "LCCertPendingBatchResign"

    @Published private(set) var health: LCCertificateHealth = .checking
    @Published private(set) var expirationDate: Date?
    @Published private(set) var organizationalUnit: String?
    @Published private(set) var lastChecked: Date?

    /// Set once the user dismisses the app-list banner for the current state; cleared
    /// whenever the health changes so a new problem always resurfaces.
    @Published var bannerDismissed = false

    /// True when the certificate was replaced with a different one and the installed apps
    /// are still signed by the old identity.
    ///
    /// Persisted: the renewal is detected on one launch but the user may not act until a
    /// later one, and until they do every app is still carrying a stale signature.
    @Published private(set) var pendingBatchResign = false

    private var isChecking = false

    private init() {
        lastChecked = LCUtils.appGroupUserDefault.object(forKey: Self.lastCheckKey) as? Date
        pendingBatchResign = LCUtils.appGroupUserDefault.bool(forKey: Self.pendingBatchResignKey)
    }

    func clearPendingBatchResign() {
        pendingBatchResign = false
        LCUtils.appGroupUserDefault.set(false, forKey: Self.pendingBatchResignKey)
    }

    var daysRemaining: Int? {
        guard let expirationDate else { return nil }
        switch LCCertificateHealth.validated(expirationDate: expirationDate) {
        case .valid(let days), .expiringSoon(let days): return days
        case .expired: return 0
        default: return nil
        }
    }

    // MARK: - Checking

    /// Re-validates unless a recent, non-actionable result is already in memory.
    ///
    /// `health` lives only for the lifetime of the process, so a fresh timestamp alone is
    /// not enough to skip: the UI reads the in-memory value, which starts at `.checking`.
    func refreshIfStale() async {
        if case .checking = health {
            await refresh()
            return
        }
        if health.isActionable {
            await refresh()
            return
        }
        if LCCertificateHealth.needsRefresh(lastChecked: lastChecked) {
            await refresh()
        }
    }

    func refresh() async {
        guard !isChecking else { return }

        guard LCUtils.certificateData() != nil, LCSharedUtils.certificatePassword() != nil else {
            health = .notConfigured
            expirationDate = nil
            organizationalUnit = nil
            lastChecked = nil
            return
        }

        isChecking = true
        defer { isChecking = false }

        // Captured before the transient `.checking` state overwrites it, so the
        // banner-dismissal reset below compares against the last *settled* health.
        let previousHealth = health
        health = .checking

        let result: (status: Int, date: Date?, ou: String?, error: String?) =
            await withCheckedContinuation { continuation in
                var resumed = false
                LCUtils.validateCertificate { status, date, ou, error in
                    // The underlying ZSigner callback is not contractually single-shot;
                    // resuming a continuation twice is a hard crash, so guard it.
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: (Int(status), date, ou, error))
                }
            }

        lastChecked = Date()
        LCUtils.appGroupUserDefault.set(lastChecked, forKey: Self.lastCheckKey)

        if let error = result.error {
            health = .error(error.loc)
            if !sameCase(previousHealth, health) {
                bannerDismissed = false
            }
            return
        }

        expirationDate = result.date
        organizationalUnit = result.ou

        // A changed expiry means a different certificate — reset the notification ledger so
        // the new one gets its own warnings.
        if let date = result.date {
            let tracked = LCUtils.appGroupUserDefault.object(forKey: Self.trackedExpiryKey) as? Date
            if tracked != date {
                LCUtils.appGroupUserDefault.set(date, forKey: Self.trackedExpiryKey)
                LCUtils.appGroupUserDefault.set([Int](), forKey: Self.notifiedThresholdsKey)
                bannerDismissed = false

                // `tracked == nil` is a first run or a fresh install: the apps were signed
                // by whatever identity is current, so there is nothing stale to re-sign.
                // A *changed* expiry means the identity was replaced under them.
                if tracked != nil {
                    pendingBatchResign = true
                    LCUtils.appGroupUserDefault.set(true, forKey: Self.pendingBatchResignKey)
                }
            }
        }

        switch result.status {
        case 0:
            health = LCCertificateHealth.validated(expirationDate: result.date)
        case 1:
            health = .revoked
        default:
            health = .error("lc.common.unknown".loc)
        }

        if !sameCase(previousHealth, health) {
            bannerDismissed = false
        }

        await postNotificationIfNeeded()
    }

    private func sameCase(_ lhs: LCCertificateHealth, _ rhs: LCCertificateHealth) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured), (.checking, .checking),
             (.expiryUnavailable, .expiryUnavailable),
             (.expired, .expired), (.revoked, .revoked):
            return true
        case (.valid(let a), .valid(let b)), (.expiringSoon(let a), .expiringSoon(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }

    // MARK: - Notifications

    /// Fires at most one notification per threshold per certificate.
    private func postNotificationIfNeeded() async {
        let title: String
        let body: String
        let thresholdKey: Int

        switch health {
        case .revoked:
            title = "lc.cert.notify.revoked.title".loc
            body = "lc.cert.notify.revoked.body".loc
            // Revocation is a single event, not a countdown; -1 keeps it out of the day buckets.
            thresholdKey = -1
        case .expired:
            title = "lc.cert.notify.expired.title".loc
            body = "lc.cert.notify.expired.body".loc
            thresholdKey = 0
        case .expiringSoon(let days):
            guard let threshold = Self.notificationThresholds.first(where: { days <= $0 }) else { return }
            title = "lc.cert.notify.expiring.title".loc
            body = "lc.cert.notify.expiring.body %lld".localizeWithFormat(days)
            thresholdKey = threshold
        default:
            return
        }

        var notified = LCUtils.appGroupUserDefault.array(forKey: Self.notifiedThresholdsKey) as? [Int] ?? []
        guard !notified.contains(thresholdKey) else { return }

        let center = UNUserNotificationCenter.current()
        // Provisional authorization delivers quietly to Notification Center without an
        // permission prompt — appropriate for a warning the user never asked for.
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .provisional])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: "lc.cert.health.\(thresholdKey)",
                                            content: content,
                                            trigger: nil)
        try? await center.add(request)

        notified.append(thresholdKey)
        LCUtils.appGroupUserDefault.set(notified, forKey: Self.notifiedThresholdsKey)
    }
}
