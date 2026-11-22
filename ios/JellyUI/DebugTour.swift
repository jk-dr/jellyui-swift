#if DEBUG
import SwiftUI

/// CI-only: signs in from launch environment and opens one screen, so the Simulator job can screenshot it.
/// `xcrun simctl launch` passes SIMCTL_CHILD_JUI_* as JUI_*. Never compiled into Release.
enum Tour {
    static let env = ProcessInfo.processInfo.environment
    static var route: String? { env["JUI_ROUTE"] }

    @MainActor static func signIn() async {
        guard !Session.shared.isSignedIn,
              let s = env["JUI_SERVER"], let u = env["JUI_USER"], let p = env["JUI_PASS"], !s.isEmpty else { return }
        try? await Api.login(base: Session.normalise(s), name: u, pw: p)
    }

    private static func first(_ kind: String) async -> Item? {
        try? await Api.items(["IncludeItemTypes": kind, "Recursive": true, "SortBy": "Random", "Limit": 1, "HasPrimaryImage": true]).first
    }

    @MainActor static func apply(nav: Nav, player: PlayerModel) async {
        guard let r = route else { return }
        try? await Task.sleep(for: .seconds(1))
        switch r {
        case "home": nav.tab = .home
        case "movies": nav.root(.movies)
        case "shows": nav.root(.shows)
        case "music": nav.root(.music)
        case "live": nav.root(.live)
        case "settings": nav.tab = .settings
        case "search": nav.searching = true
        case "movie": if let i = await first("Movie") { nav.go(.movie(i.id)) }
        case "show": if let i = await first("Series") { nav.go(.show(i.id)) }
        case "album": if let i = await first("MusicAlbum") { nav.go(.album(i.id)) }
        case "artist": if let i = await first("MusicArtist") { nav.go(.artist(i.id)) }
        case "playlist": if let i = await first("Playlist") { nav.go(.playlist(i.id)) }
        case "mini", "nowplaying", "lyrics", "queue":
            // a song that has lyrics if the server knows one, else any song
            let song = (try? await Api.items(["IncludeItemTypes": "Audio", "Recursive": true, "SortBy": "Random", "Limit": 1, "HasLyrics": true]).first) ?? nil
            var fallback: Item? = nil
            if song == nil { fallback = await first("Audio") }
            guard let s = song ?? fallback else { return }
            player.play([s])
            if r != "mini" { try? await Task.sleep(for: .seconds(1)); player.showFull = true }
            if r == "queue" { try? await Task.sleep(for: .seconds(2)); NotificationCenter.default.post(name: .tourQueue, object: nil) }
        default: break
        }
    }
}

extension Notification.Name { static let tourQueue = Notification.Name("tourQueue") }
#endif
