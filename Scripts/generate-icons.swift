#!/usr/bin/env swift
// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreText
import Foundation

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

let black = NSColor(calibratedWhite: 0.02, alpha: 1.0)
let white = NSColor(calibratedWhite: 0.98, alpha: 1.0)

func linuxLibertineBoldName() -> String? {
    let candidates = [
        root.appending(path: "Resources/Fonts/LinuxLibertine/LinLibertine_RB.otf"),
        URL(fileURLWithPath: NSString(string: "~/Library/Fonts/LinLibertine_RB.otf").expandingTildeInPath),
        URL(fileURLWithPath: "/Library/Fonts/LinLibertine_RB.otf"),
        URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/LinLibertine_RB.otf"),
    ]

    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        guard let provider = CGDataProvider(url: url as CFURL),
              let font = CGFont(provider) else {
            continue
        }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if let name = font.postScriptName as String? {
            return name
        }
    }
    return nil
}

let titleFontName = linuxLibertineBoldName()

func titleFont(size: CGFloat) -> NSFont {
    if let titleFontName, let font = NSFont(name: titleFontName, size: size) {
        return font
    }
    return NSFont.systemFont(ofSize: size, weight: .black)
}

func gradient() -> NSGradient {
    NSGradient(colorsAndLocations:
        (lightCMYOGV[0], 0.00),
        (lightCMYOGV[1], 0.18),
        (lightCMYOGV[2], 0.38),
        (lightCMYOGV[3], 0.55),
        (lightCMYOGV[4], 0.74),
        (lightCMYOGV[5], 1.00)
    )!
}

func drawReticle(in rect: CGRect, scale: CGFloat, lineWidth: CGFloat) {
    let markLength = 92 * scale
    let inset = 36 * scale
    let centers = [
        CGPoint(x: rect.midX, y: rect.maxY - inset),
        CGPoint(x: rect.midX, y: rect.minY + inset),
        CGPoint(x: rect.minX + inset, y: rect.midY),
        CGPoint(x: rect.maxX - inset, y: rect.midY),
    ]

    black.setStroke()
    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.move(to: CGPoint(x: centers[0].x - markLength / 2, y: centers[0].y))
    path.line(to: CGPoint(x: centers[0].x + markLength / 2, y: centers[0].y))
    path.move(to: CGPoint(x: centers[1].x - markLength / 2, y: centers[1].y))
    path.line(to: CGPoint(x: centers[1].x + markLength / 2, y: centers[1].y))
    path.move(to: CGPoint(x: centers[2].x, y: centers[2].y - markLength / 2))
    path.line(to: CGPoint(x: centers[2].x, y: centers[2].y + markLength / 2))
    path.move(to: CGPoint(x: centers[3].x, y: centers[3].y - markLength / 2))
    path.line(to: CGPoint(x: centers[3].x, y: centers[3].y + markLength / 2))
    path.stroke()
}

func drawPrinterAlignmentMarks(in rect: CGRect, scale: CGFloat, lineWidth: CGFloat) {
    let centerInset = 96 * scale
    let armLength = 56 * scale
    let ringRadius = 22 * scale
    let centers = [
        CGPoint(x: rect.minX + centerInset, y: rect.maxY - centerInset),
        CGPoint(x: rect.maxX - centerInset, y: rect.minY + centerInset),
    ]

    black.setStroke()
    for center in centers {
        let ring = NSBezierPath(ovalIn: CGRect(
            x: center.x - ringRadius,
            y: center.y - ringRadius,
            width: ringRadius * 2,
            height: ringRadius * 2
        ))
        ring.lineWidth = lineWidth
        ring.stroke()

        let crosshair = NSBezierPath()
        crosshair.lineWidth = lineWidth
        crosshair.lineCapStyle = .round
        crosshair.move(to: CGPoint(x: center.x - armLength, y: center.y))
        crosshair.line(to: CGPoint(x: center.x + armLength, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - armLength))
        crosshair.line(to: CGPoint(x: center.x, y: center.y + armLength))
        crosshair.stroke()
    }
}

