#!/usr/bin/env swift
// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreText
import Foundation
import ImageIO

enum IconKind {
    case app
    case package
    case source
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetRoot = root.appending(path: "Resources/Assets.xcassets")
let appIconSet = assetRoot.appending(path: "AppIcon.appiconset")
let documentIconRoot = root.appending(path: "Resources/DocumentIcons")

let lightCMYOGV: [NSColor] = [
    NSColor(calibratedRed: 0.72, green: 0.96, blue: 1.00, alpha: 1.0),
    NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.91, alpha: 1.0),
    NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.62, alpha: 1.0),
    NSColor(calibratedRed: 1.00, green: 0.77, blue: 0.49, alpha: 1.0),
    NSColor(calibratedRed: 0.70, green: 0.96, blue: 0.72, alpha: 1.0),
    NSColor(calibratedRed: 0.78, green: 0.72, blue: 1.00, alpha: 1.0),
]

/// Near-black rather than pure black, so the outline reads as ink on the
/// pastel gradient instead of a hard system stroke.
let ink = NSColor(calibratedWhite: 0.02, alpha: 1.0)
let white = NSColor(calibratedWhite: 0.98, alpha: 1.0)

/// Libertinus Serif — the maintained continuation of Linux Libertine, and the
/// font Typst sets by default. Vendored under `Resources/Fonts/Libertinus` so
/// the icons regenerate identically on any machine.
let libertinusPostScriptName: String = {
    let url = root.appending(path: "Resources/Fonts/Libertinus/LibertinusSerif-Bold.otf")
    guard FileManager.default.fileExists(atPath: url.path),
          let provider = CGDataProvider(url: url as CFURL),
          let font = CGFont(provider),
          let name = font.postScriptName as String? else {
        fatalError("Missing Resources/Fonts/Libertinus/LibertinusSerif-Bold.otf — the icons need it")
    }
    var error: Unmanaged<CFError>?
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    return name
}()

func libertinus(size: CGFloat) -> NSFont {
    guard let font = NSFont(name: libertinusPostScriptName, size: size) else {
        fatalError("Could not instantiate \(libertinusPostScriptName) at \(size)pt")
    }
    return font
}

let gradientAngle: CGFloat = -34

func ramp(_ colors: [NSColor]) -> NSGradient {
    NSGradient(colorsAndLocations:
        (colors[0], 0.00),
        (colors[1], 0.18),
        (colors[2], 0.38),
        (colors[3], 0.55),
        (colors[4], 0.74),
        (colors[5], 1.00)
    )!
}

func gradient() -> NSGradient { ramp(lightCMYOGV) }

/// The same hues, pushed toward full saturation and darkened a little, so the
/// border reads as a deeper band of the fill rather than a different colour.
func saturated(_ color: NSColor, by factor: CGFloat = 2.7, darkenedTo brightness: CGFloat = 0.86) -> NSColor {
    guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
    var hue: CGFloat = 0, saturation: CGFloat = 0, value: CGFloat = 0, alpha: CGFloat = 0
    rgb.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha)
    return NSColor(
        calibratedHue: hue,
        saturation: min(1.0, saturation * factor),
        brightness: value * brightness,
        alpha: alpha
    )
}

func saturatedGradient() -> NSGradient { ramp(lightCMYOGV.map { saturated($0) }) }

/// Strokes a rounded rect with the gradient itself: the ring between the edge
/// and an inset copy, filled from the same rect at the same angle so the ramp
/// lines up with the fill it surrounds.
func drawGradientRing(in rect: CGRect, cornerRadius: CGFloat, width: CGFloat) {
    let ring = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    let innerRadius = max(0, cornerRadius - width)
    ring.append(NSBezierPath(
        roundedRect: rect.insetBy(dx: width, dy: width),
        xRadius: innerRadius,
        yRadius: innerRadius
    ))
    ring.windingRule = .evenOdd

    NSGraphicsContext.saveGraphicsState()
    ring.addClip()
    saturatedGradient().draw(in: rect, angle: gradientAngle)
    NSGraphicsContext.restoreGraphicsState()
}

func drawText(
    _ text: String,
    in rect: CGRect,
    font: NSFont,
    color: NSColor = ink,
    alignment: NSTextAlignment = .left
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
    NSAttributedString(string: text, attributes: attributes).draw(in: rect)
}

