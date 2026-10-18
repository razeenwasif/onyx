import Foundation

/// The notebook folder: the same "Scribe Notebooks" folder the Mac uses,
/// chosen once from iCloud Drive in the Files picker and remembered as a
/// security-scoped bookmark. Reading a folder the user picked needs no iCloud
/// entitlement, which is what lets Scribe sync without a paid developer
/// account.
enum Library {
    static let bookmarkKey = "notebookFolderBookmark"

    /// Remembers `url` (just picked) and starts reading from it. `key` keeps
    /// Scribe's folder and Electron's vault apart.
    static func choose(_ url: URL, key: String = bookmarkKey) throws -> URL {
        guard url.startAccessingSecurityScopedResource() else {
            throw Core.Failure(message: "The app wasn't given access to that folder.")
        }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
        return url
    }

    /// The remembered folder, opened for reading and writing, or nil.
    static func restore(key: String = bookmarkKey) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return url
    }

    static func forget(key: String = bookmarkKey) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Asks iCloud to download every file in the folder that is only a
    /// placeholder on this device. Returns how many are still on their way.
    @discardableResult
    static func requestDownloads(in root: URL) -> Int {
        let keys: [URLResourceKey] = [.ubiquitousItemDownloadingStatusKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var pending = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true,
                  let status = values.ubiquitousItemDownloadingStatus, status != .current
            else { continue }
            pending += 1
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        return pending
    }
}
