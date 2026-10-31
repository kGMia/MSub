import XCTest
@testable import MSub

final class NativeQwenResidencyTests: XCTestCase {
    func testWarmReuseInvalidatesOldTimerAndRejectsConcurrentEntry() {
        var state = NativeQwenResidency()
        XCTAssertTrue(state.begin())
        let first = state.generation
        XCTAssertFalse(state.begin())
        XCTAssertFalse(state.canExpire(generation: first))
        XCTAssertTrue(state.finish(success: true))
        XCTAssertTrue(state.canExpire(generation: first))
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.canExpire(generation: first))
        XCTAssertTrue(state.finish(success: true))
        XCTAssertFalse(state.canExpire(generation: first))
        XCTAssertTrue(state.canExpire(generation: state.generation))
    }

    func testPressureOrExplicitReleaseWaitsForDecodeToDrain() {
        var state = NativeQwenResidency()
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.requestRelease())
        XCTAssertFalse(state.requestRelease())
        XCTAssertTrue(state.busy)
        XCTAssertFalse(state.finish(success: true))
        XCTAssertFalse(state.busy)
        XCTAssertTrue(state.requestRelease())
        XCTAssertTrue(state.begin())
        XCTAssertTrue(state.finish(success: true))
    }

    func testFailureAndCancellationNeverRetain() {
        var state = NativeQwenResidency()
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.finish(success: false))
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.requestRelease())
        XCTAssertFalse(state.finish(success: false))
    }

    func testRetentionBoundsAndLowMemoryDefault() {
        let big: UInt64 = 32 * 1024 * 1024 * 1024
        let small: UInt64 = 8 * 1024 * 1024 * 1024
        XCTAssertEqual(NativeQwenResidency.idleSeconds(environment: [:], physicalMemory: big), 45)
        XCTAssertEqual(NativeQwenResidency.idleSeconds(environment: [:], physicalMemory: small), 0)
        for (value, expected) in [("0", 0.0), ("-10", 0), ("1000", 120), ("12.5", 12.5), ("nan", 45), ("inf", 45), ("invalid", 45)] {
            XCTAssertEqual(NativeQwenResidency.idleSeconds(environment: ["MSUB_NATIVE_QWEN_IDLE_SECONDS": value], physicalMemory: big), expected)
        }
    }
}
