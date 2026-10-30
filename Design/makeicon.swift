// Renders the LectureReflector app icon: a bright moon over still water with its
// reflection — 明镜 ("bright mirror") — in Kevin's Michigan–Minnesota split
// palette: navy #00274C upper-left, maroon #7A0019 lower-right, meeting in a
// hard diagonal that doubles as the waterline; maize moon, gold shimmer.
// Output: Design/app-icon-1024.png
// Run: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift Design/makeicon.swift
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Palette.
let navy = rgba(0x00, 0x27, 0x4C)      // Michigan navy
let maroon = rgba(0x7A, 0x00, 0x19)    // Minnesota maroon
let maize = rgba(0xFF, 0xCB, 0x05)     // UMich maize (focal)
func gold(_ a: CGFloat) -> CGColor { rgba(0xFF, 0xCC, 0x33, a) }  // UMN gold (secondary)
let cream = rgba(0xFF, 0xF8, 0xE1)     // light detail
func ink(_ a: CGFloat) -> CGColor { rgba(0x1A, 0x1A, 0x2E, a) }   // fine lines

// macOS Big Sur–style icon: rounded rect with ~10% margin on a transparent canvas.
let margin: CGFloat = 100
let iconRect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let cornerRadius: CGFloat = 185
let squircle = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// Everything below is clipped to the icon shape.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Hard diagonal split: navy sky upper-left, maroon water lower-right.
// The split line runs from the left edge down to the right edge and serves
// as the waterline. (CG origin is bottom-left.)
let splitLeft = CGPoint(x: iconRect.minX, y: iconRect.minY + iconRect.height * 0.56)
let splitRight = CGPoint(x: iconRect.maxX, y: iconRect.minY + iconRect.height * 0.30)
func splitY(at x: CGFloat) -> CGFloat {
    splitLeft.y + (splitRight.y - splitLeft.y) * (x - splitLeft.x) / (splitRight.x - splitLeft.x)
}

ctx.setFillColor(navy)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

ctx.setFillColor(maroon)
ctx.move(to: splitLeft)
ctx.addLine(to: splitRight)
ctx.addLine(to: CGPoint(x: iconRect.maxX, y: 0))
ctx.addLine(to: CGPoint(x: iconRect.minX, y: 0))
ctx.closePath()
ctx.fillPath()

// Stars in the navy sky — secondary elements, gold at ~55%.
let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (0.22, 0.87, 3.4, 0.55), (0.31, 0.78, 2.2, 0.45), (0.15, 0.70, 2.6, 0.5),
    (0.72, 0.88, 2.8, 0.55), (0.82, 0.76, 3.2, 0.55), (0.66, 0.71, 2.0, 0.4),
    (0.88, 0.63, 2.4, 0.45), (0.26, 0.62, 2.0, 0.35), (0.42, 0.83, 2.0, 0.4),
    (0.58, 0.90, 2.4, 0.45), (0.12, 0.60, 1.8, 0.35), (0.79, 0.52, 1.8, 0.35),
]
for (fx, fy, r, a) in stars {
    let x = iconRect.minX + fx * iconRect.width
    let y = iconRect.minY + fy * iconRect.height
    ctx.setFillColor(gold(a))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// Maize moon with soft gold glow, upper middle.
let moonCenter = CGPoint(x: size / 2, y: iconRect.minY + iconRect.height * 0.72)
let moonRadius: CGFloat = 118

let glow = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [gold(0.40), gold(0.12), gold(0)] as CFArray,
    locations: [0, 0.5, 1]
)!
ctx.drawRadialGradient(
    glow,
    startCenter: moonCenter, startRadius: moonRadius * 0.6,
    endCenter: moonCenter, endRadius: moonRadius * 2.6,
    options: []
)

let moonFill = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgba(0xFF, 0xD8, 0x3D), maize] as CFArray,
    locations: [0, 1]
)!
ctx.saveGState()
ctx.addEllipse(in: CGRect(
    x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius,
    width: 2 * moonRadius, height: 2 * moonRadius
))
ctx.clip()
ctx.drawLinearGradient(
    moonFill,
    start: CGPoint(x: moonCenter.x, y: moonCenter.y + moonRadius),
    end: CGPoint(x: moonCenter.x, y: moonCenter.y - moonRadius),
    options: []
)
ctx.restoreGState()

