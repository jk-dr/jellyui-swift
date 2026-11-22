import SwiftUI

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
                PlayBar(duration: pm.duration, ink: Ink(r: 248, g: 204, b: 204, a: 1), compact: true)
            }
            .padding(.leading, 13).padding(.trailing, 10).padding(.top, 10).padding(.bottom, 6)
            .background(Color(hex: 0x1c1c1f).opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
            .padding(.horizontal, 12)
            .contextMenu {
                Button { Favs.toggle(it) } label: { Label(fav ? "Remove from Favourites" : "Favourite", systemImage: fav ? "heart.slash" : "heart") }
                Button { open() } label: { Label("Lyrics and full screen", systemImage: "music.quarternote.3") }
                Button(role: .destructive) { closeAsk = true } label: { Label("Close playback", systemImage: "xmark") }
            }
            .gesture(DragGesture(minimumDistance: 10).onEnded { v in if v.translation.height < -40 && abs(v.translation.width) < 24 { open() } })
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
    @State private var qY: CGFloat = UIScreen.main.bounds.height
    @State private var qOpen = false
    @State private var mode = 0 // 0 undecided, 1 closing the sheet, 2 opening the queue
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

    var body: some View {
        let H = UIScreen.main.bounds.height
        let top = Insets.top, bottom = Insets.bottom
        let it = pm.current
        let artist = it?.artistLine ?? ""
        let showLyrics = !coverOnly && !settings.lyricsHidden && (loading || !lines.isEmpty)
        let noLyrics = !loading && lines.isEmpty
        let cover = it.flatMap { Pic.square($0, 160) }
        let ink = look.ink

        ZStack {
            Color(hex: 0x0a0a0c)
            if late { BackdropView(cover: cover, playing: pm.isPlaying).transition(.opacity.animation(.easeIn(duration: 0.9))).allowsHitTesting(false) }
            else { Color(red: 8 / 255, green: 8 / 255, blue: 10 / 255).opacity(0.55) }
            if late, let g = Grain.image { Image(uiImage: g).resizable(resizingMode: .tile).allowsHitTesting(false) }

            // the lyrics column: 76 under the safe area, 222 above the bottom; the sung line rests in its middle
            if showLyrics {
                ZStack {
                    if early && !lines.isEmpty {
                        LyricsView(lines: lines, player: pm, topInset: 25, bottomInset: UIScreen.main.bounds.height * 0.4)
                            .mask(LinearGradient(gradient: LyricsFade.gradient, startPoint: .top, endPoint: .bottom))
                            .id(lyricsFor) // a new song gets a new column: it starts at its own first line, with no glide from the last song's place
                            .transition(.opacity.animation(.easeIn(duration: 0.22)))
                    }
                    if loading && lines.isEmpty { Spinner() }
                }
                .padding(.top, top + 76).padding(.bottom, 222 + bottom).padding(.trailing, 46)
                // the strip down the right edge closes the screen from over the lyrics
                Color.clear.contentShape(Rectangle()).frame(width: 46).frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, top + 76).padding(.bottom, 222 + bottom).gesture(zone(H, noQueue: true))
            } else {
                // no lyrics (or hidden): the cover and the name fill the space, centred
                VStack(spacing: 0) {
                    if let it { Pic_(Pic.square(it, 700), radius: 12).aspectRatio(1, contentMode: .fit).frame(maxWidth: 420).containerRelativeFrame(.horizontal) { w, _ in w * 0.82 } }
                    MarqueeText(text: it?.title ?? "", font: .q(26), color: ink.color(), center: true).padding(.top, 24).shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                    MarqueeText(text: artist, font: .q(17), color: ink.color(), center: true).padding(.top, 6).shadow(color: .black.opacity(0.75), radius: 4, y: 1)
                    if loading { Spinner().padding(.top, 20) }
                }
                .padding(.horizontal, 18).frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, top + 64).padding(.bottom, 222 + bottom)
                .contentShape(Rectangle()).gesture(zone(H))
            }

            EdgeFades(look: look).opacity(pm.isPlaying ? 1 : 0.4).animation(.easeInOut(duration: 0.7), value: pm.isPlaying)

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
            }

            controls(it, noLyrics: noLyrics, bottom: bottom, H: H)

            // the queue: drags up from the bottom with the finger
            QueuePanel(close: { toggleQueue(false, H) }, zone: zone(H, noQueue: true), top: top, bottom: bottom)
                .offset(y: qY).allowsHitTesting(qOpen || qY < H).opacity(late ? 1 : 0)
        }
        .environment(\.ink, ink)
        .frame(width: UIScreen.main.bounds.width, height: H)
        .clipped()
        .offset(y: sheetY)
        .opacity(shown ? 1 - 0.5 * Double(max(0, min(1, sheetY / H))) : 0)
        .ignoresSafeArea()
        .onAppear {
            FrameMonitor.event("player", "sheet mounted")
            withAnimation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.45)) { sheetY = 0 }
            withAnimation(.easeOut(duration: 0.38)) { shown = true }
            Task {
                try? await Task.sleep(nanoseconds: 180_000_000); early = true
                try? await Task.sleep(nanoseconds: 300_000_000); FrameMonitor.event("player", "heavy parts mount now"); withAnimation { late = true }
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task(id: it?.id) { await loadSong(it) }
        .task(id: cover) { if let u = cover, let l = await CoverInk.load(u) { withAnimation(.easeInOut(duration: 0.5)) { look = l } } }
        .task(id: pm.next?.id) { if let n = pm.next, let u = Pic.square(n, 160) { _ = await CoverInk.load(u); _ = await CoverColours.load(u) } }
        .onChange(of: pm.current == nil) { _, none in if none { requestClose() } }
    }

    private func loadSong(_ it: Item?) async {
        coverOnly = false
        // the last song's lines go at once (they used to stay up until the new ones arrived)
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

    private func toggleQueue(_ open: Bool, _ H: CGFloat) {
        qOpen = open
        withAnimation(open ? .timingCurve(0.2, 0.7, 0.3, 1, duration: 0.18) : .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.26)) { qY = open ? 0 : H }
    }

    /// A swipe DOWN drags the whole screen down (and away when let go past 90 px, or flicked), a swipe UP drags the queue up from the bottom.
    private func zone(_ H: CGFloat, noQueue: Bool = false) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                // a new drag has a new start point. A cancelled drag never reaches onEnded, so this is what clears its mode.
                if v.startLocation != gestureStart { gestureStart = v.startLocation; mode = 0; edge = v.startLocation.y > H - 44 }
                let dy = v.translation.height
                if abs(v.translation.width) > abs(dy) * 1.5 && mode == 0 { return }
                if qOpen { if dy > 0 { qY = dy }; return }
                if mode == 0 {
                    if dy > 0 { mode = 1 } else if !edge && !noQueue { mode = 2 } else { return }
                }
                if mode == 1 { sheetY = max(0, dy) } else { qY = max(0, H + dy) }
            }
            .onEnded { v in
                let dy = v.translation.height
                let flick = abs(v.predictedEndTranslation.height - dy) > 90
                gestureStart = nil
                if qOpen {
                    if dy > FAR || (flick && dy > 30) { toggleQueue(false, H) } else { withAnimation(SHEET) { qY = 0 } }
                } else if mode == 1 {
                    if dy > FAR || (flick && dy > 30) { requestClose() } else { withAnimation(SHEET) { sheetY = 0 } }
                } else if mode == 2 {
                    if -dy > FAR || (flick && -dy > 30) { toggleQueue(true, H) } else { withAnimation(SHEET) { qY = H } }
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
                HStack(spacing: 0) {
                    // the lyrics button (new in the Swift app): shows or hides the lyrics
                    cell { Button { if !noLyrics { withAnimation(.easeInOut(duration: 0.3)) { coverOnly.toggle() } } } label: {
                        SVGPath(d: "M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z").fill(ink.color()).frame(width: 22, height: 22).frame(width: 46, height: 46)
                    }.buttonStyle(.plain).opacity(noLyrics ? 0.3 : 1).accessibilityLabel("Lyrics") }
                    fs("queueAdd", "Open queue") { toggleQueue(true, H) }
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
            PlayBar(duration: pm.duration, ink: ink).transaction { $0.animation = nil }.padding(.horizontal, 14).padding(.bottom, 138 + bottom)
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
    @State private var drag: Double?

    var body: some View {
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
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in drag = Double(max(0, min(1, v.location.x / max(1, g.size.width)))) }
                    .onEnded { v in
                        let f = Double(max(0, min(1, v.location.x / max(1, g.size.width))))
                        pm.seek(to: f * duration)
                        drag = nil
                    })
            }.frame(height: compact ? 20 : 40).padding(.horizontal, 6)
            Text(timeText(duration)).font(.system(size: 11)).monospacedDigit().foregroundStyle(ink.color()).frame(minWidth: 34, alignment: .trailing)
        }
    }
}

