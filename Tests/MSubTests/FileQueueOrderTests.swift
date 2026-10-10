import Foundation
import XCTest
@testable import MSub

final class FileQueueOrderTests: XCTestCase {
    func testMultiItemMovePreservesRelativeOrderAndCanAppend() {
        let ids = (0..<5).map { _ in UUID() }
        XCTAssertEqual(FileQueueOrder.moving(ids, sources: [ids[3], ids[1]], before: ids[0]),
                       [ids[1], ids[3], ids[0], ids[2], ids[4]])
        XCTAssertEqual(FileQueueOrder.moving(ids, sources: [ids[0]], before: nil),
                       [ids[1], ids[2], ids[3], ids[4], ids[0]])
    }

    func testStaleOrSelfTargetedDragDoesNotChangeQueue() {
        let ids = (0..<3).map { _ in UUID() }
        XCTAssertNil(FileQueueOrder.moving(ids, sources: [UUID()], before: ids[0]))
        XCTAssertNil(FileQueueOrder.moving(ids, sources: [ids[0]], before: ids[0]))
        XCTAssertNil(FileQueueOrder.moving(ids, sources: [ids[0]], before: UUID()))
    }
}
