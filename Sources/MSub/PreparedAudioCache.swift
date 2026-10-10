import Foundation

/// An owned temporary PCM file. Active operations retain this even after cache
/// eviction; only the last reference removes the file. Never wrap source media.
final class PreparedAudioLease: Sendable {
    let url: URL

    fileprivate init(ownedURL: URL) { url = ownedURL }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor
final class PreparedAudioCache {
    struct FileVersion: Hashable {
        let size: Int64
        let modified: Date
        let inode: UInt64

        init?(url: URL) {
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  values[.type] as? FileAttributeType == .typeRegular,
                  let size = values[.size] as? NSNumber,
                  let modified = values[.modificationDate] as? Date else { return nil }
            self.size = size.int64Value
            self.modified = modified
            self.inode = (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }

    struct Key: Hashable {
        let sourcePath: String
        let version: FileVersion
        let start: Double?
        let end: Double?

        init?(source: URL, start: Double?, end: Double?) {
            guard let version = FileVersion(url: source) else { return nil }
            if let start, let end {
                guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            } else if start != nil || end != nil { return nil }
            sourcePath = source.standardizedFileURL.path
            self.version = version
            self.start = start
            self.end = end
        }
    }

    private struct Entry {
        let key: Key
        let lease: PreparedAudioLease
        let version: FileVersion
    }

    private var entries: [Entry] = [] // Least recently used first; bounded to a few files.
    private let byteLimit: Int64
    private let entryLimit: Int

    init(byteLimit: Int64 = 512 * 1024 * 1024, entryLimit: Int = 8) {
        self.byteLimit = max(0, byteLimit)
        self.entryLimit = max(0, entryLimit)
    }

    func lookup(_ key: Key) -> PreparedAudioLease? {
        // A changed source invalidates all old clips, not just the requested one.
        entries.removeAll { $0.key.sourcePath == key.sourcePath && $0.key.version != key.version }
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        guard FileVersion(url: entry.lease.url) == entry.version else { return nil }
        entries.append(entry)
        return entry.lease
    }

    /// Transfers ownership even for oversized files; those live only as long as
    /// the caller's lease and are not retained by the cache.
    func insert(ownedURL: URL, for key: Key) -> PreparedAudioLease {
        precondition(ownedURL.standardizedFileURL.path != key.sourcePath)
        let lease = PreparedAudioLease(ownedURL: ownedURL)
        entries.removeAll { $0.key.sourcePath == key.sourcePath && ($0.key == key || $0.key.version != key.version) }
        guard let version = FileVersion(url: ownedURL), version.size <= byteLimit, entryLimit > 0 else { return lease }
        while !entries.isEmpty && (entries.count >= entryLimit || entries.reduce(Int64(0), { $0 + $1.version.size }) > byteLimit - version.size) {
            entries.removeFirst()
        }
        entries.append(Entry(key: key, lease: lease, version: version))
        return lease
    }

    func retainSources(_ paths: Set<String>) {
        entries.removeAll { !paths.contains($0.key.sourcePath) }
    }

    func removeAll() { entries.removeAll() }
}
