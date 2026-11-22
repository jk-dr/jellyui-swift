import SwiftUI

struct Option<T: Hashable>: Hashable { var value: T; var label: String }

private let BITRATES: [Option<Int>] = [
    .init(value: 120_000_000, label: "Auto (best)"), .init(value: 40_000_000, label: "40 Mbps"), .init(value: 20_000_000, label: "20 Mbps"),
    .init(value: 10_000_000, label: "10 Mbps"), .init(value: 6_000_000, label: "6 Mbps"), .init(value: 4_000_000, label: "4 Mbps"),
    .init(value: 2_000_000, label: "2 Mbps"), .init(value: 1_000_000, label: "1 Mbps"),
]
private let SEG: [Option<String>] = [.init(value: "ask", label: "Ask to skip"), .init(value: "auto", label: "Skip automatically"), .init(value: "none", label: "Do nothing")]
private let LANGS: [Option<String>] = [
    .init(value: "", label: "Any"), .init(value: "eng", label: "English"), .init(value: "spa", label: "Español"), .init(value: "fre", label: "Français"),
    .init(value: "ger", label: "Deutsch"), .init(value: "ita", label: "Italiano"), .init(value: "por", label: "Português"), .init(value: "jpn", label: "日本語"), .init(value: "chi", label: "中文"),
]

// MARK: - Controls

private struct SRow<C: View>: View {
    let label: String
    var desc: String?
    @ViewBuilder var control: () -> C
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.q(15)).foregroundStyle(Color(hex: 0xe6e6e6))
                if let desc { Text(desc).font(.q(12)).foregroundStyle(Color.dimText) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
        .padding(12).background(Color(hex: 0x121214), in: RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(.bottom, 8)
    }
}

/// The web's switch: 46 x 26, pink when on.
private struct PinkSwitch: View {
    @Binding var on: Bool
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { on.toggle() } } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Color.pink : Color(hex: 0x2a2a30))
                Circle().fill(on ? Color.bg : Color(hex: 0xbababa)).frame(width: 20, height: 20).padding(3)
            }.frame(width: 46, height: 26)
        }.buttonStyle(.plain)
    }
}

private struct ToggleRow: View {
    let label: String
    var desc: String?
    @Binding var value: Bool
    var body: some View { SRow(label: label, desc: desc) { PinkSwitch(on: $value) } }
}

private struct SelectRow<T: Hashable>: View {
    let label: String
    var desc: String?
    let options: [Option<T>]
    @Binding var value: T
    var body: some View {
        let cur = options.first { $0.value == value } ?? options[0]
        SRow(label: label, desc: desc) {
            Menu {
                ForEach(options, id: \.self) { o in
                    Button { value = o.value } label: { if o.value == value { Label(o.label, systemImage: "checkmark") } else { Text(o.label) } }
                }
            } label: {
                HStack(spacing: 4) { Text(cur.label).font(.q(13)).foregroundStyle(Color.pink); Icon(name: "chevronDown", size: 18, color: .pink) }
                    .padding(.leading, 14).padding(.trailing, 8).frame(height: 34).background(Color.surfaceHi, in: Capsule())
            }
        }
    }
}

private struct StepperRow: View {
    let label: String
    var desc: String?
    @Binding var value: Double
    let min: Double, max: Double, step: Double
    let unit: String
    var body: some View {
        SRow(label: label, desc: desc) {
            HStack(spacing: 7) {
                btn("−") { value = Swift.max(min, Swift.min(max, ((value - step) * 100).rounded() / 100)) }
                Text("\(value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)) \(unit)").font(.q(14)).foregroundStyle(Color(hex: 0xe6e6e6)).frame(minWidth: 48)
                btn("+") { value = Swift.max(min, Swift.min(max, ((value + step) * 100).rounded() / 100)) }
            }
        }
    }
    private func btn(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Text(t).font(.q(18)).foregroundStyle(Color.pink).frame(width: 30, height: 30).background(Color.surfaceHi, in: Circle()) }.buttonStyle(.plain)
    }
}

