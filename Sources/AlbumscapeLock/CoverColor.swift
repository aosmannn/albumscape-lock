//
//  CoverColor.swift
//
//  The song's colour, taken from the cover itself: the hue that most of the cover's colourful pixels share, made bright
//  enough to read on a dark picture. (Apple's page lists text colours that are chosen to contrast with the cover, so on
//  a purple album one of them can be a neon green; the cover's own colours can't be.)
//

import AppKit
import SwiftUI

enum CoverColor {
    static func vivid(from url: URL) async -> Color? {
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSBitmapImageRep(data: data) else { return nil }
        let side = 32
        guard let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: small) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        // 24 hue buckets, each counting how colourful (saturated and bright) the pixels in it are
        let buckets = 24
        var weight = [Double](repeating: 0, count: buckets)
        var sum = [(h: Double, s: Double, b: Double)](repeating: (0, 0, 0), count: buckets)
        var average = (r: 0.0, g: 0.0, b: 0.0)
        for x in 0..<side { for y in 0..<side {
            guard let c = small.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            average.r += Double(c.redComponent); average.g += Double(c.greenComponent); average.b += Double(c.blueComponent)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            guard s > 0.22, b > 0.2 else { continue }  // greys and near-blacks don't give a cover its colour
            let i = min(buckets - 1, Int(h * CGFloat(buckets)))
            let w = Double(s * b)
            weight[i] += w
            sum[i].h += Double(h) * w; sum[i].s += Double(s) * w; sum[i].b += Double(b) * w
        } }
        if let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0.5 {
            let w = weight[best]
            let h = sum[best].h / w, s = sum[best].s / w, b = sum[best].b / w
            return Color(hue: h, saturation: min(max(s, 0.45), 0.85), brightness: max(b, 0.82))
        }
        // A cover with no real colour: its average, as a light grey with a hint of it
        let n = Double(side * side)
        let (r, g, b) = (average.r / n, average.g / n, average.b / n)
        let lift = max(1, 0.8 / max(r, g, b, 0.01))
        return Color(red: min(1, r * lift), green: min(1, g * lift), blue: min(1, b * lift))
    }
}