func drawCenteredText(_ text: String, in rect: CGRect, fontSize: CGFloat, lineHeightMultiple: CGFloat = 0.82) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineHeightMultiple = lineHeightMultiple

    let attributes: [NSAttributedString.Key: Any] = [
        .font: titleFont(size: fontSize),
        .foregroundColor: black,
        .paragraphStyle: paragraph,
        .kern: -fontSize * 0.025,
    ]
    NSAttributedString(string: text, attributes: attributes).draw(in: rect)
}

func drawText(
    _ text: String,
    in rect: CGRect,
    font: NSFont,
    color: NSColor = black,
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

func pathThrough(_ points: [CGPoint], closed: Bool = false) -> NSBezierPath {
    let path = NSBezierPath()
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() {
        path.line(to: point)
    }
    if closed {
        path.close()
    }
    return path
}

func strokePath(_ path: NSBezierPath, color: NSColor = black, width: CGFloat, cap: NSBezierPath.LineCapStyle = .round) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = cap
    path.lineJoinStyle = .round
    path.stroke()
}

func strokeLine(from start: CGPoint, to end: CGPoint, color: NSColor = black, width: CGFloat) {
    strokePath(pathThrough([start, end]), color: color, width: width)
}

func drawArrow(from start: CGPoint, to end: CGPoint, scale: CGFloat, color: NSColor = black, width: CGFloat) {
    strokeLine(from: start, to: end, color: color, width: width)
    let angle = atan2(end.y - start.y, end.x - start.x)
    let length = 16 * scale
    let spread = CGFloat.pi / 7
    let left = CGPoint(x: end.x - cos(angle - spread) * length, y: end.y - sin(angle - spread) * length)
    let right = CGPoint(x: end.x - cos(angle + spread) * length, y: end.y - sin(angle + spread) * length)
    strokePath(pathThrough([left, end, right]), color: color, width: width)
}

