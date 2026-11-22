import Foundation
import SwiftUI

// MARK: - A value the server may send as a number or as text

struct Flex: Codable, Hashable {
    var s: String
    init(_ s: String) { self.s = s }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { s = v }
        else if let v = try? c.decode(Int.self) { s = String(v) }
        else if let v = try? c.decode(Double.self), v.isFinite, abs(v) < 9.0e15 { s = String(Int(v)) } // Int(v) traps on huge values
        else { s = "" }
    }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(s) }
}

// MARK: - Settings (the app's Settings store, on this device)

@Observable
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var homeContinue: Bool { didSet { d.set(homeContinue, forKey: "s.homeContinue") } }
    var homeLibraries: Bool { didSet { d.set(homeLibraries, forKey: "s.homeLibraries") } }
    var homeGenres: Bool { didSet { d.set(homeGenres, forKey: "s.homeGenres") } }
    var homeTrending: Bool { didSet { d.set(homeTrending, forKey: "s.homeTrending") } }
    var backdrops: Bool { didSet { d.set(backdrops, forKey: "s.backdrops") } }
    var autoNext: Bool { didSet { d.set(autoNext, forKey: "s.autoNext") } }
    var maxBitrate: Int { didSet { d.set(maxBitrate, forKey: "s.maxBitrate") } }
    var skipBack: Int { didSet { d.set(skipBack, forKey: "s.skipBack") } }
    var skipFwd: Int { didSet { d.set(skipFwd, forKey: "s.skipFwd") } }
    var segIntro: String { didSet { d.set(segIntro, forKey: "s.segIntro") } }
    var segOutro: String { didSet { d.set(segOutro, forKey: "s.segOutro") } }
    var segRecap: String { didSet { d.set(segRecap, forKey: "s.segRecap") } }
    var segPreview: String { didSet { d.set(segPreview, forKey: "s.segPreview") } }
    var subMode: String { didSet { d.set(subMode, forKey: "s.subMode") } }
    var subLang: String { didSet { d.set(subLang, forKey: "s.subLang") } }
    var subSize: Int { didSet { d.set(subSize, forKey: "s.subSize") } }
    var subBold: Bool { didSet { d.set(subBold, forKey: "s.subBold") } }
    var subBackground: Bool { didSet { d.set(subBackground, forKey: "s.subBackground") } }
    var subOffset: Double { didSet { d.set(subOffset, forKey: "s.subOffset") } }
    var lyricsHidden: Bool { didSet { d.set(lyricsHidden, forKey: "s.lyricsHidden") } }
    var songCache: Bool { didSet { d.set(songCache, forKey: "s.songCache") } }
    var songCacheMb: Int { didSet { d.set(songCacheMb, forKey: "s.songCacheMb") } }
    var songCacheWifi: Bool { didSet { d.set(songCacheWifi, forKey: "s.songCacheWifi") } }
    var songAhead: Int { didSet { d.set(songAhead, forKey: "s.songAhead") } }
    var slideDelay: Int { didSet { d.set(slideDelay, forKey: "s.slideDelay") } }

    private static func b(_ k: String, _ v: Bool) -> Bool { UserDefaults.standard.object(forKey: "s." + k) as? Bool ?? v }
    private static func i(_ k: String, _ v: Int) -> Int { UserDefaults.standard.object(forKey: "s." + k) as? Int ?? v }
    private static func t(_ k: String, _ v: String) -> String { UserDefaults.standard.string(forKey: "s." + k) ?? v }

    init() {
        homeContinue = Self.b("homeContinue", true)
        homeLibraries = Self.b("homeLibraries", true)
        homeGenres = Self.b("homeGenres", true)
        homeTrending = Self.b("homeTrending", true)
        backdrops = Self.b("backdrops", true)
        autoNext = Self.b("autoNext", true)
        maxBitrate = Self.i("maxBitrate", 120_000_000)
        skipBack = Self.i("skipBack", 10)
        skipFwd = Self.i("skipFwd", 30)
        segIntro = Self.t("segIntro", "ask")
        segOutro = Self.t("segOutro", "ask")
        segRecap = Self.t("segRecap", "none")
        segPreview = Self.t("segPreview", "none")
        subMode = Self.t("subMode", "default")
        subLang = Self.t("subLang", "")
        subSize = Self.i("subSize", 20)
        subBold = Self.b("subBold", false)
        subBackground = Self.b("subBackground", false)
        subOffset = UserDefaults.standard.object(forKey: "s.subOffset") as? Double ?? 0
        lyricsHidden = Self.b("lyricsHidden", false)
        songCache = Self.b("songCache", true)
        songCacheMb = Self.i("songCacheMb", 1024)
        songCacheWifi = Self.b("songCacheWifi", true)
        songAhead = Self.i("songAhead", 2)
        slideDelay = Self.i("slideDelay", 5)
    }
}

// MARK: - Plugin data

