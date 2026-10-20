import Foundation

struct MathPiece {
    var display: Bool
    var tex: String
}

struct AlertPiece {
    var kind: String
    var title: String
    var body: String
}

struct PreparedMarkdown {
    var frontMatter: String?
    var markdown: String
    var math: [MathPiece]
    var alerts: [AlertPiece]
    var alertTokens: [String]
}

enum SourcePreparation {
    static func prepare(_ markdown: String) -> PreparedMarkdown {
        let split = FrontMatter.split(markdown)
        var math: [MathPiece] = []
        var alerts: [AlertPiece] = []
        var alertTokens: [String] = []
        let body = transform(split.body, math: &math, alerts: &alerts, alertTokens: &alertTokens)
        return PreparedMarkdown(
            frontMatter: split.table,
            markdown: body,
            math: math,
            alerts: alerts,
            alertTokens: alertTokens
        )
    }

    private static func transform(
        _ markdown: String,
        math: inout [MathPiece],
        alerts: inout [AlertPiece],
        alertTokens: inout [String]
    ) -> String {
        FencedBlocks.split(markdown).map { chunk in
            switch chunk {
            case let .code(text):
                return text
            case let .math(source):
                return mathToken(MathPiece(display: true, tex: source), into: &math)
            case let .prose(text):
                return transformProse(text, math: &math, alerts: &alerts, alertTokens: &alertTokens)
            }
        }
        .joined(separator: "\n")
    }

    private static func transformProse(
        _ text: String,
        math: inout [MathPiece],
        alerts: inout [AlertPiece],
        alertTokens: inout [String]
    ) -> String {
        let masked = InlineCode.mask(text)
        let extracted = Alerts.extract(masked.text)
        let restoredAlerts = extracted.alerts.map { alert -> AlertPiece in
            let body = extractMath(InlineCode.restore(alert.body, using: masked.codes), into: &math)
            return AlertPiece(kind: alert.kind, title: alert.title, body: body)
        }
        alerts.append(contentsOf: restoredAlerts)
        alertTokens.append(contentsOf: extracted.tokens)
        let withMath = MathSyntax.extract(extracted.text, into: &math)
        return InlineCode.restore(withMath, using: masked.codes)
    }

    private static func extractMath(_ text: String, into math: inout [MathPiece]) -> String {
        let masked = InlineCode.mask(text)
        let extracted = MathSyntax.extract(masked.text, into: &math)
        return InlineCode.restore(extracted, using: masked.codes)
    }

    private static func mathToken(_ piece: MathPiece, into math: inout [MathPiece]) -> String {
        let token = String(format: "MDVMATHTOKEN%06dEND", math.count)
        math.append(piece)
        return token
    }
}

enum FrontMatter {
    static func split(_ markdown: String) -> (table: String?, body: String) {
        guard markdown.hasPrefix("---\n") else { return (nil, markdown) }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, lines[0].trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, markdown)
        }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return (nil, markdown)
        }
        let yaml = lines[1..<end].joined(separator: "\n")
        let rows = parse(yaml)
        guard !rows.isEmpty else { return (nil, markdown) }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (tableHTML(rows), body)
    }

    private static func parse(_ yaml: String) -> [(String, String)] {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rows: [(String, String)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
                index += 1
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            index += 1
            if value.isEmpty || value == "|" || value == ">" {
                var block: [String] = []
                while index < lines.count {
                    let next = lines[index]
                    if next.hasPrefix(" ") || next.hasPrefix("\t") || next.trimmingCharacters(in: .whitespaces).isEmpty {
                        block.append(next.trimmingCharacters(in: .whitespaces))
                        index += 1
                    } else {
                        break
                    }
                }
                value = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !key.isEmpty {
                rows.append((key, value))
            }
        }
        return rows
    }

    private static func tableHTML(_ rows: [(String, String)]) -> String {
        var html = "<table><tbody>"
        for (key, value) in rows {
            let rendered = HTML.escape(value).replacingOccurrences(of: "\n", with: "<br>")
            html += "<tr><td>\(HTML.escape(key))</td><td>\(rendered)</td></tr>"
        }
        html += "</tbody></table>"
        return html
    }
}

