import SwiftUI
import UIKit

extension Api {
    static func suggestions(_ kind: String, limit: Int = 8) async -> [Item] {
        ((try? await get("/Items/Suggestions", ["userId": uid, "type": kind, "limit": limit, "enableTotalRecordCount": false]) as ItemsResult)?.items) ?? []
    }
}

/// The page title the web shows: 36 pink, left, under the search bar, with a shadow.
/// On the Libraries tab a library's title is the native menu that switches library.
struct PageTitle: View {
    let text: String
    var top: CGFloat = 66
    @Environment(Nav.self) private var nav
    var body: some View {
        Group {
            if nav.tab == .libraries, nav.path.isEmpty, let l = Lib.titled(text) { LibrarySwitcher(lib: l) }
            else { Text(text).font(.q(36)).foregroundStyle(Color.pink) }
        }
        .shadow(color: .black, radius: 4, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, top)
    }
}

/// The web's numbered pages: Previous, 1 … n … last, Next.
struct Pager: View {
    let cur: Int
    let total: Int
    var onPage: (Int) -> Void

    var body: some View {
        if total > 1 {
            let n = Self.numbers(cur: cur, total: total, width: UIScreen.main.bounds.width)
            HStack(spacing: 6) {
                btn("‹", cur - 1, on: false, disabled: cur == 1)
                ForEach(Array(n.enumerated()), id: \.offset) { i, v in
                    if i > 0 && v - n[i - 1] > 1 { Text("…").font(.q(15)).foregroundStyle(Color.dimText) }
                    btn(String(v), v, on: v == cur, disabled: false)
                }
                btn("›", cur + 1, on: false, disabled: cur == total)
            }
            .padding(.horizontal, 16).padding(.top, 12)
        }
    }

    static func numbers(cur: Int, total: Int, width: CGFloat) -> [Int] {
        let N = max(5, Int(floor((width - 32 + 6) / 46)) - 2)
        var nums: [Int] = []
        func add(_ n: Int) { if n >= 1 && n <= total && !nums.contains(n) { nums.append(n) } }
        if total <= N { for a in 1...total { add(a) } }
        else if N < 7 {
            let l0 = min(max(1, cur - N / 2), total - N + 1)
            for k in l0..<(l0 + N) { add(k) }
        } else {
            add(1); add(total)
            let mid = N - 4
            let lo = min(max(2, cur - mid / 2), total - 1 - mid)
            for k in lo..<(lo + mid) { add(k) }
            add(cur)
            nums.sort()
        }
        return nums
    }

    private func btn(_ label: String, _ p: Int, on: Bool, disabled: Bool) -> some View {
        Button { onPage(p) } label: {
            Text(label).font(.q(15)).foregroundStyle(on ? Color.bg : Color(hex: 0xd4d4d4))
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(on ? Color.pink : Color.surfaceHi, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.3 : 1)
    }
}

/// Lower-case words of a title, accents removed: "Amélie" -> ["amelie"].
private func words(_ x: String) -> [String] {
    let t = x.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        .folding(options: .diacriticInsensitive, locale: nil)
    return t.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

private func rank(_ w: [String], _ toks: [String]) -> Int {
    var first = -1
    for (t, tok) in toks.enumerated() {
        guard let hit = w.firstIndex(where: { $0.hasPrefix(tok) }) else { return -1 }
        if t == 0 { first = hit }
    }
    return first
}

enum LibKind { case movies, shows
    var type: String { self == .movies ? "Movie" : "Series" }
    var title: String { self == .movies ? "Movies" : "TV Shows" }
}

/// The web's phone grid: three across, 28 pt at the sides, 12 between (--pw).
private func browseCell() -> CGFloat { floor((UIScreen.main.bounds.width - 56 - 24) / 3) }

/// A section heading at the web's phone insets: 20 pt pink, 28 pt in.
private struct SectionHead: View {
    let text: String
    let top: CGFloat
    var body: some View {
        Text(text).font(.q(20)).foregroundStyle(Color.pink)
            .shadow(color: .black, radius: 4, y: 1)
            .padding(.leading, 28).padding(.top, top)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The web's empty line: 18 pt grey, centred, 30 pt below the heading above it.
private func browseEmpty(_ t: String) -> some View {
    Text(t).font(.q(18)).foregroundStyle(Color.dimText).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity).padding(.top, 30)
}

/// A row of posters (the web's .row on a phone): starts 28 pt in, 12 apart, 6 pt above and below.
private struct PosterRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) { content() }.padding(6)
        }
        .frame(height: 327)
        .padding(.leading, 22).padding(.top, 6)
    }
}

/// Posters three across at the web's phone insets (28 pt at the sides, 12 between).
private func posterGrid<Content: View>(width w: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: 12), count: 3), spacing: 12) { content() }
        .padding(.horizontal, 28)
}

