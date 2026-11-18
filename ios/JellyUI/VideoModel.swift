import Foundation
import SwiftUI

// MARK: - Streams and sources

struct MStream: Hashable, Identifiable {
    var id: Int { index }
    var index: Int
    var type: String
    var language: String?
    var displayTitle: String?
    var isForced: Bool
    var isDefault: Bool
    var isText: Bool?
    var deliveryUrl: String?
}

struct MSource {
    var id: String
    var path: String?
    var etag: String?
    var liveStreamId: String?
    var directPlay: Bool
    var directStream: Bool
    var transcodingUrl: String?
    var streams: [MStream]
    var defaultAudio: Int?
    var defaultSub: Int?

    init?(_ d: [String: Any]) {
        guard let id = d["Id"] as? String else { return nil }
        self.id = id
        path = d["Path"] as? String
        etag = d["ETag"] as? String
        liveStreamId = d["LiveStreamId"] as? String
        directPlay = d["SupportsDirectPlay"] as? Bool ?? false
        directStream = d["SupportsDirectStream"] as? Bool ?? false
        transcodingUrl = d["TranscodingUrl"] as? String
        defaultAudio = d["DefaultAudioStreamIndex"] as? Int
        defaultSub = d["DefaultSubtitleStreamIndex"] as? Int
        streams = (d["MediaStreams"] as? [[String: Any]] ?? []).map { s in
            MStream(index: s["Index"] as? Int ?? 0, type: s["Type"] as? String ?? "", language: s["Language"] as? String,
                    displayTitle: s["DisplayTitle"] as? String, isForced: s["IsForced"] as? Bool ?? false, isDefault: s["IsDefault"] as? Bool ?? false,
                    isText: s["IsTextSubtitleStream"] as? Bool, deliveryUrl: s["DeliveryUrl"] as? String)
        }
    }
    var subs: [MStream] { streams.filter { $0.type == "Subtitle" } }
    var audio: [MStream] { streams.filter { $0.type == "Audio" } }
}

struct VSource: Equatable {
    var url: URL
    var transcode: Bool
    var key: Int
}

struct GateInfo {
    var status = ""
    var progress: Double?
    var quality: String?
    var open = false
    var headerTail = false
    var fraction = false
    var speed = false
    var gateProgress: Double = 0
    var hasGate = false
}

let STATUS_TEXT: [String: String] = [
    "Requested": "Finding a release…", "Grabbing": "Sending it to the downloader…", "Preparing": "Starting the download…",
    "Streaming": "Downloading…", "Downloading": "Downloading…", "InLibrary": "Download complete", "Failed": "The download failed", "Cancelled": "The download was cancelled",
]
private let STATUS_NAMES = ["Requested", "Grabbing", "Preparing", "Streaming", "Downloading", "InLibrary", "Failed", "Cancelled"]

/// What the person's subtitle settings would choose for this file (Jellyfin's own rules). Returns a stream index, or -1.
func pickDefaultSub(_ subs: [MStream], _ audio: [MStream], defAudio: Int?, defSub: Int?) -> Int {
    let st = Settings.shared
    if subs.isEmpty || st.subMode == "none" { return -1 }
    let aud = audio.first { $0.index == defAudio } ?? audio.first
    let audLang = (aud?.language ?? "").lowercased()
    let lang = st.subLang.lowercased()
    func inLang(_ x: MStream) -> Bool { lang.isEmpty || (x.language ?? "").lowercased() == lang }
    switch st.subMode {
    case "default": return (defSub ?? -1) > -1 ? defSub! : (subs.first { $0.isForced && inLang($0) }?.index ?? -1)
    case "smart": return (!lang.isEmpty && !audLang.isEmpty && audLang != lang) ? (subs.first { inLang($0) && !$0.isForced }?.index ?? -1) : -1
    case "forced": return (subs.first { $0.isForced && inLang($0) } ?? subs.first { $0.isForced })?.index ?? -1
    case "always": return (subs.first { inLang($0) && !$0.isForced } ?? subs.first { !$0.isForced } ?? subs[0]).index
    default: return -1
    }
}

func defaultBurnIndex(_ ms: MSource) -> Int {
    let idx = pickDefaultSub(ms.subs, ms.audio, defAudio: ms.defaultAudio, defSub: ms.defaultSub)
    if let s = ms.subs.first(where: { $0.index == idx }), s.isText == false { return idx }
    return -1
}

// MARK: - The playback session (what the web's playback.ts did)

@Observable
final class VideoModel {
    enum Phase { case loading, gate, ready, error }

