import AVFoundation
import AVKit
import SwiftUI

// MARK: - Orientation (video opens sideways)

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var mask: UIInterfaceOrientationMask = .portrait
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { Self.mask }
}

enum Orient {
    static func set(_ mask: UIInterfaceOrientationMask, rotateTo: UIInterfaceOrientationMask? = nil) {
        AppDelegate.mask = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: rotateTo ?? mask)) { _ in }
    }
}

// MARK: - The picture

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var onReady: (AVPlayerLayer) -> Void = { _ in }
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        onReady(v.playerLayer)
        return v
    }
    func updateUIView(_ v: PlayerLayerView, context: Context) {}
}

// MARK: - The screen

struct VideoScreen: View {
    let request: PlayRequest
    @Environment(\.dismiss) private var dismiss
    @State private var pb: VideoModel
    @State private var everReady = false

    init(request: PlayRequest) {
        self.request = request
        _pb = State(initialValue: VideoModel(request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if everReady { Stage(pb: pb, onExit: leave) }
            else if pb.phase == .error { PlayError(pb: pb, onExit: leave) }
            else { PrepScreen(pb: pb, onLeave: leave) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task { await pb.start() }
        .onChange(of: pb.phase) { _, p in if p == .ready { everReady = true } }
        .onDisappear { pb.dispose() }
    }

    private func leave() {
        // only what watching changes: continue-watching, next-up, episode progress, the item itself
        Mem.clear()
        Orient.set(.portrait)
        dismiss()
    }
}

struct PlayError: View {
    let pb: VideoModel
    var onExit: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Text(pb.title).font(.q(22)).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(pb.error).font(.q(15)).foregroundStyle(Color.dimText).multilineTextAlignment(.center)
            Btn(label: "Back", action: onExit).padding(.top, 16).frame(maxWidth: 200)
        }.padding(24)
    }
}

// MARK: - Preparing the stream (the on-demand gate)

private struct GateSteps {
    var p: Double
    var rows: [(label: String, ok: Bool, extra: String)]
    var pct: Double
}

private func steps(_ g: GateInfo?) -> GateSteps {
    let has = g?.hasGate ?? false
    let found = has || ((g?.status ?? "") != "" && g?.status != "Requested")
    let p = has ? max(0, min(100, (g?.gateProgress ?? 0) * 100)) : 0
    let rows: [(String, Bool, String)] = [
        ("Finding a release", found, ""), ("Starting the download", has, ""), ("Download fast enough to play", g?.speed ?? false, ""),
        ("Start and end of the file", g?.headerTail ?? false, ""), ("First chunk buffered", g?.fraction ?? false, has ? "\(Int(p.rounded()))%" : ""),
    ]
    var pct = 0.0
    if found { pct += 9 }
    if has { pct += 3 }
    if g?.speed == true { pct += 5 }
    if g?.headerTail == true { pct += 15 }
    if has { pct += 63 * ((g?.fraction ?? false) ? 1 : max(0, min(1, g?.gateProgress ?? 0))) }
    return GateSteps(p: p, rows: rows.map { (label: $0.0, ok: $0.1, extra: $0.2) }, pct: pct)
}

private func gateMessage(_ g: GateInfo?) -> String {
    guard let g, g.hasGate else { return STATUS_TEXT[g?.status ?? ""] ?? "Getting things ready…" }
    if g.open { return "Ready" }
    if !g.headerTail { return "Fetching the start and the end of the file…" }
    if !g.fraction { return (STATUS_TEXT[g.status] ?? "Downloading…") + (g.progress.map { String(format: " %.1f%% of the file", $0 * 100) } ?? "") }
    return "Buffered. Waiting for the download speed to be enough to play without pausing…"
}

func formatTime(_ sec: Double) -> String {
    let s = max(0, Int(sec.rounded()))
    let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
    return (h > 0 ? "\(h):" + String(format: "%02d", m) : String(m)) + ":" + String(format: "%02d", ss)
}

struct PrepScreen: View {
    let pb: VideoModel
    var onLeave: () -> Void
    @State private var pctShown = 0.0
    @State private var forcing = ""
    @State private var discarding = false
    @State private var waitSince: Date?
    @State private var gateStart = Date()

