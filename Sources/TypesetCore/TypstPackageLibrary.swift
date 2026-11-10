// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Typst Universe packages Typeset ships, so the sample document renders
/// without a network.
///
/// They sit in `TypesetCore.framework` exactly as published, and are copied
/// into the package cache before the first compile. The compiler never reads
/// them from the bundle: it looks in the user's local package folder first and
/// the cache second, which is what lets someone swap in their own build of a
/// package (`TypstPackageLibrary.replace`). Several are under licences that
/// require exactly that.
public enum TypstBundledPackages {
    /// The bundled package directory (`<namespace>/<name>/<version>` beneath
    /// it), or `nil` in builds that don't carry it.
    public static let directoryURL: URL? = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.resourceURL?.appending(path: "TypstPackages", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }()

    /// Copies every bundled package the cache lacks into it. A package already
    /// there is left alone, since a published version never changes. Failures
    /// are swallowed, because the compiler falls back to downloading.
    public static func seed(
        cacheURL: URL,
        from bundledURL: URL? = directoryURL,
        fileManager: FileManager = .default
    ) {
        guard let bundledURL else { return }
        for (spec, source) in TypstPackageLibrary.scan(bundledURL, fileManager: fileManager) {
            let destination = spec.directory(in: cacheURL)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? TypstPackageLibrary.install(
                source,
                at: destination,
                skippingNames: [],
                fileManager: fileManager
            )
        }
    }

    /// `seed`, once per cache directory per process. Every compile passes
    /// through here, so the repeat calls have to cost nothing.
    static func seedOnce(cacheURL: URL, fileManager: FileManager) {
        let key = cacheURL.standardizedFileURL.path
        seededLock.lock()
        let isFirst = seededPaths.insert(key).inserted
        if isFirst {
            // Held across the copy, so a second compile starting meanwhile
            // waits for the packages instead of downloading them.
            seed(cacheURL: cacheURL, fileManager: fileManager)
        }
        seededLock.unlock()
    }

    private static let seededLock = NSLock()
    nonisolated(unsafe) private static var seededPaths: Set<String> = []
}

private final class BundleToken {}

/// `@namespace/name:version`.
public struct TypstPackageSpec: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var namespace: String
    public var name: String
    public var version: String

    public init(namespace: String, name: String, version: String) {
        self.namespace = namespace
        self.name = name
        self.version = version
    }

    public var description: String { "@\(namespace)/\(name):\(version)" }

    func directory(in root: URL) -> URL {
        root
            .appending(path: namespace, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
            .appending(path: version, directoryHint: .isDirectory)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if lhs.version != rhs.version {
            return lhs.version.compare(rhs.version, options: .numeric) == .orderedAscending
        }
        return lhs.namespace < rhs.namespace
    }
}

/// The `[package]` table of a `typst.toml`, as far as Typeset shows it.
public struct TypstPackageManifest: Hashable, Sendable {
    public var name: String
    public var version: String
    public var license: String?
    public var repository: String?
    public var homepage: String?
    public var summary: String?

    /// Reads the single-line string keys of the `[package]` table. That is
    /// everything Typst Universe requires a manifest to carry, so a full TOML
    /// parser would buy nothing here.
    public init?(toml: String) {
        var values: [String: String] = [:]
        var table = ""
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = line
                    .prefix { $0 != "#" }
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
                continue
            }
            guard table == "package", let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard values[key] == nil, let value = Self.basicString(rest) else { continue }
            values[key] = value
        }

        guard let name = values["name"], let version = values["version"],
              !name.isEmpty, !version.isEmpty
        else { return nil }
        self.name = name
        self.version = version
        license = values["license"]
        repository = values["repository"]
        homepage = values["homepage"]
        summary = values["description"]
    }

    public init?(directory: URL) {
        let url = directory.appending(path: "typst.toml", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(toml: String(decoding: data, as: UTF8.self))
    }

    /// The contents of a `"…"` or `'…'` string at the start of `text`.
    private static func basicString(_ text: String) -> String? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var result = ""
        var isEscaped = false
        for character in text.dropFirst() {
            if isEscaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                isEscaped = false
            } else if character == "\\", quote == "\"" {
                isEscaped = true
            } else if character == quote {
                // An empty string followed by another quote opens a multi-line
                // string, which this reader doesn't follow.
                return result.isEmpty && text.dropFirst(2).first == quote ? nil : result
            } else {
                result.append(character)
            }
        }
        return nil
    }
}

