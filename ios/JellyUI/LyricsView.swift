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
    @ObservationIgnored private var task: Task<Void, Never>?

    func run(starts: [Double], sstarts: [Double], player: PlayerModel) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let t = player.now + Lyr.ahead
                let i = Lyr.indexAt(starts, t)
                let s = max(i, Lyr.indexAt(sstarts, t))
                if i != self.idx { self.idx = i }
                if s != self.sidx { self.sidx = s }
                // sleep until the next boundary (either list), capped so a seek or pause is noticed within 0.25 s
                let nextA = i + 1 < starts.count ? starts[i + 1] : .infinity
                let nextS = s + 1 < sstarts.count ? sstarts[s + 1] : .infinity
                let wait = player.isPlaying ? min(0.25, max(0.008, min(nextA, nextS) - t)) : 0.25
                try? await Task.sleep(for: .seconds(wait))
            }
        }
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

/// A long held word jumps letter by letter as it is sung (the web's letter jump).
private func isJumpy(_ w: LyricWord) -> Bool {
    let n = w.w.replacingOccurrences(of: " ", with: "").count
    let dur = max(0.05, (w.e ?? w.t + 0.4) - w.t)
    return n >= 3 && dur * 1000 >= max(360, 240 + 40 * Double(n))
}

// MARK: - Renderer

/// Draws a row: each word dim, then lit up to its wipe position with a soft edge. Long words lift letter by letter.
private struct WipeRenderer: TextRenderer {
    var t: Double
    let words: [LyricWord]
    let back: [LyricWord]
    let size: CGFloat
    var dim: Double = 0.32

    var displayPadding: EdgeInsets { EdgeInsets(top: size * 0.14, leading: 2, bottom: 2, trailing: 2) }

    private func word(_ i: Int) -> LyricWord? {
        if i >= 10_000 { let j = i - 10_000; return back.indices.contains(j) ? back[j] : nil }
        return words.indices.contains(i) ? words[i] : nil
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let soft = 0.35
        for line in layout {
            for run in line {
                guard let tag = run[WordTag.self], let w = word(tag.i) else { ctx.draw(run); continue }
                let p = Lyr.progress(w, t)
                let r = run.typographicBounds.rect
                let jumpy = p > 0 && p < 1 && isJumpy(w)

                if jumpy {
                    // letter jump: each glyph rises before its moment and settles after it
                    let n = max(1, run.count)
                    let dur = max(0.05, (w.e ?? w.t + 0.4) - w.t)
                    let rise = min(0.45, max(0.11, 0.06 * Double(n - 1), 1.2 * dur / Double(n)))
                    let fall = max(0.08, 0.75 * rise)
                    for (k, g) in run.enumerated() {
                        let pk = w.t + dur * Double(k) / Double(n)
                        let y = t < pk ? max(0, 1 - (pk - t) / rise) : max(0, 1 - (t - pk) / fall)
                        var c = ctx
                        c.translateBy(x: 0, y: -size * 0.09 * y)
                        drawWipe(g, rect: g.typographicBounds.rect, wordRect: r, p: p, soft: soft, in: &c)
                    }
                } else {
                    drawWipe(run, rect: r, wordRect: r, p: p, soft: soft, in: &ctx)
                }
            }
        }
    }

    /// `rect` is the piece being drawn (a word or one glyph of it); the wipe runs across the whole word (`wordRect`).
    private func drawWipe<S: GlyphDrawable>(_ piece: S, rect: CGRect, wordRect: CGRect, p: Double, soft: Double, in ctx: inout GraphicsContext) {
        if p <= 0 { var c = ctx; c.opacity = dim; piece.draw(in: &c); return }
        if p >= 1 { piece.draw(in: &ctx); return }
        // dim under, lit on top through a soft-edged mask (the edge travels past the end so the last letters finish lit)
        var d = ctx; d.opacity = dim; piece.draw(in: &d)
        let pos = p * (1 + soft)
        let x0 = wordRect.minX + wordRect.width * max(0, min(1, pos - soft))
        let x1 = wordRect.minX + wordRect.width * max(0, min(1, pos))
        if x1 <= rect.minX { return }
        var lit = ctx
        if x0 >= rect.maxX {
            piece.draw(in: &lit)
            return
        }
        lit.clipToLayer { m in
            m.fill(Path(rect.insetBy(dx: -2, dy: -size * 0.3)), with: .linearGradient(
                Gradient(stops: [.init(color: .white, location: 0), .init(color: .clear, location: 1)]),
                startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: max(x1, x0 + 0.5), y: 0)))
        }
        piece.draw(in: &lit)
    }
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
    var onTap: () -> Void = {}

    static func == (a: LyricRow, b: LyricRow) -> Bool {
        a.ink == b.ink && a.line.id == b.line.id && a.size == b.size && a.active == b.active && a.level == b.level && a.playing == b.playing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if line.brk {
                if active {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { _ in
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
        .opacity(level)
        .scaleEffect(active ? 1.08 : 1, anchor: .leading)
        .animation(.easeInOut(duration: 0.85), value: level)
        .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.8), value: active)
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

/// Three dots for a long silence: they fill as the silence passes.
private struct Dots: View {
    let ink: Ink
    let line: LyricLine
    let t: Double
    let size: CGFloat

    var body: some View {
        let from = line.t ?? 0
        let to = line.until ?? (line.e ?? from + 1)
        let p = to > from ? max(0, min(1, (t - from) / (to - from))) : 0
        HStack(spacing: size * 0.3) {
            ForEach(0..<3, id: \.self) { i in
                let seg = max(0, min(1, p * 3 - Double(i)))
                Circle()
                    .fill(ink.color(0.3 + 0.7 * seg))
                    .frame(width: size * 0.42, height: size * 0.42)
                    .scaleEffect(0.8 + 0.2 * seg)
            }
        }
        .frame(height: size * 1.2)
    }
}

// MARK: - The column

struct LyricsView: View {
    let lines: [LyricLine]
    let player: PlayerModel
    var topInset: CGFloat = 40
    var bottomInset: CGFloat = 200

    @Environment(\.ink) private var ink
    @State private var clock = LyricsClock()
    @State private var hold = Date.distantPast

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
                            let upcoming = synced && i > idx && i <= idx + 2
                            LyricRow(
                                ink: ink, line: l, size: 30,
                                active: isActive || !synced,
                                level: !playing ? 0.07 : (!synced ? 0.9 : (isActive ? 1 : (upcoming ? 0.3 : 0.15))),
                                playing: playing && isActive,
                                player: player,
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
            .onChange(of: clock.sidx) { _, new in
                guard synced, new >= 0, Date() > hold else { return }
                withAnimation(.timingCurve(0.45, 0.05, 0.15, 1, duration: 0.8)) {
                    proxy.scrollTo(new, anchor: UnitPoint(x: 0.5, y: 0.5))
                }
            }
            .onAppear {
                start()
                if synced, clock.sidx >= 0 { proxy.scrollTo(clock.sidx, anchor: UnitPoint(x: 0.5, y: 0.5)) }
            }
            .onChange(of: lines.first?.id) { _, _ in start() }
            .onChange(of: playing) { _, _ in start() } // a resume or a seek wakes the clock at once
            .onDisappear { clock.stop() }
        }
    }

    private func start() {
        clock.run(starts: Lyr.activeStarts(lines), sstarts: Lyr.scrollStarts(lines), player: player)
    }
}
