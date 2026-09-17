#!/usr/bin/env swift
// Renders MeetingScribe/Resources/Assets.xcassets/AppIcon.appiconset from the
// same waveform geometry the menu bar icon uses (MenuBarIconRenderer).
//
//   swift scripts/generate-app-icon.swift
//
// Regenerate whenever the menu bar glyph changes so both stay in sync.

import AppKit
import Foundation

// Bar layout copied from MenuBarIconRenderer.drawWaveform, expressed as
// fractions of the 18pt menu bar canvas so it scales to any icon size.
private let menuBarCanvas: CGFloat = 18
private let barHeights: [CGFloat] = [6, 11, 16, 10, 6]
private let barWidth: CGFloat = 2.1
private let barSpacing: CGFloat = 3.1

/// Superellipse close to the macOS app icon corner shape.
private func squircle(in rect: CGRect) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 720
    let a = rect.width / 2
    let b = rect.height / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let n: CGFloat = 5
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t)
        let sinT = sin(t)
        let x = center.x + a * pow(abs(cosT), 2 / n) * (cosT < 0 ? -1 : 1)
        let y = center.y + b * pow(abs(sinT), 2 / n) * (sinT < 0 ? -1 : 1)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.line(to: CGPoint(x: x, y: y))
        }
    }
    path.close()
    return path
}

private func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        guard let context = NSGraphicsContext.current else { return false }
        context.shouldAntialias = true
        context.imageInterpolation = .high

        // macOS icon grid: the artwork body sits inside a ~10% margin.
        let inset = size * 0.0977
        let body = rect.insetBy(dx: inset, dy: inset)
        let shape = squircle(in: body)

        context.saveGraphicsState()
        shape.addClip()
        let gradient = NSGradient(
            colors: [
                NSColor(srgbRed: 0.35, green: 0.58, blue: 1.00, alpha: 1),
                NSColor(srgbRed: 0.09, green: 0.31, blue: 0.82, alpha: 1),
            ]
        )
        gradient?.draw(in: body, angle: -90)
        context.restoreGraphicsState()

        // Waveform, scaled from the menu bar layout and centred in the body.
        let scale = body.width * 0.62 / menuBarCanvas
        let width = barWidth * scale
        let spacing = barSpacing * scale
        let totalWidth = spacing * CGFloat(barHeights.count - 1) + width
        let originX = body.midX - totalWidth / 2
        NSColor.white.setFill()
        for (index, height) in barHeights.enumerated() {
            let barHeight = height * scale
            let bar = CGRect(
                x: originX + CGFloat(index) * spacing,
                y: body.midY - barHeight / 2,
                width: width,
                height: barHeight
            )
            let radius = width / 2
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        }
        return true
    }
    return image
}

private func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    representation.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSet = repositoryRoot
    .appendingPathComponent("MeetingScribe/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

struct Entry {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var filename: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
}

let entries = [16, 32, 128, 256, 512].flatMap { points in
    [Entry(points: points, scale: 1), Entry(points: points, scale: 2)]
}

for entry in entries {
    let image = drawIcon(size: CGFloat(entry.pixels))
    try writePNG(image, pixels: entry.pixels, to: iconSet.appendingPathComponent(entry.filename))
}

let images = entries.map { entry in
    """
        {
          "filename" : "\(entry.filename)",
          "idiom" : "mac",
          "scale" : "\(entry.scale)x",
          "size" : "\(entry.points)x\(entry.points)"
        }
    """
}

let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(
    to: iconSet.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

print("Wrote \(entries.count) icon variants to \(iconSet.path)")
