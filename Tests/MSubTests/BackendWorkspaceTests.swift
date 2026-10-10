import Foundation
import XCTest
@testable import MSub

@MainActor
final class BackendWorkspaceTests: XCTestCase {
    func testPackagedBackendWinsOverEnclosingCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func backend(_ path: URL) throws -> URL {
            try FileManager.default.createDirectory(at: path.appending(path: "src/huz_subtitle"), withIntermediateDirectories: true)
            try Data().write(to: path.appending(path: "pyproject.toml"))
            try Data().write(to: path.appending(path: "src/huz_subtitle/web.py"))
            return path
        }
        let checkout = try backend(root)
        let bundle = try backend(root.appending(path: "Derived/MSub.app/Contents/Resources/backend"))
        let executable = root.appending(path: "Derived/MSub.app/Contents/MacOS")
        XCTAssertEqual(BackendService.resolveWorkspaceRoot(explicit: nil, bundled: bundle, candidates: [executable])?.path, bundle.path)
        // Explicit development overrides and unbundled CLI discovery still work.
        XCTAssertEqual(BackendService.resolveWorkspaceRoot(explicit: checkout, bundled: bundle, candidates: [executable])?.path, checkout.path)
        XCTAssertEqual(BackendService.resolveWorkspaceRoot(explicit: nil, bundled: nil, candidates: [executable])?.path, checkout.path)
        XCTAssertEqual(BackendService.resolveWorkspaceRoot(explicit: root.appending(path: "missing"), bundled: bundle, candidates: [])?.path, bundle.path)
    }
}
