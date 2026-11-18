import SwiftUI
import UIKit

/// The cover shrunk to 6x6 colours (36 cells of r, g, b), the form the shader reads.
enum CoverColours {
    private static var cache: [URL: [Float]] = [:]
    static let fallback: [Float] = Array(repeating: 0.2, count: 108)

    static func cached(_ url: URL) -> [Float]? { cache[url] }

    static func load(_ url: URL) async -> [Float]? {
        if let c = cache[url] { return c }
        guard let img = await ImageStore.shared.load(url), let cg = img.cgImage else { return nil }
        let n = 6
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            // drawn upside down on purpose: the shader's rows run from the bottom (as the web's did)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var out: [Float] = []
        for i in 0..<(n * n) {
            out.append(Float(px[i * 4]) / 255)
            out.append(Float(px[i * 4 + 1]) / 255)
            out.append(Float(px[i * 4 + 2]) / 255)
        }
        cache[url] = out
        if cache.count > 12, let k = cache.keys.first(where: { $0 != url }) { cache[k] = nil }
        return out
    }
}

/// The full-screen backdrop. It draws the shader on a small view (1/6 of the screen) and stretches it, so the picture is smooth and cheap.
struct BackdropView: View {
    let cover: URL?
    let playing: Bool

    @State private var a: [Float] = CoverColours.fallback
    @State private var b: [Float] = CoverColours.fallback
    @State private var fadeFrom: Date?
    @State private var shownCover: URL?
    @State private var clock = Clock()

    private let divisor: CGFloat = 6
    private let fade = 0.9

    /// the colour clock: only moves while a song plays, at 35 % of the web's speed
    final class Clock {
        var t = 0.0
        var last: Date?
        func step(_ date: Date, running: Bool) -> Double {
            if let l = last, running {
                let dt = date.timeIntervalSince(l)
                if dt < 0.5 { t += dt * 0.35 }
            }
            last = date
            return t
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / divisor
            let h = geo.size.height / divisor
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !playing && fadeFrom == nil)) { tl in
                let m = fadeFrom.map { min(1, max(0, tl.date.timeIntervalSince($0) / fade)) } ?? 0
                Rectangle()
                    .fill(Color.black)
                    .frame(width: w, height: h)
                    .colorEffect(ShaderLibrary.fluid(.float2(w, h), .float(clock.step(tl.date, running: playing)), .float(m), .floatArray(a), .floatArray(b)))
                    .blur(radius: 1.5, opaque: true)
                    .scaleEffect(divisor)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        }
        .ignoresSafeArea()
        .opacity(playing ? 1 : 0.35)
        .animation(.easeInOut(duration: 0.9), value: playing)
        .task(id: cover) { await change() }
    }

    private func change() async {
        guard let cover, cover != shownCover, let cols = await CoverColours.load(cover) else { return }
        defer { shownCover = cover }
        if shownCover == nil {
            a = cols
            b = cols
            return
        }
        // cross-fade: B takes the new cover while the mix goes 0 -> 1, then A takes it
        b = cols
        fadeFrom = Date()
        try? await Task.sleep(nanoseconds: UInt64((fade + 0.1) * 1_000_000_000))
        a = cols
        fadeFrom = nil
    }
}
