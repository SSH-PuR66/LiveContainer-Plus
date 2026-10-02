import Foundation

/// Missing folders are empty; other failures are unknown, not zero backups.
enum LCBackupListing {
    case files([URL])
    case unavailable(String)

    static func read(at directory: URL, fileManager: FileManager = .default) -> Self {
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
}
