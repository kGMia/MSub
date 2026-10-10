import XCTest
@testable import MSub

final class NativeQwenDiagnosticsTests: XCTestCase {
    func testColdLoadDecodeAndPauseAreExclusive() {
        var clock = NativeQwenDiagnostics(totalSegments: 2)
        clock.transition(to: .preparation, at: 0)
        clock.modelCache = .miss
        clock.transition(to: .modelLoading, at: 1)
        clock.transition(to: .checkpoint, at: 4)
        clock.transition(to: .preparation, at: 14)
        clock.transition(to: .decoding, at: 15)
        clock.transition(to: .postprocessing, at: 20)
        clock.completedSegments = 1
        clock.transition(to: .checkpoint, at: 21)
        clock.transition(to: .decoding, at: 23)
        clock.transition(to: .postprocessing, at: 27)
        clock.completedSegments = 2
        let result = clock.finish(.completed, at: 28)
        XCTAssertEqual(result.stages["modelLoading"], 3)
        XCTAssertEqual(result.stages["recognition"], 9)
        XCTAssertEqual(result.stages["nativeCheckpoint"], 12)
        XCTAssertEqual(result.stages["nativePreparation"], 2)
        XCTAssertEqual(result.stages["postprocessing"], 2)
        XCTAssertEqual(result.stages.values.reduce(0, +), 28)
        XCTAssertEqual(result.completedSegments, 2)
        XCTAssertEqual(result.totalSegments, 2)
        XCTAssertEqual(result.modelCache, .miss)
    }

    func testWarmReuseExcludesReportingTime() {
        var clock = NativeQwenDiagnostics(totalSegments: 1)
        clock.transition(to: .preparation, at: 0)
        clock.modelCache = .hit
        clock.transition(to: nil, at: 1)
        let update = clock.snapshot(stage: .checkpoint)
        XCTAssertEqual(update.stages["nativePreparation"], 1)
        XCTAssertEqual(update.outcome, .running)
        // Five seconds spent delivering UI updates must not count as decoding.
        clock.transition(to: .checkpoint, at: 6)
        clock.transition(to: .decoding, at: 7)
        let result = clock.finish(.completed, at: 9)
        XCTAssertNil(result.stages["modelLoading"])
        XCTAssertEqual(result.stages["recognition"], 2)
        XCTAssertEqual(result.stages.values.reduce(0, +), 4)
        XCTAssertEqual(result.modelCache, .hit)
    }

    func testFailedLoadAndCancelledDecodeFreezePartialResults() {
        for (stage, outcome) in [(NativeQwenDiagnostics.Stage.modelLoading, NativeQwenDiagnostics.Outcome.failed),
                                 (.decoding, .cancelled)] {
            var clock = NativeQwenDiagnostics(totalSegments: 3)
            clock.transition(to: stage, at: 1)
            let result = clock.finish(outcome, at: 4)
            XCTAssertEqual(result.stages[stage.rawValue], 3)
            XCTAssertEqual(result.completedSegments, 0)
            XCTAssertEqual(result.outcome, outcome)
            clock.transition(to: .preparation, at: 20)
            clock.completedSegments = 3
            let repeated = clock.finish(.completed, at: 99)
            XCTAssertEqual(repeated.stages, result.stages)
            XCTAssertEqual(repeated.completedSegments, 0)
            XCTAssertEqual(repeated.outcome, outcome)
            XCTAssertEqual(clock.snapshot(stage: .preparation).outcome, outcome)
        }
    }

    func testSilenceHasNoModelOrDecodeStages() {
        var clock = NativeQwenDiagnostics(totalSegments: 0)
        clock.transition(to: .preparation, at: 1)
        let result = clock.finish(.completed, at: 1)
        XCTAssertNil(result.modelCache)
        XCTAssertNil(result.stages["modelLoading"])
        XCTAssertNil(result.stages["recognition"])
        XCTAssertEqual(result.totalSegments, 0)
        XCTAssertNil(result.stage)
    }
}
