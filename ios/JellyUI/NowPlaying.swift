import SwiftUI
import UIKit

func timeText(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    let h = t / 3600, m = (t % 3600) / 60, r = t % 60
    return (h > 0 ? "\(h):" + String(format: "%02d", m) : "\(m)") + ":" + String(format: "%02d", r)
}

// MARK: - A title or artist too long for its place scrolls (the web's marquee)

struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color
    var center = false
    @State private var box: CGFloat = 0
    @State private var w: CGFloat = 0
    @State private var start = Date()
    private let HOLD = 3.0, SPEED: CGFloat = 38, GAPX: CGFloat = 36

    var body: some View {
        let over = box > 0 && w > box + 2
        let d = w + GAPX
        let cruise = max(0.01, Double(d / SPEED))
        let cycle = HOLD + cruise
        ZStack(alignment: center && !over ? .center : .leading) {
            if over {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    let t = tl.date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
                    let x: CGFloat = t < HOLD ? 0 : -CGFloat((t - HOLD) / cruise) * d
                    HStack(spacing: GAPX) {
                        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
                        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
                    }.offset(x: x).frame(width: box, alignment: .leading)
                }
            } else {
                Text(text).font(font).foregroundStyle(color).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: center ? .center : .leading).clipped()
        .background(GeometryReader { g in Color.clear.onAppear { box = g.size.width }.onChange(of: g.size.width) { _, v in box = v } })
        .background(alignment: .leading) {
            Text(text).font(font).lineLimit(1).fixedSize().hidden()
                .background(GeometryReader { g in Color.clear.onAppear { w = g.size.width }.onChange(of: g.size.width) { _, v in w = v } })
        }
        .onChange(of: text) { _, _ in start = Date() }
    }
}

// MARK: - Player bar

/// The web's phone player bar: a cover (80 px) at the left beside both rows; the name and artist on the top row, centred;
/// Back / Play / Next on the second row with the heart in the top right corner and the three dots at the far right; the progress bar along the bottom.
struct MiniPlayer: View {
    @Environment(PlayerModel.self) private var pm
    @Environment(Nav.self) private var nav
    @State private var closeAsk = false
    @State private var tint = Color(hex: 0x1c1c1f)

    var body: some View {
        if let it = pm.current {
            let fav = Favs.isFav(it)
            // the web's phone player bar: cover, name and artist, then Back / Play / Next on one row; times and the bar under it
            VStack(spacing: 2) {
                HStack(spacing: 12) {
                    Button { open() } label: {
                        HStack(spacing: 12) {
                            Pic_(Pic.square(it, 160), radius: 8).frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 1) {
                                MarqueeText(text: it.title, font: .q(15), color: .pink)
                                MarqueeText(text: it.artistLine, font: .q(12), color: Color.dimText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 4) {
                        mini("skipPrev") { pm.previous() }
                        Button { pm.toggle() } label: {
                            Icon(name: pm.isPlaying || pm.loading ? "pause" : "play", size: 22, color: .bg)
                                .frame(width: 46, height: 46).background(Color.pink, in: Circle())
                        }.buttonStyle(PressStyle()).accessibilityLabel(pm.isPlaying ? "Pause" : "Play")
                        mini("skipNext") { pm.nextSong() }
                    }
                }
            }
            .padding(.leading, 13).padding(.trailing, 10).padding(.vertical, 10)
            // Liquid Glass, like the tab bar under it (the web's corner: 20)
            .glassEffect(.regular.tint(tint.opacity(0.6)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .task(id: it.id) {
                // the cover's average colour, darkened, as the web's bar does
                guard let u = Pic.square(it, 160), let c = await CoverColours.load(u) else { return }
                _ = await CoverInk.load(u) // ready for the full screen's first frame
                var r: Float = 0, g: Float = 0, b: Float = 0
                for k in stride(from: 0, to: c.count, by: 3) { r += c[k]; g += c[k + 1]; b += c[k + 2] }
                let n = Float(max(1, c.count / 3)), dim: Float = 0.55
                withAnimation(.easeInOut(duration: 0.6)) { tint = Color(red: Double(r / n * dim), green: Double(g / n * dim), blue: Double(b / n * dim)) }
            }
            .padding(.horizontal, 12)
            .contextMenu {
                Button { Favs.toggle(it) } label: { Label(fav ? "Remove from Favourites" : "Favourite", systemImage: fav ? "heart.slash" : "heart") }
                Button { open() } label: { Label("Lyrics and full screen", systemImage: "music.quarternote.3") }
                Button(role: .destructive) { closeAsk = true } label: { Label("Close playback", systemImage: "xmark") }
            }
            // a swipe up from anywhere on the bar (its buttons too) opens the full screen
            .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { v in
                if v.translation.height < -36 && abs(v.translation.width) < abs(v.translation.height) { open() }
            })
            .alert("Close playback?", isPresented: $closeAsk) {
                Button("Cancel", role: .cancel) {}
                Button("Close", role: .destructive) { pm.stop() }
            } message: { Text("This stops the music and removes everything from the queue.") }
        }
    }

    private func open() { FrameMonitor.event("player", "open"); pm.showFull = true }

    private func mini(_ name: String, color: Color = Color(hex: 0xd4d4d4), _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Icon(name: name, size: 22, color: color).frame(width: 38, height: 38) }.buttonStyle(.plain)
    }
}

/// A thin progress bar, drawn from the player's own clock a frame at a time.
struct MiniProgress: View {
    let duration: Double
    @Environment(PlayerModel.self) private var pm
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { _ in
            let f = duration > 0 ? max(0, min(1, pm.now / duration)) : 0
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3))
                    Capsule().fill(Color.pink).frame(width: g.size.width * CGFloat(f))
                }
            }.frame(height: 6)
        }.frame(height: 20)
    }
}

