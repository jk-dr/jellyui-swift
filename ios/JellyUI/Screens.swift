import AVKit
import SwiftUI

// MARK: - App

@main
struct JellyUIApp: App {
    @State private var session = Session.shared
    @State private var player = PlayerModel.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isSignedIn { RootView() } else { LoginView() }
            }
            .environment(session)
            .environment(player)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
    }
}

// MARK: - Login

struct LoginView: View {
    @Environment(Session.self) private var session
    @State private var step = Session.shared.server.isEmpty ? 0 : 1
    @State private var address = Session.shared.server
    @State private var serverName = ""
    @State private var user = ""
    @State private var pw = ""
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Spacer()
                Text("JellyUI").font(.system(size: 36, weight: .bold)).foregroundStyle(Theme.text).frame(maxWidth: .infinity)
                    .padding(.bottom, 20)
                if step == 0 {
                    Text("Connect to server").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                    field("192.168.1.10:8096 or jellyfin.example.com", text: $address, secure: false)
                        .keyboardType(.URL)
                    Button(busy ? "Connecting…" : "Connect") { Task { await connect() } }.buttonStyle(Primary()).disabled(busy)
                } else {
                    Text("Sign in").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                    Button { step = 0; error = "" } label: { Text("\(serverName.isEmpty ? Session.shared.server : serverName) · Change").font(.system(size: 13)).foregroundStyle(Theme.dim) }
                    field("Username", text: $user, secure: false)
                    field("Password", text: $pw, secure: true)
                    Button(busy ? "Signing in…" : "Sign in") { Task { await signIn() } }.buttonStyle(Primary()).disabled(busy)
                }
                if !error.isEmpty { Text(error).font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.54, blue: 0.54)) }
                Spacer()
                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .task {
            if step == 1, let n = try? await Api.probe(Session.shared.server) { serverName = n }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(14)
        .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(Theme.text)
    }

    private func connect() async {
        let base = Session.normalise(address)
        guard !base.isEmpty else { error = "Enter your server address"; return }
        busy = true; error = ""
        defer { busy = false }
        do {
            serverName = try await Api.probe(base)
            session.server = base
            step = 1
        } catch { self.error = error.localizedDescription }
    }

    private func signIn() async {
        let u = user.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { error = "Enter your username"; return }
        guard !pw.isEmpty else { error = "Enter your password"; return }
        busy = true; error = ""
        defer { busy = false }
        do {
            try await Api.login(base: session.server, name: u, pw: pw)
            pw = ""
        } catch {
            self.error = error.localizedDescription
            pw = ""
        }
    }
}

struct Primary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

// MARK: - Tabs

struct RootView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        @Bindable var p = player
        TabView {
            NavigationStack { HomeView().navigationDestination(for: Item.self) { DetailRouter(item: $0) } }.tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { MusicView().navigationDestination(for: Item.self) { DetailRouter(item: $0) } }.tabItem { Label("Music", systemImage: "music.note") }
            NavigationStack { SearchView().navigationDestination(for: Item.self) { DetailRouter(item: $0) } }.tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayer()
        }
        .sheet(isPresented: $p.showFull) {
            FullPlayer().presentationBackground(.black).presentationDragIndicator(.hidden)
        }
    }
}

// MARK: - Rows and tiles

struct Poster: View {
    let item: Item
    var width: CGFloat = 120
    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 6) {
                let square = item.type == "MusicAlbum" || item.type == "Audio" || item.type == "Playlist"
                Pic_(Pic.poster(item, h: 360), radius: 10)
                    .frame(width: width, height: square ? width : width * 1.5)
                Text(item.title).font(.system(size: 13)).foregroundStyle(Theme.mid).lineLimit(1).frame(width: width, alignment: .leading)
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
    private var sub: String {
        switch item.type {
        case "MusicAlbum": return item.albumArtist ?? "Album"
        case "Playlist": return "Playlist"
        case "Episode": return "S\(item.parentIndexNumber ?? 0) · E\(item.indexNumber ?? 0)"
        case "Movie", "Series": return item.productionYear.map(String.init) ?? ""
        default: return item.artistLine
        }
    }
}

struct Shelf: View {
    let title: String
    let items: [Item]
    var width: CGFloat = 120
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 20)).foregroundStyle(Theme.text).padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) { ForEach(items) { Poster(item: $0, width: width) } }.padding(.horizontal, 16)
                }
            }
        }
    }
}

private extension View {
    func page() -> some View {
        self.background(Theme.bg.ignoresSafeArea())
    }
}

struct DetailRouter: View {
    let item: Item
    var body: some View {
        switch item.type {
        case "MusicAlbum", "Playlist": SongListView(item: item)
        case "Audio": SongListView(item: Item(id: item.albumId ?? item.id, name: item.album, type: "MusicAlbum", albumArtist: item.albumArtist))
        case "MusicArtist": LibraryView(item: item, artist: true)
        case "Series": SeriesView(item: item)
        case "CollectionFolder", "UserView", "Folder", "BoxSet": LibraryView(item: item)
        default: MovieView(item: item)
        }
    }
}

