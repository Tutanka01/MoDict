// MoDict app icon generator.
//
// Run as a script (no Xcode, no build step):
//
//     swift Support/generate-icon.swift path/to/Icon-1024.png
//
// Draws the flat 1024×1024 fallback icon described in Docs/DESIGN.md "App icon":
// a near-black squircle with a ~10% margin and the white mark (a voice waveform
// whose peak is a text cursor). Monochrome, no border, only a barely-visible
// vertical luminance shift (<4%). The Makefile `icon` target feeds the result to
// `sips` + `iconutil` to produce AppIcon.icns. When the toolchain's actool can
// compile Support/AppIcon.icon, the bundle ships that layered Liquid Glass icon
// instead, and this file is only the fallback.

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

// MARK: - The mark: a voice waveform whose peak is a text cursor (I-beam)
//
// Same proportions as `MoDictMark` (Sources/MoDict/UI/Mark.swift) and the layers
// of Support/AppIcon.icon; keep all three in sync.

let markSide = bodyRect.width * (560.0 / 1024.0)
let barWidth = 0.11 * markSide
let barGap = 0.075 * markSide
let cursorStem = 0.075 * markSide
let serifWidth = 0.23 * markSide
let serifThickness = 0.075 * markSide
let cursorHeight = 0.86 * markSide
let centerY = canvas / 2

func fillCapsule(_ rect: CGRect) {
    let radius = min(rect.width, rect.height) / 2
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

context.setFillColor(gray(1))
var markX = canvas / 2 - (4 * barWidth + serifWidth + 4 * barGap) / 2
func bar(_ proportion: CGFloat) {
    let height = proportion * markSide
    fillCapsule(CGRect(x: markX, y: centerY - height / 2, width: barWidth, height: height))
    markX += barWidth + barGap
}
bar(0.30)
bar(0.56)
let cursorX = markX + serifWidth / 2
let cursorBottom = centerY - cursorHeight / 2
fillCapsule(CGRect(x: cursorX - cursorStem / 2, y: cursorBottom, width: cursorStem, height: cursorHeight))
fillCapsule(CGRect(x: cursorX - serifWidth / 2, y: cursorBottom, width: serifWidth, height: serifThickness))
fillCapsule(CGRect(x: cursorX - serifWidth / 2, y: cursorBottom + cursorHeight - serifThickness,
                   width: serifWidth, height: serifThickness))
markX += serifWidth + barGap
bar(0.56)
bar(0.30)

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
