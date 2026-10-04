// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import CoreText
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

#if os(iOS)
/// Two panes side by side, divided by a separator the user drags to share
/// the width between them. On iPhone Duo folded like a book, the separator
/// sits on the fold instead, so each pane keeps to its own side of it.
struct PaneSplit<Leading: View, Trailing: View>: View {
    /// The leading pane's share of the width.
    @Binding var fraction: Double
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    /// The live share while a drag is under way. It's committed to `fraction`
    /// when the drag ends, so the stored value isn't rewritten every frame.
    @State private var dragFraction: Double?
    @State private var dragStartWidth: CGFloat?

    private static var minimumPaneWidth: CGFloat { 220 }
    /// The strip centered on the separator that picks up a drag.
    private static var handleWidth: CGFloat { 20 }
    private static var coordinateSpaceName: String { "PaneSplit" }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fold = Self.fold(in: proxy)
            let leadingWidth = fold?.minX ?? Self.leadingWidth(for: dragFraction ?? fraction, in: width)

            HStack(spacing: 0) {
                leading
                    .frame(width: leadingWidth)
                Divider()
                    .frame(width: fold?.width)
                    .overlay {
                        // Folded, the separator belongs to the hinge.
                        if fold == nil {
                            dragHandle(leadingWidth: leadingWidth, totalWidth: width)
                        }
                    }
                    // Above the trailing pane, so the handle's overhang
                    // there still picks up touches.
                    .zIndex(1)
                trailing
            }
            .coordinateSpace(.named(Self.coordinateSpaceName))
            .animation(.snappy(duration: 0.24), value: fold)
        }
    }

    private func dragHandle(leadingWidth: CGFloat, totalWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: Self.handleWidth)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 5, height: 40)
            }
            .gesture(
                DragGesture(coordinateSpace: .named(Self.coordinateSpaceName))
                    .onChanged { value in
                        let startWidth = dragStartWidth ?? leadingWidth
                        dragStartWidth = startWidth
                        dragFraction = (startWidth + value.translation.width) / totalWidth
                    }
                    .onEnded { _ in
                        if let dragFraction {
                            fraction = Self.leadingWidth(for: dragFraction, in: totalWidth) / totalWidth
                        }
                        dragFraction = nil
                        dragStartWidth = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Pane Divider")
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.05 : direction == .decrement ? -0.05 : 0
                fraction = Self.leadingWidth(for: fraction + step, in: totalWidth) / totalWidth
            }
    }

    /// The leading pane's width for a share of the total, leaving both panes
    /// at least the minimum width, or an even split when there isn't room
    /// for that.
    private static func leadingWidth(for fraction: Double, in totalWidth: CGFloat) -> CGFloat {
        guard totalWidth >= 2 * minimumPaneWidth else { return totalWidth / 2 }
        return min(max(totalWidth * fraction, minimumPaneWidth), totalWidth - minimumPaneWidth)
    }

    /// The fold, in local coordinates, while the device is folded like a
    /// book: an active division region running top to bottom with room for
    /// a pane on either side. Flat, the region is inactive and isn't reported.
    private static func fold(in proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        let totalWidth = proxy.size.width
        return proxy.reservedRegions(kind: .division)
            .map(\.frame)
            .first { frame in
                frame.height > frame.width
                    && frame.minX >= minimumPaneWidth
                    && frame.maxX <= totalWidth - minimumPaneWidth
            }
    }
}
#endif

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

    var body: some View {
        Group {
            if file.isImageAsset {
                PackageImagePreview(file: file)
            } else if file.isFontAsset {
                PackageFontPreview(file: file)
            } else {
                QuickLookFilePreview(file: file)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Font preview. macOS embeds the system Quick Look specimen; iOS Quick Look
/// has no generator for fonts, so it renders its own specimen with CoreText.
struct PackageFontPreview: View {
    var file: PackageFile

    var body: some View {
        #if os(macOS)
        QuickLookFilePreview(file: file)
        #else
        FontSpecimenPreview(file: file)
        #endif
    }
}

/// Writes the file's bytes to a temporary file and shows the system Quick Look
/// preview for it.
struct QuickLookFilePreview: View {
    var file: PackageFile

    @State private var previewURL: URL?
    @State private var previewError: String?

    var body: some View {
        Group {
            if let previewURL {
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
            preparePreviewFile()
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

/// Renders a font's faces directly from the package bytes with CoreText, no
/// registration or temporary file needed. A collection (`.ttc`/`.otc`) yields
/// one section per face.
struct FontSpecimenPreview: View {
    var file: PackageFile

    private struct Face: Identifiable {
        var id: Int
        var name: String
        var descriptor: CTFontDescriptor
    }

    @State private var faces: [Face] = []
    @State private var didLoad = false

    private static let alphabet = """
    ABCDEFGHIJKLMNOPQRSTUVWXYZ
    abcdefghijklmnopqrstuvwxyz
    0123456789 .,;:!?&@#%()[]{}
    """
    private static let pangram = "How vexingly quick daft zebras jump!"

    var body: some View {
        Group {
            if !faces.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(faces) { face in
                            specimen(for: face)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            } else if didLoad {
                ContentUnavailableView(file.name, systemImage: "textformat", description: Text("The font could not be read."))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(file.path)-\(file.data.count)-\(file.data.hashValue)") {
            let descriptors = CTFontManagerCreateFontDescriptorsFromData(file.data as CFData) as? [CTFontDescriptor] ?? []
            faces = descriptors.enumerated().map { index, descriptor in
                let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
                return Face(id: index, name: CTFontCopyDisplayName(font) as String, descriptor: descriptor)
            }
            didLoad = true
        }
    }

    private func specimen(for face: Face) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(face.name)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(Self.alphabet)
                .font(font(for: face, size: 22))

            ForEach([28, 18, 13], id: \.self) { size in
                Text(Self.pangram)
                    .font(font(for: face, size: CGFloat(size)))
            }
        }
    }

    private func font(for face: Face, size: CGFloat) -> Font {
        Font(CTFontCreateWithFontDescriptor(face.descriptor, size, nil))
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

    /// The formats the embedded compiler picks up as project fonts.
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    var isFontAsset: Bool {
        Self.fontExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Files shown in the sidebar's preview popover rather than opened in the
    /// editor or the main asset preview.
    var isPopoverPreviewable: Bool {
        isImageAsset || isPDF || isFontAsset
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
}