    var body: some View {
        let gate = pb.phase == .gate ? pb.gate : nil
        let simple = gate == nil
        let st = steps(gate)
        let pct = max(gate?.open == true ? max(st.pct, 95) : st.pct, pctShown)
        let low = ["720p", "576p", "480p"].contains(gate?.quality ?? "")
        let canAnyway = (gate?.fraction ?? false) && (gate?.headerTail ?? false) && !(gate?.speed ?? false)
        let showAnyway = canAnyway && (waitSince.map { Date().timeIntervalSince($0) > 15 } ?? false)
        let slow = !simple && !(gate?.open ?? false) && pb.elapsed > 30 && Date().timeIntervalSince(gateStart) > 30

        ScrollView {
            VStack(spacing: 0) {
                if let p = pb.poster { Pic_(p, radius: 12).frame(width: 120, height: 180).padding(.bottom, 16) }
                Text(pb.title).font(.q(24)).foregroundStyle(Color.pink).multilineTextAlignment(.center).lineLimit(2).padding(.bottom, 12)
                if simple {
                    VStack(spacing: 12) { ProgressView().tint(.white); Text(pb.message).font(.q(14)).foregroundStyle(Color.dimText) }.padding(.top, 16)
                } else {
                    Text("Preparing your stream").font(.q(18)).foregroundStyle(Color.pink).padding(.bottom, 16)
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.12), lineWidth: 8)
                        Circle().trim(from: 0, to: pct / 100).stroke(Color.pink, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text("\(Int(pct.rounded()))%").font(.q(26)).foregroundStyle(Color.pink)
                    }.frame(width: 112, height: 112).padding(.bottom, 16)
                    VStack(alignment: .leading, spacing: 10) {
                        let first = st.rows.firstIndex { !$0.ok }
                        ForEach(Array(st.rows.enumerated()), id: \.offset) { i, r in
                            let cur = !r.ok && first == i
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().stroke(r.ok ? Color.pink : Color.white.opacity(0.25), lineWidth: 2).background(Circle().fill(r.ok ? Color.pink : .clear))
                                    if r.ok { Icon(name: "check", size: 14, color: .white) } else if cur { ProgressView().scaleEffect(0.5).tint(.white) }
                                }.frame(width: 22, height: 22)
                                Text(r.label).font(.system(size: 14, weight: .bold)).foregroundStyle(!r.ok && !cur ? Color(hex: 0x6a6a70) : Color.pink).frame(maxWidth: .infinity, alignment: .leading)
                                if !r.extra.isEmpty { Text(r.extra).font(.q(13)).foregroundStyle(Color.dimText) }
                            }
                        }
                    }.frame(maxWidth: 380).padding(.bottom, 16)
                    Text(gateMessage(gate)).font(.q(14)).foregroundStyle(Color.dimText).multilineTextAlignment(.center)
                    Text("Elapsed \(formatTime(pb.elapsed))").font(.q(12)).foregroundStyle(Color(hex: 0x6a6a70)).padding(.top, 6)
                    Text(slow ? "This download is taking awhile, you might want to come back later." : (pb.busy ? "Multiple people have requested different movies, it’s recommended that you come back later since stutter may occur" : "This won’t take long, you can either come back or wait for the loading to conclude."))
                        .font(.q(13)).foregroundStyle(slow || pb.busy ? Color(hex: 0xffb454) : Color.dimText).multilineTextAlignment(.center).frame(maxWidth: 360).padding(.top, 12)
                    if low {
                        Btn(label: forcing.isEmpty ? "Downloading in \(gate?.quality ?? ""). Tap to force 1080p (this will take longer)" : forcing, disabled: !forcing.isEmpty) { Task { await force1080() } }
                            .padding(.top, 12).frame(maxWidth: 380)
                    }
                }
                VStack(spacing: 8) {
                    if showAnyway { Btn(label: "Play anyway", kind: .primary) { pb.playAnyway() } }
                    if !simple { Btn(label: "Leave and download", action: onLeave) }
                    if !simple && !pb.tmdb.isEmpty {
                        Btn(label: discarding ? "Discarding…" : "Leave and discard", kind: .danger, busy: discarding) {
                            discarding = true
                            Task { _ = try? await Api.request("/JellyUI/Discard/\(pb.tmdb)", method: "POST", quiet: true); onLeave() }
                        }
                    }
                }.frame(maxWidth: 380).padding(.top, 24)
            }
            .padding(.horizontal, 24).padding(.top, Insets.top + 56).padding(.bottom, 32)
        }
        .background(Color.bg.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            Button(action: onLeave) { Icon(name: "back", size: 22).frame(width: 40, height: 40).background(Color.black.opacity(0.45), in: Circle()) }
                .buttonStyle(.plain).padding(.leading, 16).padding(.top, Insets.top + 8)
        }
        .onChange(of: pct) { _, p in if p > pctShown { pctShown = p } }
        .onChange(of: canAnyway) { _, c in waitSince = c ? (waitSince ?? Date()) : nil }
        .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000); _ = pb.elapsed } }
    }

    private func force1080() async {
        guard forcing.isEmpty, !pb.tmdb.isEmpty else { return }
        forcing = "Looking for a 1080p release…"
        do {
            let d = try await Api.request("/OnDemand/Force1080/\(pb.tmdb)", method: "POST", quiet: true)
            let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            let gb = (o?["sizeGb"] ?? o?["SizeGb"]).map { " (\($0) GB)" } ?? ""
            forcing = "Switching to 1080p\(gb)…"
        } catch let e as ApiError {
            forcing = e.status == 404 ? "No 1080p release was found" : (e.status == 403 ? "You can’t change the quality" : "Couldn’t switch to 1080p")
        } catch { forcing = "Couldn’t switch to 1080p" }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        forcing = ""
    }
}

