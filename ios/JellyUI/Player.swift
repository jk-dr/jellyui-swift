import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI

/// The music player: a queue played by AVPlayer, with lock-screen controls.
@Observable
final class PlayerModel {
    static let shared = PlayerModel()

    var queue: [Item] = []
    var index = 0
    var isPlaying = false
    var position: Double = 0 // updated about twice a second, for bars and labels
    var duration: Double = 0
    var showFull = false
    var loading = false
    var repeatMode = "off" // off, all, one
    var shuffleOn = false
    @ObservationIgnored var more: (() async -> [Item])?
    @ObservationIgnored private var fetchingMore = false
    /// set while a film is playing: the lock screen's play, pause and seek then go to it
    @ObservationIgnored var video: AVPlayer?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    @ObservationIgnored private var triedUniversal = false
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

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
    }

    // MARK: queue

    func play(_ songs: [Item], at start: Int = 0, more: (() async -> [Item])? = nil, shuffle: Bool = false) {
        guard !songs.isEmpty else { return }
        report("Stopped")
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
        guard let more, !fetchingMore else { return }
        fetchingMore = true
        Task {
            let got = await more()
            await MainActor.run {
                let have = Set(queue.map { $0.id })
                let fresh = got.filter { !have.contains($0.id) }
                if !fresh.isEmpty { queue.append(contentsOf: fresh) }
                fetchingMore = false
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
        guard queue.indices.contains(i), i != index else { return }
        queue.remove(at: i)
        if i < index { index -= 1 }
    }

    func clearUpcoming() {
        guard !queue.isEmpty else { return }
        queue = [queue[index]]
        index = 0
    }

    func nextSong(auto: Bool = false) {
        if auto && repeatMode == "one" { seek(to: 0); player.play(); return }
        if index + 1 < queue.count { jump(to: index + 1) }
        else if repeatMode == "all" && !queue.isEmpty { jump(to: 0) }
        else if auto { player.pause(); isPlaying = false; seek(to: 0) }
        else { stop() }
    }

    func previous() {
        if now > 3 || index == 0 { seek(to: 0) } else { jump(to: index - 1) }
    }

    func toggle() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to s: Double) {
        player.seek(to: CMTime(seconds: max(0, s), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = s
    }

    func stop() {
        report("Stopped")
        player.pause()
        player.replaceCurrentItem(with: nil)
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

    private func load(universal: Bool = false) {
        guard let it = current else { return }
        triedUniversal = universal
        let url: URL?
        if universal {
            url = Api.keyed("/Audio/\(it.id)/universal", [
                "userId": Api.uid, "deviceId": Session.shared.deviceId, "container": "mp3,aac,m4a,flac,wav",
                "transcodingContainer": "mp3", "transcodingProtocol": "http", "audioCodec": "mp3", "maxStreamingBitrate": 320000,
            ])
        } else {
            url = Api.keyed("/Audio/\(it.id)/stream", ["static": true, "deviceId": Session.shared.deviceId])
        }
        guard let url = (universal ? nil : SongCache.shared.cached(it.id)) ?? url else { return }
        SongCache.shared.precache(queue, from: index)
        let avItem = AVPlayerItem(url: url)
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: avItem, queue: .main) { [weak self] _ in
            self?.nextSong(auto: true)
        }
        statusObserver = avItem.observe(\.status, options: [.new]) { [weak self] i, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if i.status == .failed {
                    SongCache.shared.drop(it.id) // a saved copy that will not play is forgotten
                    if !self.triedUniversal { self.load(universal: true) } else { self.nextSong() }
                }
                if i.status != .unknown { self.loading = false }
                if i.status == .readyToPlay {
                    let d = i.duration.seconds
                    if d.isFinite && d > 0 { self.duration = d }
                }
            }
        }
        duration = it.seconds
        position = 0
        loading = true
        if more != nil && queue.count - index <= 5 { topUp() }
        player.replaceCurrentItem(with: avItem)
        player.play()
        report("Playing")
        lastReport = Date()
        setNowPlaying(it)
        Task { _ = await LyricsStore.shared.load(it) } // lyrics ready before the screen opens
        if let n = next { Task { _ = await LyricsStore.shared.load(n) } }
    }

    // MARK: server reports

    private func report(_ kind: String) {
        guard let it = current, Session.shared.isSignedIn else { return }
        let path = kind == "Playing" ? "/Sessions/Playing" : kind == "Stopped" ? "/Sessions/Playing/Stopped" : "/Sessions/Playing/Progress"
        let body: [String: Any] = ["ItemId": it.id, "PositionTicks": Int64(max(0, now) * 10_000_000), "IsPaused": !isPlaying, "CanSeek": true]
        Task { _ = try? await Api.request(path, method: "POST", body: body, quiet: true) }
    }

    // MARK: lock screen

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
        artworkTask?.cancel()
        artworkTask = Task {
            guard let u = Pic.square(it, 600), let img = await ImageStore.shared.load(u), !Task.isCancelled else { return }
            var out = info
            out[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            await MainActor.run { MPNowPlayingInfoCenter.default().nowPlayingInfo = out }
        }
    }

    private func updateNowPlayingPosition() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = now
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.timeControlStatus == .paused ? 0.0 : 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in if let v = self?.video { v.play() } else { self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in if let v = self?.video { v.pause() } else { self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            if let v = self?.video { if v.timeControlStatus == .paused { v.play() } else { v.pause() } } else { self?.toggle() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.nextSong(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent {
                if let v = self?.video { v.seek(to: CMTime(seconds: e.positionTime, preferredTimescale: 600)) } else { self?.seek(to: e.positionTime) }
            }
            return .success
        }
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
        Task {
            await Api.setFavourite(it.id, !was)
        }
    }
}
