import Foundation
import SwiftUI
import UIKit

// MARK: - Theme (the web's colours)

enum Theme {
    static let bg = Color(red: 12 / 255, green: 12 / 255, blue: 14 / 255)
    static let surface = Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)
    static let surfaceHi = Color(red: 29 / 255, green: 29 / 255, blue: 32 / 255)
    static let text = Color(red: 248 / 255, green: 204 / 255, blue: 204 / 255) // the web's pink
    static let mid = Color(red: 186 / 255, green: 186 / 255, blue: 186 / 255)
    static let dim = Color(red: 134 / 255, green: 134 / 255, blue: 134 / 255)
    static let accent = Color(red: 248 / 255, green: 204 / 255, blue: 204 / 255)
    static let onAccent = Color(red: 12 / 255, green: 12 / 255, blue: 14 / 255)
}

// MARK: - Session

@Observable
final class Session {
    static let shared = Session()

    var server: String = UserDefaults.standard.string(forKey: "server") ?? "" {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }
    var token: String? = UserDefaults.standard.string(forKey: "token") {
        didSet { UserDefaults.standard.set(token, forKey: "token") }
    }
    var userId: String? = UserDefaults.standard.string(forKey: "userId") {
        didSet { UserDefaults.standard.set(userId, forKey: "userId") }
    }
    var userName: String = UserDefaults.standard.string(forKey: "userName") ?? "" {
        didSet { UserDefaults.standard.set(userName, forKey: "userName") }
    }

    @ObservationIgnored let deviceId: String

    var isSignedIn: Bool { token != nil && userId != nil && !server.isEmpty }

    init() {
        if let d = UserDefaults.standard.string(forKey: "deviceId") {
            deviceId = d
        } else {
            let d = "jellyui-swift-" + UUID().uuidString.lowercased()
            UserDefaults.standard.set(d, forKey: "deviceId")
            deviceId = d
        }
    }

    func authHeader(withToken: Bool = true) -> String {
        var h = "MediaBrowser Client=\"Monarth\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"1.0.0\""
        if withToken, let t = token { h += ", Token=\"\(t)\"" }
        return h
    }

    func signOut() {
        token = nil
        userId = nil
    }

    /// "192.168.1.5:8096" -> "http://192.168.1.5:8096"
    static func normalise(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - Models

struct UserData: Codable, Hashable {
    var isFavorite: Bool?
    var played: Bool?
    var playbackPositionTicks: Int64?
    var playedPercentage: Double?
    var lastPlayedDate: String?
}

struct Person: Codable, Hashable {
    var id: String
    var name: String?
    var role: String?
    var type: String?
    var primaryImageTag: String?
}

struct Trailer: Codable, Hashable { var url: String? }
struct SourceStub: Codable, Hashable { var id: String? }

struct Item: Codable, Identifiable, Hashable {
    var id: String
    var name: String?
    var type: String?
    var mediaType: String?
    var collectionType: String?
    var productionYear: Int?
    var runTimeTicks: Int64?
    var overview: String?
    var genres: [String]?
    var communityRating: Double?
    var officialRating: String?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var albumId: String?
    var album: String?
    var albumArtist: String?
    var albumPrimaryImageTag: String?
    var artists: [String]?
    var seriesId: String?
    var seriesName: String?
    var seriesPrimaryImageTag: String?
    var seasonId: String?
    var parentIndexNumber: Int?
    var indexNumber: Int?
    var childCount: Int?
    var userData: UserData?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var primaryImageTag: String?
    var itemId: String?
    var people: [Person]?
    var providerIds: [String: String]?
    var canDelete: Bool?
    var remoteTrailers: [Trailer]?
    var mediaSources: [SourceStub]?
    var number: String?
    var primaryImageAspectRatio: Double?
    var currentProgram: Program?
    var premiereDate: String?
    var dateCreated: String?

    var seconds: Double { Double(runTimeTicks ?? 0) / 10_000_000 }
    var title: String { name ?? "" }
    var isFavourite: Bool { userData?.isFavorite ?? false }
    var artistLine: String {
        if let a = artists, !a.isEmpty { return a.joined(separator: ", ") }
        return albumArtist ?? ""
    }
}

struct Program: Codable, Hashable {
    var name: String?
    var startDate: String?
    var endDate: String?
}

struct ItemsResult: Codable {
    var items: [Item]
    var totalRecordCount: Int?
}

/// Key decoding: the server's "RunTimeTicks" becomes "runTimeTicks".
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

let jellyDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .custom { keys in
        let k = keys.last!.stringValue
        // only server keys start with a capital; the plugin's lyric keys (t, e, w, text) are already lower case
        guard let first = k.first, first.isUppercase else { return AnyKey(stringValue: k)! }
        return AnyKey(stringValue: first.lowercased() + k.dropFirst())!
    }
    return d
}()

// MARK: - API

struct ApiError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

enum Api {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 50_000_000, diskCapacity: 400_000_000)
        c.requestCachePolicy = .useProtocolCachePolicy
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    static func url(_ path: String, _ query: [String: Any?] = [:]) -> URL? {
        guard var c = URLComponents(string: Session.shared.server + path) else { return nil }
        var list = c.queryItems ?? []
        for k in query.keys.sorted() {
            guard let v = query[k] ?? nil else { continue }
            let text = "\(v)"
            if text.isEmpty { continue }
            list.append(URLQueryItem(name: k, value: text))
        }
        if !list.isEmpty { c.queryItems = list }
        // URLComponents leaves "+" alone in values: encode it so a title or a list is read back correctly
        if let q = c.percentEncodedQuery { c.percentEncodedQuery = q.replacingOccurrences(of: "+", with: "%2B") }
        return c.url
    }