// MARK: - Full screen

private let SHEET = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.17)
private let FAR: CGFloat = 90

struct NowPlaying: View {
    @Environment(PlayerModel.self) private var pm
    private let settings = Settings.shared
    @State private var sheetY: CGFloat = UIScreen.main.bounds.height
    /// the queue: 0 closed, 1 small (the controls risen, the list under them), 2 full (the list fills the screen); in between while a finger moves it
    @State private var qp: CGFloat = 0
    @State private var qBase: CGFloat = 0 // the level when the drag began
    @State private var qFromButton = false // the full queue was opened by the queue button (its close button then closes it altogether)
    @State private var mode = 0 // 0 undecided, 1 closing the sheet, 2 moving the queue
    @State private var edge = false
    @State private var gestureStart: CGPoint? // where the drag under way began; nil between drags
    @State private var early = false
    @State private var late = false
    @State private var lyricsFor: String?
    @State private var shown = false
    @State private var lines: [LyricLine] = []
    @State private var loading = true
    @State private var coverOnly = false
    @State private var look = CoverLook()
    @State private var leaving = false

    private var qg: QGeo { QGeo(H: UIScreen.main.bounds.height, top: Insets.top, bottom: Insets.bottom) }

    init() {
        // lyrics (or the knowledge that there are none) loaded ahead are there from the first frame: no spinner swapped for the cover after the opening
        if let c = PlayerModel.shared.current, let m = LyricsMemo.map[c.id] {
            _lines = State(initialValue: m); _loading = State(initialValue: false); _lyricsFor = State(initialValue: c.id)
        }
    }

