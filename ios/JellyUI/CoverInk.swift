import SwiftUI
import UIKit

/*
 * The web's colours taken from the cover (inkFor / dominant / edgeGradients):
 *  - ink: the colour of all text, icons and bars on the full screen: the inverse of the cover's dominant colour, pulled toward white,
 *    with enough contrast against the backdrop;
 *  - top / bottom: the colour of the fades over the top and the bottom of the screen (the cover's own edge colours).
 */

typealias Rgb = (Double, Double, Double)

struct Ink: Equatable {
    var r: Double, g: Double, b: Double
    var a: Double
    static let white = Ink(r: 240, g: 240, b: 240, a: 0.95)
    func color(_ k: Double = 1) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255).opacity(a * k) }
    var solid: Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
}

struct CoverLook: Equatable {
    var ink: Ink = .white
    var top: Rgb = (38, 38, 42)
    var bottom: Rgb = (38, 38, 42)
    static func == (a: CoverLook, b: CoverLook) -> Bool { a.ink == b.ink && a.top == b.top && a.bottom == b.bottom }
}

private struct InkKey: EnvironmentKey { static let defaultValue = Ink.white }
extension EnvironmentValues {
    var ink: Ink { get { self[InkKey.self] } set { self[InkKey.self] = newValue } }
}

@MainActor
enum CoverInk {
    private static func luma(_ c: Rgb) -> Double { 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2 }
    private static func lin(_ v: Double) -> Double { let s = v / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    private static func relLum(_ c: Rgb) -> Double { 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2) }
    private static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    private static func hueOf(_ c: Rgb) -> Double {
        let r = c.0 / 255, g = c.1 / 255, b = c.2 / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        if d == 0 { return 0 }
        var h: Double
        if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    /// The most common colour (4 bits a channel) of rows y0..<y1 of an RGBA picture, as the mean of that bucket.
    static func dominant(_ px: [UInt8], _ w: Int, _ y0: Int, _ y1: Int) -> Rgb {
        var count: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for y in y0..<y1 {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if px[o + 3] < 16 { continue }
                let k = (Int(px[o] >> 4) << 8) | (Int(px[o + 1] >> 4) << 4) | Int(px[o + 2] >> 4)
                var e = count[k] ?? (0, 0, 0, 0)
                e.n += 1; e.r += Int(px[o]); e.g += Int(px[o + 1]); e.b += Int(px[o + 2])
                count[k] = e
            }
        }
        guard let best = count.values.max(by: { $0.n < $1.n }) else { return (38, 38, 42) }
        return ((Double(best.r) / Double(best.n)).rounded(), (Double(best.g) / Double(best.n)).rounded(), (Double(best.b) / Double(best.n)).rounded())
    }

    private static func meanLuma(_ px: [UInt8], _ w: Int, _ y0: Int, _ y1: Int) -> Double {
        var s = 0.0, n = 0.0
        for y in y0..<y1 { for x in 0..<w { let o = (y * w + x) * 4; s += 0.299 * Double(px[o]) + 0.587 * Double(px[o + 1]) + 0.114 * Double(px[o + 2]); n += 1 } }
        return n > 0 ? s / n : 0
    }

    /// The colour of a fade: the edge's dominant colour, scaled so its brightness is the edge's average brightness x .35.
    static func edgeColour(_ px: [UInt8], _ w: Int, _ y0: Int, _ y1: Int) -> Rgb {
        let c = dominant(px, w, y0, y1)
        let lc = luma(c)
        let target = meanLuma(px, w, y0, y1) * 0.35
        let k = lc > 1 ? min(4, target / lc) : 0
        return (min(255, (c.0 * k).rounded()), min(255, (c.1 * k).rounded()), min(255, (c.2 * k).rounded()))
    }

    /// The text colour for a cover whose dominant colour is `c` (the web's inkFor).
    static func inkFor(_ c: Rgb) -> Ink {
        let d = max(c.0, c.1, c.2) - min(c.0, c.1, c.2)
        var ink: Rgb
        if d < 26 { ink = (255, 255, 255) } else {
            let h = hueOf(c)
            let w = (h >= 15 && h <= 75) ? 0.7 : (d >= 60 ? 0.45 : 0.2)
            func f(_ v: Double) -> Double { let inv = 255 - v; return (inv + (255 - inv) * w).rounded() }
            ink = (f(c.0), f(c.1), f(c.2))
        }
        let L = luma(c) / 255
        var a = L >= 0.5 ? 0.5 : min(1, 0.5 + (0.5 - L))
        // what the ink sits on: the cover darkened to 35 % and lifted by the shader's 1.75
        let bg: Rgb = (min(255, c.0 * 0.6), min(255, c.1 * 0.6), min(255, c.2 * 0.6))
        let bgL = relLum(bg)
        for _ in 0..<10 {
            let over: Rgb = (ink.0 * a + bg.0 * (1 - a), ink.1 * a + bg.1 * (1 - a), ink.2 * a + bg.2 * (1 - a))
            if contrast(relLum(over), bgL) >= 4.5 { break }
            if a < 1 { a = min(1, a + 0.12) } else {
                let to: Double = bgL < 0.4 ? 255 : 0
                ink = ((ink.0 + (to - ink.0) * 0.3).rounded(), (ink.1 + (to - ink.1) * 0.3).rounded(), (ink.2 + (to - ink.2) * 0.3).rounded())
            }
        }
        return Ink(r: ink.0, g: ink.1, b: ink.2, a: (a * 1000).rounded() / 1000)
    }

    /// The fade's alpha at each stop (top fade from the top edge down; the bottom one is the mirror image).
    static let fadeAlpha: [Double] = [0.96, 0.93, 0.85, 0.72, 0.55, 0.36, 0.19, 0.07, 0]
    static let fadeAt: [Double] = [0, 0.08, 0.16, 0.26, 0.38, 0.52, 0.66, 0.82, 1]

    // MARK: reading a cover

    private static var looks: [URL: CoverLook] = [:]
    private static let N = 40

    static func cached(_ u: URL) -> CoverLook? { looks[u] }

    static func load(_ u: URL) async -> CoverLook? {
        if let l = looks[u] { return l }
        guard let img = await ImageStore.shared.load(u), let cg = img.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: N * N * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: N, height: N, bitsPerComponent: 8, bytesPerRow: N * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: N, height: N))
            return true
        }
        guard ok else { return nil }
        let look = CoverLook(ink: inkFor(dominant(px, N, 0, N)), top: edgeColour(px, N, 0, 10), bottom: edgeColour(px, N, N - 10, N))
        looks[u] = look
        if looks.count > 20, let k = looks.keys.first(where: { $0 != u }) { looks[k] = nil }
        return look
    }
}

/// The web's dither over the backdrop: a 128 px tile of random white and black pixels at 0-3 / 255 opacity (made once).
enum Grain {
    static let image: UIImage? = {
        let n = 128
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for i in 0..<(n * n) {
            let v: UInt8 = Bool.random() ? 255 : 0
            let a = UInt8.random(in: 0...3)
            // premultiplied
            bytes[i * 4] = UInt8(Int(v) * Int(a) / 255); bytes[i * 4 + 1] = bytes[i * 4]; bytes[i * 4 + 2] = bytes[i * 4]; bytes[i * 4 + 3] = a
        }
        let data = Data(bytes) as CFData
        guard let prov = CGDataProvider(data: data),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }()
}
