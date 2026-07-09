// MoDict app icon generator.
//
// Run as a script (no Xcode, no build step):
//
//     swift Support/generate-icon.swift path/to/Icon-1024.png
//
// Draws the 1024×1024 master icon described in Docs/DESIGN.md "App icon":
// a near-black squircle with a ~10% margin, and five white capsule bars forming
// a symmetric waveform silhouette with the centre bar tallest. Monochrome, no
// border, only a barely-visible vertical luminance shift (<4%). The Makefile
// `icon` target feeds the result to `sips` + `iconutil` to produce AppIcon.icns.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Arguments

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: swift generate-icon.swift <output.png>\n".utf8))
    exit(1)
}
let outputPath = arguments[1]

// MARK: - Canvas

let side = 1024
let canvas = CGFloat(side)
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let context = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("error: could not create bitmap context\n".utf8))
    exit(1)
}

context.setShouldAntialias(true)
context.interpolationQuality = .high

func gray(_ value: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [value, value, value, alpha])!
}

// MARK: - Squircle body (~10% margin all around)

let margin = canvas * 0.098          // ~100 pt inset -> 824 pt body
let bodyRect = CGRect(x: margin, y: margin, width: canvas - 2 * margin, height: canvas - 2 * margin)
let cornerRadius = bodyRect.width * 0.2237   // continuous-corner ratio of the macOS icon grid
let squircle = CGPath(
    roundedRect: bodyRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil)

// Base #141414 with a <4% top-to-bottom luminance shift (top slightly lighter).
context.saveGState()
context.addPath(squircle)
context.clip()
let topShade: CGFloat = 22.0 / 255.0
let bottomShade: CGFloat = 18.0 / 255.0
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [gray(topShade), gray(bottomShade)] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: bodyRect.maxY),
    end: CGPoint(x: 0, y: bodyRect.minY),
    options: [])
context.restoreGState()

// MARK: - Waveform bars (five white capsules, centre tallest, symmetric)

let barWidth: CGFloat = 84
let barGap: CGFloat = 46
let barHeights: [CGFloat] = [230, 370, 520, 370, 230]

let clusterWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * barGap
var barX = (canvas - clusterWidth) / 2
let centerY = canvas / 2

context.setFillColor(gray(1))
for height in barHeights {
    let barRect = CGRect(x: barX, y: centerY - height / 2, width: barWidth, height: height)
    let capsule = CGPath(
        roundedRect: barRect,
        cornerWidth: barWidth / 2,
        cornerHeight: barWidth / 2,
        transform: nil)
    context.addPath(capsule)
    context.fillPath()
    barX += barWidth + barGap
}

// MARK: - Encode PNG

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("error: could not render image\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath) as CFURL
guard let destination = CGImageDestinationCreateWithURL(
    url, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("error: could not create \(outputPath)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("error: could not write \(outputPath)\n".utf8))
    exit(1)
}

print("wrote \(outputPath) (\(side)×\(side))")
