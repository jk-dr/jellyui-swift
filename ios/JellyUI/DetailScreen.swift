import SwiftUI

/// One shape for a library item and a Seerr title.
struct DModel {
    var jf: String?
    var tmdb: String?
    var title: String
    var year: String?
    var runtime: String? // movies: minutes; shows: "3 seasons"
    var age: String?
    var score: Double?
    var genres: [String] = []
    var overview: String?
    var tagline: String?
    var director: String?
    var dirLabel: String
    var cast: [CastPerson] = []
    var poster: URL?
    var pct: Double = 0
    var left: Int = 0
    var trailer: String?
    var fav = false
    var inLib = false
    var canDelete = false
    var canPlayNow: Bool?
    var status: Int?
    var hasSeerr: Bool?
    var seasons: [TitleData.TSeason]?
}

struct CastPerson: Hashable { var name: String; var role: String?; var img: URL? }

private func runtimeText(_ min: Int) -> String { min >= 60 ? "\(min / 60)h \(min % 60)m" : "\(min)m" }

private func fromJf(_ it: Item, show: Bool) -> DModel {
    let ppl = it.people ?? []
    let dir = ppl.filter { $0.type == "Director" || $0.type == "Creator" }.compactMap { $0.name }.prefix(2).joined(separator: ", ")
    let pos = it.userData?.playbackPositionTicks ?? 0
    let total = it.runTimeTicks ?? 0
    let pct = total > 0 && pos > 0 ? Double(pos) / Double(total) * 100 : 0
    let mins = total > 0 ? Int((Double(total) / 600_000_000).rounded()) : 0
    return DModel(
        jf: it.id, tmdb: it.providerIds?["tmdb"], title: it.title, year: it.productionYear.map(String.init),
        runtime: show ? ((it.childCount ?? 0) > 0 ? "\(it.childCount!) \(it.childCount == 1 ? "season" : "seasons")" : "") : (mins > 0 ? String(mins) : nil),
        age: it.officialRating, score: it.communityRating, genres: it.genres ?? [], overview: it.overview, director: dir,
        dirLabel: show ? "Created by" : "Director",
        cast: ppl.filter { $0.type == "Actor" }.prefix(14).map { CastPerson(name: $0.name ?? "", role: $0.role, img: Pic.person($0)) },
        poster: Pic.poster(it, h: 600), pct: pct > 1 && pct < 95 ? pct : 0,
        left: total > 0 && pos > 0 ? Int((Double(total - pos) / 600_000_000).rounded()) : 0,
        trailer: it.remoteTrailers?.first?.url.flatMap { $0.lowercased().hasPrefix("http") ? $0 : nil },
        fav: it.userData?.isFavorite ?? false, inLib: true, canDelete: it.canDelete ?? false)
}

private func fromSeerr(_ t: TitleData, show: Bool) -> DModel {
    DModel(
        jf: t.jellyfinId, tmdb: t.tmdb, title: t.title ?? "", year: t.year,
        runtime: show ? ((t.seasons ?? []).isEmpty ? "" : "\(t.seasons!.count) \(t.seasons!.count == 1 ? "season" : "seasons")") : t.runtime,
        age: t.age, score: t.score, genres: t.genres ?? [], overview: t.overview, tagline: t.tagline, director: t.director,
        dirLabel: show ? "Created by" : "Director",
        cast: (t.cast ?? []).map { CastPerson(name: $0.name ?? "", role: $0.role, img: Pic.tmdb($0.photo, "w185")) },
        poster: Pic.tmdb(t.poster, "w342"), trailer: t.trailer.map { "https://www.youtube.com/watch?v=\($0)" },
        canPlayNow: t.canPlayNow, status: t.seerrStatus, hasSeerr: t.hasSeerrUser, seasons: t.seasons)
}

