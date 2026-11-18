import SwiftUI

// MARK: - App

@main
struct JellyUIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session = Session.shared
    @State private var player = PlayerModel.shared

    init() {
        DebugLog.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isSignedIn { RootView() } else { LoginView() }
            }
            .environment(session)
            .environment(player)
            .preferredColorScheme(.dark)
            .tint(Color.pink)
            .background(Color.bg.ignoresSafeArea())
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
    @State private var fails = 0
    @FocusState private var focus: Field?
    enum Field { case address, user, pw }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    if let img = UIImage(contentsOfFile: Bundle.main.path(forResource: "logo", ofType: "png") ?? "") {
                        Image(uiImage: img).resizable().scaledToFit().frame(width: 56, height: 56)
                    }
                    if step == 0 {
                        Text("Connect to server").font(.q(30)).foregroundStyle(Color.pink)
                        label("Server address")
                        field("192.168.1.10:8096 or jellyfin.example.com", $address, secure: false, f: .address)
                            .keyboardType(.URL).submitLabel(.go).onSubmit { Task { await connect() } }
                        errorText
                        Btn(label: busy ? "Connecting…" : "Connect", kind: .primary, busy: busy) { Task { await connect() } }.frame(width: 160)
                    } else {
                        Text("Sign in").font(.q(30)).foregroundStyle(Color.pink)
                        Button { step = 0; error = "" } label: {
                            Text("\(serverName.isEmpty ? Session.shared.server : serverName) · Change").font(.q(14)).foregroundStyle(Color.pink)
                        }.buttonStyle(.plain)
                        label("Username")
                        field("", $user, secure: false, f: .user).textContentType(.username).submitLabel(.next).onSubmit { focus = .pw }
                        label("Password")
                        field("", $pw, secure: true, f: .pw).textContentType(.password).submitLabel(.go).onSubmit { Task { await signIn() } }
                        errorText
                        Btn(label: busy ? "Signing in…" : "Sign in", kind: .primary, busy: busy) { Task { await signIn() } }.frame(width: 160)
                    }
                }
                .padding(.vertical, 28).padding(.horizontal, 20)
                .background(Color(hex: 0x121214), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 14).frame(maxWidth: 560)
                .frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height - 120, alignment: .center)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .task { if step == 1, let n = try? await Api.probe(Session.shared.server) { serverName = n } }
    }

    private var errorText: some View {
        Text(error).font(.q(14)).foregroundStyle(Color.danger).multilineTextAlignment(.center).frame(minHeight: 20)
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.q(13)).foregroundStyle(Color.dimText).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).padding(.bottom, -6)
    }

    private func field(_ placeholder: String, _ text: Binding<String>, secure: Bool, f: Field) -> some View {
        Group {
            if secure { SecureField("", text: text, prompt: Text(placeholder).foregroundStyle(Color(hex: 0x6f6262))) }
            else { TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Color(hex: 0x6f6262))) }
        }
        .focused($focus, equals: f)
        .font(.q(18)).foregroundStyle(Color.pink)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .padding(.horizontal, 18).frame(height: 46).background(Color.surfaceHi, in: Capsule())
    }

    private func connect() async {
        if busy { return }
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
        if busy { return }
        let u = user.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { error = "Enter your username"; return }
        guard !pw.isEmpty else { error = "Enter your password"; return }
        busy = true; error = ""
        defer { busy = false }
        do {
            try await Api.login(base: session.server, name: u, pw: pw)
            Mem.clear()
            pw = ""
        } catch {
            self.error = error.localizedDescription
            pw = ""
            fails += 1
            // each wrong try makes the next one wait a little longer, so guessing is slow
            try? await Task.sleep(nanoseconds: UInt64(min(4000, 700 * fails)) * 1_000_000)
        }
    }
}
