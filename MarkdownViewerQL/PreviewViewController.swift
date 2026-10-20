import Cocoa
import MarkdownRendering
import QuickLookUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let page = MarkdownWebController()

    override func loadView() {
        view = NSView()
        page.attach(to: view)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        if page.webView.superview == nil {
            page.attach(to: view)
        }
        let directory = url.deletingLastPathComponent()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: url)
                let text = MarkdownRenderer.decode(data)
                let rendered = try MarkdownRenderer.render(markdown: text, mode: .quickLook(baseURL: directory))
                DispatchQueue.main.async {
                    self.page.load(html: rendered.html, baseURL: directory)
                    handler(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    handler(error)
                }
            }
        }
    }
}