enum FencedBlocks {
    enum Chunk {
        case prose(String)
        case code(String)
        case math(String)
    }

    static func split(_ markdown: String) -> [Chunk] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [Chunk] = []
        var prose: [String] = []
        func flush() {
            if !prose.isEmpty {
                chunks.append(.prose(prose.joined(separator: "\n")))
                prose.removeAll()
            }
        }

        var index = 0
        while index < lines.count {
            if let fence = openingFence(lines[index]) {
                flush()
                var cursor = index + 1
                var closed = false
                while cursor < lines.count {
                    if closingFence(lines[cursor], marker: fence.marker, minimum: fence.count) {
                        closed = true
                        break
                    }
                    cursor += 1
                }
                let end = closed ? cursor : lines.count - 1
                let language = fence.info.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
                if language == "math" {
                    let source = lines[(index + 1)..<(closed ? cursor : lines.count)].joined(separator: "\n")
                    chunks.append(.math(source))
                } else {
                    chunks.append(.code(lines[index...end].joined(separator: "\n")))
                }
                index = closed ? cursor + 1 : lines.count
                continue
            }
            prose.append(lines[index])
            index += 1
        }
        flush()
        return chunks
    }

    private struct Fence {
        var marker: Character
        var count: Int
        var info: String
    }

    private static func openingFence(_ line: String) -> Fence? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let run = rest.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        let info = rest.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return Fence(marker: marker, count: run.count, info: info)
    }

    private static func closingFence(_ line: String, marker: Character, minimum: Int) -> Bool {
        let indent = leadingSpaces(line)
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let run = rest.prefix { $0 == marker }
        guard run.count >= minimum else { return false }
        return rest.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}

enum InlineCode {
    struct Mask {
        var text: String
        var codes: [String: String]
    }

