import SwiftUI

// MARK: - Search

private struct SearchResults {
    var movies: [Item] = [], shows: [Item] = [], artists: [Item] = [], albums: [Item] = [], songs: [Item] = [], playlists: [Item] = []
    var total: Int { movies.count + shows.count + artists.count + albums.count + songs.count + playlists.count }
}

private let clockPath = "M13 3a9 9 0 0 0-9 9H1l3.89 3.89.07.14L9 12H6a7 7 0 1 1 2.05 4.95l-1.41 1.41A9 9 0 1 0 13 3zm-1 5v5l4.28 2.54.72-1.21-3.5-2.08V8H12z"

/// The web's search: the pill stays where the header's was and narrows to make room for Cancel; the results fade in.
struct SearchScreen: View {
    @Environment(Nav.self) private var nav
    @Environment(PlayerModel.self) private var pm
    @State private var q = ""
    @State private var res = SearchResults()
    @State private var loading = false
    @State private var error = ""
    @State private var dym = ""
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    @State private var recAll = false
    @State private var expanded: Set<String> = []
    /// "Search Movie / TV show providers": what the On-Demand plugin finds that is not in the library yet (asked only when pressed)
    @State private var prov: [Card]?
    @State private var provFor = ""
    @State private var provLoading = false
    /// "Load song providers": songs and artists from YouTube / SoundCloud (the YtSearch plugin answers Jellyfin's own search), asked only when pressed
    @State private var ext: [Item]?
    @State private var extFor = ""
    @State private var extLoading = false
    @State private var open: CGFloat = 0
    @FocusState private var focused: Bool

    private var term: String { q.trimmingCharacters(in: .whitespaces) }
    /// how many of each group are listed before "Show N more" (the web: 2 on a phone, 4 on a larger screen)
    private var per: Int { UIScreen.main.bounds.width > 700 ? 4 : 2 }
    private var recentCap: Int { UIScreen.main.bounds.width > 700 ? 8 : 4 }