    /// A URL that carries the token, for pictures and streams (they cannot send headers).
    static func keyed(_ path: String, _ query: [String: Any?] = [:]) -> URL? {
        var q = query
        if let t = Session.shared.token { q["api_key"] = t }
        return url(path, q)
    }

    static func request(_ path: String, query: [String: Any?] = [:], method: String = "GET", body: Any? = nil, quiet: Bool = false) async throws -> Data {
        guard let u = url(path, query) else { throw ApiError(status: 0, message: "Bad address") }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.setValue(Session.shared.authHeader(), forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && !quiet {
            await MainActor.run { Session.shared.signOut() }
        }
        guard (200..<300).contains(code) else { throw ApiError(status: code, message: "Server error (\(code))") }
        return data
    }

    static func get<T: Decodable>(_ path: String, _ query: [String: Any?] = [:], quiet: Bool = false) async throws -> T {
        let d = try await request(path, query: query, quiet: quiet)
        return try jellyDecoder.decode(T.self, from: d)
    }

    // sign in

    struct Public: Decodable { var serverName: String }

    static func probe(_ base: String) async throws -> String {
        guard let u = URL(string: base + "/System/Info/Public") else { throw ApiError(status: 0, message: "That address isn't valid.") }
        do {
            let (d, r) = try await URLSession.shared.data(from: u)
            if let c = (r as? HTTPURLResponse)?.statusCode, c != 200 { throw ApiError(status: c, message: "That address answered with an error (\(c)).") }
            let p = try jellyDecoder.decode(Public.self, from: d)
            return p.serverName
        } catch let e as ApiError {
            throw e
        } catch is DecodingError {
            throw ApiError(status: 0, message: "That doesn't look like a compatible server.")
        } catch {
            throw ApiError(status: 0, message: "Can't reach that address. Check it and that you're on the right network.")
        }
    }

    static func login(base: String, name: String, pw: String) async throws {
        guard let u = URL(string: base + "/Users/AuthenticateByName") else { throw ApiError(status: 0, message: "Bad address") }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue(Session.shared.authHeader(withToken: false), forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["Username": name, "Pw": pw])
        let d: Data, resp: URLResponse
        do { (d, resp) = try await URLSession.shared.data(for: r) } catch { throw ApiError(status: 0, message: "Can't reach the server: check your connection") }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if [400, 401, 403].contains(code) { throw ApiError(status: code, message: "Wrong name or password") }
        if code == 429 { throw ApiError(status: code, message: "Too many attempts: wait a moment and try again") }
        guard code == 200 else { throw ApiError(status: code, message: "Server error (\(code))") }
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tok = o["AccessToken"] as? String,
              let user = o["User"] as? [String: Any], let uid = user["Id"] as? String
        else { throw ApiError(status: 0, message: "The server gave an unexpected answer") }
        await MainActor.run {
            let s = Session.shared
            s.server = base
            s.userId = uid
            s.userName = user["Name"] as? String ?? name
            UserDefaults.standard.set(((user["Policy"] as? [String: Any])?["IsAdministrator"] as? Bool) ?? false, forKey: "admin")
            s.token = tok
        }
    }

    // items

    static var uid: String { Session.shared.userId ?? "" }

    static func items(_ q: [String: Any?]) async throws -> [Item] {
        var q = q
        q["userId"] = uid
        let r: ItemsResult = try await get("/Items", q)
        return r.items
    }
    static func views() async throws -> [Item] {
        let r: ItemsResult = try await get("/UserViews", ["userId": uid])
        return r.items
    }
    static func resume() async throws -> [Item] {
        let r: ItemsResult = try await get("/UserItems/Resume", ["userId": uid, "Limit": 12, "MediaTypes": "Video", "EnableImageTypes": "Backdrop,Thumb,Primary"])
        return r.items
    }
    static func recent(_ kind: String, limit: Int = 24) async throws -> [Item] {
        try await items(["IncludeItemTypes": kind, "Recursive": true, "SortBy": "DateCreated", "SortOrder": "Descending", "Limit": limit, "EnableImageTypes": "Primary,Backdrop", "ImageTypeLimit": 1])
    }
    static func library(_ kind: String) async throws -> [Item] {
        try await items(["IncludeItemTypes": kind, "Recursive": true, "SortBy": "SortName", "SortOrder": "Ascending", "Limit": 5000, "EnableImageTypes": "Primary", "ImageTypeLimit": 1])
    }
    static func item(_ id: String) async throws -> Item {
        try await get("/Users/\(uid)/Items/\(id)")
    }
    static func children(_ id: String) async throws -> [Item] {
        try await items(["ParentId": id, "SortBy": "ParentIndexNumber,IndexNumber,SortName", "Fields": "RunTimeTicks,AlbumArtist"])
    }
    static func albumSongs(_ albumId: String) async throws -> [Item] {
        try await items(["ParentId": albumId, "IncludeItemTypes": "Audio", "Recursive": true, "SortBy": "ParentIndexNumber,IndexNumber,SortName", "Fields": "RunTimeTicks,AlbumArtist"])
    }
    static func playlistSongs(_ id: String) async throws -> [Item] {
        let r: ItemsResult = try await get("/Playlists/\(id)/Items", ["userId": uid, "Fields": "RunTimeTicks,AlbumArtist"])
        return r.items
    }
    static func seasons(_ showId: String) async throws -> [Item] {
        let r: ItemsResult = try await get("/Shows/\(showId)/Seasons", ["userId": uid])
        return r.items
    }
    static func episodes(_ showId: String, season: String) async throws -> [Item] {
        let r: ItemsResult = try await get("/Shows/\(showId)/Episodes", ["userId": uid, "seasonId": season, "Fields": "Overview,RunTimeTicks"])
        return r.items
    }
    static func search(_ text: String) async throws -> [Item] {
        try await items(["searchTerm": text, "Recursive": true, "Limit": 40, "IncludeItemTypes": "Movie,Series,MusicAlbum,Audio,Playlist,MusicArtist", "EnableImageTypes": "Primary"])
    }
    static func setFavourite(_ id: String, _ on: Bool) async {
        _ = try? await request("/Users/\(uid)/FavoriteItems/\(id)", method: on ? "POST" : "DELETE")
    }

    // JellyUI plugin (every call optional)

    struct ItemList: Decodable { var items: [Item]? }
    static func recentAlbums() async -> [Item] {
        if let r = (try? await get("/JellyUI/RecentAlbums", ["limit": 40], quiet: true) as ItemList)?.items, !r.isEmpty { return r }
        return (try? await items(["IncludeItemTypes": "MusicAlbum", "Recursive": true, "SortBy": "DateCreated", "SortOrder": "Descending", "Limit": 40])) ?? []
    }
    static func favouriteSongs() async -> [Item] {
        ((try? await get("/JellyUI/Favourites", quiet: true) as ItemList)?.items) ?? []
    }
    static func forYou() async -> [Item] {
        ((try? await get("/JellyUI/ForYou", quiet: true) as ItemList)?.items) ?? []
    }
    static func playlists() async -> [Item] {
        (try? await items(["IncludeItemTypes": "Playlist", "Recursive": true, "SortBy": "SortName", "Limit": 50, "Fields": "ChildCount"])) ?? []
    }
    static func albums() async -> [Item] {
        (try? await library("MusicAlbum")) ?? []
    }
}

// MARK: - Pictures

extension Item {
    /// The server's ImageTags keys are "Primary", "Thumb"…; look them up whatever case the decoder left them in.
    func imageTag(_ kind: String) -> String? {
        guard let tags = imageTags else { return nil }
        if let t = tags[kind] { return t }
        let low = kind.prefix(1).lowercased() + kind.dropFirst()
        return tags[low] ?? tags.first { $0.key.caseInsensitiveCompare(kind) == .orderedSame }?.value
    }
}

enum Pic {
    private static func img(_ id: String, _ kind: String, h: Int, tag: String?) -> URL? {
        Api.url("/Items/\(id)/Images/\(kind)", ["maxHeight": h, "quality": 85, "tag": tag])
    }