private struct ActRow: View {
    let label: String
    var desc: String?
    let button: String
    let action: () -> Void
    var body: some View {
        SRow(label: label, desc: desc) {
            Button(action: action) {
                Text(button).font(.q(13)).foregroundStyle(Color.pink)
                    .padding(.horizontal, 14).frame(height: 34).background(Color.surfaceHi, in: Capsule())
            }.buttonStyle(.plain)
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var body: some View { SRow(label: label) { Text(value).font(.q(12)).foregroundStyle(Color.midText).multilineTextAlignment(.trailing).frame(maxWidth: 200, alignment: .trailing) } }
}

private func intBinding(_ get: @escaping () -> Int, _ set: @escaping (Int) -> Void) -> Binding<Double> {
    Binding(get: { Double(get()) }, set: { set(Int($0)) })
}

// MARK: - Screen

private let SECTIONS = ["Profile", "Home", "Playback", "Subtitles", "Music", "Photos", "About"]

struct SettingsScreen: View {
    @Environment(Session.self) private var session
    @State private var s = Settings.shared
    @State private var sec = UserDefaults.standard.string(forKey: "settings.section") ?? "Profile"
    @State private var pwOpen = false
    @State private var qcOpen = false
    @State private var code = ""
    @State private var signOutAsk = false
    @State private var stats = SongCache.shared.stats()
    @State private var clearAsk = false
    @State private var message = ""

    var body: some View {
        Page {
            PageTitle(text: "Settings")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SECTIONS, id: \.self) { t in
                        Button { sec = t; UserDefaults.standard.set(t, forKey: "settings.section") } label: {
                            Text(t).font(.q(14)).foregroundStyle(t == sec ? Color.pink : Color.midText)
                                .padding(.horizontal, 16).padding(.vertical, 8).background(t == sec ? Color.surfaceHi : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 4)
            }.padding(.top, 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(sec).font(.q(20)).foregroundStyle(Color.pink).padding(.horizontal, 4).padding(.bottom, 10)
                switch sec {
                case "Profile":
                    InfoRow(label: "Display name", value: session.userName + (session.isAdmin ? " (admin)" : ""))
                    ActRow(label: "Profile image", desc: "Shown next to your name.", button: "Change image") {}
                    ActRow(label: "Password", button: "Change password") { pwOpen = true }
                    ActRow(label: "Easy PIN code", desc: "A short PIN for signing in on your home network.", button: "Set PIN") {}
                    ActRow(label: "Quick Connect", desc: "Enter the code shown on another device to sign it in.", button: "Enter code") { qcOpen = true }
                    ActRow(label: "Sign out", button: "Sign out") { signOutAsk = true }
                case "Home":
                    ToggleRow(label: "My Media", desc: "Show your libraries on the Home page.", value: $s.homeLibraries)
                    ToggleRow(label: "Continue Watching", value: $s.homeContinue)
                    ToggleRow(label: "Genres", value: $s.homeGenres)
                    ToggleRow(label: "Trending and discover rows", value: $s.homeTrending)
                case "Playback":
                    ToggleRow(label: "Auto-play next episode", value: $s.autoNext)
                    SelectRow(label: "Maximum streaming bitrate", desc: "Lower values make the server convert the video, which uses less data.", options: BITRATES, value: $s.maxBitrate)
                    StepperRow(label: "Skip back length", value: intBinding({ s.skipBack }, { s.skipBack = $0 }), min: 5, max: 60, step: 5, unit: "s")
                    StepperRow(label: "Skip forward length", value: intBinding({ s.skipFwd }, { s.skipFwd = $0 }), min: 5, max: 120, step: 5, unit: "s")
                    SelectRow(label: "Intros", desc: "What to do when an intro is detected.", options: SEG, value: $s.segIntro)
                    SelectRow(label: "Outros / credits", options: SEG, value: $s.segOutro)
                    SelectRow(label: "Recaps", options: SEG, value: $s.segRecap)
                    SelectRow(label: "Previews", options: SEG, value: $s.segPreview)
                case "Subtitles":
                    SelectRow(label: "Subtitle mode", options: [.init(value: "default", label: "Default"), .init(value: "smart", label: "Smart"), .init(value: "forced", label: "Only forced subtitles"), .init(value: "always", label: "Always"), .init(value: "none", label: "None")], value: $s.subMode)
                    SelectRow(label: "Preferred subtitle language", options: LANGS, value: $s.subLang)
                    StepperRow(label: "Text size", value: intBinding({ s.subSize }, { s.subSize = $0 }), min: 12, max: 40, step: 2, unit: "pt")
                    ToggleRow(label: "Text weight: bold", value: $s.subBold)
                    ToggleRow(label: "Background", value: $s.subBackground)
                    StepperRow(label: "Subtitle offset", desc: "Positive values show subtitles later.", value: $s.subOffset, min: -10, max: 10, step: 0.5, unit: "s")
                case "Music":
                    ToggleRow(label: "Hide lyrics", desc: "Show the album art instead on the Now Playing screen.", value: $s.lyricsHidden)
                    ToggleRow(label: "Save played songs on this device", desc: "Each song is downloaded once, kept here and played from this copy, so playing it again uses no data.", value: $s.songCache)
                    StepperRow(label: "Save ahead", desc: "How many songs after the playing one are saved in advance, so the next starts at once.", value: intBinding({ s.songAhead }, { s.songAhead = $0 }), min: 0, max: 6, step: 1, unit: "songs")
                    SelectRow(label: "Saved songs: size", options: [.init(value: 512, label: "500 MB"), .init(value: 1024, label: "1 GB"), .init(value: 2048, label: "2 GB"), .init(value: 5120, label: "5 GB"), .init(value: 10240, label: "10 GB"), .init(value: 20480, label: "20 GB"), .init(value: 51200, label: "50 GB")], value: $s.songCacheMb)
                    ToggleRow(label: "Saved songs: Wi-Fi only", desc: "Never uses mobile data to save songs.", value: $s.songCacheWifi)
                    let mb = stats.bytes >= 1_073_741_824 ? String(format: "%.2f GB", Double(stats.bytes) / 1_073_741_824) : "\(stats.bytes / 1_048_576) MB"
                    ActRow(label: "Songs saved on this device", desc: "\(stats.count) \(stats.count == 1 ? "song" : "songs"), \(mb)", button: "Clear") { clearAsk = true }
                case "Photos":
                    StepperRow(label: "Slideshow delay", desc: "Time each photo stays on screen.", value: intBinding({ s.slideDelay }, { s.slideDelay = $0 }), min: 2, max: 60, step: 1, unit: "s")
                default:
                    InfoRow(label: "App", value: "Monarth")
                    InfoRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    InfoRow(label: "Server", value: session.server)
                    InfoRow(label: "Device", value: "This iPhone")
                    ActRow(label: "Debug log", desc: "What the app has been doing (errors, stalls, dropped frames, lyric lines), including the run before this one. Share it to get a problem looked at.", button: "Share log") { shareLog() }
                    ActRow(label: "Clear the log", button: "Clear") { DebugLog.clear() }
                }
                if !message.isEmpty { Text(message).font(.q(13)).foregroundStyle(Color.dimText).padding(.top, 8).padding(.horizontal, 4) }
            }
            .padding(.horizontal, 12).padding(.top, 12)
        }
        .sheet(isPresented: $pwOpen) { PasswordSheet(done: { pwOpen = false; message = "Password changed" }) }
        .alert("Quick Connect", isPresented: $qcOpen) {
            TextField("Code", text: $code)
            Button("Cancel", role: .cancel) { code = "" }
            Button("Sign it in") { Task { await quickConnect() } }
        } message: { Text("Enter the code shown on the other device.") }
        .alert("Sign out?", isPresented: $signOutAsk) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                PlayerModel.shared.stop()
                // what the last account showed must not show for the next one
                Mem.clear(); Favs.shared.map = [:]; PlaylistCache.shared.clear()
                Task { _ = try? await Api.request("/Sessions/Logout", method: "POST", quiet: true); await MainActor.run { session.signOut() } } }
        }
        .alert("Delete the saved songs?", isPresented: $clearAsk) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { SongCache.shared.clear(); stats = SongCache.shared.stats() }
        } message: { Text("They will be saved again as you play them.") }
        .onAppear { stats = SongCache.shared.stats() }
    }

    private func quickConnect() async {
        let c = code.trimmingCharacters(in: .whitespaces)
        code = ""
        guard !c.isEmpty else { return }
        do { _ = try await Api.request("/QuickConnect/Authorize", query: ["code": c, "userId": Api.uid], method: "POST", quiet: true); message = "Device signed in" }
        catch let e as ApiError { message = e.status == 404 ? "That code was not found or has expired." : e.message }
        catch { message = error.localizedDescription }
    }

    private func shareLog() {
        DebugLog.flush()
        let av = UIActivityViewController(activityItems: [DebugLog.text()], applicationActivities: nil)
        guard let root = Insets.window?.rootViewController else { return }
        // on iPad the sheet needs an anchor, or UIKit raises an exception
        if let pop = av.popoverPresentationController {
            pop.sourceView = root.view
            pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.maxY - 60, width: 1, height: 1)
        }
        (root.presentedViewController ?? root).present(av, animated: true)
    }
}

