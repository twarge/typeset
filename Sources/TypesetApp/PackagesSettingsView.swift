// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TypesetCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// The Typst packages the compiler has on hand: the ones Typeset ships, the
/// ones a document made it download, and any the user has put in their place.
///
/// Reached from the bottom of Settings. Most people never need it; it exists
/// so that anyone can read a package's licence, get its source, and run a
/// modified copy, which some of those licences require Typeset to allow.
struct PackagesSettingsView: View {
    var onDismiss: () -> Void

    @State private var packages: [TypstInstalledPackage] = []
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(packages) { package in
                        NavigationLink(value: package.spec) {
                            PackageRow(package: package)
                        }
                    }
                } footer: {
                    Text("Typeset includes the packages its sample document uses and downloads others from Typst Universe when a document imports them. Each package is its author's work under its own license. Choose one to read its license, get its source, or replace it with your own version.")
                }
            }
            .navigationTitle("Typst Packages")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: TypstPackageSpec.self) { spec in
                if let package = packages.first(where: { $0.spec == spec }) {
                    PackageDetailView(package: package, perform: perform)
                } else {
                    ContentUnavailableView("Package Removed", systemImage: "shippingbox")
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
            .overlay {
                if packages.isEmpty {
                    ContentUnavailableView(
                        "No Packages",
                        systemImage: "shippingbox",
                        description: Text("Packages appear here once a document imports them.")
                    )
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 560)
        #endif
        .task { reload() }
        .alert(
            "Couldn’t Change the Package",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var library: TypstPackageLibrary? {
        guard let storage = try? TypstPackageStorage.appSupportStorage() else { return nil }
        try? storage.createDirectories()
        return TypstPackageLibrary(storage: storage)
    }

    private func reload() {
        packages = library?.packages() ?? []
    }

    /// Runs one change to the library, then tells open documents to compile
    /// against the result.
    private func perform(_ change: (TypstPackageLibrary) throws -> Void) {
        guard let library else { return }
        do {
            try change(library)
            NotificationCenter.default.post(name: .typstPackagesDidChange, object: nil)
        } catch {
            failure = error.localizedDescription
        }
        reload()
    }
}

private struct PackageRow: View {
    var package: TypstInstalledPackage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(package.spec.name) \(package.spec.version)")
                Text(package.manifest?.license ?? "License not stated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(package.statusTitle)
                .font(.caption)
                .foregroundStyle(package.isReplaced ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PackageDetailView: View {
    var package: TypstInstalledPackage
    var perform: ((TypstPackageLibrary) throws -> Void) -> Void

    @State private var isChoosingReplacement = false
    @State private var licenseText = ""
    #if os(iOS) || os(visionOS)
    @State private var isExporting = false
    #endif

    var body: some View {
        Form {
            Section {
                LabeledContent("Import", value: package.spec.description)
                LabeledContent("License", value: package.manifest?.license ?? "Not stated")
                LabeledContent("Status", value: package.statusDetail)
            } footer: {
                if let summary = package.manifest?.summary {
                    Text(summary)
                }
            }

            Section("Source") {
                ForEach(package.links) { link in
                    Link(destination: link.url) {
                        LabeledContent(link.title) {
                            Text(link.url.host() ?? link.url.absoluteString)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                #if os(macOS)
                Button("Show Files in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([package.directoryURL])
                }
                #else
                Button("Export Files…") { isExporting = true }
                #endif
            }

            Section {
                Button(package.isReplaced ? "Replace Again with Folder…" : "Replace with Folder…") {
                    isChoosingReplacement = true
                }
                if package.isReplaced {
                    Button("Revert to Original") {
                        perform { try $0.revert(package.spec) }
                    }
                }
                if package.canDelete {
                    Button("Delete", role: .destructive) {
                        perform { try $0.delete(package) }
                    }
                }
            } header: {
                Text("Your Version")
            } footer: {
                Text("To use a modified version, choose a folder holding the package with the same name and version in its typst.toml. Typeset copies it and uses it in place of the original, which stays available to revert to.")
            }

            Section("License") {
                Text(licenseText.isEmpty ? "This package has no license file." : licenseText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(package.spec.name)
        .task(id: package) { licenseText = package.fullLicenseText }
        .fileImporter(isPresented: $isChoosingReplacement, allowedContentTypes: [.folder]) { result in
            guard case let .success(folder) = result else { return }
            perform { library in
                let isScoped = folder.startAccessingSecurityScopedResource()
                defer { if isScoped { folder.stopAccessingSecurityScopedResource() } }
                try library.replace(package.spec, withContentsOf: folder)
            }
        }
        #if os(iOS) || os(visionOS)
        .fileExporter(
            isPresented: $isExporting,
            document: PackageFolderDocument(url: package.directoryURL),
            contentType: .folder,
            defaultFilename: "\(package.spec.name)-\(package.spec.version)"
        ) { _ in }
        #endif
    }
}

private extension TypstInstalledPackage {
    var statusTitle: String {
        if isReplaced { return "Replaced" }
        switch origin {
        case .bundled: return "Included"
        case .downloaded: return "Downloaded"
        case .local: return "Local"
        }
    }

    var statusDetail: String {
        if isReplaced { return "Replaced with your version" }
        switch origin {
        case .bundled: return "Included with Typeset"
        case .downloaded: return "Downloaded from Typst Universe"
        case .local: return "Installed locally"
        }
    }

    /// The package's own licence files, followed by the licence texts they
    /// refer to without carrying: the LGPL builds on the GPL, and Graphviz
    /// inside diagraph-layout has a licence of its own.
    var fullLicenseText: String {
        var sections = [licenseText()]
        if manifest?.license?.contains("LGPL") == true {
            sections.append(Self.bundledText("GPL-3.0"))
        }
        if spec.name == "diagraph-layout" {
            sections.append(Self.bundledText("EPL-2.0", heading: "Graphviz, contained in diagraph.wasm, is under this license:"))
        }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n\n")
    }

    private static func bundledText(_ name: String, heading: String? = nil) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.map { "\($0)\n\n\(body)" } ?? body
    }
}

#if os(iOS) || os(visionOS)
/// A package folder, for saving a copy to Files.
private struct PackageFolderDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }

    var url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}
#endif
