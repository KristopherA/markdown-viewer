import Foundation
import MarkdownRendering
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown")
}

struct MarkdownFile: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownDocument] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = MarkdownRenderer.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