// MARK: - A library

struct LibraryView: View {
    let item: Item
    var artist = false
    @State private var items: [Item] = []
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 16) {
                ForEach(items) { Poster(item: $0, width: 110) }
            }
            .padding(16)
        }
        .navigationTitle(item.title)
        .page()
        .task {
            if artist {
                items = (try? await Api.items(["ArtistIds": item.id, "IncludeItemTypes": "MusicAlbum", "Recursive": true, "SortBy": "ProductionYear,SortName", "Limit": 500])) ?? []
            } else {
                items = (try? await Api.items(["ParentId": item.id, "SortBy": "SortName", "Limit": 500, "EnableImageTypes": "Primary", "ImageTypeLimit": 1])) ?? []
            }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @State private var libraries: [Item] = []
    @State private var resume: [Item] = []
    @State private var movies: [Item] = []
    @State private var shows: [Item] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                Shelf(title: "Libraries", items: libraries, width: 150)
                Shelf(title: "Continue Watching", items: resume, width: 150)
                Shelf(title: "Recently added movies", items: movies)
                Shelf(title: "Recently added shows", items: shows)
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Home")
        .page()
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        async let v = try? Api.views()
        async let r = try? Api.resume()
        async let m = try? Api.recent("Movie")
        async let s = try? Api.recent("Series")
        libraries = await v ?? libraries
        resume = await r ?? resume
        movies = await m ?? movies
        shows = await s ?? shows
    }
}

// MARK: - Music

struct MusicView: View {
    @State private var recent: [Item] = []
    @State private var playlists: [Item] = []
    @State private var albums: [Item] = []
    @State private var favourites: [Item] = []
    @State private var forYou: [Item] = []
    @Environment(PlayerModel.self) private var player

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                Menu {
                    Button("All songs") { Task { await shuffleAll() } }
                    Button("Favourite songs") { player.shuffle(favourites) }
                } label: {
                    HStack { Image(systemName: "shuffle"); Text("Shuffle"); Image(systemName: "chevron.down").font(.system(size: 11)) }
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent, in: Capsule())
                }
                .padding(.horizontal, 16)
                Shelf(title: "Quick Play", items: forYou)
                Shelf(title: "Recent albums", items: recent)
                Shelf(title: "Playlists", items: playlists)
                Shelf(title: "Albums", items: albums)
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("Music")
        .page()
        .refreshable { await load() }
        .task { await load() }
    }

    private func shuffleAll() async {
        if let s = try? await Api.items(["IncludeItemTypes": "Audio", "Recursive": true, "SortBy": "Random", "Limit": 100, "Fields": "RunTimeTicks,AlbumArtist"]) {
            player.play(s)
        }
    }

    private func load() async {
        async let r = Api.recentAlbums()
        async let p = Api.playlists()
        async let a = Api.albums()
        async let f = Api.favouriteSongs()
        async let y = Api.forYou()
        recent = await r
        playlists = await p
        albums = Array((await a).prefix(60))
        favourites = await f
        forYou = await y
    }
}

// MARK: - Album / playlist

struct SongListView: View {
    let item: Item
    @State private var songs: [Item] = []
    @Environment(PlayerModel.self) private var player

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Pic_(Pic.poster(item, h: 900), radius: 14).aspectRatio(1, contentMode: .fit)
                Text(item.title).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
                Text(item.type == "Playlist" ? "\(songs.count) songs" : [item.albumArtist, item.productionYear.map(String.init), "\(songs.count) songs"].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(Theme.dim)
                HStack(spacing: 10) {
                    Button { player.play(songs) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(Primary()).disabled(songs.isEmpty)
                    Button { player.addToQueue(songs) } label: { Image(systemName: "text.badge.plus").frame(width: 44, height: 44) }
                        .background(Theme.surfaceHi, in: Circle()).foregroundStyle(Theme.text)
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.system(size: 16)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(s.artistLine).font(.system(size: 12.5)).foregroundStyle(Theme.dim).lineLimit(1)
                            }
                            Spacer()
                            Text(timeText(s.seconds)).font(.system(size: 12.5)).foregroundStyle(Theme.dim).monospacedDigit()
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(songs, at: i) }
                        .contextMenu {
                            Button("Play next") { player.playNext(s) }
                            Button("Add to queue") { player.addToQueue([s]) }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .page()
        .task {
            if item.type == "Playlist" { songs = (try? await Api.playlistSongs(item.id)) ?? [] } else { songs = (try? await Api.albumSongs(item.id)) ?? [] }
        }
    }
}

// MARK: - Movies and shows

struct VideoPlayerView: View {
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear { PlayerModel.shared.pause(); player.play() }
            .onDisappear { player.pause() }
    }
}