struct SeerrTile: Decodable, Hashable, Identifiable {
    var t: String
    var rawId: String
    var id: String { t + rawId }
    var title: String
    var year: String?
    var poster: String?
    var backdrop: String?

    enum K: String, CodingKey { case t, id, title, year, poster, backdrop }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        t = (try? c.decode(String.self, forKey: .t)) ?? "m"
        rawId = (try? c.decode(Flex.self, forKey: .id).s) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        year = try? c.decode(Flex.self, forKey: .year).s
        poster = try? c.decode(String.self, forKey: .poster)
        backdrop = try? c.decode(String.self, forKey: .backdrop)
    }

    var card: Card {
        let movie = t == "m"
        return Card(id: id, title: title, sub: (movie ? "Movie" : "Show") + ((year ?? "").isEmpty ? "" : " · \(year!)"),
                    img: Pic.tmdb(poster, "w342"), t: movie ? "m" : "s", route: movie ? .movie("tmdb-" + rawId) : .show("tmdb-" + rawId))
    }
}

struct HomeService: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var logo: String?
    var kind: String
    enum K: String, CodingKey { case id, name, logo, kind }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decode(Flex.self, forKey: .id).s) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        logo = try? c.decode(String.self, forKey: .logo)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "network"
    }
}

struct HomeGenre: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var count: Int
    enum K: String, CodingKey { case id, name, count }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decode(Flex.self, forKey: .id).s) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }
}

struct HomeSection: Decodable, Hashable {
    var title: String
    var items: [SeerrTile]
}

struct HomeData: Decodable {
    var ready: Bool?
    var seerr: Bool?
    var services: [HomeService]?
    var genres: [HomeGenre]?
    var sections: [HomeSection]?
}

struct PendingRequest: Decodable, Hashable, Identifiable {
    var id: Int
    var type: String
    var title: String
    var year: String?
    var poster: String?
    var seasons: [Int]?
    var is4k: Bool?
    var requestedBy: String?
    enum K: String, CodingKey { case id, type, title, year, poster, seasons, is4k, requestedBy }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        type = (try? c.decode(String.self, forKey: .type)) ?? "movie"
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        year = try? c.decode(Flex.self, forKey: .year).s
        poster = try? c.decode(String.self, forKey: .poster)
        seasons = try? c.decode([Int].self, forKey: .seasons)
        is4k = try? c.decode(Bool.self, forKey: .is4k)
        requestedBy = try? c.decode(String.self, forKey: .requestedBy)
    }
}

struct RequestsData: Decodable {
    var can: Bool?
    var items: [PendingRequest]?
}

struct Collection: Decodable {
    var name: String?
    var logo: String?
    var kind: String?
    var items: [SeerrTile]?
    var pages: Int?
}

struct MoreData: Decodable {
    var items: [SeerrTile]?
    var done: Bool?
}

struct TitleData: Decodable {
    var jellyfinId: String?
    var tmdb: String?
    var title: String?
    var year: String?
    var runtime: String?
    var age: String?
    var score: Double?
    var genres: [String]?
    var overview: String?
    var tagline: String?
    var director: String?
    var cast: [Cast]?
    var poster: String?
    var backdrop: String?
    var trailer: String?
    var canPlayNow: Bool?
    var seerrStatus: Int?
    var hasSeerrUser: Bool?
    var virtualId: String?
    var seasons: [TSeason]?

    struct Cast: Decodable, Hashable { var name: String?; var role: String?; var photo: String? }
    struct TSeason: Decodable, Hashable {
        var n: Int
        var name: String?
    }

    enum K: String, CodingKey { case jellyfinId, tmdb, title, year, runtime, age, score, genres, overview, tagline, director, cast, poster, backdrop, trailer, canPlayNow, seerrStatus, hasSeerrUser, virtualId, seasons }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        jellyfinId = try? c.decode(String.self, forKey: .jellyfinId)
        tmdb = try? c.decode(Flex.self, forKey: .tmdb).s
        title = try? c.decode(String.self, forKey: .title)
        year = try? c.decode(Flex.self, forKey: .year).s
        runtime = try? c.decode(Flex.self, forKey: .runtime).s
        age = try? c.decode(String.self, forKey: .age)
        score = try? c.decode(Double.self, forKey: .score)
        genres = try? c.decode([String].self, forKey: .genres)
        overview = try? c.decode(String.self, forKey: .overview)
        tagline = try? c.decode(String.self, forKey: .tagline)
        director = try? c.decode(String.self, forKey: .director)
        cast = try? c.decode([Cast].self, forKey: .cast)
        poster = try? c.decode(String.self, forKey: .poster)
        backdrop = try? c.decode(String.self, forKey: .backdrop)
        trailer = try? c.decode(String.self, forKey: .trailer)
        canPlayNow = try? c.decode(Bool.self, forKey: .canPlayNow)
        seerrStatus = try? c.decode(Int.self, forKey: .seerrStatus)
        hasSeerrUser = try? c.decode(Bool.self, forKey: .hasSeerrUser)
        virtualId = try? c.decode(String.self, forKey: .virtualId)
        seasons = try? c.decode([TSeason].self, forKey: .seasons)
    }
}

