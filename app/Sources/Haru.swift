import Foundation
import AppKit

// MARK: - models returned by engine/haru_page.js

struct SourceHit: Codable, Hashable {
    var source: String
    var sourceTitle: String
    var mangaId: String
    var title: String
    var official: Bool?
    var multi: Bool?
}

struct SearchGroup: Codable, Identifiable, Hashable {
    var id: String { key }
    var key: String
    var title: String
    var score: Double
    var sources: [SourceHit]
}

struct RankedSource: Codable, Identifiable, Hashable {
    var id: String { source + "|" + mangaId }
    var source: String
    var sourceTitle: String
    var mangaId: String
    var title: String
    var ok: Bool
    var error: String?
    var total: Int?
    var usable: Int?
    var distinct: Int?
    var latest: Double?
    var tagged: Bool?
    var best: Bool?
    var official: Bool?

    var latestText: String {
        guard let l = latest, l > 0 else { return "—" }
        return l == l.rounded() ? String(Int(l)) : String(l)
    }
}

struct ChapterInfo: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var num: Double?
    var lang: String?
    var group: String? {
        guard let r = title.range(of: #"\[([^\]]+)\]\s*$"#, options: .regularExpression) else { return nil }
        return String(title[r]).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
    }
    var numText: String {
        guard let n = num else { return "?" }
        return n == n.rounded() ? String(Int(n)) : String(n)
    }
}

struct ChapterList: Codable {
    var source: String
    var sourceTitle: String
    var mangaId: String
    var title: String
    var total: Int
    var distinct: Int
    var latest: Double
    var tagged: Bool
    var chapters: [ChapterInfo]
}

struct DLTask: Codable, Identifiable, Hashable {
    var id: String
    var chapter: String
    var manga: String?
    var source: String?
    var sourceId: String?
    var mangaId: String?
    var chapterId: String?
    var status: String
    var progress: Double
    var errors: [String]
    var finished: Bool { status == "completed" || status == "failed" }
}

/// A HaruNeko window that wants a "verify you are human" check (kept hidden until the user asks).
struct VerifyCheck: Codable, Identifiable, Hashable {
    var id: Int
    var url: String
    var since: Double
    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
}

struct BridgeError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A batch the user asked to download (and maybe convert when it finishes).
/// Replacement downloads for failed chapters are extra batches in the same `group` (the first batch's id).
/// Saved to disk, so downloads continue (and still convert) after the app or the Mac restarts.
struct Batch: Identifiable, Codable {
    var id = UUID()
    var group: UUID?
    var sourceId: String = ""
    var mangaId: String = ""
    var sourceTitle: String
    var mangaTitle: String
    var chapterIds: Set<String>
    var chapterTitles: [String]
    var titles: [String: String] = [:]       // chapter id → chapter title (to find its file)
    var nums: [String: Double] = [:]          // chapter id → chapter number
    var sources: [SourceHit] = []             // every source that has this manga (from the search)
    var convert: Bool
    var handled = false
    var queued = false                        // HaruNeko accepted it (until then old failed tasks don't count)
    var groupId: UUID { group ?? id }
}

/// One source's answer to "do you have these chapters?"
struct AltSource: Codable, Identifiable, Hashable {
    struct Ch: Codable, Hashable { var id: String; var title: String }
    var id: String { source + "|" + mangaId }
    var source: String
    var sourceTitle: String
    var mangaId: String
    var title: String
    var official: Bool?
    var ok: Bool
    var error: String?
    var has: [String: Ch]
    func chapter(_ n: Double) -> Ch? { has[AltSource.key(n)] }
    /// JS prints 12 as "12" and 12.5 as "12.5"
    static func key(_ n: Double) -> String { n == n.rounded() ? String(Int(n)) : String(n) }
}

/// Chapters that failed and are waiting for the user: find them elsewhere, or convert without them.
struct FixRequest: Identifiable, Codable {
    var id: UUID                              // the batch group
    var mangaTitle: String
    var failedSource: String                  // source title where they failed
    var failedSourceId: String
    var missing: [Double]
    var sources: [SourceHit]
    var convert: Bool                         // a book is waiting for these chapters
}

// MARK: - HaruNeko, driven in the background

@MainActor
final class Haru: ObservableObject {
    static let shared = Haru()

    enum State: Equatable { case idle, starting, connected, failed(String) }
    @Published var state: State = .idle
    @Published var sourcesIndexed = 0
    @Published var sourcesTotal = 0
    @Published var titles = 0