/// A poster with the web's 12 pt corners; the type badge shows only in the All view.
private struct BrowsePoster: View {
    let card: Card
    let width: CGFloat
    var badge = false
    @Environment(Nav.self) private var nav
    var body: some View {
        Button { nav.go(card.route) } label: {
            ZStack(alignment: .topTrailing) {
                if card.img != nil { Pic_(card.img, radius: 12) } else { placeholder }
                if badge { TypeBadge(t: card.t) }
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1d1d20), Color(hex: 0x111113)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 6) {
                Text(String(card.title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()).font(.q(42)).foregroundStyle(Color.pink)
                Text(card.title).font(.q(12)).foregroundStyle(Color(hex: 0xd4d4d4)).multilineTextAlignment(.center).lineLimit(3)
            }.padding(8)
        }
    }
}

/// Movies / TV Shows: title, Recommended, Recently Added, then A-Z search and the whole library in pages.
struct LibraryListScreen: View {
    let kind: LibKind
    @State private var rec: [Item] = []
    @State private var recent: [Item] = []
    @State private var lib: [Item] = []
    @State private var loaded = false
    @State private var q = ""
    @State private var pageNo = 1
    @State private var indexed: [(it: Item, w: [String])] = []

    private let PAGE = 100
    private let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)

    private var found: [Item] {
        let toks = words(q)
        if toks.isEmpty { return indexed.map { $0.it } }
        var sc: [(Int, Int, Item)] = []
        for (i, x) in indexed.enumerated() { let r = rank(x.w, toks); if r > -1 { sc.append((r, i, x.it)) } }
        sc.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return sc.map { $0.2 }
    }

    var body: some View {
        let list = found
        let pages = max(1, Int(ceil(Double(list.count) / Double(PAGE))))
        let cur = min(pageNo, pages)
        let slice = Array(list.dropFirst((cur - 1) * PAGE).prefix(PAGE))
        let w = browseCell()
        let curLetter = q.count == 1 ? q.uppercased() : ""

        Page(refresh: { await load(force: true) }) {
            PageTitle(text: kind.title)
            SectionHead(text: "Recommended", top: 36)
            cardRow(rec, loading: !loaded, skeletons: 5)
            SectionHead(text: "Recently Added", top: 34)
            cardRow(recent, loading: !loaded, skeletons: 8)

            (Text("Search").font(.q(20)).foregroundStyle(Color.pink) + (q.isEmpty ? Text("") : Text("  “\(q)”").font(.q(20)).foregroundStyle(Color.dimText)))
                .shadow(color: .black, radius: 4, y: 1).padding(.top, 100).padding(.leading, 28)
            FlowLetters(letters: letters, current: curLetter) { l in
                q = (q.count == 1 && q.uppercased() == l) ? "" : l.lowercased()
                pageNo = 1
            }
            Pager(cur: cur, total: pages) { pageNo = $0 }
            Color.clear.frame(height: 12)
            if slice.isEmpty {
                if !loaded {
                    posterGrid(width: w) { ForEach(0..<5, id: \.self) { _ in Skeleton(width: w, height: w * 1.5, radius: 12) } }
                } else {
                    browseEmpty(q.isEmpty ? "Nothing here yet" : "Nothing with “\(q)”")
                }
            } else {
                posterGrid(width: w) { ForEach(slice.map { $0.card }) { BrowsePoster(card: $0, width: w) } }
            }
        }
        .task { await load(force: false) }
    }

    @ViewBuilder private func cardRow(_ items: [Item], loading: Bool, skeletons: Int) -> some View {
        if items.isEmpty && loading { PosterRow { ForEach(0..<skeletons, id: \.self) { _ in Skeleton(width: 210, height: 315, radius: 12) } } }
        else if items.isEmpty { browseEmpty("Nothing here yet") }
        else { PosterRow { ForEach(items.map { $0.card }) { BrowsePoster(card: $0, width: 210) } } }
    }

    private func load(force: Bool) async {
        let k = kind.type
        if !force, let r: [Item] = Mem.get("rec\(k)", ttl: 300), let n: [Item] = Mem.get("recent\(k)", ttl: 120), let l: [Item] = Mem.get("lib\(k)", ttl: 600) {
            rec = r; recent = n; lib = l; reindex(); loaded = true; return
        }
        async let s = Api.suggestions(k, limit: 8)
        async let n = try? Api.recent(k, limit: 24)
        async let l = try? Api.library(k)
        var r = await s
        if r.isEmpty { r = (try? await Api.recent(k, limit: 8)) ?? [] }
        rec = Array(r.prefix(8)); Mem.set("rec\(k)", rec)
        if let n = await n { recent = n; Mem.set("recent\(k)", n) }
        if let l = await l { lib = l; Mem.set("lib\(k)", l); reindex() }
        loaded = true
    }

    private func reindex() { indexed = lib.map { ($0, words($0.title)) } }
}