    static func poster(_ it: Item, h: Int = 450) -> URL? {
        if it.type == "Audio", let a = it.albumId { return img(a, "Primary", h: h, tag: it.albumPrimaryImageTag) }
        if let t = it.imageTag("Primary") { return img(it.id, "Primary", h: h, tag: t) }
        if let t = it.primaryImageTag { return img(it.itemId ?? it.id, "Primary", h: h, tag: t) }
        if let s = it.seriesId, let t = it.seriesPrimaryImageTag { return img(s, "Primary", h: h, tag: t) }
        if let a = it.albumId, let t = it.albumPrimaryImageTag { return img(a, "Primary", h: h, tag: t) }
        if it.type == "Audio" { return img(it.albumId ?? it.id, "Primary", h: h, tag: nil) }
        return nil
    }

    static func backdrop(_ it: Item, h: Int = 720) -> URL? {
        if let t = it.backdropImageTags?.first { return img(it.id, "Backdrop", h: h, tag: t) }
        if let p = it.parentBackdropItemId, let t = it.parentBackdropImageTags?.first { return img(p, "Backdrop", h: h, tag: t) }
        if let t = it.imageTag("Thumb") { return img(it.id, "Thumb", h: h, tag: t) }
        return poster(it, h: h)
    }

    static func square(_ it: Item, _ px: Int) -> URL? {
        guard let u = poster(it, h: px) else { return nil }
        return URL(string: u.absoluteString + "&fillWidth=\(px)&fillHeight=\(px)")
    }
}

// MARK: - Image cache (memory + the URL cache's disk)

final class ImageStore {
    static let shared = ImageStore()
    private let mem = NSCache<NSURL, UIImage>()
    private var loading: [URL: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    init() { mem.totalCostLimit = 120 * 1_048_576 }

    func cached(_ url: URL) -> UIImage? { mem.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let i = cached(url) { return i }
        let t = task(for: url)
        let out = await t.value
        finish(url)
        return out
    }

    private func task(for url: URL) -> Task<UIImage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let t = loading[url] { return t }
        let t = Task<UIImage?, Never> {
            var r = URLRequest(url: url)
            r.cachePolicy = .returnCacheDataElseLoad
            r.setValue(Session.shared.authHeader(), forHTTPHeaderField: "Authorization")
            guard let (d, _) = try? await Api.session.data(for: r), let raw = UIImage(data: d) else { return nil }
            // decoded here, in the background, so the first draw on screen does not have to
            let i = await raw.byPreparingForDisplay() ?? raw
            self.mem.setObject(i, forKey: url as NSURL, cost: Int(i.size.width * i.size.height * i.scale * i.scale * 4))
            return i
        }
        loading[url] = t
        return t
    }

    private func finish(_ url: URL) {
        lock.lock()
        loading[url] = nil
        lock.unlock()
    }
}

struct Pic_: View {
    let url: URL?
    var radius: CGFloat = 8
    var fit: ContentMode = .fill
    @State private var image: UIImage?

    init(_ url: URL?, radius: CGFloat = 8, fit: ContentMode = .fill) {
        self.url = url
        self.radius = radius
        self.fit = fit
        _image = State(initialValue: url.flatMap { ImageStore.shared.cached($0) })
    }

    var body: some View {
        Theme.surface
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: fit).transition(.opacity)
                }
            }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = ImageStore.shared.cached(url) { image = c; return }
            let i = await ImageStore.shared.load(url)
            withAnimation(.easeOut(duration: 0.2)) { image = i }
        }
    }
}
