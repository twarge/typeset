// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import PhotosUI
import PDFKit
import SwiftUI
import TypesetCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import QuickLookUI
#else
import UIKit
import QuickLook
#endif

struct StableSourcePane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

struct ToolbarStatusIcon: View {
    var isLogPresented: Bool
    var isCompiling: Bool
    var hasErrorLogs: Bool

    var body: some View {
        Group {
            if isLogPresented {
                Image(systemName: "xmark")
            } else if isCompiling {
                // Stop icon: keep it a plain image so the button stays part of
                // the unified toolbar group (a ProgressView renders as a bare,
                // unbordered item that visually splits the group). Tapping it
                // cancels the compile.
                Image(systemName: "stop.fill")
            } else if hasErrorLogs {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                // Run icon: the preview is up to date; tapping recompiles.
                Image(systemName: "play.fill")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isLogPresented)
        .animation(.easeInOut(duration: 0.15), value: isCompiling)
        .animation(.easeInOut(duration: 0.15), value: hasErrorLogs)
    }
}

struct PackageAssetPreview: View {
    var file: PackageFile

    @State private var previewURL: URL?
    @State private var previewError: String?

    var body: some View {
        Group {
            if file.isImageAsset {
                PackageImagePreview(file: file)
            } else if let previewURL {
                PlatformQuickLookPreview(url: previewURL)
                    .background(.background)
            } else if let previewError {
                ContentUnavailableView(file.name, systemImage: "exclamationmark.triangle", description: Text(previewError))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: previewIdentity) {
            if file.isImageAsset {
                previewURL = nil
                previewError = nil
            } else {
                preparePreviewFile()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewIdentity: String {
        "\(file.path)-\(file.data.count)-\(file.data.hashValue)"
    }

    private func preparePreviewFile() {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "TypesetAssetPreviews", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let url = directory.appending(path: file.name, directoryHint: .notDirectory)
            try file.data.write(to: url, options: .atomic)
            previewURL = url
            previewError = nil
        } catch {
            previewURL = nil
            previewError = error.localizedDescription
        }
    }
}

struct PackageImagePreview: View {
    var file: PackageFile
    var backgroundColor = Color.clear

    var body: some View {
        Group {
            if file.isPDF {
                if PDFDocument(data: file.data) != nil {
                    PackagePDFView(data: file.data)
                        .background(backgroundColor)
                } else {
                    ContentUnavailableView(file.name, systemImage: "doc.richtext", description: Text("The PDF could not be displayed."))
                }
            } else if let image = PlatformImage(data: file.data) {
                GeometryReader { proxy in
                    PlatformImageView(image: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .background(backgroundColor)
            } else {
                ContentUnavailableView(file.name, systemImage: "photo", description: Text("The image could not be displayed."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
private typealias PlatformImage = NSImage

private func PlatformImageView(image: PlatformImage) -> Image {
    Image(nsImage: image)
}

struct PlatformQuickLookPreview: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }
}

/// Renders PDF data with PDFKit's scrollable, zoomable `PDFView`. The document
/// is rebuilt only when the underlying data changes, so scroll/zoom isn't reset
/// on unrelated re-renders.
struct PackagePDFView: NSViewRepresentable {
    var data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .white
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var data: Data? }
}
#else
private typealias PlatformImage = UIImage

private func PlatformImageView(image: PlatformImage) -> Image {
    Image(uiImage: image)
}

struct PlatformQuickLookPreview: UIViewControllerRepresentable {
    var url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// Renders PDF data with PDFKit's scrollable, zoomable `PDFView`. The document
/// is rebuilt only when the underlying data changes, so scroll/zoom isn't reset
/// on unrelated re-renders.
struct PackagePDFView: UIViewRepresentable {
    var data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .white
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var data: Data? }
}
#endif

extension PackageFile {
    private var fileType: UTType? {
        guard let fileExtension = name.split(separator: ".").last,
              fileExtension != name else {
            return nil
        }
        return UTType(filenameExtension: String(fileExtension))
    }

    var isImageAsset: Bool {
        fileType?.conforms(to: .image) ?? false
    }

    var isPDF: Bool {
        fileType?.conforms(to: .pdf) ?? false
    }

    /// Files shown in the sidebar's image/PDF popover rather than opened in the
    /// editor or the main asset preview.
    var isPopoverPreviewable: Bool {
        isImageAsset || isPDF
    }

    var isPythonScript: Bool {
        path.lowercased().hasSuffix(".py")
    }
}

extension View {
    @ViewBuilder
    func platformPreferredColorScheme(_ colorScheme: ColorScheme?) -> some View {
        #if os(macOS)
        self
        #else
        self.preferredColorScheme(colorScheme)
        #endif
    }

    @ViewBuilder
    func platformTransparentToolbarBackground() -> some View {
        #if os(macOS)
        self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #else
        self
        #endif
    }
}

