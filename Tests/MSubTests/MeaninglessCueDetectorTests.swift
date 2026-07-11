import XCTest
@testable import MSub

final class MeaninglessCueDetectorTests: XCTestCase {
    func testChineseInterjectionWithSymbols() {
        let result = MeaninglessCueDetector.classification(for: "啊啊，呃呃呃！哦！")
        XCTAssertEqual(result.reason, .interjection)
    }

    func testJapaneseInterjectionGroupsWithSymbols() {
        let result = MeaninglessCueDetector.classification(for: "あああ、あう、ははは！")
        XCTAssertEqual(result.reason, .interjection)
    }

    func testEnglishRepeatedSyllable() {
        let result = MeaninglessCueDetector.classification(for: "AhAhAh")
        XCTAssertEqual(result.reason, .repetition)
    }

    func testSymbolsOnly() {
        let result = MeaninglessCueDetector.classification(for: "!!! ...")
        XCTAssertEqual(result.reason, .symbols)
    }

    func testNormalChineseSentenceIsKept() {
        XCTAssertFalse(MeaninglessCueDetector.isMeaningless("啊，我知道了"))
    }

    func testNormalJapaneseSentenceIsKept() {
        XCTAssertFalse(MeaninglessCueDetector.isMeaningless("あの人が来ました"))
    }

    func testNormalEnglishSentenceIsKept() {
        XCTAssertFalse(MeaninglessCueDetector.isMeaningless("oh I see"))
    }
}
