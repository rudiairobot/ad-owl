import AppKit

/// Monochrome owl for the menu bar: eyes open while blocking is on, closed while it's off.
/// Same silhouette as the app icon, drawn as a template image so macOS tints it.
enum OwlGlyph {
    static let awake = make(awake: true)
    static let asleep = make(awake: false)

    private static func make(awake: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Icon coordinates: the owl spans x 270...754, y 236...838.
            let s: CGFloat = 16.5 / 602
            ctx.translateBy(x: 9 - 512 * s, y: 0.75 - 236 * s)
            ctx.scaleBy(x: s, y: s)

            let body = CGMutablePath()
            body.move(to: CGPoint(x: 318, y: 236))
            body.addQuadCurve(to: CGPoint(x: 512, y: 334), control: CGPoint(x: 432, y: 320))
            body.addQuadCurve(to: CGPoint(x: 706, y: 236), control: CGPoint(x: 592, y: 320))
            body.addCurve(to: CGPoint(x: 744, y: 470), control1: CGPoint(x: 744, y: 300), control2: CGPoint(x: 754, y: 400))
            body.addCurve(to: CGPoint(x: 512, y: 838), control1: CGPoint(x: 732, y: 662), control2: CGPoint(x: 622, y: 782))
            body.addCurve(to: CGPoint(x: 280, y: 470), control1: CGPoint(x: 402, y: 782), control2: CGPoint(x: 292, y: 662))
            body.addCurve(to: CGPoint(x: 318, y: 236), control1: CGPoint(x: 270, y: 400), control2: CGPoint(x: 280, y: 300))
            body.closeSubpath()
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(body); ctx.fillPath()

            // Punch out eyes and beak.
            ctx.setBlendMode(.clear)
            let eyes: [CGFloat] = [424, 600]
            if awake {
                for x in eyes { ctx.addEllipse(in: CGRect(x: x - 90, y: 392, width: 180, height: 180)) }
                ctx.fillPath()
            } else {
                ctx.setLineWidth(46); ctx.setLineCap(.round)
                for x in eyes {
                    ctx.move(to: CGPoint(x: x - 50, y: 476))
                    ctx.addQuadCurve(to: CGPoint(x: x + 50, y: 476), control: CGPoint(x: x, y: 540))
                }
                ctx.strokePath()
            }
            ctx.move(to: CGPoint(x: 470, y: 590)); ctx.addLine(to: CGPoint(x: 554, y: 590)); ctx.addLine(to: CGPoint(x: 512, y: 664))
            ctx.closePath(); ctx.fillPath()

            if awake {   // pupils
                ctx.setBlendMode(.normal)
                for x in eyes { ctx.addEllipse(in: CGRect(x: x - 46, y: 448, width: 92, height: 92)) }
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = awake ? "Ad-Owl: blocking on" : "Ad-Owl: blocking off"
        return image
    }
}
