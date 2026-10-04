import Foundation
import AppKit

// Where the Python engine, Kindle Comic Converter and kindlegen live.
enum Tools {
    static let home = NSHomeDirectory()
    /// venv with Pillow / PyMuPDF / natsort / mozjpeg etc. (made by ~/MangaKindle/setup.sh)
    static var python: String {
        if let o = UserDefaults.standard.string(forKey: "pythonPath"), !o.isEmpty,
           FileManager.default.isExecutableFile(atPath: o) { return o }
        return home + "/MangaKindle/venv/bin/python"
    }
    static var res: String { Bundle.main.resourcePath ?? "." }
    static var engine: String { res + "/engine/mangamerge.py" }
    static var kccDir: String { res + "/kcc" }
    static var binDir: String { res + "/bin" }

    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = binDir + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["PYTHONUNBUFFERED"] = "1"
        e["PYTHONIOENCODING"] = "utf-8"
        e["MK_KCC_DIR"] = kccDir
        e["MK_BIN_DIR"] = binDir
        e["LANG"] = e["LANG"] ?? "en_US.UTF-8"
        return e
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func descendants(of root: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,ppid="]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var children: [pid_t: [pid_t]] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count == 2, let a = pid_t(f[0]), let b = pid_t(f[1]) { children[b, default: []].append(a) }
        }
        var result: [pid_t] = [], queue = [root]
        while let x = queue.popLast() { for c in children[x] ?? [] { result.append(c); queue.append(c) } }
        return result
    }
}

// MARK: - model (mirrors the JSON from `mangamerge.py scan`)

struct Chapter: Codable, Identifiable, Hashable {
    var id: String { path }
    var path: String
    var kind: String
    var name: String
    var format: String
    var pages: Int
    var vol: Double?
    var ch: Double?
    var chText: String?
    var title: String
    var lang: String?
    var group: String?
    var selected: Bool
    var duplicate: Bool

    var chapterSort: Double { ch ?? .infinity }
    var chapterDisplay: String { chText ?? "?" }
    var volDisplay: String { vol.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" }
    var langDisplay: String { lang ?? "—" }
    var groupDisplay: String { group ?? "" }
    var key: String { chText ?? "name:" + name }
}

struct LangCount: Codable, Hashable { var code: String; var count: Int }

struct ScanResult: Codable {
    var title: String
    var language: String
    var languages: [LangCount]
    var items: [Chapter]
    var missing: [Int]
}

struct LogLine: Identifiable {
    let id: Int
    let text: String
    var isError: Bool { text.hasPrefix("ERROR") || text.contains("Traceback") || text.hasPrefix("  ! ") || text.hasPrefix("error") }
}

// MARK: - the whole job: scan → choose → merge → KCC

@MainActor
final class Job: ObservableObject {
    static let shared = Job()

    @Published var sources: [String] = []
    @Published var chapters: [Chapter] = []
    @Published var languages: [LangCount] = []
    @Published var language: String = "en" { didSet { if oldValue != language { autoSelect() } } }
    @Published var title = ""
    @Published var author = ""
    @Published var scanning = false
    @Published var scanError: String?

    // conversion state
    @Published var running = false
    @Published var stage = ""
    @Published var done = 0
    @Published var total = 0
    @Published var log: [LogLine] = []
    @Published var resultFiles: [String] = []
    @Published var errorMessage: String?
    @Published var summary: String?

    private var proc: Process?
    /// downloads that finished while another book was converting
    private var queued: [([String], String?, Bool)] = []
    /// set for "Convert & Send" runs: send to the Kindle even if auto-send is off
    private var sendThisRun = false
    @Published var queuedCount = 0
    private var pending = Data()
    private var counter = 0
    private var activity: NSObjectProtocol?
    private var stopped = false
    /// title of the book being converted (the Title field can be edited meanwhile)
    private(set) var convTitle = ""

