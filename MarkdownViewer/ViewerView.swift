import MarkdownRendering
import SwiftUI

struct ViewerActions {
    var find: () -> Void
    var findNext: () -> Void
    var findPrevious: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var resetZoom: () -> Void
}

private struct ViewerActionsKey: FocusedValueKey {
    typealias Value = ViewerActions
}

extension FocusedValues {
    var viewerActions: ViewerActions? {
        get { self[ViewerActionsKey.self] }
        set { self[ViewerActionsKey.self] = newValue }
    }
}

struct ViewerView: View {
    let document: MarkdownFile
    let fileURL: URL?

    @State private var html = ""
    @State private var baseURL: URL?
    @State private var pageZoom: CGFloat = 1
    @State private var findPresented = false
    @State private var findText = ""
    @State private var findToken = 0
    @State private var findBackwards = false
    @State private var findStatus = ""
    @State private var sourceText = ""
    @State private var reloadInFlight = false
    @State private var reloadQueued = false
    @State private var loadGeneration = 0
    @State private var watcher = FileChangeCenter()
    @FocusState private var findFocused: Bool

    var body: some View {
        MarkdownWebView(
            html: html,
            baseURL: baseURL,
            pageZoom: pageZoom,
            findToken: findToken,
            findQuery: findText,
            findBackwards: findBackwards,
            onFindResult: { found in
                findStatus = findText.isEmpty || found ? "" : "Not found"
            }
        )
        .overlay(alignment: .topTrailing) {
            if findPresented {
                findBar
                    .padding(12)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .focusedValue(\.viewerActions, actions)
        .onAppear(perform: loadInitial)
        .onDisappear { watcher.stop() }
        .onChange(of: fileURL) { _, _ in
            loadInitial()
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            TextField("Find", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($findFocused)
                .onSubmit { runFind(backwards: false) }
            if !findStatus.isEmpty {
                Text(findStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button { runFind(backwards: true) } label: {
                Image(systemName: "chevron.up")
            }
            .help("Find Previous")
            Button { runFind(backwards: false) } label: {
                Image(systemName: "chevron.down")
            }
            .help("Find Next")
            Button {
                findPresented = false
                findStatus = ""
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close Find")
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { findFocused = true }
        .onChange(of: findText) { _, _ in
            runFind(backwards: false)
        }
    }

    private var actions: ViewerActions {
        ViewerActions(
            find: {
                findPresented = true
                findFocused = true
            },
            findNext: {
                findPresented = true
                runFind(backwards: false)
            },
            findPrevious: {
                findPresented = true
                runFind(backwards: true)
            },
            zoomIn: { pageZoom = min(pageZoom * 1.1, 3) },
            zoomOut: { pageZoom = max(pageZoom / 1.1, 0.5) },
            resetZoom: { pageZoom = 1 }
        )
    }

    private func runFind(backwards: Bool) {
        findBackwards = backwards
        findToken += 1
    }

    private func loadInitial() {
        watcher.stop()
        loadGeneration += 1
        let generation = loadGeneration
        let url = fileURL
        let fallback = document.text
        let accessing = url?.startAccessingSecurityScopedResource() ?? false
        // Dispatch, not Task: a task created during the first layout pass was running
        // the render on the main thread, and reading a Desktop image from there never returned.
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = Self.renderDocument(url: url, fallback: fallback, inlineImages: false)
            DispatchQueue.main.async {
                if accessing, let url {
                    url.stopAccessingSecurityScopedResource()
                }
                guard generation == self.loadGeneration else { return }
                self.baseURL = rendered.directory
                self.sourceText = rendered.text
                self.html = rendered.html
                if let url {
                    self.watcher.watch(url) { self.scheduleReload() }
                }
                let text = rendered.text
                DispatchQueue.global(qos: .userInitiated).async {
                    let withImages = Self.renderDocument(url: url, fallback: text, inlineImages: true)
                    DispatchQueue.main.async {
                        guard generation == self.loadGeneration else { return }
                        self.html = withImages.html
                    }
                }
            }
        }
    }

    private func scheduleReload() {
        watcher.debounce?.cancel()
        watcher.debounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            reloadFromDisk()
        }
    }

    private func reloadFromDisk() {
        guard let fileURL else { return }
        if reloadInFlight {
            reloadQueued = true
            return
        }
        reloadInFlight = true
        let previous = sourceText
        let directory = fileURL.deletingLastPathComponent()
        let accessing = fileURL.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered: (text: String, html: String)?
            if let text = Self.contents(of: fileURL), text != previous {
                let page = Self.renderDocument(url: fileURL, fallback: text, inlineImages: true)
                rendered = (text, page.html)
            } else {
                rendered = nil
            }
            DispatchQueue.main.async {
                if accessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
                if let rendered {
                    self.sourceText = rendered.text
                    self.html = rendered.html
                    self.baseURL = directory
                }
                self.reloadInFlight = false
                if self.reloadQueued {
                    self.reloadQueued = false
                    self.reloadFromDisk()
                }
            }
        }
    }

    nonisolated private static func renderDocument(url: URL?, fallback: String, inlineImages: Bool) -> (directory: URL?, text: String, html: String) {
        let directory = url?.deletingLastPathComponent()
        let text = url.flatMap(contents(of:)) ?? fallback
        let base = directory ?? URL(fileURLWithPath: "/")
        let html = (try? MarkdownRenderer.render(markdown: text, mode: .document(baseURL: base), inlineImages: inlineImages).html) ?? errorHTML
        return (directory, text, html)
    }

    nonisolated private static func contents(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return MarkdownRenderer.decode(data)
    }

    private static let errorHTML = """
    <!DOCTYPE html><html><body style="font: 14px -apple-system; padding: 24px;">
    This file could not be rendered.
    </body></html>
    """
}

final class FileChangeCenter {
    var debounce: Task<Void, Never>?
    private var source: DispatchSourceFileSystemObject?

    func watch(_ url: URL, onChange: @escaping () -> Void) {
        source?.cancel()
        source = nil
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let flags = source.data
            DispatchQueue.main.async {
                onChange()
                if flags.contains(.delete) || flags.contains(.rename) {
                    self?.watch(url, onChange: onChange)
                }
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
    }
}
