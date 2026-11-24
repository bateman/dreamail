import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The private copies of attachments the user opened or previewed
/// (`MailStore.attachmentTempURL`), laid out as
/// `<root>/<account>/<gmail message id>/<attachment row id>/<file name>`.
///
/// Removal of an account deletes its folder (F-04). The tree sits in a
/// directory other processes of the same user can write to, so the walk
/// never follows a symbolic link: a link planted anywhere in the tree is
/// unlinked, and whatever it points at is left alone. The walk holds every
/// directory open with `O_NOFOLLOW` and removes entries relative to that
/// handle, so swapping a directory for a link mid-walk cannot redirect it
/// outside the cache either.
enum AttachmentCache {
    static let folderName = "MishMailAttachments"

    static var defaultRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Folder name for an account. Unchanged from earlier builds so a copy
    /// cached by one of them is found and removed too.
    static func accountFolderName(_ accountId: String) -> String {
        MessageParser.safeFilename(accountId)
    }

    static func messageDirectory(root: URL = defaultRoot, accountId: String,
                                 gmailMessageId: String, attachmentRowId: Int64?) -> URL {
        root.appendingPathComponent(accountFolderName(accountId), isDirectory: true)
            .appendingPathComponent(MessageParser.safeFilename(gmailMessageId), isDirectory: true)
            .appendingPathComponent(String(attachmentRowId ?? 0), isDirectory: true)
    }

    /// True when every component from `root` down to `directory` is a real
    /// directory, not a symbolic link. `directory` must lie under `root`.
    /// Writing is refused otherwise: a planted link would send the file, and
    /// later its removal, outside the cache.
    static func isContained(_ directory: URL, in root: URL) -> Bool {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = directory.standardizedFileURL.pathComponents
        guard parts.count >= rootParts.count,
              Array(parts.prefix(rootParts.count)) == rootParts,
              !parts.contains("..") else { return false }
        var current = root.standardizedFileURL
        guard isRealDirectory(current.path) else { return false }
        for part in parts.dropFirst(rootParts.count) {
            current.appendPathComponent(part, isDirectory: true)
            guard isRealDirectory(current.path) else { return false }
        }
        return true
    }

    /// Deletes everything cached for `accountId`. Returns false when the
    /// cache root itself is a link or not a directory; nothing is touched
    /// then, because the files behind it are not ours to delete.
    @discardableResult
    static func removeAccount(_ accountId: String, root: URL = defaultRoot) -> Bool {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return errno == ENOENT }
        defer { close(rootFD) }
        return removeEntry(named: accountFolderName(accountId), in: rootFD)
    }

    /// Whether a downloaded copy may still be written. A download that
    /// finishes after its account was removed must not recreate the
    /// account's folder.
    static func mayStore(accountId: String, liveAccounts: [String]) -> Bool {
        liveAccounts.contains(accountId)
    }

    /// Deletes every account folder under `root` that belongs to none of
    /// `liveAccounts`: what a removal interrupted by a quit, or a delete
    /// that failed, left behind. Never follows a link; a linked root is left
    /// alone. Returns false when anything could not be removed.
    @discardableResult
    static func removeOrphans(liveAccounts: [String], root: URL = defaultRoot) -> Bool {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return errno == ENOENT }
        defer { close(rootFD) }
        let live = Set(liveAccounts.map(accountFolderName))
        var ok = true
        for name in entries(of: rootFD) where !live.contains(name) {
            if !removeEntry(named: name, in: rootFD) { ok = false }
        }
        return ok
    }

    // MARK: - Walk

    private static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Removes `name` inside the directory `parentFD`. A link or file is
    /// unlinked; a directory is emptied through its own `O_NOFOLLOW` handle
    /// and then removed.
    private static func removeEntry(named name: String, in parentFD: Int32) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
        var info = stat()
        guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            return unlinkat(parentFD, name, 0) == 0 || errno == ENOENT
        }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        // Swapped for a link (or a file) since the stat: unlink what is
        // there now, without following it.
        guard fd >= 0 else {
            return unlinkat(parentFD, name, 0) == 0 || errno == ENOENT
        }
        var ok = true
        for child in entries(of: fd) where !removeEntry(named: child, in: fd) {
            ok = false
        }
        close(fd)
        return unlinkat(parentFD, name, AT_REMOVEDIR) == 0 && ok
    }

    /// Entry names of the directory `fd`, read through a duplicate so the
    /// caller's handle stays open for the removals.
    private static func entries(of fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { return [] }
        guard let dir = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }
}