// MARK: - The player

private enum VMenu { case quality, subs, audio }

struct Stage: View {
    let pb: VideoModel
    var onExit: () -> Void
    private let settings = Settings.shared
    @Environment(Nav.self) private var nav

    @State private var player = AVPlayer()
    @State private var layer: AVPlayerLayer?
    @State private var pip: AVPictureInPictureController?
    @State private var playing = false
    @State private var buffering = true
    @State private var swapMsg = ""
    @State private var playErr = ""
    @State private var visible = true
    @State private var menu: VMenu?
    @State private var flash: (text: String, side: Int)?
    @State private var cues: [Cue] = []
    @State private var textSub = -1
    @State private var segs: [Segment] = []
    @State private var skipSeg: Segment?
    @State private var shown = Set<String>()
    @State private var position: Double = 0
    @State private var buffered: Double = 0
    @State private var scrub: Double?
    @State private var fav = false
    @State private var landscapeLock = true
    @State private var hideTask: Task<Void, Never>?
    @State private var lastKey = -1
    @State private var lastGood: Double = 0
    @State private var errRetries = 0
    @State private var observers = Observers()
    @State private var reported = false
    @State private var stopped = false
    @State private var chosenFor = ""
    @State private var lastTap = (t: Date.distantPast, side: 0)

    final class Observers {
        var time: Any?
        var items: [NSKeyValueObservation] = []
        var end: NSObjectProtocol?
    }

