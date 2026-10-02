import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

let now = Date(timeIntervalSince1970: 1_791_000_000)
let day: TimeInterval = 24 * 60 * 60
expect(LCCertificateHealth.validated(expirationDate: nil, now: now) == .expiryUnavailable,
       "A missing expiry must never become a fictional valid countdown")
expect(LCCertificateHealth.validated(expirationDate: now, now: now) == .expired,
       "An expiry exactly at the check time is expired")
expect(LCCertificateHealth.validated(expirationDate: now.addingTimeInterval(-1), now: now) == .expired,
       "Past expiry is expired")
expect(LCCertificateHealth.validated(expirationDate: now.addingTimeInterval(60), now: now)
       == .expiringSoon(daysRemaining: 0), "Less than a day remains valid until its actual expiry")
expect(LCCertificateHealth.validated(expirationDate: now.addingTimeInterval(day), now: now)
       == .expiringSoon(daysRemaining: 1), "One-day warning")
expect(LCCertificateHealth.validated(expirationDate: now.addingTimeInterval(7 * day), now: now)
       == .expiringSoon(daysRemaining: 7), "Seven-day warning boundary")
expect(LCCertificateHealth.validated(expirationDate: now.addingTimeInterval(8 * day), now: now)
       == .valid(daysRemaining: 8), "Eight-day valid boundary")
expect(LCCertificateHealth.expiryUnavailable.isActionable, "Unknown expiry needs review")
expect(!LCCertificateHealth.notConfigured.isActionable, "No certificate does not rule out JIT")
expect(LCCertificateHealth.needsRefresh(lastChecked: nil, now: now), "No check is unknown")
expect(!LCCertificateHealth.needsRefresh(lastChecked: now, now: now), "A current check is fresh")
expect(!LCCertificateHealth.needsRefresh(lastChecked: now.addingTimeInterval(-21_599), now: now),
       "A check just inside six hours is fresh")
expect(LCCertificateHealth.needsRefresh(lastChecked: now.addingTimeInterval(-21_600), now: now),
       "A check at six hours needs refresh")
expect(LCCertificateHealth.needsRefresh(lastChecked: now.addingTimeInterval(1), now: now),
       "Future timestamps caused by a changed clock must refresh")

let invalidTimes: [Double] = [.infinity, -Double.infinity, .nan, .greatestFiniteMagnitude]
for timestamp in invalidTimes {
    let date = Date(timeIntervalSince1970: timestamp)
    expect(LCCertificateHealth.validated(expirationDate: date, now: now) == .expiryUnavailable,
           "Nonfinite or unrepresentable expiry must remain unknown without Int conversion")
    expect(LCCertificateHealth.needsRefresh(lastChecked: date, now: now),
           "Invalid or extreme check timestamps cannot count as fresh")
}
expect(LCCertificateHealth.validated(expirationDate: Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude), now: now)
       == .expired, "A finite past expiry is expired without attempting a days conversion")
expect(LCCertificateHealth.needsRefresh(lastChecked: now, now: Date(timeIntervalSince1970: .nan)),
       "An invalid current clock cannot claim freshness")
expect(LCCertificateHealth.needsRefresh(lastChecked: now, now: now, interval: .nan),
       "An invalid freshness interval must refresh")

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("LCReadinessTests-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

if case .files(let files) = LCBackupListing.read(at: root.appendingPathComponent("missing")) {
    expect(files.isEmpty, "A folder never created is genuinely empty")
} else { preconditionFailure("A missing backup folder should be empty") }

if case .files(let files) = LCBackupListing.read(at: root) {
    expect(files.isEmpty, "An existing empty directory is genuinely empty")
} else { preconditionFailure("An empty directory should be readable") }

let archive = root.appendingPathComponent("example.lcbackup")
try Data([1, 2, 3]).write(to: archive)
try Data([4]).write(to: root.appendingPathComponent(".hidden"))
if case .files(let files) = LCBackupListing.read(at: root) {
    expect(files.count == 1 && files.first?.lastPathComponent == "example.lcbackup",
           "Actual files are listed and hidden entries stay hidden")
} else { preconditionFailure("A populated directory should be readable") }

if case .unavailable(let error) = LCBackupListing.read(at: archive) {
    expect(!error.isEmpty, "A file used as a directory is a failed read, never zero backups")
} else { preconditionFailure("An invalid directory must be unavailable") }

print("Passed \(checks) native readiness and filesystem checks")
