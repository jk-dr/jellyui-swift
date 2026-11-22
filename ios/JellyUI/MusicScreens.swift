import SwiftUI

private let SONG_FIELDS = "AlbumArtist,RunTimeTicks,CanDelete"

extension Api {
    static func songs(_ o: [String: Any?] = [:]) async throws -> ItemsResult {
        var q: [String: Any?] = ["userId": uid, "IncludeItemTypes": "Audio", "Recursive": true, "Fields": SONG_FIELDS]
        for (k, v) in o { q[k] = v }
        return try await get("/Items", q)
    }
    static func randomSongs(_ n: Int) async -> [Item] { ((try? await songs(["Limit": n, "SortBy": "Random"]))?.items) ?? [] }
}

func shuffleList<T>(_ a: [T]) -> [T] { a.shuffled() }

func slug(_ n: String) -> String {
    let s = n.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

/// "Song (Live)" -> title + a LIVE tag, as the web UI showed it.
func songName(_ name: String) -> (t: String, live: Bool) {
    var live = false
    var t = name
    if let r = t.range(of: "\\s*[(\\[]\\s*live\\b([^)\\]]*)[)\\]]", options: [.regularExpression, .caseInsensitive]) {
        live = true
        let m = String(t[r])
        var rest = m.replacingOccurrences(of: "^\\s*[(\\[]\\s*live\\b", with: "", options: [.regularExpression, .caseInsensitive])
        rest = rest.replacingOccurrences(of: "[)\\]]\\s*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        rest = rest.replacingOccurrences(of: "^(version|recording|performance)\\b\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        t.replaceSubrange(r, with: rest.isEmpty ? "" : " (\(rest))")
    }
    t = t.trimmingCharacters(in: .whitespaces)
    return (t.isEmpty ? name : t, live)
}

func mmss(_ ticks: Int64?) -> String {
    guard let ticks, ticks > 0 else { return "" }
    let s = Int((Double(ticks) / 1e7).rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Menus

@Observable
final class PlaylistCache {
    static let shared = PlaylistCache()
    var list: [Item] = []
    private var at = Date.distantPast
    func load() {
        if Date().timeIntervalSince(at) < 60 { return }
        at = Date()
        Task { list = await Api.playlists() }
    }
    func reset() { at = .distantPast; load() }
}

struct AddToPlaylistMenu<Content: View>: View {
    let ids: [String]
    @ViewBuilder var label: () -> Content
    @State private var naming = false
    @State private var name = ""
    private let pls = PlaylistCache.shared

    var body: some View {
        Menu {
            Button { naming = true } label: { Label("New playlist…", systemImage: "plus") }
            ForEach(pls.list) { p in
                Button { Task { await add(p.id) } } label: { Label(p.title, systemImage: "music.note.list") }
            }
        } label: { label() }
        .onAppear { pls.load() }
        .alert("New playlist", isPresented: $naming) {
            TextField("Name for the playlist", text: $name)
            Button("Cancel", role: .cancel) { name = "" }
            Button("Create") {
                let n = name.trimmingCharacters(in: .whitespaces)
                name = ""
                guard !n.isEmpty else { return }
                Task { _ = try? await Api.request("/Playlists", method: "POST", body: ["Name": n, "Ids": ids, "UserId": Api.uid, "MediaType": "Audio"]); pls.reset() }
            }
        }
    }

    private func add(_ pid: String) async {
        _ = try? await Api.request("/Playlists/\(pid)/Items", query: ["ids": ids.joined(separator: ","), "userId": Api.uid], method: "POST")
    }
}

/// An album's or playlist's ⋮ menu: Add all to queue, Add all to playlist (a submenu, or a new playlist), and Favourite when `favOn` is given.
struct ListMenu: View {
    let songs: [Item]
    var favOn: Bool?
    var onFav: () -> Void
    @Environment(PlayerModel.self) private var pm
    @State private var naming = false
    @State private var name = ""
    private let pls = PlaylistCache.shared

    var body: some View {
        let ids = songs.map { $0.id }
        Menu {
            Button { songs.forEach { pm.enqueueLast($0) } } label: { Label("Add all to queue", systemImage: "text.badge.plus") }
            Menu {
                Button { naming = true } label: { Label("New playlist…", systemImage: "plus") }
                ForEach(pls.list) { p in
                    Button { Task { _ = try? await Api.request("/Playlists/\(p.id)/Items", query: ["ids": ids.joined(separator: ","), "userId": Api.uid], method: "POST") } } label: { Label(p.title, systemImage: "music.note.list") }
                }
            } label: { Label("Add all to playlist", systemImage: "music.note.list") }
            if let favOn {
                Button(action: onFav) { Label(favOn ? "Remove from favourites" : "Add to favourites", systemImage: favOn ? "heart.slash" : "heart") }
            }
        } label: {
            Icon(name: "more", size: 20, color: .pink).frame(width: 44, height: 44).background(Color.surfaceHi, in: Circle())
        }
        .disabled(songs.isEmpty)
        .onAppear { pls.load() }
        .alert("New playlist", isPresented: $naming) {
            TextField("Name for the playlist", text: $name)
            Button("Cancel", role: .cancel) { name = "" }
            Button("Create") {
                let n = name.trimmingCharacters(in: .whitespaces)
                name = ""
                guard !n.isEmpty else { return }
                Task { _ = try? await Api.request("/Playlists", method: "POST", body: ["Name": n, "Ids": ids, "UserId": Api.uid, "MediaType": "Audio"]); pls.reset() }
            }
        }
    }
}

/// A song's menu: Play next, Add to queue, Add to playlist (a submenu), Favourite, Go to album. In the player also Shuffle and Repeat.
struct SongMenu<Content: View>: View {
    let it: Item
    var player = false
    @ViewBuilder var label: () -> Content
    @Environment(PlayerModel.self) private var pm
    @Environment(Nav.self) private var nav
    private let pls = PlaylistCache.shared

    var body: some View {
        Menu {
            actions
        } label: { label() }
        .onAppear { pls.load() }
    }

    @ViewBuilder var actions: some View {
        Button { pm.enqueueNext(it) } label: { Label("Play next", systemImage: "text.insert") }
        Button { pm.enqueueLast(it) } label: { Label("Add to queue", systemImage: "text.badge.plus") }
        Menu {
            ForEach(pls.list) { p in
                Button { Task { _ = try? await Api.request("/Playlists/\(p.id)/Items", query: ["ids": it.id, "userId": Api.uid], method: "POST") } } label: { Label(p.title, systemImage: "music.note.list") }
            }
        } label: { Label("Add to playlist", systemImage: "music.note.list") }
        let fav = Favs.isFav(it)
        Button { Favs.toggle(it) } label: { Label(fav ? "Remove from favourites" : "Add to favourites", systemImage: fav ? "heart.slash" : "heart") }
        if let a = it.albumId { Button { pm.showFull = false; nav.go(.album(a)) } label: { Label("Go to album", systemImage: "square.stack") } }
        if player {
            Button { pm.toggleShuffle() } label: { Label(pm.shuffleOn ? "Shuffle: on" : "Shuffle", systemImage: "shuffle") }
            Button { pm.cycleRepeat() } label: { Label(pm.repeatMode == "one" ? "Repeat: one song" : (pm.repeatMode == "all" ? "Repeat: all" : "Repeat: off"), systemImage: pm.repeatMode == "one" ? "repeat.1" : "repeat") }
        }
    }
}

// MARK: - Rows and tiles

struct EqBars: View {
    let playing: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach([0.55, 1.0, 0.7], id: \.self) { h in
                RoundedRectangle(cornerRadius: 1).fill(Color.pink).frame(width: 3, height: 14 * (playing ? h : 0.35))
            }
        }.frame(height: 14)
    }
}

/// A song row, as the web draws it on a phone (.trk): cover, title over "artist • length", a heart when it is a favourite, and a ⋮ button.
struct SongRow: View {
    let it: Item
    let index: Int
    var showArt = true
    var showIndex = true
    var onPlay: (Int) -> Void
    @Environment(PlayerModel.self) private var pm

    var body: some View {
        let now = pm.current?.id == it.id
        let playing = now && pm.isPlaying
        let fav = Favs.isFav(it)
        let n = songName(it.title)
        let who = it.artistLine
        let len = mmss(it.runTimeTicks)
        HStack(spacing: 6) {
            Button { onPlay(index) } label: {
                HStack(spacing: 12) {
                    if showIndex {
                        Group {
                            if now { EqBars(playing: playing) } else { Text(String(it.indexNumber ?? index + 1)).font(.q(15)).foregroundStyle(Color.dimText).monospacedDigit() }
                        }.frame(width: 24, height: 20, alignment: .trailing)
                    }
                    if showArt { Pic_(Pic.poster(it, h: 100), radius: 6).frame(width: 40, height: 40) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(n.t + (n.live ? " (Live)" : "")).font(.q(15)).foregroundStyle(now ? Color.pink : Color(hex: 0xd4d4d4)).lineLimit(1)
                        Text(who + (len.isEmpty ? "" : " • \(len)")).font(.q(12)).foregroundStyle(Color.dimText).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if fav { Icon(name: "heart", size: 16, color: .pink) }
                }
                .padding(.vertical, now ? 6.8 : 8).padding(.horizontal, now ? 10.8 : 12)
                .background(now ? Color(hex: 0x1d1618) : Color(hex: 0x121214), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(now ? Color.pink.opacity(0.35) : .clear, lineWidth: 1.2))
            }
            .buttonStyle(PressStyle())
            .contextMenu { SongMenu(it: it) { EmptyView() }.actions }
            SongMenu(it: it) {
                Icon(name: "more", size: 20, color: Color(hex: 0xcfcfcf)).frame(width: 38, height: 38).contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 6)
    }
}

/// An album / playlist / artist tile (the web's .mc): a square cover with its name and line along the bottom.
struct MusicTile: View {
    let it: Item
    var size: CGFloat = 150
    @Environment(Nav.self) private var nav

    var body: some View {
        let artist = it.type == "MusicArtist"
        let sub = it.type == "Audio" ? it.artistLine : (it.type == "MusicAlbum" ? (it.albumArtist ?? "Album") : (artist ? "Artist" : (it.childCount.map { "\($0) songs" } ?? "Playlist")))
        let fav = it.id == "favourites"
        Button { nav.go(it.route) } label: {
            ZStack(alignment: .bottomLeading) {
                Color(hex: 0x181818)
                if let u = Pic.poster(it, h: 320) { Pic_(u, radius: 0) }
                else if fav {
                    LinearGradient(colors: [Color(hex: 0x6b1f2e), Color(hex: 0x2a0d14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Icon(name: "heart", size: size * 0.42, color: Color(hex: 0xff8597)).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Icon(name: "music", size: size * 0.34, color: Color(hex: 0x2c2c30)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                LinearGradient(colors: [.clear, Color.black.opacity(0.65)], startPoint: .top, endPoint: .bottom).frame(height: 60).frame(maxHeight: .infinity, alignment: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    Text(it.title).font(.q(12)).foregroundStyle(Color.midText).lineLimit(1)
                    Text(sub).font(.q(10)).foregroundStyle(Color.dimText).lineLimit(1)
                }.padding(.horizontal, 14).padding(.bottom, 8)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: artist ? size / 2 : 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// A genre mix (the web's .mc.mix): a 2 x 2 collage of the covers of its songs, tinted by a colour taken from its name.
struct MixTile: View {
    let name: String
    var count: Int?
    let covers: [URL]
    var size: CGFloat = 150
    @Environment(Nav.self) private var nav

    var body: some View {
        var pics = Array(covers.prefix(4))
        while !pics.isEmpty && pics.count < 4 { pics.append(pics[pics.count % max(1, pics.count)]) }
        let cap = name.prefix(1).uppercased() + name.dropFirst()
        let h = genreHue(name)
        return Button { nav.go(.playlist("mix-" + slug(name))) } label: {
            ZStack(alignment: .bottomLeading) {
                Color(hex: 0x181818)
                if pics.isEmpty { Icon(name: "music", size: size * 0.34, color: Color(hex: 0x2c2c30)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) { Pic_(pics[0], radius: 0).frame(width: size / 2, height: size / 2); Pic_(pics[1], radius: 0).frame(width: size / 2, height: size / 2) }
                        HStack(spacing: 0) { Pic_(pics[2], radius: 0).frame(width: size / 2, height: size / 2); Pic_(pics[3], radius: 0).frame(width: size / 2, height: size / 2) }
                    }
                }
                Color(h: h, s: 60, l: 45).opacity(0.28)
                LinearGradient(colors: [.clear, Color.black.opacity(0.65)], startPoint: .top, endPoint: .bottom).frame(height: 60).frame(maxHeight: .infinity, alignment: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(cap) mix").font(.q(12)).foregroundStyle(Color.midText).lineLimit(1)
                    Text("\(count ?? 0) songs").font(.q(10)).foregroundStyle(Color.dimText).lineLimit(1)
                }.padding(.horizontal, 14).padding(.bottom, 8)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// One song of a Quick Play column (the web's .tk on a phone): a 56 pt cover, title over artist, and a ⋮ button at its right.
struct QuickRow: View {
    let it: Item
    let index: Int
    let width: CGFloat
    var onPlay: (Int) -> Void

    var body: some View {
        let n = songName(it.title)
        HStack(spacing: 0) {
            Button { onPlay(index) } label: {
                HStack(spacing: 14) {
                    Group {
                        if let u = Pic.poster(it, h: 200) { Pic_(u, radius: 0) }
                        else { Color.surfaceHi.overlay(Icon(name: "music", size: 26, color: Color(hex: 0x2c2c30))) }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(n.t).font(.q(16)).foregroundStyle(Color(hex: 0xd4d4d4)).lineLimit(1)
                        Text(it.artistLine).font(.q(14)).foregroundStyle(Color.dimText).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .contextMenu { SongMenu(it: it) { EmptyView() }.actions }
            SongMenu(it: it) {
                Icon(name: "more", size: 22, color: Color(hex: 0xbdbdc2)).frame(width: 40, height: 40).contentShape(Rectangle())
            }
        }
        .frame(width: width)
    }
}

/// Songs in columns of four, side by side and paged by swiping (the web's Quick Play and Recently downloaded on a phone).
struct RowColumns: View {
    let songs: [Item]
    let colW: CGFloat
    var onPlay: (Int) -> Void

    var body: some View {
        let cols = (songs.count + 3) / 4
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(0..<cols, id: \.self) { c in
                    VStack(spacing: 8) {
                        ForEach(c * 4..<min(c * 4 + 4, songs.count), id: \.self) { i in
                            QuickRow(it: songs[i], index: i, width: colW, onPlay: onPlay)
                        }
                    }
                    .frame(width: colW, alignment: .top)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 28, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }
}

/// Wraps its tiles onto as many lines as they need (the web's .mrow.alb).
struct TileWrap<Content: View>: View {
    var gap: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        WordFlowGrid(spacing: gap) { content() }.padding(6).padding(.horizontal, 5).padding(.top, 6)
    }
}

// MARK: - Music page

struct MusicScreen: View {
    @Environment(PlayerModel.self) private var pm
    @State private var playlists: [Item] = Mem.stale("m.pl") ?? []
    @State private var favAlbums: [Item] = Mem.stale("m.fa") ?? []
    @State private var recent: [Item] = Mem.stale("m.recent") ?? []
    @State private var mixes: Plugin.MixesData? = Mem.stale("m.mixes")
    @State private var quick: [Item] = []
    @State private var downloads: [Item] = []
    @State private var toast = ""
    @State private var loadedOnce = false

    var body: some View {
        let width = UIScreen.main.bounds.width
        let pls = [Item(id: "favourites", name: "Favourites", type: "Playlist")] + playlists.filter { $0.id != "favourites" }
        let mixById = Dictionary((mixes?.items ?? []).map { ($0.id.replacingOccurrences(of: "-", with: "").lowercased(), $0) }, uniquingKeysWith: { _, b in b })

        Page(refresh: { await refresh() }) {
            PageTitle(text: "Music")
            Menu {
                Button { Task { await shuffleAll() } } label: { Label("All songs", systemImage: "shuffle") }
                Button { Task { await shuffleSongs() } } label: { Label("Favourite songs", systemImage: "heart") }
                Button { Task { await shuffleAlbums() } } label: { Label("Favourite albums", systemImage: "square.stack") }
                Button { Task { await shufflePlaylists() } } label: { Label("Favourite playlists", systemImage: "music.note.list") }
                Button { Task { await shuffleDownloads() } } label: { Label("My downloads", systemImage: "arrow.down.circle") }
            } label: {
                HStack(spacing: 8) {
                    Icon(name: "shuffle", size: 20, color: .bg)
                    Text("Shuffle").font(.q(16)).foregroundStyle(Color.bg)
                    Spacer(minLength: 8)
                    Icon(name: "chevronDown", size: 22, color: .bg)
                }
                .padding(.leading, 20).padding(.trailing, 16)
                .frame(maxWidth: .infinity).frame(height: 44).background(Color.pink, in: Capsule())
            }
            .padding(.horizontal, 28).padding(.top, 14)
            if !toast.isEmpty { Text(toast).font(.q(13)).foregroundStyle(Color.dimText).padding(.horizontal, 28).padding(.top, 8) }

            H2("Playlists").padding(.top, -14)
            HRow(height: 150, pad: 28) { ForEach(pls) { MusicTile(it: $0) } }

            if !favAlbums.isEmpty {
                H2("Favourite Albums").padding(.top, -6)
                HRow(height: 150, pad: 28) { ForEach(favAlbums) { MusicTile(it: $0) } }
            }

            H2("Quick Play").padding(.top, -6)
            if quick.isEmpty {
                if loadedOnce { Note("No songs yet.") }
            } else {
                RowColumns(songs: quick, colW: width - 56) { idx in
                    pm.play(quick, at: idx, more: { await Api.randomSongs(50) })
                }
                .padding(.top, 20)
            }

            H2("Recent Albums").padding(.top, -6)
            if recent.isEmpty {
                if loadedOnce { Note("Nothing here yet.") }
            } else {
                HRow(height: 150, pad: 28) { ForEach(recent) { MusicTile(it: $0) } }
            }

            if let ms = mixes?.mixes, !ms.isEmpty {
                H2("Mixes").padding(.top, -6)
                HRow(height: 150, pad: 28) {
                    ForEach(ms, id: \.name) { m in
                        MixTile(name: m.name, count: m.count, covers: (m.covers ?? []).compactMap { cid in
                            mixById[cid.replacingOccurrences(of: "-", with: "").lowercased()].flatMap { Pic.poster($0, h: 200) }
                        })
                    }
                }
            }

            H2("Recently downloaded").padding(.top, -6)
            if downloads.isEmpty {
                if loadedOnce { Note("Nothing downloaded yet.") }
            } else {
                RowColumns(songs: downloads, colW: width - 56) { idx in
                    pm.play(downloads, at: idx, more: { await Api.randomSongs(50) })
                }
                .padding(.top, 20)
            }
        }
        .task { await loadTop() }
    }

    // MARK: data

    private func loadTop() async {
        async let p = try? Api.items(["IncludeItemTypes": "Playlist", "Recursive": true, "SortBy": "SortName", "Limit": 30, "Fields": "ChildCount"])
        async let fa = try? Api.items(["IncludeItemTypes": "MusicAlbum", "Recursive": true, "Filters": "IsFavorite", "SortBy": "SortName", "Limit": 60])
        async let r = Api.recentAlbums()
        async let m = Plugin.mixes()
        async let qk = Api.randomSongs(24)
        async let dl = try? Api.songs(["SortBy": "DateCreated", "SortOrder": "Descending", "Limit": 25])
        if let p = await p { playlists = p; Mem.set("m.pl", p) }
        if let fa = await fa { favAlbums = fa; Mem.set("m.fa", fa) }
        recent = await r; Mem.set("m.recent", recent)
        mixes = await m; if let mixes { Mem.set("m.mixes", mixes) }
        quick = await qk
        if let dl = await dl { downloads = dl.items }
        loadedOnce = true
    }

    private func refresh() async {
        await loadTop()
    }

    private func say(_ t: String) {
        toast = t
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if toast == t { toast = "" } }
    }

    private func shuffleAll() async {
        let r = await Api.randomSongs(300)
        if r.isEmpty { return say("No songs found") }
        pm.shuffle(r, more: { await Api.randomSongs(100) })
        say("Shuffling your songs")
    }
    private func shuffleSongs() async {
        guard let r = try? await Api.songs(["Limit": 3000, "Filters": "IsFavorite"]), !r.items.isEmpty else { return say("No favourite songs yet") }
        pm.shuffle(r.items)
        say("Shuffling \(r.items.count) favourites")
    }
    private func shuffleAlbums() async {
        guard let r = try? await Api.items(["IncludeItemTypes": "MusicAlbum", "Recursive": true, "Filters": "IsFavorite", "Limit": 200]), !r.isEmpty else { return say("No favourite albums yet") }
        let albums = r.shuffled()
        guard let x = try? await Api.songs(["AlbumIds": albums.map { $0.id }.joined(separator: ","), "SortBy": "ParentIndexNumber,IndexNumber,SortName", "Limit": 3000]) else { return say("Could not start") }
        var by: [String: [Item]] = [:]
        for t in x.items { by[t.albumId ?? "", default: []].append(t) }
        let flat = albums.flatMap { (by[$0.id] ?? []).shuffled() }
        if flat.isEmpty { return say("No songs in your favourite albums") }
        pm.play(flat, shuffle: true)
        say("Shuffling \(albums.count) album\(albums.count == 1 ? "" : "s")")
    }
    private func shufflePlaylists() async {
        guard let r = try? await Api.items(["IncludeItemTypes": "Playlist", "Recursive": true, "Filters": "IsFavorite", "Limit": 100]), !r.isEmpty else { return say("No favourite playlists yet") }
        var seen = Set<String>(), flat: [Item] = []
        for p in r { for t in (try? await Api.playlistSongs(p.id)) ?? [] where seen.insert(t.id).inserted { flat.append(t) } }
        if flat.isEmpty { return say("Those playlists are empty") }
        pm.shuffle(flat)
        say("Shuffling \(r.count) favourite playlist\(r.count == 1 ? "" : "s")")
    }
    private func shuffleDownloads() async {
        guard let d = try? await Api.request("/YtSearch/MyDownloads"), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let ids = o["ids"] as? [String], !ids.isEmpty else { return say("You have not downloaded any songs yet") }
        var flat: [Item] = []
        var i = 0
        while i < ids.count {
            flat += (try? await Api.items(["Ids": ids[i..<min(i + 80, ids.count)].joined(separator: ","), "Fields": SONG_FIELDS])) ?? []
            i += 80
        }
        if flat.isEmpty { return say("Your downloaded songs are no longer here") }
        pm.shuffle(flat)
        say("Shuffling \(flat.count) of your downloads")
    }
}

// MARK: - Album / playlist / artist

enum ListKind { case album, playlist, artist }

struct ListScreen: View {
    let id: String
    let kind: ListKind
    @Environment(PlayerModel.self) private var pm
    @State private var head: Item?
    @State private var songs: [Item] = []
    @State private var albums: [Item] = []
    @State private var loading = true
    @State private var error: String?
    @State private var fav: Bool?

    var body: some View {
        let width = UIScreen.main.bounds.width
        let artW = kind == .artist ? min(220, width - 32) : width * 0.7
        let isFav = fav ?? (head?.userData?.isFavorite ?? false)
        let canFav = head != nil && id != "favourites" && !id.hasPrefix("mix-")

        Page {
            if let head {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if let u = Pic.poster(head, h: 700) { Pic_(u, radius: 0) }
                        else if id == "favourites" {
                            LinearGradient(colors: [Color(hex: 0x6b1f2e), Color(hex: 0x2a0d14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .overlay(Icon(name: "heart", size: artW * 0.3, color: Color(hex: 0xff8597)))
                        } else {
                            Color.surfaceHi.overlay(Text(String(head.title.prefix(1)).uppercased()).font(.q(artW * 0.3)).foregroundStyle(Color(hex: 0x5a5a62)))
                        }
                    }
                    .frame(width: artW, height: artW)
                    .clipShape(RoundedRectangle(cornerRadius: kind == .artist ? artW / 2 : 12, style: .continuous))
                    .frame(maxWidth: .infinity)
                    Text(head.title).font(.q(28)).foregroundStyle(Color.pink).shadow(color: .black, radius: 4, y: 1).lineLimit(3)
                        .multilineTextAlignment(kind == .artist ? .center : .leading).frame(maxWidth: .infinity, alignment: kind == .artist ? .center : .leading).padding(.top, 14)
                    if kind == .artist {
                        VStack(spacing: 10) {
                            playButton
                            ActionRow(items: [
                                Act(id: "queue", icon: "queueAdd", label: "Add all to queue", disabled: songs.isEmpty, action: { songs.forEach { pm.enqueueLast($0) } }),
                                Act(id: "pl", icon: "queue", label: "Add all to playlist", disabled: songs.isEmpty, menu: AnyView(AddToPlaylistMenu(ids: songs.map { $0.id }) { Color.clear.frame(maxWidth: .infinity, minHeight: 44) })),
                            ])
                        }.padding(.top, 14)
                    } else {
                        HStack(spacing: 10) {
                            playButton
                            ListMenu(songs: songs, favOn: canFav && kind == .album ? isFav : nil, onFav: { toggleFav(head, isFav) })
                        }.padding(.top, 12)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 84 + 32 + 14)
            }
            if kind == .artist && !albums.isEmpty {
                H2("Albums").padding(.top, -6)
                TileWrap { ForEach(albums) { MusicTile(it: $0) } }
                H2("Songs").padding(.top, -6)
            }
            Color.clear.frame(height: 16)
            if songs.isEmpty {
                if loading { ProgressView().tint(Color.dimText).frame(maxWidth: .infinity).padding(24) }
                else if let e = error { Note(e, error: true) } else { Note("Nothing here yet") }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { i, s in
                        SongRow(it: s, index: i, showArt: true, showIndex: false) { pm.play(songs, at: $0) }
                    }
                }
            }
        }
        .task { await load() }
    }

    private var playButton: some View {
        Button { pm.play(songs, at: 0) } label: {
            HStack(spacing: 8) { Icon(name: "play", size: 20, color: .bg); Text("Play").font(.q(16)).foregroundStyle(Color.bg) }
                .frame(maxWidth: .infinity).frame(height: 44).background(Color.pink, in: Capsule())
        }
        .buttonStyle(PressStyle()).disabled(songs.isEmpty).opacity(songs.isEmpty ? 0.55 : 1)
    }

    private func toggleFav(_ h: Item, _ cur: Bool) {
        fav = !cur
        Task { await Api.setFavourite(h.id, !cur) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            switch kind {
            case .album:
                async let h = Api.item(id)
                async let s = Api.songs(["AlbumIds": id, "SortBy": "ParentIndexNumber,IndexNumber,SortName"])
                head = try await h
                songs = try await s.items
            case .artist:
                async let h = Api.item(id)
                async let a = Api.items(["ArtistIds": id, "IncludeItemTypes": "MusicAlbum", "Recursive": true, "SortBy": "ProductionYear,SortName", "SortOrder": "Descending"])
                async let s = Api.songs(["ArtistIds": id, "SortBy": "PlayCount,SortName", "SortOrder": "Descending", "Limit": 200])
                head = try await h
                albums = (try? await a) ?? []
                songs = try await s.items
            case .playlist:
                if id == "favourites" {
                    head = Item(id: id, name: "Favourites", type: "Playlist")
                    songs = await Api.favouriteSongs()
                } else if id.hasPrefix("mix-") {
                    let want = String(id.dropFirst(4))
                    let m = await Plugin.mixes()
                    let name = m?.mixes?.first { slug($0.name) == want }?.name ?? want.replacingOccurrences(of: "-", with: " ")
                    head = Item(id: id, name: name, type: "Playlist")
                    songs = await Plugin.genreMix(name, n: 100)
                } else {
                    async let h = Api.item(id)
                    async let s = Api.playlistSongs(id)
                    head = try await h
                    songs = try await s
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct ArtistScreen: View {
    let id: String
    var body: some View { ListScreen(id: id, kind: .artist) }
}
