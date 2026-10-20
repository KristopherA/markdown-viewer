import Foundation
import JavaScriptCore

enum PageAssets {
    static let style: String = {
        let github = text(named: "github-markdown.css")
        let light = text(named: "highlight-github.css")
        let dark = text(named: "highlight-github-dark.css")
        let katex = inlineKatexFonts(text(named: "katex.min.css"))
        return """
        \(pageChrome)
        \(github)
        @media (prefers-color-scheme: light) {
        \(light)
        }
        @media (prefers-color-scheme: dark) {
        \(dark)
        }
        \(katex)
        """
    }()

    static let mermaidScript: String = {
        text(named: "mermaid.min.js").replacingOccurrences(of: "</script", with: "<\\/script", options: [.caseInsensitive])
    }()

    static let emoji: [String: String] = {
        guard let data = try? Data(contentsOf: url(named: "emoji.json")),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var map: [String: String] = [:]
        for row in rows {
            guard let emoji = row["emoji"] as? String, !emoji.isEmpty, let aliases = row["aliases"] as? [String] else {
                continue
            }
            for alias in aliases where !alias.isEmpty {
                map[alias] = emoji
            }
        }
        return map
    }()

    private static let pageChrome = """
    html { color-scheme: light dark; }
    body { margin: 0; }
    .markdown-body {
      box-sizing: border-box;
      min-width: 200px;
      max-width: 980px;
      margin: 0 auto;
      padding: 45px;
    }
    @media (max-width: 767px) {
      .markdown-body { padding: 15px; }
    }
    @media (prefers-color-scheme: dark) {
      body { background-color: #0d1117; }
    }
    @media (prefers-color-scheme: light) {
      body { background-color: #ffffff; }
    }
    pre.mermaid { background: transparent; text-align: center; }
    """

    static func text(named filename: String) -> String {
        guard let data = try? Data(contentsOf: url(named: filename)),
              let string = String(data: data, encoding: .utf8) else {
            preconditionFailure("Missing resource \(filename)")
        }
        return string
    }

    static func url(named filename: String) -> URL {
        let ns = filename as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        if let url = Bundle.module.url(forResource: base, withExtension: ext.isEmpty ? nil : ext) {
            return url
        }
        if let root = Bundle.module.resourceURL {
            let nested = root.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
        }
        preconditionFailure("Missing resource \(filename)")
    }

    private static func inlineKatexFonts(_ css: String) -> String {
        let directory = fontDirectory()
        guard let regex = try? NSRegularExpression(pattern: #"url\(fonts/([^)]+)\)"#) else { return css }
        let source = css as NSString
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: source.length))
        var result = css
        for match in matches.reversed() {
            let filename = source.substring(with: match.range(at: 1))
            guard filename.hasSuffix(".woff2"),
                  let file = directory?.appendingPathComponent(filename),
                  let data = try? Data(contentsOf: file),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "url(data:font/woff2;base64,\(data.base64EncodedString()))")
        }
        if let leftover = try? NSRegularExpression(pattern: #"url\(fonts/[^)]+\)"#) {
            result = leftover.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
    }

    private static func fontDirectory() -> URL? {
        if let root = Bundle.module.resourceURL {
            let nested = root.appendingPathComponent("katex-fonts")
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
            let processed = root.appendingPathComponent("Resources/katex-fonts")
            if FileManager.default.fileExists(atPath: processed.path) { return processed }
        }
        return Bundle.module.url(forResource: "katex-fonts", withExtension: nil)
    }
}

enum PageDocument {
    static func make(fragment: String, frontMatter: String?) -> String {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let matter = frontMatter.map { $0 + "\n" } ?? ""
        let policy = [
            "default-src 'none'",
            "script-src 'nonce-\(nonce)' 'unsafe-eval'",
            "style-src 'unsafe-inline'",
            "img-src data: blob: https: http: file:",
            "font-src data:",
            "worker-src blob:",
            "connect-src 'none'",
        ].joined(separator: "; ")
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <style>
        \(PageAssets.style)
        </style>
        </head>
        <body>
        <article class="markdown-body">
        \(matter)\(fragment)
        </article>
        <script nonce="\(nonce)">
        \(PageAssets.mermaidScript)
        </script>
        <script nonce="\(nonce)">
        \(bootScript)
        </script>
        </body>
        </html>
        """
    }

    private static let bootScript = """
    (function () {
      var media = window.matchMedia("(prefers-color-scheme: dark)");
      function theme() { return media.matches ? "dark" : "default"; }
      function nodes() { return document.querySelectorAll("pre.mermaid"); }
      function stash() {
        nodes().forEach(function (node) {
          if (!node.dataset.source) node.dataset.source = node.textContent;
        });
      }
      function draw() {
        if (!window.mermaid) return;
        stash();
        nodes().forEach(function (node) {
          node.removeAttribute("data-processed");
          node.textContent = node.dataset.source || "";
        });
        window.mermaid.initialize({
          startOnLoad: false,
          theme: theme(),
          securityLevel: "antiscript"
        });
        var pending = window.mermaid.run({ nodes: Array.from(nodes()) });
        if (pending && pending.catch) pending.catch(function () {});
      }
      draw();
      if (media.addEventListener) media.addEventListener("change", draw);
    })();
    """
}

final class PageScript {
    static let shared = PageScript()

    private var context: JSContext?

    func highlight(_ code: String, language: String) -> String? {
        let ctx = engine()
        let aliases = [
            "sh": "bash", "shell": "bash", "zsh": "bash", "yml": "yaml",
            "md": "markdown", "text": "plaintext", "txt": "plaintext",
            "docker": "dockerfile", "c++": "cpp", "c#": "csharp", "cs": "csharp",
            "js": "javascript", "ts": "typescript", "py": "python", "rb": "ruby",
            "objc": "objectivec", "objective-c": "objectivec",
        ]
        let name = aliases[language.lowercased()] ?? language.lowercased()
        guard let function = ctx.objectForKeyedSubscript("mdvHighlight"),
              let value = function.call(withArguments: [code, name]),
              !value.isNull, !value.isUndefined,
              let html = value.toString() else { return nil }
        return html
    }

    func renderMath(_ source: String, display: Bool) -> String {
        let ctx = engine()
        if let function = ctx.objectForKeyedSubscript("mdvMath"),
           let value = function.call(withArguments: [source, display]),
           !value.isNull, !value.isUndefined,
           let html = value.toString(), !html.isEmpty {
            return html
        }
        let escaped = HTML.escape(source)
        return display ? "<pre><code>\(escaped)</code></pre>" : "<code>\(escaped)</code>"
    }

    private func engine() -> JSContext {
        if let context { return context }
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, _ in }
        ctx.evaluateScript("""
        var window = this;
        var self = this;
        var global = this;
        var console = { log: function(){}, warn: function(){}, error: function(){}, debug: function(){} };
        """)
        ctx.evaluateScript(PageAssets.text(named: "highlight.min.js"))
        ctx.evaluateScript(PageAssets.text(named: "dockerfile.min.js"))
        ctx.evaluateScript(PageAssets.text(named: "katex.min.js"))
        ctx.evaluateScript("""
        function mdvHighlight(code, language) {
          if (!language || !hljs.getLanguage(language)) return null;
          return hljs.highlight(code, { language: language, ignoreIllegals: true }).value;
        }
        function mdvMath(source, display) {
          return katex.renderToString(source, {
            throwOnError: false,
            displayMode: !!display,
            output: "html"
          });
        }
        """)
        context = ctx
        return ctx
    }
}
