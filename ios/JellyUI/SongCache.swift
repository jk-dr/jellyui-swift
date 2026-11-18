import Foundation
import Network
import UIKit

/// A small log kept on the phone: Settings > About > Share log sends it (AirDrop, Messages, Notes...).
enum DebugLog {
    private static var lines: [String] = []
    private static let t0 = Date()
    private static var prev = ""
    private static var started = false
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "debuglog")

    static func start() {
        guard !started else { return }
        started = true
        prev = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        log("app", "start")
        DispatchQueue.main.async { FrameMonitor.shared.start() }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in log("app", "background"); flush() }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in log("app", "active") }
        // the main thread stopped for longer than it should have
        var at = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            let now = Date()
            let late = now.timeIntervalSince(at) - 0.1
            at = now
            if late > 0.15 && late < 60 { log("stall", "main thread stopped for about \(Int(late * 1000)) ms") }
        }
    }

    static func log(_ tag: String, _ msg: String = "") {
        queue.async {
            lines.append(String(format: "%7.2f [%@] %@", Date().timeIntervalSince(t0), tag, msg))
            if lines.count > 1500 { lines.removeFirst(lines.count - 1500) }
        }
    }

    static func flush() {
        queue.async { try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
    }

    static func text() -> String {
        queue.sync {
            [prev.isEmpty ? "" : "---- the run before this one ----\n" + prev.split(separator: "\n").suffix(500).joined(separator: "\n"), "---- this run ----", lines.suffix(900).joined(separator: "\n")]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    static func clear() { queue.async { lines.removeAll(); prev = "" }; flush() }
}

/// Saved songs: each song is downloaded once, kept in the app's own storage and played from that copy. The songs next
/// to the one playing are fetched ahead of time. The oldest-used songs go first when the size limit is reached.
final class SongCache {
    static let shared = SongCache()
    private struct Entry: Codable { var size: Int; var at: Double }
    private var manifest: [String: Entry]
    private let dir: URL
    private let lock = NSLock()
    private var busy = Set<String>()
    private let monitor = NWPathMonitor()
    private var onWifi = true

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = UserDefaults.standard.data(forKey: "songcache"), let m = try? JSONDecoder().decode([String: Entry].self, from: d) { manifest = m } else { manifest = [:] }
        monitor.pathUpdateHandler = { [weak self] p in self?.onWifi = !p.isExpensive && !p.usesInterfaceType(.cellular) }
        monitor.start(queue: DispatchQueue(label: "net"))
    }

    private func file(_ id: String) -> URL { dir.appendingPathComponent("\(id).audio") }
    private func save() { if let d = try? JSONEncoder().encode(manifest) { UserDefaults.standard.set(d, forKey: "songcache") } }

    /// The saved copy of a song (a file address), or nil. Using it marks the song as recently used.
    func cached(_ id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard manifest[id] != nil, FileManager.default.fileExists(atPath: file(id).path) else { return nil }
        manifest[id]?.at = Date().timeIntervalSince1970
        return file(id)
    }

    func stats() -> (count: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (manifest.count, manifest.values.reduce(0) { $0 + $1.size })
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        manifest = [:]
        save()
    }

    /// Saves this song and the next few in the queue (when the setting is on, and on Wi-Fi if it says so).
    func precache(_ queue: [Item], from i: Int) {
        let s = Settings.shared
        guard s.songCache, !(s.songCacheWifi && !onWifi) else { return }
        let upto = min(queue.count, i + 1 + max(0, s.songAhead))
        for k in i..<upto where queue.indices.contains(k) { download(queue[k].id) }
    }

    private func download(_ id: String) {
        lock.lock()
        if manifest[id] != nil || busy.contains(id) { lock.unlock(); return }
        busy.insert(id)
        lock.unlock()
        guard let url = Api.keyed("/Audio/\(id)/stream", ["static": true, "deviceId": Session.shared.deviceId]) else { return }
        URLSession.shared.downloadTask(with: url) { [weak self] tmp, resp, _ in
            guard let self else { return }
            defer { self.lock.lock(); self.busy.remove(id); self.lock.unlock() }
            guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let dest = self.file(id)
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
            self.lock.lock()
            self.manifest[id] = Entry(size: size, at: Date().timeIntervalSince1970)
            self.trim()
            self.save()
            self.lock.unlock()
        }.resume()
    }

    /// the oldest-used songs go first when the size limit is reached (the caller holds the lock)
    private func trim() {
        let limit = Settings.shared.songCacheMb * 1_048_576
        var total = manifest.values.reduce(0) { $0 + $1.size }
        for (id, e) in manifest.sorted(by: { $0.value.at < $1.value.at }) where total > limit {
            try? FileManager.default.removeItem(at: file(id))
            manifest[id] = nil
            total -= e.size
        }
    }
}
