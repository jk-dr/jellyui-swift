import SwiftUI
import UIKit

// MARK: - Insets

enum Insets {
    static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }.first
    }
    static var top: CGFloat { window?.safeAreaInsets.top ?? 47 }
    static var bottom: CGFloat { window?.safeAreaInsets.bottom ?? 34 }
    static let bar: CGFloat = 58 // the bottom bar, above the home indicator
}

// MARK: - Navigation

enum Route: Hashable {
    case movie(String)
    case show(String)
    case album(String)
    case playlist(String)
    case artist(String)
    case genre(String)
    case service(String)
    case photos(String)
    case settings
}

/// What to play in the video player: a library item, or an on-demand title by its TMDB id.
struct PlayRequest: Identifiable, Hashable {
    var itemId: String?
    var tmdb: String?
    var live = false
    var id: String { itemId ?? ("tmdb-" + (tmdb ?? "")) }
}

enum RootTab: Hashable { case home, movies, shows, music, live }

@Observable
final class Nav {
    var tab: RootTab = .home
    var path: [Route] = []
    var searching = false
    var play: PlayRequest?

    func go(_ r: Route) { FrameMonitor.event("go", String(describing: r)); path.append(r) }
    func root(_ t: RootTab) { FrameMonitor.event("tab", String(describing: t)); path = []; tab = t }
    func back() { if !path.isEmpty { path.removeLast() } }
}

extension Item {
    var route: Route {
        switch type {
        case "Movie": return .movie(id)
        case "Series": return .show(id)
        case "Episode": return .show(seriesId ?? id)
        case "MusicAlbum": return .album(id)
        case "Playlist": return .playlist(id)
        case "Audio": return .album(albumId ?? id)
        case "MusicArtist": return .artist(id)
        default: return .photos(id)
        }
    }
}

// MARK: - The shell: header, bar, back, player bar

struct RootView: View {
    @Environment(PlayerModel.self) private var player
    @State private var nav = Nav()

    var body: some View {
        @Bindable var p = player
        @Bindable var n = nav
        ZStack {
            Color.bg.ignoresSafeArea()
            NavigationStack(path: $n.path) {
                rootPage
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: Route.self) { r in
                        destination(r).toolbar(.hidden, for: .navigationBar)
                    }
            }
            ShellOverlay()
            if p.showFull { NowPlaying().zIndex(20) }
            if nav.searching {
                SearchScreen().transition(.identity).zIndex(10)
            }
        }
        .environment(nav)
        .fullScreenCover(item: $n.play) { VideoScreen(request: $0) }
    }

    @ViewBuilder private var rootPage: some View {
        switch nav.tab {
        case .home: HomeScreen()
        case .movies: LibraryListScreen(kind: .movies)
        case .shows: LibraryListScreen(kind: .shows)
        case .music: MusicScreen()
        case .live: LiveScreen()
        }
    }

    @ViewBuilder private func destination(_ r: Route) -> some View {
        switch r {
        case .movie(let id): DetailScreen(id: id, show: false)
        case .show(let id): DetailScreen(id: id, show: true)
        case .album(let id): ListScreen(id: id, kind: .album)
        case .playlist(let id): ListScreen(id: id, kind: .playlist)
        case .artist(let id): ArtistScreen(id: id)
        case .genre(let id): CollectionScreen(id: id, service: false)
        case .service(let id): CollectionScreen(id: id, service: true)
        case .photos(let id): PhotosScreen(id: id)
        case .settings: SettingsScreen()
        }
    }
}