func drawDocumentPage(in page: CGRect, scale: CGFloat, cornerRadius: CGFloat, borderWidth: CGFloat, shadowAlpha: CGFloat = 0.18) {
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 36 * scale
    shadow.shadowOffset = CGSize(width: 0, height: -12 * scale)
    shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
    shadow.set()

    let body = NSBezierPath(roundedRect: page, xRadius: cornerRadius, yRadius: cornerRadius)
    // Filled with the same gradient as the app icon, so a document reads as a
    // sheet of the app's colour rather than a white card.
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    gradient().draw(in: page, angle: gradientAngle)
    NSGraphicsContext.restoreGraphicsState()

    NSShadow().set()
    drawGradientRing(in: page, cornerRadius: cornerRadius, width: borderWidth)
}

/// The wordmark: T, Y and P stepping down a diagonal, set in Libertinus and
/// kerned tight enough that the letters interlock.
///
/// Each letter is placed individually — a single drawn string can only sit on
/// one baseline, and tightening it this far needs negative tracking that would
/// collide without the vertical stagger to separate the glyphs.
func drawDiagonalTyp(in rect: CGRect, fill: CGFloat = 0.92) {
    let letters = ["T", "Y", "P"]
    /// Horizontal advance as a fraction of the letter's own width: under 1 the
    /// letters overlap.
    let tracking: CGFloat = 0.68
    /// Vertical step per letter, as a fraction of cap height.
    let drop: CGFloat = 0.42

    func layout(at size: CGFloat) -> (font: NSFont, origins: [CGPoint], size: CGSize) {
        let font = libertinus(size: size)
        let widths = letters.map {
            NSAttributedString(string: $0, attributes: [.font: font]).size().width
        }
        let cap = font.capHeight
        let step = cap * drop
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        for (index, width) in widths.enumerated() {
            origins.append(CGPoint(x: x, y: -CGFloat(index) * step))
            x += width * tracking
        }
        let boxWidth = origins[origins.count - 1].x + widths[widths.count - 1]
        let boxHeight = cap + step * CGFloat(letters.count - 1)
        return (font, origins, CGSize(width: boxWidth, height: boxHeight))
    }

    // Size the whole group, not one glyph, so it fills the frame on whichever
    // axis runs out first.
    let probeSize: CGFloat = 100
    let probe = layout(at: probeSize)
    let size = probeSize * min(
        rect.width * fill / probe.size.width,
        rect.height * fill / probe.size.height
    )
    let final = layout(at: size)

    // Centre the group's bounding box: it runs from the first cap top down to
    // the last baseline.
    let cap = final.font.capHeight
    let step = cap * drop
    let originX = rect.midX - final.size.width / 2
    let originY = rect.midY - (cap - step * CGFloat(letters.count - 1)) / 2

    for (index, letter) in letters.enumerated() {
        let text = NSAttributedString(string: letter, attributes: [
            .font: final.font,
            .foregroundColor: ink,
        ])
        text.draw(at: CGPoint(
            x: originX + final.origins[index].x,
            y: originY + final.origins[index].y + final.font.descender
        ))
    }
}

func renderImage(size: Int, draw: (CGFloat) -> Void) -> NSImage {
    let side = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create bitmap for \(size)x\(size) icon")
    }
    rep.size = CGSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    CGRect(x: 0, y: 0, width: side, height: side).fill()
    draw(side)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: CGSize(width: side, height: side))
    image.addRepresentation(rep)
    return image
}

func appIcon(size: Int) -> NSImage {
    renderImage(size: size) { side in
        let scale = side / 1024.0

        let rect = CGRect(x: 62 * scale, y: 62 * scale, width: 900 * scale, height: 900 * scale)
        let radius = 182 * scale
        let borderWidth = max(1.0, 58 * scale)
        let fillPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        fillPath.addClip()
        gradient().draw(in: rect, angle: gradientAngle)
        drawDiagonalTyp(in: rect.insetBy(dx: borderWidth * 1.4, dy: borderWidth * 1.4))
        NSGraphicsContext.restoreGraphicsState()

        drawGradientRing(in: rect, cornerRadius: radius, width: borderWidth)
    }
}