/// Somewhere a package's source can be read or fetched.
public struct TypstPackageLink: Identifiable, Hashable, Sendable {
    public var title: String
    public var url: URL
    public var id: URL { url }
}

/// One package version the compiler can currently resolve.
public struct TypstInstalledPackage: Identifiable, Hashable, Sendable {
    public enum Origin: Sendable {
        /// Shipped inside Typeset.
        case bundled
        /// Fetched from Typst Universe when a document imported it.
        case downloaded
        /// Only in the user's local package folder.
        case local
    }

    public var spec: TypstPackageSpec
    /// Where the copy underneath any replacement came from.
    public var origin: Origin
    /// The user's own copy is in use in place of the bundled or downloaded one.
    public var isReplaced: Bool
    /// The copy the compiler reads.
    public var directoryURL: URL
    public var manifest: TypstPackageManifest?

    public var id: TypstPackageSpec { spec }

    /// Whether removing it does anything lasting. A bundled package would
    /// simply be copied back, so there it is only its replacement that goes.
    public var canDelete: Bool { !isReplaced && origin != .bundled }

    /// Where to get the source: the author's repository, the exact files as
    /// published, and the upstream of any third-party code compiled into it.
    public var links: [TypstPackageLink] {
        var links: [TypstPackageLink] = []
        func add(_ title: String, _ string: String?) {
            guard let string, let url = URL(string: string), url.scheme?.hasPrefix("http") == true,
                  !links.contains(where: { $0.url == url })
            else { return }
            links.append(TypstPackageLink(title: title, url: url))
        }

        add("Source Repository", manifest?.repository)
        if spec.namespace == "preview" {
            add(
                "Files as Published",
                "https://github.com/typst/packages/tree/main/packages/preview/\(spec.name)/\(spec.version)"
            )
            add("Typst Universe", "https://typst.app/universe/package/\(spec.name)")
        }
        add("Homepage", manifest?.homepage)
        for component in Self.embeddedComponents[spec.name] ?? [] {
            add(component.title, component.url)
        }
        return links
    }

    /// Third-party code compiled into a package's WebAssembly plugin, which
    /// its own repository link doesn't lead to.
    private static let embeddedComponents: [String: [(title: String, url: String)]] = [
        "diagraph-layout": [
            ("Graphviz Source (EPL 2.0)", "https://gitlab.com/graphviz/graphviz")
        ]
    ]

