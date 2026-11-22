import SwiftUI
import UIKit

// MARK: - Insets

enum Insets {
    static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }.first
    }
    static var top: CGFloat { window?.safeAreaInsets.top ?? 62 }
    static var bottom: CGFloat { window?.safeAreaInsets.bottom ?? 34 }
    static let mini: CGFloat = 88 // the floating player bar (one row, no progress) and its gap
    /// the native tab bar's height above the home indicator (iOS 26 floating glass bar)
    static let bar: CGFloat = 56
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

/// The three native tabs. The web's "Libraries" menu becomes one tab whose page title switches library.
enum RootTab: Hashable { case home, libraries, settings }

enum Lib: String, CaseIterable, Hashable {
    case shows, movies, music, live
    var title: String {
        switch self { case .shows: "TV Shows"; case .movies: "Movies"; case .music: "Music"; case .live: "Live TV" }
    }
    var icon: String {
        switch self { case .shows: "play.rectangle"; case .movies: "film"; case .music: "music.note"; case .live: "tv" }
    }
    static func titled(_ s: String) -> Lib? { allCases.first { $0.title == s } }
}

@Observable
final class Nav {
    var tab: RootTab = .home
    var lib: Lib = Lib(rawValue: UserDefaults.standard.string(forKey: "nav.lib") ?? "") ?? .music {
        didSet { UserDefaults.standard.set(lib.rawValue, forKey: "nav.lib") }
    }
    var paths: [RootTab: [Route]] = [.home: [], .libraries: [], .settings: []]
    var searching = false
    var searchBase = 0
    var play: PlayRequest?

    /// the open tab's stack
    var path: [Route] {
        get { paths[tab] ?? [] }
        set { paths[tab] = newValue }
    }

    func go(_ r: Route) {
        FrameMonitor.event("go", String(describing: r))
        if r == .settings { tab = .settings; paths[.settings] = []; return }
        path.append(r)
    }
    /// open a library in the Libraries tab, at its root
    func root(_ l: Lib) { FrameMonitor.event("lib", l.rawValue); lib = l; paths[.libraries] = []; tab = .libraries }
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

// MARK: - The shell: native glass tab bar, header, back, player bar

struct RootView: View {
    @Environment(PlayerModel.self) private var player
    @State private var nav = Nav()

    var body: some View {
        @Bindable var p = player
        @Bindable var n = nav
        ZStack {
            Color.bg.ignoresSafeArea()
            TabView(selection: $n.tab) {
                Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                    TabStack(tab: .home) { HomeScreen() }
                }
                Tab("Libraries", systemImage: "books.vertical.fill", value: RootTab.libraries) {
                    TabStack(tab: .libraries) { LibraryRoot() }
                }
                Tab("Settings", systemImage: "gearshape.fill", value: RootTab.settings) {
                    TabStack(tab: .settings) { SettingsScreen() }
                }
            }
            .tint(Color.pink)
            if nav.searching { SearchLayer().zIndex(10) }
        }
        .overlay { if p.showFull { NowPlaying().ignoresSafeArea() } }
        .environment(nav)
        .modifier(ConfirmHost())
        // a full-screen cover does not inherit the environment: the film's screen read Nav and crashed
        .fullScreenCover(item: $n.play) { VideoScreen(request: $0).environment(nav).environment(player) }
        #if DEBUG
        .task { await Tour.apply(nav: nav, player: player) }
        #endif
    }
}

/// The search screen over the tabs. A result pushed from it is hidden, not removed, until Back brings the search back.
private struct SearchLayer: View {
    @Environment(Nav.self) private var nav
    var body: some View {
        let shown = nav.path.count == nav.searchBase
        SearchScreen().transition(.identity)
            .opacity(shown ? 1 : 0).allowsHitTesting(shown)
    }
}

/// One tab: its own navigation stack, the header and Back pill over it, and the player bar above the tab bar.
private struct TabStack<Root: View>: View {
    let tab: RootTab
    @ViewBuilder var root: () -> Root
    @Environment(Nav.self) private var nav

    var body: some View {
        let path = Binding<[Route]>(get: { nav.paths[tab] ?? [] }, set: { nav.paths[tab] = $0 })
        NavigationStack(path: path) {
            root()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { r in
                    Destination(route: r).toolbar(.hidden, for: .navigationBar)
                }
        }
        .overlay(alignment: .top) { TabHeader(tab: tab) }
        .overlay(alignment: .bottom) { MiniSlot() } // pages make their own room for it (PageEnd)
    }
}

