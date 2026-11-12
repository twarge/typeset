#!/usr/bin/env swift
// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreText
import Foundation
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetRoot = root.appending(path: "Resources/Assets.xcassets")
let appIconBundle = root.appending(path: "Resources/AppIcon.icon")
let visionIconStack = assetRoot.appending(path: "AppIcon.solidimagestack")

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

/// Where the six colours sit along the ramp.
let rampLocations: [CGFloat] = [0.00, 0.18, 0.38, 0.55, 0.74, 1.00]

func ramp(_ colors: [NSColor]) -> NSGradient {
    NSGradient(colorsAndLocations:
        (colors[0], rampLocations[0]),
        (colors[1], rampLocations[1]),
        (colors[2], rampLocations[2]),
        (colors[3], rampLocations[3]),
        (colors[4], rampLocations[4]),
        (colors[5], rampLocations[5])
    )!
}

func gradient() -> NSGradient { ramp(lightCMYOGV) }

/// The same hue, pushed toward full saturation and, by default, darkened a
/// little.
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

/// The wordmark: T, Y and P stepping down a diagonal, set in Libertinus and
/// kerned tight enough that the letters interlock. Each letter sits on its own
/// baseline: tightened this far, they would collide without the vertical
/// stagger to separate the glyphs.
let typLetters = ["T", "Y", "P"]
/// Horizontal advance as a fraction of the letter's own width: under 1 the
/// letters overlap.
let typTracking: CGFloat = 0.68
/// Vertical step per letter, as a fraction of cap height.
let typDrop: CGFloat = 0.42

/// Each letter's origin on its own baseline, relative to the first letter's,
/// and the box the group fills from the first cap top to the last baseline.
func typLayout(at size: CGFloat) -> (font: NSFont, origins: [CGPoint], size: CGSize) {
    let font = libertinus(size: size)
    let widths = typLetters.map {
        NSAttributedString(string: $0, attributes: [.font: font]).size().width
    }
    let cap = font.capHeight
    let step = cap * typDrop
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    for (index, width) in widths.enumerated() {
        origins.append(CGPoint(x: x, y: -CGFloat(index) * step))
        x += width * typTracking
    }
    let boxWidth = origins[origins.count - 1].x + widths[widths.count - 1]
    let boxHeight = cap + step * CGFloat(typLetters.count - 1)
    return (font, origins, CGSize(width: boxWidth, height: boxHeight))
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

// MARK: - App icon
//
// The app icon is drawn once, as outlines, and stored two ways. On macOS and
// iOS it is an Icon Composer bundle, Resources/AppIcon.icon: the system adds
// its own shape, glass and the dark, clear and tinted renditions, so the
// artwork is full bleed and carries no mask, ring or shadow of its own.
// visionOS takes no Icon Composer file, so the same layers are also rendered
// into an image stack in the asset catalog, which that SDK alone reads.
//
// The layers, back to front: the pastel ramp (Spectrum), then T and P, then
// Y, which reaches over both of its neighbours.
//
// To look at a rendition without building (Default, Dark, TintedLight,
// TintedDark, ClearLight or ClearDark; iOS or macOS):
//
//     "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//         Resources/AppIcon.icon --export-image --output-file icon.png \
//         --platform macOS --rendition Dark --width 512 --height 512 --scale 2

let iconCanvas: CGFloat = 1024
/// How wide the wordmark's ink runs on the canvas. visionOS crops to a circle
/// and floats the layers apart, so there it is set smaller.
let iconWordmarkWidth: CGFloat = 700
let visionWordmarkWidth: CGFloat = 600

/// The wordmark's letters as outlines on the icon canvas, y up, in the
/// spacing `typLayout` gives them, scaled until the ink is `width`
/// across and centred on its own bounds.
func typOutlines(width: CGFloat) -> [String: CGPath] {
    let probe = typLayout(at: 1000)
    let font = probe.font as CTFont
    var outlines: [(letter: String, path: CGPath)] = []
    for (letter, origin) in zip(typLetters, probe.origins) {
        var characters = Array(letter.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        var place = CGAffineTransform(translationX: origin.x, y: origin.y)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
              let path = CTFontCreatePathForGlyph(font, glyphs[0], &place) else {
            fatalError("Libertinus has no outline for \(letter)")
        }
        outlines.append((letter, path))
    }

    let bounds = outlines.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    let scale = width / bounds.width
    var fit = CGAffineTransform(translationX: iconCanvas / 2, y: iconCanvas / 2)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -bounds.midX, y: -bounds.midY)
    return Dictionary(uniqueKeysWithValues: outlines.map { ($0.letter, $0.path.copy(using: &fit)!) })
}

/// A colour as the bitmaps here end up holding it: drawn into one pixel and
/// read back, so the vector layers match the visionOS bitmaps exactly.
func hex(_ color: NSColor) -> String {
    let image = renderImage(size: 1) { side in
        color.setFill()
        CGRect(x: 0, y: 0, width: side, height: side).fill()
    }
    guard let rep = image.representations.first as? NSBitmapImageRep else {
        fatalError("Could not read back a colour")
    }
    var pixel = [Int](repeating: 0, count: 4)
    rep.getPixel(&pixel, atX: 0, y: 0)
    return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
}

func svgNumber(_ value: CGFloat) -> String {
    var text = String(format: "%.2f", Double(value))
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

/// Path data for an outline drawn y up; SVG runs y down, so it is flipped.
func svgPathData(_ path: CGPath) -> String {
    func point(_ p: CGPoint) -> String { "\(svgNumber(p.x)) \(svgNumber(iconCanvas - p.y))" }
    var commands: [String] = []
    path.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: commands.append("M\(point(points[0]))")
        case .addLineToPoint: commands.append("L\(point(points[0]))")
        case .addQuadCurveToPoint: commands.append("Q\(point(points[0])) \(point(points[1]))")
        case .addCurveToPoint: commands.append("C\(point(points[0])) \(point(points[1])) \(point(points[2]))")
        case .closeSubpath: commands.append("Z")
        @unknown default: break
        }
    }
    return commands.joined()
}