// Moon reflection: the moon mirrored across the diagonal waterline — a true
// mirror image (明镜), gold at ~55% and fading with depth, sliced by ripple
// gaps so it reads as still water rather than a second moon.
let dx = splitRight.x - splitLeft.x
let dy = splitRight.y - splitLeft.y
let dLen = (dx * dx + dy * dy).squareRoot()
let dir = CGPoint(x: dx / dLen, y: dy / dLen)          // along the waterline
// Mirror vertically at the waterline, directly below the moon — that's how
// the eye expects a reflection, even with a stylized diagonal shoreline.
// Foreshortened (×0.75) so the disc clears the bottom of the squircle.
let waterlineY = splitY(at: moonCenter.x)
let mirrorCenter = CGPoint(x: moonCenter.x, y: waterlineY - (moonCenter.y - waterlineY) * 0.75)
let mirrorRect = CGRect(
    x: mirrorCenter.x - moonRadius, y: mirrorCenter.y - moonRadius,
    width: 2 * moonRadius, height: 2 * moonRadius
)

// Keep the reflection strictly below the diagonal waterline.
ctx.saveGState()
ctx.move(to: splitLeft)
ctx.addLine(to: splitRight)
ctx.addLine(to: CGPoint(x: iconRect.maxX, y: 0))
ctx.addLine(to: CGPoint(x: iconRect.minX, y: 0))
ctx.closePath()
ctx.clip()

// The mirrored disc: brightest at the top (nearest the waterline), fading
// with depth. Everything is clipped to the disc so ripple slices stay inside.
ctx.saveGState()
ctx.addEllipse(in: mirrorRect)
ctx.clip()
let mirrorFill = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [gold(0.62), gold(0.26)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    mirrorFill,
    start: CGPoint(x: mirrorCenter.x, y: mirrorRect.maxY),
    end: CGPoint(x: mirrorCenter.x, y: mirrorRect.minY),
    options: []
)

// Ripple gaps: maroon slices parallel to the waterline cut through the disc,
// widening with depth, so the reflection shimmers like water.
ctx.setStrokeColor(maroon)
ctx.setLineCap(.round)
let gaps: [(CGFloat, CGFloat)] = [
    // (offset below disc top edge, in moon radii; line width)
    (0.50, 8),
    (0.92, 12),
    (1.34, 16),
    (1.74, 20),
]
let gapSlope = dir.y / dir.x
for (f, w) in gaps {
    let cy = mirrorRect.maxY - f * moonRadius
    let cx = mirrorCenter.x
    let reach = moonRadius * 1.2
    ctx.setLineWidth(w)
    ctx.move(to: CGPoint(x: cx - reach, y: cy - gapSlope * reach))
    ctx.addLine(to: CGPoint(x: cx + reach, y: cy + gapSlope * reach))
    ctx.strokePath()
}
ctx.restoreGState()

// Faint ripple lines in the water, parallel to the diagonal waterline —
// near-black navy fine lines that read on the maroon ground.
ctx.setStrokeColor(ink(0.22))
ctx.setLineWidth(3)
ctx.setLineCap(.round)
let ripples: [(CGFloat, CGFloat, CGFloat)] = [
    // (fraction below waterline, x0 fraction, x1 fraction)
    (0.10, 0.14, 0.34), (0.14, 0.58, 0.86), (0.24, 0.10, 0.30),
    (0.30, 0.62, 0.90), (0.42, 0.16, 0.38), (0.50, 0.60, 0.84),
    (0.62, 0.12, 0.36), (0.72, 0.58, 0.82),
]
let waterDepth = splitY(at: moonCenter.x) - iconRect.minY
let slope = (splitRight.y - splitLeft.y) / (splitRight.x - splitLeft.x)
for (f, x0, x1) in ripples {
    let ax = iconRect.minX + x0 * iconRect.width
    let bx = iconRect.minX + x1 * iconRect.width
    let ay = splitY(at: ax) - f * waterDepth
    let by = ay + slope * (bx - ax)
    ctx.move(to: CGPoint(x: ax, y: ay))
    ctx.addLine(to: CGPoint(x: bx, y: by))
    ctx.strokePath()
}
ctx.restoreGState()

// Crisp cream waterline along the diagonal split.
ctx.setStrokeColor(cream)
ctx.setLineWidth(4)
ctx.move(to: splitLeft)
ctx.addLine(to: splitRight)
ctx.strokePath()

ctx.restoreGState()

// Subtle inner edge highlight on the squircle.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
ctx.addPath(CGPath(
    roundedRect: iconRect.insetBy(dx: 2, dy: 2),
    cornerWidth: cornerRadius - 2, cornerHeight: cornerRadius - 2, transform: nil
))
ctx.setStrokeColor(rgba(255, 255, 255, 0.14))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: "Design/app-icon-1024.png")
try! png.write(to: out)
print("Wrote \(out.path)")
