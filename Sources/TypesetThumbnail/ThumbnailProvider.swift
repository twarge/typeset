// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import PDFKit
import QuickLookThumbnailing
import TypesetCore

/// Draws the first page of a Typst document as its icon in Finder.
///
/// The document is compiled with the same embedded compiler as the editor. A
/// document that fails to compile, or that needs a package this extension has
/// not got (it has no network access), gets no thumbnail and keeps its
/// document icon.
nonisolated final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        let maximumSize = request.maximumSize
        // The handler is only ever called once, from the task below.
        nonisolated(unsafe) let handler = handler
        Task {
            do {
                let package = try Self.package(at: url)
                let data = try await TypstRenderer().previewPDF(package: package).data
                guard let page = PDFDocument(data: data)?.page(at: 0) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let pageSize = page.bounds(for: .mediaBox).size
                guard pageSize.width > 0, pageSize.height > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let scale = min(maximumSize.width / pageSize.width, maximumSize.height / pageSize.height)
                let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
                nonisolated(unsafe) let drawnPage = page
                handler(QLThumbnailReply(contextSize: size) { context in
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.fill(CGRect(origin: .zero, size: size))
                    context.scaleBy(x: scale, y: scale)
                    drawnPage.draw(with: .mediaBox, to: context)
                    return true
                }, nil)
            } catch {
                handler(nil, error)
            }
        }
    }

    private static func package(at url: URL) throws -> DocumentPackage {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return try DocumentPackage(fileWrapper: FileWrapper(url: url, options: [.immediate]))
        }
        return try DocumentPackage(files: [PackageFile(path: "main.typ", data: Data(contentsOf: url))])
    }
}
