import Foundation
import XCTest
@testable import MSub

final class NativeMLXLibrarySearchTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testMissingDirectoriesAndDuplicatePathsDoNotReachMetal() throws {
        try withDirectory { root in
            let library = root.appending(path: "mlx.metallib")
            try Data([1]).write(to: library)
            var loaded: [URL] = []
            let result = NativeMLXLibrarySearch.find(preferred: nil, candidates: {
                [root.appending(path: "missing"), root, library,
                 root.appending(path: "./mlx.metallib"), library]
            }, load: { loaded.append($0); return false })
            XCTAssertNil(result)
            XCTAssertEqual(loaded, [library])
        }
    }

    func testPreferredLibraryIsRevalidatedWithoutEnumeratingBundles() throws {
        try withDirectory { root in
            let library = root.appending(path: "mlx.metallib")
            try Data([1]).write(to: library)
            var scans = 0, loads = 0
            for _ in 0..<3 {
                let result = NativeMLXLibrarySearch.find(preferred: library, candidates: {
                    scans += 1; return []
                }, load: { _ in loads += 1; return true })
                XCTAssertEqual(result, library)
            }
            XCTAssertEqual(scans, 0)
            XCTAssertEqual(loads, 3)
        }
    }

    func testCorruptPreferredLibraryFallsBackAndFailureIsNotCached() throws {
        try withDirectory { root in
            let primary = root.appending(path: "primary.metallib")
            let backup = root.appending(path: "backup.metallib")
            try Data([0]).write(to: primary)
            try Data([1]).write(to: backup)
            var loaded: [URL] = []
            let load: (URL) -> Bool = { url in
                loaded.append(url)
                return (try? Data(contentsOf: url)) == Data([1])
            }
            XCTAssertEqual(NativeMLXLibrarySearch.find(preferred: primary,
                candidates: { [primary, backup] }, load: load), backup)
            XCTAssertEqual(loaded, [primary, backup])
            // Same path and size; validity comes from opening it, not metadata.
            try Data([1]).write(to: primary)
            XCTAssertEqual(NativeMLXLibrarySearch.find(preferred: primary,
                candidates: { [] }, load: load), primary)
        }
    }

    func testRemovedLibraryFailsAndNewSymlinkCanRecover() throws {
        try withDirectory { root in
            let library = root.appending(path: "mlx.metallib")
            try Data([1]).write(to: library)
            try FileManager.default.removeItem(at: library)
            var loads = 0
            XCTAssertNil(NativeMLXLibrarySearch.find(preferred: library,
                candidates: { [library] }, load: { _ in loads += 1; return true }))
            XCTAssertEqual(loads, 0)
            let target = root.appending(path: "target.metallib")
            try Data([1]).write(to: target)
            try FileManager.default.createSymbolicLink(at: library, withDestinationURL: target)
            XCTAssertEqual(NativeMLXLibrarySearch.find(preferred: library,
                candidates: { [] }, load: { _ in true }), library)
        }
    }
}