func hexagon(center: CGPoint, radius: CGFloat) -> [CGPoint] {
    (0..<6).map { index in
        let angle = CGFloat.pi / 6 + CGFloat(index) * CGFloat.pi / 3
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
}

func drawHexagon(center: CGPoint, radius: CGFloat, scale: CGFloat, color: NSColor = black) {
    strokePath(pathThrough(hexagon(center: center, radius: radius), closed: true), color: color, width: max(1.0, 5 * scale))
}

func drawDocumentPage(in page: CGRect, scale: CGFloat, cornerRadius: CGFloat, borderWidth: CGFloat, shadowAlpha: CGFloat = 0.18) {
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 36 * scale
    shadow.shadowOffset = CGSize(width: 0, height: -12 * scale)
    shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
    shadow.set()

    let body = NSBezierPath(roundedRect: page, xRadius: cornerRadius, yRadius: cornerRadius)
    white.setFill()
    body.fill()

    NSShadow().set()
    black.setStroke()
    let outline = NSBezierPath(
        roundedRect: page.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
        xRadius: cornerRadius - borderWidth / 2,
        yRadius: cornerRadius - borderWidth / 2
    )
    outline.lineWidth = borderWidth
    outline.stroke()
}

func drawMathFigure(in rect: CGRect, scale: CGFloat) {
    drawText("Math", in: CGRect(x: rect.minX, y: rect.maxY - 24 * scale, width: rect.width, height: 24 * scale), font: titleFont(size: 23 * scale))
    drawText("∑", in: CGRect(x: rect.minX + 8 * scale, y: rect.midY - 18 * scale, width: 58 * scale, height: 66 * scale), font: titleFont(size: 58 * scale))
    drawText("k = 1 + ... + n", in: CGRect(x: rect.minX + 67 * scale, y: rect.midY + 10 * scale, width: rect.width - 74 * scale, height: 24 * scale), font: NSFont.systemFont(ofSize: 18 * scale, weight: .medium))
    drawText("n(n+1)", in: CGRect(x: rect.minX + 86 * scale, y: rect.midY - 25 * scale, width: 86 * scale, height: 24 * scale), font: NSFont.systemFont(ofSize: 18 * scale, weight: .medium), alignment: .center)
    strokeLine(from: CGPoint(x: rect.minX + 92 * scale, y: rect.midY - 5 * scale), to: CGPoint(x: rect.minX + 168 * scale, y: rect.midY - 5 * scale), width: max(1, 3 * scale))
    drawText("2", in: CGRect(x: rect.minX + 120 * scale, y: rect.midY - 48 * scale, width: 26 * scale, height: 24 * scale), font: NSFont.systemFont(ofSize: 18 * scale, weight: .medium), alignment: .center)
    drawText("(1)", in: CGRect(x: rect.maxX - 46 * scale, y: rect.midY - 20 * scale, width: 44 * scale, height: 26 * scale), font: NSFont.systemFont(ofSize: 18 * scale, weight: .regular), alignment: .right)
}

func drawChemistryFigure(in rect: CGRect, scale: CGFloat) {
    drawText("Chemistry", in: CGRect(x: rect.minX, y: rect.maxY - 24 * scale, width: rect.width, height: 24 * scale), font: titleFont(size: 23 * scale))
    let left = CGPoint(x: rect.minX + 55 * scale, y: rect.midY - 5 * scale)
    let right = CGPoint(x: rect.maxX - 54 * scale, y: rect.midY - 5 * scale)
    drawHexagon(center: left, radius: 38 * scale, scale: scale)
    drawArrow(from: CGPoint(x: left.x + 50 * scale, y: left.y), to: CGPoint(x: right.x - 54 * scale, y: right.y), scale: scale, width: max(1.0, 4 * scale))
    drawText("Br₂", in: CGRect(x: rect.midX - 10 * scale, y: rect.midY + 10 * scale, width: 42 * scale, height: 22 * scale), font: NSFont.systemFont(ofSize: 15 * scale, weight: .semibold))
    drawHexagon(center: right, radius: 38 * scale, scale: scale)
    strokeLine(from: CGPoint(x: right.x, y: right.y + 38 * scale), to: CGPoint(x: right.x, y: right.y + 72 * scale), width: max(1.0, 4 * scale))
    drawText("Br", in: CGRect(x: right.x - 13 * scale, y: right.y + 72 * scale, width: 32 * scale, height: 24 * scale), font: NSFont.systemFont(ofSize: 20 * scale, weight: .medium), color: NSColor(calibratedRed: 0.58, green: 0.12, blue: 0.17, alpha: 1.0), alignment: .center)
}

func drawDiagramFigure(in rect: CGRect, scale: CGFloat) {
    drawText("Diagrams", in: CGRect(x: rect.minX, y: rect.maxY - 24 * scale, width: rect.width, height: 24 * scale), font: titleFont(size: 23 * scale))
    let top = CGRect(x: rect.midX - 64 * scale, y: rect.maxY - 82 * scale, width: 128 * scale, height: 40 * scale)
    let diamond = [
        CGPoint(x: rect.midX, y: rect.maxY - 112 * scale),
        CGPoint(x: rect.midX + 72 * scale, y: rect.maxY - 166 * scale),
        CGPoint(x: rect.midX, y: rect.maxY - 220 * scale),
        CGPoint(x: rect.midX - 72 * scale, y: rect.maxY - 166 * scale),
    ]
    black.setStroke()
    let topPath = NSBezierPath(roundedRect: top, xRadius: 7 * scale, yRadius: 7 * scale)
    topPath.lineWidth = max(1.0, 4 * scale)
    topPath.stroke()
    strokePath(pathThrough(diamond, closed: true), width: max(1.0, 4 * scale))
    drawArrow(from: CGPoint(x: rect.midX, y: top.minY), to: CGPoint(x: rect.midX, y: rect.maxY - 108 * scale), scale: scale, width: max(1.0, 4 * scale))
    drawArrow(from: CGPoint(x: rect.midX + 72 * scale, y: rect.maxY - 166 * scale), to: CGPoint(x: rect.maxX - 36 * scale, y: rect.maxY - 166 * scale), scale: scale, width: max(1.0, 4 * scale))
    let maybe = CGRect(x: rect.maxX - 36 * scale, y: rect.maxY - 184 * scale, width: 44 * scale, height: 36 * scale)
    NSBezierPath(rect: maybe).stroke()
    drawArrow(from: CGPoint(x: rect.midX, y: rect.maxY - 220 * scale), to: CGPoint(x: rect.midX, y: rect.minY + 20 * scale), scale: scale, width: max(1.0, 4 * scale))
    NSBezierPath(rect: CGRect(x: rect.midX - 22 * scale, y: rect.minY + 2 * scale, width: 44 * scale, height: 34 * scale)).stroke()
}

func drawCircuitFigure(in rect: CGRect, scale: CGFloat) {
    drawText("Circuits", in: CGRect(x: rect.minX, y: rect.maxY - 24 * scale, width: rect.width, height: 24 * scale), font: titleFont(size: 23 * scale))
    let y1 = rect.minY + rect.height * 0.45
    let y2 = y1 - 44 * scale
    strokeLine(from: CGPoint(x: rect.minX + 8 * scale, y: y1), to: CGPoint(x: rect.maxX - 8 * scale, y: y1), width: max(1.0, 4 * scale))
    strokeLine(from: CGPoint(x: rect.minX + 8 * scale, y: y2), to: CGPoint(x: rect.maxX - 8 * scale, y: y2), width: max(1.0, 4 * scale))
    let gate = CGRect(x: rect.minX + 58 * scale, y: y1 - 16 * scale, width: 32 * scale, height: 32 * scale)
    white.setFill()
    NSBezierPath(rect: gate).fill()
    NSBezierPath(rect: gate).stroke()
    drawText("H", in: gate.insetBy(dx: 5 * scale, dy: 4 * scale), font: NSFont.systemFont(ofSize: 19 * scale, weight: .medium), alignment: .center)
    let control = CGPoint(x: rect.midX + 12 * scale, y: y1)
    NSBezierPath(ovalIn: CGRect(x: control.x - 6 * scale, y: control.y - 6 * scale, width: 12 * scale, height: 12 * scale)).fill()
    strokeLine(from: control, to: CGPoint(x: control.x, y: y2), width: max(1.0, 4 * scale))
    let target = CGPoint(x: control.x, y: y2)
    strokePath(NSBezierPath(ovalIn: CGRect(x: target.x - 13 * scale, y: target.y - 13 * scale, width: 26 * scale, height: 26 * scale)), width: max(1.0, 3 * scale))
    strokeLine(from: CGPoint(x: target.x - 12 * scale, y: target.y), to: CGPoint(x: target.x + 12 * scale, y: target.y), width: max(1.0, 3 * scale))
    strokeLine(from: CGPoint(x: target.x, y: target.y - 12 * scale), to: CGPoint(x: target.x, y: target.y + 12 * scale), width: max(1.0, 3 * scale))
    drawText("√2", in: CGRect(x: rect.maxX - 42 * scale, y: y1 + 7 * scale, width: 38 * scale, height: 24 * scale), font: NSFont.systemFont(ofSize: 17 * scale, weight: .regular))
}

func drawTimelineFigure(in rect: CGRect, scale: CGFloat) {
    drawText("Timelines", in: CGRect(x: rect.minX, y: rect.maxY - 24 * scale, width: rect.width, height: 24 * scale), font: titleFont(size: 23 * scale))
    let table = CGRect(x: rect.minX + 10 * scale, y: rect.minY + 22 * scale, width: rect.width - 20 * scale, height: rect.height - 62 * scale)
    strokePath(NSBezierPath(rect: table), width: max(1.0, 4 * scale))
    for index in 1..<5 {
        let x = table.minX + table.width * CGFloat(index) / 5
        strokeLine(from: CGPoint(x: x, y: table.minY), to: CGPoint(x: x, y: table.maxY), color: black.withAlphaComponent(0.32), width: max(0.7, 2 * scale))
    }
    for index in 1..<4 {
        let y = table.minY + table.height * CGFloat(index) / 4
        strokeLine(from: CGPoint(x: table.minX, y: y), to: CGPoint(x: table.maxX, y: y), color: black.withAlphaComponent(0.32), width: max(0.7, 2 * scale))
    }
    strokeLine(from: CGPoint(x: table.minX + 50 * scale, y: table.minY + 38 * scale), to: CGPoint(x: table.minX + 146 * scale, y: table.minY + 38 * scale), width: max(2.0, 8 * scale))
    strokeLine(from: CGPoint(x: table.minX + 132 * scale, y: table.minY + 78 * scale), to: CGPoint(x: table.minX + 240 * scale, y: table.minY + 78 * scale), width: max(2.0, 8 * scale))
    strokeLine(from: CGPoint(x: table.minX + 232 * scale, y: table.minY + 116 * scale), to: CGPoint(x: table.maxX - 4 * scale, y: table.minY + 116 * scale), width: max(2.0, 8 * scale))
}

func drawGraphFigure(in rect: CGRect, scale: CGFloat) {
    drawText("Graphs", in: CGRect(x: rect.minX, y: rect.maxY - 24 * scale, width: rect.width, height: 24 * scale), font: titleFont(size: 23 * scale))
    let plot = CGRect(x: rect.minX + 18 * scale, y: rect.minY + 20 * scale, width: rect.width - 36 * scale, height: rect.height - 60 * scale)
    strokePath(NSBezierPath(rect: plot), width: max(1.0, 4 * scale))
    for index in 1..<4 {
        let x = plot.minX + plot.width * CGFloat(index) / 4
        strokeLine(from: CGPoint(x: x, y: plot.minY), to: CGPoint(x: x, y: plot.maxY), color: black.withAlphaComponent(0.18), width: max(0.6, 1.5 * scale))
        let y = plot.minY + plot.height * CGFloat(index) / 4
        strokeLine(from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y), color: black.withAlphaComponent(0.18), width: max(0.6, 1.5 * scale))
    }
    let curve = NSBezierPath()
    for index in 0...48 {
        let t = CGFloat(index) / 48
        let x = plot.minX + t * plot.width
        let bell = exp(-pow((t - 0.33) * 4.2, 2))
        let y = plot.minY + (0.10 + bell * 0.78) * plot.height
        if index == 0 {
            curve.move(to: CGPoint(x: x, y: y))
        } else {
            curve.line(to: CGPoint(x: x, y: y))
        }
    }
    strokePath(curve, color: NSColor(calibratedRed: 0.22, green: 0.52, blue: 0.78, alpha: 1.0), width: max(1.0, 5 * scale))
}