/// The header and Back pill of one tab. Only this reads the tab's stack, so a push does not redraw the tab's page.
private struct TabHeader: View {
    let tab: RootTab
    @Environment(Nav.self) private var nav
    var body: some View {
        ZStack(alignment: .topLeading) {
            HeaderBar()
            if !(nav.paths[tab] ?? []).isEmpty { BackPill() }
        }
    }
}

/// The room after a page's last row: more while the player bar floats over the bottom, so the last rows can be scrolled clear of it.
struct PageEnd: View {
    @Environment(PlayerModel.self) private var player
    var body: some View { Color.clear.frame(height: player.current != nil ? 16 + Insets.mini : 16) }
}

/// The player bar. Its own view, so a song change does not redraw the tab's page.
private struct MiniSlot: View {
    @Environment(PlayerModel.self) private var player
    var body: some View {
        if player.current != nil { MiniPlayer().padding(.bottom, 6) }
    }
}

private struct Destination: View {
    let route: Route
    var body: some View {
        switch route {
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

/// The Libraries tab: the library last chosen (its title is a native menu to switch).
/// Every library stays mounted once visited, so switching back is instant and keeps its scroll.
struct LibraryRoot: View {
    @Environment(Nav.self) private var nav
    @State private var visited: Set<Lib> = []

    var body: some View {
        ZStack {
            ForEach(Lib.allCases, id: \.self) { l in
                if visited.contains(l) || nav.lib == l {
                    page(l).opacity(nav.lib == l ? 1 : 0).allowsHitTesting(nav.lib == l).zIndex(nav.lib == l ? 1 : 0)
                }
            }
        }
        .onAppear { visited.insert(nav.lib) }
        .onChange(of: nav.lib) { _, l in visited.insert(l) }
    }

    @ViewBuilder private func page(_ l: Lib) -> some View {
        switch l {
        case .movies: LibraryListScreen(kind: .movies)
        case .shows: LibraryListScreen(kind: .shows)
        case .music: MusicScreen()
        case .live: LiveScreen()
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
        let back = !nav.path.isEmpty
        ZStack(alignment: .top) {
            LinearGradient(stops: [
                .init(color: Color(hex: 0x0c0c0e, alpha: 1), location: 0), .init(color: Color(hex: 0x0c0c0e, alpha: 0.97), location: 0.35),
                .init(color: Color(hex: 0x0c0c0e, alpha: 0.8), location: 0.55), .init(color: Color(hex: 0x0c0c0e, alpha: 0.45), location: 0.75),
                .init(color: Color(hex: 0x0c0c0e, alpha: 0.15), location: 0.9), .init(color: Color(hex: 0x0c0c0e, alpha: 0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 96 + top).allowsHitTesting(false)
            Button { nav.searchBase = nav.path.count; withAnimation(.easeInOut(duration: 0.38)) { nav.searching = true } } label: {
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
            // on a pushed page the web puts the round back button left of the search bar
            .padding(.leading, back ? 16 + 44 + 10 : 16).padding(.trailing, 16).padding(.top, 8 + top)
            .animation(.easeOut(duration: 0.2), value: back)
        }
        .ignoresSafeArea(edges: .top)
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

// MARK: Back button

/// The web's round back button: a 44 pt circle left of the search bar on pushed pages.
struct BackPill: View {
    @Environment(Nav.self) private var nav
    var body: some View {
        Button { nav.back() } label: {
            Icon(name: "back", size: 20, color: .pink)
                .frame(width: 44, height: 44)
                .background(Color(hex: 0x1a1a1c), in: Circle())
                .overlay(Circle().stroke(Color(hex: 0x2a2a2d), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .padding(.leading, 16).padding(.top, 10 + Insets.top)
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Page scaffolding

/// A scrolling page that starts under the header. The bottom follows the safe area (tab bar and player bar).
struct Page<Content: View>: View {
    var refresh: (() async -> Void)?
    var bg: Color = .bg
    @ViewBuilder var content: () -> Content

    var body: some View {
        let scroll = ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Insets.top)
                content()
                PageEnd()
            }
        }
        Group {
            if let refresh { scroll.refreshable { await refresh() } } else { scroll }
        }
        .ignoresSafeArea(edges: .top)
        .background(bg.ignoresSafeArea())
    }
}

/// The library page title. On the Libraries tab it is a native menu that switches library.
struct LibrarySwitcher: View {
    let lib: Lib
    @Environment(Nav.self) private var nav
    var body: some View {
        Menu {
            Picker("Library", selection: Binding(get: { nav.lib }, set: { nav.root($0) })) {
                ForEach(Lib.allCases, id: \.self) { l in Label(l.title, systemImage: l.icon).tag(l) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(lib.title).font(.q(36)).foregroundStyle(Color.pink)
                Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.pink.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }
}

extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}