    /// The licence and notice files in the package's top level, joined.
    public func licenseText(fileManager: FileManager = .default) -> String {
        let prefixes = ["license", "licence", "copying", "notice"]
        let names = (try? fileManager.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        let files = names
            .filter { name in prefixes.contains { name.lowercased().hasPrefix($0) } }
            .sorted()
        let sections = files.compactMap { name -> String? in
            let url = directoryURL.appending(path: name, directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return files.count > 1 ? "\(name)\n\n\(text)" : text
        }
        return sections.joined(separator: "\n\n\n")
    }
}

public enum TypstPackageLibraryError: LocalizedError, Equatable {
    case missingManifest
    case mismatch(expected: TypstPackageSpec, foundName: String, foundVersion: String)

    public var errorDescription: String? {
        switch self {
        case .missingManifest:
            "That folder has no readable typst.toml, so it isn't a Typst package."
        case let .mismatch(expected, foundName, foundVersion):
            "That folder holds \(foundName) \(foundVersion). A replacement for \(expected.name) \(expected.version) has to carry the same name and version in its typst.toml, because that is how documents import it."
        }
    }
}

/// What the compiler can resolve without downloading, and the means to swap a
/// package for the user's own copy.
///
/// Nothing here is new machinery in the compiler. It reads a local package
/// folder ahead of the download cache, so a copy placed there wins; this type
/// lists both folders and moves files between them.
public struct TypstPackageLibrary: Sendable {
    public var storage: TypstPackageStorage
    public var bundledURL: URL?

    public init(storage: TypstPackageStorage, bundledURL: URL? = TypstBundledPackages.directoryURL) {
        self.storage = storage
        self.bundledURL = bundledURL
    }

    public func packages(fileManager: FileManager = .default) -> [TypstInstalledPackage] {
        let local = Self.scan(storage.localPackagesURL, fileManager: fileManager)
        let cache = Self.scan(storage.packageCacheURL, fileManager: fileManager)
        let bundled = bundledURL.map { Set(Self.scan($0, fileManager: fileManager).keys) } ?? []

        return Set(local.keys).union(cache.keys).sorted().compactMap { spec in
            guard let directory = local[spec] ?? cache[spec] else { return nil }
            let origin: TypstInstalledPackage.Origin =
                if cache[spec] == nil { .local } else if bundled.contains(spec) { .bundled } else { .downloaded }
            return TypstInstalledPackage(
                spec: spec,
                origin: origin,
                isReplaced: local[spec] != nil && cache[spec] != nil,
                directoryURL: directory,
                manifest: TypstPackageManifest(directory: directory)
            )
        }
    }

    /// Puts the package in `folder` in front of the bundled or downloaded copy
    /// of `spec`. The original is untouched, so `revert` brings it back.
    public func replace(
        _ spec: TypstPackageSpec,
        withContentsOf folder: URL,
        fileManager: FileManager = .default
    ) throws {
        guard let manifest = TypstPackageManifest(directory: folder) else {
            throw TypstPackageLibraryError.missingManifest
        }
        guard manifest.name == spec.name, manifest.version == spec.version else {
            throw TypstPackageLibraryError.mismatch(
                expected: spec,
                foundName: manifest.name,
                foundVersion: manifest.version
            )
        }
        try Self.install(
            folder,
            at: spec.directory(in: storage.localPackagesURL),
            // A checkout's history is no part of the package, and can dwarf it.
            skippingNames: [".git", ".DS_Store"],
            fileManager: fileManager
        )
    }

    /// Removes the user's replacement, returning to the original copy.
    public func revert(_ spec: TypstPackageSpec, fileManager: FileManager = .default) throws {
        try remove(spec, from: storage.localPackagesURL, fileManager: fileManager)
    }

    /// Removes a downloaded or local-only package. A downloaded one is fetched
    /// again the next time a document imports it.
    public func delete(_ package: TypstInstalledPackage, fileManager: FileManager = .default) throws {
        guard package.canDelete else { return }
        let root = package.origin == .local ? storage.localPackagesURL : storage.packageCacheURL
        try remove(package.spec, from: root, fileManager: fileManager)
    }

    private func remove(_ spec: TypstPackageSpec, from root: URL, fileManager: FileManager) throws {
        let directory = spec.directory(in: root)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)

        // Leave no empty name or namespace folder behind.
        var parent = directory.deletingLastPathComponent()
        for _ in 0..<2 {
            guard (try? fileManager.contentsOfDirectory(atPath: parent.path))?.isEmpty == true else { break }
            try? fileManager.removeItem(at: parent)
            parent = parent.deletingLastPathComponent()
        }
    }

    /// Every `<namespace>/<name>/<version>` directory under `root`.
    static func scan(_ root: URL, fileManager: FileManager) -> [TypstPackageSpec: URL] {
        func directories(in url: URL) -> [URL] {
            let children = (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            return children.filter { child in
                // Dot-names are the half-written copies `install` and the
                // compiler's own downloader leave while they work.
                !child.lastPathComponent.hasPrefix(".")
                    && (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        }

        var found: [TypstPackageSpec: URL] = [:]
        for namespace in directories(in: root) {
            for name in directories(in: namespace) {
                for version in directories(in: name) {
                    let spec = TypstPackageSpec(
                        namespace: namespace.lastPathComponent,
                        name: name.lastPathComponent,
                        version: version.lastPathComponent
                    )
                    found[spec] = version
                }
            }
        }
        return found
    }

    /// Copies `source` to `destination` by way of a hidden sibling, so the
    /// compiler never finds a package half there.
    static func install(
        _ source: URL,
        at destination: URL,
        skippingNames: Set<String>,
        fileManager: FileManager
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            for name in try fileManager.contentsOfDirectory(atPath: source.path)
            where !skippingNames.contains(name) {
                try fileManager.copyItem(
                    at: source.appending(path: name),
                    to: staging.appending(path: name)
                )
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}

public extension Notification.Name {
    /// Posted after a package is replaced, reverted or deleted, so open
    /// documents compile again against what is there now.
    static let typstPackagesDidChange = Notification.Name("TypstPackagesDidChange")
}
