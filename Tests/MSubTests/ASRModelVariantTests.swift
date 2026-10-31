import XCTest
@testable import MSub

final class ASRModelVariantTests: XCTestCase {
    func testOldCatalogWithoutVariantsStillDecodes() throws {
        let data = Data(#"{"engine":"qwen3","title":"Qwen3","defaultModel":"general","localModel":"/models/general","localModelAvailable":true,"supports":["language"]}"#.utf8)
        let model = try JSONDecoder().decode(ASRModelInfo.self, from: data)
        XCTAssertNil(model.variants)
        XCTAssertEqual(model.defaultModel, "general")
    }

    func testJapaneseVariantDecodesLanguageAndInstallation() throws {
        let data = Data(#"{"engine":"qwen3","title":"Qwen3","defaultModel":"general","localModel":"/models/general","localModelAvailable":true,"supports":[],"variants":[{"repo":"ph0ryn/Qwen3-ASR-1.7B-JA-MLX-bf16","title":"JA bf16","localModel":"/models/ja","localModelAvailable":true,"language":"ja"}]}"#.utf8)
        let model = try JSONDecoder().decode(ASRModelInfo.self, from: data)
        XCTAssertEqual(model.variants?.first?.language, .ja)
        XCTAssertEqual(model.variants?.first?.localModel, "/models/ja")
        XCTAssertEqual(model.variants?.first?.localModelAvailable, true)
        XCTAssertEqual(model.defaultModel, "general")
    }
}