struct ShellOverlay: View {
    @Environment(Nav.self) private var nav
    @Environment(PlayerModel.self) private var player

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HeaderBar()
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
            if !nav.path.isEmpty { BackPill().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                MiniPlayer()
                BottomBar()
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

// MARK: Header

private let hints: [(text: String, types: [String])] = [
    ("What do you want to watch?", []),
    ("What do you want to listen to?", ["music"]),
    ("What do you want to read?", ["books"]),
    ("What do you want to stream?", ["livetv"]),
    ("What do you want to reminisce on?", ["homevideos", "photos"]),
]

struct HeaderBar: View {
    @Environment(Nav.self) private var nav
    @State private var n = 0
    @State private var types: [String] = []

    private var texts: [String] { hints.filter { $0.types.isEmpty || $0.types.contains { types.contains($0) } }.map { $0.text } }

    var body: some View {
        let top = Insets.top
        ZStack(alignment: .top) {
            LinearGradient(stops: [
                .init(color: Color(hex: 0x0c0c0e, alpha: 1), location: 0), .init(color: Color(hex: 0x0c0c0e, alpha: 0.97), location: 0.35),
                .init(color: Color(hex: 0x0c0c0e, alpha: 0.8), location: 0.55), .init(color: Color(hex: 0x0c0c0e, alpha: 0.45), location: 0.75),
                .init(color: Color(hex: 0x0c0c0e, alpha: 0.15), location: 0.9), .init(color: Color(hex: 0x0c0c0e, alpha: 0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 120 + top).allowsHitTesting(false)
            Button { withAnimation(.easeInOut(duration: 0.38)) { nav.searching = true } } label: {
                ZStack {
                    SVGPath(d: "M24 14a10 10 0 11-20 0 10 10 0 0120 0z M22 22l7 7", box: 32)
                        .stroke(Color(hex: 0x3e2222), style: StrokeStyle(lineWidth: 2.6, lineCap: .round)).frame(width: 22, height: 22)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 13)
                    HintText(texts: texts, n: n).padding(.horizontal, 44)
                }
                .frame(height: 48)
                .background(Color(hex: 0x1a1a1c), in: Capsule())
                .overlay(Capsule().stroke(Color(hex: 0x2a2a2d), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 10 + top)
        }
        .task {
            if let v = try? await Api.views() { types = v.compactMap { $0.collectionType } }
        }
        .task(id: texts.count) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if texts.count > 1 { n = (n + 1) % texts.count }
            }
        }
    }
}

/// The search bar's line that changes every 5 s: the old one slides up and out while the next rises from below.
private struct HintText: View {
    let texts: [String]
    let n: Int
    var body: some View {
        let text = texts.isEmpty ? hints[0].text : texts[n % texts.count]
        ZStack {
            Text(text).font(.q(16)).foregroundStyle(Color(hex: 0x8a5a5a)).lineLimit(1)
                .id(text)
                .transition(.asymmetric(insertion: .offset(y: 22).combined(with: .opacity), removal: .offset(y: -22).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity).clipped()
        .animation(.easeOut(duration: 0.65), value: text)
    }
}

// MARK: Back pill

struct BackPill: View {
    @Environment(Nav.self) private var nav
    var body: some View {
        Button { nav.back() } label: {
            HStack(spacing: 6) {
                Icon(name: "back", size: 20, color: .pink)
                Text("Back").font(.q(15)).foregroundStyle(Color.pink)
            }
            .padding(.vertical, 6).padding(.leading, 10).padding(.trailing, 14)
            .background(Color(hex: 0x16161a), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.leading, 16).padding(.top, 84 + Insets.top)
    }
}

// MARK: Bottom bar

struct BottomBar: View {
    @Environment(Nav.self) private var nav

    private var on: String {
        if nav.path.last == .settings { return "settings" }
        if !nav.path.isEmpty { return "" }
        switch nav.tab {
        case .home: return "home"
        default: return "libs"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            item("home", "Home", "home") { nav.root(.home) }
            Menu {
                Button { nav.root(.shows) } label: { Label("TV Shows", systemImage: "play.rectangle") }
                Button { nav.root(.movies) } label: { Label("Movies", systemImage: "film") }
                Button { nav.root(.music) } label: { Label("Music", systemImage: "music.note") }
                Button { nav.root(.live) } label: { Label("Live TV", systemImage: "tv") }
            } label: { face("libs", "Libraries", "libraries") }
            item("settings", "Settings", "settings") { if nav.path.last != .settings { nav.go(.settings) } }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, Insets.bottom)
        .frame(height: Insets.bar + Insets.bottom)
        .background(.ultraThinMaterial.opacity(0.9))
        .background(Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255).opacity(0.9))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
    }

    private func item(_ key: String, _ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { face(key, label, icon) }.buttonStyle(.plain)
    }

    private func face(_ key: String, _ label: String, _ icon: String) -> some View {
        let col: Color = on == key ? .pink : Color(hex: 0x9a9aa0)
        return VStack(spacing: 2) {
            Icon(name: icon, size: 24, color: col)
            Text(label).font(.q(11)).foregroundStyle(col)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - Page scaffolding

/// A scrolling page that starts under the header and ends above the bar and the player bar.
struct Page<Content: View>: View {
    var refresh: (() async -> Void)?
    @ViewBuilder var content: () -> Content
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let scroll = ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Insets.top)
                content()
                Color.clear.frame(height: Insets.bar + Insets.bottom + (player.current != nil ? 156 : 0) + 16)
            }
        }
        Group {
            if let refresh { scroll.refreshable { await refresh() } } else { scroll }
        }
        .ignoresSafeArea()
        .background(Color.bg.ignoresSafeArea())
    }
}

extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}
