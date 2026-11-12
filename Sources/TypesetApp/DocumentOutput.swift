// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import PDFKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Sends a compiled document to the system's print panel.
///
/// What prints is the PDF itself, at its own page size, so the paper matches
/// the preview page for page.
enum PDFPrinter {
    /// Returns `false` when there was nothing to present the panel from, or
    /// the PDF couldn't be read.
    @discardableResult
    static func print(pdfAt url: URL, jobName: String) -> Bool {
        #if os(macOS)
        guard let document = PDFDocument(url: url),
              let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo,
              let operation = document.printOperation(
                  for: printInfo,
                  scalingMode: .pageScaleDownToFit,
                  autoRotate: true
              )
        else { return false }
        operation.jobTitle = jobName
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        return true
        #else
        guard UIPrintInteractionController.canPrint(url) else { return false }
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = jobName
        info.outputType = .general
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = url
        controller.present(animated: true)
        return true
        #endif
    }
}

#if os(macOS)
/// The macOS share menu for an exported file: Mail, Messages, AirDrop and
/// whatever else the user has enabled. iOS reaches the same services through
/// the share sheet its Export button already opens.
enum PDFSharing {
    @discardableResult
    static func present(_ url: URL) -> Bool {
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { return false }
        // Anchored at the top trailing corner, under the toolbar's export
        // button, since a menu command has no view of its own to hang from.
        let anchor = NSRect(x: view.bounds.maxX - 44, y: view.bounds.maxY - 1, width: 1, height: 1)
        NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: .minY)
        return true
    }
}
#endif
