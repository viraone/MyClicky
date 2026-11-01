import XCTest
@testable import MyClicky

final class DeepSeekServiceTests: XCTestCase {
    func testDisplayNameKeepsBracketSuffixButRequestModelDropsIt() {
        let config = DeepSeekService.Configuration(
            apiKey: "test-key",
            baseURL: DeepSeekService.defaultBaseURL,
            model: "deepseek-flash[1m]"
        )
        XCTAssertEqual(config.displayName, "deepseek-flash[1m]")
        XCTAssertEqual(config.apiModel, "deepseek-flash")
    }

    func testModelWithoutABracketSuffixIsSentAsWritten() {
        let config = DeepSeekService.Configuration(
            apiKey: "test-key",
            baseURL: DeepSeekService.defaultBaseURL,
            model: "deepseek-chat"
        )
        XCTAssertEqual(config.displayName, "deepseek-chat")
        XCTAssertEqual(config.apiModel, "deepseek-chat")
    }
}