/// A ramp as an SVG gradient laid across `rect` (canvas coordinates, y up)
/// the way `NSGradient.draw(in:angle:)` lays it: through the centre along the
/// angle, long enough to put the first and last colours on opposite corners.
func svgSpectrum(_ colors: [NSColor], across rect: CGRect) -> [String] {
    let radians = gradientAngle * .pi / 180
    let direction = CGPoint(x: cos(radians), y: -sin(radians))
    let reach = (rect.width * abs(direction.x) + rect.height * abs(direction.y)) / 2
    let centre = CGPoint(x: rect.midX, y: iconCanvas - rect.midY)
    var lines = [
        "<defs>",
        "  <linearGradient id=\"spectrum\" gradientUnits=\"userSpaceOnUse\""
            + " x1=\"\(svgNumber(centre.x - direction.x * reach))\" y1=\"\(svgNumber(centre.y - direction.y * reach))\""
            + " x2=\"\(svgNumber(centre.x + direction.x * reach))\" y2=\"\(svgNumber(centre.y + direction.y * reach))\">",
    ]
    for (color, location) in zip(colors, rampLocations) {
        lines.append("    <stop offset=\"\(svgNumber(location))\" stop-color=\"\(hex(color))\"/>")
    }
    lines += ["  </linearGradient>", "</defs>"]
    return lines
}

func svgDocument(_ body: [String]) -> String {
    let size = svgNumber(iconCanvas)
    return (["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(size)\" height=\"\(size)\" viewBox=\"0 0 \(size) \(size)\">"]
        + body.map { "  " + $0 }
        + ["</svg>", ""]).joined(separator: "\n")
}

/// One visionOS layer: the canvas with `draw` run in it, y up.
func visionLayer(_ draw: () -> Void) -> NSImage {
    renderImage(size: Int(iconCanvas)) { _ in draw() }
}

