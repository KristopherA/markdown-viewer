import SwiftUI

@main
struct MarkdownViewerApp: App {
    // App Nap otherwise defers main-queue work while the window is in the background,
    // so a file an agent rewrites would not reload until the app is clicked.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated],
        reason: "Reloading the open Markdown file"
    )

    var body: some Scene {
        DocumentGroup(viewing: MarkdownFile.self) { configuration in
            ViewerView(document: configuration.document, fileURL: configuration.fileURL)
        }
        .commands {
            ViewerCommands()
        }
    }
}

private struct ViewerCommands: Commands {
    @FocusedValue(\.viewerActions) private var actions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Find…") { actions?.find() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button("Find Next") { actions?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(actions == nil)
            Button("Find Previous") { actions?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { actions?.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(actions == nil)
            Button("Zoom Out") { actions?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions == nil)
            Button("Actual Size") { actions?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(actions == nil)
        }
    }
}
