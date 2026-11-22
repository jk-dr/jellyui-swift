import SwiftUI
import UIKit

extension Color {
    /// hsl(h, s%, l%) as the web's style sheet writes it
    init(h: Double, s: Double, l: Double) {
        let s = s / 100, l = l / 100
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m)
    }
}

/// Answers kept for a while so a page opens with what it showed last time, then refreshes.
enum Mem {
    private static var store: [String: (at: Date, value: Any)] = [:]
    static func get<T>(_ key: String, ttl: TimeInterval = 600) -> T? {
        guard let e = store[key], Date().timeIntervalSince(e.at) < ttl else { return nil }
        return e.value as? T
    }
    static func stale<T>(_ key: String) -> T? { store[key]?.value as? T }
    static func set(_ key: String, _ v: Any) { store[key] = (Date(), v) }
    static func clear() { store = [:] }
}

private let coverType = ["movies": "Movie", "tvshows": "Series", "music": "MusicAlbum", "homevideos": "Photo,Video", "photos": "Photo,Video"]
private let countType = ["movies": "Movie", "tvshows": "Series", "music": "Audio", "homevideos": "Video,Photo", "photos": "Photo,Video"]

struct LibCover: Hashable { var n: Int?; var img: URL? }

/// The home page, in the web's order and sizes: libraries, services, genres, continue watching, then Seerr's rows.
struct HomeScreen: View {
    @Environment(Nav.self) private var nav
    @Environment(Session.self) private var session
    private let settings = Settings.shared

    @State private var views: [Item] = Mem.stale("views") ?? []
    @State private var home: HomeData? = Mem.stale("home")
    @State private var resume: [Item] = Mem.stale("resume") ?? []
    @State private var reqs: RequestsData? = nil
    @State private var covers: [String: LibCover] = Mem.stale("libcovers") ?? [:]
    @State private var loaded = false
    @State private var svcKind = "network"
    @State private var filters: [Int: String] = [:]
    @State private var dismissed: Set<Int> = []

    private var libs: [Item] { views.filter { ($0.collectionType ?? "") != "" && $0.collectionType != "playlists" && $0.collectionType != "boxsets" } }

    private let kinds = [("network", "Networks"), ("provider", "Streaming"), ("studio", "Studios")]

    var body: some View {
        let w = UIScreen.main.bounds.width
        let cw = w - 56
        let h = home
        let availKinds = kinds.filter { k in h?.services?.contains { $0.kind == k.0 } ?? false }
        let activeKind = availKinds.contains { $0.0 == svcKind } ? svcKind : (availKinds.first?.0 ?? svcKind)
        let svcList = (h?.services ?? []).filter { $0.kind == activeKind }
        let pending = (reqs?.items ?? []).filter { !dismissed.contains($0.id) }
        let showReqs = (reqs?.can ?? false) && !pending.isEmpty

        Page(refresh: { await load(force: true) }) {
            VStack(alignment: .leading, spacing: 0) {
                if showReqs {
                    Color.clear.frame(height: 58)
                    PendingRequestsView(items: pending) { id in dismissed.insert(id) }
                }

                if settings.homeLibraries {
                    HomeHeader("Libraries", top: showReqs ? 24 : 70)
                    if libs.isEmpty && !loaded {
                        HRowSkeleton(height: 225, width: 150, pad: 28).padding(.vertical, 6)
                    } else if libs.isEmpty {
                        Text("No libraries yet.").font(.q(16)).foregroundStyle(Color.dimText).frame(maxWidth: .infinity).padding(.top, 30)
                    } else {
                        HomeRow(height: 225) { ForEach(libs) { LibraryTile(v: $0, cover: covers[$0.id]) } }
                    }
                }

                if h?.ready == true, !availKinds.isEmpty {
                    HomeHeader("Explore Services", top: showReqs ? 18 : 36)
                    HomePills(options: availKinds.map { (value: $0.0, label: $0.1) }, value: Binding(get: { activeKind }, set: { svcKind = $0 }), top: 10)
                    HomeRow(height: 72) { ForEach(svcList) { ServiceLogo(s: $0) } }.padding(.top, 2)
                } else if h == nil && !loaded {
                    HomeHeader("Explore Services", top: showReqs ? 18 : 36)
                    HRowSkeleton(height: 72, width: 72, pad: 28).padding(.vertical, 6)
                }

                if settings.homeGenres, h?.ready == true, let g = h?.genres, !g.isEmpty {
                    HomeHeader("Genres")
                    HomeRow(height: 84, gap: 10) { ForEach(g) { GenreTile(g: $0) } }
                }

                if settings.homeContinue, !resume.isEmpty {
                    HomeHeader("Continue Watching")
                    HomeRow(height: cw * 0.5625, snap: cw) { ForEach(resume) { ContinueCard(it: $0, width: cw) } }
                }

                if settings.homeTrending, h?.ready == true, let secs = h?.sections {
                    ForEach(Array(secs.enumerated()), id: \.offset) { i, sec in
                        let mixed = sec.items.contains { $0.t == "m" } && sec.items.contains { $0.t == "s" }
                        let f = filters[i] ?? "all"
                        let cards = sec.items.map { $0.card }.filter { f == "all" || String($0.t) == f }
                        HomeHeader(sec.title)
                        if mixed {
                            HomePills(options: [(value: "all", label: "All"), (value: "m", label: "Movie"), (value: "s", label: "Show")],
                                      value: Binding(get: { f }, set: { filters[i] = $0 }), top: 8)
                        }
                        if cards.isEmpty {
                            Text("Nothing here").font(.q(16)).foregroundStyle(Color.dimText).frame(maxWidth: .infinity).padding(.top, 30)
                        } else {
                            HomeRow(height: 225) { ForEach(cards) { HomeTile(card: $0, badge: mixed && f == "all") } }
                        }
                    }
                }

                if let h, h.ready != true, h.seerr == false {
                    Note("Seerr is not set up in the On-Demand plugin, so services, genres and trending are unavailable.").padding(.horizontal, 12)
                }
            }
        }
        .task { if !loaded || Date().timeIntervalSince(HomeScreen.lastLoad) > 60 { await load(force: false) } }
        .onChange(of: nav.play) { _, n in if n == nil { Task { await load(force: true) } } }
    }