func fillOutlines(_ paths: [CGPath]) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.setFillColor(ink.usingColorSpace(.deviceRGB)?.cgColor ?? CGColor(gray: 0, alpha: 1))
    for path in paths {
        context.addPath(path)
        context.fillPath()
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

/// An Icon Composer colour: components in extended sRGB.
func iconColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> String {
    String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", Double(red), Double(green), Double(blue))
}

func generateAppIcon() throws {
    let assets = appIconBundle.appending(path: "Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    let outlines = typOutlines(width: iconWordmarkWidth)
    let canvas = CGRect(x: 0, y: 0, width: iconCanvas, height: iconCanvas)
    let wordmark = outlines.values.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }

    try svgDocument(svgSpectrum(lightCMYOGV, across: canvas) + [
        "<rect width=\"\(svgNumber(iconCanvas))\" height=\"\(svgNumber(iconCanvas))\" fill=\"url(#spectrum)\"/>",
    ]).write(to: assets.appending(path: "Spectrum.svg"), atomically: true, encoding: .utf8)

    // Each letter twice: in ink for the light icon, and in colour for the
    // dark one, where the ramp behind is put away and the letters are what is
    // left of it. There the ramp is fitted to the wordmark, so all six
    // colours run through the three letters unbroken, and they are
    // saturated and at full brightness: pastels wash out on black.
    let vivid = lightCMYOGV.map { saturated($0, darkenedTo: 1.0) }
    for letter in typLetters {
        let data = svgPathData(outlines[letter]!)
        try svgDocument([
            "<path fill=\"\(hex(ink))\" d=\"\(data)\"/>",
        ]).write(to: assets.appending(path: "\(letter).svg"), atomically: true, encoding: .utf8)
        try svgDocument(svgSpectrum(vivid, across: wordmark) + [
            "<path fill=\"url(#spectrum)\" d=\"\(data)\"/>",
        ]).write(to: assets.appending(path: "\(letter)-Dark.svg"), atomically: true, encoding: .utf8)
    }

    // The tinted and clear icons are drawn from brightness alone, where the
    // saturated colours come out dim and uneven, so there the letters are
    // plain white.
    func letterLayer(_ letter: String) -> [String: Any] {
        [
            "fill-specializations": [
                ["appearance": "tinted", "value": ["solid": iconColor(1, 1, 1)]],
            ],
            "image-name-specializations": [
                ["value": "\(letter).svg"],
                ["appearance": "dark", "value": "\(letter)-Dark.svg"],
            ],
            "name": letter,
        ]
    }
    func group(_ layers: [[String: Any]], shadow: Double) -> [String: Any] {
        [
            "layers": layers,
            "shadow": ["kind": "neutral", "opacity": shadow],
            "translucency": ["enabled": false, "value": 0.5],
        ]
    }

    let document: [String: Any] = [
        // What lies under the ramp. The light icon never shows it; the dark
        // one, with the ramp put away, is all ground.
        "fill-specializations": [
            ["value": ["solid": iconColor(1.0, 0.945, 0.698)]],
            ["appearance": "dark", "value": ["linear-gradient": [iconColor(0.13, 0.13, 0.14), iconColor(0.02, 0.02, 0.02)]]],
        ],
        // Front to back. The ramp stays flat; the letters are the glass.
        "groups": [
            group([letterLayer("Y")], shadow: 0.5),
            group([letterLayer("T"), letterLayer("P")], shadow: 0.5),
            group([[
                "glass": false,
                "hidden-specializations": [
                    ["appearance": "dark", "value": true],
                    ["appearance": "tinted", "value": true],
                ],
                "image-name": "Spectrum.svg",
                "name": "Spectrum",
            ]], shadow: 0),
        ],
        "supported-platforms": ["squares": "shared"],
    ]
    var json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    json.append(contentsOf: "\n".utf8)
    try json.write(to: appIconBundle.appending(path: "icon.json"), options: [.atomic])
}

/// The visionOS icon: three full-canvas layers the system crops to a circle
/// and floats apart. The back one is opaque, as that platform requires.
func generateVisionAppIcon() throws {
    let outlines = typOutlines(width: visionWordmarkWidth)
    let canvas = CGRect(x: 0, y: 0, width: iconCanvas, height: iconCanvas)
    let layers: [(name: String, image: NSImage, opaque: Bool)] = [
        ("Front", visionLayer { fillOutlines([outlines["Y"]!]) }, false),
        ("Middle", visionLayer { fillOutlines([outlines["T"]!, outlines["P"]!]) }, false),
        ("Back", visionLayer { gradient().draw(in: canvas, angle: gradientAngle) }, true),
    ]

    let info = "\"info\" : { \"author\" : \"xcode\", \"version\" : 1 }"
    for layer in layers {
        let folder = visionIconStack.appending(path: "\(layer.name).solidimagestacklayer")
        let imageSet = folder.appending(path: "Content.imageset")
        try FileManager.default.createDirectory(at: imageSet, withIntermediateDirectories: true)
        let png = imageSet.appending(path: "\(layer.name).png")
        if layer.opaque {
            try writeOpaquePNG(layer.image, to: png)
        } else {
            try writePNG(layer.image, to: png)
        }
        try "{\n  \(info)\n}\n".write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
        try """
        {
          "images" : [
            { "idiom" : "vision", "scale" : "2x", "filename" : "\(layer.name).png" }
          ],
          \(info)
        }

        """.write(to: imageSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
    }

    let entries = layers.map { "    { \"filename\" : \"\($0.name).solidimagestacklayer\" }" }.joined(separator: ",\n")
    try "{\n  \(info),\n  \"layers\" : [\n\(entries)\n  ]\n}\n"
        .write(to: visionIconStack.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
}

try generateAppIcon()
try generateVisionAppIcon()

print("Generated the Typeset app icon.")