    var body: some View {
        ZStack(alignment: .top) {
            Color.bg.opacity(Double(open)).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ZStack {
                        SVGPath(d: "M24 14a10 10 0 11-20 0 10 10 0 0120 0z M22 22l7 7", box: 32)
                            .stroke(Color(hex: 0x3e2222), style: StrokeStyle(lineWidth: 2.6, lineCap: .round)).frame(width: 22, height: 22)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 13)
                        TextField("", text: $q, prompt: Text("What do you want to watch?").foregroundStyle(Color(hex: 0x8a5a5a)))
                            .font(.q(16)).foregroundStyle(focused ? Color(hex: 0xd4d4d4) : Color(hex: 0x6f6262)).multilineTextAlignment(.center)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                            .focused($focused).padding(.horizontal, 44)
                            .onSubmit { remember(); focused = false }
                    }
                    .frame(height: 48)
                    .background(Color(hex: 0x1a1a1c), in: Capsule())
                    .overlay(Capsule().stroke(focused ? Color(hex: 0xe6e6e6) : Color(hex: 0x2a2a2d), lineWidth: focused ? 2 : 1))
                    .padding(.trailing, open * 78)
                }
                .overlay(alignment: .trailing) {
                    Button { cancel() } label: { Text("Cancel").font(.q(16)).foregroundStyle(Color.pink).frame(width: 70, height: 48, alignment: .trailing) }
                        .buttonStyle(.plain).opacity(Double(open)).offset(x: (1 - open) * 28)
                        .allowsHitTesting(open > 0.5)
                }
                // this column sits inside the safe area already: the field lands exactly where the header's search bar is
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) { results; PageEnd() }
                        .padding(.horizontal, 14).padding(.top, 6)
                    Color.clear.frame(height: 120)
                }
                .scrollDismissesKeyboard(.immediately)
                .opacity(Double(open))
            }
        }
        .task(id: q) { await runSearch() }
        .onChange(of: q) { _, _ in expanded = [] }
        .onAppear {
            withAnimation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.38)) { open = 1 }
            DispatchQueue.main.async { focused = true }
        }
    }

    @ViewBuilder private var results: some View {
        if term.isEmpty {
            if !recent.isEmpty {
                h3("Recent searches")
                let shown = recAll ? recent : Array(recent.prefix(recentCap))
                ForEach(shown, id: \.self) { r in
                    HStack(spacing: 12) {
                        SVGPath(d: clockPath).fill(Color.dimText).frame(width: 18, height: 18)
                            .frame(width: 38, height: 38).background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                        Text(r).font(.q(16)).foregroundStyle(Color(hex: 0xd4d4d4)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Button { recent.removeAll { $0 == r }; UserDefaults.standard.set(recent, forKey: "recentSearches") } label: { Icon(name: "close", size: 18, color: Color.dimText).padding(10) }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
                    .onTapGesture { q = r }
                }
                if !recAll && recent.count > shown.count { moreRow("Show more") { recAll = true } }
                moreRow("Clear recent searches") { recent = []; UserDefaults.standard.set(recent, forKey: "recentSearches") }
            }
        } else {
            if loading && res.total == 0 { ProgressView().tint(Color.dimText).frame(maxWidth: .infinity).padding(24) }
            if !error.isEmpty { Text(error).font(.q(15)).foregroundStyle(Color.danger).frame(maxWidth: .infinity).padding(12) }
            if !loading && res.total == 0 && error.isEmpty {
                if !dym.isEmpty { dymRow }
                else { Text("No results for “\(term)”").font(.q(15)).foregroundStyle(Color.dimText).frame(maxWidth: .infinity).padding(12) }
            }
            group("TV Shows", res.shows) { m in row(m, "Show" + yr(m)) { go(.show(m.id)) } }
            group("Movies", res.movies) { m in row(m, "Movie" + yr(m)) { go(.movie(m.id)) } }
            group("Artists", res.artists) { a in row(a, "Artist", round: true) { go(.artist(a.id)) } }
            songGroup
            group("Albums", res.albums) { m in row(m, m.albumArtist ?? "Album") { go(.album(m.id)) } }
            group("Playlists", res.playlists) { m in row(m, "Playlist") { go(.playlist(m.id)) } }
            providers
            songProviders
        }
    }

    private func yr(_ it: Item) -> String { it.productionYear.map { " · \($0)" } ?? "" }
    /// The web's "Movie & TV Providers" section: a row to ask, then what was found (movies first, then shows, best match first)
    @ViewBuilder private var providers: some View {
        if term.count >= 2 {
            h3("Movie & TV Providers")
            if let prov, provFor == term {
                if prov.isEmpty { Text("Nothing found").font(.q(14)).foregroundStyle(Color.dimText).padding(.horizontal, 8).padding(.vertical, 6) }
                ForEach(prov) { c in
                    Button { remember(); go(c.route) } label: {
                        HStack(spacing: 12) {
                            Group { if let u = c.img { Pic_(u, radius: 6) } else { Color.surfaceHi } }
                                .frame(width: 38, height: 54).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.title).font(.q(16)).foregroundStyle(Color(hex: 0xd4d4d4)).lineLimit(1)
                                Text(c.sub).font(.q(12)).foregroundStyle(Color.dimText).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                }
            } else {
                Button { Task { await loadProviders() } } label: {
                    HStack(spacing: 12) {
                        Text("+").font(.q(20)).foregroundStyle(Color.pink).frame(width: 38, height: 38).background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Search Movie / TV show providers").font(.q(16)).foregroundStyle(Color(hex: 0xd4d4d4)).lineLimit(1)
                            Text("Find movies and shows that are not in the library yet").font(.q(12)).foregroundStyle(Color.dimText).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if provLoading { ProgressView().tint(Color.dimText) }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
                }.buttonStyle(PressStyle()).disabled(provLoading)
            }
        }
    }

    /// The web's "Music Streaming" section
    @ViewBuilder private var songProviders: some View {
        if term.count >= 2 {
            h3("Music Streaming")
            if let ext, extFor == term {
                let have = Set(res.songs.map(\.id) + res.artists.map(\.id))
                let more = ext.filter { !have.contains($0.id) }
                let songs = more.filter { $0.type == "Audio" }
                if more.isEmpty { Text("Nothing more found").font(.q(14)).foregroundStyle(Color.dimText).padding(.horizontal, 8).padding(.vertical, 6) }
                ForEach(more.filter { $0.type == "MusicArtist" }) { a in row(a, "Artist", round: true) { go(.artist(a.id)) } }
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, it in
                    HStack(spacing: 4) {
                        row(it, it.artistLine.isEmpty ? "Song" : it.artistLine) { remember(); focused = false; close {}; pm.playNow(it) }
                            .contextMenu { SongMenuItems(it: it) }
                        SongMenu(it: it) {
                            Icon(name: "moreV", size: 18, color: Color(hex: 0xcfcfcf)).frame(width: 34, height: 34).background(Color.surfaceHi, in: Circle())
                        }
                        .padding(.trailing, 6)
                    }
                }
            } else {
                Button { Task { await loadSongProviders() } } label: {
                    HStack(spacing: 12) {
                        Text("+").font(.q(20)).foregroundStyle(Color.pink).frame(width: 38, height: 38).background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Load song providers").font(.q(16)).foregroundStyle(Color(hex: 0xd4d4d4)).lineLimit(1)
                            Text("Search YouTube and SoundCloud").font(.q(12)).foregroundStyle(Color.dimText).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if extLoading { ProgressView().tint(Color.dimText) }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
                }.buttonStyle(PressStyle()).disabled(extLoading)
            }
        }
    }

    private func loadSongProviders() async {
        let t = term
        extLoading = true
        defer { extLoading = false }
        struct Hints: Decodable { var searchHints: [Item]? }
        let r: Hints? = try? await Api.get("/Search/Hints", ["userId": Api.uid, "searchTerm": t, "limit": 30, "includeItemTypes": "Audio,MusicArtist"])
        guard t == term else { return }
        let items = r?.searchHints ?? []
        // artists (not in the library) first, then the songs, in the server's order
        ext = items.filter { $0.type == "MusicArtist" } + items.filter { $0.type != "MusicArtist" }
        extFor = t
    }

    private func loadProviders() async {
        let t = term
        provLoading = true
        defer { provLoading = false }
        struct Hints: Decodable { var searchHints: [Item]? }
        struct Shows: Decodable { var items: [SeerrTile]? }
        async let mv: Hints? = try? Api.get("/Search/Hints", ["userId": Api.uid, "searchTerm": t, "limit": 30, "includeItemTypes": "Movie"])
        async let sh: Shows? = try? Api.get("/JellyUI/Shows", ["q": t], quiet: true)
        // movies the plugin added for the search (no length: not downloaded yet), then the shows Seerr knows
        let movies = ((await mv)?.searchHints ?? []).filter { ($0.runTimeTicks ?? 0) == 0 }.map { $0.card }
        let shows = ((await sh)?.items ?? []).map { $0.card }
        guard t == term else { return }
        let low = t.lowercased()
        func rel(_ c: Card) -> Int { let n = c.title.lowercased(); return n == low ? 3 : (n.hasPrefix(low) ? 2 : (n.contains(low) ? 1 : 0)) }
        prov = (movies + shows).enumerated().sorted { (rel($0.element), -$0.offset) > (rel($1.element), -$1.offset) }.map(\.element)
        provFor = t
    }

    private func h3(_ t: String) -> some View {
        Text(t.uppercased()).font(.q(11)).tracking(1.54).foregroundStyle(Color.dimText).padding(.top, 8).padding(.horizontal, 10).padding(.bottom, 4)
    }

    @ViewBuilder private func group<V: View>(_ title: String, _ items: [Item], _ build: @escaping (Item) -> V) -> some View {
        if !items.isEmpty {
            let n = expanded.contains(title) ? min(items.count, 40) : min(items.count, per)
            h3(title)
            ForEach(items.prefix(n)) { build($0) }
            if items.count > n { moreRow("Show \(items.count - n) more") { _ = expanded.insert(title) } }
        }
    }

    @ViewBuilder private var songGroup: some View {
        if !res.songs.isEmpty {
            let n = expanded.contains("Songs") ? min(res.songs.count, 40) : min(res.songs.count, per)
            h3("Songs")
            // the web's compact search rows (cover, title, artist) with a round dots button; held or dotted, the full song menu
            ForEach(0..<n, id: \.self) { i in
                let it = res.songs[i]
                HStack(spacing: 4) {
                    row(it, it.artistLine.isEmpty ? "Song" : it.artistLine) { remember(); focused = false; close {}; pm.playNow(it) }
                        .contextMenu { SongMenuItems(it: it) }
                    SongMenu(it: it) {
                        Icon(name: "moreV", size: 18, color: Color(hex: 0xcfcfcf)).frame(width: 34, height: 34).background(Color.surfaceHi, in: Circle())
                    }
                    .padding(.trailing, 6)
                }
            }
            if res.songs.count > n { moreRow("Show \(res.songs.count - n) more") { _ = expanded.insert("Songs") } }
        }
    }

    /// the web's "Show N more" row: full width, dark, pink words
    private func moreRow(_ t: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(t).font(.q(13)).foregroundStyle(Color.pink).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7).padding(.horizontal, 14)
                .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 10))
                .padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }

    /// "Did you mean": the library name closest to what was typed
    private var dymRow: some View {
        Button { q = dym } label: {
            HStack(spacing: 12) {
                Text("?").font(.q(16)).foregroundStyle(Color.bg).frame(width: 38, height: 38).background(Color.pink, in: RoundedRectangle(cornerRadius: 8))
                Text("Did you mean “\(dym)”?").font(.q(16)).foregroundStyle(Color.pink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }

    /// one prediction row: a small picture (round for an artist), the name with what was typed picked out, and a line under it
    private func row(_ it: Item, _ sub: String, round: Bool = false, _ tap: @escaping () -> Void) -> some View {
        Button { remember(); tap() } label: {
            HStack(spacing: 12) {
                Group {
                    if let u = Pic.poster(it, h: 100) { Pic_(u, radius: round ? 19 : 8) } else { Color.surfaceHi.overlay(Text(String(it.title.prefix(1))).font(.q(16)).foregroundStyle(Color.pink)) }
                }
                .frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: round ? 19 : 8, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    mark(it.title)
                    Text(sub).font(.q(12)).foregroundStyle(Color.dimText).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }

    @ViewBuilder private func mark(_ name: String) -> some View {
        if !term.isEmpty, let r = name.range(of: term, options: .caseInsensitive) {
            (Text(String(name[..<r.lowerBound])).foregroundStyle(Color(hex: 0xd4d4d4)) + Text(String(name[r])).foregroundStyle(Color.pink) + Text(String(name[r.upperBound...])).foregroundStyle(Color(hex: 0xd4d4d4))).font(.q(16)).lineLimit(1)
        } else {
            Text(name).font(.q(16)).foregroundStyle(Color(hex: 0xd4d4d4)).lineLimit(1)
        }
    }

    private func go(_ r: Route) { focused = false; nav.go(r) }

    private func cancel() {
        focused = false
        close {}
    }

    private func close(_ then: @escaping () -> Void) {
        withAnimation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.24)) { open = 0 }
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            nav.searching = false
            then()
        }
    }

    private func remember() {
        guard !term.isEmpty else { return }
        recent = Array(([term] + recent.filter { $0.lowercased() != term.lowercased() }).prefix(8))
        UserDefaults.standard.set(recent, forKey: "recentSearches")
    }

    /// One search per change of the box. The query is read once, so a slow answer for an old query cannot be
    /// shown for a new one: a cancelled run (the box changed again) stops before it writes anything.
    private func runSearch() async {
        let query = term
        guard !query.isEmpty else { res = SearchResults(); loading = false; dym = ""; return }
        loading = true
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        defer { if !Task.isCancelled { loading = false } }
        do {
            // the library's own movies, shows, artists, albums, songs and playlists, searched on the server with nothing online (the web's /JellyUI/Find).
            // Jellyfin's own search is what the YouTube / SoundCloud plugin hooks into: it went online on every search. Those come only from "Load song providers".
            struct Found: Decodable { var items: [Item]? }
            var q: [String: Any?] = ["q": query, "limit": 80]
            let plain = String(query.filter { !"\u{2019}\u{2018}'`".contains($0) })
            if plain != query { q["alt"] = plain } // "don't" also as "dont", as the web asks
            let f: Found = try await Api.get("/JellyUI/Find", q)
            let r = (f.items ?? []).filter { !$0.isVirtual }
            if Task.isCancelled { return }
            func by(_ t: String) -> [Item] { r.filter { $0.type == t } }
            res = SearchResults(movies: by("Movie"), shows: by("Series"), artists: by("MusicArtist"), albums: by("MusicAlbum"), songs: by("Audio"), playlists: by("Playlist"))
            error = ""; dym = ""
            if res.total == 0 {
                struct Sug: Decodable { var suggestion: String? }
                let s: Sug? = try? await Api.get("/JellyUI/Suggest", ["q": query], quiet: true)
                if Task.isCancelled { return }
                dym = s?.suggestion ?? ""
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

// MARK: - Live TV

private func clock(_ d: String?) -> String {
    guard let d, let date = ISO8601DateFormatter.flexible(d) else { return "" }
    let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
    return f.string(from: date)
}

private let heartPath = "M16.5 3c-1.74 0-3.41.81-4.5 2.09C10.91 3.81 9.24 3 7.5 3 4.42 3 2 5.42 2 8.5c0 3.78 3.4 6.86 8.55 11.54L12 21.35l1.45-1.32C18.6 15.36 22 12.28 22 8.5 22 5.42 19.58 3 16.5 3z"

/// A channel card (the web's .chc): its number large on a dark panel with a LIVE tag, then name, what is on, the times and a progress bar.
struct ChannelCard: View {
    let c: Item
    let fav: Bool
    var onFav: (Item) -> Void
    var onOpen: (Item) -> Void

    var body: some View {
        var pct: Double = 0
        var np = "No guide data"
        var range = ""
        if let cp = c.currentProgram, let s = ISO8601DateFormatter.flexible(cp.startDate ?? ""), let e = ISO8601DateFormatter.flexible(cp.endDate ?? ""), e > s {
            pct = max(0, min(100, Date().timeIntervalSince(s) / e.timeIntervalSince(s) * 100))
            np = cp.name ?? ""
            range = "\(clock(cp.startDate)) – \(clock(cp.endDate))"
        }
        return ZStack(alignment: .topTrailing) {
            Button { onOpen(c) } label: {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        LinearGradient(colors: [Color(hex: 0x222228), Color(hex: 0x121216)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Text(c.number ?? "").font(.q(46)).foregroundStyle(Color(hex: 0x31313a)).frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text("LIVE").font(.q(10)).tracking(1.2).foregroundStyle(.white).padding(.horizontal, 6).frame(height: 15)
                            .background(Color(hex: 0xe0344a), in: RoundedRectangle(cornerRadius: 6)).padding(8)
                    }.frame(height: 106)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.title).font(.q(15)).foregroundStyle(Color(hex: 0xf2f2f2))
                        Text(np).font(.q(13)).foregroundStyle(Color.midText).lineLimit(1)
                        if !range.isEmpty { Text(range).font(.q(11)).foregroundStyle(Color.dimText) }
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Rectangle().fill(Color.pink).scaleEffect(x: max(pct / 100, 0.001), anchor: .leading)
                        }
                        .frame(height: 6).clipShape(Capsule()).padding(.top, 10)
                    }
                    .padding(.top, 10).padding(.horizontal, 12).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 220).background(Color(hex: 0x16161a)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }.buttonStyle(PressStyle())
            Button { onFav(c) } label: {
                SVGPath(d: heartPath).fill(fav ? Color.pink : .clear)
                    .overlay(SVGPath(d: heartPath).stroke(fav ? Color.pink : Color(hex: 0xf2f2f2), style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
                    .frame(width: 18, height: 18).frame(width: 32, height: 32).background(Color.black.opacity(0.55), in: Circle())
            }.buttonStyle(.plain).padding(6)
        }
        .frame(width: 220)
    }
}

extension Api {
    static func channels(withProgram: Bool) async -> [Item] {
        ((try? await get("/LiveTv/Channels", ["userId": uid, "addCurrentProgram": withProgram ? true : nil, "enableUserData": true, "SortBy": "SortName", "Limit": 5000]) as ItemsResult)?.items) ?? []
    }
}

struct LiveScreen: View {
    @Environment(Nav.self) private var nav
    @State private var chans: [Item] = []
    @State private var loaded = false
    @State private var filter = ""
    @State private var pageNo = 1
    @State private var favs: [String: Bool] = [:]
    @State private var recents: [String] = UserDefaults.standard.stringArray(forKey: "recents") ?? []

    private let LPAGE = 48

    private func isFav(_ c: Item) -> Bool { favs[c.id] ?? (c.userData?.isFavorite ?? false) }
    /// the searchable words of each channel, made once when the list loads (not per keystroke)
    @State private var wordsById: [String: String] = [:]
    private static func searchWords(_ c: Item) -> String {
        ((c.title + " " + (c.number ?? "")).lowercased()).replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    private func words(_ c: Item) -> String { wordsById[c.id] ?? LiveScreen.searchWords(c) }
    private func setChannels(_ list: [Item]) {
        chans = list
        wordsById = Dictionary(list.map { ($0.id, LiveScreen.searchWords($0)) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let toks = filter.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).split(separator: " ").map(String.init)
        let list = toks.isEmpty ? chans : chans.filter { c in let w = " " + words(c); return toks.allSatisfy { w.contains(" " + $0) || w.contains($0) } }
        let pages = max(1, Int(ceil(Double(list.count) / Double(LPAGE))))
        let cur = min(pageNo, pages)
        let page = Array(list.dropFirst((cur - 1) * LPAGE).prefix(LPAGE))
        let favList = chans.filter(isFav)
        let byId = Dictionary(chans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recList = recents.compactMap { byId[$0] }

        Page(refresh: { await load() }) {
            PageTitle(text: "Live TV")
            TextField("", text: $filter, prompt: Text("Filter channels (e.g. uk bbc)").foregroundStyle(Color(hex: 0x6f6262)))
                .font(.q(16)).foregroundStyle(Color.pink).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 18).frame(height: 42).background(Color.surfaceHi, in: Capsule())
                .padding(.horizontal, 16).padding(.top, 10)
                .onChange(of: filter) { _, _ in pageNo = 1 }
            if chans.isEmpty {
                if !loaded { ProgressView().tint(Color.dimText).frame(maxWidth: .infinity).padding(24) }
                else { Note("No channels found. Add a tuner or an M3U playlist under Dashboard → Live TV, then come back.") }
            } else {
                if toks.isEmpty {
                    H2("Favorited channels")
                    if favList.isEmpty { Text("No favorited channels yet. Tap the heart on any channel to add it here.").font(.q(14)).foregroundStyle(Color.dimText).padding(.horizontal, 16).padding(.top, 12) }
                    else { chRow(favList) }
                    if !recList.isEmpty { H2("Recently watched channels").padding(.top, -2); chRow(recList) }
                }
                H2(toks.isEmpty ? "All channels · \(chans.count)" : "Channels · \(list.count)").padding(.top, -2)
                Pager(cur: cur, total: pages) { pageNo = $0 }
                FlowWrap(spacing: 12) {
                    ForEach(page) { c in ChannelCard(c: c, fav: isFav(c), onFav: toggle, onOpen: open) }
                }.padding(.horizontal, 16).padding(.top, 12)
                if page.isEmpty { Text("No channels match").font(.q(16)).foregroundStyle(Color.dimText).padding(.top, 30).frame(maxWidth: .infinity) }
            }
        }
        .task { await load() }
    }

    private func chRow(_ items: [Item]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) { ForEach(items) { c in ChannelCard(c: c, fav: isFav(c), onFav: toggle, onOpen: open) } }
                .padding(.horizontal, 11).padding(.vertical, 6)
        }.padding(.top, 6)
    }

    private func toggle(_ c: Item) {
        let on = !isFav(c)
        favs[c.id] = on
        Task { await Api.setFavourite(c.id, on) }
    }

    private func open(_ c: Item) {
        recents = Array(([c.id] + recents.filter { $0 != c.id }).prefix(12))
        UserDefaults.standard.set(recents, forKey: "recents")
        nav.play = PlayRequest(itemId: c.id, live: true)
    }

    private func load() async {
        setChannels(await Api.channels(withProgram: false))
        loaded = true
        let withProg = await Api.channels(withProgram: true)
        if !withProg.isEmpty { setChannels(withProg) }
    }
}