func drawFigurePageContent(in page: CGRect, scale: CGFloat, compact: Bool = false) {
    drawText("Typeset", in: CGRect(x: page.minX + 58 * scale, y: page.maxY - 76 * scale, width: page.width - 116 * scale, height: 36 * scale), font: titleFont(size: compact ? 32 * scale : 38 * scale))
    drawText("compiled Typst figures", in: CGRect(x: page.minX + 60 * scale, y: page.maxY - 104 * scale, width: page.width - 120 * scale, height: 24 * scale), font: NSFont.systemFont(ofSize: 18 * scale, weight: .regular))

    let gutter = 42 * scale
    let top = page.maxY - 134 * scale
    let bottom = page.minY + (compact ? 120 : 58) * scale
    let columnGap = 28 * scale
    let cellWidth = (page.width - gutter * 2 - columnGap) / 2
    let cellHeight = (top - bottom) / 3
    let leftX = page.minX + gutter
    let rightX = leftX + cellWidth + columnGap
    let rows = (0..<3).map { row in top - CGFloat(row + 1) * cellHeight }

    drawMathFigure(in: CGRect(x: leftX, y: rows[0], width: cellWidth, height: cellHeight - 12 * scale), scale: scale)
    drawChemistryFigure(in: CGRect(x: rightX, y: rows[0], width: cellWidth, height: cellHeight - 12 * scale), scale: scale)
    drawDiagramFigure(in: CGRect(x: leftX, y: rows[1], width: cellWidth, height: cellHeight - 10 * scale), scale: scale)
    drawCircuitFigure(in: CGRect(x: rightX, y: rows[1] + 48 * scale, width: cellWidth, height: cellHeight * 0.42), scale: scale)
    drawTimelineFigure(in: CGRect(x: rightX, y: rows[1] - cellHeight * 0.42, width: cellWidth, height: cellHeight * 0.52), scale: scale)
    drawGraphFigure(in: CGRect(x: leftX, y: rows[2], width: cellWidth, height: cellHeight - 12 * scale), scale: scale)
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
        let borderWidth = max(2.0, 42 * scale)
        let fillPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fillPath.addClip()
        gradient().draw(in: fillPath, angle: -34)

        let page = CGRect(x: 180 * scale, y: 114 * scale, width: 664 * scale, height: 784 * scale)
        drawDocumentPage(in: page, scale: scale, cornerRadius: 34 * scale, borderWidth: max(2.0, 15 * scale))
        drawFigurePageContent(in: page, scale: scale)

        black.setStroke()
        let strokePath = NSBezierPath(roundedRect: rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), xRadius: radius - borderWidth / 2, yRadius: radius - borderWidth / 2)
        strokePath.lineWidth = borderWidth
        strokePath.stroke()
    }
}

