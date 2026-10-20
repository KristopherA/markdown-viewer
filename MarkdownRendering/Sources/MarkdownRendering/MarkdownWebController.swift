import Foundation
import SwiftUI
import WebKit

public final class MarkdownWebController: NSObject, WKNavigationDelegate {
    public let webView: WKWebView
    public var baseURL: URL?
    public var onFindResult: ((Bool) -> Void)?

    private var pendingScroll: CGPoint?
    private var loadedHTML: String?
    private var findQuery = ""
    private var findBackwards = false
    private var findToken = 0

    public override init() {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
    }

    public func attach(to container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    public func load(html: String, baseURL: URL?) {
        self.baseURL = baseURL
        guard html != loadedHTML else {
            webView.pageZoom = webView.pageZoom
            return
        }
        let apply = { [weak self] in
            guard let self else { return }
            self.loadedHTML = html
            // A file-URL base makes WebKit issue a sandbox extension on the main
            // thread, and that call never returns for directories this process can
            // already read. Relative links are rewritten to file URLs before this.
            self.webView.loadHTMLString(html, baseURL: nil)
        }
        if loadedHTML == nil {
            apply()
            return
        }
        webView.evaluateJavaScript("({x: window.scrollX, y: window.scrollY})") { [weak self] value, _ in
            if let point = Self.point(from: value) {
                self?.pendingScroll = point
            }
            // loadHTMLString waits on the web process. Calling it inside this
            // completion deadlocks, because that reply still owns the main thread.
            DispatchQueue.main.async {
                apply()
            }
        }
    }

    public func setZoom(_ zoom: CGFloat) {
        webView.pageZoom = zoom
    }

    public func find(_ query: String, token: Int, backwards: Bool) {
        findQuery = query
        findBackwards = backwards
        guard token != findToken else { return }
        findToken = token
        runFind()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let pendingScroll {
            webView.evaluateJavaScript("window.scrollTo(\(pendingScroll.x), \(pendingScroll.y))")
            self.pendingScroll = nil
        }
        if !findQuery.isEmpty {
            runFind()
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if isSamePageAnchor(url) {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            if Self.markdownExtensions.contains(ext) {
                openInApp(url)
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.cancel)
    }

    private func runFind() {
        guard !findQuery.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = findBackwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(findQuery, configuration: configuration) { [weak self] result in
            self?.onFindResult?(result.matchFound)
        }
    }

    private func isSamePageAnchor(_ url: URL) -> Bool {
        guard let fragment = url.fragment, !fragment.isEmpty else { return false }
        if url.scheme == "about" { return true }
        guard let base = baseURL?.standardizedFileURL else { return false }
        let target = url.standardizedFileURL
        return normalizedPath(target) == normalizedPath(base)
    }

    private func normalizedPath(_ url: URL) -> String {
        var path = url.path
        if path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func openInApp(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: hostAppURL(), configuration: configuration)
    }

    private func hostAppURL() -> URL {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "appex" {
            return bundle
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        return bundle
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]

    private static func point(from value: Any?) -> CGPoint? {
        if let dictionary = value as? [String: Double] {
            return CGPoint(x: dictionary["x"] ?? 0, y: dictionary["y"] ?? 0)
        }
        if let dictionary = value as? [String: NSNumber] {
            return CGPoint(x: dictionary["x"]?.doubleValue ?? 0, y: dictionary["y"]?.doubleValue ?? 0)
        }
        return nil
    }
}

public struct MarkdownWebView: NSViewRepresentable {
    public var html: String
    public var baseURL: URL?
    public var pageZoom: CGFloat
    public var findToken: Int
    public var findQuery: String
    public var findBackwards: Bool
    public var onFindResult: (Bool) -> Void

    public init(
        html: String,
        baseURL: URL?,
        pageZoom: CGFloat,
        findToken: Int,
        findQuery: String,
        findBackwards: Bool,
        onFindResult: @escaping (Bool) -> Void = { _ in }
    ) {
        self.html = html
        self.baseURL = baseURL
        self.pageZoom = pageZoom
        self.findToken = findToken
        self.findQuery = findQuery
        self.findBackwards = findBackwards
        self.onFindResult = onFindResult
    }

    public func makeCoordinator() -> MarkdownWebController {
        let controller = MarkdownWebController()
        controller.onFindResult = onFindResult
        return controller
    }

    public func makeNSView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        let controller = context.coordinator
        controller.onFindResult = onFindResult
        controller.setZoom(pageZoom)
        controller.load(html: html, baseURL: baseURL)
        controller.find(findQuery, token: findToken, backwards: findBackwards)
    }
}
