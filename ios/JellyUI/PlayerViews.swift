import SwiftUI

func timeText(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    return String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: - Mini player

struct MiniPlayer: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if let it = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Pic_(Pic.square(it, 120), radius: 6).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(it.artistLine).font(.system(size: 12.5)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20)).frame(width: 40, height: 40)
                    }
                    Button { player.nextSong() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 18)).frame(width: 40, height: 40)
                    }
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                ProgressView(value: player.duration > 0 ? min(1, player.position / player.duration) : 0)
                    .progressViewStyle(.linear).tint(Theme.accent).padding(.horizontal, 12).padding(.bottom, 6)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.bottom, 6 + 49) // above the tab bar
            .contentShape(Rectangle())
            .onTapGesture { player.showFull = true }
        }
    }
}

// MARK: - Full screen

struct FullPlayer: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [LyricLine] = []
    @State private var loading = true
    @State private var showQueue = false
    @State private var coverOnly = false
    @State private var scrub: Double?

    var body: some View {
        let it = player.current
        let cover = it.flatMap { Pic.square($0, 160) }
        ZStack {
            Color.black.ignoresSafeArea()
            BackdropView(cover: cover, playing: player.isPlaying)
            VStack(spacing: 0) {
                header(it)
                middle(it)
                controls(it)
            }
            .padding(.horizontal, 20)
            if showQueue {
                QueueView(close: { withAnimation(.easeInOut(duration: 0.26)) { showQueue = false } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .task(id: it?.id) { await loadLyrics(it) }
    }

    private func loadLyrics(_ it: Item?) async {
        guard let it else { lines = []; return }
        if let c = await LyricsStore.shared.cached(it.id) { lines = c; loading = false; return }
        lines = []
        loading = true
        var r = await LyricsStore.shared.load(it)
        if r == nil {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            r = await LyricsStore.shared.load(it)
        }
        guard it.id == player.current?.id else { return }
        lines = r ?? []
        loading = false
    }

    private var hasLyrics: Bool { !lines.isEmpty && !coverOnly }

    @ViewBuilder
    private func header(_ it: Item?) -> some View {
        HStack(spacing: 14) {
            if hasLyrics, let it {
                Pic_(Pic.square(it, 160), radius: 8).frame(width: 56, height: 56).transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 2) {
                if hasLyrics {
                    Text(it?.title ?? "").font(.system(size: 17, weight: .bold)).lineLimit(1)
                    Text(it?.artistLine ?? "").font(.system(size: 14)).opacity(0.7).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40) }
        }
        .foregroundStyle(.white)
        .frame(height: 64)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func middle(_ it: Item?) -> some View {
        ZStack {
            if hasLyrics {
                LyricsView(lines: lines, player: player, topInset: 30, bottomInset: 260)
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.82), .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .transition(.opacity)
            } else {
                VStack(spacing: 18) {
                    Spacer()
                    if let it {
                        Pic_(Pic.square(it, 700), radius: 14)
                            .aspectRatio(1, contentMode: .fit)
                            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                        VStack(spacing: 4) {
                            Text(it.title).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
                            Text(it.artistLine).font(.system(size: 16)).opacity(0.7)
                        }
                        .foregroundStyle(.white)
                    }
                    if loading { ProgressView().tint(.white) }
                    Spacer()
                }
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: hasLyrics)
    }

    @ViewBuilder
    private func controls(_ it: Item?) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Slider(value: Binding(get: { scrub ?? player.position }, set: { scrub = $0 }), in: 0...max(1, player.duration)) { editing in
                    if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                }
                .tint(.white)
                HStack {
                    Text(timeText(scrub ?? player.position))
                    Spacer()
                    Text(timeText(player.duration))
                }
                .font(.system(size: 12)).opacity(0.7).monospacedDigit()
            }
            HStack {
                Button { coverOnly.toggle() } label: {
                    Image(systemName: lines.isEmpty ? "quote.bubble" : (coverOnly ? "quote.bubble" : "quote.bubble.fill")).font(.system(size: 20))
                }
                .opacity(lines.isEmpty ? 0.3 : 1).disabled(lines.isEmpty)
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 26)) }
                Spacer()
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64)) }
                Spacer()
                Button { player.nextSong() } label: { Image(systemName: "forward.fill").font(.system(size: 26)) }
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.18)) { showQueue = true } } label: { Image(systemName: "list.bullet").font(.system(size: 20)) }
            }
            .padding(.horizontal, 6)
            HStack {
                Spacer()
                Button { player.toggleFavourite() } label: {
                    Image(systemName: (it?.isFavourite ?? false) ? "heart.fill" : "heart").font(.system(size: 20))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.bottom, 24)
    }
}

// MARK: - Queue

struct QueueView: View {
    @Environment(PlayerModel.self) private var player
    let close: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.55)).background(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Queue").font(.system(size: 20, weight: .bold))
                    Spacer()
                    Button("Clear") { player.clearUpcoming() }.font(.system(size: 15)).padding(.trailing, 12)
                    Button("Close", action: close).font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 14)
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { i, s in
                            HStack(spacing: 14) {
                                Pic_(Pic.square(s, 120), radius: 6).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.system(size: 16)).lineLimit(1)
                                    Text(s.artistLine).font(.system(size: 12.5)).opacity(0.65).lineLimit(1)
                                }
                                Spacer()
                                if i == player.index { Image(systemName: "waveform").font(.system(size: 14)) }
                            }
                            .foregroundStyle(.white)
                            .opacity(i < player.index ? 0.45 : 1)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .contentShape(Rectangle())
                            .onTapGesture { player.jump(to: i) }
                            .swipeActions { if i != player.index { Button(role: .destructive) { player.remove(at: i) } label: { Text("Remove") } } }
                            .id(i)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onAppear { proxy.scrollTo(player.index, anchor: .top) }
                    .onChange(of: player.index) { _, n in proxy.scrollTo(n, anchor: .top) } // the playing song goes to the top at once
                }
            }
        }
    }
}
