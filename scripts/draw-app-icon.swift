// Draws the ConceptStudio app icon (Instant Print, direction A: a developing print) at 1024 × 1024.
// Usage: swift scripts/draw-app-icon.swift <output.png>
// Then make app/Packaging/ConceptStudio.icns from it: an .iconset with icon_<n>x<n>.png and @2x for
// n = 16, 32, 128, 256, 512 (sips -z), then `iconutil -c icns <dir>.iconset -o app/Packaging/ConceptStudio.icns`.
import AppKit

let side: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

let charcoal = color(0x282828)
let paper = color(0xFCFCFB)
let developer = color(0xF86319)

guard let context = CGContext(
    data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

// Core Graphics draws from the bottom left; flip so the layout reads top-down.
context.translateBy(x: 0, y: side)
context.scaleBy(x: 1, y: -1)

func linear(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

// The macOS icon grid: an 824-point rounded square with a soft drop shadow below it.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: color(0x000000, 0.35))
context.addPath(tilePath)
context.setFillColor(charcoal)
context.fillPath()
context.restoreGState()

// Film-back charcoal with a gentle light from the top.
context.saveGState()
context.addPath(tilePath)
context.clip()
context.drawLinearGradient(
    linear([color(0x363636), color(0x282828), color(0x1F1F1F)], [0, 0.55, 1]),
    start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: []
)
context.restoreGState()

// The print: a square window above a deep bottom margin, slightly forward of centre.
let card = CGRect(x: 262, y: 196, width: 500, height: 610)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: color(0x000000, 0.45))
context.addPath(CGPath(roundedRect: card, cornerWidth: 14, cornerHeight: 14, transform: nil))
context.setFillColor(paper)
context.fillPath()
context.restoreGState()

let window = CGRect(x: card.minX + 34, y: card.minY + 34, width: card.width - 68, height: card.width - 68)
context.saveGState()
context.addPath(CGPath(roundedRect: window, cornerWidth: 4, cornerHeight: 4, transform: nil))
context.clip()
// Developed at the top, still charcoal at the bottom.
context.drawLinearGradient(
    linear([color(0xE9D9CC), color(0xC9B3A3), color(0x3A3330), color(0x262626)], [0, 0.38, 0.78, 1]),
    start: CGPoint(x: window.midX, y: window.minY), end: CGPoint(x: window.midX, y: window.maxY), options: []
)
// A flat head-and-shoulders figure, developing with the rest of the image.
let figure = CGMutablePath()
let headCenter = CGPoint(x: window.midX, y: window.minY + window.height * 0.40)
let headRadius = window.width * 0.155
figure.addEllipse(in: CGRect(
    x: headCenter.x - headRadius, y: headCenter.y - headRadius * 1.12,
    width: headRadius * 2, height: headRadius * 2.24
))
let shoulderTop = headCenter.y + headRadius * 1.25
figure.move(to: CGPoint(x: window.minX + window.width * 0.12, y: window.maxY + 2))
figure.addCurve(
    to: CGPoint(x: window.midX, y: shoulderTop),
    control1: CGPoint(x: window.minX + window.width * 0.14, y: shoulderTop + 40),
    control2: CGPoint(x: window.midX - 120, y: shoulderTop)
)
figure.addCurve(
    to: CGPoint(x: window.maxX - window.width * 0.12, y: window.maxY + 2),
    control1: CGPoint(x: window.midX + 120, y: shoulderTop),
    control2: CGPoint(x: window.maxX - window.width * 0.14, y: shoulderTop + 40)
)
figure.closeSubpath()
context.addPath(figure)
context.clip()
context.drawLinearGradient(
    linear([color(0x5C4A40), color(0x46382F), color(0x2A2523, 0.0)], [0, 0.45, 0.9]),
    start: CGPoint(x: window.midX, y: headCenter.y - headRadius), end: CGPoint(x: window.midX, y: window.maxY),
    options: [.drawsBeforeStartLocation]
)
context.restoreGState()

// Silver grain where the image has not developed yet: denser toward the bottom. A fixed seed keeps it stable.
var seed: UInt64 = 0x5EED_1CE5
func random() -> CGFloat {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
}
context.saveGState()
context.addPath(CGPath(roundedRect: window, cornerWidth: 4, cornerHeight: 4, transform: nil))
context.clip()
for _ in 0 ..< 2600 {
    let y = window.minY + window.height * (0.45 + 0.55 * sqrt(random()))
    let x = window.minX + window.width * random()
    let size = 2 + random() * 3
    context.setFillColor(color(0x8A817B, 0.10 + 0.22 * random()))
    context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
}
context.restoreGState()

// The bottom margin: the trigger, highlighted, then the start of a caption line.
let marginY = window.maxY + (card.maxY - window.maxY) / 2
let trigger = CGRect(x: window.minX, y: marginY - 17, width: 150, height: 34)
context.addPath(CGPath(roundedRect: trigger, cornerWidth: 9, cornerHeight: 9, transform: nil))
context.setFillColor(developer)
context.fillPath()
let caption = CGRect(x: trigger.maxX + 22, y: marginY - 7, width: window.maxX - trigger.maxX - 22, height: 14)
context.addPath(CGPath(roundedRect: caption, cornerWidth: 7, cornerHeight: 7, transform: nil))
context.setFillColor(color(0xCFD1D6))
context.fillPath()

guard let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else { fatalError("could not encode") }
try data.write(to: URL(fileURLWithPath: output))
print(output)
