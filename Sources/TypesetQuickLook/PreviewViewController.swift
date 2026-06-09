// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Cocoa
@preconcurrency import QuickLookUI
import TypesetCore
import UniformTypeIdentifiers

@MainActor
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    private var sidebarView: NSView!
    private var tableView: NSTableView!
    private var contentHost: NSView!
    private var previewItems: [PreviewItem] = []

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))

        let rootStack = NSStackView()
        rootStack.orientation = .horizontal
        rootStack.alignment = .top
        rootStack.distribution = .fill
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rootStack)

        sidebarView = makeSidebarView()
        rootStack.addArrangedSubview(sidebarView)

        let detailView = makeDetailView()
        rootStack.addArrangedSubview(detailView)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: container.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: 230),
            detailView.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])

        view = container
        preferredContentSize = container.frame.size
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let model = try QuickLookPreviewModel(url: url)
            display(model)
            handler(nil)
        } catch {
            displayError(error)
            handler(nil)
        }
    }

    private func display(_ model: QuickLookPreviewModel) {
        previewItems = model.items
        sidebarView.isHidden = !model.showsSidebar
        tableView.reloadData()

        if model.showsSidebar,
           let selectedIndex = previewItems.firstIndex(where: { $0.path == model.selectedPath }) {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }

        guard let selectedItem = previewItems.first(where: { $0.path == model.selectedPath }) ?? previewItems.first else {
            displayError(TypesetPackageError.noTypstFile)
            return
        }
        display(selectedItem)
    }

    private func display(_ item: PreviewItem) {
        contentHost.subviews.forEach { $0.removeFromSuperview() }

        switch item.kind {
        case .typst:
            showText(String(decoding: item.data, as: UTF8.self), for: item)
        case .image:
            showImage(item)
        }
    }

    private func displayError(_ error: Error) {
        previewItems = []
        sidebarView.isHidden = true
        tableView.reloadData()
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showText(message, for: nil)
    }

    private func showText(_ text: String, for item: PreviewItem?) {
        let scrollView = NSScrollView(frame: contentHost.bounds)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.string = text

        scrollView.documentView = textView
        addContentView(scrollView)

        if item == nil {
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        }
    }

    private func showImage(_ item: PreviewItem) {
        guard let image = NSImage(data: item.data) else {
            showText("The image could not be displayed.\n\n\(item.path)", for: item)
            return
        }

        let scrollView = NSScrollView(frame: contentHost.bounds)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let imageView = NSImageView(frame: scrollView.contentView.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.image = image
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor

        scrollView.documentView = imageView
        addContentView(scrollView)
    }

    private func addContentView(_ contentView: NSView) {
        contentHost.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    private func makeSidebarView() -> NSView {
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Package Files")
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(label)

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        sidebar.addSubview(scrollView)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),
        ])

        return sidebar
    }

    private func makeDetailView() -> NSView {
        let detail = NSView()
        detail.translatesAutoresizingMaskIntoConstraints = false

        contentHost = NSView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(contentHost)

        NSLayoutConstraint.activate([
            contentHost.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: detail.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])

        return detail
    }
}

extension PreviewViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        previewItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard previewItems.indices.contains(row) else { return nil }

        let item = previewItems[row]
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("PreviewItemCell")

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.contentTintColor = item.isMain ? .controlAccentColor : .secondaryLabelColor
        iconView.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
        cell.addSubview(iconView)

        let textField = NSTextField(labelWithString: item.path)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingMiddle
        textField.font = .preferredFont(forTextStyle: .body)
        textField.toolTip = item.subtitle
        cell.addSubview(textField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard previewItems.indices.contains(row) else { return }
        display(previewItems[row])
    }
}

private struct QuickLookPreviewModel {
    var items: [PreviewItem]
    var selectedPath: String
    var showsSidebar: Bool

    init(url: URL) throws {
        if url.pathExtension.lowercased() == "typ" {
            let data = try Data(contentsOf: url)
            let item = PreviewItem(
                path: url.lastPathComponent,
                data: data,
                kind: .typst,
                isMain: true
            )
            items = [item]
            selectedPath = item.path
            showsSidebar = false
            return
        }

        let package = try DocumentPackage(fileWrapper: FileWrapper(url: url, options: [.immediate]))
        let mainPath = package.mainTypstPath ?? package.selectedPath
        items = package.files
            .filter { PreviewItem.Kind(filePath: $0.path) != nil }
            .filter { !Self.isHiddenPackagePath($0.path) }
            .map { file in
                PreviewItem(
                    path: file.path,
                    data: file.data,
                    kind: PreviewItem.Kind(filePath: file.path)!,
                    isMain: file.path == mainPath
                )
            }
            .sorted()

        guard !items.isEmpty else {
            throw TypesetPackageError.noTypstFile
        }

        selectedPath = items.first(where: \.isMain)?.path ?? items[0].path
        showsSidebar = items.count > 1
    }

    private static func isHiddenPackagePath(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            component.hasPrefix(".")
        }
    }
}

private struct PreviewItem: Comparable {
    enum Kind: Int, Comparable {
        case typst
        case image

        init?(filePath: String) {
            let url = URL(fileURLWithPath: filePath)
            if url.pathExtension.lowercased() == "typ" {
                self = .typst
                return
            }

            guard let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image) else {
                return nil
            }
            self = .image
        }

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var path: String
    var data: Data
    var kind: Kind
    var isMain: Bool

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var subtitle: String {
        if isMain {
            return "\(path) - compile target"
        }
        return path
    }

    var symbolName: String {
        if isMain { return "scope" }
        switch kind {
        case .typst:
            return "doc.text"
        case .image:
            return "photo"
        }
    }

    static func < (lhs: PreviewItem, rhs: PreviewItem) -> Bool {
        if lhs.isMain != rhs.isMain {
            return lhs.isMain
        }
        if lhs.kind != rhs.kind {
            return lhs.kind < rhs.kind
        }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}
