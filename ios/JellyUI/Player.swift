import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI

/// The music player: a queue played by AVPlayer, with lock-screen controls.
@Observable
final class PlayerModel {
    static let shared = PlayerModel()

    var queue: [Item] = [] { didSet { needPrep() } }
    var index = 0
    var isPlaying = false
    var position: Double = 0 // updated about twice a second, for bars and labels
    var duration: Double = 0
    var showFull = false
    var loading = false
    var repeatMode = "off" { didSet { needPrep() } } // off, all, one
    var shuffleOn = false
    /// bumped by every seek: the lyrics re-sync to it at once
    var seeks = 0
    @ObservationIgnored var more: (() async -> [Item])?
    @ObservationIgnored private var fetchingMore = false
    /// set while a film is playing: the lock screen's play, pause and seek then go to it
    @ObservationIgnored var video: AVPlayer?

    /// a queue player: the next song waits behind the playing one and starts the moment it ends (gapless)
    @ObservationIgnored private let player = AVQueuePlayer()
    /// the AVPlayerItem of the song playing now, and the next song's, already queued behind it
    @ObservationIgnored private var currentAV: AVPlayerItem?
    @ObservationIgnored private var prepared: (id: String, item: AVPlayerItem)?
    @ObservationIgnored private var prepPending = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    @ObservationIgnored private var triedUniversal = false
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterInterruption = false
    /// the person wants sound (set by play / toggle on, cleared by pause / stop): read when a call ends, as the player itself is already paused by then
    @ObservationIgnored private var wantsPlay = false
    /// songs in a row that would not play: after a few the queue stops skipping (no signal would otherwise drain the whole queue)
    @ObservationIgnored private var failedInARow = 0
    /// bumped when the queue is replaced: a fetch started for the old queue then adds nothing to the new one
    @ObservationIgnored private var queueGeneration = 0
    /// the song ended at the end of the queue while more songs were on their way (the value is `auto`)
    @ObservationIgnored private var pendingEnd: Bool?

    var current: Item? { queue.indices.contains(index) ? queue[index] : nil }
    var next: Item? { queue.indices.contains(index + 1) ? queue[index + 1] : nil }

