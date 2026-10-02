import Foundation
import Dispatch

var checks = 0
@MainActor
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

// The scanner is the production Foundation code, including extension filtering,
// metadata reads and ordering. Fixture files never contain app or signing data.
try Data([9]).write(to: root.appendingPathComponent("ignored.txt"))
try Data([9]).write(to: root.appendingPathComponent(".hidden.lcbackup"))
if case .files(let files) = LCBackupListing.scan(at: root) {
    let fixtureDescription = "count=\(files.count), names=\(files.map { $0.url.lastPathComponent }.joined(separator: ", "))"
    expect(files.count == 1,
           "The metadata snapshot includes exactly one visible backup file; \(fixtureDescription)")
    if let listedURL = files.first?.url, listedURL != archive {
        print("Fixture URL representation differs: actual=\(listedURL.absoluteString), baseURL=\(listedURL.baseURL?.absoluteString ?? "<nil>"); expected=\(archive.absoluteString), baseURL=\(archive.baseURL?.absoluteString ?? "<nil>")")
    }
    let listedPath = files.first?.url.resolvingSymlinksInPath().standardizedFileURL.path
    let expectedPath = archive.resolvingSymlinksInPath().standardizedFileURL.path
    expect(listedPath == expectedPath,
           "The metadata snapshot identifies the actual fixture archive; \(fixtureDescription), actualPath=\(listedPath ?? "<nil>"), expectedPath=\(expectedPath)")
    expect(files.first?.byteSize == 3, "The snapshot carries the actual archive size")
} else { preconditionFailure("The metadata snapshot should be readable") }
if case .files(let files) = LCBackupListing.scan(at: root.appendingPathComponent("missing")) {
    expect(files.isEmpty, "The snapshot preserves genuinely missing-folder semantics")
} else { preconditionFailure("A missing snapshot directory should be empty") }
if case .unavailable(let error) = LCBackupListing.scan(at: archive) {
    expect(!error.isEmpty, "The snapshot preserves failed-read semantics")
} else { preconditionFailure("An invalid snapshot directory should be unavailable") }

/// Blocks one real worker invocation so requests can complete in a deterministic order.
/// The locks protect the only shared test state; waits have deadlines and never run on main.
final class ControlledBackupScan: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observedOffMain = false
    let snapshot: LCBackupListing.Snapshot

    init(_ snapshot: LCBackupListing.Snapshot) { self.snapshot = snapshot }

    func run() -> LCBackupListing.Snapshot {
        lock.lock()
        observedOffMain = !Thread.isMainThread
        lock.unlock()
        started.signal()
        precondition(released.wait(timeout: .now() + 5) == .success,
                     "The controlled worker must be released within the test deadline")
        return snapshot
    }

    func waitUntilStarted() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.started.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func release() { released.signal() }

    var ranOffMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedOffMain
    }
}

@MainActor
final class BackupRefreshProbe {
    var files: [LCBackupListing.File]
    var error: String?
    var applied: [LCBackupListing.Snapshot] = []

    init(files: [LCBackupListing.File] = []) { self.files = files }

    func apply(_ snapshot: LCBackupListing.Snapshot) {
        applied.append(snapshot)
        switch snapshot {
        case .files(let files): self.files = files; error = nil
        case .unavailable(let message): error = message
        }
    }
}

@MainActor
final class BackupRefreshSignal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?
    func signal() { fired = true; continuation?.resume(); continuation = nil }
    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
