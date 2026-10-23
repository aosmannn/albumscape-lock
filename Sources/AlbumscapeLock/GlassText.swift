//
//  GlassText.swift
//
//  The clock's digits as glass, drawn the way the player card's glass is: the picture behind them (the album cover, as
//  it fills the screen) is bent through each digit like a rounded lens, split a little into colours at the edges, and lit
//  with a bright rim and a sheen from above. Drawn once per minute (and when the album changes), not every frame.
//

import AppKit
import CoreImage
import simd

enum GlassText {
    /// `top` is the distance of the digits' box from the top of the screen, in points.
    static func render(_ text: String, fontSize: CGFloat, backdrop: NSImage?, screenSize: CGSize, top: CGFloat, scale: CGFloat = 2) -> NSImage? {
        let base = NSFont.systemFont(ofSize: fontSize * scale, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize * scale) } ?? base
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let pad = 16 * scale
        let textSize = string.size()
        let w = Int(ceil(textSize.width + pad * 2)), h = Int(ceil(textSize.height + pad * 2))
        guard w > 0, h > 0 else { return nil }

        // 1. the digits' shape
        guard let maskCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: maskCtx, flipped: false)
        string.draw(at: NSPoint(x: pad, y: pad))
        NSGraphicsContext.restoreGraphicsState()
        guard let maskImage = maskCtx.makeImage(), let maskPx = GlassShader.pixels(maskImage, width: w, height: h),
              // 2. a soft height field: the shape blurred, so each stroke is a rounded ridge, highest along its middle
              let heightImage = GlassShader.blurred(maskImage, sigma: 7 * scale), let heightPx = GlassShader.pixels(heightImage, width: w, height: h) else { return nil }

        // 3. what lies behind the digits on screen (the cover, filled to the screen as it is shown), with a margin
        let margin: CGFloat = 40
        let boxW = CGFloat(w) / scale, boxH = CGFloat(h) / scale
        let origin = CGPoint(x: (screenSize.width - boxW) / 2 - margin, y: top - margin)
        let cropW = Int((boxW + margin * 2) * scale), cropH = Int((boxH + margin * 2) * scale)
        var back: [UInt8]?
        if let backdrop, let cropped = GlassShader.crop(backdrop, screenSize: screenSize, origin: origin, width: cropW, height: cropH, scale: scale) {
            back = GlassShader.pixels(cropped, width: cropW, height: cropH)
        }

        var out = [UInt8](repeating: 0, count: w * h * 4)
        let marginPx = Float(margin * scale)
        func alpha(_ x: Int, _ y: Int) -> Float { Float(maskPx[(min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4 + 3]) / 255 }
        func height(_ x: Int, _ y: Int) -> Float { Float(heightPx[(min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4 + 3]) / 255 }
        let light = simd_normalize(SIMD3<Float>(-0.35, -0.75, 0.55))  // from the upper left (y grows downward here)
        for y in 0..<h {
            for x in 0..<w {
                let a = alpha(x, y)
                if a <= 0.004 { continue }
                let gx = (height(x + 2, y) - height(x - 2, y)) / 4  // rows run top to bottom, like the screen
                let gy = (height(x, y + 2) - height(x, y - 2)) / 4
                let n = simd_normalize(SIMD3<Float>(-gx * 26, -gy * 26, 1))
                let hC = height(x, y)
                let screenY = Float(y)
                var col: SIMD3<Float>
                if let back {
                    let refr = SIMD2<Float>(gx, gy) * 260 * Float(scale)  // bend the picture toward each stroke's middle
                    let base = SIMD2<Float>(Float(x) + 0.5 + marginPx, screenY + 0.5 + marginPx) - refr
                    let ca = SIMD2<Float>(n.x, n.y) * 3 * Float(scale)
                    col = SIMD3(GlassShader.sample(back, cropW, cropH, base + ca).x, GlassShader.sample(back, cropW, cropH, base).y,
                                GlassShader.sample(back, cropW, cropH, base - ca).z)
                    col = col + (SIMD3(repeating: 1) - col) * 0.24  // glass lifts what's behind it a little
                } else {
                    col = SIMD3(repeating: 0.82 - 0.25 * Float(y) / Float(h))  // nothing behind: a plain light glass
                }
                // edges: lit where they face the light (upper left), shaded where they face away
                let edge = GlassShader.smoothstep(0.62, 0.12, hC)
                let side = simd_length(SIMD2(n.x, n.y)) > 0.001 ? simd_normalize(SIMD2(n.x, n.y)) : SIMD2<Float>(0, 0)
                let facing = simd_dot(side, simd_normalize(SIMD2<Float>(-0.45, -0.9)))
                col += SIMD3(repeating: edge * max(facing, 0) * 0.7)
                col *= 1 - edge * max(-facing, 0) * 0.38
                let fres = powf(1 - abs(n.z), 2.5)
                col = col + (SIMD3(repeating: 1) - col) * min(1, fres * 0.35)
                let spec = powf(max(simd_dot(n, light), 0), 9) * 0.45
                col += SIMD3(repeating: spec)
                let i = (y * w + x) * 4
                out[i] = UInt8(clamping: Int(min(max(col.x, 0), 1) * a * 255))
                out[i + 1] = UInt8(clamping: Int(min(max(col.y, 0), 1) * a * 255))
                out[i + 2] = UInt8(clamping: Int(min(max(col.z, 0), 1) * a * 255))
                out[i + 3] = UInt8(clamping: Int(a * 255))
            }
        }
        return out.withUnsafeMutableBytes { raw -> NSImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = ctx.makeImage() else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: boxW, height: boxH))
        }
    }
}

/// Keeps the clock's glass picture current: drawn again when the minute or the album changes, off the main thread.
@MainActor
final class GlassClock: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var key = ""
    private var wanted = ""
    private var cover: (url: URL, image: NSImage)?

    func update(time: String, cover url: URL?, top: CGFloat) async {
        let k = time + "|" + (url?.absoluteString ?? "")
        guard k != wanted else { return }
        wanted = k
        var backdrop: NSImage?
        if let url {
            if let cached = cover, cached.url == url { backdrop = cached.image }
            else if let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                cover = (url, image); backdrop = image
            }
        }
        guard wanted == k else { return }
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1470, height: 956)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let picture = backdrop
        let drawn = await Task.detached(priority: .userInitiated) {
            GlassText.render(time, fontSize: 124, backdrop: picture, screenSize: screen, top: top, scale: scale)
        }.value
        guard wanted == k, let drawn else { return }
        image = drawn
        key = k
    }
}
