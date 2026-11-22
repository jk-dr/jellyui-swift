import Foundation

// Port of the app's lyrics-core.ts: lines, lead times, break rows (three dots), and the current-line search.

struct LyricWord: Decodable, Hashable {
    var t: Double
    var e: Double?
    var w: String
    /// a word sung in syllables: where each piece starts in the text (in characters) and when it is sung (the web's data-pt)
    var pt: [LyricPiece]? = nil
}

struct LyricPiece: Decodable, Hashable {
    var c: Int
    var t: Double
    var e: Double
}

struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var t: Double?
    var e: Double?
    var words: [LyricWord]?
    var back: [LyricWord]?
    var brk = false
    var lead: Double?
    var until: Double?
}

enum Lyr {
    static let lead = 0.25
    static let leadWords = 0.65
    static let brkMin = 7.0
    static let scrollLead = 0.85
    static let ahead = 0.025
    static let activeLead = 0.65

    static func capFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return s }
        let c = s[i]
        guard c.isLowercase else { return s }
        return String(s[..<i]) + c.uppercased() + String(s[s.index(after: i)...])
    }

    static func lineEnd(_ l: LyricLine, next: Double?) -> Double {
        let t = l.t ?? 0
        var e = l.words?.last?.e
        if e == nil || !(e! > t) { e = t + 3 }
        if let n = next { return min(e!, n) }
        return e!
    }

    /// From the plugin's parsed .ttml
    struct TtmlLine: Decodable {
        var text: String?
        var t: Double?
        var e: Double?
        var words: [LyricWord]?
        var back: [LyricWord]?
    }

    static func fromTtml(_ lines: [TtmlLine]) -> [LyricLine] {
        lines.map { l in
            let words = (l.words?.isEmpty ?? true) ? nil : l.words.map(Lyr.joinSyllables)
            let back: [LyricWord]? = words != nil && !(l.back?.isEmpty ?? true)
                ? Lyr.joinSyllables(Lyr.capitalFirst(l.back!.map { LyricWord(t: $0.t, e: $0.e, w: $0.w.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")) }))
                : nil
            return LyricLine(text: l.text ?? "", t: l.t, e: l.e, words: words, back: back)
        }
    }

    /// From Jellyfin's own lyrics (Start in 100 ns ticks; absent for plain lyrics)
    static func fromJellyfin(_ json: Any?) -> [LyricLine] {
        guard let o = json as? [String: Any], let ls = o["Lyrics"] as? [[String: Any]] else { return [] }
        return ls.compactMap { l in
            guard let text = l["Text"] as? String else { return nil }
            let start = (l["Start"] as? NSNumber)?.doubleValue
            return LyricLine(text: text, t: start.map { $0 / 1e7 })
        }
    }

    static func prep(_ input: [LyricLine], duration: Double) -> [LyricLine] {
        var lyr = input.map { l -> LyricLine in
            var m = l
            m.text = capFirst(l.text)
            if var w = m.words, !w.isEmpty { w[0].w = capFirst(w[0].w); m.words = w }
            return m
        }
        guard lyr.contains(where: { $0.t != nil }) else { return lyr }
        if lyr.allSatisfy({ $0.t != nil }) { lyr.sort { ($0.t ?? 0) < ($1.t ?? 0) } } // stable enough for timed lyrics
        var out: [LyricLine] = []
        var prev: LyricLine?
        for var l in lyr {
            if let p = prev, let lt = l.t, p.t != nil {
                let pe = lineEnd(p, next: lt)
                let gap = lt - pe
                if l.words != nil { l.lead = max(0.05, min(leadWords, gap - 0.05)) }
                if gap >= brkMin {
                    out.append(LyricLine(text: "", t: pe + 1, e: lt, brk: true, lead: 0, until: lt - (l.lead ?? lead)))
                }
            } else if let lt = l.t {
                if l.words != nil { l.lead = min(leadWords, max(0.05, lt - 0.3)) }
                if lt >= brkMin {
                    out.append(LyricLine(text: "", t: 0.5, e: lt, brk: true, lead: 0, until: lt - (l.lead ?? lead)))
                }
            }
            out.append(l)
            if l.t != nil { prev = l }
        }
        if let p = prev, duration > 0 {
            let le = lineEnd(p, next: nil)
            if duration - le >= brkMin {
                out.append(LyricLine(text: "", t: le + 1, e: duration, brk: true, lead: 0, until: duration - 0.5))
            }
        }
        return out
    }

    /// the moment a line becomes the current one
    static func activeStart(_ l: LyricLine) -> Double {
        guard let t = l.t else { return 1e9 }
        if l.words != nil { return t - min(activeLead, l.lead ?? activeLead) }
        return t - (l.lead ?? lead)
    }

    /// the slide to a line starts this early
    static func scrollStart(_ l: LyricLine) -> Double {
        guard let t = l.t else { return 1e9 }
        let ld = l.words != nil ? max(l.lead ?? 0, scrollLead) : (l.lead ?? (l.words != nil ? leadWords : lead))
        return t - ld
    }

    static func monotone(_ raw: [Double]) -> [Double] {
        var a: [Double] = []
        var hi = -Double.infinity
        for s in raw {
            if s == 1e9 { a.append(1e9) } else { hi = max(hi, s); a.append(hi) }
        }
        var nxt = 1e9
        var i = a.count - 1
        while i >= 0 {
            if raw[i] == 1e9 { a[i] = nxt } else { nxt = a[i] }
            i -= 1
        }
        return a
    }

    static func activeStarts(_ lines: [LyricLine]) -> [Double] { monotone(lines.map(activeStart)) }
    static func scrollStarts(_ lines: [LyricLine]) -> [Double] { monotone(lines.map(scrollStart)) }

    /// index of the last line whose start <= t, or -1
    static func indexAt(_ starts: [Double], _ t: Double) -> Int {
        var lo = 0, hi = starts.count - 1, idx = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= t { idx = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return idx
    }

    static func progress(_ w: LyricWord, _ t: Double) -> Double {
        let e = (w.e ?? 0) > w.t ? w.e! : w.t + 0.25
        if t <= w.t { return 0 }
        if t >= e { return 1 }
        return (t - w.t) / (e - w.t)
    }
}

// MARK: - Loading

/// The loaded lyrics, readable on the main thread at once: a skip shows the next song's lines in the same frame (they are loaded ahead).
@MainActor
enum LyricsMemo { static var map: [String: [LyricLine]] = [:] }

actor LyricsStore {
    static let shared = LyricsStore()
    private var done: [String: [LyricLine]] = [:]
    private var none: [String: Date] = [:]
    private var running: [String: Task<[LyricLine]?, Never>] = [:]
    private var failures: [String: Bool] = [:]

    func cached(_ id: String) -> [LyricLine]? { done[id] }
    func markFailed(_ id: String) { failures[id] = true }
    func didFail(_ id: String) -> Bool { failures[id] == true }

    func load(_ it: Item) async -> [LyricLine]? {
        if let c = done[it.id] { return c }
        if let at = none[it.id], Date().timeIntervalSince(at) < 1800 { return nil }
        failures[it.id] = nil
        if let t = running[it.id] { return await t.value }
        let t = Task<[LyricLine]?, Never> { await Self.fetch(it) }
        running[it.id] = t
        let r = await t.value
        running[it.id] = nil
        if let r {
            done[it.id] = r
            let id = it.id
            await MainActor.run { LyricsMemo.map[id] = r; if LyricsMemo.map.count > 60, let k = LyricsMemo.map.keys.first(where: { $0 != id }) { LyricsMemo.map[k] = nil } }
            if done.count > 40, let k = done.keys.first { done[k] = nil }
        } else if failures[it.id] != true {
            none[it.id] = Date() // a clean "no lyrics" answer is remembered; a failed request is not
            let id = it.id
            await MainActor.run { LyricsMemo.map[id] = [] }
        }
        return r
    }

    private static func fetch(_ it: Item) async -> [LyricLine]? {
        let duration = it.seconds
        // the word-timed file first, then Jellyfin's own
        struct Resp: Decodable { var blocked: Bool?; var lines: [Lyr.TtmlLine]? }
        var failed = false
        do {
            let r: Resp = try await Api.get("/JellyUI/Ttml/\(it.id)", ["t": Int(Date().timeIntervalSince1970 * 1000)], quiet: true)
            if r.blocked == true { return nil }
            if let ls = r.lines, !ls.isEmpty { return Lyr.prep(Lyr.fromTtml(ls), duration: duration) }
        } catch let e as ApiError where e.status == 404 {
            // no plugin: that is an answer, not a failure
        } catch { failed = true }
        do {
            let d = try await Api.request("/Audio/\(it.id)/Lyrics", quiet: true)
            if let j = try? JSONSerialization.jsonObject(with: d) {
                let ls = Lyr.fromJellyfin(j)
                if !ls.isEmpty { return Lyr.prep(ls, duration: duration) }
            }
        } catch let e as ApiError where e.status == 404 {
        } catch { failed = true }
        if failed { await LyricsStore.shared.markFailed(it.id) }
        return nil
    }
}


extension Lyr {
    /// the first letter of a line's first word made upper case (backing lines often start lower case)
    static func capitalFirst(_ ws: [LyricWord]) -> [LyricWord] {
        guard var w = ws.first(where: { $0.w.contains { $0.isLetter } }), let k = ws.firstIndex(of: w),
              let i = w.w.firstIndex(where: { $0.isLetter }) else { return ws }
        var out = ws
        w.w.replaceSubrange(i...i, with: String(w.w[i]).uppercased())
        out[k] = w
        return out
    }
}

extension Lyr {
    /// The web's wordGroups: the pieces of one word (sung in syllables, no space between them) become one word, from the first
    /// piece's start to the last one's end, with the pieces' places and times kept. Its fill is then one sweep and it rises once,
    /// instead of starting over (and hopping) at every syllable. A piece ending in a space or a dash ends a word.
    static func joinSyllables(_ ws: [LyricWord]) -> [LyricWord] {
        let n = ws.count
        guard n > 1, ws.dropLast().contains(where: { $0.w.last?.isWhitespace == true }) else { return ws } // (a line with no spaces, Chinese say: left as it is)
        func ends(_ k: Int) -> Bool {
            guard k < n - 1, let c = ws[k].w.last else { return true }
            return c.isWhitespace || "-\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}".contains(c)
        }
        var out: [LyricWord] = []
        var i = 0
        while i < n {
            var j = i
            while !ends(j) { j += 1 }
            if j > i && j - i < 8 {
                var text = "", pt: [LyricPiece] = []
                for k in i...j {
                    pt.append(LyricPiece(c: text.count, t: ws[k].t, e: ws[k].e ?? (ws[k].t + 0.25)))
                    text += ws[k].w
                }
                out.append(LyricWord(t: ws[i].t, e: ws[j].e ?? pt.last!.e, w: text, pt: pt))
            } else {
                out.append(contentsOf: ws[i...j])
            }
            i = j + 1
        }
        return out
    }
}