    var body: some View {
        let H = UIScreen.main.bounds.height
        let top = Insets.top, bottom = Insets.bottom
        let it = pm.current
        let g = qg
        let L = g.lifted(qp)
        let up = max(0, L - g.lift) // how far past the small queue: the header, lyrics and controls ride up with the list
        let artist = it?.artistLine ?? ""
        let showLyrics = !coverOnly && !settings.lyricsHidden && (loading || !lines.isEmpty)
        let noLyrics = !loading && lines.isEmpty
        let cover = it.flatMap { Pic.square($0, 160) }
        let ink = look.ink

        ZStack {
            Color(hex: 0x0a0a0c)
            // the backdrop is there from the first frame (it came in late and faded up from black)
            BackdropView(cover: cover, playing: pm.isPlaying).allowsHitTesting(false)
            if late, let g = Grain.image { Image(uiImage: g).resizable(resizingMode: .tile).allowsHitTesting(false) }

            // the lyrics column: 76 under the safe area, 222 above the bottom; the sung line rests in its middle
            if showLyrics {
                ZStack {
                    if early && !lines.isEmpty {
                        LyricsView(lines: lines, player: pm, topInset: 25, bottomInset: UIScreen.main.bounds.height * 0.4, anchor: qp > 0.5 ? 0.25 : 0.4)
                            .mask(LinearGradient(gradient: LyricsFade.gradient, startPoint: .top, endPoint: .bottom))
                            .id(lyricsFor) // a new song gets a new column: it starts at its own first line, with no glide from the last song's place
                            .transition(.opacity.animation(.easeIn(duration: 0.22)))
                    }
                    if loading && lines.isEmpty { Spinner() }
                }
                .padding(.top, top + 76).padding(.bottom, 222 + bottom).padding(.trailing, 46)
                .mask(alignment: .top) {
                    // (the box's own padding under the lines, 222 + the bottom inset, is part of the masked area)
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 0.2 * g.lift * min(1, qp))
                        Color.clear.frame(height: (qp > 0 ? 222 + bottom : 0) + min(L, g.lift))
                    }
                }
                .offset(y: -up).opacity(qp > 1 ? Double(2 - qp) : 1)
            } else {
                // no lyrics (or hidden): the cover and the name fill the space, centred
                // the column sits between the header room and the controls; as the controls rise over the small queue only the cover
                // shrinks to fit (the title and artist keep their size and stay under it)
                let room = H - (top + 64) - (222 + bottom + min(L, g.lift))
                let side = max(72, min(420, UIScreen.main.bounds.width * 0.82, room - 90))
                VStack(spacing: 0) {
                    if let it { Pic_(Pic.square(it, 700), radius: 12).frame(width: side, height: side) }
                    MarqueeText(text: it?.title ?? "", font: .q(26), color: ink.color(), center: true).padding(.top, 24).shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                    MarqueeText(text: artist, font: .q(17), color: ink.color(), center: true).padding(.top, 6).shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                    if loading { Spinner().padding(.top, 20) }
                }
                .padding(.horizontal, 18).frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, top + 64).padding(.bottom, 222 + bottom + min(L, g.lift))
                .offset(y: -up)
                .contentShape(Rectangle()).gesture(zone(H))
            }

            EdgeFades(look: look).opacity(pm.isPlaying ? 1 : 0.4).animation(.easeInOut(duration: 0.7), value: pm.isPlaying)

            // the strip down the right edge: a swipe up there raises the queue a level (closed -> small -> full), down lowers it or closes the screen.
            // It reaches down to the risen controls, so it works over the small queue too (the shrunk cover no longer covers the right side).
            if qp < 1.5 {
                Color.clear.contentShape(Rectangle()).frame(width: 52).frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, top + 64).padding(.bottom, 222 + bottom + min(L, g.lift))
                    .gesture(zone(H))
            }

            if showLyrics, let it {
                HStack(spacing: 14) {
                    Button { requestClose() } label: { Pic_(Pic.square(it, 160), radius: 8).frame(width: 44, height: 44) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 0) {
                        MarqueeText(text: it.title, font: .q(15), color: ink.color())
                        MarqueeText(text: artist, font: .q(12), color: ink.color())
                    }.frame(minHeight: 44)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                // only the header row itself catches touches (a full-screen hit area here used to swallow taps on the lyrics)
                .contentShape(Rectangle()).gesture(zone(H))
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, top + 8)
                .offset(y: -up)
            }

            // the fade under the risen controls (the cover's bottom colour), half strength
            if qp > 0 {
                let c = look.bottom
                LinearGradient(stops: [.init(color: Color(red: c.0 * 0.62 / 255, green: c.1 * 0.62 / 255, blue: c.2 * 0.62 / 255).opacity(0), location: 0),
                                       .init(color: Color(red: c.0 * 0.62 / 255, green: c.1 * 0.62 / 255, blue: c.2 * 0.62 / 255), location: 150 / (g.lift + 294 + bottom))],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: g.lift + 294 + bottom).frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(0.5 * Double(min(1, qp))).offset(y: 24 * (1 - min(1, qp)))
                    .allowsHitTesting(false)
            }

            // the queue: always as tall as the full queue, moved (never resized) with the finger
            QueuePanel(level: qp, set: { setQ($0) }, zone: zone(H, noQueue: true), top: top, bottom: bottom)
                .frame(height: H - g.qtop).frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: g.listY(qp))
                .opacity(late ? Double(min(1, qp * 5)) : 0)
                .allowsHitTesting(qp > 0.5)

            // the full queue's close button: on top of everything, sliding in from the right once the queue is full
            let fullQ = qp > 1.5
            Button { setQ(qFromButton ? 0 : 1) } label: {
                Image(systemName: "xmark").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color(hex: 0xf2f2f2))
                    .frame(width: 52, height: 52).background(Color(hex: 0x26262b), in: Circle())
                    .shadow(color: .black.opacity(0.45), radius: 9, y: 4)
                    .contentShape(Circle().inset(by: -12))
            }
            .buttonStyle(PressStyle())
            // (labelled on the button itself: on the full-screen frame below it covered the whole screen for VoiceOver)
            .accessibilityLabel("Close the queue")
            .accessibilityHidden(!fullQ)
            .offset(x: fullQ ? 0 : 140)
            .animation(fullQ ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3) : .easeOut(duration: 0.2), value: fullQ)
            .padding(.trailing, 14).padding(.bottom, 12 + bottom * 0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(fullQ)
            .zIndex(5)

            controls(it, noLyrics: noLyrics, bottom: bottom, H: H)
                .offset(y: -L)
                .opacity(qp > 1 ? Double(max(0, 2 - qp) * 1.4 - 0.4) : 1) // they leave through the top: gone before they reach the status bar
                .allowsHitTesting(qp < 1.5)
        }
        .environment(\.ink, ink)
        .frame(width: UIScreen.main.bounds.width, height: H)
        .clipped()
        .offset(y: sheetY)
        .opacity(shown ? 1 - 0.5 * Double(max(0, min(1, sheetY / H))) : 0)
        .ignoresSafeArea()
        .onAppear {
            FrameMonitor.event("player", "sheet mounted")
            // the cover's colours for the text and the edge fades, known already: the first frame has them
            if let u = pm.current.flatMap({ Pic.square($0, 160) }), let l = CoverInk.cached(u) { look = l }
            withAnimation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.45)) { sheetY = 0 }
            withAnimation(.easeOut(duration: 0.38)) { shown = true }
            Task {
                try? await Task.sleep(nanoseconds: 180_000_000); early = true
                try? await Task.sleep(nanoseconds: 300_000_000); FrameMonitor.event("player", "heavy parts mount now"); withAnimation { late = true }
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .tourQueue)) { _ in setQ(1) } // the CI tour's "queue" screen: the small queue
        #endif
        // the song changed: its lines are put up in this same update (a task would run a frame later)
        .onChange(of: it?.id) { _, _ in if let c = pm.current, let m = LyricsMemo.map[c.id] { coverOnly = false; lines = m; loading = false; lyricsFor = c.id } }
        .task(id: it?.id) { await loadSong(it) }
        .task(id: cover) { if let u = cover, let l = await CoverInk.load(u) { withAnimation(.easeInOut(duration: 0.5)) { look = l } } }
        .task(id: pm.next?.id) { if let n = pm.next, let u = Pic.square(n, 160) { _ = await CoverInk.load(u); _ = await CoverColours.load(u) } }
        .onChange(of: pm.current == nil) { _, none in if none { requestClose() } }
    }

    private func loadSong(_ it: Item?) async {
        coverOnly = false
        // lines loaded ahead (the next song's always are) go up at once; otherwise the last song's go and the new ones load
        if let it, let m = LyricsMemo.map[it.id] { lines = m; loading = false; lyricsFor = it.id; return }
        lines = []; loading = true; lyricsFor = it?.id
        guard let it else { loading = false; return }
        // an answer for a song that is no longer the current one must not overwrite the new song's lyrics
        if let c = await LyricsStore.shared.cached(it.id) {
            guard !Task.isCancelled, it.id == pm.current?.id else { return }
            lines = c; loading = false; return
        }
        var r = await LyricsStore.shared.load(it)
        if r == nil, await LyricsStore.shared.didFail(it.id) { try? await Task.sleep(nanoseconds: 1_200_000_000); if Task.isCancelled { return }; r = await LyricsStore.shared.load(it) }
        guard it.id == pm.current?.id else { return }
        lines = r ?? []; loading = false
    }

    // MARK: sheet and queue

    private func requestClose() {
        if leaving { return }
        leaving = true
        let H = UIScreen.main.bounds.height
        withAnimation(.timingCurve(0.4, 0, 0.6, 1, duration: 0.3)) { sheetY = H; shown = false }
        Task { try? await Task.sleep(nanoseconds: 310_000_000); pm.showFull = false }
    }

    /// the web's --qease: .27 s, cubic-bezier(.5, 0, .2, 1)
    private func setQ(_ level: CGFloat) {
        if level < 1.5 && level > 0.5 { qFromButton = false } // the small queue: from here the full one returns to it
        withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: 0.27)) { qp = level }
        qBase = level
    }

    /// A swipe DOWN drags the whole screen down (queue closed) or lowers the queue a level; a swipe UP raises the queue a level.
    /// Everything follows the finger; letting go settles on the nearest level (a flick goes on to the next one).
    private func zone(_ H: CGFloat, noQueue: Bool = false) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                // a new drag has a new start point. A cancelled drag never reaches onEnded, so this is what clears its mode.
                if v.startLocation != gestureStart { gestureStart = v.startLocation; mode = 0; edge = v.startLocation.y > H - 44; qBase = qp.rounded() }
                let dy = v.translation.height
                if abs(v.translation.width) > abs(dy) * 1.5 && mode == 0 { return }
                if mode == 0 {
                    if dy > 0 && qBase == 0 { mode = 1 }
                    else if dy < 0 && edge { return }
                    else { mode = 2 }
                }
                if mode == 1 { sheetY = max(0, dy) }
                else { qp = qg.level(qg.lifted(qBase) - dy) }
            }
            .onEnded { v in
                let dy = v.translation.height
                let flick = abs(v.predictedEndTranslation.height - dy) > 90
                gestureStart = nil
                if mode == 1 {
                    if dy > FAR || (flick && dy > 30) { requestClose() } else { withAnimation(SHEET) { sheetY = 0 } }
                } else if mode == 2 {
                    var to = qp.rounded()
                    if flick { to = dy < 0 ? min(2, qBase + 1) : max(0, qBase - 1) }
                    setQ(to)
                }
                mode = 0
            })
    }

    // MARK: controls

    private func controls(_ it: Item?, noLyrics: Bool, bottom: CGFloat, H: CGFloat) -> some View {
        let ink = look.ink
        return ZStack(alignment: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    fs("skipPrev", "Previous") { pm.previous() }
                    fs(pm.isPlaying || pm.loading ? "pause" : "play", pm.isPlaying || pm.loading ? "Pause" : "Play", main: true) { pm.toggle() }
                    fs("skipNext", "Next") { pm.nextSong() }
                }
                .padding(.horizontal, 38) // the web's grid: the three sit over columns 2-7, centred over the four below
                HStack(spacing: 0) {
                    // the lyrics button (new in the Swift app): shows or hides the lyrics
                    cell { Button { if !noLyrics { withAnimation(.easeInOut(duration: 0.3)) { coverOnly.toggle() } } } label: {
                        SVGPath(d: "M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z").fill(ink.color()).frame(width: 22, height: 22).frame(width: 46, height: 46)
                    }.buttonStyle(.plain).opacity(noLyrics ? 0.3 : 1).accessibilityLabel("Lyrics") }
                    fs("queueAdd", "Open queue") { qFromButton = qp < 0.5; setQ(qp > 0.5 ? 0 : 2) }
                    cell { Button { if let it { Favs.toggle(it) } } label: {
                        let on = it.map { Favs.isFav($0) } ?? false
                        SVGPath(d: "M16.5 3c-1.74 0-3.41.81-4.5 2.09C10.91 3.81 9.24 3 7.5 3 4.42 3 2 5.42 2 8.5c0 3.78 3.4 6.86 8.55 11.54L12 21.35l1.45-1.32C18.6 15.36 22 12.28 22 8.5 22 5.42 19.58 3 16.5 3z").fill(on ? ink.color() : .clear)
                            .overlay(SVGPath(d: "M16.5 3c-1.74 0-3.41.81-4.5 2.09C10.91 3.81 9.24 3 7.5 3 4.42 3 2 5.42 2 8.5c0 3.78 3.4 6.86 8.55 11.54L12 21.35l1.45-1.32C18.6 15.36 22 12.28 22 8.5 22 5.42 19.58 3 16.5 3z").stroke(ink.color(), style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
                            .frame(width: 22, height: 22).frame(width: 46, height: 46)
                    }.buttonStyle(.plain) }
                    if let it { cell { SongMenu(it: it, player: true) { Icon(name: "moreV", size: 22, color: ink.color()).frame(width: 46, height: 46) } } }
                }
            }
            .frame(width: 304).padding(.bottom, 18 + bottom).contentShape(Rectangle()).gesture(zone(H))
            // no contentShape here: the padding below the bar is part of this view, and a shape over it swallowed every tap on the buttons under it
            // no layout animation inside the bar: the sheet's opening animation slid the times in from the top-left corner
            PlayBar(duration: pm.duration, ink: ink).geometryGroup().padding(.horizontal, 14).padding(.bottom, 138 + bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func cell<C: View>(@ViewBuilder _ c: () -> C) -> some View { c().frame(width: 76).frame(maxWidth: .infinity) }

    private func fs(_ name: String, _ label: String, main: Bool = false, _ action: @escaping () -> Void) -> some View {
        let size: CGFloat = main ? 54 : 46
        let ink = look.ink
        return cell {
            Button(action: action) {
                Icon(name: name, size: 22, color: main ? Color(hex: 0x0c0c0e) : ink.color()).frame(width: size, height: size)
                    .background(main ? ink.color() : .clear, in: Circle())
            }.buttonStyle(PressStyle()).accessibilityLabel(label).accessibilityIdentifier("fs-" + label)
        }
    }
}

/// The web's loading spinner: 26 px, shown only when the lyrics take longer than 0.3 s.
struct Spinner: View {
    @State private var show = false
    @State private var rot = 0.0
    var body: some View {
        Group {
            if show {
                Circle().trim(from: 0, to: 0.75).stroke(Color.white.opacity(0.85), lineWidth: 3).frame(width: 26, height: 26).rotationEffect(.degrees(rot)).opacity(0.8)
                    .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { rot = 360 } }
            }
        }.task { try? await Task.sleep(nanoseconds: 300_000_000); show = true }
    }
}

/// The web's fades over the top and the bottom of the screen: the cover's own edge colours, strong at the edge, clear toward the middle.
struct EdgeFades: View {
    let look: CoverLook
    var body: some View {
        let H = UIScreen.main.bounds.height
        func stops(_ c: Rgb, reversed: Bool) -> [Gradient.Stop] {
            let col = Color(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255)
            var s = zip(CoverInk.fadeAlpha, CoverInk.fadeAt).map { Gradient.Stop(color: col.opacity($0), location: $1) }
            if reversed { s = s.map { Gradient.Stop(color: $0.color, location: 1 - $0.location) }.reversed() }
            return s
        }
        return ZStack {
            LinearGradient(stops: stops(look.top, reversed: false), startPoint: .top, endPoint: .bottom).frame(height: H * 0.22).frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(stops: stops(look.bottom, reversed: true), startPoint: .top, endPoint: .bottom).frame(height: H * 0.38).frame(maxHeight: .infinity, alignment: .bottom)
        }.allowsHitTesting(false)
    }
}

/// The web's bar: the time so far, the bar, the length of the song. It fills a frame at a time; dragging scrubs and the song seeks on release.
struct PlayBar: View {
    let duration: Double
    let ink: Ink
    var compact = false
    @Environment(PlayerModel.self) private var pm
    // a drag that is cancelled (Control Center, a call) resets by itself
    @GestureState private var drag: Double?

    var body: some View {
        let _ = pm.position // a seek while paused redraws the bar (the timelines below are paused then)
        HStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !pm.isPlaying && drag == nil)) { _ in
                Text(timeText(drag.map { $0 * duration } ?? min(pm.now, duration > 0 ? duration : pm.now))).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(ink.color()).frame(minWidth: 34, alignment: .leading)
            }
            GeometryReader { g in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !pm.isPlaying && drag == nil)) { _ in
                    let f: CGFloat = CGFloat(drag ?? (duration > 0 ? max(0, min(1, pm.now / duration)) : 0))
                    ZStack(alignment: .leading) {
                        Capsule().fill(ink.color(0.3)).frame(height: 6)
                        Capsule().fill(ink.color()).frame(width: g.size.width * f, height: 6)
                        Circle().fill(ink.solid).frame(width: 14.4, height: 14.4).scaleEffect(drag != nil ? 1.25 : 1).offset(x: g.size.width * f - 7.2)
                    }.frame(height: compact ? 20 : 40)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($drag) { v, st, _ in st = Double(max(0, min(1, v.location.x / max(1, g.size.width)))) }
                    .onEnded { v in
                        guard duration > 0 else { return } // no length yet: a seek would restart the song
                        let f = Double(max(0, min(1, v.location.x / max(1, g.size.width))))
                        pm.seek(to: f * duration)
                    })
            }.frame(height: compact ? 20 : 40).padding(.horizontal, 6)
            Text(timeText(duration)).font(.system(size: 11)).monospacedDigit().foregroundStyle(ink.color()).frame(minWidth: 34, alignment: .trailing)
        }
    }
}