// MARK: - Plugin calls

enum Plugin {
    static func home() async -> HomeData? { try? await Api.get("/JellyUI/Home", quiet: true) }
    static func requests() async -> RequestsData? { try? await Api.get("/JellyUI/Requests", quiet: true) }
    static func decide(_ id: Int, _ verb: String) async throws { _ = try await Api.request("/JellyUI/Requests/\(id)/\(verb)", method: "POST") }
    static func title(_ kind: String, _ tmdb: String) async throws -> TitleData {
        try await Api.get("/JellyUI/Title/\(kind)/\(tmdb.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tmdb)")
    }
    static func genre(_ id: String) async throws -> Collection {
        try await Api.get("/JellyUI/Genre/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")
    }
    static func service(_ id: String) async throws -> Collection {
        try await Api.get("/JellyUI/Service/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")
    }
    static func more(_ kind: String, _ id: String, page: Int) async -> MoreData? {
        try? await Api.get("/JellyUI/More/\(kind)/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)", ["page": page])
    }
    static func request(_ type: String, _ tmdb: Int) async throws { _ = try await Api.request("/JellyUI/Request", method: "POST", body: ["type": type, "tmdb": tmdb]) }
    static func deleteItem(_ id: String) async throws { _ = try await Api.request("/JellyUI/Item/\(id)", method: "DELETE") }
    static func onDemandPlay(_ tmdb: String) async throws { _ = try await Api.request("/OnDemand/Play/\(tmdb)", method: "POST") }
    static func onDemandStatus(_ tmdb: String) async -> [String: Any]? {
        guard let d = try? await Api.request("/OnDemand/Status/\(tmdb)", quiet: true) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    static func season(_ tmdb: String, _ n: Int) async -> [[String: Any]] {
        guard let d = try? await Api.request("/JellyUI/Season/\(tmdb)/\(n)"),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        return o["episodes"] as? [[String: Any]] ?? []
    }
    struct MixesData: Decodable {
        struct Mix: Decodable, Hashable { var name: String; var count: Int?; var covers: [String]? }
        var mixes: [Mix]?
        var items: [Item]?
    }
    /// A radio from a song or an artist (the server's RadioController): a batch of songs like it; asked again as the queue runs low.
    static func radio(_ seed: String, served: Int = 0, exclude: [String] = []) async -> [Item] {
        struct R: Decodable { var items: [Item]? }
        let body: [String: Any] = ["n": 25, "served": served, "exclude": Array(exclude.suffix(1500)), "likes": [String](), "skips": [String](), "seed": seed]
        guard let data = try? await Api.request("/JellyUI/Radio", method: "POST", body: body, quiet: true),
              let r = try? jellyDecoder.decode(R.self, from: data) else { return [] }
        return r.items ?? []
    }

    /// Plays a radio: the first batch now, the next ones as the queue runs low (songs already queued are left out).
    @MainActor
    static func startRadio(_ seed: String) async {
        let first = await radio(seed)
        guard !first.isEmpty else { return }
        final class Count { var n = 0 }
        let served = Count(); served.n = first.count
        PlayerModel.shared.play(first, at: 0, more: {
            let have = await MainActor.run { PlayerModel.shared.queue.map(\.id) }
            let got = await radio(seed, served: served.n, exclude: have)
            served.n += got.count
            return got
        })
    }

    static func mixes() async -> MixesData? { try? await Api.get("/JellyUI/Mixes", quiet: true) }
    static func genreMix(_ genre: String, n: Int = 100) async -> [Item] {
        guard let d = try? await Api.request("/JellyUI/GenreMix", method: "POST", body: ["genre": genre, "n": n, "served": 0, "exclude": []], quiet: true),
              let r = try? jellyDecoder.decode(Api.ItemList.self, from: d) else { return [] }
        return r.items ?? []
    }
}

extension Pic {
    /// A plain TMDB file name only, nothing that could change the request path.
    private static func tmdbFile(_ p: String?) -> String? {
        guard var p, !p.isEmpty else { return nil }
        if p.lowercased().hasPrefix("http") { p = "/" + (p.split(separator: "/").last.map(String.init) ?? "") }
        let ok = p.range(of: "^/[A-Za-z0-9_-]{1,80}\\.[a-z]{3,4}$", options: [.regularExpression, .caseInsensitive]) != nil
        return ok ? p : nil
    }
    static func tmdb(_ p: String?, _ w: String = "w342") -> URL? {
        guard let f = tmdbFile(p) else { return nil }
        return Api.keyed("/JellyUI/Img/\(w)\(f)")
    }
}

/// The deterministic hue the web UI gave each genre tile.
func genreHue(_ s: String) -> Double {
    var h = 0
    for u in s.utf16 { h = (h &* 31 &+ Int(u)) % 360 }
    return Double(h)
}