func documentIcon(size: Int, kind: IconKind) -> NSImage {
    renderImage(size: size) { side in
        let scale = side / 1024.0

        let page = CGRect(x: 154 * scale, y: 74 * scale, width: 716 * scale, height: 874 * scale)
        let radius = 58 * scale
        let fold = 154 * scale
        let borderWidth = max(2.0, 36 * scale)

        drawDocumentPage(in: page, scale: scale, cornerRadius: radius, borderWidth: borderWidth, shadowAlpha: 0.14)

        let foldPath = NSBezierPath()
        foldPath.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
        foldPath.line(to: CGPoint(x: page.maxX, y: page.maxY - fold))
        foldPath.line(to: CGPoint(x: page.maxX, y: page.maxY))
        foldPath.close()
        NSColor(calibratedRed: 0.90, green: 0.94, blue: 0.97, alpha: 1.0).setFill()
        foldPath.fill()

        black.setStroke()
        let foldStroke = NSBezierPath()
        foldStroke.move(to: CGPoint(x: page.maxX - fold, y: page.maxY - borderWidth / 2))
        foldStroke.line(to: CGPoint(x: page.maxX - borderWidth / 2, y: page.maxY - fold))
        foldStroke.lineWidth = max(1.5, 20 * scale)
        foldStroke.lineCapStyle = .round
        foldStroke.stroke()

        let outline = NSBezierPath(roundedRect: page.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), xRadius: radius - borderWidth / 2, yRadius: radius - borderWidth / 2)
        outline.lineWidth = borderWidth
        outline.stroke()

        drawFigurePageContent(in: page, scale: scale, compact: true)

        let badge = CGRect(x: page.minX + 78 * scale, y: page.minY + 64 * scale, width: page.width - 156 * scale, height: 86 * scale)
        let badgePath = NSBezierPath(roundedRect: badge, xRadius: 28 * scale, yRadius: 28 * scale)
        NSColor(calibratedWhite: 0.02, alpha: 1.0).setFill()
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
        try writePNG(appIcon(size: size), to: appIconSet.appending(path: "Icon-\(size).png"))
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