func documentIcon(size: Int, kind: IconKind) -> NSImage {
    renderImage(size: size) { side in
        let scale = side / 1024.0

        let page = CGRect(x: 154 * scale, y: 74 * scale, width: 716 * scale, height: 874 * scale)
        let borderWidth = max(1.0, 46 * scale)

        drawDocumentPage(in: page, scale: scale, cornerRadius: 0, borderWidth: borderWidth, shadowAlpha: 0.14)

        drawDiagonalTyp(in: CGRect(x: page.minX + borderWidth * 1.6, y: page.minY + 170 * scale, width: page.width - borderWidth * 3.2, height: page.height - 190 * scale), fill: 0.94)

        let badge = CGRect(x: page.minX + 78 * scale, y: page.minY + 64 * scale, width: page.width - 156 * scale, height: 86 * scale)
        let badgePath = NSBezierPath(roundedRect: badge, xRadius: 28 * scale, yRadius: 28 * scale)
        ink.setFill()
        badgePath.fill()

        switch kind {
        case .package:
            drawText(".typeset", in: CGRect(x: badge.minX + 18 * scale, y: badge.minY + 21 * scale, width: badge.width - 36 * scale, height: 56 * scale), font: NSFont.systemFont(ofSize: 48 * scale, weight: .bold), color: white, alignment: .center)
        case .source:
            drawText(".typ", in: CGRect(x: badge.minX + 18 * scale, y: badge.minY + 20 * scale, width: badge.width - 36 * scale, height: 58 * scale), font: NSFont.systemFont(ofSize: 50 * scale, weight: .bold), color: white, alignment: .center)
        case .app:
            break
        }
    }
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
          let data = rep.representation(using: .png, properties: [.compressionFactor: 0.92]) else {
        throw NSError(domain: "TypesetIconGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG for \(url.path)"])
    }
    try data.write(to: url, options: [.atomic])
}

func writeOpaquePNG(_ image: NSImage, to url: URL, background: NSColor = white) throws {
    guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
          let source = rep.cgImage else {
        throw NSError(domain: "TypesetIconGeneration", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read bitmap for \(url.path)"])
    }

    let width = source.width
    let height = source.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw NSError(domain: "TypesetIconGeneration", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create opaque context for \(url.path)"])
    }

    let backgroundColor = background.usingColorSpace(.deviceRGB)?.cgColor ?? CGColor(gray: 1.0, alpha: 1.0)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(backgroundColor)
    context.fill(rect)
    context.draw(source, in: rect)

    guard let flattened = context.makeImage(),
          let destinationData = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(destinationData, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "TypesetIconGeneration", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not prepare opaque PNG for \(url.path)"])
    }

    CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "TypesetIconGeneration", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not encode opaque PNG for \(url.path)"])
    }

    try (destinationData as Data).write(to: url, options: [.atomic])
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "TypesetIconGeneration", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"])
    }
}

func generateAppIcons() throws {
    let sizes = [16, 20, 29, 32, 40, 58, 60, 64, 76, 80, 87, 120, 128, 152, 167, 180, 256, 512, 1024]
    try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
    for size in sizes {
        try writeOpaquePNG(appIcon(size: size), to: appIconSet.appending(path: "Icon-\(size).png"))
    }
}

func generateDocumentIcon(name: String, kind: IconKind) throws {
    try FileManager.default.createDirectory(at: documentIconRoot, withIntermediateDirectories: true)
    try writePNG(documentIcon(size: 64, kind: kind), to: documentIconRoot.appending(path: "\(name)-64.png"))
    try writePNG(documentIcon(size: 320, kind: kind), to: documentIconRoot.appending(path: "\(name)-320.png"))
    try writePNG(documentIcon(size: 1024, kind: kind), to: documentIconRoot.appending(path: "\(name)-1024.png"))

    let iconset = documentIconRoot.appending(path: "\(name).iconset")
    if FileManager.default.fileExists(atPath: iconset.path) {
        try FileManager.default.removeItem(at: iconset)
    }
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    let iconSizes: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for (filename, size) in iconSizes {
        try writePNG(documentIcon(size: size, kind: kind), to: iconset.appending(path: filename))
    }

    try run("/usr/bin/iconutil", [
        "-c", "icns",
        "-o", documentIconRoot.appending(path: "\(name).icns").path,
        iconset.path,
    ])
    try FileManager.default.removeItem(at: iconset)
}

try generateAppIcons()
try generateDocumentIcon(name: "TypesetPackageIcon", kind: .package)
try generateDocumentIcon(name: "TypstSourceIcon", kind: .source)

print("Generated Typeset app and document icons.")
