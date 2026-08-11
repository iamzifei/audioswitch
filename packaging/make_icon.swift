#!/usr/bin/env swift
//
// Draws AudioSwitch.icns from scratch.
//
// Everything is rendered with CoreGraphics rather than hand-drawn artwork so
// that the result follows Apple's macOS icon geometry exactly:
//
//   * 1024x1024 canvas
//   * the icon shape occupies the centre 824x824, leaving the standard margin
//   * corner radius 185.4 with *continuous* curvature (the "squircle" that
//     macOS has used since Big Sur — a plain rounded rect is visibly wrong)
//   * a soft contact shadow below the shape, as in Apple's icon template
//
// Usage: swift make_icon.swift <output.icns>

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry constants from Apple's macOS icon template

let canvasSize: CGFloat = 1024
let artSize: CGFloat = 824
let artOrigin = (canvasSize - artSize) / 2   // 100pt margin on every side
let cornerRadius: CGFloat = 185.4

// MARK: - Palette
//
// A blue→indigo ramp in the same family as the system's own audio-related
// icons, kept dark enough that a white glyph stays legible at 16pt.

let topColor = NSColor(srgbRed: 0.30, green: 0.55, blue: 1.00, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.27, green: 0.20, blue: 0.78, alpha: 1)

// MARK: - Rendering

/// Continuous-curvature rounded rectangle, matching `cornerCurve = .continuous`.
///
/// The shape is built from four corner arcs whose control points are pulled
/// further along the edges than a circular corner would place them, which is
/// what gives the squircle its smooth transition from straight edge to curve.
func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    // 1.28 is the ratio Apple's continuous corners use between the control
    // point distance and the nominal corner radius.
    let control = radius * 1.28
    let limit = min(rect.width, rect.height) / 2
    let r = min(radius, limit)
    let c = min(control, limit)

    let minX = rect.minX, maxX = rect.maxX
    let minY = rect.minY, maxY = rect.maxY

    path.move(to: CGPoint(x: minX + c, y: minY))
    path.addLine(to: CGPoint(x: maxX - c, y: minY))
    path.addCurve(
        to: CGPoint(x: maxX, y: minY + c),
        control1: CGPoint(x: maxX - r * 0.34, y: minY),
        control2: CGPoint(x: maxX, y: minY + r * 0.34)
    )
    path.addLine(to: CGPoint(x: maxX, y: maxY - c))
    path.addCurve(
        to: CGPoint(x: maxX - c, y: maxY),
        control1: CGPoint(x: maxX, y: maxY - r * 0.34),
        control2: CGPoint(x: maxX - r * 0.34, y: maxY)
    )
    path.addLine(to: CGPoint(x: minX + c, y: maxY))
    path.addCurve(
        to: CGPoint(x: minX, y: maxY - c),
        control1: CGPoint(x: minX + r * 0.34, y: maxY),
        control2: CGPoint(x: minX, y: maxY - r * 0.34)
    )
    path.addLine(to: CGPoint(x: minX, y: minY + c))
    path.addCurve(
        to: CGPoint(x: minX + c, y: minY),
        control1: CGPoint(x: minX, y: minY + r * 0.34),
        control2: CGPoint(x: minX + r * 0.34, y: minY)
    )
    path.closeSubpath()
    return path
}

/// Draws the icon into `context` using a fixed 1024pt coordinate space.
/// Callers scale the context so every exported size is rasterised from vectors
/// rather than resampled from a bitmap.
func drawIconContents(in context: CGContext) {
    let artRect = CGRect(x: artOrigin, y: artOrigin, width: artSize, height: artSize)
    let shape = squirclePath(in: artRect, radius: cornerRadius)

    // Contact shadow: soft, tight, and slightly below the shape — the same
    // treatment Apple's template applies to third-party icons.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10),
        blur: 24,
        color: NSColor.black.withAlphaComponent(0.28).cgColor
    )
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // Background gradient, clipped to the squircle.
    context.saveGState()
    context.addPath(shape)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [topColor.cgColor, bottomColor.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: artRect.midX, y: artRect.maxY),
        end: CGPoint(x: artRect.midX, y: artRect.minY),
        options: []
    )

    // Glass highlight across the top third, very low contrast so it reads as
    // material rather than as gloss.
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        highlight,
        start: CGPoint(x: artRect.midX, y: artRect.maxY),
        end: CGPoint(x: artRect.midX, y: artRect.midY + artRect.height * 0.05),
        options: []
    )
    context.restoreGState()

    // Hairline inner edge, which keeps the shape crisp against light wallpapers.
    context.saveGState()
    context.addPath(shape)
    context.setLineWidth(2)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    context.strokePath()
    context.restoreGState()

    // Foreground glyph: the same speaker symbol family the menu bar item uses,
    // so the app reads consistently from Dock to menu bar.
    let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 420, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfiguration) {

        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
        symbol.draw(
            at: .zero, from: NSRect(origin: .zero, size: symbol.size),
            operation: .destinationIn, fraction: 1
        )
        tinted.unlockFocus()

        // Optically centred: the trailing sound waves are visually lighter than
        // the solid speaker cone, so geometric centring reads as shifted right.
        // Nudging left compensates.
        let glyphRect = NSRect(
            x: (canvasSize - symbol.size.width) / 2 - 16,
            y: (canvasSize - symbol.size.height) / 2,
            width: symbol.size.width,
            height: symbol.size.height
        )

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -6),
            blur: 18,
            color: NSColor.black.withAlphaComponent(0.22).cgColor
        )
        tinted.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
        context.restoreGState()
    }

}

// MARK: - Export

/// Renders the icon at an exact pixel size.
///
/// The bitmap representation is allocated explicitly instead of going through
/// `NSImage.lockFocus()`, because on a Retina display the latter silently
/// creates a 2x backing store — a "1024" export would come out at 2048px and
/// every entry in the iconset would then be the wrong size.
///
/// Each size is rasterised from the drawing code rather than resampled from a
/// larger bitmap, so the 16pt and 32pt variants stay crisp.
func pngData(size: CGFloat) -> Data {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("failed to allocate bitmap at \(size)px") }
    // 1 point == 1 pixel in this representation.
    rep.size = NSSize(width: size, height: size)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("failed to create context at \(size)px")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: size / canvasSize, y: size / canvasSize)
    drawIconContents(in: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to encode PNG at \(size)px")
    }
    return data
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: make_icon.swift <output.icns>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = arguments[1]

let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AudioSwitch.iconset")
try? FileManager.default.removeItem(at: workDirectory)
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

// The exact set of representations `iconutil` expects for a complete .icns.
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for variant in variants {
    let data = pngData(size: variant.size)
    try data.write(to: workDirectory.appendingPathComponent(variant.name))
}

// Keep a 1024 preview next to the .icns for documentation.
let previewURL = URL(fileURLWithPath: outputPath)
    .deletingLastPathComponent()
    .appendingPathComponent("icon-preview.png")
try pngData(size: 1024).write(to: previewURL)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", workDirectory.path, "-o", outputPath]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

print("wrote \(outputPath)")
print("wrote \(previewURL.path)")