struct DetailScreen: View {
    let id: String
    let show: Bool
    @Environment(Nav.self) private var nav
    @Environment(Session.self) private var session
    @State private var item: Item?
    @State private var title: TitleData?
    @State private var error: String?
    @State private var favOverride: Bool?
    @State private var reqSent = false
    @State private var reqBusy = false
    @State private var reqErr = ""
    @State private var delBusy = false
    @State private var confirmDelete = false
    @State private var redirected = false
    @State private var next: Item?
    @State private var first: Item?
    @State private var nextLoaded = false
    @State private var waiting = false

    private var tmdbParam: String { id.hasPrefix("tmdb-") ? String(id.dropFirst(5)) : "" }

    var body: some View {
        let model: DModel? = item.map { fromJf($0, show: show) } ?? ((title != nil && title?.jellyfinId == nil) ? fromSeerr(title!, show: show) : nil)
        Page {
            if let m = model { content(m) }
            else if let e = error { Note(e, error: true).padding(.top, 130) }
            else { ProgressView().tint(Color.dimText).frame(maxWidth: .infinity).padding(.top, 200) }
        }
        .task(id: id) { if item == nil && title == nil { await load() } }
        .onChange(of: nav.play) { _, n in if n == nil && item != nil { Task { await load() } } }
        .task(id: model?.tmdb) { await pollDownload(model) }
        .alert("Delete “\(model?.title ?? "")”?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await delete(model) } }
        } message: { Text("This removes \(show ? "the show and all its episodes" : "the movie") and its files for everyone, stops any download, and stops anyone who is watching it right now.") }
    }

    // MARK: content