    private var now: Double { let t = player.currentTime().seconds; return t.isFinite ? t : position }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Color.black
                PlayerSurface(player: player) { l in layer = l; pip = AVPictureInPictureController(playerLayer: l) }.ignoresSafeArea()
                Color.clear.contentShape(Rectangle()).onTapGesture(count: 1) { loc in tap(loc.x, w) }
                    .gesture(SpatialTapGesture().onEnded { tap($0.location.x, w) })
                subtitles(bottom: visible ? 110 + Insets.bottom : 36 + Insets.bottom)
                if let f = flash {
                    Text(f.text).font(.system(size: 18, weight: .heavy)).foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: f.side < 0 ? .leading : (f.side > 0 ? .trailing : .center))
                        .padding(.horizontal, w * 0.14).allowsHitTesting(false)
                }
                if buffering || !swapMsg.isEmpty {
                    VStack(spacing: 8) { ProgressView().tint(.white).scaleEffect(1.3); if !swapMsg.isEmpty { Text(swapMsg).font(.q(14)).foregroundStyle(.white) } }.allowsHitTesting(false)
                }
                if !playErr.isEmpty {
                    VStack(spacing: 16) {
                        Text(playErr).font(.q(15)).foregroundStyle(Color.dimText).multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            Btn(label: "Try again", kind: .primary) { playErr = ""; Task { await reopen(label: "Reconnecting…") } }
                            Btn(label: "Back", action: exit)
                        }.frame(maxWidth: 360)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.7))
                }
                if let s = skipSeg {
                    Button { player.seek(to: CMTime(seconds: s.end, preferredTimescale: 600)); skipSeg = nil; showFlash("Skipped \(segLabel(s.type))") } label: {
                        Text("Skip \(segLabel(s.type))").font(.q(15)).foregroundStyle(.black).padding(.horizontal, 20).padding(.vertical, 10)
                            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 20).padding(.bottom, 130 + Insets.bottom)
                }
                controls(w)
                if let m = menu { menuSheet(m) }
            }
            .ignoresSafeArea()
        }
        .onAppear { setup() }
        .onDisappear { teardown() }
        .onChange(of: pb.source) { _, s in if let s { Task { await swap(to: s) } } }
        .task(id: pb.ms?.id) { await chooseDefaultSub() }
        .task(id: pb.itemId) { await loadSegments() }
        .task { await segmentLoop() }
    }

    // MARK: setup

    private func setup() {
        fav = pb.favourite
        Orient.set(.landscape)
        player.allowsExternalPlayback = true
        PlayerModel.shared.pause()
        let o = observers
        o.time = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { t in
            let s = t.seconds
            if s.isFinite { position = s; if s > 1 { lastGood = s } }
            if let r = player.currentItem?.loadedTimeRanges.first?.timeRangeValue { buffered = r.start.seconds + r.duration.seconds }
        }
        o.items.append(player.observe(\.timeControlStatus, options: [.new]) { p, _ in
            DispatchQueue.main.async {
                playing = p.timeControlStatus == .playing
                buffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if !playing { wake(stay: true) } else { wake() }
                if reported && !stopped { pb.report("Progress", position: now, paused: !playing) }
            }
        })
        if let s = pb.source { Task { await swap(to: s) } }
        Task { // progress every 10 s
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if reported && !stopped { pb.report("Progress", position: now, paused: !playing) }
            }
        }
    }

    private func teardown() {
        reportStop()
        if let t = observers.time { player.removeTimeObserver(t) }
        if let e = observers.end { NotificationCenter.default.removeObserver(e) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        hideTask?.cancel()
    }

    private func swap(to src: VSource) async {
        guard src.key != lastKey else { return }
        lastKey = src.key
        buffering = true
        let item = AVPlayerItem(url: src.url)
        if let e = observers.end { NotificationCenter.default.removeObserver(e) }
        observers.end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in ended() }
        observers.items.removeAll { $0.description.contains("status") }
        observers.items.append(item.observe(\.status, options: [.new]) { i, _ in
            DispatchQueue.main.async {
                if i.status == .readyToPlay { buffering = false; playErr = ""; errRetries = 0 }
                if i.status == .failed {
                    if errRetries < 2 && !pb.isLive {
                        errRetries += 1; swapMsg = "Reconnecting…"
                        Task { try? await pb.open(pb.itemId, at: max(lastGood - 2, 0)) }
                    } else { buffering = false; playErr = i.error?.localizedDescription ?? "Playback error" }
                }
            }
        })
        player.replaceCurrentItem(with: item)
        let start = pb.startSec
        if !pb.isLive && start > 1 { await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        position = start
        PlayerModel.shared.pause() // a film must not play over a song
        player.play()
        swapMsg = ""
        reported = true; stopped = false
        pb.report("Playing", position: start, paused: false)
    }

    private func reportStop() {
        guard reported, !stopped else { return }
        stopped = true
        pb.report("Stopped", position: now > 0 ? now : lastGood, paused: true)
    }

    private func exit() {
        reportStop()
        player.pause()
        onExit()
    }

    private func ended() {
        if pb.isLive { return }
        // the stream stopped early (still downloading), not the end of the film
        if pb.duration > 0, now < pb.duration - 15, pb.downloaded > 0, pb.downloaded < 99 {
            Task { try? await pb.open(pb.itemId, at: max(0, now - 2)) }
            return
        }
        reportStop()
        if settings.autoNext, let n = pb.nextId {
            Task { await goTo(n) }
        } else { exit() }
    }

    private func goTo(_ id: String) async {
        reportStop()
        // a new player for the next episode: the screen opens again on it
        onExit()
        try? await Task.sleep(nanoseconds: 450_000_000)
        nav.play = PlayRequest(itemId: id)
    }

    // MARK: controls

    private func wake(stay: Bool = false) {
        withAnimation(.easeOut(duration: 0.16)) { visible = true }
        hideTask?.cancel()
        if stay { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if Task.isCancelled || menu != nil { return }
            withAnimation(.easeOut(duration: 0.26)) { visible = false }
        }
    }

    private func tap(_ x: CGFloat, _ w: CGFloat) {
        let side = x < w * 0.35 ? -1 : (x > w * 0.65 ? 1 : 0)
        let t = Date()
        if side != 0, t.timeIntervalSince(lastTap.t) < 0.32, lastTap.side == side {
            lastTap = (t, side)
            skip(side < 0 ? -settings.skipBack : settings.skipFwd)
            return
        }
        lastTap = (t, side)
        Task {
            try? await Task.sleep(nanoseconds: 320_000_000)
            if lastTap.t != t || menu != nil { return }
            if visible { withAnimation(.easeOut(duration: 0.22)) { visible = false } } else { wake() }
        }
    }

    private func togglePlay() { if player.timeControlStatus == .paused { player.play() } else { player.pause() }; wake() }

    /// An on-demand file only exists up to the downloaded point: seeking past it would just stall, so stop just short of it.
    private func limit(_ sec: Double) -> Double {
        guard pb.downloaded > 0, pb.downloaded < 99.95, pb.duration > 0 else { return sec }
        let mx = max(0, pb.duration * pb.downloaded / 100 - 20)
        return sec > mx && sec > now ? max(now, mx) : sec
    }

    private func seekTo(_ sec: Double) {
        if pb.isLive { return }
        let t = max(0, min(limit(sec), pb.duration > 0 ? pb.duration : sec))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = t
        wake()
    }

    private func skip(_ d: Int) {
        if pb.isLive { return }
        seekTo(now + Double(d))
        showFlash((d > 0 ? "+" : "−") + "\(abs(d))s", side: d > 0 ? 1 : -1)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func showFlash(_ t: String, side: Int = 0) {
        flash = (t, side)
        Task { try? await Task.sleep(nanoseconds: 700_000_000); flash = nil }
    }

    private func reopen(sub: Int? = nil, audio: Int? = nil, bitrate: Int? = nil, label: String = "Changing…") async {
        let at = now
        swapMsg = label
        do { try await pb.open(pb.itemId, at: at, sub: sub, audio: audio, bitrate: bitrate) }
        catch { swapMsg = "Could not change that"; try? await Task.sleep(nanoseconds: 2_500_000_000); swapMsg = "" }
    }

    // MARK: subtitles and segments

    private func loadCues(_ s: MStream?) async {
        guard let s, let ms = pb.ms else { cues = []; return }
        let path = s.deliveryUrl ?? "/Videos/\(pb.itemId)/\(ms.id)/Subtitles/\(s.index)/0/Stream.vtt"
        guard let u = Api.keyed(path), let (d, _) = try? await URLSession.shared.data(from: u), let t = String(data: d, encoding: .utf8) else { cues = []; return }
        cues = VTT.parse(t)
    }

    private func chooseDefaultSub() async {
        guard let ms = pb.ms, chosenFor != pb.itemId else { return }
        chosenFor = pb.itemId
        let idx = pickDefaultSub(ms.subs, ms.audio, defAudio: ms.defaultAudio, defSub: ms.defaultSub)
        guard let st = ms.subs.first(where: { $0.index == idx }) else { return }
        if st.isText == false { if pb.subIndex != idx { await reopen(sub: idx) } }
        else { textSub = idx; await loadCues(st) }
    }

    private func chooseSub(_ idx: Int) async {
        menu = nil
        let st = pb.ms?.subs.first { $0.index == idx }
        let burning = pb.subIndex > -1
        if idx == -1 { textSub = -1; cues = []; if burning { await reopen(sub: -1) }; return }
        if st?.isText == false { textSub = -1; cues = []; await reopen(sub: idx) }
        else { textSub = idx; await loadCues(st); if burning { await reopen(sub: -1) } }
    }

    private func loadSegments() async {
        segs = []
        guard !pb.isLive, !pb.itemId.isEmpty else { return }
        segs = await Api.segments(pb.itemId)
    }

    private func segLabel(_ t: String) -> String { t == "Outro" ? "Credits" : (["Intro", "Recap", "Preview"].contains(t) ? t : "Segment") }
    private func action(for t: String) -> String {
        t == "Intro" ? settings.segIntro : t == "Outro" ? settings.segOutro : t == "Recap" ? settings.segRecap : t == "Preview" ? settings.segPreview : "none"
    }

    private func segmentLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !segs.isEmpty else { continue }
            let t = now
            guard let seg = segs.first(where: { t >= $0.start && t < $0.end - 1 }) else { skipSeg = nil; continue }
            let act = action(for: seg.type)
            let key = seg.type + String(seg.start)
            if act == "auto" && !shown.contains(key) {
                shown.insert(key)
                player.seek(to: CMTime(seconds: seg.end, preferredTimescale: 600))
                showFlash("Skipped \(segLabel(seg.type))")
            } else if act == "ask" && !shown.contains(key) {
                shown.insert(key)
                skipSeg = seg
                Task { try? await Task.sleep(nanoseconds: 7_000_000_000); if skipSeg == seg { skipSeg = nil } }
            }
        }
    }

    // MARK: layout

    @ViewBuilder private func subtitles(bottom: CGFloat) -> some View {
        if !cues.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.15)) { _ in
                let text = VTT.at(cues, now - settings.subOffset).map { $0.text }.joined(separator: "\n")
                if !text.isEmpty {
                    Text(text).font(.system(size: CGFloat(settings.subSize), weight: settings.subBold ? .heavy : .semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(.horizontal, settings.subBackground ? 10 : 0).padding(.vertical, settings.subBackground ? 3 : 0)
                        .background(settings.subBackground ? Color.black.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: settings.subBackground ? .clear : .black.opacity(0.95), radius: 4, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.horizontal, 32).padding(.bottom, bottom)
                }
            }.allowsHitTesting(false)
        }
    }

    private func controls(_ w: CGFloat) -> some View {
        let padL = max(Insets.window?.safeAreaInsets.left ?? 0, 16), padR = max(Insets.window?.safeAreaInsets.right ?? 0, 16)
        let q = BITRATES_VIDEO.first { $0.value == (pb.maxBitrate >= 120_000_000 ? 120_000_000 : pb.maxBitrate) }?.label ?? "Auto"
        let subNow = pb.subIndex > -1 ? pb.subIndex : textSub
        return ZStack {
            Color.black.opacity(0.4).allowsHitTesting(false)
            VStack {
                HStack(spacing: 10) {
                    iconBtn("back", 22, bg: true) { exit() }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(pb.title).font(.q(18)).foregroundStyle(Color(hex: 0xf2f2f2)).lineLimit(1)
                        if !pb.epLabel.isEmpty { Text(pb.epLabel).font(.q(13)).foregroundStyle(Color.midText).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    iconBtn("heart", 22, bg: true, color: fav ? .pink : .white) { fav.toggle(); let on = fav; Task { await Api.setFavourite(pb.itemId, on) } }
                }
                .padding(.leading, padL).padding(.trailing, padR).padding(.top, 16)
                Spacer()
                VStack(spacing: 2) {
                    if pb.isLive {
                        Text("LIVE").font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.danger, in: RoundedRectangle(cornerRadius: 4)).frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
                    } else {
                        VideoSeek(position: scrub ?? position, duration: pb.duration > 0 ? pb.duration : (player.currentItem?.duration.seconds ?? 0), buffered: buffered, downloaded: pb.downloaded, limit: limit,
                                  onScrub: { s in scrub = s; wake(stay: true) }, onSeek: { s in scrub = nil; seekTo(s) })
                    }
                    HStack(spacing: 2) {
                        if let p = pb.prevId { iconBtn("skipPrev", 24) { Task { await goTo(p) } } }
                        if let n = pb.nextId { iconBtn("skipNext", 24) { Task { await goTo(n) } } }
                        Spacer()
                        Button { menu = .quality; wake(stay: true) } label: {
                            Text(q.replacingOccurrences(of: "Auto (best)", with: "Auto").replacingOccurrences(of: " Mbps", with: "M")).font(.q(14)).foregroundStyle(pb.maxBitrate < 120_000_000 ? Color.pink : Color(hex: 0xf2f2f2))
                                .frame(minWidth: 40, minHeight: 34).padding(.horizontal, 8).background(pb.maxBitrate < 120_000_000 ? Color.pink.opacity(0.18) : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).padding(.trailing, 6)
                        if !(pb.ms?.subs.isEmpty ?? true) { iconBtn("subtitles", 24, color: subNow > -1 ? .pink : .white) { menu = .subs; wake(stay: true) } }
                        if (pb.ms?.audio.count ?? 0) > 1 { iconBtn("audio", 24) { menu = .audio; wake(stay: true) } }
                        iconBtn("pip", 24) { pip?.startPictureInPicture() }
                        iconBtn("rotate", 24, color: landscapeLock ? .pink : .white) {
                            landscapeLock.toggle()
                            Orient.set(landscapeLock ? .landscape : .allButUpsideDown)
                        }
                    }
                }
                .padding(.leading, padL).padding(.trailing, padR).padding(.bottom, Insets.bottom > 20 ? 14 : 8)
            }
            if !pb.isLive || true {
                HStack(spacing: 16) {
                    if !pb.isLive { iconBtn("replay10", 30) { skip(-settings.skipBack) } }
                    Button { togglePlay() } label: {
                        Icon(name: playing ? "pause" : "play", size: 38, color: .bg).frame(width: 72, height: 72).background(Color.pink, in: Circle())
                    }.buttonStyle(.plain)
                    if !pb.isLive { iconBtn("forward30", 30) { skip(settings.skipFwd) } }
                }
            }
        }
        .opacity(visible ? 1 : 0).allowsHitTesting(visible)
    }

    private func iconBtn(_ name: String, _ size: CGFloat, bg: Bool = false, color: Color = .white, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(name: name, size: size, color: color).frame(width: bg ? 40 : 44, height: bg ? 40 : 44).background(bg ? Color.white.opacity(0.14) : .clear, in: Circle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func menuSheet(_ kind: VMenu) -> some View {
        let subs = pb.ms?.subs ?? [], audio = pb.ms?.audio ?? []
        let subSel = pb.subIndex > -1 ? pb.subIndex : textSub
        let audioSel = pb.audioIndex > -1 ? pb.audioIndex : (pb.ms?.defaultAudio ?? audio.first?.index ?? -1)
        let rows: [(key: String, label: String, sub: String?, on: Bool, press: () -> Void)] = {
            switch kind {
            case .quality:
                return BITRATES_VIDEO.map { q in (String(q.value), q.label, nil, q.value == (pb.maxBitrate >= 120_000_000 ? 120_000_000 : pb.maxBitrate), { menu = nil; settings.maxBitrate = q.value; Task { await reopen(bitrate: q.value, label: "Changing quality…") } }) }
            case .subs:
                return [("off", "Off", nil, subSel == -1, { Task { await chooseSub(-1) } })] + subs.map { x in
                    (String(x.index), x.displayTitle ?? "\(x.language ?? "Subtitles")\(x.isForced ? " (forced)" : "")", x.isText == false ? "Picture subtitles: converted by the server" : nil, subSel == x.index, { Task { await chooseSub(x.index) } })
                }
            case .audio:
                return audio.map { x in (String(x.index), x.displayTitle ?? x.language ?? "Track \(x.index)", nil, audioSel == x.index, { menu = nil; Task { await reopen(audio: x.index, label: "Changing audio…") } }) }
            }
        }()
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.6).onTapGesture { menu = nil; wake() }
            VStack(alignment: .leading, spacing: 0) {
                Text(kind == .quality ? "Quality" : (kind == .subs ? "Subtitles" : "Audio")).font(.q(18)).foregroundStyle(Color.pink).padding(.horizontal, 24).padding(.bottom, 8)
                ScrollView {
                    ForEach(rows, id: \.key) { r in
                        Button(action: r.press) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.label).font(.system(size: 16, weight: .heavy)).foregroundStyle(r.on ? Color.pink : Color.pink.opacity(0.9))
                                    if let s = r.sub { Text(s).font(.q(12)).foregroundStyle(Color.dimText) }
                                }
                                Spacer()
                                if r.on { Icon(name: "check", size: 20, color: .pink) }
                            }
                            .padding(.vertical, 14).padding(.horizontal, 24).background(r.on ? Color.white.opacity(0.1) : .clear)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 12).padding(.bottom, Insets.bottom + 8).frame(maxWidth: 520, maxHeight: 360).background(Color.surface, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
        }
    }
}