    /// the exact playback time right now (read by the lyrics every frame; it is not observable on purpose)
    var now: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : position
    }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.automaticallyWaitsToMinimizeStalling = false // start as soon as the first piece of the song is in
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            let s = t.seconds
            if s.isFinite { self.position = s }
            self.updateNowPlayingPosition()
            if Date().timeIntervalSince(self.lastReport) > 10 { self.report("Progress"); self.lastReport = Date() }
        }
        rateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = p.timeControlStatus != .paused
                self.updateNowPlayingPosition()
            }
        }
        setupRemote()
        // a phone call, Siri or another app taking the audio, and headphones coming out
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            self?.handleInterruption(n)
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            self?.handleRouteChange(n)
        }
    }

    // MARK: queue

    /// the queue is being replaced: a fetch still running for the old one must not add to the new one
    private func resetQueueState() {
        queueGeneration += 1
        fetchingMore = false
        pendingEnd = nil
    }

    func play(_ songs: [Item], at start: Int = 0, more: (() async -> [Item])? = nil, shuffle: Bool = false) {
        guard !songs.isEmpty else { return }
        report("Stopped")
        resetQueueState()
        self.more = more
        shuffleOn = shuffle
        queue = songs
        index = max(0, min(start, songs.count - 1))
        load()
    }

    /// A shuffled queue that keeps topping itself up with fresh songs as it runs low.
    func shuffle(_ songs: [Item], more: (() async -> [Item])? = nil) {
        play(songs.shuffled(), at: 0, more: more, shuffle: true)
    }

    func toggleShuffle() {
        shuffleOn.toggle()
        if shuffleOn { shuffleUpcoming() }
    }

    /// Shuffle the songs still to come (the one playing and those already played stay where they are).
    func shuffleUpcoming() {
        guard index + 1 < queue.count else { return }
        let head = Array(queue[0...index])
        queue = head + Array(queue[(index + 1)...]).shuffled()
    }

    func cycleRepeat() { repeatMode = repeatMode == "off" ? "all" : (repeatMode == "all" ? "one" : "off") }

    private func topUp() {
        guard let more = self.more, !fetchingMore else { return }
        fetchingMore = true
        let gen = queueGeneration
        Task {
            let got = await more()
            await MainActor.run {
                // the queue was replaced while this fetch ran: its songs belong to the old queue
                guard gen == self.queueGeneration else { return }
                let have = Set(self.queue.map { $0.id })
                let fresh = got.filter { !have.contains($0.id) }
                if !fresh.isEmpty { self.queue.append(contentsOf: fresh) }
                self.fetchingMore = false
                if let auto = self.pendingEnd {
                    self.pendingEnd = nil
                    self.nextSong(auto: auto)
                }
            }
        }
    }

    func moreQueue() { topUp() }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        report("Stopped")
        index = i
        load()
    }

    func enqueueNext(_ s: Item) { playNext(s) }
    func enqueueLast(_ s: Item) { addToQueue([s]) }

    func addToQueue(_ songs: [Item]) {
        if queue.isEmpty { play(songs) } else { queue.append(contentsOf: songs) }
    }

    func playNext(_ song: Item) {
        if queue.isEmpty { play([song]); return }
        queue.insert(song, at: min(index + 1, queue.count))
    }

    func remove(at i: Int) {
        guard queue.indices.contains(i) else { return }
        if i == index {
            // the playing song: the next one takes its place (the end of the queue stops playback)
            report("Stopped")
            queue.remove(at: i)
            if index >= queue.count { stop(); return }
            load()
            return
        }
        queue.remove(at: i)
        if i < index { index -= 1 }
    }

    func clearUpcoming() {
        guard queue.indices.contains(index) else { return }
        queue = [queue[index]]
        index = 0
    }

    func nextSong(auto: Bool = false) {
        // (the finished item has left the queue player: the song is loaded again)
        if auto && repeatMode == "one" { load(); return }
        if index + 1 < queue.count { jump(to: index + 1); return }
        // at the end of an endless queue: wait for the songs on their way (topUp carries on from here)
        if fetchingMore { pendingEnd = auto; return }
        if repeatMode == "all" && !queue.isEmpty { jump(to: 0) }
        else if auto { report("Stopped"); load(); wantsPlay = false; player.pause(); isPlaying = false }
        else { stop() }
    }

    func previous() {
        if now > 3 || index == 0 { seek(to: 0) } else { jump(to: index - 1) }
    }

    func toggle() {
        if player.timeControlStatus == .paused { wantsPlay = true; player.play() } else { wantsPlay = false; player.pause() }
    }

    func play() { wantsPlay = true; player.play() }
    func pause() { wantsPlay = false; player.pause() }

    func seek(to s: Double) {
        player.seek(to: CMTime(seconds: max(0, s), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.seeks += 1 } // once the player is really there
        }
        position = s
        seeks += 1
    }

    func stop() {
        report("Stopped")
        resetQueueState()
        more = nil
        wantsPlay = false
        loading = false
        artworkTask?.cancel(); artworkTask = nil
        player.pause()
        player.removeAllItems()
        currentAV = nil
        prepared = nil
        queue = []
        index = 0
        position = 0
        duration = 0
        showFull = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func toggleFavourite() {
        guard let it = current else { return }
        Favs.toggle(it)
    }

    // MARK: loading

    /// Where a song is played from: its saved copy, else a stream (`original`: the file as it is; otherwise mp3 / aac as they are
    /// and anything else as a 320k mp3, which starts at once)
    private func source(_ it: Item, original: Bool) -> URL? {
        if !original, let c = SongCache.shared.cached(it.id) { return c }
        // an online-only song: the plugin serves it on the plain stream
        if original || it.isVirtual { return Api.keyed("/Audio/\(it.id)/stream", ["static": true, "deviceId": Session.shared.deviceId]) }
        return Api.keyed("/Audio/\(it.id)/universal", [
            "userId": Api.uid, "deviceId": Session.shared.deviceId, "container": "mp3,aac,m4a|aac,m4b|aac,mp4|aac",
            "transcodingContainer": "mp3", "transcodingProtocol": "http", "audioCodec": "mp3", "maxStreamingBitrate": 320000,
        ])
    }

    /// Watches an item that is (or is about to be) the playing one: its end, and whether it plays.
    private func attach(_ avItem: AVPlayerItem, _ it: Item) {
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: avItem, queue: .main) { [weak self] _ in
            // an item that was already replaced (the person jumped to another song) says nothing more
            guard let self, self.currentAV === avItem else { return }
            self.ended()
        }
        statusObserver = avItem.observe(\.status, options: [.initial, .new]) { [weak self] i, _ in
            DispatchQueue.main.async {
                guard let self, self.currentAV === i else { return }
                if i.status == .failed {
                    SongCache.shared.drop(it.id) // a saved copy that will not play is forgotten
                    if !self.triedUniversal { self.load(universal: true); return }
                    self.failedInARow += 1
                    // a few songs in a row that will not play (no signal): stop here, paused, instead of skipping through the whole queue
                    if self.failedInARow >= 3 { self.loading = false; self.wantsPlay = false; self.player.pause(); return }
                    self.nextSong()
                    return
                }
                if i.status != .unknown { self.loading = false }
                if i.status == .readyToPlay {
                    self.failedInARow = 0
                    let d = i.duration.seconds
                    if d.isFinite && d > 0 { self.duration = d }
                }
            }
        }
    }

    private func load(universal: Bool = false) {
        guard let it = current else { return }
        // `universal` here means the second try: the original file as it is
        triedUniversal = universal
        guard let url = source(it, original: universal) else { return }
        SongCache.shared.precache(queue, from: index)
        let avItem = AVPlayerItem(url: url)
        currentAV = avItem
        attach(avItem, it)
        duration = it.seconds
        position = 0
        loading = true
        if more != nil && queue.count - index <= 5 { topUp() }
        prepared = nil
        player.removeAllItems()
        player.insert(avItem, after: nil)
        prepareNext()
        wantsPlay = true
        player.play()
        report("Playing")
        lastReport = Date()
        setNowPlaying(it)
        Task { _ = await LyricsStore.shared.load(it) } // lyrics ready before the screen opens
        if let n = next { Task { _ = await LyricsStore.shared.load(n) } }
    }

    /// The song ended. If the next one was waiting behind it, the queue player is already playing it with no gap: it is taken
    /// on as the current song. Otherwise (repeat one, the end of the queue, a next song that changed) it goes the usual way.
    private func ended() {
        if repeatMode != "one", let p = prepared, let n = next, p.id == n.id, player.currentItem === p.item {
            report("Stopped")
            index += 1
            prepared = nil
            currentAV = p.item
            triedUniversal = false
            attach(p.item, n)
            duration = n.seconds
            position = 0
            SongCache.shared.precache(queue, from: index)
            if more != nil && queue.count - index <= 5 { topUp() }
            report("Playing")
            lastReport = Date()
            setNowPlaying(n)
            if let nn = next { Task { _ = await LyricsStore.shared.load(nn) } }
            prepareNext()
            return
        }
        nextSong(auto: true)
    }

    private func needPrep() {
        if prepPending { return }
        prepPending = true
        DispatchQueue.main.async { [weak self] in self?.prepPending = false; self?.prepareNext() }
    }

    /// Queues the next song behind the playing one (from its saved copy when there is one), so it starts the moment this one ends.
    private func prepareNext() {
        let want = repeatMode == "one" ? nil : next
        if let p = prepared, p.id == want?.id, player.items().contains(p.item) { return }
        if let p = prepared { player.remove(p.item); prepared = nil }
        guard let n = want, let cur = currentAV, player.items().contains(cur), let url = source(n, original: false) else { return }
        let item = AVPlayerItem(url: url)
        guard player.canInsert(item, after: cur) else { return }
        player.insert(item, after: cur)
        prepared = (n.id, item)
    }

    // MARK: server reports

    private func report(_ kind: String) {
        guard let it = current, Session.shared.isSignedIn else { return }
        let path = kind == "Playing" ? "/Sessions/Playing" : kind == "Stopped" ? "/Sessions/Playing/Stopped" : "/Sessions/Playing/Progress"
        // a song that has just started is playing, whatever isPlaying still says from the song before
        let body: [String: Any] = ["ItemId": it.id, "PositionTicks": Int64(max(0, now) * 10_000_000), "IsPaused": kind == "Playing" ? false : !isPlaying, "CanSeek": true]
        Task { _ = try? await Api.request(path, method: "POST", body: body, quiet: true) }
    }

    // MARK: lock screen

    /// Puts the song back on the lock screen (a film that closed cleared it).
    func republishNowPlaying() {
        if let it = current { setNowPlaying(it); updateNowPlayingPosition() }
    }

    private func setNowPlaying(_ it: Item) {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: it.title,
            MPMediaItemPropertyArtist: it.artistLine,
            MPMediaItemPropertyAlbumTitle: it.album ?? "",
            MPMediaItemPropertyPlaybackDuration: it.seconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        refreshLike(it)
        artworkTask?.cancel()
        artworkTask = Task {
            guard let u = Pic.square(it, 600), let img = await ImageStore.shared.load(u), !Task.isCancelled else { return }
            await MainActor.run {
                // only the artwork is added to what the lock screen shows now, and only for the song still playing
                guard self.current?.id == it.id, var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                cur[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
            }
        }
    }

    private func updateNowPlayingPosition() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = now
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.timeControlStatus == .paused ? 0.0 : 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// A lock-screen handler: the model is changed on the main thread (the handler itself may run elsewhere).
    private func remote(_ action: @escaping (PlayerModel, MPRemoteCommandEvent) -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return { [weak self] e in
            DispatchQueue.main.async {
                if let self { action(self, e) }
            }
            return .success
        }
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = true
        c.playCommand.addTarget(handler: remote { m, _ in
            if let v = m.video { v.play() } else { m.play() }
        })
        c.pauseCommand.addTarget(handler: remote { m, _ in
            if let v = m.video { v.pause() } else { m.pause() }
        })
        c.togglePlayPauseCommand.addTarget(handler: remote { m, _ in
            if let v = m.video {
                if v.timeControlStatus == .paused { v.play() } else { v.pause() }
            } else {
                m.toggle()
            }
        })
        // while a film plays these do nothing: they must not start a song over it
        c.nextTrackCommand.addTarget(handler: remote { m, _ in if m.video == nil { m.nextSong() } })
        c.previousTrackCommand.addTarget(handler: remote { m, _ in if m.video == nil { m.previous() } })
        // the favourite (heart) among the lock screen's controls
        c.likeCommand.isEnabled = true
        c.likeCommand.localizedTitle = "Add to favourites"
        c.likeCommand.localizedShortTitle = "Favourite"
        c.likeCommand.addTarget(handler: remote { m, _ in
            guard let it = m.current else { return }
            Favs.toggle(it)
            m.refreshLike(it)
        })
        c.changePlaybackPositionCommand.addTarget(handler: remote { m, e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return }
            if let v = m.video { v.seek(to: CMTime(seconds: e.positionTime, preferredTimescale: 600)) } else { m.seek(to: e.positionTime) }
        })
    }

    /// The lock screen's heart shows whether the playing song is a favourite.
    func refreshLike(_ it: Item) {
        let on = Favs.isFav(it)
        let c = MPRemoteCommandCenter.shared().likeCommand
        c.isActive = on
        c.localizedTitle = on ? "Remove from favourites" : "Add to favourites"
    }

    /// A call or another app takes the audio: pause, and resume only if the system says the audio may come back.
    private func handleInterruption(_ n: Notification) {
        let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
        guard let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            resumeAfterInterruption = wantsPlay
            player.pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            try? AVAudioSession.sharedInstance().setActive(true)
            if resumeAfterInterruption && options.contains(.shouldResume) { player.play() }
            resumeAfterInterruption = false
        default:
            break
        }
    }

    /// Headphones or a speaker unplugged: the sound must not carry on out of the phone's speaker.
    private func handleRouteChange(_ n: Notification) {
        let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        guard AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        resumeAfterInterruption = false
        player.pause()
        video?.pause()
    }
}

/// What the person has just (un)favourited, by item id (lists show items fetched earlier, so their own flag goes stale).
@Observable
final class Favs {
    static let shared = Favs()
    var map: [String: Bool] = [:]

    static func isFav(_ it: Item) -> Bool { shared.map[it.id] ?? it.isFavourite }
    static func set(_ id: String, _ on: Bool) { shared.map[id] = on }
    static func toggle(_ it: Item) {
        let was = isFav(it)
        set(it.id, !was)
        let pm = PlayerModel.shared
        if pm.current?.id == it.id { pm.refreshLike(it) }
        Task {
            await Api.setFavourite(it.id, !was)
        }
    }
}
