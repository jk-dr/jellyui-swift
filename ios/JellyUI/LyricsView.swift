import SwiftUI

// Fullscreen lyrics, built for 120 Hz without dropped frames:
//  - Every row is ONE Text laid out once. Rows never relayout when they become current, so nothing jumps.
//  - The word wipe, the soft edge and the letter jump are drawn by a TextRenderer straight from the laid-out glyphs:
//    per frame there is no layout, no view diffing, only drawing of the single sung row.
//  - Only the sung row sits in a TimelineView. The other rows are Equatable and static.
//  - Which row is sung is not polled per frame: LyricsClock sleeps until the next row's start (or a seek / pause).

// MARK: - Clock: the current and scroll-target row, changed only at row boundaries

@Observable
final class LyricsClock {
    private(set) var idx = -1
    private(set) var sidx = -1
    /// a line before the sung one whose last words are still filling (the web's .fill): it stays lit, full size, until they are sung
    private(set) var fill = -1
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var ends: [Double] = []

    func run(starts: [Double], sstarts: [Double], ends: [Double], player: PlayerModel) {
        task?.cancel()
        self.ends = ends
        step(starts, sstarts, player) // the current row now, before the first frame, so an opening screen can scroll to it
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.step(starts, sstarts, player)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Updates the sung row and the scroll target; returns how long to sleep before the next boundary.
    @discardableResult
    private func step(_ starts: [Double], _ sstarts: [Double], _ player: PlayerModel) -> Double {
        let t = player.now + Lyr.ahead
        let i = Lyr.indexAt(starts, t)
        let s = max(i, Lyr.indexAt(sstarts, t))
        if i != idx { idx = i }
        if s != sidx { sidx = s }
        // the line before still filling (its last word ends after now)
        var f = -1
        var k = i - 1
        while k >= 0 && k >= i - 2 { if ends.indices.contains(k), ends[k] > t { f = k; break }; k -= 1 }
        if f != fill { fill = f }
        // sleep until the next boundary (either list, or the filling line's end), capped so a seek or pause is noticed within 0.25 s
        let nextA = i + 1 < starts.count ? starts[i + 1] : .infinity
        let nextS = s + 1 < sstarts.count ? sstarts[s + 1] : .infinity
        let nextF = f >= 0 ? ends[f] : .infinity
        return player.isPlaying ? min(0.25, max(0.008, min(nextA, nextS, nextF) - t)) : 0.25
    }

    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

// MARK: - Text pieces

/// Marks which word a run of glyphs belongs to (index into the row's words; back vocals offset by 10_000).
private struct WordTag: TextAttribute { let i: Int }

private func rowText(_ words: [LyricWord], base: Int, size: CGFloat) -> Text {
    var out = Text("")
    for (k, w) in words.enumerated() {
        out = out + Text(w.w).customAttribute(WordTag(i: base + k))
    }
    return out.font(.lato(size))
}

/// The web's letter jump: a word of n letters sung for at least max(360, 240 + 40 n) ms has its letters rise one after another.
private func jumpNeed(_ n: Int) -> Double { max(0.36, 0.24 + 0.04 * Double(n)) }
private func wordEnd(_ w: LyricWord) -> Double { (w.e ?? 0) > w.t ? w.e! : w.t + 0.25 }
private func isJumpy(_ w: LyricWord) -> Bool {
    let n = w.w.filter { !$0.isWhitespace }.count
    return w.e != nil && n >= 3 && wordEnd(w) - w.t >= jumpNeed(n)
}
/// 0...1, eased both ways (the web's .5 - .5 cos)
@inline(__always) private func ease(_ u: Double) -> Double { 0.5 - 0.5 * cos(Double.pi * max(0, min(1, u))) }

// MARK: - Renderer

/// Where the middle of a word's soft edge is (in px from its left) at a time after the word's start: straight across a plain word;
/// through each syllable's place at its own start for a word sung in syllables, held through any gap between them (the web's pieceMap).
/// Before the word it comes in at the word's first speed, after it it leaves at the last.
private struct Sweep {
    let T: [Double], P: [Double]
    let W: Double, dur: Double
    let v0: Double, v1: Double

    init(_ w: LyricWord, run: Text.Layout.Run, rect r: CGRect, dur: Double) {
        let W = max(1, Double(r.width))
        var T: [Double] = [0], P: [Double] = [0]
        if let pt = w.pt, pt.count > 1 {
            let chars = max(1, w.w.count), n = run.count
            func x(_ c: Int) -> Double {
                let k = n == chars ? c : Int((Double(c) / Double(chars) * Double(n)).rounded())
                if k <= 0 { return 0 }
                if k >= n { return W }
                return Double(run[run.startIndex + k].typographicBounds.rect.minX - r.minX)
            }
            func add(_ tm: Double, _ v: Double) { T.append(max(T.last!, min(dur, tm))); P.append(max(P.last!, v)) }
            for i in 1..<pt.count {
                let v = x(pt[i].c)
                add(pt[i - 1].e - w.t, v)
                if pt[i].t - w.t > T.last! { add(pt[i].t - w.t, v) }
            }
            add(dur, W)
        } else {
            T = [0, dur]; P = [0, W]
        }
        var a = W / dur, b = W / dur
        if let i = (1..<T.count).first(where: { P[$0] > P[$0 - 1] }) { a = (P[i] - P[i - 1]) / max(0.001, T[i] - T[i - 1]) }
        if let i = (1..<T.count).reversed().first(where: { P[$0] > P[$0 - 1] }) { b = (P[i] - P[i - 1]) / max(0.001, T[i] - T[i - 1]) }
        self.T = T; self.P = P; self.W = W; self.dur = dur; v0 = a; v1 = b
    }

    private static func map(_ A: [Double], _ B: [Double], _ x: Double) -> Double {
        for i in 1..<A.count where x <= A[i] {
            return A[i] > A[i - 1] ? B[i - 1] + (B[i] - B[i - 1]) * (x - A[i - 1]) / (A[i] - A[i - 1]) : B[i]
        }
        return B[B.count - 1]
    }

    /// the edge's middle at rel seconds after the word's start (-inf / +inf: not in or past the word yet)
    func mid(_ rel: Double, edge: Double) -> Double {
        let lead = min(0.35, (edge / 2) / max(1, v0)), trail = min(0.35, (edge / 2) / max(1, v1))
        if rel < -lead { return -.infinity }
        if rel > dur + trail { return .infinity }
        if rel < 0 { return v0 * rel }
        if rel > dur { return W + v1 * (rel - dur) }
        return Sweep.map(T, P, rel)
    }

    /// when the edge's middle reaches x (for the letter jump)
    func time(at x: Double) -> Double { max(0, min(dur, Sweep.map(P, T, x))) }
}

/// Draws a row as the web does: the unsung words at 30 %, a fill whose soft edge sweeps across each word while it is sung
/// (coming in up to 0.35 s before the word and leaving up to 0.35 s after it), the sung word lifted 0.05 em, and long words'
/// letters rising one after another as the edge passes them.
private struct WipeRenderer: TextRenderer {
    var t: Double
    let words: [LyricWord]
    let back: [LyricWord]
    let size: CGFloat
    var dim: Double = 0.3

    var displayPadding: EdgeInsets { EdgeInsets(top: size * 0.12, leading: 2, bottom: 2, trailing: 2) }

    private func word(_ i: Int) -> LyricWord? {
        if i >= 10_000 { let j = i - 10_000; return back.indices.contains(j) ? back[j] : nil }
        return words.indices.contains(i) ? words[i] : nil
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        if t == .infinity { for line in layout { for run in line { ctx.draw(run) } }; return } // not sung: plain, fully lit
        let edge = Double(size) * 0.9 // the soft edge's width
        for line in layout {
            for run in line {
                guard let tag = run[WordTag.self], let w = word(tag.i) else { ctx.draw(run); continue }
                let r = run.typographicBounds.rect
                let dur = max(0.05, wordEnd(w) - w.t)
                // the middle of the soft edge, in px from the word's left: crosses the word while it is sung (through its syllables' times)
                let sweep = Sweep(w, run: run, rect: r, dur: dur)
                let rel = t - w.t
                let mid = sweep.mid(rel, edge: edge)
                if isJumpy(w) && rel > -0.45 && rel < dur + 0.45 {
                    let n = max(1, run.count)
                    let R = min(0.45, max(0.11, 0.06 * Double(n - 1), 1.2 * dur / Double(n)))
                    let up = min(0.075, 0.035 + 0.025 * log(max(1, dur / jumpNeed(n)))) * Double(size)
                    // each letter's lift, worked out once
                    var lifts: [CGFloat] = []
                    lifts.reserveCapacity(n)
                    for g in run {
                        let gr = g.typographicBounds.rect
                        let pk = sweep.time(at: Double(gr.midX - r.minX))
                        let F = max(0.08, min(R * 0.75, dur - pk)), t0 = max(-0.45, pk - R)
                        let y: Double = rel < t0 || rel > pk + F ? 0 : (rel <= pk ? ease((rel - t0) / max(0.001, pk - t0)) : ease(1 - (rel - pk) / F))
                        lifts.append(-CGFloat(up * y))
                    }
                    let x0 = Double(r.minX) + mid - edge / 2, x1 = x0 + edge
                    func letters(_ c: inout GraphicsContext) {
                        for (k, g) in run.enumerated() { var cc = c; if lifts[k] != 0 { cc.translateBy(x: 0, y: lifts[k]) }; cc.draw(g) }
                    }
                    // dim under (unless the whole word is lit), the lit copy over it through one mask for the word
                    if x1 > Double(r.minX) { } else { var dmc = ctx; dmc.opacity = dim; letters(&dmc); continue }
                    if x0 < Double(r.maxX) { var dmc = ctx; dmc.opacity = dim; letters(&dmc) }
                    var lit = ctx
                    if x0 < Double(r.maxX) {
                        lit.clipToLayer { m in
                            m.fill(Path(r.insetBy(dx: -2, dy: -size * 0.4)), with: .linearGradient(WipeRenderer.soft,
                                startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                        }
                    }
                    letters(&lit)
                } else {
                    // the sung word sits 0.05 em higher: up over 0.3 s from 0.15 s before it, down over 0.32 s after it
                    let upT = 0.3, pre = 0.15, down = 0.32, top = max(upT, dur)
                    let a = rel + pre
                    let y: Double = a <= 0 ? 0 : (a < upT ? ease(a / upT) : (a < top ? 1 : max(0, ease(1 - (a - top) / down))))
                    var c = ctx
                    if y > 0 { c.translateBy(x: 0, y: -CGFloat(0.05 * Double(size) * y)) }
                    fill(run, rect: r, wordX: r.minX, mid: mid, edge: edge, in: &c)
                }
            }
        }
    }

    /// One piece (a word or a letter of it): dim, with the lit copy on top through an eased soft-edged mask.
    private func fill<S: GlyphDrawable>(_ piece: S, rect: CGRect, wordX: CGFloat, mid: Double, edge: Double, in ctx: inout GraphicsContext) {
        let x0 = Double(wordX) + mid - edge / 2, x1 = x0 + edge
        if x1 <= Double(rect.minX) { var c = ctx; c.opacity = dim; piece.draw(in: &c); return }
        if x0 >= Double(rect.maxX) { piece.draw(in: &ctx); return }
        var d = ctx; d.opacity = dim; piece.draw(in: &d)
        var lit = ctx
        lit.clipToLayer { m in
            m.fill(Path(rect.insetBy(dx: -2, dy: -size * 0.3)), with: .linearGradient(WipeRenderer.soft,
                startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
        }
        piece.draw(in: &lit)
    }

    /// lit -> unlit along a smoothstep curve (no visible band at either end of the edge)
    static let soft: Gradient = {
        Gradient(stops: (0...8).map { k in
            let u = Double(k) / 8
            return .init(color: .white.opacity(1 - u * u * (3 - 2 * u)), location: u)
        })
    }()
}

private protocol GlyphDrawable { func draw(in ctx: inout GraphicsContext) }
extension Text.Layout.Run: GlyphDrawable { fileprivate func draw(in ctx: inout GraphicsContext) { ctx.draw(self) } }
extension Text.Layout.RunSlice: GlyphDrawable { fileprivate func draw(in ctx: inout GraphicsContext) { ctx.draw(self) } }

// MARK: - A row

private struct LyricRow: View, Equatable {
    let ink: Ink
    let line: LyricLine
    let size: CGFloat
    let active: Bool
    let level: Double // brightness: 1 current, .3 next, .15 others
    let playing: Bool
    let player: PlayerModel
    var soft = false // out of focus (the web's blur of the lines not being sung)
    var tick = 0 // changes on a seek while paused, so the sung row redraws at the new place
    var onTap: () -> Void = {}

    static func == (a: LyricRow, b: LyricRow) -> Bool {
        a.ink == b.ink && a.line.id == b.line.id && a.size == b.size && a.active == b.active && a.level == b.level && a.playing == b.playing && a.tick == b.tick && a.soft == b.soft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if line.brk {
                if active {
                    TimelineView(.animation(paused: !playing)) { _ in
                        Dots(ink: ink, line: line, t: player.now + Lyr.ahead, size: size)
                    }
                } else {
                    Dots(ink: ink, line: line, t: 0, size: size)
                }
            } else if let words = line.words {
                timed(words)
            } else {
                Text(line.text).font(.lato(size)).foregroundStyle(ink.color())
                    .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 20) // the sung line grows from its left edge: room for it
        .padding(.vertical, 25)
        // the line that becomes current takes its full colour at once (a fade made the words hard to follow); the others ease
        .opacity(line.brk ? (active ? (level < 0.1 ? 0.07 : 1) : 0) : level)
        // smooth, never sudden: the line coming in brightens quickly (so it can be followed), the others ease over 0.7 s
        .animation(active ? nil : .easeInOut(duration: 0.7), value: level)
        // out of focus: sharp at once when it comes into focus; going out, it first finishes shrinking (0.8 s), then blurs over 0.7 s
        .blur(radius: soft ? size * 0.1 : 0)
        .animation(soft ? .easeInOut(duration: 0.7).delay(0.84) : .easeOut(duration: 0.25), value: soft)
        .scaleEffect(active && !line.brk ? 1.08 : 1, anchor: .leading)
        // growing: done in 0.5 s, so the line is at full size (it turns current 0.65 s ahead) before its first word is sung; shrinking keeps the slow 0.8 s
        .animation(active ? .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.5) : .timingCurve(0.45, 0.05, 0.15, 1, duration: 0.8), value: active)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder private func timed(_ words: [LyricWord]) -> some View {
        let back = line.back ?? []
        // same Text whether sung or not: only the renderer's time changes, never the layout
        if active {
            TimelineView(.animation(paused: !playing)) { _ in
                face(words, back, t: player.now + Lyr.ahead)
            }
        } else {
            // a row that is not sung is drawn fully lit (its level dims it), with no per-frame work
            face(words, back, t: .infinity)
        }
    }

    private func face(_ words: [LyricWord], _ back: [LyricWord], t: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            rowText(words, base: 0, size: size)
                .foregroundStyle(ink.color())
                .lineSpacing(6)
                .textRenderer(WipeRenderer(t: t, words: words, back: [], size: size))
                .fixedSize(horizontal: false, vertical: true)
            if !back.isEmpty {
                rowText(back, base: 10_000, size: size * 0.7)
                    .foregroundStyle(ink.color(0.7))
                    .textRenderer(WipeRenderer(t: t, words: [], back: back, size: size * 0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Three dots for a long silence (the web's): each in turn lights over its third of the break and swells as it does.
private struct Dots: View {
    let ink: Ink
    let line: LyricLine
    let t: Double
    let size: CGFloat

    var body: some View {
        let from = line.t ?? 0
        let to = line.until ?? (line.e ?? from + 1)
        let p = max(0, min(1, (t - from) / max(0.5, to - from)))
        HStack(spacing: size * 0.6) {
            ForEach(0..<3, id: \.self) { i in
                let q = max(0, min(1, (p - Double(i) / 3) * 3))
                let bounce = q > 0 && q < 1 ? sin(Double.pi * q) : 0
                Circle()
                    .fill(ink.color())
                    .frame(width: size * 0.5, height: size * 0.5)
                    .opacity(0.28 + 0.72 * q)
                    .scaleEffect(CGFloat(1 + 0.6 * bounce))
            }
        }
        .padding(.leading, size * 0.2)
        .frame(height: size * 1.4)
    }
}

/// Watches the player's position while paused: a seek then redraws the sung row.
private struct SeekWatch: View {
    let player: PlayerModel
    let changed: () -> Void
    var body: some View { Color.clear.onChange(of: player.position) { _, _ in changed() } }
}

// MARK: - The column

struct LyricsView: View {
    let lines: [LyricLine]
    let player: PlayerModel
    var topInset: CGFloat = 40
    var bottomInset: CGFloat = 200
    /// where the sung line rests, down the column (0.4; higher while the small queue covers the lower part)
    var anchor: CGFloat = 0.4

    @Environment(\.ink) private var ink
    @State private var clock = LyricsClock()
    @State private var hold = Date.distantPast
    @State private var seekTick = 0
    @State private var placed = false
    @State private var seekedAt = Date.distantPast // a seek (the bar let go, a line tapped, the lock screen) just landed

    // written out (not the memberwise one): the private state above would make that initializer private
    init(lines: [LyricLine], player: PlayerModel, topInset: CGFloat = 40, bottomInset: CGFloat = 200, anchor: CGFloat = 0.4) {
        self.anchor = anchor
        self.lines = lines
        self.player = player
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    var body: some View {
        let idx = clock.idx
        let synced = lines.contains { $0.t != nil }
        let playing = player.isPlaying
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: topInset)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                            let isActive = synced && i == idx
                            let filling = synced && i == clock.fill // still filling after the next line began: lit and full size until done
                            let upcoming = synced && i > idx && i <= idx + 2
                            // in focus: the sung line, the next one, and up to two more starting within 2.5 s of it
                            let near = i == idx + 1 || (upcoming && idx >= 0 && (l.t ?? 1e9) - (lines[idx].t ?? 0) <= 2.5)
                            LyricRow(
                                ink: ink, line: l, size: 30,
                                active: isActive || filling || !synced,
                                level: !playing ? 0.07 : (!synced ? 0.9 : (isActive || filling || (i < idx && l.words != nil) ? 1 : (upcoming ? 0.3 : 0.15))),
                                playing: playing && (isActive || filling),
                                player: player,
                                soft: synced && !l.brk && !isActive && !filling && !near,
                                tick: seekTick,
                                onTap: { if let lt = l.t { player.seek(to: max(0, lt - 0.05)); hold = .distantPast; Task { try? await Task.sleep(for: .milliseconds(60)); start() } } }
                            )
                            .equatable()
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("lyric-\(i)")
                            .id(i)
                        }
                    }
                    Color.clear.frame(height: bottomInset)
                }
                .padding(.horizontal, 18)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in hold = Date().addingTimeInterval(3) })
            .onChange(of: clock.sidx) { old, new in
                guard synced, Date() > hold else { return }
                if new < old {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(max(0, new), anchor: UnitPoint(x: 0.5, y: anchor)) }
                    return
                }
                guard new >= 0 else { return }
                // the first line change after a seek forward: there quickly, not with the slow glide of one line to the next
                if Date().timeIntervalSince(seekedAt) < 1.5 {
                    seekedAt = .distantPast
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(new, anchor: UnitPoint(x: 0.5, y: anchor)) }
                    return
                }
                withAnimation(.timingCurve(0.45, 0.05, 0.15, 1, duration: 0.8)) {
                    proxy.scrollTo(new, anchor: UnitPoint(x: 0.5, y: anchor))
                }
            }
            .opacity(placed ? 1 : 0)
            .onAppear {
                start()
                // the lazy column has no layout yet on the first pass: place it, then place it again once it has, then show it
                if synced, clock.sidx >= 0 { proxy.scrollTo(clock.sidx, anchor: UnitPoint(x: 0.5, y: anchor)) }
                DispatchQueue.main.async {
                    if synced, clock.sidx >= 0 { proxy.scrollTo(clock.sidx, anchor: UnitPoint(x: 0.5, y: anchor)) }
                    withAnimation(.easeOut(duration: 0.2)) { placed = true }
                }
            }
            .onChange(of: lines.first?.id) { _, _ in start() }
            .onChange(of: playing) { _, _ in start() } // a resume or a seek wakes the clock at once
            .onChange(of: player.seeks) { _, _ in seekedAt = Date(); hold = .distantPast; start() }
            // the small queue opened or closed: the sung line glides to its new resting place, with the queue's own curve
            .onChange(of: anchor) { _, a in
                guard synced, clock.sidx >= 0 else { return }
                withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: 0.27)) { proxy.scrollTo(clock.sidx, anchor: UnitPoint(x: 0.5, y: a)) }
            } // a seek (bar, lock screen, a line) re-syncs the lines at once
            // a seek (a row tap or the bar) while paused: the paused sung row is redrawn, as it is not on a timeline
            // only this tiny view reads the position (it changes twice a second): the column itself is not redrawn for it
            .background { if !playing { SeekWatch(player: player) { seekTick += 1 } } }
            .onDisappear { clock.stop() }
        }
    }

    private func start() {
        // when each word-timed line's last word (or backing word) is sung
        let ends = lines.map { l -> Double in
            let ws = (l.words ?? []) + (l.back ?? [])
            return ws.map { ($0.e ?? 0) > $0.t ? $0.e! : $0.t + 0.25 }.max() ?? -.infinity
        }
        clock.run(starts: Lyr.activeStarts(lines), sstarts: Lyr.scrollStarts(lines), ends: ends, player: player)
    }
}