// MARK: - Queue

/// The web's phone queue: "Queue (N)" at the top, the songs (the playing one at the top), swipe a row to the right to take it out,
/// and Clear / Shuffle / Close floating at the bottom right. The background is blurred.
struct QueuePanel: View {
    var close: () -> Void
    var zone: AnyGesture<DragGesture.Value>
    var top: CGFloat
    var bottom: CGFloat
    @Environment(PlayerModel.self) private var pm
    @State private var clearAsk = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(Color.black.opacity(0.45)).background(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 0) {
                Text("Queue (\(pm.queue.count))").font(.q(20)).foregroundStyle(Color.pink)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 16).padding(.top, 6).padding(.bottom, 12)
                    .contentShape(Rectangle()).gesture(zone)
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(pm.queue.enumerated()), id: \.offset) { i, s in
                            let now = i == pm.index
                            HStack(spacing: 14) {
                                Pic_(Pic.square(s, 100), radius: 7).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(s.title).font(.q(16)).foregroundStyle(now ? Color.pink : Color(hex: 0xd4d4d4)).lineLimit(1)
                                    Text(s.artistLine + (s.runTimeTicks == nil ? "" : " • \(mmss(s.runTimeTicks))")).font(.q(12.5)).foregroundStyle(Color.dimText).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .opacity(i < pm.index ? 0.5 : 1)
                            .padding(.vertical, 11).padding(.horizontal, 10).frame(height: 66)
                            .background(now ? Color(hex: 0x1d1d20) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { pm.jump(to: i) }
                            .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if !now { Button(role: .destructive) { pm.remove(at: i) } label: { Text("Remove") } }
                            }
                            .id(i)
                            .onAppear { if i >= pm.queue.count - 6 { pm.moreQueue() } }
                        }
                        Color.clear.frame(height: 70 + bottom).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    // pulling the list down past its top closes the queue (not just the title row)
                    .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top < -70 } action: { _, past in if past { close() } }
                    .onAppear { proxy.scrollTo(pm.index, anchor: .top) }
                    // the playing song goes to the top at once, with no animation
                    .onChange(of: pm.index) { _, n in var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { proxy.scrollTo(n, anchor: .top) } }
                }
            }
            .padding(.top, top + 14)
            HStack(spacing: 10) {
                pill(width: 72) { Text("Clear").font(.q(14)).foregroundStyle(Color(hex: 0xd4d4d4)) } action: { clearAsk = true }
                pill(width: 44) { Icon(name: "shuffle", size: 22, color: Color(hex: 0xd4d4d4)) } action: { pm.shuffleUpcoming() }
                pill(width: 44) { Text("×").font(.q(24)).foregroundStyle(Color(hex: 0xd4d4d4)) } action: { close() }
            }.padding(.trailing, 14).padding(.bottom, 14 + bottom)
        }
        .alert("Clear the queue?", isPresented: $clearAsk) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { close(); pm.stop() }
        } message: { Text("This stops the music and empties the queue.") }
    }

    private func pill<C: View>(width: CGFloat, @ViewBuilder _ c: () -> C, action: @escaping () -> Void) -> some View {
        Button(action: action) { c().frame(width: width, height: 44).background(Color.surfaceHi, in: Capsule()).shadow(color: .black.opacity(0.5), radius: 9, y: 4) }.buttonStyle(.plain)
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