    // index
    @Published var indexing = false
    @Published var indexDone = 0
    @Published var indexTotal = 0
    @Published var indexCurrent: [String] = []
    private var indexProc: Process?

    // search
    @Published var query = ""
    @Published var searching = false
    @Published var results: [SearchGroup] = []
    @Published var searchError: String?
    @Published var picked: SearchGroup?
    @Published var ranking = false
    @Published var ranked: [RankedSource] = []
    @Published var source: RankedSource?
    @Published var loadingChapters = false
    @Published var chapterList: ChapterList?
    @Published var chosen = Set<String>()
    @Published var showAllLanguages = false

    // downloads
    @Published var tasks: [DLTask] = []
    @Published var batches: [Batch] = Haru.loadSaved().0 { didSet { save() } }
    @Published var autoFallback: Bool = UserDefaults.standard.object(forKey: "autoFallback") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoFallback, forKey: "autoFallback") } }
    private var resumed = false
    // Cloudflare-blocked chapters: unblock the site, then retry them once before other sources are tried
    private var cfTried = Set<String>()                 // task ids already handled
    private var cfHold: [String: Date] = [:]            // "source|chapter" → hold fallback until
    private var cfWaiting: [Int: [DLTask]] = [:]        // verify window id → chapters to retry once it's passed
    @Published var convertAfter: Bool = UserDefaults.standard.object(forKey: "convertAfter") as? Bool ?? true {
        didSet { UserDefaults.standard.set(convertAfter, forKey: "convertAfter") } }
    @Published var language: String = UserDefaults.standard.string(forKey: "searchLang") ?? "en" {
        didSet { UserDefaults.standard.set(language, forKey: "searchLang") } }
    @Published var checks: [VerifyCheck] = []
    @Published var fixes: [FixRequest] = Haru.loadSaved().1 { didSet { save() } }

    // MARK: saved downloads

    private static var savedURL: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MangaToKindle")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("downloads.json")
    }
    private struct Saved: Codable { var batches: [Batch]; var fixes: [FixRequest] }
    private static func loadSaved() -> ([Batch], [FixRequest]) {
        guard let d = try? Data(contentsOf: savedURL), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return ([], []) }
        // finished groups (converted, nothing waiting) aren't needed any more
        let open = Set(s.batches.filter { !$0.handled }.map(\.groupId)).union(s.fixes.map(\.id))
        var b = s.batches.filter { open.contains($0.groupId) }
        for i in b.indices where !b[i].handled { b[i].queued = false }   // re-checked by resume()
        return (b, s.fixes)
    }
    private func save() {
        guard let d = try? JSONEncoder().encode(Saved(batches: batches, fixes: fixes)) else { return }
        try? d.write(to: Haru.savedURL, options: .atomic)
    }

    /// After a restart: chapters that are neither in HaruNeko's queue nor on disk are queued again
    /// (only those — everything already downloaded stays).
    private func resume() async {
        guard !resumed else { return }
        resumed = true
        guard let t = try? await call("downloads", as: [DLTask].self, timeout: 30) else { resumed = false; return }
        tasks = t
        for b in batches where !b.handled {
            let lost = b.chapterIds.filter { cid in
                !tasks.contains { $0.chapterId == cid && $0.sourceId == b.sourceId } && fileFor(b, cid) == nil }
            if lost.isEmpty || b.mangaId.isEmpty {
                if let i = batches.firstIndex(where: { $0.id == b.id }) { batches[i].queued = true }
                continue
            }
            struct Q: Decodable { var queued: Int }
            do { _ = try await call("download", [b.sourceId, b.mangaId, Array(lost)], as: Q.self, timeout: 180) }
            catch { searchError = "Couldn't resume \(b.mangaTitle): \(error.localizedDescription)" }
            if let i = batches.firstIndex(where: { $0.id == b.id }) { batches[i].queued = true }
        }
        // saved "chapters failed" bars: check again — they may have arrived meanwhile (then the book is made now)
        for f in fixes { fixes.removeAll { $0.id == f.id }; groupFinished(f.id) }
        await poll()
    }
    private var checkTick = 0
    private var poller: Timer?
    private var weStarted = false

    var mediaDir: String {
        UserDefaults.standard.string(forKey: "haruDir") ?? (NSHomeDirectory() + "/Documents/HARUNEKU")
    }

    // MARK: bridge

    nonisolated static func run(_ args: [String], timeout: TimeInterval = 600) async -> (Int32, Data) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Tools.python)
                p.arguments = [Tools.res + "/engine/haru.py"] + args
                p.environment = Tools.env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: (-1, Data())); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: (p.terminationStatus, data))
            }
        }
    }

    func call<T: Decodable>(_ fn: String, _ args: [Any] = [], as: T.Type, timeout: TimeInterval = 600) async throws -> T {
        let argData = try JSONSerialization.data(withJSONObject: args)
        let (_, data) = await Haru.run(["call", fn, String(decoding: argData, as: UTF8.self)], timeout: timeout)
        if let err = try? JSONDecoder().decode([String: String].self, from: data), let m = err["error"] {
            if m.contains("not connected") { state = .idle }
            throw BridgeError(message: m)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw BridgeError(message: "Unexpected reply from HaruNeko: " + String(decoding: data.prefix(300), as: UTF8.self)) }
    }

    // MARK: lifecycle — HaruNeko runs hidden; nobody needs to open it

    func start() {
        guard state != .starting && state != .connected else { return }
        state = .starting
        Task {
            let (_, data) = await Haru.run(["ensure", "--restart", "--hide"], timeout: 180)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch obj?["state"] as? String {
            case "connected":
                weStarted = true
                state = .connected
                await refreshStatus()
                await resume()
                startPolling()
            case "missing":
                state = .failed("HaruNeko isn't installed (/Applications/HakuNeko.app).")
            default:
                state = .failed((obj?["message"] as? String) ?? (obj?["error"] as? String) ?? "Could not start HaruNeko.")
            }
        }
    }

    func refreshStatus() async {
        struct St: Decodable { var sources: Int; var indexed: Int; var titles: Int }
        if let s = try? await call("status", as: St.self, timeout: 20) {
            sourcesTotal = s.sources; sourcesIndexed = s.indexed; titles = s.titles
        }
    }

    func showHaruNeko() { Task { _ = await Haru.run(["window", "show"], timeout: 20) } }

    /// Quit the hidden HaruNeko when the app quits (only if nothing is downloading).
    func shutdown() {
        guard weStarted, !tasks.contains(where: { !$0.finished }) else { return }
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        q.arguments = ["-f", "HakuNeko.app/Contents/MacOS/hakuneko-electron"]
        try? q.run(); q.waitUntilExit()
    }

    // MARK: index (load every source's title list once; HaruNeko keeps them)

    func updateIndex() {
        guard !indexing, state == .connected else { return }
        indexing = true; indexDone = 0; indexTotal = 0; indexCurrent = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Tools.python)
        p.arguments = [Tools.res + "/engine/haru.py", "index", language]
        p.environment = Tools.env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        var buf = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    buf.append(d)
                    while let i = buf.firstIndex(of: 10) {
                        let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self)
                        buf.removeSubrange(buf.startIndex...i)
                        self?.indexLine(line)
                    }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    self?.indexing = false
                    Task { await self?.refreshStatus() }
                }
            }
        }
        try? p.run()
        indexProc = p
    }

    func stopIndex() {
        indexProc?.terminate()
        Task { _ = await Haru.run(["call", "stopIndex", "[]"], timeout: 20) }
    }

    private func indexLine(_ line: String) {
        guard line.hasPrefix("@@"), let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(2).utf8)) as? [String: Any] else { return }
        indexDone = o["done"] as? Int ?? indexDone
        indexTotal = o["total"] as? Int ?? indexTotal
        indexCurrent = o["current"] as? [String] ?? []
        if (o["type"] as? String) == "done" {
            sourcesIndexed = o["indexed"] as? Int ?? sourcesIndexed
            titles = o["titles"] as? Int ?? titles
        }
    }

    // MARK: search → rank sources → chapters

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, state == .connected else { return }
        searching = true; searchError = nil; picked = nil; ranked = []; source = nil; chapterList = nil
        Task {
            defer { searching = false }
            do {
                if q.lowercased().hasPrefix("http") {
                    let hit = try await call("fromURL", [q], as: SourceHit?.self, timeout: 120)
                    guard let h = hit else { searchError = "No HaruNeko source recognises that link."; results = []; return }
                    let g = SearchGroup(key: h.title.lowercased(), title: h.title, score: 100, sources: [h])
                    results = [g]
                    pick(g)
                } else {
                    results = try await call("search", [q, language, false, 40], as: [SearchGroup].self, timeout: 60)
                    if results.isEmpty {
                        searchError = sourcesIndexed < 20
                            ? "Nothing found yet — only \(sourcesIndexed) sources are loaded. Click “Update Sources” once to load all of them."
                            : "Nothing found. Try a shorter name, the Japanese/romaji title, or paste the manga's link."
                    } else if let first = results.first, first.score >= 99 {
                        pick(first)
                    }
                }
            } catch { searchError = error.localizedDescription }
        }
    }

    func pick(_ g: SearchGroup) {
        picked = g; ranked = []; source = nil; chapterList = nil; ranking = true
        let items = g.sources.map { s -> [String: Any] in
            ["source": s.source, "sourceTitle": s.sourceTitle, "mangaId": s.mangaId, "title": s.title,
             "official": s.official ?? false] }
        Task {
            defer { ranking = false }
            do {
                let r = try await call("rank", [items, language, 6], as: [RankedSource].self, timeout: 120)
                guard picked?.id == g.id else { return }
                ranked = r
                if let best = r.first(where: { $0.ok }) { open(best) }
            } catch { searchError = error.localizedDescription }
        }
    }

    func open(_ r: RankedSource) {
        source = r; chapterList = nil; chosen = []; loadingChapters = true
        Task {
            defer { loadingChapters = false }
            do {
                let list = try await call("chapters", [r.source, r.mangaId, language], as: ChapterList.self, timeout: 90)
                guard source?.id == r.id else { return }
                chapterList = list
                chosen = defaultSelection(list)
            } catch { searchError = error.localizedDescription }
        }
    }

    /// Chapters in my language; one per chapter number (the scan group with the most chapters wins).
    func visibleChapters(_ list: ChapterList) -> [ChapterInfo] {
        let mine = list.chapters.filter { c in
            showAllLanguages || !list.tagged || c.lang == language || (c.lang ?? "").hasPrefix(language + "-") }
        return mine.sorted { ($0.num ?? .infinity, $0.title) < ($1.num ?? .infinity, $1.title) }
    }

    func defaultSelection(_ list: ChapterList) -> Set<String> {
        let mine = list.chapters.filter { c in !list.tagged || c.lang == language || (c.lang ?? "").hasPrefix(language + "-") }
        var cov: [String: Int] = [:]
        for c in mine { cov[c.group ?? "", default: 0] += 1 }
        var pick: [String: ChapterInfo] = [:]
        for c in mine {
            let k = c.num.map { String($0) } ?? "t:" + c.title
            if let cur = pick[k] {
                if (cov[c.group ?? ""] ?? 0) > (cov[cur.group ?? ""] ?? 0) { pick[k] = c }
            } else { pick[k] = c }
        }
        return Set(pick.values.map(\.id))
    }

    // MARK: downloads

    func download(convert: Bool) {
        guard let list = chapterList, !chosen.isEmpty else { return }
        let ids = Array(chosen)
        // already downloading exactly these chapters → don't start a second (duplicate) book
        if batches.contains(where: { !$0.handled && $0.sourceId == list.source && $0.chapterIds == Set(ids) }) { return }
        let picked = list.chapters.filter { chosen.contains($0.id) }
        var nums: [String: Double] = [:]
        for c in picked { if let n = c.num { nums[c.id] = n } }
        var titles: [String: String] = [:]
        for c in picked { titles[c.id] = c.title }
        let b = Batch(sourceId: list.source, mangaId: list.mangaId, sourceTitle: list.sourceTitle, mangaTitle: list.title,
                      chapterIds: Set(ids), chapterTitles: picked.map(\.title), titles: titles, nums: nums,
                      sources: self.picked?.sources ?? [], convert: convert)
        batches.append(b)
        Status.shared.start(list.title, download: true, convert: convert)
        Status.shared.set(list.title, \.download, .active, "Queued \(ids.count) chapter\(ids.count == 1 ? "" : "s") from \(list.sourceTitle)")
        enqueue(b, mangaId: list.mangaId)
    }

    private func enqueue(_ b: Batch, mangaId: String) {
        Task {
            struct Q: Decodable { var queued: Int }
            do { _ = try await call("download", [b.sourceId, mangaId, Array(b.chapterIds)], as: Q.self, timeout: 120) }
            catch { searchError = error.localizedDescription }
            if let i = batches.firstIndex(where: { $0.id == b.id }) { batches[i].queued = true }
            await poll()
        }
    }

    func startPolling() {
        poller?.invalidate()
        poller = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .connected else { return }
                self.checkTick += 1
                if self.checkTick % 3 == 0 { Task { await self.pollChecks() } }
                if self.tasks.contains(where: { !$0.finished }) || self.batches.contains(where: { !$0.handled }) {
                    Task { await self.poll() }
                }
            }
        }
    }

    private var polling = false
    func poll() async {
        guard !polling else { return }
        polling = true; defer { polling = false }
        guard let t = try? await call("downloads", as: [DLTask].self, timeout: 30) else { return }
        tasks = t
        handleCloudflare()
        checkBatches()
        updateDownloadStatus()
    }

    /// live "Download" step of every group that is still downloading (from HaruNeko's queue only — cheap)
    private func updateDownloadStatus() {
        for root in batches where root.id == root.groupId {
            let group = batches.filter { $0.groupId == root.id }
            guard group.contains(where: { !$0.handled }) else { continue }
            let total = root.nums.isEmpty ? root.chapterIds.count : Set(root.nums.values.map(AltSource.key)).count
            var got = Set<String>(), failed = Set<String>()
            for b in group {
                for t in tasksOf(b) {
                    let k = (t.chapterId.flatMap { b.nums[$0] }).map(AltSource.key) ?? t.id
                    if t.status == "completed" { got.insert(k) } else if t.status == "failed" { failed.insert(k) }
                }
            }
            failed.subtract(got)
            var d = "\(got.count) of \(total) chapters downloaded"
            let others = Array(Set(group.filter { !$0.handled && $0.group != nil }.map(\.sourceTitle))).sorted()
            if !others.isEmpty { d += " · getting failed ones from " + others.joined(separator: ", ") }
            if !failed.isEmpty && others.isEmpty { d += " · \(failed.count) failed so far" }
            if !cfWaiting.isEmpty { d += " · a site needs “Verify Now” (orange bar)" }
            Status.shared.set(root.mangaTitle, \.download, .active, d)
        }
    }

    private func handleCloudflare() {
        let blocked = tasks.filter { t in
            t.status == "failed" && !cfTried.contains(t.id) && t.errors.contains { $0.localizedCaseInsensitiveContains("cloudflare") } }
        guard !blocked.isEmpty else { return }
        for t in blocked { cfTried.insert(t.id); cfHold[(t.sourceId ?? "") + "|" + (t.chapterId ?? "")] = Date().addingTimeInterval(240) }
        let url = blocked.lazy.compactMap { t in t.errors.lazy.compactMap { e -> String? in
            guard let r = e.range(of: #"https?://[^"\s]+"#, options: .regularExpression) else { return nil }
            return String(e[r]) }.first }.first
        guard let url else { release(blocked); return }
        Task {
            let (_, data) = await Haru.run(["unblock", url], timeout: 90)
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch o?["state"] as? String {
            case "clear": await retry(blocked)
            case "human":
                if let id = o?["id"] as? Int { cfWaiting[id] = blocked }
                await pollChecks()                   // "Verify Now" banner
            default: release(blocked)
            }
        }
    }

    private func release(_ ts: [DLTask]) {
        for t in ts { cfHold[(t.sourceId ?? "") + "|" + (t.chapterId ?? "")] = nil }
    }

    private func held(_ b: Batch) -> Bool {
        let now = Date()
        return b.chapterIds.contains { cid in (cfHold[b.sourceId + "|" + cid] ?? .distantPast) > now }
    }

    /// queue the same chapters again on the same source (their old failed tasks are replaced)
    private func retry(_ ts: [DLTask]) async {
        var bySrc: [String: (String, String, [String])] = [:]
        for t in ts {
            guard let s = t.sourceId, let m = t.mangaId, let c = t.chapterId else { continue }
            bySrc[s + "|" + m, default: (s, m, [])].2.append(c)
        }
        for (_, (s, m, ids)) in bySrc {
            struct Q: Decodable { var queued: Int }
            _ = try? await call("download", [s, m, ids], as: Q.self, timeout: 120)
        }
        // their batches are open again until the retry finishes
        for i in batches.indices where batches[i].handled {
            if ts.contains(where: { $0.sourceId == batches[i].sourceId && batches[i].chapterIds.contains($0.chapterId ?? "") }) {
                batches[i].handled = false
            }
        }
        release(ts)
        await poll()
    }

    func pollChecks() async {
        let (_, data) = await Haru.run(["checks"], timeout: 15)
        if let c = try? JSONDecoder().decode([VerifyCheck].self, from: data) { checks = c }
    }

    func verify(_ c: VerifyCheck) {
        Task {
            _ = await Haru.run(["verify", String(c.id)], timeout: 15)
            checks.removeAll { $0.id == c.id }
            // a site that blocked downloads: once the check is passed, retry those chapters
            guard let waiting = cfWaiting.removeValue(forKey: c.id) else { return }
            for t in waiting { cfHold[(t.sourceId ?? "") + "|" + (t.chapterId ?? "")] = Date().addingTimeInterval(600) }
            for _ in 0..<150 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                let (_, data) = await Haru.run(["cfstate", String(c.id)], timeout: 20)
                let st = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["state"] as? String
                if st == "clear" { await retry(waiting); return }
                if st == "gone" { break }
            }
            release(waiting)
        }
    }

    func clearFinished() {
        Task { _ = try? await call("clearFinished", as: Int.self, timeout: 30); await poll() }
    }

    func cancel(_ ids: [String]) {
        Task { _ = try? await call("cancel", [ids], as: Int.self, timeout: 30); await poll() }
    }

    /// When every chapter of a batch is finished: open those files in the converter (and convert).
    private func tasksOf(_ b: Batch) -> [DLTask] {
        tasks.filter { b.chapterIds.contains($0.chapterId ?? "") && (b.sourceId.isEmpty || $0.sourceId == b.sourceId) }
    }

    /// completed / failed / queued / downloading — from HaruNeko's queue, else from the disk
    /// (a chapter that is in neither was lost, e.g. cleared from the list: it counts as failed).
    private func chapterState(_ b: Batch, _ cid: String) -> String {
        if let t = tasks.first(where: { $0.chapterId == cid && (b.sourceId.isEmpty || $0.sourceId == b.sourceId) }) {
            return t.status
        }
        return fileFor(b, cid) != nil ? "completed" : "failed"
    }

    private func checkBatches() {
        var finishedGroups: [UUID] = []
        for i in batches.indices where !batches[i].handled && batches[i].queued && !held(batches[i]) {
            let b = batches[i]
            guard b.chapterIds.allSatisfy({ ["completed", "failed"].contains(chapterState(b, $0)) }) else { continue }
            batches[i].handled = true
            finishedGroups.append(b.groupId)
        }
        for g in Set(finishedGroups) { groupFinished(g) }
    }

    /// Every batch of a group is done: convert, or (if chapters failed) ask what to do about them.
    private func groupFinished(_ g: UUID) {
        let group = batches.filter { $0.groupId == g }
        guard let root = group.first(where: { $0.id == g }), group.allSatisfy(\.handled) else { return }
        var got = Set<String>()
        var failedSrc: (String, String)?
        for b in group {
            for cid in b.chapterIds {
                guard let n = b.nums[cid] else { continue }
                if chapterState(b, cid) == "completed" { got.insert(AltSource.key(n)) }
                else { failedSrc = (b.sourceTitle, b.sourceId) }
            }
        }
        let missing = root.nums.values.filter { !got.contains(AltSource.key($0)) }
        let missingSorted = Array(Set(missing)).sorted()
        if !missingSorted.isEmpty {
            let f = FixRequest(id: g, mangaTitle: root.mangaTitle, failedSource: failedSrc?.0 ?? root.sourceTitle,
                               failedSourceId: failedSrc?.1 ?? root.sourceId, missing: missingSorted,
                               sources: root.sources, convert: root.convert)
            Status.shared.set(root.mangaTitle, \.download, autoFallback ? .active : .failed, autoFallback
                ? "\(missingSorted.count) chapter\(missingSorted.count == 1 ? "" : "s") failed on \(f.failedSource) — looking on other sources…"
                : "\(missingSorted.count) chapter\(missingSorted.count == 1 ? "" : "s") failed (\(FixSheet.numList(missingSorted))) — see the orange bar")
            if autoFallback {
                let tried = Set(group.map(\.sourceId))
                Task { await autoReplace(f, tried: tried) }
            } else {
                fixes.removeAll { $0.id == g }
                fixes.append(f)
            }
            return
        }
        Status.shared.set(root.mangaTitle, \.download, .done, "All \(Set(root.nums.values.map(AltSource.key)).count) chapters downloaded")
        if root.convert { convertGroup(g) }
    }

    private func convertGroup(_ g: UUID) {
        let group = batches.filter { $0.groupId == g }
        guard let root = group.first(where: { $0.id == g }) else { return }
        let files = Array(Set(group.flatMap { findFiles($0) })).sorted()
        guard !files.isEmpty else { return }
        Job.shared.open(files, autoConvert: true, title: root.mangaTitle)
        NotificationCenter.default.post(name: .showConverter, object: nil)
    }

    // MARK: failed chapters → other sources

    /// Failed chapters: fetch each from the best source that wasn't tried yet for this download.
    /// Only the missing chapters are fetched. Asks the user (banner) when no untried source has them.
    private func autoReplace(_ f: FixRequest, tried: Set<String>) async {
        var picks: [Double: AltSource] = [:]
        if let alts = try? await alternatives(for: f) {
            let fresh = alts.filter { $0.ok && !tried.contains($0.source) }   // already sorted: most of the missing first
            for n in f.missing { if let a = fresh.first(where: { $0.chapter(n) != nil }) { picks[n] = a } }
        }
        if picks.isEmpty {
            fixes.removeAll { $0.id == f.id }
            fixes.append(f)
            Status.shared.set(f.mangaTitle, \.download, .failed,
                "\(f.missing.count) chapter\(f.missing.count == 1 ? "" : "s") (\(FixSheet.numList(f.missing))) not on any other source — "
                + "use the orange bar: Get from Other Sources or Convert Without Them")
        } else {
            downloadReplacements(f, picks: picks)   // chapters nobody else has come back on the next round
        }
    }

    /// "Convert without them": build the book from what did download.
    func convertWithout(_ f: FixRequest) {
        fixes.removeAll { $0.id == f.id }
        Status.shared.set(f.mangaTitle, \.download, .done, "Done without \(f.missing.count) chapter\(f.missing.count == 1 ? "" : "s") (\(FixSheet.numList(f.missing)))")
        convertGroup(f.id)
    }

    func dismissFix(_ f: FixRequest) {
        fixes.removeAll { $0.id == f.id }
        Status.shared.set(f.mangaTitle, \.download, .failed, "\(f.missing.count) chapter\(f.missing.count == 1 ? "" : "s") missing — dismissed, nothing converted")
        if f.convert { Status.shared.set(f.mangaTitle, \.convert, .skipped, "Not converted") ; Status.shared.set(f.mangaTitle, \.send, .skipped, "—") }
    }

    /// Which sources have the missing chapters. Uses the search result's sources; searches by title if there are none.
    func alternatives(for f: FixRequest) async throws -> [AltSource] {
        var items = f.sources
        if items.isEmpty {
            let groups = try await call("search", [f.mangaTitle, language, false, 10], as: [SearchGroup].self, timeout: 60)
            let want = f.mangaTitle.lowercased()
            items = (groups.first { $0.title.lowercased() == want } ?? groups.first)?.sources ?? []
        }
        guard !items.isEmpty else { return [] }
        let arg = items.map { s -> [String: Any] in
            ["source": s.source, "sourceTitle": s.sourceTitle, "mangaId": s.mangaId, "title": s.title, "official": s.official ?? false] }
        return try await call("alternatives", [arg, f.missing, language, 6], as: [AltSource].self, timeout: 180)
    }

    /// Download the chosen replacements (chapter number → source); they join the original batch group.
    func downloadReplacements(_ f: FixRequest, picks: [Double: AltSource]) {
        fixes.removeAll { $0.id == f.id }
        let names = Array(Set(picks.values.map(\.sourceTitle))).sorted().joined(separator: ", ")
        Status.shared.set(f.mangaTitle, \.download, .active, "Getting \(picks.count) failed chapter\(picks.count == 1 ? "" : "s") from \(names)")
        var bySource: [String: (AltSource, [(Double, AltSource.Ch)])] = [:]
        for (n, src) in picks { if let ch = src.chapter(n) { bySource[src.id, default: (src, [])].1.append((n, ch)) } }
        for (_, (src, chs)) in bySource {
            var nums: [String: Double] = [:]
            for (n, ch) in chs { nums[ch.id] = n }
            var titles: [String: String] = [:]
            for (_, ch) in chs { titles[ch.id] = ch.title }
            let b = Batch(group: f.id, sourceId: src.source, mangaId: src.mangaId, sourceTitle: src.sourceTitle, mangaTitle: src.title,
                          chapterIds: Set(chs.map(\.1.id)), chapterTitles: chs.map(\.1.title), titles: titles, nums: nums,
                          sources: f.sources, convert: f.convert)
            batches.append(b)
            enqueue(b, mangaId: src.mangaId)
        }
    }

    /// Failed downloads that don't belong to a batch of this session (e.g. queued before a restart).
    func fixFromTasks(_ failed: [DLTask]) {
        guard let first = failed.first else { return }
        let same = failed.filter { $0.manga == first.manga && $0.sourceId == first.sourceId }
        Task {
            let nums = (try? await call("chNums", [same.map(\.chapter)], as: [Double?].self, timeout: 20)) ?? []
            let ns = Array(Set(nums.compactMap { $0 })).sorted()
            guard !ns.isEmpty else { searchError = "Couldn't read chapter numbers of the failed downloads."; return }
            var b = Batch(sourceId: first.sourceId ?? "", sourceTitle: first.source ?? "", mangaTitle: first.manga ?? "",
                          chapterIds: Set(same.compactMap(\.chapterId)), chapterTitles: same.map(\.chapter), convert: false)
            b.mangaId = first.mangaId ?? ""
            for (t, n) in zip(same, nums) { if let c = t.chapterId { b.titles[c] = t.chapter; if let n { b.nums[c] = n } } }
            b.handled = true
            batches.append(b)
            fixes.removeAll { $0.id == b.id }
            fixes.append(FixRequest(id: b.id, mangaTitle: b.mangaTitle, failedSource: b.sourceTitle, failedSourceId: b.sourceId,
                                    missing: ns, sources: [], convert: false))
        }
    }

    /// chapter number of a task: from its batch, else parsed from the title ("Ch.21.5 - Omake", "Chapter 182 …")
    func number(of t: DLTask) -> Double? {
        if let cid = t.chapterId, let b = batches.first(where: { $0.sourceId == t.sourceId && $0.nums[cid] != nil }) { return b.nums[cid] }
        let s = t.chapter.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        guard let r = s.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(s[r])
    }

    /// Failed chapters that are still missing: one per manga + chapter number (a chapter that failed on two sources
    /// counts once; one that later downloaded from another source doesn't count).
    var stillFailed: [DLTask] {
        func key(_ t: DLTask) -> String { (t.manga ?? "") + "#" + (number(of: t).map(AltSource.key) ?? t.chapter) }
        let got = Set(tasks.filter { $0.status == "completed" }.map(key))
        var seen = Set<String>()
        return tasks.filter { t in
            guard t.status == "failed" else { return false }
            let k = key(t)
            return !got.contains(k) && seen.insert(k).inserted
        }
    }

    /// failed tasks not covered by a batch of this session
    var orphanFailed: [DLTask] {
        stillFailed.filter { t in !batches.contains { b in
            b.chapterIds.contains(t.chapterId ?? "") && (b.sourceId.isEmpty || b.sourceId == t.sourceId) } }
    }

    /// HaruNeko saves <media dir>/<source>/<manga>/<chapter>.cbz (names cleaned of illegal characters).
    func findFiles(_ b: Batch) -> [String] {
        if !b.titles.isEmpty { return b.chapterIds.compactMap { fileFor(b, $0) }.sorted() }
        return findFilesByTitles(b)
    }

    /// the downloaded file of one chapter of a batch, if it's there
    func fileFor(_ b: Batch, _ cid: String) -> String? {
        guard let t = b.titles[cid] else { return nil }
        var one = b; one.chapterTitles = [t]
        return findFilesByTitles(one).first
    }

    private func findFilesByTitles(_ b: Batch) -> [String] {
        let fm = FileManager.default
        func clean(_ s: String) -> String {
            s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        func child(_ dir: String, _ name: String) -> String? {
            let want = clean(name)
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
            if let hit = items.first(where: { clean($0) == want }) { return dir + "/" + hit }
            return items.first(where: { clean($0).hasPrefix(want) || want.hasPrefix(clean($0)) && !clean($0).isEmpty })
                .map { dir + "/" + $0 }
        }
        guard let srcDir = child(mediaDir, b.sourceTitle), let mangaDir = child(srcDir, b.mangaTitle) else { return [] }
        let wanted = Set(b.chapterTitles.map(clean))
        let items = (try? fm.contentsOfDirectory(atPath: mangaDir)) ?? []
        return items.filter { name in
            let stem = (name as NSString).deletingPathExtension
            return wanted.contains(clean(stem)) || wanted.contains(clean(name))
        }.map { mangaDir + "/" + $0 }.sorted()
    }
}

extension Notification.Name {
    static let showConverter = Notification.Name("mk.showConverter")
}
