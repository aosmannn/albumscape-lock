//
//  GlassShader.swift
//
//  A port of the liquid glass shader from github.com/ybouane/liquidglass (WebGL) to Swift. The card is drawn once, on the
//  CPU, from the wallpaper that lies behind it: the picture is bent through a rounded, bevelled lens (refraction), split
//  slightly into colours at the edge (chromatic aberration), softened (blur), and lit with a rim, an inner glow and a
//  Fresnel sheen. The numbers are that library's defaults for its "regular" glass.
//

import AppKit
import CoreImage
import simd

enum GlassShader {
    struct Config {
        var refraction: Float = 0.69
        var chromAberration: Float = 0.05
        var edgeHighlight: Float = 0.05
        var specular: Float = 0.0
        var fresnel: Float = 1.0
        var cornerRadius: Float = 40  // the library's "Regular Glass" panel: corner 40, bevel 40, no blur
        var zRadius: Float = 40
        var saturation: Float = 0
        var brightness: Float = -0.2  // a little darker than the picture, so white text reads on it
        var blurPoints: Float = 0
    }

    /// The glass for a card of `size` points whose top-left corner is at `origin` on a screen of `screenSize` points.
    static func render(wallpaper: NSImage, screenSize: CGSize, origin: CGPoint, size: CGSize, scale: CGFloat = 2, config c: Config = Config()) -> NSImage? {
        let s = Float(scale)
        let margin: CGFloat = 60
        let cropW = Int((size.width + margin * 2) * scale), cropH = Int((size.height + margin * 2) * scale)
        guard let sharpImage = crop(wallpaper, screenSize: screenSize, origin: CGPoint(x: origin.x - margin, y: origin.y - margin), width: cropW, height: cropH, scale: scale),
              let blurImage = c.blurPoints > 0 ? blurred(sharpImage, sigma: CGFloat(c.blurPoints) * scale) : sharpImage,
              let sharp = pixels(sharpImage, width: cropW, height: cropH), let blur = pixels(blurImage, width: cropW, height: cropH) else { return nil }

        let outW = Int(size.width * scale), outH = Int(size.height * scale)
        var out = [UInt8](repeating: 0, count: outW * outH * 4)
        let half = SIMD2<Float>(Float(size.width) / 2, Float(size.height) / 2)
        let r = min(c.cornerRadius, min(half.x, half.y))
        let zR = c.zRadius
        let e: Float = 2
        let marginPx = Float(margin) * s

        for y in 0..<outH {
            for x in 0..<outW {
                let local = SIMD2<Float>((Float(x) + 0.5) / s - half.x, (Float(y) + 0.5) / s - half.y)  // points from the centre, y down
                let sdf = rrSDF(local, half, r)
                if sdf > 0.5 { continue }  // outside the card: stays clear
                let mask = 1 - smoothstep(-1.5, 0.5, sdf)
                let maxD = min(half.x, half.y)
                let inside = -sdf
                let edge = smoothstep(maxD * 0.35, 0, inside)

                // surface normal from the bevel height field
                let hC = bevel(inside, zR)
                let hR = bevel(-rrSDF(local + SIMD2(e, 0), half, r), zR), hL = bevel(-rrSDF(local - SIMD2(e, 0), half, r), zR)
                let hU = bevel(-rrSDF(local + SIMD2(0, e), half, r), zR), hD = bevel(-rrSDF(local - SIMD2(0, e), half, r), zR)
                let hGrad = SIMD2<Float>(hR - hL, hU - hD) / (2 * e)
                let n = simd_normalize(SIMD3<Float>(-hGrad.x, -hGrad.y, 1))
                let depth = smoothstep(0, zR, inside)

                // biconvex refraction, then a pull toward the centre
                let refrPow: Float = 1 - 1 / 1.5
                let thickNorm = (hC * 2) / max(zR * 2, 1)
                let exitRefr = hGrad * refrPow, entryRefr = hGrad * refrPow
                let through = entryRefr * thickNorm * 0.5
                var refr = (exitRefr + entryRefr + through) * c.refraction * 30
                refr += (-local / SIMD2(max(half.x, 1), max(half.y, 1))) * c.refraction * 4 * depth

                // chromatic aberration
                let caS = c.chromAberration * 18 * (edge * 0.7 + 0.3) * 2
                let caD = SIMD2<Float>(n.x, n.y) * caS

                // where this pixel sits in the cropped wallpaper (points -> crop pixels)
                let base = SIMD2<Float>((Float(x) + 0.5) + refr.x * s + marginPx, (Float(y) + 0.5) + refr.y * s + marginPx)
                let d = caD * s
                let sh = SIMD3<Float>(sample(sharp, cropW, cropH, base + d).x, sample(sharp, cropW, cropH, base).y, sample(sharp, cropW, cropH, base - d).z)
                let bl = SIMD3<Float>(sample(blur, cropW, cropH, base + d).x, sample(blur, cropW, cropH, base).y, sample(blur, cropW, cropH, base - d).z)
                var col = sh + (bl - sh) * (1 - edge * 0.15)

                col *= 1 + c.brightness
                let lum = simd_dot(col, SIMD3<Float>(0.299, 0.587, 0.114))
                col = SIMD3(repeating: lum) + (col - SIMD3(repeating: lum)) * (1 + c.saturation)
                col *= 1 + 0.06 * depth

                let fres = powf(1 - abs(n.z), 4) * c.fresnel
                let v = SIMD3<Float>(0, 0, 1)
                func spec(_ l: SIMD3<Float>, _ p: Float) -> Float { powf(max(simd_dot(n, simd_normalize(simd_normalize(l) + v)), 0), p) }
                let totalSpec = (spec(SIMD3(0.4, 0.7, 1), 90) + spec(SIMD3(-0.3, -0.5, 1), 50) * 0.3
                                 + powf(max(simd_dot(n, simd_normalize(SIMD3(0.1, 0.3, 1))), 0), 6) * 0.1 + spec(SIMD3(0, 0.9, 0.4), 120) * 0.6) * c.specular

                let borderWidth: Float = 1.5
                var innerStroke = smoothstep(-borderWidth - 1, -borderWidth, sdf) * (1 - smoothstep(-1, 0, sdf))
                innerStroke *= 0.4 + 0.6 * (0.5 + 0.5 * (-local.y / half.y))
                let rim = edge * c.edgeHighlight * 0.22
                let innerGlow = smoothstep(5, 0, -sdf) * c.edgeHighlight * 0.15
                let envRefl = (n.y * 0.5 + 0.5) * fres * 0.08

                var fin = col + SIMD3(repeating: totalSpec + rim + innerGlow + innerStroke * c.edgeHighlight * 0.55 + envRefl)
                fin = fin + (SIMD3(repeating: 1) - fin) * (fres * 0.2)

                let i = (y * outW + x) * 4
                // premultiplied
                out[i] = UInt8(clamping: Int((min(max(fin.x, 0), 1) * mask) * 255))
                out[i + 1] = UInt8(clamping: Int((min(max(fin.y, 0), 1) * mask) * 255))
                out[i + 2] = UInt8(clamping: Int((min(max(fin.z, 0), 1) * mask) * 255))
                out[i + 3] = UInt8(clamping: Int(mask * 255))
            }
        }
        return out.withUnsafeMutableBytes { raw -> NSImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = ctx.makeImage() else { return nil }
            return NSImage(cgImage: cg, size: size)
        }
    }

