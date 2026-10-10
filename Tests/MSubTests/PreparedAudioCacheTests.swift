import Foundation
import XCTest
@testable import MSub

@MainActor
final class PreparedAudioCacheTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ root: URL, _ name: String, count: Int = 4) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 1, count: count).write(to: url)
        return url
    }

    func testMediaAndClipKeysAndMissingPCM() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source.mov")
        let pcm = try write(root, "pcm.wav")
        let cache = PreparedAudioCache()
        let key = try XCTUnwrap(PreparedAudioCache.Key(source: source, start: 1, end: 3))
        _ = cache.insert(ownedURL: pcm, for: key)
        XCTAssertEqual(cache.lookup(key)?.url, pcm)
        let otherClip = try XCTUnwrap(PreparedAudioCache.Key(source: source, start: 2, end: 3))
        XCTAssertNil(cache.lookup(otherClip))
        try Data(repeating: 2, count: 8).write(to: source)
        let changed = try XCTUnwrap(PreparedAudioCache.Key(source: source, start: 1, end: 3))
        XCTAssertNotEqual(changed, key)
        XCTAssertNil(cache.lookup(changed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pcm.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let replacement = try write(root, "new.wav")
        _ = cache.insert(ownedURL: replacement, for: changed)
        try FileManager.default.removeItem(at: replacement)
        XCTAssertNil(cache.lookup(changed))
    }

    func testLRUEvictionKeepsActiveLeaseAlive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try write(root, "source.mov")
        let key = try XCTUnwrap(PreparedAudioCache.Key(source: source, start: nil, end: nil))
        let clip = try XCTUnwrap(PreparedAudioCache.Key(source: source, start: 1, end: 2))
        let pcmA = try write(root, "a.wav")
        let pcmB = try write(root, "b.wav")
        let cache = PreparedAudioCache(entryLimit: 1)
        var active: PreparedAudioLease? = cache.insert(ownedURL: pcmA, for: key)
        _ = cache.insert(ownedURL: pcmB, for: clip)
        XCTAssertNil(cache.lookup(key))
        cache.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pcmB.path))
        XCTAssertEqual(active?.url, pcmA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pcmA.path))
        active = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: pcmA.path))
    }

    func testByteBudgetAndSourceRemoval() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreparedAudioCache(byteLimit: 8)
        var keys: [PreparedAudioCache.Key] = []
        var pcm: [URL] = []
        for index in 0..<3 {
            let source = try write(root, "source\(index).mov")
            keys.append(try XCTUnwrap(PreparedAudioCache.Key(source: source, start: nil, end: nil)))
            pcm.append(try write(root, "pcm\(index).wav"))
        }
        _ = cache.insert(ownedURL: pcm[0], for: keys[0])
        _ = cache.insert(ownedURL: pcm[1], for: keys[1])
        XCTAssertNotNil(cache.lookup(keys[0])) // Make first entry most recent.
        _ = cache.insert(ownedURL: pcm[2], for: keys[2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: pcm[1].path))
        XCTAssertNotNil(cache.lookup(keys[0]))
        cache.retainSources([keys[2].sourcePath])
        XCTAssertFalse(FileManager.default.fileExists(atPath: pcm[0].path))
        XCTAssertNotNil(cache.lookup(keys[2]))
        let large = try write(root, "large.wav", count: 9)
        var active: PreparedAudioLease? = cache.insert(ownedURL: large, for: keys[0])
        XCTAssertNil(cache.lookup(keys[0]))
        XCTAssertEqual(active?.url, large)
        active = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: large.path))
    }
}