// MARK: - Queue

/// The web's phone queue: no title; the songs (the playing one at the top). In the full queue a chevron at the top lowers it
/// and a close button slides in at the bottom right. Swipe a song to the right to take it out (the red deepens as it goes);
/// hold one for its menu. Pulling the list down at its top lowers the queue; scrolling it up from the small queue opens the full one.
struct QueuePanel: View {
    var level: CGFloat
    var set: (CGFloat) -> Void
    var zone: AnyGesture<DragGesture.Value>
    var top: CGFloat
    var bottom: CGFloat
    @Environment(PlayerModel.self) private var pm
    @State private var touching = false // the person's finger is scrolling the list (programmatic scrolls never change the level)

    /// scrolls a row to 40 under the list's top (the room kept above the first row), not to the very top: a row's point at y = f * 66
    /// meets the list's point at f * its height, so f = 40 / (height - 66)
    private var rowTop: UnitPoint {
        let h = UIScreen.main.bounds.height - (top + 12)
        return UnitPoint(x: 0.5, y: 40 / max(1, h - 66))
    }

    var body: some View {
        let full = level > 1.5
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(pm.queue.enumerated()), id: \.offset) { i, s in
                            QueueRow(song: s, i: i, now: i == pm.index, played: i < pm.index)
                                .id(i)
                                .onAppear { if i >= pm.queue.count - 6 { pm.moreQueue() } }
                        }
                        Color.clear.frame(height: 90 + bottom)
                    }
                    .padding(.horizontal, 12).padding(.top, 40)
                }
                .mask(LinearGradient(stops: [.init(color: full ? .clear : .black, location: 0), .init(color: .black, location: 22 / max(1, UIScreen.main.bounds.height))], startPoint: .top, endPoint: .bottom))
                .onScrollPhaseChange { _, p in touching = p == .interacting || p == .tracking }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { old, y in
                    // only the person's own scrolling moves the queue: pulled down past the top, down a level; scrolled up from the small queue, the full queue
                    guard touching else { return }
                    if y < -60 { touching = false; set(max(0, level.rounded() - 1)) }
                    else if y > old + 24 && level > 0.5 && level < 1.5 { touching = false; set(2) }
                }
                // the web's: in the small queue the list is lifted by the 40 kept for the chevron, so it starts right under the buttons
                .offset(y: -40 * (1 - max(0, min(1, level - 1))))
                .onAppear { proxy.scrollTo(pm.index, anchor: rowTop) }
                // the playing song goes to the top at once, with no animation
                .onChange(of: pm.index) { _, n in var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { proxy.scrollTo(n, anchor: rowTop) } }
            }
            // the chevron at the top of the full queue lowers it to the small one
            Button { set(1) } label: {
                Image(systemName: "chevron.compact.down").font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity).frame(height: 44, alignment: .top).padding(.top, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).opacity(full ? 1 : 0).allowsHitTesting(full).gesture(zone)
            .accessibilityLabel("Lower the queue")
        }

    }

}

