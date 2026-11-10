// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TypesetCore

private struct Sandbox {
    let root: URL
    let storage: TypstPackageStorage
    let bundled: URL
    var library: TypstPackageLibrary { TypstPackageLibrary(storage: storage, bundledURL: bundled) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "TypstPackageLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        storage = TypstPackageStorage(
            localPackagesURL: root.appending(path: "local", directoryHint: .isDirectory),
            packageCacheURL: root.appending(path: "cache", directoryHint: .isDirectory)
        )
        bundled = root.appending(path: "bundled", directoryHint: .isDirectory)
        for url in [storage.localPackagesURL, storage.packageCacheURL, bundled] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    func writePackage(
        in base: URL,
        namespace: String = "preview",
        name: String,
        version: String,
        body: String = "original",
        nested: Bool = true
    ) throws -> URL {
        let directory = nested
            ? base.appending(path: "\(namespace)/\(name)/\(version)", directoryHint: .isDirectory)
            : base
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
        [package]
        name = "\(name)"
        version = "\(version)"
        entrypoint = "lib.typ"
        license = "MIT"
        repository = "https://example.com/\(name)"
        """
        try Data(manifest.utf8).write(to: directory.appending(path: "typst.toml"))
        try Data(body.utf8).write(to: directory.appending(path: "lib.typ"))
        try Data("Licence of \(name)".utf8).write(to: directory.appending(path: "LICENSE"))
        return directory
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func manifestReadsThePackageTableOnly() throws {
    let manifest = try #require(TypstPackageManifest(toml: """
    # A comment
    [package] # trailing
    name = "cetz"
    version = '0.5.2'
    license = "LGPL-3.0-or-later"
    repository = "https://github.com/cetz-package/cetz" # where it lives
    description = "Draw \\"things\\""
    authors = ["Someone"]

    [tool.other]
    name = "not-this"
    homepage = "https://wrong.example"
    """))

    #expect(manifest.name == "cetz")
    #expect(manifest.version == "0.5.2")
    #expect(manifest.license == "LGPL-3.0-or-later")
    #expect(manifest.repository == "https://github.com/cetz-package/cetz")
    #expect(manifest.summary == "Draw \"things\"")
    #expect(manifest.homepage == nil)
    #expect(TypstPackageManifest(toml: "[package]\nname = \"x\"") == nil)
}

@Test func seedingCopiesOnlyWhatTheCacheLacks() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.writePackage(in: sandbox.bundled, name: "alpha", version: "1.0.0")
    try sandbox.writePackage(in: sandbox.bundled, name: "beta", version: "2.0.0")
    try sandbox.writePackage(in: sandbox.storage.packageCacheURL, name: "beta", version: "2.0.0", body: "already here")

    TypstBundledPackages.seed(cacheURL: sandbox.storage.packageCacheURL, from: sandbox.bundled)

    let packages = sandbox.library.packages()
    #expect(packages.map(\.spec.description) == ["@preview/alpha:1.0.0", "@preview/beta:2.0.0"])
    #expect(packages.allSatisfy { $0.origin == .bundled && !$0.isReplaced && !$0.canDelete })
    let beta = sandbox.storage.packageCacheURL.appending(path: "preview/beta/2.0.0/lib.typ")
    try #expect(String(contentsOf: beta, encoding: .utf8) == "already here")
    // No staging folders left for the compiler to trip over.
    let leftovers = try FileManager.default
        .contentsOfDirectory(atPath: sandbox.storage.packageCacheURL.appending(path: "preview/alpha").path)
    #expect(leftovers == ["1.0.0"])
}

@Test func replacingPutsTheUsersCopyInFrontAndRevertingRestoresTheOriginal() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.writePackage(in: sandbox.bundled, name: "alpha", version: "1.0.0")
    TypstBundledPackages.seed(cacheURL: sandbox.storage.packageCacheURL, from: sandbox.bundled)
    let spec = TypstPackageSpec(namespace: "preview", name: "alpha", version: "1.0.0")

    let mine = sandbox.root.appending(path: "my-alpha", directoryHint: .isDirectory)
    try sandbox.writePackage(in: mine, name: "alpha", version: "1.0.0", body: "modified", nested: false)
    try FileManager.default.createDirectory(at: mine.appending(path: ".git"), withIntermediateDirectories: true)
    try sandbox.library.replace(spec, withContentsOf: mine)

    var package = try #require(sandbox.library.packages().first)
    #expect(package.isReplaced)
    #expect(package.origin == .bundled)
    // The local folder is the one the compiler reads first.
    // Compared resolved: a listing may spell the temporary directory through
    // /private where the sandbox's own URL doesn't.
    #expect(
        package.directoryURL.resolvingSymlinksInPath().path
            .hasPrefix(sandbox.storage.localPackagesURL.resolvingSymlinksInPath().path)
    )
    try #expect(String(contentsOf: package.directoryURL.appending(path: "lib.typ"), encoding: .utf8) == "modified")
    #expect(!FileManager.default.fileExists(atPath: package.directoryURL.appending(path: ".git").path))

    // Replacing again swaps the copy rather than failing on the existing one.
    try Data("modified twice".utf8).write(to: mine.appending(path: "lib.typ"))
    try sandbox.library.replace(spec, withContentsOf: mine)
    package = try #require(sandbox.library.packages().first)
    try #expect(String(contentsOf: package.directoryURL.appending(path: "lib.typ"), encoding: .utf8) == "modified twice")

    try sandbox.library.revert(spec)
    package = try #require(sandbox.library.packages().first)
    #expect(!package.isReplaced)
    try #expect(String(contentsOf: package.directoryURL.appending(path: "lib.typ"), encoding: .utf8) == "original")
    try #expect(FileManager.default.contentsOfDirectory(atPath: sandbox.storage.localPackagesURL.path).isEmpty)
}

@Test func aReplacementMustBeTheSamePackageAndVersion() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let spec = TypstPackageSpec(namespace: "preview", name: "alpha", version: "1.0.0")

    let other = sandbox.root.appending(path: "other", directoryHint: .isDirectory)
    try sandbox.writePackage(in: other, name: "alpha", version: "1.1.0", nested: false)
    #expect(throws: TypstPackageLibraryError.mismatch(expected: spec, foundName: "alpha", foundVersion: "1.1.0")) {
        try sandbox.library.replace(spec, withContentsOf: other)
    }

    let empty = sandbox.root.appending(path: "empty", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(throws: TypstPackageLibraryError.missingManifest) {
        try sandbox.library.replace(spec, withContentsOf: empty)
    }
    #expect(sandbox.library.packages().isEmpty)
}

@Test func downloadedAndLocalPackagesCanBeDeleted() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.writePackage(in: sandbox.storage.packageCacheURL, name: "fetched", version: "0.1.0")
    try sandbox.writePackage(in: sandbox.storage.localPackagesURL, namespace: "local", name: "mine", version: "0.1.0")

    let packages = sandbox.library.packages()
    #expect(packages.map(\.origin) == [.downloaded, .local])
    #expect(packages.allSatisfy { $0.canDelete })
    for package in packages { try sandbox.library.delete(package) }

    #expect(sandbox.library.packages().isEmpty)
}

@Test func aPackageOffersItsLicenceAndWhereToGetItsSource() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.writePackage(in: sandbox.storage.packageCacheURL, name: "diagraph-layout", version: "0.0.1")

    let package = try #require(sandbox.library.packages().first)
    #expect(package.licenseText() == "Licence of diagraph-layout")
    #expect(package.links.map(\.url.absoluteString) == [
        "https://example.com/diagraph-layout",
        "https://github.com/typst/packages/tree/main/packages/preview/diagraph-layout/0.0.1",
        "https://typst.app/universe/package/diagraph-layout",
        "https://gitlab.com/graphviz/graphviz",
    ])
}

/// The point of bundling: a new document must never need the network. Every
/// package the sample document imports, and every package those import, has to
/// be in the bundle, with a licence file and a source link to show for it.
@Test func theSampleDocumentsPackagesAreAllBundled() throws {
    let bundled = try #require(
        TypstBundledPackages.directoryURL,
        "the bundled packages are missing from TypesetCore.framework"
    )
    let available = TypstPackageLibrary.scan(bundled, fileManager: .default)
    #expect(available.count == 19)

    // Only an `#import` at the start of a line: an indented one sits inside a
    // function and loads its package when that function is called (lilaq's
    // optional contour and violin plots), and the rest are in doc comments.
    let importPattern = /(?m)^#import\s+"@preview\/([a-z0-9-]+):([0-9.]+)"/
    func imports(in text: String) -> Set<TypstPackageSpec> {
        Set(text.matches(of: importPattern).map {
            TypstPackageSpec(namespace: "preview", name: String($0.1), version: String($0.2))
        })
    }
    // The sample document runs every import it has, wherever it is written.
    func sampleImports(in text: String) -> Set<TypstPackageSpec> {
        Set(text.matches(of: /import\s+"@preview\/([a-z0-9-]+):([0-9.]+)"/).map {
            TypstPackageSpec(namespace: "preview", name: String($0.1), version: String($0.2))
        })
    }

    let sample = try #require(DocumentPackage.defaultFiles().first)
    var pending = sampleImports(in: String(decoding: sample.data, as: UTF8.self))
    #expect(!pending.isEmpty)
    var seen: Set<TypstPackageSpec> = []
    while let spec = pending.popFirst() {
        guard seen.insert(spec).inserted else { continue }
        let directory = try #require(available[spec], "\(spec) is imported but not bundled")
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        // A package's manual and examples import whatever they like; only
        // what its entry point can reach matters.
        let documentation = ["manual.typ", "sample.typ"]
        for case let file as URL in files ?? .init()
        where file.pathExtension == "typ" && !documentation.contains(file.lastPathComponent)
            && !file.path.contains("/gallery/") && !file.path.contains("/docs/") {
            pending.formUnion(imports(in: try String(contentsOf: file, encoding: .utf8)))
        }
    }
    #expect(seen == Set(available.keys), "bundled but unused: \(Set(available.keys).subtracting(seen))")

    let library = TypstPackageLibrary(
        storage: TypstPackageStorage(localPackagesURL: bundled.appending(path: "none"), packageCacheURL: bundled),
        bundledURL: bundled
    )
    for package in library.packages() {
        #expect(!package.licenseText().isEmpty, "\(package.spec) has no licence file")
        #expect(package.manifest?.license != nil, "\(package.spec) states no licence")
        #expect(package.links.first?.title == "Source Repository", "\(package.spec) has no repository link")
    }
}