    static var lastLoad = Date.distantPast

    private func load(force: Bool) async {
        HomeScreen.lastLoad = Date()
        if force { Mem.clear() }
        async let v = try? Api.views()
        async let hm = Plugin.home()
        async let rs = try? Api.resume()
        async let rq = Plugin.requests()
        if let v = await v { views = v; Mem.set("views", v) }
        if let hm = await hm { home = hm; Mem.set("home", hm) }
        if let rs = await rs { resume = rs; Mem.set("resume", rs) }
        reqs = await rq
        loaded = true
        // each library: how many items it holds, and a clean cover (the artwork of its newest title)
        var out: [String: LibCover] = covers
        await withTaskGroup(of: (String, LibCover).self) { group in
            for v in libs {
                group.addTask {
                    let ct = v.collectionType ?? ""
                    guard let cov = coverType[ct], ct != "livetv" else { return (v.id, LibCover(n: nil, img: nil)) }
                    async let n = try? await Api.get("/Items", ["userId": Api.uid, "ParentId": v.id, "Recursive": true, "Limit": 0, "IncludeItemTypes": countType[ct]]) as ItemsResult
                    async let newest = try? await Api.items(["ParentId": v.id, "Recursive": true, "Limit": 1, "IncludeItemTypes": cov, "ImageTypes": "Primary", "SortBy": "DateCreated", "SortOrder": "Descending", "EnableImageTypes": "Primary", "ImageTypeLimit": 1])
                    let count = await n?.totalRecordCount
                    let img = await newest?.first.flatMap { Pic.poster($0, h: 450) }
                    return (v.id, LibCover(n: count, img: img))
                }
            }
            for await (id, c) in group { out[id] = c }
        }
        covers = out
        Mem.set("libcovers", out)
    }
}

// MARK: - Home rows and headings (the web's phone sizes: 28 in from the edge)

