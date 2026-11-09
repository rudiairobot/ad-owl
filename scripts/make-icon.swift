// Draws the Ad-Owl app icon (an owl whose body is a shield) as a 1024px PNG.
// Usage: swift scripts/make-icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)   // top-left origin

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}
func linear(_ path: CGPath, _ g: CGGradient, _ a: CGPoint, _ b: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func radial(_ path: CGPath, _ g: CGGradient, _ c: CGPoint, _ r: CGFloat) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: .drawsAfterEndLocation)
    ctx.restoreGState()
}
func shadowed(_ path: CGPath, _ color: CGColor, blur: CGFloat, dy: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: color)   // offsets ignore the flip
    ctx.addPath(path); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
}
func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// Background squircle: magenta to deep violet, with a soft top gloss.
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
shadowed(tile, rgb(0x1A0033, 0.5), blur: 36, dy: 14)
linear(tile, gradient([rgb(0xFF5AD2), rgb(0xA62BE0), rgb(0x4B12A6)], [0, 0.5, 1]), P(180, 120), P(860, 940))
radial(tile, gradient([rgb(0xFF8BE6, 0.55), rgb(0xFF8BE6, 0)]), P(300, 300), 520)
linear(tile, gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)]), P(512, 100), P(512, 480))

// Owl body = shield: ear tufts on top, tapering to a point.
let body = CGMutablePath()
body.move(to: P(318, 236))
body.addQuadCurve(to: P(512, 334), control: P(432, 320))
body.addQuadCurve(to: P(706, 236), control: P(592, 320))
body.addCurve(to: P(744, 470), control1: P(744, 300), control2: P(754, 400))
body.addCurve(to: P(512, 838), control1: P(732, 662), control2: P(622, 782))
body.addCurve(to: P(280, 470), control1: P(402, 782), control2: P(292, 662))
body.addCurve(to: P(318, 236), control1: P(270, 400), control2: P(280, 300))
body.closeSubpath()
shadowed(body, rgb(0x24004A, 0.55), blur: 40, dy: 20)
linear(body, gradient([rgb(0xFFFFFF), rgb(0xF1E8FF), rgb(0xD7C2FF)], [0, 0.45, 1]), P(512, 236), P(512, 838))

// Facial discs: outline both first, then fill, so the overlap shows one merged shape.
ctx.setStrokeColor(rgb(0xC9B0FF)); ctx.setLineWidth(10)
ctx.addPath(circle(424, 482, 104)); ctx.strokePath()
ctx.addPath(circle(600, 482, 104)); ctx.strokePath()
for x in [CGFloat(424), 600] {
    let disc = circle(x, 482, 104)
    linear(disc, gradient([rgb(0xE9DCFF), rgb(0xFBF8FF)]), P(x, 378), P(x, 586))
}

// Eyes: amber iris, dark pupil, two highlights.
for x in [CGFloat(424), 600] {
    radial(circle(x, 486, 70), gradient([rgb(0xFFE07A), rgb(0xFFB020), rgb(0xF07800)], [0, 0.6, 1]), P(x - 10, 476), 74)
    ctx.addPath(circle(x, 490, 37)); ctx.setFillColor(rgb(0x1E0638)); ctx.fillPath()
    ctx.addPath(circle(x - 13, 476, 13)); ctx.setFillColor(rgb(0xFFFFFF, 0.95)); ctx.fillPath()
    ctx.addPath(circle(x + 13, 504, 6)); ctx.setFillColor(rgb(0xFFFFFF, 0.7)); ctx.fillPath()
}

// Beak.
let beak = CGMutablePath()
beak.move(to: P(486, 572)); beak.addLine(to: P(538, 572)); beak.addLine(to: P(512, 626)); beak.closeSubpath()
ctx.saveGState()
ctx.addPath(beak); ctx.setLineJoin(.round); ctx.setLineWidth(14); ctx.setStrokeColor(rgb(0xFF9A1F)); ctx.strokePath()
ctx.restoreGState()
linear(beak, gradient([rgb(0xFFC04D), rgb(0xFF8A00)]), P(512, 572), P(512, 626))

// Breast feathers.
ctx.setStrokeColor(rgb(0xB794FF)); ctx.setLineWidth(10); ctx.setLineCap(.round); ctx.setLineJoin(.round)
for (x, y) in [(CGFloat(466), CGFloat(694)), (558, 694), (512, 744)] {
    ctx.move(to: P(x - 20, y - 9)); ctx.addLine(to: P(x, y + 9)); ctx.addLine(to: P(x + 20, y - 9))
}
ctx.strokePath()

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(url.path)")
