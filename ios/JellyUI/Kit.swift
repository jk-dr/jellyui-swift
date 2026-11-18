import SwiftUI
import UIKit

// MARK: - Fonts (the web's Questrial for text, Lato Black for lyrics)

extension Font {
    static func q(_ size: CGFloat) -> Font { .custom("Questrial", size: size) }
    static func lato(_ size: CGFloat) -> Font { .custom("Lato-Black", size: size) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: alpha)
    }
    static let pink = Color(hex: 0xf8cccc)
    static let bg = Color(hex: 0x0c0c0e)
    static let surface = Color(hex: 0x181818)
    static let surfaceHi = Color(hex: 0x1d1d20)
    static let midText = Color(hex: 0xbababa)
    static let dimText = Color(hex: 0x868686)
    static let danger = Color(hex: 0xff8a8a)
}

// MARK: - SVG path data as a SwiftUI shape (the icons are the web's own glyphs)

struct SVGPath: Shape {
    let d: String
    var box: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        var p = SVGParser(d).parse()
        let s = min(rect.width, rect.height) / box
        p = p.applying(CGAffineTransform(scaleX: s, y: s))
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

private struct SVGParser {
    let chars: [Character]
    var i = 0
    init(_ d: String) { chars = Array(d) }

    mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" { i += 1 } }

    mutating func number() -> CGFloat? {
        skip()
        var s = ""
        var dot = false
        var exp = false
        if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
        while i < chars.count {
            let c = chars[i]
            if c.isNumber { s.append(c); i += 1 }
            else if c == "." && !dot && !exp { dot = true; s.append(c); i += 1 }
            else if (c == "e" || c == "E") && !exp && !s.isEmpty { exp = true; s.append(c); i += 1; if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 } }
            else { break }
        }
        return Double(s).map { CGFloat($0) }
    }

    mutating func flag() -> Bool {
        skip()
        guard i < chars.count else { return false }
        let v = chars[i] == "1"
        i += 1
        return v
    }