/// A section heading: Questrial 20, pink, 28 in from the edge; `top` is the room above it.
private struct HomeHeader: View {
    let text: String
    var top: CGFloat
    init(_ t: String, top: CGFloat = 36) { text = t; self.top = top }
    var body: some View {
        Text(text).font(.q(20)).foregroundStyle(Color.pink)
            .shadow(color: .black, radius: 4, y: 1)
            .padding(.leading, 28).padding(.top, top)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of cards (the web's .libs, .svc, .gens, .cont): starts 28 in, 6 above and 6 below the cards.
private struct HomeRow<Content: View>: View {
    var height: CGFloat
    var gap: CGFloat = 12
    var snap: CGFloat?
    @ViewBuilder var content: () -> Content
    var body: some View {
        HRow(height: height, gap: gap, pad: 28, snap: snap) { content() }
            .padding(.top, 6).padding(.bottom, 6)
    }
}

/// The web's All / Movie / Show and Networks / Streaming / Studios switch: pink on the chosen one, 28 in from the edge.
private struct HomePills<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var value: T
    var top: CGFloat
    var body: some View {
        HStack(spacing: 2.4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.value == value
                Button { value = o.value } label: {
                    Text(o.label).font(.q(14)).lineLimit(1).frame(height: 20)
                        .foregroundStyle(on ? Color.bg : Color.midText)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(on ? Color.pink : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(hex: 0x16161a), in: Capsule())
        .padding(.leading, 28).padding(.top, top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The web's cover fade for the tall tiles (.lib.has:before)
private struct HomeFade: View {
    var body: some View {
        let stops: [Gradient.Stop] = [
            .init(color: Color(hex: 0x0c0c0e, alpha: 0.8), location: 0), .init(color: Color(hex: 0x0c0c0e, alpha: 0.61), location: 0.12),
            .init(color: Color(hex: 0x0c0c0e, alpha: 0.45), location: 0.21), .init(color: Color(hex: 0x0c0c0e, alpha: 0.24), location: 0.29),
            .init(color: Color(hex: 0x0c0c0e, alpha: 0.07), location: 0.37), .init(color: Color(hex: 0x0c0c0e, alpha: 0.12), location: 0.46),
            .init(color: Color(hex: 0x0c0c0e, alpha: 0.33), location: 0.54), .init(color: Color(hex: 0x0c0c0e, alpha: 0.52), location: 0.62),
            .init(color: Color(hex: 0x0c0c0e, alpha: 0.68), location: 0.71), .init(color: Color(hex: 0x0c0c0e, alpha: 0.73), location: 0.79),
            .init(color: Color(hex: 0x0c0c0e, alpha: 0.8), location: 0.87), .init(color: Color(hex: 0x0c0c0e, alpha: 0.86), location: 1),
        ]
        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}

/// A title in the Trending and Popular rows: the web's .lib tile (150 x 225, 12 corners), with the type badge top right when asked.
private struct HomeTile: View {
    let card: Card
    var badge = false
    @Environment(Nav.self) private var nav
    var body: some View {
        let sub = (card.t == "m" || card.t == "s") ? card.sub.replacingOccurrences(of: "^(Movie|Show)( · )?", with: "", options: .regularExpression) : card.sub
        Button { nav.go(card.route) } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(hex: 0x181818), Color(hex: 0x0f0f11)], startPoint: .top, endPoint: .bottom)
                if card.img != nil {
                    Pic_(card.img, radius: 0)
                    HomeFade()
                } else {
                    Text(String(card.title.prefix(1))).font(.q(56)).foregroundStyle(Color(hex: 0x2c2c30))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 64)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.q(16)).foregroundStyle(Color.midText).lineLimit(1)
                    if !sub.isEmpty { Text(sub).font(.q(11)).foregroundStyle(Color.dimText).lineLimit(1) }
                }
                .padding(.horizontal, 9).padding(.bottom, 15)
                if badge { TypeBadge(t: card.t).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
            }
            .frame(width: 150, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Tiles

struct LibraryTile: View {
    let v: Item
    var cover: LibCover?
    @Environment(Nav.self) private var nav

    private static let icons: [String: String] = [
        "movies": "M12 2a10 10 0 100 20 10 10 0 000-20zm0 3.5a1.8 1.8 0 110 3.6 1.8 1.8 0 010-3.6zM6.5 13.2a1.8 1.8 0 110-3.6 1.8 1.8 0 010 3.6zm2.2 4.6a1.8 1.8 0 113.6 0 1.8 1.8 0 01-3.6 0zm6.8-4.6a1.8 1.8 0 110-3.6 1.8 1.8 0 010 3.6zM12 12.9a.9.9 0 110-1.8.9.9 0 010 1.8z",
        "livetv": "M8.3 1.5l3.7 3.7 3.7-3.7 1.2 1.2-3 3H20a2 2 0 012 2V20a2 2 0 01-2 2H4a2 2 0 01-2-2V8.7a2 2 0 012-2h6.1l-3-3zM4 8.7V20h12.5V8.7zM18.5 10a1 1 0 100 2 1 1 0 000-2zm0 4a1 1 0 100 2 1 1 0 000-2z",
        "music": "M20 2H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-2 5h-3v5.5c0 1.38-1.12 2.5-2.5 2.5S10 13.88 10 12.5s1.12-2.5 2.5-2.5c.57 0 1.08.19 1.5.51V5h4v2zM4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6z",
        "photo": "M5 3h14a2 2 0 012 2v14a2 2 0 01-2 2H5a2 2 0 01-2-2V5a2 2 0 012-2zm0 2v10l4-4 4 4 3-3 4 4V5zm11 1.5a1.5 1.5 0 100 3 1.5 1.5 0 000-3z",
    ]

    var body: some View {
        let ct = v.collectionType ?? ""
        let sub = cover?.n.map { "\(NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal)) \(ct == "music" ? "Songs" : "items")" } ?? (ct == "livetv" ? "Channels" : "Library")
        Button {
            switch ct {
            case "movies": nav.root(.movies)
            case "tvshows": nav.root(.shows)
            case "music": nav.root(.music)
            case "livetv": nav.root(.live)
            default: nav.go(.photos(v.id))
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(hex: 0x181818), Color(hex: 0x0f0f11)], startPoint: .top, endPoint: .bottom)
                if let u = cover?.img {
                    Pic_(u, radius: 0)
                    HomeFade()
                } else {
                    SVGPath(d: Self.icons[ct] ?? Self.icons["photo"]!).fill(Color(hex: 0x232323)).frame(width: 60, height: 60)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.leading, 45).padding(.top, 80)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.title).font(.q(16)).foregroundStyle(Color.midText).lineLimit(1)
                    Text(sub).font(.q(11)).foregroundStyle(Color.dimText).lineLimit(1)
                }
                .padding(.horizontal, 9).padding(.bottom, 15)
            }
            .frame(width: 150, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

struct ServiceLogo: View {
    let s: HomeService
    @Environment(Nav.self) private var nav
    var body: some View {
        let u = Pic.tmdb(s.logo, s.kind == "provider" ? "w154" : "w185")
        let co = s.kind != "provider"
        Button { nav.go(.service(s.id)) } label: {
            ZStack {
                (co ? Color.surfaceHi : Color.surface)
                if let u {
                    if co { Pic_(u, radius: 0, fit: .fit).frame(width: 52, height: 52).brightness(0.15) } else { Pic_(u, radius: 0) }
                } else {
                    Text(s.name).font(.q(11)).foregroundStyle(Color.dimText).multilineTextAlignment(.center).padding(4)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

struct GenreTile: View {
    let g: HomeGenre
    @Environment(Nav.self) private var nav
    var body: some View {
        let hue = genreHue(g.id)
        Button { nav.go(.genre(g.id)) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                Text(g.name).font(.q(16)).foregroundStyle(Color(hex: 0xf2f2f2)).lineLimit(2)
                Text("\(g.count) \(g.count == 1 ? "title" : "titles")").font(.q(11)).foregroundStyle(Color.white.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: 210, height: 84, alignment: .leading)
            .background(LinearGradient(colors: [Color(h: hue, s: 38, l: 25), Color(h: (hue + 35).truncatingRemainder(dividingBy: 360), s: 42, l: 12)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

private func hm(_ ticks: Int64) -> String {
    let m = Int((Double(ticks) / 600_000_000).rounded())
    let h = m / 60
    if ticks <= 0 { return "0m" }
    if m < 1 { return "<1m" }
    return (h > 0 ? "\(h)h " : "") + (m % 60 != 0 ? "\(m % 60)m" : (h > 0 ? "" : "0m"))
}

private func rel(_ d: String?) -> String {
    guard let d, let date = ISO8601DateFormatter.flexible(d) else { return "" }
    let s = Date().timeIntervalSince(date)
    if s < 3600 { return "\(max(1, Int((s / 60).rounded()))) minutes ago" }
    if s < 86400 { let h = Int((s / 3600).rounded()); return "\(h) \(h == 1 ? "hour" : "hours") ago" }
    let dd = Int((s / 86400).rounded())
    return "\(dd) \(dd == 1 ? "day" : "days") ago"
}

extension ISO8601DateFormatter {
    static func flexible(_ s: String) -> Date? {
        let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: s) { return d }
        let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
        if let d = b.date(from: s) { return d }
        // Jellyfin writes 7 fraction digits: cut them to 3
        if let dot = s.firstIndex(of: ".") {
            let rest = s[s.index(after: dot)...]
            let digits = rest.prefix { $0.isNumber }
            let tail = rest.dropFirst(digits.count)
            return a.date(from: String(s[..<dot]) + "." + digits.prefix(3) + tail)
        }
        return nil
    }
}

struct ContinueCard: View {
    let it: Item
    let width: CGFloat
    @Environment(Nav.self) private var nav
    var body: some View {
        let ud = it.userData
        let pos = ud?.playbackPositionTicks ?? 0
        let pct = ud?.playedPercentage ?? 0
        let episode = it.type == "Episode"
        let title = episode ? (it.seriesName ?? it.title) : it.title
        let sub = (episode ? "S\(it.parentIndexNumber.map(String.init) ?? "?") · E\(it.indexNumber.map(String.init) ?? "?") · " : "") + rel(ud?.lastPlayedDate)
        Button {
            if episode { nav.play = PlayRequest(itemId: it.id) } else { nav.go(.movie(it.id)) }
        } label: {
            ZStack(alignment: .topLeading) {
                Color(hex: 0x181818)
                if let u = Pic.backdrop(it, h: 540) { Pic_(u, radius: 0) }
                LinearGradient(stops: [
                    .init(color: Color(hex: 0x0c0c0e, alpha: 0.9), location: 0), .init(color: Color(hex: 0x0c0c0e, alpha: 0.21), location: 0.62),
                    .init(color: Color(hex: 0x0c0c0e, alpha: 0.45), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.q(20)).foregroundStyle(Color.midText).lineLimit(1).shadow(color: .black, radius: 4)
                    Text(sub).font(.q(13)).foregroundStyle(Color.midText).lineLimit(1).shadow(color: .black, radius: 4)
                }
                .padding(.leading, 14).padding(.top, 12).padding(.trailing, 14)
                if pos > 0 {
                    Text("\(hm(pos)) watched").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: 0xe6e6e6)).shadow(color: .black, radius: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, 12).padding(.bottom, 4)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.35))
                    Capsule().fill(Color.white).frame(width: (width - 28) * CGFloat(min(1, pct / 100)))
                }
                .frame(height: 2.4).padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 14)
            }
            .frame(width: width, height: width * 0.5625)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

struct PendingRequestsView: View {
    let items: [PendingRequest]
    var onDone: (Int) -> Void
    @State private var busy: Int?
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pending requests").font(.q(20)).foregroundStyle(Color.pink).padding(.top, 18).padding(.leading, 16)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { r in
                    let kind: String = r.type == "tv" ? "Series" : "Movie"
                    let yr: String = (r.year ?? "").isEmpty ? "" : " · " + (r.year ?? "")
                    let seasonNums: [Int] = r.type == "tv" ? (r.seasons ?? []) : []
                    let seasonList: String = seasonNums.map { String($0) }.joined(separator: ", ")
                    let seasonText: String = seasonNums.isEmpty ? "" : " · Season" + (seasonNums.count > 1 ? "s " : " ") + seasonList
                    let hd: String = r.is4k == true ? " · 4K" : ""
                    let meta: String = kind + yr + seasonText + hd
                    HStack(alignment: .top, spacing: 12) {
                        Pic_(Pic.tmdb(r.poster, "w185"), radius: 7.2).frame(width: 64, height: 96)
                        VStack(alignment: .leading, spacing: 2.4) {
                            Text(r.title).font(.q(15.6)).foregroundStyle(Color.pink).lineLimit(1)
                            Text(meta).font(.q(12)).foregroundStyle(Color(hex: 0xa9a9a9)).lineLimit(1)
                            Text("Requested by \(r.requestedBy ?? "")").font(.q(12)).foregroundStyle(Color(hex: 0xa9a9a9)).lineLimit(1)
                            Spacer(minLength: 7)
                            HStack(spacing: 8) {
                                pill("Approve", Color(red: 70 / 255, green: 180 / 255, blue: 110 / 255).opacity(0.25), Color(hex: 0x8fe0ae)) { await decide(r, "approve") }
                                pill("Deny", Color(red: 224 / 255, green: 64 / 255, blue: 64 / 255).opacity(0.2), Color(hex: 0xff9a9a)) { await decide(r, "decline") }
                            }
                        }
                    }
                    .padding(10).frame(width: 290)
                    .background(Color(hex: 0x151518), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.top, 8).padding(.leading, 16)
            if !error.isEmpty { Text(error).font(.q(12)).foregroundStyle(Color.danger).padding(.leading, 16).padding(.top, 6) }
        }
    }

    private func pill(_ t: String, _ bg: Color, _ fg: Color, _ act: @escaping () async -> Void) -> some View {
        Button { Task { await act() } } label: {
            Text(t).font(.q(13.2)).foregroundStyle(fg).padding(.horizontal, 18).padding(.vertical, 6).background(bg, in: Capsule())
        }.buttonStyle(.plain).disabled(busy != nil)
    }

    private func decide(_ r: PendingRequest, _ verb: String) async {
        busy = r.id; error = ""
        defer { busy = nil }
        do { try await Plugin.decide(r.id, verb); onDone(r.id) } catch { self.error = "Could not \(verb == "approve" ? "approve" : "deny"): \(error.localizedDescription)" }
    }
}
