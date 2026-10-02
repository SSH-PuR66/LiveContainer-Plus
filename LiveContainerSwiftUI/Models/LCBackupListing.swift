import Foundation
import Dispatch

/// Missing folders are empty; other failures are unknown, not zero backups.
enum LCBackupListing: Sendable {
    case files([URL])
    case unavailable(String)

    struct File: Sendable, Equatable {
        let url: URL
        let byteSize: Int64
        let createdAt: Date
    }

    enum Snapshot: Sendable, Equatable {
        case files([File])
        case unavailable(String)
    }

    nonisolated static func read(at directory: URL, fileManager: FileManager = .default) -> Self {
        do {
            return .files(try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles]))
        } catch {
            let fileError = error as NSError
            if fileError.domain == NSCocoaErrorDomain && fileError.code == NSFileReadNoSuchFileError {
                return .files([])
            }
            return .unavailable(error.localizedDescription)
        }
    }

    /// Enumeration, metadata reads and sorting all run on the scanner's worker queue.
    nonisolated static func scan(at directory: URL, fileExtension: String = "lcbackup") -> Snapshot {
        switch read(at: directory, fileManager: FileManager()) {
        case .unavailable(let error):
            return .unavailable(error)
        case .files(let urls):
            let files = urls.filter { $0.pathExtension == fileExtension }.map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                return File(url: url,
                            byteSize: Int64(values?.fileSize ?? 0),
                            createdAt: values?.creationDate ?? .distantPast)
            }
            return .files(files.sorted { $0.createdAt > $1.createdAt })
        }
    }
}

/// Keeps blocking filesystem work off the main actor and applies only the latest request.
/// Cancellation cannot stop an in-flight filesystem call; its result is discarded instead.
@MainActor
final class LCBackupListRefresher {
    typealias Scanner = @Sendable (URL) -> LCBackupListing.Snapshot

    private let scanner: Scanner
    private var currentRequest: UUID?
    private var currentTask: Task<Void, Never>?

    init(scanner: @escaping Scanner = { LCBackupListing.scan(at: $0) }) {
        self.scanner = scanner
    }

    @discardableResult
    func refresh(at directory: URL,
                 apply: @escaping @MainActor (LCBackupListing.Snapshot) -> Void) -> Task<Void, Never> {
        let request = UUID()
        currentTask?.cancel()
        currentRequest = request
        let scanner = self.scanner

        let task = Task { @MainActor [weak self] in
            defer {
                if let self, self.currentRequest == request {
                    self.currentRequest = nil
                    self.currentTask = nil
                }
            }
            guard !Task.isCancelled else { return }
            let snapshot = await Self.scanOffMain(at: directory, scanner: scanner)
            guard !Task.isCancelled, let self, self.currentRequest == request else { return }
            apply(snapshot)
        }
        currentTask = task
        return task
    }

    func cancel() {
        currentRequest = nil
        currentTask?.cancel()
        currentTask = nil
    }

    /// Internal backup creation/retention needs the current snapshot before using its list.
    /// A replaced request is not settled until its latest replacement has also completed.
    func waitUntilSettled(onWait: (@MainActor () -> Void)? = nil) async {
        while let task = currentTask {
            // The optional observer lets tests confirm each suspension without timing sleeps.
            onWait?()
            await task.value
        }
    }

    nonisolated private static func scanOffMain(at directory: URL,
                                               scanner: @escaping Scanner) async -> LCBackupListing.Snapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanner(directory))
            }
        }
    }
}