/// One song in the queue. A swipe to the right takes it out: the row follows the finger over a red that deepens as it goes,
/// and letting go past a third of the width removes it (the playing song too: the next one plays).
private struct QueueRow: View {
    let song: Item
    let i: Int
    let now: Bool
    let played: Bool
    @Environment(PlayerModel.self) private var pm
    @State private var dx: CGFloat = 0
    @State private var gone = false

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            let f = min(1, dx / w)
            ZStack(alignment: .leading) {
                // the red under the row: deeper the further it is pulled
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.86 - 0.5 * Double(f), green: 0.16 - 0.12 * Double(f), blue: 0.18 - 0.12 * Double(f)))
                    .overlay(alignment: .leading) {
                        Image(systemName: "trash.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .padding(.leading, 20).opacity(Double(min(1, f * 4)))
                    }
                    .opacity(dx > 1 ? 1 : 0)
                row
                    .offset(x: dx)
            }
            // a UIKit pan that only starts on a swipe to the right: an up/down drag is left to the list, which scrolls
            // (a SwiftUI drag on every row took the vertical drags too, and the queue could not be scrolled)
            .gesture(RowSwipe(changed: { dx = max(0, $0) }, ended: { x, v in
                if x > w * 0.35 || (x > 20 && v > 900) {
                    withAnimation(.easeOut(duration: 0.22)) { dx = w; gone = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { pm.remove(at: i); dx = 0; gone = false }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dx = 0 }
                }
            }))
        }
        .frame(height: 66)
        .opacity(gone ? 0 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("queue-row-\(i)")
    }

    private var row: some View {
        HStack(spacing: 14) {
            Pic_(Pic.thumb(song, 132), radius: 7).frame(width: 44, height: 44).savedEdge(song.id, radius: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(song.title).font(.q(16)).foregroundStyle(now ? Color.pink : Color(hex: 0xd4d4d4)).lineLimit(1)
                Text(song.artistLine + (song.runTimeTicks == nil ? "" : " • \(mmss(song.runTimeTicks))")).font(.q(12.5)).foregroundStyle(Color.dimText).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .opacity(played ? 0.5 : 1)
        .padding(.vertical, 11).padding(.horizontal, 10).frame(height: 66)
        .background(now ? Color.white.opacity(0.07) : Color.black.opacity(0.001), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { pm.jump(to: i) }
        .contextMenu {
            Button { pm.jump(to: i) } label: { Label("Play from here", systemImage: "play") }
            Button(role: .destructive) { pm.remove(at: i) } label: { Label("Remove from queue", systemImage: "minus.circle") }
            Divider()
            SongMenuItems(it: song)
        }
    }
}



/// The lyrics column's top and bottom fade: an eased curve (no visible band where a straight ramp would end)
enum LyricsFade {
    static let gradient: Gradient = {
        func ss(_ u: Double) -> Double { let x = max(0, min(1, u)); return x * x * (3 - 2 * x) }
        var stops: [Gradient.Stop] = []
        for k in 0...10 { let u = Double(k) / 10; stops.append(.init(color: .black.opacity(ss(u)), location: 0.2 * u)) }
        for k in 0...10 { let u = Double(k) / 10; stops.append(.init(color: .black.opacity(ss(1 - u)), location: 0.68 + 0.32 * u)) }
        return Gradient(stops: stops)
    }()
}


/// The web's queue geometry (--qlift, --qtop, --qrange): how far the controls have risen at a level, and where the list sits.
struct QGeo {
    let H: CGFloat, top: CGFloat, bottom: CGFloat
    var lift: CGFloat { H * 0.27 }
    var qtop: CGFloat { top + 12 }
    var range: CGFloat { max(1, H - qtop - lift - 4 - bottom) }
    /// how far the controls have risen at level p (0...2)
    func lifted(_ p: CGFloat) -> CGFloat { p <= 1 ? lift * max(0, p) : lift + range * min(1, p - 1) }
    /// the level for a rise of l points
    func level(_ l: CGFloat) -> CGFloat { l <= lift ? max(0, l / lift) : min(2, 1 + (l - lift) / range) }
    /// the list's offset from its full-queue place
    func listY(_ p: CGFloat) -> CGFloat { p <= 1 ? range + lift * (1 - max(0, p)) : range * (2 - min(2, p)) }
}


/// A pan that begins only when the finger moves mostly to the right, so the scroll view keeps every vertical drag.
struct RowSwipe: UIGestureRecognizerRepresentable {
    var changed: (CGFloat) -> Void
    var ended: (_ dx: CGFloat, _ velocity: CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return false }
            let v = p.velocity(in: p.view)
            return v.x > 0 && abs(v.x) > abs(v.y) * 1.3
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let dx = g.translation(in: g.view).x
        switch g.state {
        case .began, .changed: changed(dx)
        case .ended: ended(dx, g.velocity(in: g.view).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }
}