struct MovieView: View {
    let item: Item
    @State private var full: Item?
    @State private var playing: URL?
    @State private var error = ""

    var body: some View {
        let it = full ?? item
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Pic_(Pic.backdrop(it, h: 720), radius: 14).aspectRatio(16.0 / 9.0, contentMode: .fit)
                Text(it.title).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
                Text([it.productionYear.map(String.init), it.officialRating, it.seconds > 0 ? "\(Int(it.seconds / 60)) min" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(Theme.dim)
                Button { Task { await start(it) } } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(Primary())
                if !error.isEmpty { Text(error).font(.system(size: 13)).foregroundStyle(.red) }
                if let o = it.overview { Text(o).font(.system(size: 15)).foregroundStyle(Theme.mid) }
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .page()
        .task { full = try? await Api.item(item.id) }
        .fullScreenCover(item: Binding(get: { playing.map { Wrap(url: $0) } }, set: { if $0 == nil { playing = nil } })) { VideoPlayerView(url: $0.url) }
    }

    struct Wrap: Identifiable { let url: URL; var id: String { url.absoluteString } }

    /// Asks the server how to play the title (direct, or its HLS transcode) and opens the player.
    private func start(_ it: Item) async {
        error = ""
        let profile: [String: Any] = [
            "Name": "JellyUI iOS", "MaxStreamingBitrate": 20_000_000, "MaxStaticBitrate": 20_000_000,
            "DirectPlayProfiles": [["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,mp3,ac3,eac3,alac,flac"]],
            "TranscodingProfiles": [["Container": "mp4", "Type": "Video", "AudioCodec": "aac,mp3,ac3,eac3", "VideoCodec": "h264,hevc", "Context": "Streaming", "Protocol": "hls", "MaxAudioChannels": "6", "MinSegments": 2, "BreakOnNonKeyFrames": true]],
            "SubtitleProfiles": [["Format": "vtt", "Method": "External"], ["Format": "srt", "Method": "External"]],
        ]
        do {
            let d = try await Api.request("/Items/\(it.id)/PlaybackInfo", query: ["userId": Api.uid, "maxStreamingBitrate": 20_000_000, "autoOpenLiveStream": true], method: "POST", body: ["DeviceProfile": profile])
            guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ms = (o["MediaSources"] as? [[String: Any]])?.first else { error = "This title can't be played."; return }
            if let t = ms["TranscodingUrl"] as? String, let u = Api.keyed(t, [:]) {
                // the server's path already has a query: add the key to it
                playing = u
            } else if let msId = ms["Id"] as? String, let u = Api.keyed("/Videos/\(it.id)/stream", ["static": true, "mediaSourceId": msId, "deviceId": Session.shared.deviceId, "PlaySessionId": o["PlaySessionId"] as? String]) {
                playing = u
            } else { error = "This title can't be played." }
        } catch { self.error = error.localizedDescription }
    }
}

struct SeriesView: View {
    let item: Item
    @State private var seasons: [Item] = []
    @State private var selected: Item?
    @State private var episodes: [Item] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Pic_(Pic.backdrop(item, h: 720), radius: 14).aspectRatio(16.0 / 9.0, contentMode: .fit)
                Text(item.title).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
                if let o = item.overview { Text(o).font(.system(size: 15)).foregroundStyle(Theme.mid) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(seasons) { s in
                            Button(s.title) { selected = s }
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(selected?.id == s.id ? Theme.accent : Theme.surfaceHi, in: Capsule())
                                .foregroundStyle(selected?.id == s.id ? Theme.onAccent : Theme.text)
                        }
                    }
                }
                ForEach(episodes) { e in
                    NavigationLink(value: e) {
                        HStack(alignment: .top, spacing: 12) {
                            Pic_(Pic.poster(e, h: 240), radius: 8).frame(width: 130, height: 73)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(e.indexNumber ?? 0). \(e.title)").font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(2)
                                if let o = e.overview { Text(o).font(.system(size: 12.5)).foregroundStyle(Theme.dim).lineLimit(3) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .page()
        .task {
            seasons = (try? await Api.seasons(item.id)) ?? []
            selected = seasons.first
        }
        .task(id: selected?.id) {
            guard let s = selected else { return }
            episodes = (try? await Api.episodes(item.id, season: s.id)) ?? []
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @State private var text = ""
    @State private var results: [Item] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 16) {
                ForEach(results) { Poster(item: $0, width: 110) }
            }
            .padding(16)
        }
        .navigationTitle("Search")
        .page()
        .searchable(text: $text, prompt: "Search")
        .task(id: text) {
            let q = text.trimmingCharacters(in: .whitespaces)
            if q.count < 2 { results = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            results = (try? await Api.search(q)) ?? []
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(Session.self) private var session
    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Signed in as", value: session.userName)
                LabeledContent("Server", value: session.server)
                Button("Sign out", role: .destructive) { PlayerModel.shared.stop(); session.signOut() }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        .page()
    }
}