    var phase: Phase = .loading
    var message = "Loading…"
    var error = ""
    var title = ""
    var epLabel = ""
    var poster: URL?
    var isLive = false
    var isEpisode = false
    var tmdb = ""
    var itemId = ""
    var startSec: Double = 0
    var duration: Double = 0
    var source: VSource?
    var ms: MSource?
    var playSession = ""
    var prevId: String?
    var nextId: String?
    var favourite = false
    var gate: GateInfo?
    var elapsed: Double = 0
    var busy = false
    var downloaded: Double = 0
    var subIndex = -1
    var audioIndex = -1
    var maxBitrate = Settings.shared.maxBitrate

    @ObservationIgnored private var gone = false
    @ObservationIgnored private var skipGate = false
    @ObservationIgnored private var keyN = 0
    @ObservationIgnored private var busyAskedAt = Date.distantPast
    @ObservationIgnored var request: PlayRequest
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(_ r: PlayRequest) { request = r }

    func dispose() { gone = true; tasks.forEach { $0.cancel() } }
    func playAnyway() { skipGate = true }

    /// Opens another episode in the same player (next / previous / auto-play).
    func switchTo(_ id: String) async {
        tasks.forEach { $0.cancel() }
        tasks = []
        request = PlayRequest(itemId: id)
        source = nil; ms = nil; subIndex = -1; audioIndex = -1; downloaded = 0
        prevId = nil; nextId = nil; gate = nil; error = ""
        phase = .loading; message = "Opening the stream…"
        do { try await startItem(id) }
        catch { phase = .error; self.error = (error as? ApiError)?.message ?? error.localizedDescription }
    }

