import Foundation

/// Signing observations, not a promise that a particular guest app can launch.
enum LCCertificateHealth: Equatable {
    case notConfigured
    case checking
    case valid(daysRemaining: Int)
    case expiringSoon(daysRemaining: Int)
    case expiryUnavailable
    case expired
    case revoked
    case error(String)

    static let warningThresholdDays = 7

    var isActionable: Bool {
        switch self {
        case .expiringSoon, .expiryUnavailable, .expired, .revoked, .error:
            return true
        case .notConfigured, .checking, .valid:
            return false
        }
    }

    static func validated(expirationDate: Date?, now: Date = Date()) -> Self {
        guard let expirationDate else { return .expiryUnavailable }
        let remaining = expirationDate.timeIntervalSince(now)
        guard remaining.isFinite else { return .expiryUnavailable }
        guard remaining > 0 else { return .expired }
        let rawDays = remaining / (24 * 60 * 60)
        // Double(Int.max) rounds upward on 64-bit platforms, so use a strict bound.
        guard rawDays < Double(Int.max) else { return .expiryUnavailable }
        let days = Int(rawDays)
        return days <= warningThresholdDays
            ? .expiringSoon(daysRemaining: days)
            : .valid(daysRemaining: days)
    }

    static func needsRefresh(lastChecked: Date?, now: Date = Date(),
                             interval: TimeInterval = 6 * 60 * 60) -> Bool {
        guard let lastChecked else { return true }
        let age = now.timeIntervalSince(lastChecked)
        guard age.isFinite, interval.isFinite, interval > 0 else { return true }
        // A clock change must not make a future timestamp look freshly checked.
        return age < 0 || age >= interval
    }
}
