import SwiftUI

// MARK: - Word layout

private struct GapKey: LayoutValueKey { static let defaultValue: CGFloat = 0 }

/// Words flow left to right and wrap, with a gap after each word (none inside a split word).
struct WordFlow: Layout {
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW + 0.5 { w = max(w, x); x = 0; y += rowH + lineSpacing; rowH = 0 }
            x += sz.width + s[GapKey.self]
            rowH = max(rowH, sz.height)
        }
        w = max(w, x)
        return CGSize(width: min(w, maxW.isFinite ? maxW : w), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX + 0.5 { x = bounds.minX; y += rowH + lineSpacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + s[GapKey.self]
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - One word

/// A long held word jumps letter by letter as it is sung (the web's letter jump).
private func isJumpy(_ w: LyricWord) -> Bool {
    let n = w.w.replacingOccurrences(of: " ", with: "").count
    let dur = max(0.05, (w.e ?? w.t + 0.4) - w.t)
    return n >= 3 && dur * 1000 >= max(360, 240 + 40 * Double(n))
}

/// 0...1: how high a letter is at time t (it rises before its moment `pk` and falls after it).
private func letterY(_ t: Double, _ pk: Double, _ rise: Double, _ fall: Double) -> CGFloat {
    if t < pk { return CGFloat(max(0, 1 - (pk - t) / rise)) }
    return CGFloat(max(0, 1 - (t - pk) / fall))
}

/// A word that fills from left to right as it is sung (a soft edge, the web's wipe).
private struct FillWord: View {
    let ink: Ink
    let word: LyricWord
    let text: String
    let size: CGFloat
    let t: Double

    var body: some View {
        let p = Lyr.progress(word, t)
        let soft = 0.35
        let pos = p * (1 + soft) // the edge travels past the end so the last letters finish lit
        let jumpy = isJumpy(word) && p > 0 && p < 1.4
        ZStack(alignment: .leading) {
            face.foregroundStyle(ink.color(0.32))
            face.foregroundStyle(ink.color())
                .mask {
                    LinearGradient(stops: [
                        .init(color: Color.white, location: max(0, min(1, pos - soft))),
                        .init(color: .clear, location: max(0, min(1, pos))),
                    ], startPoint: .leading, endPoint: .trailing)
                }
        }
        .fixedSize()
        .id(jumpy)
    }

    @ViewBuilder private var face: some View {
        if isJumpy(word) {
            let chars = Array(text)
            let n = max(1, chars.count)
            let dur = max(0.05, (word.e ?? word.t + 0.4) - word.t)
            let rise = min(0.45, max(0.11, 0.06 * Double(n - 1), 1.2 * dur / Double(n)))
            let fall = max(0.08, 0.75 * rise)
            HStack(spacing: 0) {
                ForEach(Array(chars.enumerated()), id: \.offset) { k, c in
                    let pk = word.t + dur * Double(k) / Double(n)
                    Text(String(c)).font(.lato(size)).offset(y: -size * 0.09 * letterY(t, pk, rise, fall))
                }
            }
        } else {
            Text(text).font(.lato(size))
        }
    }
}

// MARK: - A line

private struct LyricRow: View, Equatable {
    let ink: Ink
    let line: LyricLine
    let size: CGFloat
    let active: Bool
    let level: Double // the row's brightness: 1 current, .3 next, .15 others
    let t: Double // only the current line gets the time; the others get 0 so they are not redrawn every frame
    var onTap: () -> Void = {}

    static func == (a: LyricRow, b: LyricRow) -> Bool {
        a.ink == b.ink && a.line.id == b.line.id && a.size == b.size && a.active == b.active && a.level == b.level && a.t == b.t
    }

    private func flow(_ words: [LyricWord], _ s: CGFloat) -> some View {
        WordFlow(lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                let trimmed = w.w.trimmingCharacters(in: .whitespaces)
                // a gap after a word that ends with a space, or before one that starts with a space
                let next = i + 1 < words.count ? words[i + 1].w : ""
                let gap: CGFloat = w.w.hasSuffix(" ") || next.hasPrefix(" ") || i == words.count - 1 ? s * 0.26 : 0
                FillWord(ink: ink, word: w, text: trimmed, size: s, t: t)
                    .layoutValue(key: GapKey.self, value: gap)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if line.brk {
                Dots(ink: ink, line: line, t: active ? t : 0, size: size)
            } else if let words = line.words, active {
                flow(words, size)
                // backing vocals: smaller, under the line
                if let back = line.back, !back.isEmpty { flow(back, size * 0.7).padding(.top, 3) }
            } else {
                Text(line.text)
                    .font(.lato(size))
                    .foregroundStyle(ink.color())
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let back = line.back, !back.isEmpty {
                    Text(back.map { $0.w }.joined().trimmingCharacters(in: .whitespaces))
                        .font(.lato(size * 0.7)).foregroundStyle(ink.color(0.7)).padding(.top, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
    @State private var hold = Date.distantPast

    private var activeStarts: [Double] { Lyr.activeStarts(lines) }
    private var scrollStarts: [Double] { Lyr.scrollStarts(lines) }

    var body: some View {
        let starts = activeStarts
        let sstarts = scrollStarts
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { tl in
                    column(starts: starts, sstarts: sstarts, proxy: proxy, date: tl.date)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in hold = Date().addingTimeInterval(3) })
        }
    }

    @ViewBuilder
    private func column(starts: [Double], sstarts: [Double], proxy: ScrollViewProxy, date: Date) -> some View {
        let t = player.now + Lyr.ahead
        let idx = Lyr.indexAt(starts, t)
        let sidx = max(idx, Lyr.indexAt(sstarts, t))
        let synced = lines.contains { $0.t != nil }
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: topInset)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                    let isActive = synced && i == idx
                    let upcoming = synced && i > idx && i <= idx + 2 && (l.t ?? 1e9) - t < 2.5
                    let paused = !player.isPlaying
                    LyricRow(
                        ink: ink,
                        line: l, size: 30, active: isActive || !synced,
                        level: paused ? 0.07 : (!synced ? 0.9 : (isActive ? 1 : (upcoming ? 0.3 : 0.15))),
                        t: isActive ? t : 0,
                        onTap: { if let lt = l.t { player.seek(to: max(0, lt - 0.05)) } }
                    )
                    .equatable()
                    .id(i)
                }
            }
            Color.clear.frame(height: bottomInset)
        }
        .padding(.horizontal, 18)
        .onChange(of: sidx) { _, new in
            guard synced, new >= 0, Date() > hold else { return }
            withAnimation(.timingCurve(0.45, 0.05, 0.15, 1, duration: 0.8)) {
                proxy.scrollTo(new, anchor: UnitPoint(x: 0.5, y: 0.5))
            }
        }
        .onAppear {
            if synced, sidx >= 0 { proxy.scrollTo(sidx, anchor: UnitPoint(x: 0.5, y: 0.5)) }
        }
    }
}
