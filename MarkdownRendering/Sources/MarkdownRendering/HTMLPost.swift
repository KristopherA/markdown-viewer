import Foundation

enum HTML {
    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }
}

enum AlertHTML {
    static func wrap(kind: String, title: String, body: String) -> String {
        """
        <div class="markdown-alert markdown-alert-\(kind)"><p class="markdown-alert-title">\(HTML.escape(title))</p>
        \(body)
        </div>
        """
    }
}

enum HTMLPost {
    static func processFragment(_ html: String, math: [MathPiece]) -> String {
        var result = highlightCode(html)
        result = HeadingAnchors.apply(result)
        result = Emoji.replace(result)
        result = substituteMath(result, math: math)
        return result
    }

    static func spliceAlerts(_ html: String, tokens: [String], blocks: [String]) -> String {
        var result = html
        for (token, block) in zip(tokens, blocks) {
            let paragraph = "<p>\(token)</p>"
            if result.contains(paragraph) {
                result = result.replacingOccurrences(of: paragraph, with: block)
            } else {
                result = result.replacingOccurrences(of: token, with: block)
            }
        }
        return result
    }

    static func inlineImages(_ html: String, baseURL: URL, inlineContained: Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*?>"#, options: [.caseInsensitive]) else {
            return html
        }
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        var result = html
        for match in matches.reversed() {
            let tag = source.substring(with: match.range)
            let updated = imageTag(tag, baseURL: baseURL, inlineContained: inlineContained)
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: updated)
        }
        return result
    }

    private static func highlightCode(_ html: String) -> String {
        let pattern = #"<pre([^>]*)><code([^>]*)>(.*?)</code></pre>"#
        return replaceMatches(pattern: pattern, in: html) { match, source in
            let codeAttributes = source.substring(with: match.range(at: 2))
            let inner = source.substring(with: match.range(at: 3))
            guard let rawLanguage = languageName(in: codeAttributes) else {
                return nil
            }
            let language = rawLanguage.lowercased()
            if language == "mermaid" {
                return "<pre class=\"mermaid\">\(inner)</pre>"
            }
            if language == "math" {
                let tex = HTML.unescape(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                return PageScript.shared.renderMath(tex, display: true)
            }
            let plain = HTML.unescape(inner)
            guard let highlighted = PageScript.shared.highlight(plain, language: language) else {
                return nil
            }
            let attributes = codeAttributes.replacingOccurrences(
                of: "class=\"language-\(rawLanguage)\"",
                with: "class=\"hljs language-\(rawLanguage)\""
            )
            return "<pre><code\(attributes)>\(highlighted)</code></pre>"
        }
    }

    private static func languageName(in attributes: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"language-([^"\s]+)"#) else { return nil }
        let range = NSRange(attributes.startIndex..., in: attributes)
        guard let match = regex.firstMatch(in: attributes, range: range),
              let nameRange = Range(match.range(at: 1), in: attributes) else { return nil }
        return String(attributes[nameRange])
    }

    private static func substituteMath(_ html: String, math: [MathPiece]) -> String {
        var result = html
        for (index, piece) in math.enumerated() {
            let token = String(format: "MDVMATHTOKEN%06dEND", index)
            let rendered = PageScript.shared.renderMath(piece.tex, display: piece.display)
            let paragraph = "<p>\(token)</p>"
            if piece.display, result.contains(paragraph) {
                result = result.replacingOccurrences(of: paragraph, with: rendered)
            } else {
                result = result.replacingOccurrences(of: token, with: rendered)
            }
        }
        return result
    }

    static func absolutizeLinks(_ html: String, baseURL: URL) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"href\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive]) else {
            return html
        }
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        var result = html
        for match in matches.reversed() {
            let valueRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard valueRange.location != NSNotFound, let range = Range(valueRange, in: result) else { continue }
            let raw = HTML.unescape(String(result[range]))
            guard let absolute = absoluteFileURL(raw, baseURL: baseURL) else { continue }
            result.replaceSubrange(range, with: absolute.absoluteString)
        }
        return result
    }

    private static func absoluteFileURL(_ source: String, baseURL: URL) -> URL? {
        if source.isEmpty || source.hasPrefix("#") { return nil }
        let lowered = source.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("mailto:") || lowered.hasPrefix("data:") {
            return nil
        }
        if lowered.hasPrefix("file:") {
            return URL(string: source)?.standardizedFileURL
        }
        if source.hasPrefix("/") {
            return URL(fileURLWithPath: source).standardizedFileURL
        }
        let decoded = source.removingPercentEncoding ?? source
        return URL(fileURLWithPath: decoded, relativeTo: baseURL).standardizedFileURL
    }

    private static func imageTag(_ tag: String, baseURL: URL, inlineContained: Bool) -> String {
        guard let source = attribute("src", in: tag),
              let resolved = dataURI(for: HTML.unescape(source), baseURL: baseURL, inlineContained: inlineContained) else {
            return tag
        }
        return replacingAttribute("src", in: tag, with: resolved)
    }

    private static func dataURI(for source: String, baseURL: URL, inlineContained: Bool) -> String? {
        let lowered = source.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("data:") || lowered.hasPrefix("//") {
            return nil
        }
        let fileURL: URL
        if lowered.hasPrefix("file:") {
            guard let url = URL(string: source) else { return nil }
            fileURL = url.standardizedFileURL
        } else if source.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: source).standardizedFileURL
        } else {
            let decoded = source.removingPercentEncoding ?? source
            fileURL = URL(fileURLWithPath: decoded, relativeTo: baseURL).standardizedFileURL
        }
        if !inlineContained, fileStaysWithDocument(fileURL, baseURL: baseURL) {
            return nil
        }
        guard let data = readLocalFile(fileURL), data.count <= 15_000_000 else { return nil }
        let mime = mimeType(for: fileURL)
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func fileStaysWithDocument(_ fileURL: URL, baseURL: URL) -> Bool {
        let base = baseURL.standardizedFileURL.resolvingSymlinksInPath()
        var directory = base.path
        if !directory.hasSuffix("/") {
            directory += "/"
        }
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(directory)
    }

    /// A raw open of a sibling of the presented document can stall. Coordinating the read
    /// does not. Give up if coordination itself does not return.
    private static func readLocalFile(_ url: URL) -> Data? {
        let box = FileRead()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { coordinated in
                box.data = try? Data(contentsOf: coordinated)
            }
            group.leave()
        }
        guard group.wait(timeout: .now() + 2) == .success else { return nil }
        return box.data
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "avif": return "image/avif"
        default: return "application/octet-stream"
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        if let value = Range(match.range(at: 1), in: tag) { return String(tag[value]) }
        if let value = Range(match.range(at: 2), in: tag) { return String(tag[value]) }
        return nil
    }

    private static func replacingAttribute(_ name: String, in tag: String, with value: String) -> String {
        let pattern = #"\#(name)\s*=\s*(?:"[^"]*"|'[^']*')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return tag }
        let range = NSRange(tag.startIndex..., in: tag)
        return regex.stringByReplacingMatches(in: tag, range: range, withTemplate: "\(name)=\"\(value)\"")
    }

    private static func replaceMatches(
        pattern: String,
        in html: String,
        transform: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return html
        }
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        var result = html
        for match in matches.reversed() {
            guard let replacement = transform(match, source), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

enum HeadingAnchors {
    private static let dropped: CharacterSet = {
        var set = CharacterSet(charactersIn: "\\'\"!#$%&()*+,./:;<=>?@[]^`{|}~")
        if let start = Unicode.Scalar(0x2000), let end = Unicode.Scalar(0x206F) {
            set.insert(charactersIn: start...end)
        }
        if let start = Unicode.Scalar(0x2E00), let end = Unicode.Scalar(0x2E7F) {
            set.insert(charactersIn: start...end)
        }
        return set
    }()

    static func apply(_ html: String) -> String {
        let pattern = #"<h([1-6])([^>]*)>(.*?)</h\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return html
        }
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        var seen: [String: Int] = [:]
        var replacements: [String] = []
        replacements.reserveCapacity(matches.count)
        for match in matches {
            let level = source.substring(with: match.range(at: 1))
            let attributes = source.substring(with: match.range(at: 2))
            let inner = source.substring(with: match.range(at: 3))
            if attributes.range(of: #"\bid\s*="#, options: .regularExpression) != nil {
                replacements.append(source.substring(with: match.range))
                continue
            }
            let slug = uniqueSlug(visibleText(inner), seen: &seen)
            replacements.append("<h\(level) id=\"\(slug)\"\(attributes)>\(inner)</h\(level)>")
        }
        var result = html
        for (match, replacement) in zip(matches, replacements).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func visibleText(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return HTML.unescape(stripped)
    }

    private static func uniqueSlug(_ text: String, seen: inout [String: Int]) -> String {
        let base = slug(text)
        let key = base.isEmpty ? "section" : base
        let count = seen[key, default: 0]
        seen[key] = count + 1
        return count == 0 ? key : "\(key)-\(count)"
    }

    private static func slug(_ text: String) -> String {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = String(lowered.unicodeScalars.filter { !dropped.contains($0) })
        return filtered.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
    }
}

enum Emoji {
    static func replace(_ html: String) -> String {
        let map = PageAssets.emoji
        guard !map.isEmpty else { return html }
        let masked = maskCode(html)
        let replaced = replaceTextNodes(masked.text, map: map)
        return InlineCode.restore(replaced, using: masked.codes)
    }

    private static func maskCode(_ html: String) -> InlineCode.Mask {
        var codes: [String: String] = [:]
        var result = html
        var count = 0
        for pattern in [#"(?is)<pre\b[^>]*>.*?</pre>"#, #"(?is)<code\b[^>]*>.*?</code>"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let source = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: source.length))
            for match in matches.reversed() {
                let token = String(format: "MDVHTMLTOKEN%06dEND", count)
                count += 1
                codes[token] = source.substring(with: match.range)
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: token)
            }
        }
        return InlineCode.Mask(text: result, codes: codes)
    }

    private static func replaceTextNodes(_ html: String, map: [String: String]) -> String {
        var result = ""
        var cursor = html.startIndex
        while cursor < html.endIndex {
            if html[cursor] == "<" {
                guard let end = html[cursor...].firstIndex(of: ">") else {
                    result += replaceShortcodes(String(html[cursor...]), map: map)
                    break
                }
                result += html[cursor...end]
                cursor = html.index(after: end)
            } else if let next = html[cursor...].firstIndex(of: "<") {
                result += replaceShortcodes(String(html[cursor..<next]), map: map)
                cursor = next
            } else {
                result += replaceShortcodes(String(html[cursor...]), map: map)
                break
            }
        }
        return result
    }

    private static func replaceShortcodes(_ text: String, map: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: ":([a-z0-9_+-]{1,100}):") else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var result = text
        for match in matches.reversed() {
            let name = source.substring(with: match.range(at: 1))
            guard let emoji = map[name], let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: emoji)
        }
        return result
    }
}

private final class FileRead: @unchecked Sendable {
    var data: Data?
}
