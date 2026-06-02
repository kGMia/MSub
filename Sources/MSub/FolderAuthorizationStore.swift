import AppKit
import Foundation
import Observation

/// Manages security-scoped bookmarks the user has granted MSub.
///
/// Two flavours of bookmarks are stored under separate keys:
/// - **file bookmarks** keyed by `URL.path` — captured when the user picks a
///   media file via NSOpenPanel; survives app relaunches.
/// - **folder bookmarks** keyed by absolute folder path — captured when the
///   user explicitly authorizes a directory (e.g. to allow sidecar subtitle
///   auto-detection). Reused across launches; a single bookmark grants access
///   to every file inside that folder.
@MainActor
@Observable
final class FolderAuthorizationStore {
    static let shared = FolderAuthorizationStore()

    private let fileBookmarksKey = "msub.fileBookmarks.v1"
    private let folderBookmarksKey = "msub.folderBookmarks.v1"
    private let declinedFoldersKey = "msub.declinedFolderPrompts.v1"

    private var fileBookmarks: [String: Data] = [:]
    private var folderBookmarks: [String: Data] = [:]
    private var activeFolderURLs: [String: URL] = [:]
    private var declinedFolders: Set<String> = []

    private init() {
        fileBookmarks = loadDictionary(forKey: fileBookmarksKey)
        folderBookmarks = loadDictionary(forKey: folderBookmarksKey)
        declinedFolders = Set(UserDefaults.standard.stringArray(forKey: declinedFoldersKey) ?? [])
        resumeFolderAccesses()
    }

    // MARK: - Declined prompts

    func wasDeclined(folderPath: String) -> Bool {
        declinedFolders.contains(folderPath)
    }

    func recordDecline(folderPath: String) {
        declinedFolders.insert(folderPath)
        UserDefaults.standard.set(Array(declinedFolders), forKey: declinedFoldersKey)
    }

    func clearDecline(folderPath: String) {
        declinedFolders.remove(folderPath)
        UserDefaults.standard.set(Array(declinedFolders), forKey: declinedFoldersKey)
    }

    // MARK: - File bookmarks

    func storeFileBookmark(for url: URL) {
        let data: Data
        do {
            data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            AppLog.bookmarks.error("storeFileBookmark failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        fileBookmarks[url.standardizedFileURL.path] = data
        save(dictionary: fileBookmarks, forKey: fileBookmarksKey)
    }

    /// Resolves the stored bookmark (if any) for `path`. The returned URL has
    /// `startAccessingSecurityScopedResource()` already called; the caller MUST
    /// call `stopAccessingSecurityScopedResource()` once finished.
    func resolveFileForAccess(path: String) -> URL? {
        guard let data = fileBookmarks[path] else { return nil }
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            AppLog.bookmarks.error("resolveFileForAccess failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        if isStale {
            fileBookmarks.removeValue(forKey: path)
            save(dictionary: fileBookmarks, forKey: fileBookmarksKey)
            return nil
        }
        return url.startAccessingSecurityScopedResource() ? url : nil
    }

    func removeFileBookmark(path: String) {
        fileBookmarks.removeValue(forKey: path)
        save(dictionary: fileBookmarks, forKey: fileBookmarksKey)
    }

    // MARK: - Folder bookmarks

    func authorizeFolder(_ folderURL: URL) {
        let data: Data
        do {
            data = try folderURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            AppLog.bookmarks.error("authorizeFolder failed for \(folderURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let path = folderURL.standardizedFileURL.path
        folderBookmarks[path] = data
        save(dictionary: folderBookmarks, forKey: folderBookmarksKey)
        if activeFolderURLs[path] == nil, folderURL.startAccessingSecurityScopedResource() {
            activeFolderURLs[path] = folderURL
        }
    }

    func isFolderAuthorized(_ folderURL: URL) -> Bool {
        let path = folderURL.standardizedFileURL.path
        return folderBookmarks[path] != nil || enclosingAuthorizedPath(for: path) != nil
    }

    /// Returns the resolved folder URL that grants access for `fileURL`'s
    /// directory, or any ancestor that the user has authorized. Returns nil if
    /// nothing is authorized.
    func authorizedAncestor(for fileURL: URL) -> URL? {
        let folderPath = fileURL.deletingLastPathComponent().standardizedFileURL.path
        if let exact = activeFolderURLs[folderPath] { return exact }
        guard let ancestorPath = enclosingAuthorizedPath(for: folderPath) else { return nil }
        return activeFolderURLs[ancestorPath]
    }

    /// Prompts the user (modally) to authorize the parent directory of `url`.
    /// Returns `true` if the user granted access.
    func promptForFolderAuthorization(initialURL: URL?, message: String, prompt: String) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        if let initialURL {
            panel.directoryURL = initialURL.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let folderURL = panel.url else { return false }
        authorizeFolder(folderURL)
        return true
    }

    // MARK: - Internals

    private func loadDictionary(forKey key: String) -> [String: Data] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        var result: [String: Data] = [:]
        for (path, value) in raw {
            if let data = value as? Data {
                result[path] = data
            }
        }
        return result
    }

    private func save(dictionary: [String: Data], forKey key: String) {
        UserDefaults.standard.set(dictionary, forKey: key)
    }

    private func resumeFolderAccesses() {
        for (path, data) in folderBookmarks {
            var isStale = false
            let url: URL
            do {
                url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                AppLog.bookmarks.error("resumeFolderAccesses failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            if isStale {
                folderBookmarks.removeValue(forKey: path)
                continue
            }
            if url.startAccessingSecurityScopedResource() {
                activeFolderURLs[path] = url
            }
        }
        save(dictionary: folderBookmarks, forKey: folderBookmarksKey)
    }

    private func enclosingAuthorizedPath(for path: String) -> String? {
        let target = (path as NSString).standardizingPath
        for candidate in activeFolderURLs.keys {
            let candidateStd = (candidate as NSString).standardizingPath
            if target == candidateStd { return candidate }
            if target.hasPrefix(candidateStd + "/") { return candidate }
        }
        return nil
    }
}