    @ViewBuilder private func content(_ m: DModel) -> some View {
        let fav = favOverride ?? m.fav
        let asked = reqSent || m.status == 2 || m.status == 3 || m.status == 4
        VStack(spacing: 16) {
            // the phone page: room for the Back button, then a centred poster and the text under it
            Group {
                if let p = m.poster { Pic_(p, radius: 10) } else {
                    Color(hex: 0x181818).overlay(Text(String(m.title.prefix(1))).font(.q(44)).foregroundStyle(Color(hex: 0x6a6a70)))
                }
            }
            .frame(width: 150, height: 225).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(spacing: 0) {
                Text(m.title).font(.q(28)).foregroundStyle(Color.pink).multilineTextAlignment(.center).shadow(color: .black, radius: 4, y: 1)
                    .frame(maxWidth: .infinity)
                WrapCentered(spacing: 10) {
                    if let y = m.year { Text(y).font(.q(14)).foregroundStyle(Color.midText) }
                    if let r = m.runtime, !r.isEmpty { Text(show ? r : (Int(r).map(runtimeText) ?? r)).font(.q(14)).foregroundStyle(Color.midText) }
                    if let a = m.age { Text(a).font(.q(12)).foregroundStyle(Color.midText).padding(.horizontal, 5).overlay(RoundedRectangle(cornerRadius: 3.6).stroke(Color(hex: 0x4a4a50), lineWidth: 1)) }
                    if let s = m.score, s > 0 { Text("★ \(String(format: "%.1f", s))").font(.q(14)).foregroundStyle(Color.pink) }
                    HStack(spacing: 5) {
                        Icon(name: show ? "tv" : "reel", size: 14, color: Color(hex: 0xf2f2f2))
                        Text(show ? "TV SHOW" : "MOVIE").font(.system(size: 11, weight: .bold)).tracking(0.9).foregroundStyle(Color(hex: 0xf2f2f2))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 1).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.top, 8)
                if !m.genres.isEmpty { Text(m.genres.joined(separator: " · ")).font(.q(13)).foregroundStyle(Color.dimText).multilineTextAlignment(.center).padding(.top, 6) }
                if let o = m.overview ?? m.tagline { Text(o).font(.q(15)).foregroundStyle(Color(hex: 0xd4d4d4)).lineSpacing(3).padding(.top, 14).frame(maxWidth: .infinity, alignment: .leading) }
                if let d = m.director, !d.isEmpty {
                    (Text("\(m.dirLabel) ").foregroundStyle(Color.dimText) + Text(d).foregroundStyle(Color.midText)).font(.q(13)).padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 84 + 32 + 16)

        VStack(alignment: .leading, spacing: 0) {
            if m.pct > 0 {
                Text("\(m.left) min left").font(.q(14)).foregroundStyle(Color.dimText).padding(.top, 22)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    GeometryReader { g in Capsule().fill(Color.pink).frame(width: g.size.width * min(1, m.pct / 100)) }
                }.frame(height: 8).padding(.top, 6)
            }
            VStack(spacing: 10) {
                playButton(m, asked: asked)
                let extra = extras(m, fav: fav)
                if !extra.isEmpty { ActionRow(items: extra) }
            }
            .padding(.top, 14)
            let hint = hintText(m, asked: asked)
            if !hint.isEmpty || !reqErr.isEmpty {
                Text(reqErr.isEmpty ? hint : reqErr).font(.q(14)).foregroundStyle(reqErr.isEmpty ? Color(hex: 0xa9a9a9) : Color.danger).padding(.top, 10)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)

        if show { SeasonsView(m: m) }

        if !m.cast.isEmpty || !(m.director ?? "").isEmpty {
            let crew: [CastPerson] = ((m.director ?? "").isEmpty ? [] : [CastPerson(name: String(m.director!.split(separator: ",").first ?? ""), role: m.dirLabel == "Created by" ? "Creator" : "Director", img: nil)]) + m.cast
            H2("Cast & Crew")
            HRow(height: 150) { ForEach(Array(crew.enumerated()), id: \.offset) { _, c in CastCard(c: c) } }
        }
    }

    private func extras(_ m: DModel, fav: Bool) -> [Act] {
        var out: [Act] = []
        if let t = m.trailer, let u = URL(string: t) { out.append(Act(id: "trailer", icon: "trailer", label: "Trailer", action: { UIApplication.shared.open(u) })) }
        if m.inLib, let jf = m.jf {
            out.append(Act(id: "fav", icon: "heart", label: fav ? "Remove from favourites" : "Add to favourites", iconOnly: true, action: {
                let on = !fav
                favOverride = on
                Task { await Api.setFavourite(jf, on) }
            }))
        }
        if m.canDelete && session.isAdmin { out.append(Act(id: "del", icon: "trash", label: delBusy ? "Deleting…" : "Delete", kind: .danger, busy: delBusy, action: { confirmDelete = true })) }
        return out
    }

    private func hintText(_ m: DModel, asked: Bool) -> String {
        if m.inLib { return "" }
        if !show && m.canPlayNow == true { return "Not in your library yet. It starts streaming as it downloads." }
        if m.hasSeerr == false { return "Sign in to Seerr once with this account to request titles." }
        if asked { return "Requested. It will appear in your library when it is ready." }
        return show ? "Shows are request only. Every season is requested." : "Your account can request this movie."
    }

    @ViewBuilder private func playButton(_ m: DModel, asked: Bool) -> some View {
        if m.inLib, let jf = m.jf {
            if show {
                let nu = next ?? first
                let label = (nu?.userData?.playbackPositionTicks ?? 0) > 0 ? "Resume" : "Play"
                Btn(label: label, icon: "play", kind: .primary, disabled: nu == nil) { if let nu { nav.play = PlayRequest(itemId: nu.id) } }
            } else {
                Btn(label: waiting ? "Wait for download" : (m.pct > 0 ? "Resume" : "Play"), icon: "play", kind: .primary) { nav.play = PlayRequest(itemId: jf) }
            }
        } else if !show, m.canPlayNow == true, let t = m.tmdb {
            Btn(label: waiting ? "Wait for download" : "Play now", icon: "play", kind: .primary) { nav.play = PlayRequest(tmdb: t) }
        } else {
            Btn(label: asked ? "Requested" : "Request", kind: .primary, busy: reqBusy, disabled: asked || m.hasSeerr == false || m.tmdb == nil) {
                Task { await request(m) }
            }
        }
    }

    // MARK: loading and actions

    private func load() async {
        error = nil
        if !tmdbParam.isEmpty {
            do {
                let t = try await Plugin.title(show ? "tv" : "movie", tmdbParam)
                // a Seerr title that is in the library after all: open the library page instead
                if let jf = t.jellyfinId, !redirected {
                    redirected = true
                    nav.path.removeLast()
                    nav.go(show ? .show(jf) : .movie(jf))
                    return
                }
                title = t
            } catch { self.error = (error as? ApiError)?.status == 404 ? "Not found" : error.localizedDescription }
        } else {
            do {
                let it = try await Api.item(id)
                let tm = it.providerIds?["tmdb"]
                // a library movie that is only an on-demand stub: open the title page
                if !show, it.mediaSources == nil, let tm, !redirected {
                    redirected = true
                    nav.path.removeLast()
                    nav.go(.movie("tmdb-" + tm))
                    return
                }
                item = it
                if show { await loadNext(it.id) }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func loadNext(_ id: String) async {
        let r: ItemsResult? = try? await Api.get("/Shows/NextUp", ["userId": Api.uid, "seriesId": id, "limit": 1])
        next = r?.items.first
        if next == nil {
            // nothing "up next": play from the first episode
            if let s = try? await Api.seasons(id), let sid = s.first?.id, let eps = try? await Api.episodes(id, season: sid) { first = eps.first }
        }
        nextLoaded = true
    }

    private func pollDownload(_ m: DModel?) async {
        guard !show, let tmdb = m?.tmdb, (m?.inLib ?? false) || (m?.canPlayNow ?? false) else { return }
        let names = ["Requested", "Grabbing", "Preparing", "Streaming", "Downloading", "InLibrary", "Failed", "Cancelled"]
        while !Task.isCancelled {
            if let r = await Plugin.onDemandStatus(tmdb) {
                let low = Dictionary(r.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
                let st: String = (low["status"] as? Int).flatMap { names.indices.contains($0) ? names[$0] : nil } ?? (low["status"] as? String) ?? ""
                let gate = (low["gate"] as? [String: Any])?.first { $0.key.lowercased() == "open" }?.value as? Bool ?? false
                waiting = ["Requested", "Grabbing", "Preparing", "Streaming", "Downloading"].contains(st) && !gate
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func request(_ m: DModel) async {
        guard let t = m.tmdb, let n = Int(t) else { return }
        reqBusy = true; reqErr = ""
        defer { reqBusy = false }
        do { try await Plugin.request(show ? "tv" : "movie", n); reqSent = true } catch { reqErr = error.localizedDescription }
    }

    private func delete(_ m: DModel?) async {
        guard let jf = m?.jf else { return }
        delBusy = true
        do { try await Plugin.deleteItem(jf); Mem.clear(); nav.back() } catch { delBusy = false; reqErr = error.localizedDescription }
    }
}

extension Session {
    var isAdmin: Bool { UserDefaults.standard.bool(forKey: "admin") }
}

/// Items wrap onto new lines and each line is centred (the web's flex-wrap + justify centre).
struct WrapCentered: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 4
    private func rows(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        let maxW = proposal.width ?? 300
        var out: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { out.append([]); x = 0 }
            out[out.count - 1].append((i, sz)); x += sz.width + spacing
        }
        return out
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = rows(proposal, subviews)
        let h = r.reduce(0) { $0 + ($1.map { $0.1.height }.max() ?? 0) } + lineSpacing * CGFloat(max(0, r.count - 1))
        return CGSize(width: proposal.width ?? 300, height: h)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = b.minY
        for row in rows(proposal, subviews) {
            let w = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(row.count - 1)
            let h = row.map { $0.1.height }.max() ?? 0
            var x = b.minX + (b.width - w) / 2
            for (i, sz) in row { subviews[i].place(at: CGPoint(x: x, y: y + (h - sz.height) / 2), anchor: .topLeading, proposal: ProposedViewSize(sz)); x += sz.width + spacing }
            y += h + lineSpacing
        }
    }
}

struct CastCard: View {
    let c: CastPerson
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let u = c.img { Pic_(u, radius: 32) } else {
                    Color.surfaceHi.overlay(Text(String(c.name.prefix(1))).font(.q(26)).foregroundStyle(Color.pink))
                }
            }
            .frame(width: 64, height: 64).clipShape(Circle()).padding(.bottom, 5)
            Text(c.name).font(.q(12)).foregroundStyle(Color(hex: 0xd4d4d4)).multilineTextAlignment(.center).lineLimit(2)
            if let r = c.role { Text(r).font(.q(11)).foregroundStyle(Color.dimText).lineLimit(1) }
        }
        .padding(6).frame(width: 92)
    }
}

// MARK: - Seasons and episodes

struct Ep: Identifiable, Hashable {
    var id: String
    var jf: String?
    var n: Int?
    var name: String
    var overview: String?
    var min: Int?
    var pct: Double
    var img: URL?
}

struct SeasonsView: View {
    let m: DModel
    @Environment(Nav.self) private var nav
    @State private var seasons: [(id: String, name: String, n: Int?)] = []
    @State private var picked: Int?
    @State private var eps: [Ep] = []
    @State private var loading = true
    @State private var open = false
    @State private var startIdx = 0
    @State private var err: String?

    private var lib: Bool { m.inLib && m.jf != nil }

    var body: some View {
        let cur = picked ?? startIdx
        VStack(alignment: .leading, spacing: 0) {
            if !seasons.isEmpty {
                HStack(spacing: 12) {
                    Button { open = true } label: {
                        HStack(spacing: 4) {
                            Text(seasons.indices.contains(cur) ? seasons[cur].name : "").font(.q(15)).foregroundStyle(Color.pink)
                            Icon(name: "chevronDown", size: 20, color: .white)
                        }
                        .padding(.leading, 16).padding(.trailing, 10).frame(height: 40)
                        .background(Color.surfaceHi, in: Capsule())
                    }.buttonStyle(.plain)
                    Text(loading ? "" : "\(eps.count) \(eps.count == 1 ? "episode" : "episodes")").font(.q(13)).foregroundStyle(Color.dimText)
                }
                .padding(.top, 26).padding(.leading, 16).padding(.bottom, 12)
                if loading {
                    VStack(spacing: 12) { ForEach(0..<3, id: \.self) { _ in Skeleton(height: 84) } }.padding(.horizontal, 16)
                } else if let e = err {
                    Note(e, error: true)
                } else if eps.isEmpty {
                    Note("No episodes listed.")
                } else {
                    ForEach(eps) { ep in EpisodeRow(ep: ep) { if let id = ep.jf { nav.play = PlayRequest(itemId: id) } } }
                }
            } else if !loading {
                if lib { Note("No seasons in the library yet.") }
            }
        }
        .padding(.top, 16)
        .task { await loadSeasons() }
        .task(id: cur + (seasons.count << 8)) { await loadEpisodes(cur) }
        .sheet(isPresented: $open) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(seasons.enumerated()), id: \.offset) { i, s in
                        Button { picked = i; open = false } label: {
                            Text(s.name).font(.q(16)).foregroundStyle(i == cur ? Color.pink : Color.pink.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14).padding(.horizontal, 24)
                                .background(i == cur ? Color.white.opacity(0.1) : .clear)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .presentationDetents([.medium]).presentationBackground(Color(hex: 0x121214))
        }
    }

    private func loadSeasons() async {
        if lib, let jf = m.jf {
            let s = (try? await Api.seasons(jf)) ?? []
            seasons = s.map { ($0.id, $0.title, $0.indexNumber) }
            // start at the season of the episode that is up next
            let nu: ItemsResult? = try? await Api.get("/Shows/NextUp", ["userId": Api.uid, "seriesId": jf, "limit": 1])
            if let sid = nu?.items.first?.seasonId, let i = s.firstIndex(where: { $0.id == sid }) { startIdx = i }
        } else {
            seasons = (m.seasons ?? []).map { (String($0.n), $0.name ?? "Season \($0.n)", $0.n) }
        }
        if seasons.isEmpty { loading = false }
    }

    private func loadEpisodes(_ cur: Int) async {
        guard seasons.indices.contains(cur) else { return }
        let s = seasons[cur]
        loading = true; err = nil
        defer { loading = false }
        if lib, let jf = m.jf {
            let r = (try? await Api.episodes(jf, season: s.id)) ?? []
            eps = r.map { ep in
                let pos = ep.userData?.playbackPositionTicks ?? 0
                let total = ep.runTimeTicks ?? 0
                let pct = ep.userData?.played == true ? 100 : (total > 0 && pos > 0 ? Double(pos) / Double(total) * 100 : 0)
                return Ep(id: ep.id, jf: ep.id, n: ep.indexNumber, name: ep.title, overview: ep.overview, min: total > 0 ? Int((Double(total) / 600_000_000).rounded()) : nil, pct: pct, img: Pic.episodeThumb(ep))
            }
        } else if let t = m.tmdb, let n = s.n {
            let r = await Plugin.season(t, n)
            eps = r.map { e in
                let num = (e["n"] as? Int) ?? 0
                return Ep(id: String(num), jf: nil, n: num, name: e["name"] as? String ?? "", overview: e["overview"] as? String, min: e["runtime"] as? Int, pct: 0, img: Pic.tmdb(e["still"] as? String, "w300"))
            }
        }
    }
}

struct EpisodeRow: View {
    let ep: Ep
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Color(hex: 0x18181c)
                    if let u = ep.img { Pic_(u, radius: 0) }
                    if ep.jf != nil {
                        Icon(name: "play", size: 22, color: .white).frame(width: 34, height: 34).background(Color.black.opacity(0.55), in: Circle())
                    } else if let n = ep.n { Text(String(n)).font(.q(26)).foregroundStyle(Color(hex: 0x34343a)) }
                }
                .frame(width: 112, height: 63).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(ep.n.map { "\($0). " } ?? "")\(ep.name)").font(.q(15)).foregroundStyle(Color(hex: 0xe6e6e6)).lineLimit(1)
                    Text(ep.overview ?? "").font(.q(12)).foregroundStyle(Color.dimText).lineLimit(2).padding(.top, 2)
                    if ep.pct > 0 {
                        // the whole length of the episode, with the part already watched filled, so what is left shows
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.22))
                            GeometryReader { g in Capsule().fill(Color.pink).frame(width: g.size.width * min(1, ep.pct / 100)) }
                        }.frame(height: 5).padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let m = ep.min { Text("\(m) min").font(.q(12)).foregroundStyle(Color.dimText) }
            }
            .padding(8).padding(.horizontal, 8)
        }
        .buttonStyle(PressStyle()).disabled(ep.jf == nil)
    }
}

extension Pic {
    static func person(_ p: Person) -> URL? {
        guard let t = p.primaryImageTag else { return nil }
        return Api.url("/Items/\(p.id)/Images/Primary", ["maxHeight": 240, "quality": 85, "tag": t])
    }
    static func episodeThumb(_ it: Item, h: Int = 240) -> URL? {
        guard let t = it.imageTags?["primary"] else { return nil }
        return Api.url("/Items/\(it.id)/Images/Primary", ["maxHeight": h, "quality": 85, "tag": t])
    }
}