    // MARK: settings (UserDefaults)
    @Published var format: String = UserDefaults.standard.string(forKey: "format") ?? "azw3" {
        didSet { UserDefaults.standard.set(format, forKey: "format") } }
    @Published var manga: Bool = UserDefaults.standard.object(forKey: "manga") as? Bool ?? true {
        didSet { UserDefaults.standard.set(manga, forKey: "manga") } }
    @Published var webtoon: Bool = UserDefaults.standard.bool(forKey: "webtoon") {
        didSet { UserDefaults.standard.set(webtoon, forKey: "webtoon") } }
    @Published var keepCbz: Bool = UserDefaults.standard.object(forKey: "keepCbz") as? Bool ?? false {
        didSet { UserDefaults.standard.set(keepCbz, forKey: "keepCbz") } }
    /// "best" = lossless 16-gray pages (KCC PNG mode); "jpeg90" / "jpeg70" = mozjpeg at that quality
    @Published var imageMode: String = UserDefaults.standard.string(forKey: "imageMode") ?? "best" {
        didSet { UserDefaults.standard.set(imageMode, forKey: "imageMode") } }
    @Published var autolevel: Bool = UserDefaults.standard.object(forKey: "autolevel") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autolevel, forKey: "autolevel") } }
    @Published var spreads: String = UserDefaults.standard.string(forKey: "spreads") ?? "both" {
        didSet { UserDefaults.standard.set(spreads, forKey: "spreads") } }
    @Published var crop: String = UserDefaults.standard.string(forKey: "crop") ?? "strong" {
        didSet { UserDefaults.standard.set(crop, forKey: "crop") } }
    @Published var borders: String = UserDefaults.standard.string(forKey: "borders") ?? "auto" {
        didSet { UserDefaults.standard.set(borders, forKey: "borders") } }
    @Published var tone: String = UserDefaults.standard.string(forKey: "tone") ?? "auto" {
        didSet { UserDefaults.standard.set(tone, forKey: "tone") } }
    @Published var hq: Bool = UserDefaults.standard.bool(forKey: "hq") {
        didSet { UserDefaults.standard.set(hq, forKey: "hq") } }
    @Published var outputDir: String = UserDefaults.standard.string(forKey: "outputDir")
        ?? (NSHomeDirectory() + "/Documents/Kindle") {
        didSet { UserDefaults.standard.set(outputDir, forKey: "outputDir") } }

    var selected: [Chapter] { chapters.filter(\.selected).sorted { ($0.chapterSort, $0.name) < ($1.chapterSort, $1.name) } }
    var selectedPages: Int { selected.reduce(0) { $0 + $1.pages } }

    var missing: [Int] {
        let nums = Set(selected.compactMap { $0.ch.map { Int($0) } })
        guard let lo = nums.min(), let hi = nums.max(), hi > lo else { return [] }
        return (lo...hi).filter { !nums.contains($0) }
    }

    var duplicateChapters: [String] {
        Dictionary(grouping: selected, by: \.key).filter { $0.value.count > 1 }.keys.sorted { a, b in
            (Double(a) ?? .infinity) < (Double(b) ?? .infinity) }
    }

    // MARK: scan

    func open(_ paths: [String], autoConvert: Bool = false, title overrideTitle: String? = nil, send: Bool = false) {
        guard !paths.isEmpty else { return }
        if running {
            // the same chapters again (a second click while busy) would just make a duplicate book
            if autoConvert && Set(paths) != Set(sources) && !queued.contains(where: { Set($0.0) == Set(paths) }) {
                queued.append((paths, overrideTitle, send)); queuedCount = queued.count
                if let t = overrideTitle {
                    Status.shared.set(t, \.convert, .waiting, "In line — “\(convTitle)” is converting first")
                }
            }
            return
        }
        sources = paths
        scanning = true
        scanError = nil
        resultFiles = []; errorMessage = nil; summary = nil
        let py = Tools.python, eng = Tools.engine, env = Tools.env
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: py)
            p.arguments = [eng, "scan"] + paths
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            var data = Data(), errData = Data()
            do {
                try p.run()
                data = out.fileHandleForReading.readDataToEndOfFile()
                errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            } catch {
                errData = Data("Could not start Python at \(py): \(error.localizedDescription)".utf8)
            }
            let result = try? JSONDecoder().decode(ScanResult.self, from: data)
            let errText = String(decoding: errData, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning = false
                    guard let r = result else {
                        self.scanError = errText.isEmpty ? "Could not read that folder." : String(errText.suffix(800))
                        return
                    }
                    if r.items.isEmpty {
                        self.scanError = "No manga files found (CBZ, ZIP, CBR, RAR, CB7, 7Z, PDF, EPUB or image folders)."
                    }
                    self.chapters = r.items
                    self.languages = r.languages
                    self.title = overrideTitle ?? r.title
                    self.language = r.language
                    self.autoSelect()
                    if autoConvert && !self.selected.isEmpty {
                        self.convert()
                        self.sendThisRun = send
                    } else if autoConvert {
                        self.startNextQueued()
                    }
                }
            }
        }
    }

    /// One file per chapter number: chosen language, then the scan group that covers the most chapters.
    func autoSelect() {
        var cov: [String: Int] = [:]
        let pool = chapters.indices.filter { i in
            (language == "*" || (chapters[i].lang ?? "") == language) && chapters[i].pages > 0 }
        for i in pool { cov[chapters[i].group ?? "", default: 0] += 1 }
        for i in chapters.indices { chapters[i].selected = false; chapters[i].duplicate = false }
        let groups = Dictionary(grouping: pool, by: { chapters[$0].key })
        for (_, idx) in groups {
            let ordered = idx.sorted { a, b in
                let ca = cov[chapters[a].group ?? ""] ?? 0, cb = cov[chapters[b].group ?? ""] ?? 0
                if ca != cb { return ca > cb }
                if chapters[a].pages != chapters[b].pages { return chapters[a].pages > chapters[b].pages }
                return chapters[a].name < chapters[b].name
            }
            chapters[ordered[0]].selected = true
            for d in ordered.dropFirst() { chapters[d].duplicate = true }
        }
    }

    /// Use this file for its chapter and untick other versions of the same chapter.
    func useOnly(_ c: Chapter) {
        for i in chapters.indices where chapters[i].key == c.key {
            chapters[i].selected = chapters[i].path == c.path
        }
    }

    func setAll(_ on: Bool, visible: [Chapter]) {
        let ids = Set(visible.map(\.id))
        for i in chapters.indices where ids.contains(chapters[i].id) { chapters[i].selected = on }
    }

    func clear() {
        guard !running else { return }
        sources = []; chapters = []; languages = []; title = ""; resultFiles = []; errorMessage = nil; summary = nil
        log = []
    }

    // MARK: convert

    func convert() {
        guard !running, !selected.isEmpty else { return }
        let items = selected
        let opts: [String: Any] = [
            "title": title.trimmingCharacters(in: .whitespaces).isEmpty ? "Manga" : title,
            "author": author, "format": format, "manga": manga, "webtoon": webtoon,
            "keepCbz": keepCbz, "imageMode": imageMode == "best" ? "best" : "jpeg",
            "jpegQuality": imageMode == "jpeg70" ? 70 : 90, "autolevel": autolevel, "hq": hq,
            "spreads": spreads, "crop": crop, "borders": borders, "tone": tone, "outputDir": outputDir, "profile": "KPW5",
        ]
        guard let itemsData = try? JSONEncoder().encode(items),
              let itemsObj = try? JSONSerialization.jsonObject(with: itemsData),
              let planData = try? JSONSerialization.data(withJSONObject: ["items": itemsObj, "options": opts]) else { return }
        let planPath = NSTemporaryDirectory() + "mangakindle-plan-\(UUID().uuidString).json"
        FileManager.default.createFile(atPath: planPath, contents: planData)

        log = []; resultFiles = []; errorMessage = nil; summary = nil
        sendThisRun = false
        done = 0; total = items.count; stage = "Starting…"; stopped = false
        convTitle = opts["title"] as? String ?? title
        if let t = Status.shared.tracks.first(where: { $0.id == Status.key(convTitle) }), t.convert?.state == .done || t.convert?.state == .failed {
            Status.shared.remove(t.id)        // converting the same book again: a fresh card
        }
        Status.shared.set(convTitle, \.convert, .active, "Merging \(items.count) chapters")
        Status.shared.set(convTitle, \.send, KindleDevice.shared.autoSend ? .waiting : .skipped,
                          KindleDevice.shared.autoSend ? "After converting" : "Auto-send is off — use “Send to Kindle”")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Tools.python)
        p.arguments = [Tools.engine, "build", planPath]
        p.environment = Tools.env
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pending.removeAll()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(d) } }
        }
        p.terminationHandler = { [weak self] pr in
            let code = pr.terminationStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { self?.finished(code, planPath: planPath) }
            }
        }
        do { try p.run() } catch {
            errorMessage = "Could not start Python (\(Tools.python)): \(error.localizedDescription)"
            return
        }
        proc = p
        running = true
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Converting manga for Kindle")
    }

    func stop() {
        guard let p = proc, p.isRunning else { return }
        stopped = true
        let pid = p.processIdentifier
        let kids = Tools.descendants(of: pid)
        kill(pid, SIGTERM)
        for k in kids { kill(k, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if p.isRunning { kill(pid, SIGKILL) }
            for k in kids { kill(k, SIGKILL) }
        }
    }

    private func consume(_ d: Data) {
        if d.isEmpty { return }
        pending.append(d)
        while let i = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let chunk = pending[pending.startIndex..<i]
            pending.removeSubrange(pending.startIndex...i)
            handle(String(decoding: chunk, as: UTF8.self))
        }
    }

    private func handle(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if line.hasPrefix("@@"), let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(2).utf8)) as? [String: Any] {
            switch obj["type"] as? String {
            case "stage":
                stage = obj["message"] as? String ?? ""
                if (obj["stage"] as? String) == "kcc" {
                    done = 0; total = 0
                    Status.shared.set(convTitle, \.convert, .active, "Making the Kindle file (resizing every page — slow for big books)")
                } else if !stage.isEmpty {
                    Status.shared.set(convTitle, \.convert, .active, stage)
                }
            case "progress":
                done = obj["done"] as? Int ?? done; total = obj["total"] as? Int ?? total
                append("✓ " + (obj["message"] as? String ?? ""))
            case "error":
                errorMessage = obj["message"] as? String
            case "done":
                resultFiles = obj["files"] as? [String] ?? []
                let pages = obj["pages"] as? Int ?? 0, chs = obj["chapters"] as? Int ?? 0
                summary = "\(chs) chapters · \(pages) pages"
                if let skipped = obj["skipped"] as? [String], !skipped.isEmpty {
                    summary! += " · skipped (unreadable): " + skipped.joined(separator: ", ")
                }
            default: break
            }
            return
        }
        append(line)
    }

    private func append(_ s: String) {
        counter += 1
        log.append(LogLine(id: counter, text: s))
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
    }

    /// Convert (and maybe send) several series one after another.
    func enqueue(_ items: [(paths: [String], title: String)], send: Bool) {
        for it in items where Set(it.paths) != Set(sources) || !running {
            if !queued.contains(where: { Set($0.0) == Set(it.paths) }) {
                queued.append((it.paths, it.title, send))
                Status.shared.start(it.title, download: false, convert: true)
                Status.shared.set(it.title, \.convert, .waiting, running ? "In line — “\(convTitle)” is converting first" : "Starting…")
            }
        }
        queuedCount = queued.count
        if !running && !scanning { startNextQueued() }
    }

    func cancelQueue() { queued = []; queuedCount = 0 }

    private func startNextQueued() {
        guard !queued.isEmpty, !running else { return }
        let (paths, t, send) = queued.removeFirst()
        queuedCount = queued.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.open(paths, autoConvert: true, title: t, send: send) }
    }

    private func finished(_ code: Int32, planPath: String) {
        if let p = proc { (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        if !pending.isEmpty { handle(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        proc = nil
        running = false
        try? FileManager.default.removeItem(atPath: planPath)
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        defer {
            startNextQueued()
        }
        if stopped {
            stage = "Stopped"; errorMessage = nil
            Status.shared.set(convTitle, \.convert, .failed, "Stopped")
            Status.shared.set(convTitle, \.send, .skipped, "—")
        } else if code == 0 && !resultFiles.isEmpty {
            stage = "Done"
            let books = kindleFiles
            let bytes = books.reduce(Int64(0)) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1))?[.size] as? Int64) ?? 0) }
            Status.shared.setBooks(convTitle, books)
            Status.shared.set(convTitle, \.convert, .done, "\(books.count) book\(books.count == 1 ? "" : "s") · "
                + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + (summary.map { " · " + $0 } ?? ""))
            if !(KindleDevice.shared.autoSend || sendThisRun) {
                Status.shared.set(convTitle, \.send, .skipped, "Auto-send is off — use “Send to Kindle”")
            }
            notify()
            if KindleDevice.shared.autoSend || sendThisRun { KindleDevice.shared.send(kindleFiles) }
        } else {
            stage = "Failed"
            if errorMessage == nil { errorMessage = "Conversion failed (exit \(code)). See the log below." }
            Status.shared.set(convTitle, \.convert, .failed, errorMessage ?? "Failed")
            Status.shared.set(convTitle, \.send, .skipped, "—")
        }
    }

    private func notify() {
        NSApp.requestUserAttention(.informationalRequest)
        NSSound(named: "Glass")?.play()
    }

    /// The Kindle books from the last conversion (with "Both", the AZW3 copies — one of each book is enough).
    var kindleFiles: [String] {
        let books = resultFiles.filter { $0.hasSuffix(".azw3") || $0.hasSuffix(".mobi") }
        let azw3 = books.filter { $0.hasSuffix(".azw3") }
        return azw3.isEmpty ? books : azw3
    }
}