struct FlowLetters: View {
    let letters: [String]
    let current: String
    var onTap: (String) -> Void
    var body: some View {
        WordFlowGrid(spacing: 6) {
            ForEach(letters, id: \.self) { l in
                Button { onTap(l) } label: {
                    Text(l).font(.q(20)).foregroundStyle(current == l ? Color.bg : Color(hex: 0xd4d4d4))
                        .frame(width: 34, height: 34)
                        .background(current == l ? Color.pink : Color(hex: 0x191919), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 12).padding(.leading, 28).padding(.trailing, 28)
    }
}

/// A wrapping row of equal items.
struct WordFlowGrid: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat? = nil
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + (rowSpacing ?? spacing); rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > b.minX && x + sz.width > b.maxX { x = b.minX; y += rowH + (rowSpacing ?? spacing); rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Genre / service collection

struct CollectionScreen: View {
    let id: String
    let service: Bool
    @State private var name = ""
    @State private var logo: String?
    @State private var logoKind: String?
    @State private var tiles: [SeerrTile] = []
    @State private var mode = "all"
    @State private var loading = true
    @State private var finished = false
    @State private var errorText: String?
    @State private var nextPage = 2
    @State private var busy = false

    var body: some View {
        let w = browseCell()
        let sel = tiles.filter { mode == "all" || $0.t == mode }
        let counts = (all: tiles.count, s: tiles.filter { $0.t == "s" }.count, m: tiles.filter { $0.t == "m" }.count)
        let n = mode == "all" ? counts.all : (mode == "s" ? counts.s : counts.m)
        let logoURL = Pic.tmdb(logo, logoKind == "provider" ? "w154" : "w300")

        Page {
            HStack(alignment: logoURL == nil ? .firstTextBaseline : .center, spacing: 14) {
                if let logoURL {
                    Pic_(logoURL, radius: 12, fit: logoKind == "provider" ? .fill : .fit).padding(logoKind == "provider" ? 0 : 8).frame(width: logoKind == "provider" ? 64 : 110, height: 64)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text(name).font(.q(28)).foregroundStyle(Color.pink).lineLimit(2).shadow(color: .black, radius: 4, y: 1)
                }
                Text("\(n) \(n == 1 ? "title" : "titles")\(finished ? "" : "+")").font(.q(14)).foregroundStyle(Color.dimText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28).padding(.top, 66)
            SegmentedBar(options: [("all", "All", counts.all), ("s", "Shows", counts.s), ("m", "Movies", counts.m)], value: $mode, top: 18)
                .padding(.leading, 12)
            Color.clear.frame(height: 12)
            if let e = errorText, tiles.isEmpty {
                Text(e).font(.q(18)).foregroundStyle(Color.dimText).padding(.top, 30).padding(.horizontal, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if sel.isEmpty {
                if loading {
                    posterGrid(width: w) { ForEach(0..<10, id: \.self) { _ in Skeleton(width: w, height: w * 1.5, radius: 12) } }
                } else {
                    browseEmpty("Nothing here")
                }
            } else {
                posterGrid(width: w) {
                    ForEach(sel) { t in
                        BrowsePoster(card: t.card, width: w, badge: mode == "all")
                            .onAppear { if t.id == sel.last?.id { Task { await more() } } }
                    }
                }
                if !finished { Text("Loading more…").font(.q(15)).foregroundStyle(Color.dimText).padding(.top, 12).padding(.horizontal, 28) }
            }
        }
        .task { if tiles.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let r: Collection = try await (service ? Plugin.service(id) : Plugin.genre(id))
            name = r.name ?? ""
            if let l = r.logo { logo = l; logoKind = r.kind }
            var seen = Set<String>()
            tiles = (r.items ?? []).filter { seen.insert($0.id).inserted }
            nextPage = (r.pages ?? 1) + 1
            finished = false
        } catch let e as ApiError {
            errorText = e.status == 404 ? "Not found (the Seerr data may still be downloading)" : e.message
        } catch { errorText = error.localizedDescription }
    }

    private func more() async {
        if busy || finished || tiles.isEmpty { return }
        busy = true
        defer { busy = false }
        guard let r = await Plugin.more(service ? "service" : "genre", id, page: nextPage) else { finished = true; return }
        nextPage += 1
        let have = Set(tiles.map { $0.id })
        tiles += (r.items ?? []).filter { !have.contains($0.id) }
        if r.done == true || (r.items ?? []).isEmpty { finished = true }
    }
}
