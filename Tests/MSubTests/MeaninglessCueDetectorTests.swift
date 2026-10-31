import XCTest
@testable import MSub

final class MeaninglessCueDetectorTests: XCTestCase {
    func testJapaneseAcknowledgementsAndExclamations() {
        for text in ["うんうんうん", "うん、うん！", "ウンウンウン", "ｳﾝｳﾝ", "わー", "わーー！", "ワー", "わぁー", "わあわあ", "うわー", "うんっ、わー"] {
            XCTAssertTrue(MeaninglessCueDetector.isMeaningless(text), text)
        }
        for text in ["うん、わかった", "うんうん、続けて", "わー、きれい", "わーく", "わあるど", "うわさ", "わたし", "うんどう", "不安"] {
            XCTAssertFalse(MeaninglessCueDetector.isMeaningless(text), text)
        }
    }

    func testJapaneseCompoundVocalizationsAndWidthVariants() {
        for text in ["あう", "あうあう", "アウアウ", "ｱｳｱｳ", "うふふ", "えへへ", "あははっ",
                     "はぁはぁ", "ふぅー", "あぅあぅ", "うむ", "んふ", "あのー、えっとー", "えっとあのー", "んっ、あっ", "<i>ウフフ</i>"] {
            XCTAssertTrue(MeaninglessCueDetector.isMeaningless(text), text)
        }
    }

    func testJapaneseWordsAndSemanticRepetitionAreKept() {
        for text in ["あの人", "あう予定です", "うえ", "あいうえお", "はいはいはい", "まだまだまだ",
                     "ありがとうありがとうありがとう", "うふふ、ありがとう", "会社の名前", "えっと、明日です"] {
            XCTAssertFalse(MeaninglessCueDetector.isMeaningless(text), text)
        }
    }

    func testLongJapaneseNonFillerDoesNotBacktrack() {
        XCTAssertFalse(MeaninglessCueDetector.isMeaningless(String(repeating: "あう", count: 2000) + "か"))
    }

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
