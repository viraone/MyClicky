import Foundation
import XCTest
@testable import MyClicky

@MainActor
final class TypeScriptLSPClientTests: XCTestCase {
    func testFramerHandlesSplitAndConsecutiveMessages() throws {
        let first = try packet(["jsonrpc": "2.0", "id": 1, "result": ["ok": true]])
        let second = try packet(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
        let split = first.count / 2
        var framer = LSPMessageFramer()

        XCTAssertTrue(framer.append(first.prefix(split)).isEmpty)
        let messages = framer.append(first.suffix(from: split) + second)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual((messages[0]["id"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(messages[1]["method"] as? String, "initialized")
        XCTAssertTrue(framer.buffer.isEmpty)
    }

    func testPositionUsesLSPZeroBasedUTF16Coordinates() {
        let text = "const emoji = \"😀\"\nemoji"
        let offset = ("const emoji = \"😀\"\nemo" as NSString).length
        XCTAssertEqual(TypeScriptLSPClient.position(in: text, utf16Offset: offset),
                       CodeLSPPosition(line: 1, character: 3))
    }

    func testDiagnosticRangeConvertsBackToNSRange() {
        let text = "let 😀 = 1\nconst answer = missing"
        let range = CodeLSPRange(start: .init(line: 1, character: 15),
                                 end: .init(line: 1, character: 22))
        let converted = TypeScriptLSPClient.nsRange(range, in: text)
        XCTAssertEqual(converted.map { (text as NSString).substring(with: $0) }, "missing")
    }

    func testLiveServerPublishesTypeScriptDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LSP_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_LSP_INTEGRATION=1 to exercise npm and the real language server.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeky-lsp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "{\"compilerOptions\":{\"strict\":true}}".write(
            to: root.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        let source = "import { add } from \"./math\"\nconst answer: string = add(1, 2)\n"
        try source.write(to: root.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)
        try "export function add(a: number, b: number) { return a + b }\n".write(
            to: root.appendingPathComponent("math.ts"), atomically: true, encoding: .utf8)
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))
        let ready = expectation(description: "language server initialized")
        let diagnosed = expectation(description: "type error published")
        let hovered = expectation(description: "hover information returned")
        let defined = expectation(description: "definition returned")
        var definition: CodeLSPLocation?
        let client = TypeScriptLSPClient()
        client.onStatus = { status in
            if status == .ready {
                ready.fulfill()
                let offset = (source as NSString).range(of: "add", options: .backwards).location + 1
                client.hover(path: "index.ts", characterOffset: offset, text: source)
                client.definition(path: "index.ts", characterOffset: offset, text: source)
            }
            if case .failed(let detail) = status { XCTFail(detail) }
        }
        client.onDiagnostics = { path, diagnostics in
            if path == "index.ts", diagnostics.contains(where: { $0.message.contains("number") }) {
                diagnosed.fulfill()
            }
        }
        client.onHover = { text in
            if text?.lowercased().contains("add") == true { hovered.fulfill() }
        }
        client.onDefinition = { location in
            definition = location
            defined.fulfill()
        }

        client.start(for: project)
        client.focus(path: "index.ts", text: source)
        await fulfillment(of: [ready, diagnosed, hovered, defined], timeout: 90)
        XCTAssertEqual(definition?.path, "index.ts")
        XCTAssertEqual(definition?.range.start.line, 0)
        client.stop()
    }

    private func packet(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object)
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}
