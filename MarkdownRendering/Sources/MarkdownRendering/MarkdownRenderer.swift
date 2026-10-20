import CMarkGFMBridge
import Foundation

public enum RenderMode: Equatable, Sendable {
    case document(baseURL: URL)
    case quickLook(baseURL: URL)

    var baseURL: URL {
        switch self {
        case let .document(baseURL), let .quickLook(baseURL):
            return baseURL
        }
    }

    /// Local images are inlined in both the app and Quick Look. The web view is not given
    /// the document directory as a base URL, because a second load with that base stalls.
    var inlineContainedImages: Bool { true }
}

public struct RenderedPage: Equatable, Sendable {
    public var html: String

    public init(html: String) {
        self.html = html
    }
}

public enum MarkdownRenderError: Error, CustomStringConvertible {
    case conversionFailed

    public var description: String {
        switch self {
        case .conversionFailed:
            return "The file could not be rendered."
        }
    }
}

public enum MarkdownRenderer {
    private static let lock = NSLock()

    public static func decode(_ data: Data) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        if let string = String(data: bytes, encoding: .utf8) {
            return string
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func render(markdown: String, mode: RenderMode, inlineImages: Bool = true) throws -> RenderedPage {
        let preparedFragment = try lockedPrepare(markdown)
        var fragment = preparedFragment.html
        if inlineImages {
            // File coordination has to reach the document presenter on the main thread.
            // Holding the renderer lock across that call deadlocks the read.
            fragment = HTMLPost.inlineImages(
                fragment,
                baseURL: mode.baseURL,
                inlineContained: mode.inlineContainedImages
            )
        }
        fragment = HTMLPost.absolutizeLinks(fragment, baseURL: mode.baseURL)
        let page = lockedFinish(fragment: fragment, frontMatter: preparedFragment.frontMatter)
        return RenderedPage(html: page)
    }

    private static func lockedPrepare(_ markdown: String) throws -> (html: String, frontMatter: String?) {
        lock.lock()
        defer { lock.unlock() }
        let prepared = SourcePreparation.prepare(normalize(markdown))
        let mainHTML = try renderGFM(prepared.markdown)
        let alertHTML = try prepared.alerts.map { alert -> String in
            let body = try renderGFM(alert.body)
            let processed = HTMLPost.processFragment(body, math: prepared.math)
            return AlertHTML.wrap(kind: alert.kind, title: alert.title, body: processed)
        }
        var fragment = HTMLPost.processFragment(mainHTML, math: prepared.math)
        fragment = HTMLPost.spliceAlerts(fragment, tokens: prepared.alertTokens, blocks: alertHTML)
        return (fragment, prepared.frontMatter)
    }

    private static func lockedFinish(fragment: String, frontMatter: String?) -> String {
        lock.lock()
        defer { lock.unlock() }
        return PageDocument.make(fragment: fragment, frontMatter: frontMatter)
    }

    static func renderGFM(_ markdown: String) throws -> String {
        var bytes = Array(markdown.utf8)
        bytes.append(0)
        let html: String? = bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            let pointer = UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self)
            guard let rendered = markdown_render_gfm(pointer, buffer.count - 1) else { return nil }
            defer { markdown_render_gfm_free(rendered) }
            return String(cString: rendered)
        }
        guard let html else { throw MarkdownRenderError.conversionFailed }
        return html
    }

    private static func normalize(_ markdown: String) -> String {
        var text = markdown
        if text.hasPrefix("\u{feff}") {
            text.removeFirst()
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
