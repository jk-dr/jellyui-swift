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

/// A word that fills from left to right as it is sung (a soft edge, the web's wipe).
private struct FillWord: View {
    let text: String
    let size: CGFloat
    let p: Double // 0...1

    var body: some View {
        let soft = 0.35
        let pos = p * (1 + soft) // the edge travels past the end so the last letters finish lit
        Text(text)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white.opacity(0.32))
            .overlay(alignment: .leading) {
                Text(text)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(.white)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .white, location: max(0, min(1, pos - soft))),
                            .init(color: .clear, location: max(0, min(1, pos))),
                        ], startPoint: .leading, endPoint: .trailing)
                    }
            }
            .fixedSize()
    }
}

// MARK: - A line

private struct LyricRow: View, Equatable {
    let line: LyricLine
    let size: CGFloat
    let active: Bool
    let level: Double // the row's brightness: 1 current, .3 next, .15 others
    let t: Double // only the current line gets the time; the others get 0 so they are not redrawn every frame
    var onTap: () -> Void = {}

    static func == (a: LyricRow, b: LyricRow) -> Bool {
        a.line.id == b.line.id && a.size == b.size && a.active == b.active && a.level == b.level && a.t == b.t
    }

    var body: some View {
        Group {
            if line.brk {
                Dots(line: line, t: active ? t : 0, size: size)
            } else if let words = line.words, active {
                WordFlow(lineSpacing: 2) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        let trimmed = w.w.trimmingCharacters(in: .whitespaces)
                        let gap: CGFloat = w.w.hasSuffix(" ") || i == words.count - 1 ? size * 0.26 : 0
                        FillWord(text: trimmed, size: size, p: Lyr.progress(w, t))
                            .layoutValue(key: GapKey.self, value: gap)
                    }
                }
            } else {
                Text(line.text)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(level)
        .scaleEffect(active ? 1 : 0.95, anchor: .leading)
        .animation(.easeInOut(duration: 0.85), value: level)
        .animation(.easeInOut(duration: 0.8), value: active)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Three dots for a long silence: they fill as the silence passes.
private struct Dots: View {
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
                    .fill(.white.opacity(0.3 + 0.7 * seg))
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

    @State private var hold = Date.distantPast

    private var activeStarts: [Double] { Lyr.activeStarts(lines) }
    private var scrollStarts: [Double] { Lyr.scrollStarts(lines) }

    var body: some View {
        let starts = activeStarts
        let sstarts = scrollStarts
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                TimelineView(.animation) { tl in
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
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                    let isActive = synced && i == idx
                    let upcoming = synced && i > idx && i <= idx + 2 && (l.t ?? 1e9) - t < 2.5
                    LyricRow(
                        line: l, size: 32, active: isActive || !synced,
                        level: !synced ? 0.9 : (isActive ? 1 : (upcoming ? 0.3 : 0.15)),
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
                proxy.scrollTo(new, anchor: UnitPoint(x: 0.5, y: 0.4))
            }
        }
        .onAppear {
            if synced, sidx >= 0 { proxy.scrollTo(sidx, anchor: UnitPoint(x: 0.5, y: 0.4)) }
        }
    }
}