    mutating func parse() -> Path {
        var path = Path()
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastC: CGPoint? = nil // last cubic control, for S
        var lastQ: CGPoint? = nil
        while true {
            skip()
            if i >= chars.count { break }
            if chars[i].isLetter { cmd = chars[i]; i += 1 }
            let rel = cmd.isLowercase
            var nc: CGPoint? = nil
            var nq: CGPoint? = nil
            switch cmd {
            case "M", "m":
                guard let x = number(), let y = number() else { return path }
                cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                start = cur
                path.move(to: cur)
                cmd = rel ? "l" : "L"
            case "L", "l":
                guard let x = number(), let y = number() else { return path }
                cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: cur)
            case "H", "h":
                guard let x = number() else { return path }
                cur.x = rel ? cur.x + x : x
                path.addLine(to: cur)
            case "V", "v":
                guard let y = number() else { return path }
                cur.y = rel ? cur.y + y : y
                path.addLine(to: cur)
            case "C", "c":
                guard let a = number(), let b = number(), let c = number(), let d = number(), let x = number(), let y = number() else { return path }
                let o = rel ? cur : .zero
                let c1 = CGPoint(x: o.x + a, y: o.y + b), c2 = CGPoint(x: o.x + c, y: o.y + d), e = CGPoint(x: o.x + x, y: o.y + y)
                path.addCurve(to: e, control1: c1, control2: c2)
                nc = c2; cur = e
            case "S", "s":
                guard let c = number(), let d = number(), let x = number(), let y = number() else { return path }
                let o = rel ? cur : .zero
                let c1 = lastC.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: o.x + c, y: o.y + d), e = CGPoint(x: o.x + x, y: o.y + y)
                path.addCurve(to: e, control1: c1, control2: c2)
                nc = c2; cur = e
            case "Q", "q":
                guard let a = number(), let b = number(), let x = number(), let y = number() else { return path }
                let o = rel ? cur : .zero
                let c1 = CGPoint(x: o.x + a, y: o.y + b), e = CGPoint(x: o.x + x, y: o.y + y)
                path.addQuadCurve(to: e, control: c1)
                nq = c1; cur = e
            case "T", "t":
                guard let x = number(), let y = number() else { return path }
                let o = rel ? cur : .zero
                let c1 = lastQ.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let e = CGPoint(x: o.x + x, y: o.y + y)
                path.addQuadCurve(to: e, control: c1)
                nq = c1; cur = e
            case "A", "a":
                guard let rx = number(), let ry = number(), let rot = number() else { return path }
                let large = flag(), sweep = flag()
                guard let x = number(), let y = number() else { return path }
                let e = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                arc(&path, from: cur, to: e, rx: rx, ry: ry, rot: rot, large: large, sweep: sweep)
                cur = e
            case "Z", "z":
                path.closeSubpath()
                cur = start
            default:
                return path
            }
            lastC = nc
            lastQ = nq
        }
        return path
    }

    /// An SVG elliptical arc as cubic curves (the standard endpoint-to-centre conversion).
    func arc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, rot: CGFloat, large: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rot * .pi / 180
        let cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lam > 1 { rx *= sqrt(lam); ry *= sqrt(lam) }
        let sign: CGFloat = large == sweep ? -1 : 1
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let co = sign * sqrt(max(0, num / den))
        let cxp = co * rx * y1 / ry, cyp = -co * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2
        let cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
        func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let th1 = ang(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dth = ang((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && dth > 0 { dth -= 2 * .pi }
        if sweep && dth < 0 { dth += 2 * .pi }
        let n = max(1, Int(ceil(abs(dth) / (.pi / 2))))
        let step = dth / CGFloat(n)
        let t = 4.0 / 3.0 * tan(step / 4)
        var a = th1
        for _ in 0..<n {
            let a2 = a + step
            let c1 = CGPoint(x: cos(a) - t * sin(a), y: sin(a) + t * cos(a))
            let c2 = CGPoint(x: cos(a2) + t * sin(a2), y: sin(a2) - t * cos(a2))
            let e = CGPoint(x: cos(a2), y: sin(a2))
            func map(_ q: CGPoint) -> CGPoint {
                let x = q.x * rx, y = q.y * ry
                return CGPoint(x: cp * x - sp * y + cx, y: sp * x + cp * y + cy)
            }
            path.addCurve(to: map(e), control1: map(c1), control2: map(c2))
            a = a2
        }
    }
}

/// One of the app's glyphs (Icon.tsx) at `size`, in `color`.
struct Icon: View {
    let name: String
    var size: CGFloat = 24
    var color: Color = .white
    var body: some View {
        SVGPath(d: iconPaths[name] ?? "").fill(color).frame(width: size, height: size)
    }
}

// MARK: - Text and buttons

struct H2: View {
    let text: String
    var first = false
    init(_ t: String, first: Bool = false) { text = t; self.first = first }
    var body: some View {
        Text(text).font(.q(20)).foregroundStyle(Color.pink)
            .shadow(color: .black, radius: 4, y: 1)
            .padding(.leading, 16).padding(.top, first ? 70 : 36)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Note: View {
    let text: String
    var error = false
    init(_ t: String, error: Bool = false) { text = t; self.error = error }
    var body: some View {
        Text(text).font(.q(15)).foregroundStyle(error ? Color.danger : Color.dimText).padding(.horizontal, 16).padding(.top, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Btn: View {
    enum Kind { case primary, alt, danger }
    let label: String
    var icon: String?
    var kind: Kind = .alt
    var busy = false
    var disabled = false
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) { content }
            .buttonStyle(PressStyle())
            .disabled(disabled || busy)
            .opacity(disabled ? 0.45 : 1)
    }
    var content: some View {
        let fg: Color = kind == .primary ? .bg : (kind == .danger ? Color(hex: 0x2a0a0a) : .pink)
        let bg: Color = kind == .primary ? .pink : (kind == .danger ? .danger : .surfaceHi)
        return HStack(spacing: 8) {
            if busy { ProgressView().tint(fg) } else if let icon { Icon(name: icon, size: 20, color: fg) }
            if !label.isEmpty { Text(label).font(.q(16)).lineLimit(1) }
        }
        .foregroundStyle(fg)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 20)
        .background(bg, in: Capsule())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The web's row of buttons: each shares the line, and one whose words do not fit shows only its icon (.btn.ico).
struct Act: Identifiable {
    var id: String
    var icon: String
    var label: String
    var kind: Btn.Kind = .alt
    var iconOnly = false
    var keep = false
    var disabled = false
    var busy = false
    var action: () -> Void = {}
    /// a menu that opens from the button instead of a plain tap
    var menu: AnyView?
}

struct ActionRow: View {
    let items: [Act]
    var gap: CGFloat = 10
    @State private var width: CGFloat = 0

    private func textWidth(_ s: String) -> CGFloat {
        let f = UIFont(name: "Questrial", size: 16) ?? .systemFont(ofSize: 16)
        return ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    private var iconSet: Set<String> {
        var out = Set(items.filter { $0.iconOnly }.map { $0.id })
        guard width > 0 else { return out }
        func need(_ x: Act) -> CGFloat { 16 * 2 + 20 + 8 + textWidth(x.label) }
        for _ in 0...items.count {
            let open = items.filter { !out.contains($0.id) }
            let room = width - gap * CGFloat(items.count - 1) - CGFloat(out.count) * 44
            let share = room / CGFloat(max(1, open.count))
            guard let x = open.first(where: { !$0.keep && need($0) > share }) else { break }
            out.insert(x.id)
        }
        return out
    }

    var body: some View {
        let ico = iconSet
        HStack(spacing: gap) {
            ForEach(items) { x in
                let small = ico.contains(x.id)
                let inner = face(x, small: small)
                Group {
                    if let m = x.menu { m.overlay { inner.allowsHitTesting(false) } } else {
                        Button(action: x.action) { inner }.buttonStyle(PressStyle()).disabled(x.disabled || x.busy)
                    }
                }
                .frame(width: small ? 44 : nil)
                .frame(maxWidth: small ? 44 : .infinity)
                .opacity(x.disabled ? 0.45 : 1)
            }
        }
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
    }

    private func face(_ x: Act, small: Bool) -> some View {
        let fg: Color = x.kind == .primary ? .bg : (x.kind == .danger ? Color(hex: 0x2a0a0a) : .pink)
        let bg: Color = x.kind == .primary ? .pink : (x.kind == .danger ? .danger : .surfaceHi)
        return HStack(spacing: 8) {
            if x.busy { ProgressView().tint(fg) } else { Icon(name: x.icon, size: 20, color: fg) }
            if !small { Text(x.label).font(.q(16)).lineLimit(1) }
        }
        .foregroundStyle(fg)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(bg, in: Capsule())
    }
}

// MARK: - Skeleton

struct Skeleton: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 12
    @State private var on = false
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.surfaceHi)
            .frame(width: width, height: height).opacity(on ? 1 : 0.5)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true } }
    }
}

// MARK: - Cards

struct Card: Hashable, Identifiable {
    var id: String
    var title: String
    var sub: String
    var img: URL?
    var t: Character // m movie, s show, a audio, o other
    var route: Route
}

extension Item {
    var card: Card {
        let id = itemId ?? self.id
        switch type {
        case "Movie": return Card(id: id, title: title, sub: productionYear.map(String.init) ?? "Movie", img: Pic.poster(self), t: "m", route: route)
        case "Series": return Card(id: id, title: title, sub: productionYear.map(String.init) ?? "Show", img: Pic.poster(self), t: "s", route: route)
        case "MusicAlbum": return Card(id: id, title: title, sub: albumArtist ?? "Album", img: Pic.poster(self), t: "a", route: route)
        case "Playlist": return Card(id: id, title: title, sub: "Playlist", img: Pic.poster(self), t: "o", route: route)
        case "Audio": return Card(id: id, title: title, sub: artistLine.isEmpty ? "Song" : artistLine, img: Pic.poster(self), t: "a", route: route)
        default: return Card(id: id, title: title, sub: type ?? "", img: Pic.poster(self), t: "o", route: route)
        }
    }
}

private let movieBadge = "M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4a2 2 0 00-2 2v12a2 2 0 002 2h16a2 2 0 002-2V4h-4z"
private let showBadge = "M21 3H3a2 2 0 00-2 2v12a2 2 0 002 2h5v2h8v-2h5a2 2 0 002-2L23 5a2 2 0 00-2-2zm0 14H3V5h18v12z"

struct TypeBadge: View {
    let t: Character
    var body: some View {
        if t == "m" || t == "s" {
            SVGPath(d: t == "m" ? movieBadge : showBadge).fill(Color(hex: 0xf2f2f2)).frame(width: 22, height: 22)
                .padding(4).background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(5)
        }
    }
}

struct PosterCard: View {
    let card: Card
    let width: CGFloat
    var badge = false
    @Environment(Nav.self) private var nav
    var body: some View {
        Button { nav.go(card.route) } label: {
            ZStack(alignment: .topTrailing) {
                if card.img != nil { Pic_(card.img, radius: 10) } else { placeholder }
                if badge { TypeBadge(t: card.t) }
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1d1d20), Color(hex: 0x111113)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 6) {
                Text(String(card.title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()).font(.q(42)).foregroundStyle(Color.pink)
                Text(card.title).font(.q(12)).foregroundStyle(Color(hex: 0xd4d4d4)).multilineTextAlignment(.center).lineLimit(3)
            }.padding(8)
        }
    }
}

/// The web's `.lib` tile: the cover with a dark fade, the name and a line under it.
struct TileCard: View {
    let card: Card
    let width: CGFloat
    var badge = false
    @Environment(Nav.self) private var nav
    var body: some View {
        let sub = (card.t == "m" || card.t == "s") ? card.sub.replacingOccurrences(of: "^(Movie|Show)( · )?", with: "", options: .regularExpression) : card.sub
        Button { nav.go(card.route) } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(hex: 0x181818), Color(hex: 0x0f0f11)], startPoint: .top, endPoint: .bottom)
                if card.img != nil {
                    Pic_(card.img, radius: 0)
                    LibFade()
                } else {
                    Text(String(card.title.prefix(1))).font(.q(56)).foregroundStyle(Color(hex: 0x2c2c30))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 64)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.q(16)).foregroundStyle(Color.midText).lineLimit(2)
                    if !sub.isEmpty { Text(sub).font(.q(11)).foregroundStyle(Color.dimText).lineLimit(1) }
                }
                .padding(.horizontal, 9).padding(.bottom, 15)
                if badge { TypeBadge(t: card.t).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 9.6, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// the web's cover fade: dark at the top, clear about a third down, dark again toward the name
struct LibFade: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: Color(hex: 0x0c0c0e, alpha: 0.8), location: 0), .init(color: Color(hex: 0x0c0c0e, alpha: 0.45), location: 0.21),
            .init(color: Color(hex: 0x0c0c0e, alpha: 0.07), location: 0.37), .init(color: Color(hex: 0x0c0c0e, alpha: 0.33), location: 0.54),
            .init(color: Color(hex: 0x0c0c0e, alpha: 0.68), location: 0.71), .init(color: Color(hex: 0x0c0c0e, alpha: 0.86), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// A horizontal row of cards (the web's .row): 11 before the first, 12 between.
struct HRow<Content: View>: View {
    var height: CGFloat
    var gap: CGFloat = 12
    var pad: CGFloat = 11
    var snap: CGFloat?
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: gap) { content() }
                .padding(.horizontal, pad)
                .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .frame(height: height)
        .padding(.top, 6)
    }
}

