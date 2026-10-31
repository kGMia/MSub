import XCTest
@testable import MSub

final class NativeQwenRepetitionTests: XCTestCase {
    func testSentenceLoopsIncludingPartialTail() {
        for text in [String(repeating: "これは同じ文章です。", count: 4),
                     "前置きです。" + String(repeating: "ありがとうございます。", count: 5) + "ありが",
                     String(repeating: "This is the same sentence. ", count: 4),
                     String(repeating: "这是同一个句子。", count: 4)] {
            XCTAssertTrue(NativeQwenRepetition.hasPhraseLoop(text), text)
        }
    }
    func testOrdinarySpeechAndBriefRepetitionAreKept() {
        for text in ["", "うんうんうん", "はい、はい。", String(repeating: "ありがとうございます。", count: 2),
                     "猫が来ました。犬も来ました。それから鳥も来ました。", String(repeating: "abcde", count: 4)] {
            XCTAssertFalse(NativeQwenRepetition.hasPhraseLoop(text), text)
        }
    }
    func testRejectEmptyOrStillLoopingRetry() {
        XCTAssertFalse(NativeQwenRepetition.acceptsRetry(" \n"))
        XCTAssertFalse(NativeQwenRepetition.acceptsRetry(String(repeating: "これは同じ文章です。", count: 4)))
        XCTAssertTrue(NativeQwenRepetition.acceptsRetry("明日は晴れです。"))
    }
}
