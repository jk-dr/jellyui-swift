import SwiftUI
import UIKit

private func isVideo(_ it: Item) -> Bool { it.mediaType == "Video" || it.type == "Video" }
private func isMedia(_ it: Item) -> Bool { it.type == "Photo" || it.type == "Video" || it.mediaType == "Photo" || it.mediaType == "Video" }
private func thumb(_ it: Item) -> URL? {
    guard let t = it.imageTag("Primary") else { return nil }
    return Api.url("/Items/\(it.id)/Images/Primary", ["maxHeight": 400, "quality": 80, "tag": t])
}
private func full(_ it: Item) -> URL? {
    Api.url("/Items/\(it.id)/Images/Primary", ["maxHeight": 2200, "quality": 90, "tag": it.imageTag("Primary")])
}

private let ROW_H: CGFloat = 110
private let GAP: CGFloat = 6
private let PAGE = 120
private func ratio(_ it: Item) -> CGFloat {
    if let r = it.primaryImageAspectRatio, r > 0.2, r < 5 { return CGFloat(r) }
    return 1.5
}

private struct JCell: Identifiable {
    let it: Item
    let w: CGFloat
    var id: String { it.id }
}

private struct JRow: Identifiable {
    var id: String
    var h: CGFloat
    var cells: [JCell]
}

private func justify(_ items: [Item], avail: CGFloat) -> [JRow] {
    var rows: [JRow] = []
    var cur: [Item] = []
    var sum: CGFloat = 0
    func flush(_ full: Bool) {
        guard !cur.isEmpty else { return }
        let gaps = GAP * CGFloat(cur.count - 1)
        let h = full ? (avail - gaps) / sum : ROW_H
        rows.append(JRow(id: cur[0].id, h: h, cells: cur.map { JCell(it: $0, w: ratio($0) * h) }))
        cur = []; sum = 0
    }
    for it in items {
        cur.append(it); sum += ratio(it)
        if sum * ROW_H + GAP * CGFloat(cur.count - 1) >= avail { flush(true) }
    }
    flush(false)
    return rows
}

