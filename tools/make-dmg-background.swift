// Draws the picture behind the installer window (the disk image you drag the app out of): 660 x 400 points, drawn at 2x.
// Light, in the logo's cream, so Finder's own (dark) icon labels read on it.
// Run: swift tools/make-dmg-background.swift out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let W: CGFloat = 660, H: CGFloat = 400, s: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * s), pixelsHigh: Int(H * s), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let ink = NSColor(red: 0.067, green: 0.067, blue: 0.063, alpha: 1)
let cream = NSColor(red: 0.929, green: 0.894, blue: 0.827, alpha: 1)
let paper = NSColor(red: 0.965, green: 0.945, blue: 0.906, alpha: 1)
let red = NSColor(red: 0.898, green: 0.251, blue: 0.184, alpha: 1)

/// A rectangle given in points from the top-left, as Finder places icons.
func box(_ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: (H - yTop - h) * s, width: w * s, height: h * s) }
func point(_ x: CGFloat, _ yTop: CGFloat) -> NSPoint { NSPoint(x: x * s, y: (H - yTop) * s) }

// paper, lighter in the middle
cream.setFill(); NSRect(x: 0, y: 0, width: W * s, height: H * s).fill()
NSGradient(colors: [paper, cream])!.draw(fromCenter: point(330, 175), radius: 0, toCenter: point(330, 175), radius: 360 * s, options: [.drawsAfterEndingLocation])

// the logo's record, peeking in from the right edge behind everything
let rc = point(700, 175)
for (i, r) in [150, 128, 96, 60].enumerated() {
    let p = NSBezierPath(ovalIn: NSRect(x: rc.x - CGFloat(r) * s, y: rc.y - CGFloat(r) * s, width: CGFloat(r) * 2 * s, height: CGFloat(r) * 2 * s))
    p.lineWidth = (i == 0 ? 6 : 2) * s
    ink.withAlphaComponent(i == 0 ? 0.06 : 0.045).setStroke(); p.stroke()
}
red.withAlphaComponent(0.10).setFill()
NSBezierPath(ovalIn: NSRect(x: rc.x - 30 * s, y: rc.y - 30 * s, width: 60 * s, height: 60 * s)).fill()

// soft wells where the two icons sit (centres at x 170 and 490, y 168 from the top)
for x in [170.0, 490.0] {
    let well = NSBezierPath(roundedRect: box(CGFloat(x) - 78, 92, 156, 176), xRadius: 30 * s, yRadius: 30 * s)
    ink.withAlphaComponent(0.045).setFill(); well.fill()
    ink.withAlphaComponent(0.06).setStroke(); well.lineWidth = 1 * s; well.stroke()
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, top: CGFloat, mono: Bool = false) {
    let base = mono ? NSFont.monospacedSystemFont(ofSize: size * s, weight: weight) : NSFont.systemFont(ofSize: size * s, weight: weight)
    let font = mono ? base : (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size * s) } ?? base)
    let a = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: mono ? 0 : -0.2 * s])
    let size = a.size()
    a.draw(at: NSPoint(x: centerX * s - size.width / 2, y: (H - top) * s - size.height))
}

// headline
text("Drag to install", size: 24, weight: .heavy, color: ink, centerX: 330, top: 30)
text("Drop Albumscape Lock on your Applications folder", size: 13, weight: .medium, color: ink.withAlphaComponent(0.55), centerX: 330, top: 64)

// the arrow between the wells
let ay: CGFloat = 168
let dots = NSBezierPath()
dots.lineWidth = 5 * s; dots.lineCapStyle = .round
dots.setLineDash([0.1 * s, 12 * s], count: 2, phase: 0)
dots.move(to: point(268, ay)); dots.line(to: point(380, ay))
red.setStroke(); dots.stroke()
let head = NSBezierPath()
head.lineWidth = 5 * s; head.lineCapStyle = .round; head.lineJoinStyle = .round
head.move(to: point(378, ay - 12)); head.line(to: point(392, ay)); head.line(to: point(378, ay + 12))
head.stroke()

// the one extra step, because the app isn't registered with Apple yet: done in System Settings, no Terminal
text("The first time, your Mac asks if you trust it:", size: 11.5, weight: .semibold, color: ink.withAlphaComponent(0.5), centerX: 330, top: 296)
let pill = NSBezierPath(roundedRect: box(70, 318, 520, 40), xRadius: 12 * s, yRadius: 12 * s)
ink.setFill(); pill.fill()
text("System Settings  ›  Privacy & Security  ›  Open Anyway", size: 13, weight: .semibold, color: cream, centerX: 330, top: 329)

NSGraphicsContext.restoreGraphicsState()
rep.size = NSSize(width: W, height: H)  // 144 dpi: Finder draws it at 660 x 400 points, sharp on a Retina screen
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