    // MARK: Shader helpers

    private static func rrSDF(_ p: SIMD2<Float>, _ b: SIMD2<Float>, _ r: Float) -> Float {
        let q = SIMD2(abs(p.x), abs(p.y)) - b + SIMD2(repeating: r)
        return min(max(q.x, q.y), 0) + simd_length(SIMD2(max(q.x, 0), max(q.y, 0))) - r
    }

    private static func bevel(_ d: Float, _ zR: Float) -> Float {
        if d <= 0 { return 0 }
        if d >= zR { return zR }
        return sqrtf(d * (2 * zR - d))
    }

    private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Bilinear sample, in crop pixels, colours 0...1.
    private static func sample(_ buf: [UInt8], _ w: Int, _ h: Int, _ p: SIMD2<Float>) -> SIMD3<Float> {
        let x = min(max(p.x - 0.5, 0), Float(w - 1)), y = min(max(p.y - 0.5, 0), Float(h - 1))
        let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let fx = x - Float(x0), fy = y - Float(y0)
        func px(_ xx: Int, _ yy: Int) -> SIMD3<Float> {
            let i = (yy * w + xx) * 4
            return SIMD3(Float(buf[i]), Float(buf[i + 1]), Float(buf[i + 2])) / 255
        }
        let top = px(x0, y0) * (1 - fx) + px(x1, y0) * fx
        let bottom = px(x0, y1) * (1 - fx) + px(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }

    // MARK: Pictures

    /// The part of the wallpaper (filled to the screen like the desktop does) that lies under the card and its margin.
    private static func crop(_ image: NSImage, screenSize: CGSize, origin: CGPoint, width: Int, height: Int, scale: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let fill = max(screenSize.width / image.size.width, screenSize.height / image.size.height)
        let drawn = CGSize(width: image.size.width * fill, height: image.size.height * fill)
        let rect = CGRect(x: ((screenSize.width - drawn.width) / 2 - origin.x) * scale, y: ((screenSize.height - drawn.height) / 2 - origin.y) * scale,
                          width: drawn.width * scale, height: drawn.height * scale)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func blurred(_ image: CGImage, sigma: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(sigma, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    private static func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }
}