    func start() async {
        let t0 = Date()
        let tick = Task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000); elapsed = Date().timeIntervalSince(t0) } }
        defer { tick.cancel() }
        do {
            if let id = request.itemId { try await startItem(id) }
            else if let t = request.tmdb { try await startTmdb(t) }
            else { throw ApiError(status: 0, message: "Nothing to play") }
        } catch {
            phase = .error
            self.error = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    // MARK: an item in the library

    private func startItem(_ id: String) async throws {
        var it = try await Api.item(id)
        if it.type == "TvChannel", let ch: Item = try? await Api.get("/LiveTv/Channels/\(it.id)", ["userId": Api.uid]) { it.currentProgram = ch.currentProgram }
        fromItem(it)
        let tm = (isEpisode || isLive) ? "" : (it.providerIds?["tmdb"] ?? "")
        tmdb = tm
        if !tm.isEmpty, let r = await Plugin.onDemandStatus(tm) {
            let low = lower(r)
            let st = stName(low["status"])
            let g = low["gate"] as? [String: Any]
            if let g, (g["open"] as? Bool) != true, st != "InLibrary" {
                phase = .gate
                gate = gateInfo(st, low)
                try await waitForGate(tm)
            }
        }
        if gone { return }
        phase = .loading; message = "Opening the stream…"
        try await open(it.id, at: startSec, auto: !isLive)
        if !tm.isEmpty { pollDownloaded(tm) }
    }

    private func fromItem(_ it: Item) {
        let pos = it.userData?.playbackPositionTicks ?? 0
        poster = Pic.poster(it, h: 700)
        if it.type == "TvChannel" {
            let cp = it.currentProgram
            let st = cp?.startDate.flatMap(ISO8601DateFormatter.flexible)
            let en = cp?.endDate.flatMap(ISO8601DateFormatter.flexible)
            itemId = it.id; title = it.title
            epLabel = "Live" + ((cp?.name).map { " - " + $0 } ?? "")
            isLive = true; isEpisode = false
            duration = (st != nil && en != nil) ? en!.timeIntervalSince(st!) : 0
            startSec = 0; favourite = it.isFavourite
            return
        }
        let ep = it.type == "Episode"
        let total = it.runTimeTicks ?? 0
        startSec = request.itemId == nil || pos == 0 || (total > 0 && Double(pos) / Double(total) > 0.95) ? 0 : Double(pos) / 1e7
        itemId = it.id; isLive = false; isEpisode = ep
        duration = Double(total) / 1e7
        title = ep ? (it.seriesName ?? it.title) : it.title
        epLabel = ep ? "Season \(it.parentIndexNumber.map(String.init) ?? "?") · Episode \(it.indexNumber.map(String.init) ?? "?") - \(it.title)" : ""
        favourite = it.isFavourite
        if ep, let sid = it.seriesId {
            tasks.append(Task {
                if let r: ItemsResult = try? await Api.get("/Shows/\(sid)/Episodes", ["userId": Api.uid]) {
                    let list = r.items
                    if let i = list.firstIndex(where: { $0.id == it.id }) {
                        prevId = i > 0 ? list[i - 1].id : nil
                        nextId = i < list.count - 1 ? list[i + 1].id : nil
                    }
                }
            })
        }
    }

    // MARK: an on-demand film that is not in the library yet

    private func startTmdb(_ t: String) async throws {
        let td = try await Plugin.title("movie", t)
        if let jf = td.jellyfinId { try await startItem(jf); return }
        guard td.canPlayNow == true else { throw ApiError(status: 0, message: "Your account can request this movie but not play it on demand") }
        title = td.title ?? ""
        duration = (Double(td.runtime ?? "") ?? 0) * 60
        tmdb = t
        poster = Pic.tmdb(td.poster, "w500")
        phase = .gate
        gate = GateInfo(status: "Requested")
        // the plugin only recognises a not-yet-in-library film's id after it has appeared in a search: search first
        _ = try? await Api.items(["searchTerm": td.title, "IncludeItemTypes": "Movie", "Recursive": true, "Limit": 20])
        try await Plugin.onDemandPlay(t)
        pollDownloaded(t)
        try await waitForGate(t)
        if gone { return }
        phase = .loading; message = "Opening the stream…"
        var real = td.virtualId ?? ""
        do {
            if real.isEmpty { throw ApiError(status: 404, message: "x") }
            try await open(real, at: 0, auto: true)
        } catch let e as ApiError where e.status == 404 {
            real = try await viaLibrary(t)
            try await open(real, at: 0, auto: true)
        }
    }

    private func viaLibrary(_ t: String) async throws -> String {
        var tries = 0
        while tries <= 40 && !gone {
            let td = try await Plugin.title("movie", t)
            if let j = td.jellyfinId { return j }
            message = "Waiting for the library to pick it up…"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            tries += 1
        }
        throw ApiError(status: 0, message: "The movie is not in the library yet. Try again in a moment.")
    }

    // MARK: the first-chunk gate

    private func lower(_ o: [String: Any]) -> [String: Any] {
        var r: [String: Any] = [:]
        for (k, v) in o { r[k.prefix(1).lowercased() + k.dropFirst()] = (v as? [String: Any]).map(lower) ?? v }
        return r
    }
    private func stName(_ v: Any?) -> String {
        if let n = v as? Int, STATUS_NAMES.indices.contains(n) { return STATUS_NAMES[n] }
        return v as? String ?? ""
    }
    private func gateInfo(_ st: String, _ r: [String: Any]) -> GateInfo {
        var g = GateInfo(status: st)
        g.progress = r["progress"] as? Double
        g.quality = r["quality"] as? String
        if let gt = r["gate"] as? [String: Any] {
            g.hasGate = true
            g.open = gt["open"] as? Bool ?? false
            g.headerTail = gt["headerTail"] as? Bool ?? false
            g.fraction = gt["fraction"] as? Bool ?? false
            g.speed = gt["speed"] as? Bool ?? false
            g.gateProgress = gt["progress"] as? Double ?? 0
        }
        return g
    }

    private func waitForGate(_ t: String) async throws {
        var misses = 0
        while !gone {
            if let raw = await Plugin.onDemandStatus(t) {
                misses = 0
                let r = lower(raw)
                let st = stName(r["status"])
                if st == "Failed" || st == "Cancelled" {
                    gate = GateInfo(status: st)
                    throw ApiError(status: 0, message: STATUS_TEXT[st] ?? st)
                }
                let g = gateInfo(st, r)
                gate = g
                checkBusy(t)
                if g.open || st == "InLibrary" || skipGate { return }
            } else {
                misses += 1
                if misses >= 800 { throw ApiError(status: 404, message: "Not found") }
                gate = GateInfo(status: "Requested")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private func checkBusy(_ t: String) {
        guard Date().timeIntervalSince(busyAskedAt) > 9 else { return }
        busyAskedAt = Date()
        Task {
            if let d = try? await Api.request("/JellyUI/Busy/\(t)", quiet: true), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                busy = (o["others"] as? Int ?? 0) > 0
            }
        }
    }

    private func pollDownloaded(_ t: String) {
        tasks.append(Task {
            while !Task.isCancelled && !gone {
                guard let raw = await Plugin.onDemandStatus(t) else { return }
                let r = lower(raw)
                if let p = r["progress"] as? Double { downloaded = max(0, min(100, p * 100)) }
                if stName(r["status"]) == "InLibrary" { downloaded = 100; return }
                if downloaded >= 99.95 { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        })
    }

    // MARK: opening a stream

    private func iosProfile(_ maxBitrate: Int, burn: Bool) -> [String: Any] {
        [
            "Name": "JellyUI iOS", "MaxStreamingBitrate": maxBitrate, "MaxStaticBitrate": maxBitrate,
            "DirectPlayProfiles": [["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,mp3,ac3,eac3,alac,flac"]],
            "TranscodingProfiles": [["Container": "mp4", "Type": "Video", "AudioCodec": "aac,mp3,ac3,eac3", "VideoCodec": "h264,hevc", "Context": "Streaming", "Protocol": "hls", "MaxAudioChannels": "6", "MinSegments": 2, "BreakOnNonKeyFrames": true]],
            "ContainerProfiles": [],
            "CodecProfiles": [
                ["Type": "Video", "Codec": "h264", "Conditions": [
                    ["Condition": "EqualsAny", "Property": "VideoProfile", "Value": "high|main|baseline|constrained baseline", "IsRequired": false],
                    ["Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "52", "IsRequired": false],
                    ["Condition": "Equals", "Property": "IsInterlaced", "Value": "false", "IsRequired": false]]],
                ["Type": "Video", "Codec": "hevc", "Conditions": [
                    ["Condition": "EqualsAny", "Property": "VideoProfile", "Value": "main|main 10", "IsRequired": false],
                    ["Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "183", "IsRequired": false],
                    ["Condition": "Equals", "Property": "IsInterlaced", "Value": "false", "IsRequired": false]]],
            ],
            "SubtitleProfiles": [["Format": "vtt", "Method": "External"], ["Format": "srt", "Method": "External"]]
                + (burn ? ["pgssub", "dvdsub", "dvbsub", "sub", "ass", "ssa"].map { ["Format": $0, "Method": "Encode"] } : []),
        ]
    }

    private func playbackInfo(_ id: String, sub: Int, audio: Int, bitrate: Int) async throws -> [String: Any] {
        var n = 20
        while true {
            do {
                let q: [String: Any?] = ["userId": Api.uid, "startTimeTicks": nil, "maxStreamingBitrate": bitrate, "autoOpenLiveStream": true,
                                         "subtitleStreamIndex": sub > -1 ? sub : nil, "audioStreamIndex": audio > -1 ? audio : nil]
                let d = try await Api.request("/Items/\(id)/PlaybackInfo", query: q, method: "POST", body: ["DeviceProfile": iosProfile(bitrate, burn: sub > -1)])
                return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            } catch let e as ApiError where e.status == 503 && n > 0 && !gone {
                message = "Opening the stream…"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                n -= 1
            }
        }
    }

    /// Asks the server how to play `id` and publishes the stream.
    func open(_ id: String, at start: Double, sub: Int? = nil, audio: Int? = nil, bitrate: Int? = nil, auto: Bool = false) async throws {
        let o = (sub: sub ?? subIndex, audio: audio ?? audioIndex, bitrate: bitrate ?? maxBitrate)
        let pi = try await playbackInfo(id, sub: o.sub, audio: o.audio, bitrate: o.bitrate)
        if gone { return }
        guard let first = (pi["MediaSources"] as? [[String: Any]])?.first, let ms = MSource(first) else { throw ApiError(status: 0, message: "No playable file found") }
        guard let src = sourceFor(ms, pi, id, o.bitrate) else { throw ApiError(status: 0, message: "This file can’t be played on this device") }
        // a picture subtitle chosen by default is burnt in from the first request
        if auto, o.sub == -1 {
            let b = defaultBurnIndex(ms)
            if b > -1 { try await open(id, at: start, sub: b); return }
        }
        phase = .ready
        self.ms = ms; itemId = id; playSession = pi["PlaySessionId"] as? String ?? ""
        startSec = start
        keyN += 1
        source = VSource(url: src.0, transcode: src.1, key: keyN)
        subIndex = o.sub; audioIndex = o.audio; maxBitrate = o.bitrate
    }

    private func sourceFor(_ ms: MSource, _ pi: [String: Any], _ id: String, _ bitrate: Int) -> (URL, Bool)? {
        // an on-demand file is still downloading: play it from the gated stream directly when AVPlayer can open it
        if let p = ms.path, let r = p.range(of: "/OnDemand/Stream/(\\d+)", options: .regularExpression), bitrate >= 120_000_000,
           p.range(of: "\\.(mp4|m4v|mov)(\\?|$)", options: [.regularExpression, .caseInsensitive]) != nil {
            let num = String(p[r]).replacingOccurrences(of: "/OnDemand/Stream/", with: "")
            if let u = Api.keyed("/OnDemand/Stream/\(num)") { return (u, false) }
        }
        if let t = ms.transcodingUrl, let u = Api.keyed(t) { return (u, true) }
        if ms.directPlay || ms.directStream,
           let u = Api.keyed("/Videos/\(id)/stream", ["static": true, "mediaSourceId": ms.id, "deviceId": Session.shared.deviceId, "Tag": ms.etag,
                                                      "PlaySessionId": pi["PlaySessionId"] as? String, "LiveStreamId": ms.liveStreamId]) { return (u, false) }
        return nil
    }

    func reportBody(position: Double, paused: Bool) -> [String: Any] {
        var b: [String: Any] = ["ItemId": itemId, "PositionTicks": Int64(max(0, position) * 1e7), "CanSeek": !isLive, "IsPaused": paused,
                                "PlaySessionId": playSession, "PlayMethod": (source?.transcode ?? false) ? "Transcode" : "DirectPlay"]
        if let m = ms { b["MediaSourceId"] = m.id; if let l = m.liveStreamId { b["LiveStreamId"] = l } }
        return b
    }

    func report(_ kind: String, position: Double, paused: Bool) {
        let path = kind == "Playing" ? "/Sessions/Playing" : kind == "Stopped" ? "/Sessions/Playing/Stopped" : "/Sessions/Playing/Progress"
        let body = reportBody(position: position, paused: paused)
        Task { _ = try? await Api.request(path, method: "POST", body: body, quiet: true) }
    }
}

// MARK: - Subtitles (WebVTT)

struct Cue { var start: Double; var end: Double; var text: String }

enum VTT {
    static func time(_ s: String) -> Double? {
        let p = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard p.count >= 2, p.count <= 3 else { return nil }
        let nums = p.compactMap { Double($0) }
        guard nums.count == p.count else { return nil }
        return p.count == 3 ? nums[0] * 3600 + nums[1] * 60 + nums[2] : nums[0] * 60 + nums[1]
    }

    static func clean(_ t: String) -> String {
        var s = t
        s = s.replacingOccurrences(of: "<(?:\\d{1,2}:)?\\d{1,2}:\\d{2}[.,]\\d{3}>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "</?[a-zA-Z][^>]*>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\{\\\\an?\\d\\}", with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&lrm;": "", "&rlm;": ""] { s = s.replacingOccurrences(of: k, with: v) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ src: String) -> [Cue] {
        let text = src.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[i].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let b = time(String(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")), b > a else { continue }
            let body = clean(lines[(i + 1)...].joined(separator: "\n"))
            if !body.isEmpty { cues.append(Cue(start: a, end: b, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func at(_ cues: [Cue], _ t: Double) -> [Cue] {
        var lo = 0, hi = cues.count - 1, idx = -1
        while lo <= hi { let mid = (lo + hi) / 2; if cues[mid].start <= t { idx = mid; lo = mid + 1 } else { hi = mid - 1 } }
        var out: [Cue] = []
        var i = idx
        while i >= 0 && i > idx - 6 { if cues[i].end > t { out.insert(cues[i], at: 0) }; i -= 1 }
        return out
    }
}

struct Segment: Hashable { var type: String; var start: Double; var end: Double }

extension Api {
    static func segments(_ id: String) async -> [Segment] {
        guard let d = try? await request("/MediaSegments/\(id)?includeSegmentTypes=Intro&includeSegmentTypes=Outro&includeSegmentTypes=Recap&includeSegmentTypes=Preview&includeSegmentTypes=Commercial", quiet: true),
              let j = try? JSONSerialization.jsonObject(with: d) else { return [] }
        let list = ((j as? [String: Any])?["Items"] as? [[String: Any]]) ?? ((j as? [String: Any])?["items"] as? [[String: Any]]) ?? (j as? [[String: Any]]) ?? []
        let names = ["Unknown", "Outro", "Intro", "Recap", "Preview", "Commercial"]
        return list.compactMap { x in
            let t = x["Type"] ?? x["type"]
            let type = (t as? Int).map { names.indices.contains($0) ? names[$0] : "Unknown" } ?? (t as? String) ?? "Unknown"
            guard let s = (x["StartTicks"] ?? x["startTicks"]) as? Double, let e = (x["EndTicks"] ?? x["endTicks"]) as? Double else { return nil }
            let seg = Segment(type: type, start: s / 1e7, end: e / 1e7)
            return seg.end - seg.start > 3 ? seg : nil
        }
    }
}
