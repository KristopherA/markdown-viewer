import MarkdownRendering
import XCTest

final class RendererTests: XCTestCase {
    func testHeadingsTableTaskListAndStrikethrough() throws {
        let html = try article("""
        # Title

        # Title

        | A | B |
        | --- | --- |
        | 1 | 2 |

        - [x] Done
        - [ ] Later

        ~~gone~~
        """)
        XCTAssertTrue(html.contains("<h1 id=\"title\">"))
        XCTAssertTrue(html.contains("<h1 id=\"title-1\">"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains(">1<"))
        XCTAssertTrue(html.contains("type=\"checkbox\""))
        XCTAssertTrue(html.contains("<del>gone</del>"))
    }

    func testSwiftAndDiffHighlighting() throws {
        let html = try article("""
        ```swift
        let answer = 42
        ```

        ```diff
        - old
        + new
        ```
        """)
        XCTAssertTrue(html.contains("hljs-keyword") || html.contains("hljs-built_in") || html.contains("hljs-type"))
        XCTAssertTrue(html.contains("hljs-addition"))
    }

    func testQuickLookImageIsInlined() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try png.write(to: directory.appendingPathComponent("dot.png"))
        let page = try MarkdownRenderer.render(
            markdown: "![dot](dot.png)\n",
            mode: .quickLook(baseURL: directory)
        )
        let body = Self.article(in: page.html)
        XCTAssertTrue(body.contains("data:image/png;base64,"))
    }

    func testDollarAndBracketMath() throws {
        let html = try article("""
        Inline $a+b$ and display \\[x^2\\].
        """)
        XCTAssertTrue(html.contains("class=\"katex\""))
        XCTAssertTrue(html.contains("katex-display"))
    }

    func testDollarInsideCodeIsNotMath() throws {
        let html = try article("`$a$`\n")
        XCTAssertFalse(html.contains("class=\"katex\""))
        XCTAssertTrue(html.contains("$a$"))
    }

    func testMermaidFenceAndBootScript() throws {
        let page = try MarkdownRenderer.render(
            markdown: """
            ```mermaid
            graph TD
              A["Hello<br>there"] --> B
            ```
            """,
            mode: .document(baseURL: URL(fileURLWithPath: "/tmp"))
        )
        let body = Self.article(in: page.html)
        XCTAssertTrue(body.contains("<pre class=\"mermaid\">"))
        XCTAssertTrue(body.contains("Hello"))
        XCTAssertTrue(page.html.contains("mermaid.run"))
        XCTAssertTrue(page.html.contains("securityLevel: \"antiscript\""))
    }

    func testFrontMatterBecomesATable() throws {
        let html = try article("""
        ---
        title: Hello
        ---
        # Body
        """)
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("Hello"))
        XCTAssertTrue(html.contains("<h1"))
        XCTAssertTrue(html.contains("Body"))
    }

    func testCaseInsensitiveAlert() throws {
        let html = try article("""
        > [!note]
        > Watch this
        """)
        XCTAssertTrue(html.contains("markdown-alert-note"))
        XCTAssertTrue(html.contains("Watch this"))
    }

    func testByteOrderMarkAndUnclosedFence() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("# Hi\n".utf8)
        let decoded = MarkdownRenderer.decode(data)
        XCTAssertFalse(decoded.hasPrefix("\u{feff}"))
        let html = try article(decoded)
        XCTAssertTrue(html.contains("Hi"))

        let partial = try article("```swift\nlet x = 1\n")
        XCTAssertTrue(partial.contains("let"))
        XCTAssertTrue(partial.contains("1"))
    }

    func testEmojiOutsideCodeOnly() throws {
        let rendered = try article("A :rocket: and `:rocket:`.\n")
        XCTAssertTrue(rendered.contains("🚀"))
        XCTAssertTrue(rendered.contains(":rocket:"))
        let codeOnly = try article("`:rocket:`\n")
        XCTAssertFalse(codeOnly.contains("🚀"))
    }

    private func article(_ markdown: String) throws -> String {
        let page = try MarkdownRenderer.render(
            markdown: markdown,
            mode: .document(baseURL: URL(fileURLWithPath: "/tmp"))
        )
        return Self.article(in: page.html)
    }

    private static func article(in html: String) -> String {
        guard let start = html.range(of: "<article"), let end = html.range(of: "</article>") else { return html }
        return String(html[start.lowerBound..<end.upperBound])
    }
}