private struct PasswordSheet: View {
    var done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cur = ""
    @State private var next = ""
    @State private var again = ""
    @State private var err = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change password").font(.q(20)).foregroundStyle(Color.pink).padding(.bottom, 4)
            field("Current password", $cur)
            field("New password", $next)
            field("Repeat new password", $again)
            if !err.isEmpty { Text(err).font(.q(14)).foregroundStyle(Color.danger) }
            HStack(spacing: 10) {
                Button { dismiss() } label: { Text("Cancel").font(.q(16)).foregroundStyle(Color.pink).frame(maxWidth: .infinity).frame(height: 44).background(Color.surfaceHi, in: Capsule()) }.buttonStyle(.plain)
                Button { Task { await save() } } label: { Text(busy ? "Saving…" : "Save").font(.q(16)).foregroundStyle(Color.bg).frame(maxWidth: .infinity).frame(height: 44).background(Color.pink, in: Capsule()) }.buttonStyle(.plain).disabled(busy)
            }.padding(.top, 8)
            Spacer()
        }
        .padding(20).background(Color(hex: 0x121214).ignoresSafeArea()).presentationDetents([.medium])
    }

    private func field(_ p: String, _ t: Binding<String>) -> some View {
        SecureField("", text: t, prompt: Text(p).foregroundStyle(Color(hex: 0x6f6262))).font(.q(18)).foregroundStyle(Color.pink)
            .textInputAutocapitalization(.never).padding(.horizontal, 18).frame(height: 46).background(Color.surfaceHi, in: Capsule())
    }

    private func save() async {
        if next.isEmpty { err = "Enter a new password"; return }
        if next != again { err = "The new passwords do not match"; return }
        busy = true; err = ""
        defer { busy = false }
        do { _ = try await Api.request("/Users/\(Api.uid)/Password", method: "POST", body: ["CurrentPw": cur, "NewPw": next], quiet: true); done() }
        catch let e as ApiError { err = [400, 401, 403].contains(e.status) ? "The current password is wrong" : e.message }
        catch { err = error.localizedDescription }
    }
}