func runBackupRefreshChecks(at root: URL) async -> [(Bool, String)] {
    var results: [(Bool, String)] = []
    func check(_ condition: Bool, _ message: String) { results.append((condition, message)) }
    let oldFiles = [LCBackupListing.File(url: root.appendingPathComponent("old.lcbackup"), byteSize: 7, createdAt: now)]
    let newFiles = [LCBackupListing.File(url: root.appendingPathComponent("new.lcbackup"), byteSize: 11, createdAt: now.addingTimeInterval(1))]

    let diskProbe = BackupRefreshProbe()
    let diskRefresh = LCBackupListRefresher(scanner: { directory in
        precondition(!Thread.isMainThread, "The production metadata scanner must run off main")
        return LCBackupListing.scan(at: directory)
    })
    let diskTask = diskRefresh.refresh(at: root, apply: diskProbe.apply)
    await diskTask.value
    check(diskProbe.files.count == 1 && diskProbe.files.first?.byteSize == 3,
          "Background scanning returns actual metadata without hidden or unrelated entries")

    // Both old successes and old errors must lose to a newer result. A newer error
    // must retain the last known files rather than let an old success replace it.
    let overlappingCases: [(LCBackupListing.Snapshot, LCBackupListing.Snapshot)] = [
        (LCBackupListing.Snapshot.files(oldFiles), .files(newFiles)),
        (.unavailable("obsolete read failure"), .files(newFiles)),
        (.files(oldFiles), .unavailable("current read failure"))
    ]
    for (older, newer) in overlappingCases {
        let oldScan = ControlledBackupScan(older), newScan = ControlledBackupScan(newer)
        let probe = BackupRefreshProbe(files: newFiles)
        let refresher = LCBackupListRefresher(scanner: { url in
            url.lastPathComponent == "older" ? oldScan.run() : newScan.run()
        })
        let oldTask = refresher.refresh(at: root.appendingPathComponent("older"), apply: probe.apply)
        let olderStarted = await oldScan.waitUntilStarted()
        precondition(olderStarted, "The older worker must start")
        let newTask = refresher.refresh(at: root.appendingPathComponent("newer"), apply: probe.apply)
        let newerStarted = await newScan.waitUntilStarted()
        precondition(newerStarted, "The newer worker must start")
        newScan.release()
        await newTask.value
        oldScan.release()
        await oldTask.value
        check(oldScan.ranOffMain && newScan.ranOffMain, "Overlapping scans run off the main thread")
        check(probe.applied == [newer], "Only the latest request may apply, even when an older scan finishes last")
        check(probe.files == newFiles, "A current read error preserves the last known list without a stale restore")
        if case .unavailable(let message) = newer {
            check(probe.error == message, "The current error remains visible after an obsolete success")
        } else {
            check(probe.error == nil, "An obsolete error cannot replace current success")
        }
    }

    // Cancellation discards a pending result, but its eventual completion must
    // neither clear nor cancel the replacement request.
    let cancelledScan = ControlledBackupScan(.files(oldFiles))
    let replacementScan = ControlledBackupScan(.files(newFiles))
    let probe = BackupRefreshProbe(files: oldFiles)
    let refresher = LCBackupListRefresher(scanner: { url in
        url.lastPathComponent == "cancelled" ? cancelledScan.run() : replacementScan.run()
    })
    let cancelledTask = refresher.refresh(at: root.appendingPathComponent("cancelled"), apply: probe.apply)
    let cancelledStarted = await cancelledScan.waitUntilStarted()
    precondition(cancelledStarted, "The cancellable worker must start")
    refresher.cancel()
    let replacementTask = refresher.refresh(at: root.appendingPathComponent("replacement"), apply: probe.apply)
    let replacementStarted = await replacementScan.waitUntilStarted()
    precondition(replacementStarted, "The replacement worker must start")
    let settlingStarted = BackupRefreshSignal()
    let settlingTask = Task { @MainActor in
        settlingStarted.signal()
        await refresher.waitUntilSettled()
        return probe.files
    }
    await settlingStarted.wait()
    cancelledScan.release()
    await cancelledTask.value
    check(probe.applied.isEmpty && probe.files == oldFiles, "Cancellation cannot publish a delayed snapshot")
    replacementScan.release()
    await replacementTask.value
    check(probe.files == newFiles && probe.applied == [.files(newFiles)],
          "Finishing a cancelled worker cannot lose the replacement update")
    let settledFiles = await settlingTask.value
    check(settledFiles == newFiles, "Awaiting inventory settlement waits for the replacement scan")

    // Enter the wait on the first request before replacing it. Completing that
    // obsolete request must advance the wait to the blocked replacement, not return.
    let waitingScan = ControlledBackupScan(.files(oldFiles))
    let newerScan = ControlledBackupScan(.files(newFiles))
    let waitingProbe = BackupRefreshProbe(files: oldFiles)
    let waitingRefresh = LCBackupListRefresher(scanner: { url in
        url.lastPathComponent == "waiting" ? waitingScan.run() : newerScan.run()
    })
    let waitingRequest = waitingRefresh.refresh(at: root.appendingPathComponent("waiting"),
                                                apply: waitingProbe.apply)
    let waitingStarted = await waitingScan.waitUntilStarted()
    precondition(waitingStarted, "The first worker must start before awaiting settlement")
    let firstWaitEntered = BackupRefreshSignal(), replacementWaitEntered = BackupRefreshSignal()
    var waitCount = 0
    var waiterFinished = false
    let alreadyWaitingTask = Task { @MainActor in
        await waitingRefresh.waitUntilSettled(onWait: {
            waitCount += 1
            if waitCount == 1 { firstWaitEntered.signal() }
            else { replacementWaitEntered.signal() }
        })
        waiterFinished = true
        return waitingProbe.files
    }
    await firstWaitEntered.wait()
    let newerRequest = waitingRefresh.refresh(at: root.appendingPathComponent("newer"),
                                              apply: waitingProbe.apply)
    let newerStarted = await newerScan.waitUntilStarted()
    precondition(newerStarted, "The replacement worker must start while settlement is waiting")
    waitingScan.release()
    await waitingRequest.value
    await replacementWaitEntered.wait()
    check(waitCount == 2 && !waiterFinished && waitingProbe.applied.isEmpty,
          "An existing waiter follows replacement without returning after the obsolete scan")
    newerScan.release()
    await newerRequest.value
    let alreadySettledFiles = await alreadyWaitingTask.value
    check(waiterFinished && alreadySettledFiles == newFiles && waitingProbe.applied == [.files(newFiles)],
          "The existing waiter returns only after the latest replacement applies")

    // A subsequent scan of a genuinely missing directory may empty the list.
    // Clearing a read error is allowed only when that current scan succeeds.
    let recovered = LCBackupListRefresher()
    probe.error = "previous read failure"
    let recoveryTask = recovered.refresh(at: root.appendingPathComponent("missing"), apply: probe.apply)
    await recoveryTask.value
    check(probe.files.isEmpty && probe.error == nil, "A current missing-folder scan clears an old error and list")

    // Requests cancelled before their task starts should not perform obsolete I/O.
    let immediate = LCBackupListRefresher(scanner: { url in
        precondition(url.lastPathComponent == "latest", "Cancelled queued scans must not invoke the reader")
        return .files(newFiles)
    })
    let first = immediate.refresh(at: root.appendingPathComponent("first"), apply: probe.apply)
    let second = immediate.refresh(at: root.appendingPathComponent("second"), apply: probe.apply)
    let latest = immediate.refresh(at: root.appendingPathComponent("latest"), apply: probe.apply)
    await latest.value
    await first.value
    await second.value
    check(probe.files == newFiles && probe.applied.last == .files(newFiles),
          "Back-to-back refreshes keep the newest request without obsolete I/O")
    return results
}

for (passed, message) in await runBackupRefreshChecks(at: root) { expect(passed, message) }
print("Passed \(checks) native readiness, filesystem and asynchronous refresh checks")