private struct PhotoTile: View {
    let it: Item
    let w: CGFloat
    let h: CGFloat
    var onOpen: (Item) -> Void
    var body: some View {
        let media = isMedia(it)
        let hue = genreHue(it.title.isEmpty ? "x" : it.title)
        Button { onOpen(it) } label: {
            ZStack(alignment: .topLeading) {
                Color(hex: 0x18181c)
                if let u = thumb(it) { Pic_(u, radius: 0) }
                else if media { Color.surfaceHi.overlay(Icon(name: "photo", size: 28, color: Color(hex: 0x6a6a70))) }
                else { LinearGradient(colors: [Color(h: hue, s: 38, l: 25), Color(h: (hue + 35).truncatingRemainder(dividingBy: 360), s: 42, l: 12)], startPoint: .top, endPoint: .bottom) }
                if !media {
                    LinearGradient(colors: [.clear, Color.black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: h * 0.6).frame(maxHeight: .infinity, alignment: .bottom)
                    Icon(name: "folder", size: 18, color: .white).padding(6)
                    Text(it.title).font(.system(size: 12, weight: .heavy)).foregroundStyle(.white).lineLimit(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(6)
                } else if isVideo(it) {
                    Text("VIDEO").font(.system(size: 8, weight: .heavy)).tracking(0.6).foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(4)
                }
            }
            .frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }.buttonStyle(PressStyle())
    }
}

struct PhotosScreen: View {
    let id: String
    @Environment(Nav.self) private var nav
    private let settings = Settings.shared
    @State private var folder: Item?
    @State private var kids: [Item] = []
    @State private var loading = true
    @State private var pageNo = 1
    @State private var viewer: ViewerState?
    @State private var busy = false

    struct ViewerState: Identifiable { var id = UUID(); var list: [Item]; var index: Int; var auto: Bool }

    var body: some View {
        let l = kids
        let items = l.filter { !isMedia($0) } + l.filter(isMedia)
        let pages = max(1, Int(ceil(Double(items.count) / Double(PAGE))))
        let cur = min(pageNo, pages)
        let rows = justify(Array(items.dropFirst((cur - 1) * PAGE).prefix(PAGE)), avail: UIScreen.main.bounds.width - 10 - 12)

        Page {
            HStack(spacing: 14) {
                Text(folder?.title ?? " ").font(.q(28)).foregroundStyle(Color.pink).lineLimit(2).shadow(color: .black, radius: 4, y: 1)
                Text(items.isEmpty ? "" : "\(items.count) \(items.count == 1 ? "item" : "items")").font(.q(14)).foregroundStyle(Color.dimText)
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.top, 84 + 32 + 14)
            HStack(spacing: 10) {
                Button { Task { await startShow(true, items) } } label: {
                    HStack(spacing: 8) { Icon(name: "shuffle", size: 20, color: .bg); Text("Shuffle").font(.q(16)).foregroundStyle(Color.bg) }
                        .frame(maxWidth: .infinity).frame(height: 44).background(Color.pink, in: Capsule())
                }.buttonStyle(PressStyle()).disabled(busy)
                Button { Task { await startShow(false, items) } } label: {
                    Text("Slideshow").font(.q(16)).foregroundStyle(Color.pink).frame(maxWidth: .infinity).frame(height: 44).background(Color.surfaceHi, in: Capsule())
                }.buttonStyle(PressStyle()).disabled(busy)
            }.padding(.horizontal, 16).padding(.top, 12).opacity(busy ? 0.6 : 1)
            Pager(cur: cur, total: pages) { pageNo = $0 }
            Color.clear.frame(height: 12)
            if rows.isEmpty {
                if loading { ProgressView().tint(Color.dimText).frame(maxWidth: .infinity).padding(24) } else { Note("Nothing here yet") }
            } else {
                LazyVStack(alignment: .leading, spacing: GAP) {
                    ForEach(rows) { r in
                        HStack(spacing: GAP) { ForEach(r.cells) { c in PhotoTile(it: c.it, w: c.w, h: r.h) { open($0, items) } } }
                    }
                }.padding(.horizontal, 11)
            }
            if pages > 1 { Pager(cur: cur, total: pages) { pageNo = $0 } }
        }
        .task {
            folder = try? await Api.item(id)
            kids = (try? await Api.items(["ParentId": id, "SortBy": "SortName", "SortOrder": "Ascending", "Limit": 1000, "Fields": "PrimaryImageAspectRatio,Path,DateCreated,PremiereDate,Overview", "EnableImageTypes": "Primary", "ImageTypeLimit": 1])) ?? []
            loading = false
        }
        .fullScreenCover(item: $viewer) { v in PhotoViewer(list: v.list, start: v.index, auto: v.auto) }
    }

    private func open(_ it: Item, _ items: [Item]) {
        if !isMedia(it) { nav.go(.photos(it.id)); return }
        if isVideo(it) { nav.play = PlayRequest(itemId: it.id); return }
        let media = items.filter(isMedia)
        viewer = ViewerState(list: media, index: max(0, media.firstIndex { $0.id == it.id } ?? 0), auto: false)
    }

    private func startShow(_ shuffle: Bool, _ items: [Item]) async {
        busy = true
        defer { busy = false }
        var a = ((try? await Api.items(["ParentId": id, "Recursive": true, "IncludeItemTypes": "Photo,Video", "Limit": 3000, "Fields": "Path,DateCreated,PremiereDate,Overview", "EnableImageTypes": "Primary", "ImageTypeLimit": 1])) ?? []).filter { !isVideo($0) }
        if a.isEmpty { return }
        a = shuffle ? a.shuffled() : a.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        viewer = ViewerState(list: a, index: 0, auto: true)
    }
}

struct PhotoViewer: View {
    let list: [Item]
    let start: Int
    let auto: Bool
    @Environment(\.dismiss) private var dismiss
    private let settings = Settings.shared
    @State private var index: Int
    @State private var slide: Bool
    @State private var chrome = true

    init(list: [Item], start: Int, auto: Bool) {
        self.list = list
        self.start = start
        self.auto = auto
        _index = State(initialValue: start)
        _slide = State(initialValue: auto)
    }

    var body: some View {
        let cur = list.indices.contains(index) ? list[index] : nil
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, it in
                    Pic_(full(it), radius: 0, fit: .fit).ignoresSafeArea().tag(i).onTapGesture { withAnimation { chrome.toggle() } }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never)).ignoresSafeArea()
            if chrome {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button { dismiss() } label: { Icon(name: "close", size: 24).frame(width: 44, height: 44) }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(cur?.title ?? "").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white).lineLimit(1)
                            if let d = cur?.premiereDate ?? cur?.dateCreated, let date = ISO8601DateFormatter.flexible(d) {
                                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.q(12)).foregroundStyle(Color.dimText)
                            }
                        }
                        Spacer()
                        Text("\(index + 1) / \(list.count)").font(.q(13)).foregroundStyle(Color.dimText).padding(.trailing, 8)
                    }
                    .padding(.horizontal, 8).padding(.top, Insets.top + 8).padding(.bottom, 8).background(Color.black.opacity(0.45))
                    Spacer()
                    HStack(spacing: 8) {
                        Button { go(index - 1) } label: { Icon(name: "skipPrev", size: 24).frame(width: 44, height: 44) }
                        Button { slide.toggle() } label: { Icon(name: slide ? "pause" : "play", size: 24).frame(width: 44, height: 44) }
                        Button { go(index + 1) } label: { Icon(name: "skipNext", size: 24).frame(width: 44, height: 44) }
                        HStack(spacing: 12) {
                            Button { settings.slideDelay = max(2, settings.slideDelay - 1) } label: { Text("−").font(.system(size: 24, weight: .heavy)).foregroundStyle(.white).frame(width: 28) }
                            Text("\(settings.slideDelay)s").font(.q(14)).foregroundStyle(.white).frame(minWidth: 30)
                            Button { settings.slideDelay = min(60, settings.slideDelay + 1) } label: { Text("+").font(.system(size: 24, weight: .heavy)).foregroundStyle(.white).frame(width: 28) }
                        }.padding(.leading, 16)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, Insets.bottom + 12).background(Color.black.opacity(0.45))
                }.ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .task(id: "\(slide)|\(index)|\(settings.slideDelay)") {
            guard slide else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(2, min(60, settings.slideDelay))) * 1_000_000_000)
            if !Task.isCancelled { go(index + 1) }
        }
    }

    private func go(_ i: Int) {
        guard !list.isEmpty else { return }
        withAnimation { index = (i + list.count) % list.count }
    }
}