    static func mask(_ text: String) -> Mask {
        var codes: [String: String] = [:]
        var result = ""
        var index = text.startIndex
        var count = 0
        while index < text.endIndex {
            if text[index] == "`" {
                let runEnd = endOfRun(text, from: index, character: "`")
                let length = text.distance(from: index, to: runEnd)
                if let close = closingRun(text, from: runEnd, character: "`", length: length) {
                    let token = String(format: "MDVCODETOKEN%06dEND", count)
                    count += 1
                    let after = text.index(close, offsetBy: length)
                    codes[token] = String(text[index..<after])
                    result += token
                    index = after
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return Mask(text: result, codes: codes)
    }

    static func restore(_ text: String, using codes: [String: String]) -> String {
        var result = text
        for (token, original) in codes.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacingOccurrences(of: token, with: original)
        }
        return result
    }

    private static func endOfRun(_ text: String, from index: String.Index, character: Character) -> String.Index {
        var cursor = index
        while cursor < text.endIndex, text[cursor] == character {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private static func closingRun(
        _ text: String,
        from start: String.Index,
        character: Character,
        length: Int
    ) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex {
            if text[cursor] == character {
                let runEnd = endOfRun(text, from: cursor, character: character)
                if text.distance(from: cursor, to: runEnd) == length {
                    return cursor
                }
                cursor = runEnd
                continue
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}

enum Alerts {
    struct Extracted {
        var text: String
        var alerts: [AlertPiece]
        var tokens: [String]
    }

    private static let kinds = ["note": "Note", "tip": "Tip", "important": "Important", "warning": "Warning", "caution": "Caution"]

    static func extract(_ text: String) -> Extracted {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var alerts: [AlertPiece] = []
        var tokens: [String] = []
        var index = 0
        while index < lines.count {
            if let header = alertHeader(lines[index]) {
                var body: [String] = []
                if !header.remainder.isEmpty {
                    body.append(header.remainder)
                }
                index += 1
                while index < lines.count, let content = quoteContent(lines[index]) {
                    body.append(content)
                    index += 1
                }
                let token = String(format: "MDVALERTTOKEN%06dEND", tokens.count)
                tokens.append(token)
                alerts.append(AlertPiece(kind: header.kind, title: header.title, body: body.joined(separator: "\n")))
                output.append(token)
                continue
            }
            output.append(lines[index])
            index += 1
        }
        return Extracted(text: output.joined(separator: "\n"), alerts: alerts, tokens: tokens)
    }

    private struct Header {
        var kind: String
        var title: String
        var remainder: String
    }

    private static func alertHeader(_ line: String) -> Header? {
        guard let content = quoteContent(line) else { return nil }
        let pattern = #"^\[!(note|tip|important|warning|caution)\]\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let kindRange = Range(match.range(at: 1), in: content) else { return nil }
        let kind = content[kindRange].lowercased()
        guard let title = kinds[kind] else { return nil }
        let remainder: String
        if let remainderRange = Range(match.range(at: 2), in: content) {
            remainder = String(content[remainderRange])
        } else {
            remainder = ""
        }
        return Header(kind: kind, title: title, remainder: remainder)
    }

    private static func quoteContent(_ line: String) -> String? {
        var index = line.startIndex
        var spaces = 0
        while index < line.endIndex, line[index] == " ", spaces < 3 {
            spaces += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == ">" else { return nil }
        index = line.index(after: index)
        if index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
        }
        return String(line[index...])
    }
}

enum MathSyntax {
    static func extract(_ text: String, into math: inout [MathPiece]) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "[" || text[next] == "(" {
                    let display = text[next] == "["
                    let closer: Character = display ? "]" : ")"
                    let contentStart = text.index(after: next)
                    if let close = closingBackslash(text, from: contentStart, closer: closer) {
                        let tex = String(text[contentStart..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                        result += append(MathPiece(display: display, tex: tex), to: &math)
                        index = text.index(close, offsetBy: 2)
                        continue
                    }
                }
                result.append(character)
                if next < text.endIndex {
                    result.append(text[next])
                    index = text.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "$" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "$" {
                    let contentStart = text.index(after: next)
                    if let close = dollarDollar(text, from: contentStart) {
                        let tex = String(text[contentStart..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !tex.isEmpty {
                            result += append(MathPiece(display: true, tex: tex), to: &math)
                            index = text.index(close, offsetBy: 2)
                            continue
                        }
                    }
                } else if let inline = inlineDollar(text, open: index) {
                    result += append(MathPiece(display: false, tex: inline.tex), to: &math)
                    index = inline.after
                    continue
                }
            }

            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    private static func append(_ piece: MathPiece, to math: inout [MathPiece]) -> String {
        let token = String(format: "MDVMATHTOKEN%06dEND", math.count)
        math.append(piece)
        return token
    }

    private static func closingBackslash(_ text: String, from start: String.Index, closer: Character) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    if text[next] == closer { return index }
                    index = text.index(after: next)
                    continue
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func dollarDollar(_ text: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { break }
                index = text.index(after: next)
                continue
            }
            if text[index] == "$" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "$" { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func inlineDollar(_ text: String, open: String.Index) -> (tex: String, after: String.Index)? {
        let contentStart = text.index(after: open)
        guard contentStart < text.endIndex else { return nil }
        let first = text[contentStart]
        if first == "$" || first.isWhitespace || first.isNewline { return nil }
        var index = contentStart
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline { return nil }
            if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { break }
                index = text.index(after: next)
                continue
            }
            if character == "$" {
                let previous = text.index(before: index)
                if !text[previous].isWhitespace {
                    let tex = String(text[contentStart..<index])
                    guard !tex.isEmpty else { return nil }
                    return (tex, text.index(after: index))
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