private let BITRATES_VIDEO: [(value: Int, label: String)] = [
    (120_000_000, "Auto (best)"), (40_000_000, "40 Mbps"), (20_000_000, "20 Mbps"), (10_000_000, "10 Mbps"),
    (6_000_000, "6 Mbps"), (4_000_000, "4 Mbps"), (2_000_000, "2 Mbps"), (1_000_000, "1 Mbps"),
]

// MARK: - The seek bar

struct VideoSeek: View {
    let position: Double
    let duration: Double
    let buffered: Double
    let downloaded: Double
    var limit: (Double) -> Double
    var onScrub: (Double) -> Void
    var onSeek: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                let w = g.size.width
                let f = duration > 0 ? max(0, min(1, position / duration)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.28)).frame(height: 5.4)
                    if downloaded > 0 && downloaded < 99.95 { Capsule().fill(Color(hex: 0x2f8cff)).frame(width: w * downloaded / 100, height: 5.4) }
                    Capsule().fill(Color.white.opacity(0.3)).frame(width: duration > 0 ? w * min(1, buffered / duration) : 0, height: 5.4)
                    Capsule().fill(Color.pink).frame(width: w * f, height: 5.4)
                    Circle().fill(.white).frame(width: 13.2, height: 13.2).scaleEffect(dragging ? 1.5 : 1).shadow(color: .black.opacity(0.6), radius: 3, y: 1).offset(x: w * f - 6.6)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    dragging = true
                    let s = limit(max(0, min(1, v.location.x / max(1, w))) * duration)
                    onScrub(s)
                }.onEnded { v in
                    dragging = false
                    onSeek(limit(max(0, min(1, v.location.x / max(1, w))) * duration))
                })
            }.frame(height: 32)
            HStack {
                Text(formatTime(min(position, duration > 0 ? duration : position))).font(.q(13)).foregroundStyle(Color(hex: 0xd4d4d4)).monospacedDigit()
                Spacer()
                Text("-" + formatTime(max(0, duration - position))).font(.q(13)).foregroundStyle(Color(hex: 0xd4d4d4)).monospacedDigit()
            }
        }
    }
}