struct HRowSkeleton: View {
    var height: CGFloat
    var width: CGFloat
    var pad: CGFloat = 11
    var body: some View {
        HStack(spacing: 12) { ForEach(0..<5, id: \.self) { _ in Skeleton(width: width, height: height, radius: 9.6) } }
            .padding(.leading, pad).frame(height: height, alignment: .leading).padding(.top, 6).clipped()
    }
}

/// Three across, 16 at the sides, 12 between (the web's --pw).
struct Grid3 {
    static func width(_ total: CGFloat) -> CGFloat { floor((total - 32 - 24) / 3) }
}

struct SegmentedBar<T: Hashable>: View {
    let options: [(value: T, label: String, count: Int?)]
    @Binding var value: T
    var top: CGFloat = 10
    var body: some View {
        HStack(spacing: 2.4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.value == value
                Button { value = o.value } label: {
                    HStack(spacing: 6) {
                        Text(o.label).font(.q(14)).foregroundStyle(on ? Color.bg : Color.midText)
                        if let c = o.count { Text("\(c)").font(.q(11)).foregroundStyle(on ? Color(hex: 0x6a4a4a) : Color(hex: 0x6a6a70)) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(on ? Color.pink : Color.clear, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(4).background(Color(hex: 0x16161a), in: Capsule())
        .padding(.leading, 16).padding(.top, top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
