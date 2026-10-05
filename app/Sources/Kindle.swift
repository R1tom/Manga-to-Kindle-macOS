import SwiftUI
import AppKit

struct KindleBook: Codable, Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var size: Int64
    var modified: Double
    var folder: String
}

struct DeviceBook: Codable, Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var rel: String
    var folder: String
    var title: String
    var size: Int64
    var modified: Double
    var ext: String
    var kind: String   // book · document · store · dictionary
}

struct OrphanData: Codable, Identifiable, Hashable {
    var id: String { path }
    var path: String
    var rel: String
    var size: Int64
}

/// Kindle plugged in over USB (shows up as a drive with documents/ + system/).
@MainActor
final class KindleDevice: ObservableObject {
    static let shared = KindleDevice()

    @Published var mount: String?
    @Published var name = ""
    @Published var free: Int64 = 0
    @Published var total: Int64 = 0
    @Published var books: [KindleBook] = []
    @Published var allBooks: [DeviceBook] = []
    @Published var orphans: [OrphanData] = []
    @Published var loadingAll = false
    @Published var deleting = false

    @Published var sending = false
    @Published var sendDone: Int64 = 0
    @Published var sendTotal: Int64 = 0
    @Published var sendName = ""
    @Published var message: String?
    @Published var messageIsError = false
    @Published var waiting: [String] = []   // files to send as soon as the Kindle is plugged in
    @Published var ejecting = false

    @Published var folder: String = UserDefaults.standard.string(forKey: "kindleFolder") ?? "Manga" {
        didSet { UserDefaults.standard.set(folder, forKey: "kindleFolder") } }
    /// "direct" = byte-for-byte copy (default) · "calibre" = calibre's Kindle driver
    @Published var method: String = UserDefaults.standard.string(forKey: "kindleMethod") ?? "direct" {
        didSet { UserDefaults.standard.set(method, forKey: "kindleMethod") } }
    @Published var autoSend: Bool = UserDefaults.standard.object(forKey: "kindleAutoSend") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSend, forKey: "kindleAutoSend") } }
    @Published var ejectAfter: Bool = UserDefaults.standard.bool(forKey: "kindleEjectAfter") {
        didSet { UserDefaults.standard.set(ejectAfter, forKey: "kindleEjectAfter") } }

    var connected: Bool { mount != nil }
    static let calibre = "/Applications/calibre.app/Contents/MacOS/calibre-debug"
    var calibreInstalled: Bool { FileManager.default.isExecutableFile(atPath: KindleDevice.calibre) }

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { KindleDevice.shared.refresh() }
            }
        }
        // never leave the Kindle mounted when the Mac sleeps, restarts, shuts down or logs out
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KindleDevice.shared.ejectBeforePowerChange(reason: "sleep") }
        }
        nc.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                KindleDevice.shared.poweringOff = true
                KindleDevice.shared.ejectBeforePowerChange(reason: "restart/shut down")
            }
        }
        refresh()
    }

    @Published var autoEjectOnPower: Bool = UserDefaults.standard.object(forKey: "kindleAutoEjectPower") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoEjectOnPower, forKey: "kindleAutoEjectPower") } }
    private var sendActivity: NSObjectProtocol?
    var poweringOff = false

    /// Synchronous safe eject (sync + diskutil), used right before sleep / power-off when there's no time for async work.
    @discardableResult
    func ejectNow(timeout: TimeInterval = 15) -> Bool {
        guard let m = mount else { return true }
        func run(_ exe: String, _ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return -1 }
            let end = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < end { usleep(50_000) }
            if p.isRunning { p.terminate(); return -2 }
            return p.terminationStatus
        }
        _ = run("/bin/sync", [])
        for _ in 0..<3 {
            if run("/usr/sbin/diskutil", ["eject", m]) == 0 { mount = nil; return true }
            usleep(700_000)
        }
        return false
    }

    func ejectBeforePowerChange(reason: String) {
        guard autoEjectOnPower, connected else { return }
        if sending {
            // the Kindle is busy with a copy, so it can't be ejected; quitting asks to wait, and the copy
            // keeps going after wake (a half-written book is only ever a hidden .mk-partial file)
            message = "The Mac is going to \(reason) while books are copying — eject the Kindle when it finishes."
            messageIsError = true
            return
        }
        let ok = ejectNow()
        message = ok ? "Kindle ejected automatically before \(reason) — safe to unplug."
                     : "Couldn't eject the Kindle before \(reason). Eject it before unplugging."
        messageIsError = !ok
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        var found: String?
        for v in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            let p = "/Volumes/" + v
            var dir: ObjCBool = false
            if fm.fileExists(atPath: p + "/documents", isDirectory: &dir), dir.boolValue,
               fm.fileExists(atPath: p + "/system", isDirectory: &dir), dir.boolValue {
                found = p; break
            }
        }
        let was = mount
        mount = found
        if let m = found {
            name = URL(fileURLWithPath: m).lastPathComponent
            if let a = try? URL(fileURLWithPath: m).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) {
                free = Int64(a.volumeAvailableCapacity ?? 0); total = Int64(a.volumeTotalCapacity ?? 0)
            }
            if was == nil {
                loadBooks()
                if !waiting.isEmpty {
                    let files = waiting; waiting = []
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.send(files) }
                }
            }
        } else {
            books = []
            if was != nil && !ejecting { message = nil }
        }
    }

    // MARK: running the engine

    private func run(_ args: [String], onLine: ((String) -> Void)? = nil) async -> (Int32, String) {
        let python = Tools.python, script = Tools.res + "/engine/kindle.py", env = Tools.env
        let useCalibre = args.first == "calibre-send"
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                if useCalibre {
                    p.executableURL = URL(fileURLWithPath: KindleDevice.calibre)
                    p.arguments = ["-e", Tools.res + "/engine/calibre_send.py", "--", "send"] + Array(args.dropFirst())
                } else {
                    p.executableURL = URL(fileURLWithPath: python)
                    p.arguments = [script] + args
                }
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe
                var all = Data(), buf = Data()
                do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)); return }
                let h = pipe.fileHandleForReading
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    all.append(d); buf.append(d)
                    while let i = buf.firstIndex(of: 10) {
                        let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self)
                        buf.removeSubrange(buf.startIndex...i)
                        if let cb = onLine { DispatchQueue.main.async { cb(line) } }
                    }
                }
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: all, as: UTF8.self)))
            }
        }
    }

    func loadBooks() {
        Task {
            let (_, out) = await run(["list", "--folder", folder])
            struct L: Decodable { var books: [KindleBook] }
            if let l = try? JSONDecoder().decode(L.self, from: Data(out.utf8)) {
                books = l.books.sorted { $0.modified > $1.modified }
            }
        }
    }

    /// Send books (only .azw3 / .mobi / .pdf / .epub are sent). Queues them if no Kindle is plugged in.
    func send(_ files: [String]) {
        let books = files.filter { ["azw3", "mobi", "azw", "kfx", "pdf", "epub"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        guard !books.isEmpty else { return }
        // ebooks (from the Books search) go to documents/Books, manga to documents/<folder>
        let isEbook: (String) -> Bool = { $0.hasPrefix(BookStore.outputDir + "/") }
        if books.contains(where: isEbook) && !books.allSatisfy(isEbook) {
            send(books.filter { !isEbook($0) })
            send(books.filter(isEbook))
            return
        }
        let target = books.allSatisfy(isEbook) ? "Books" : folder
        let titles = Array(Set(books.compactMap { Status.shared.title(forFile: $0) }))
        guard connected else {
            for t in titles { Status.shared.set(t, \.send, .waiting, "Waiting for the Kindle — plug it in and it's copied automatically") }
            waiting.append(contentsOf: books.filter { !waiting.contains($0) })
            message = "Plug in your Kindle — \(waiting.count) book\(waiting.count == 1 ? "" : "s") will be sent automatically."
            messageIsError = false
            return
        }
        guard !sending else {
            for t in titles { Status.shared.set(t, \.send, .waiting, "In line — another book is being copied") }
            waiting.append(contentsOf: books); return
        }
        for t in titles {
            let n = books.filter { Status.shared.title(forFile: $0) == t }.count
            Status.shared.set(t, \.send, .active, "Copying \(n) book\(n == 1 ? "" : "s") to the Kindle…")
        }
        sending = true; sendDone = 0; sendTotal = 0; sendName = ""; message = nil; messageIsError = false
        sendActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Copying books to the Kindle")
        let useCalibre = method == "calibre" && calibreInstalled
        let args = useCalibre ? ["calibre-send", "Manga to Kindle"] + books : ["send", "--folder", target] + books
        if useCalibre { sendName = "via calibre…" }
        Task {
            var failure: String?
            var sentCount = 0
            let (code, _) = await run(args) { [weak self] line in
                guard let self, line.hasPrefix("@@"),
                      let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(2).utf8)) as? [String: Any] else { return }
                MainActor.assumeIsolated {
                    switch o["type"] as? String {
                    case "progress":
                        self.sendDone = (o["done"] as? NSNumber)?.int64Value ?? self.sendDone
                        self.sendTotal = (o["total"] as? NSNumber)?.int64Value ?? self.sendTotal
                    case "file": self.sendName = o["name"] as? String ?? ""
                    case "error": failure = o["message"] as? String
                    case "done":
                        sentCount = (o["sent"] as? [Any])?.count ?? (o["files"] as? [Any])?.count ?? 0
                    default: break
                    }
                }
            }
            sending = false
            if let a = sendActivity { ProcessInfo.processInfo.endActivity(a); sendActivity = nil }
            if code == 0 && failure == nil {
                message = "Sent \(sentCount) book\(sentCount == 1 ? "" : "s") to the Kindle (documents/\(useCalibre ? "Manga to Kindle" : target))."
                messageIsError = false
                for t in titles {
                    Status.shared.set(t, \.send, .done, "On the Kindle (documents/\(useCalibre ? "Manga to Kindle" : target)) — eject before unplugging")
                }
                refresh(); loadBooks()
                if ejectAfter { eject() }
            } else {
                message = failure ?? "Sending failed (exit \(code))."
                messageIsError = true
                for t in titles { Status.shared.set(t, \.send, .failed, message ?? "Copy failed") }
            }
            if !waiting.isEmpty && connected {
                let next = waiting; waiting = []
                send(next)
            }
        }
    }

    func loadAll() {
        guard connected else { allBooks = []; orphans = []; return }
        loadingAll = true
        Task {
            let (_, out) = await run(["list-all"])
            struct L: Decodable { var books: [DeviceBook]; var orphans: [OrphanData] }
            if let l = try? JSONDecoder().decode(L.self, from: Data(out.utf8)) {
                allBooks = l.books.sorted { $0.modified > $1.modified }
                orphans = l.orphans
            }
            loadingAll = false
        }
    }

    /// Delete books or orphan .sdr folders anywhere under documents/ (engine refuses anything outside it).
    func deletePaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        deleting = true
        Task {
            let (_, out) = await run(["delete"] + paths)
            let o = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
            let n = o?["removed"] as? Int ?? 0
            let freed = (o?["freed"] as? NSNumber)?.int64Value ?? 0
            message = "Deleted \(n) item\(n == 1 ? "" : "s") · freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))."
            messageIsError = false
            deleting = false
            refresh(); loadAll(); loadBooks()
        }
    }

    /// Writes the manga settings that worked into KOReader on the Kindle (right-to-left, full refresh, page view, no jumps).
    func setUpKOReader() {
        guard connected, !sending else {
            message = connected ? "Wait until the copy finishes." : "Plug in the Kindle (exit KOReader first)."
            messageIsError = true
            return
        }
        Task {
            let (_, out) = await run(["koreader-setup"])
            let line = out.split(separator: "\n").last.map(String.init) ?? ""
            let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            message = o?["message"] as? String ?? "Couldn't set up KOReader."
            messageIsError = (o?["ok"] as? Bool) != true
        }
    }

    func delete(_ items: [KindleBook]) {
        Task {
            _ = await run(["delete"] + items.map(\.path))
            refresh(); loadBooks()
        }
    }

    func eject() {
        guard connected, !sending else { return }
        ejecting = true
        Task {
            let (_, out) = await run(["eject"])
            ejecting = false
            let o = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
            message = o?["message"] as? String ?? "Ejected."
            messageIsError = !(o?["ok"] as? Bool ?? false)
            refresh()
        }
    }
}

// MARK: - toolbar chip + panel

/// Always-visible eject button (also ⌘E in the Kindle menu).
struct KindleEjectButton: View {
    @ObservedObject var k = KindleDevice.shared
    var body: some View {
        Button { k.eject() } label: {
            Label(k.ejecting ? "Ejecting…" : "Eject Kindle", systemImage: "eject.fill")
        }
        .disabled(!k.connected || k.sending || k.ejecting)
        .help(k.sending ? "Wait until the books finish copying" : (k.connected ? "Safely eject the Kindle (⌘E)" : "No Kindle connected"))
    }
}

struct KindleChip: View {
    @ObservedObject var k = KindleDevice.shared
    @State private var open = false
    var body: some View {
        Button { open.toggle(); if open { k.refresh(); k.loadBooks() } } label: {
            HStack(spacing: 5) {
                Image(systemName: k.sending ? "arrow.up.circle" : (k.connected ? "book.closed.fill" : "book.closed"))
                if k.sending {
                    Text("Sending…").monospacedDigit()
                } else if k.connected {
                    Text("Kindle · \(ByteCountFormatter.string(fromByteCount: k.free, countStyle: .file)) free")
                } else if !k.waiting.isEmpty {
                    Text("\(k.waiting.count) waiting for Kindle")
                } else {
                    Text("No Kindle").foregroundStyle(.secondary)
                }
            }
        }
        .help(k.connected ? "Kindle connected at \(k.mount ?? "")" : "Plug in your Kindle with the USB cable")
        .popover(isPresented: $open, arrowEdge: .bottom) { KindlePanel().frame(width: 460, height: 440) }
    }
}

struct KindlePanel: View {
    @ObservedObject var k = KindleDevice.shared
    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "book.closed.fill").font(.title2)
                VStack(alignment: .leading) {
                    Text(k.connected ? k.name : "No Kindle connected").font(.headline)
                    Text(k.connected
                         ? "\(ByteCountFormatter.string(fromByteCount: k.free, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: k.total, countStyle: .file))"
                         : "Connect it with the USB cable. It appears as a drive called Kindle.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if k.connected {
                    Button { k.eject() } label: { Label(k.ejecting ? "Ejecting…" : "Eject", systemImage: "eject") }
                        .disabled(k.sending || k.ejecting)
                }
            }
            if k.sending { SendProgress() }
            if let m = k.message {
                Text(m).font(.callout).foregroundStyle(k.messageIsError ? .red : .secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !k.waiting.isEmpty {
                HStack {
                    Text("Waiting to send: " + k.waiting.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                        .font(.caption).lineLimit(2)
                    Spacer()
                    Button("Cancel") { k.waiting = []; k.message = nil }
                }
            }
            Divider()
            HStack {
                Text("On the Kindle (documents/\(k.folder))").font(.subheadline.weight(.semibold))
                Spacer()
                Button("All Books on Kindle…") { UserDefaults.standard.set("device", forKey: "mainMode") }
                    .disabled(!k.connected)
                Button("Send Files…") { pickAndSend() }.disabled(k.sending)
            }
            List(k.books, selection: $selection) { b in
                HStack {
                    Image(systemName: "book")
                    Text(b.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }.tag(b.id)
            }
            .overlay { if k.books.isEmpty { Text(k.connected ? "No books in this folder yet" : "—").foregroundStyle(.secondary) } }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Delete from Kindle") { k.delete(k.books.filter { ids.contains($0.id) }) }
            }
            HStack {
                Button("Delete Selected") { k.delete(k.books.filter { selection.contains($0.id) }); selection = [] }
                    .disabled(selection.isEmpty || !k.connected)
                Spacer()
                Picker("Send with", selection: $k.method) {
                    Text("Direct copy").tag("direct")
                    Text("calibre").tag("calibre").disabled(!k.calibreInstalled)
                }.frame(width: 190)
            }
            HStack {
                Text("Folder on Kindle:")
                TextField("Manga", text: $k.folder).frame(width: 120)
                    .onSubmit { k.loadBooks() }
                Spacer()
                Toggle("Eject after sending", isOn: $k.ejectAfter).toggleStyle(.checkbox)
            }.font(.callout)
            Toggle("Eject automatically before the Mac sleeps, restarts or shuts down", isOn: $k.autoEjectOnPower)
                .toggleStyle(.checkbox).font(.callout)
        }
        .padding(14)
    }

    private func pickAndSend() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.init(filenameExtension: "azw3")!, .init(filenameExtension: "mobi")!, .init(filenameExtension: "kfx")!, .pdf, .epub]
        p.directoryURL = URL(fileURLWithPath: Job.shared.outputDir)
        if p.runModal() == .OK { k.send(p.urls.map(\.path)) }
    }
}

struct SendProgress: View {
    @ObservedObject var k = KindleDevice.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if k.sendTotal > 0 {
                ProgressView(value: Double(k.sendDone), total: Double(max(k.sendTotal, 1)))
                Text("Sending \(k.sendName) — \(ByteCountFormatter.string(fromByteCount: k.sendDone, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: k.sendTotal, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                ProgressView().progressViewStyle(.linear)
                Text("Sending \(k.sendName)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - everything on the Kindle, with delete

struct DevicePane: View {
    @ObservedObject var k = KindleDevice.shared
    @AppStorage("mainMode") private var mode = "search"
    @State private var selection = Set<String>()
    @State private var filter = "all"
    @State private var query = ""
    @State private var confirm: [DeviceBook] = []
    @State private var confirmOrphans = false

    var shown: [DeviceBook] {
        k.allBooks.filter { b in
            (filter == "all" || b.kind == filter)
            && (query.isEmpty || b.title.localizedCaseInsensitiveContains(query) || b.rel.localizedCaseInsensitiveContains(query))
        }
    }
    var picked: [DeviceBook] { k.allBooks.filter { selection.contains($0.id) } }
    var total: Int64 { k.allBooks.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { mode = "search" } label: { Label("Search", systemImage: "chevron.left") }
                Divider().frame(height: 18)
                Image(systemName: "books.vertical")
                Text("On Kindle").font(.headline)
                if k.connected {
                    Text("\(k.allBooks.count) items · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: k.free, countStyle: .file)) free")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if k.loadingAll || k.deleting { ProgressView().controlSize(.small) }
                Button { k.refresh(); k.loadAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!k.connected)
                Button { k.eject() } label: { Label("Eject", systemImage: "eject") }
                    .disabled(!k.connected || k.sending || k.ejecting)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            HStack(spacing: 10) {
                Picker("", selection: $filter) {
                    Text("All").tag("all")
                    Text("Books & manga").tag("book")
                    Text("Documents (PDF…)").tag("document")
                    Text("Store downloads").tag("store")
                    Text("Dictionaries").tag("dictionary")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                TextField("Filter by title or folder", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if !k.connected {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("Plug in your Kindle with the USB cable to see what's on it.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(shown, selection: $selection) {
                    TableColumn("Title") { b in Text(b.title).fontWeight(.medium).lineLimit(1).help(b.rel) }.width(min: 160, ideal: 260)
                    TableColumn("Folder") { b in Text(b.folder.isEmpty ? "documents" : b.folder).foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 80, ideal: 130)
                    TableColumn("Type") { b in
                        Text(kindLabel(b)).font(.caption).foregroundStyle(b.kind == "dictionary" || b.kind == "store" ? .orange : .secondary)
                    }.width(min: 70, ideal: 90)
                    TableColumn("Size") { b in
                        Text(ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
                    }.width(min: 60, ideal: 80)
                    TableColumn("Added") { b in
                        Text(Date(timeIntervalSince1970: b.modified).formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    }.width(min: 80, ideal: 100)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let items = k.allBooks.filter { ids.contains($0.id) }
                    Button("Delete \(items.count == 1 ? "Book" : "\(items.count) Books") from Kindle…") { confirm = items }
                }
                .onDeleteCommand { if !picked.isEmpty { confirm = picked } }
            }
            Divider()
            HStack(spacing: 10) {
                if let m = k.message { Text(m).font(.callout).foregroundStyle(k.messageIsError ? .red : .secondary).lineLimit(1) }
                if !k.orphans.isEmpty {
                    Button("Clean Up \(k.orphans.count) Leftover Reading Data (\(ByteCountFormatter.string(fromByteCount: k.orphans.reduce(0) { $0 + $1.size }, countStyle: .file)))") {
                        confirmOrphans = true
                    }
                    .help("Reading-progress folders (.sdr) whose book was already deleted")
                }
                Spacer()
                Text(selection.isEmpty ? "" : "\(picked.count) selected · \(ByteCountFormatter.string(fromByteCount: picked.reduce(0) { $0 + $1.size }, countStyle: .file))")
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { confirm = picked } label: { Label("Delete from Kindle", systemImage: "trash") }
                    .disabled(picked.isEmpty || k.deleting || k.sending)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .onAppear { k.refresh(); k.loadAll() }
        .onChange(of: k.mount) { _, _ in selection = []; k.loadAll() }
        .alert(confirmTitle, isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } })) {
            Button("Delete", role: .destructive) {
                k.deletePaths(confirm.map(\.path)); selection.subtract(confirm.map(\.id)); confirm = []
            }
            Button("Cancel", role: .cancel) { confirm = [] }
        } message: {
            Text(confirmMessage)
        }
        .alert("Delete leftover reading data?", isPresented: $confirmOrphans) {
            Button("Clean Up", role: .destructive) { k.deletePaths(k.orphans.map(\.path)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(k.orphans.count) .sdr folders belong to books that are no longer on the Kindle (bookmarks, last page read). Nothing else is touched.")
        }
    }

    private var confirmTitle: String {
        confirm.count == 1 ? "Delete “\(confirm[0].title)” from the Kindle?" : "Delete \(confirm.count) items from the Kindle?"
    }
    private var confirmMessage: String {
        let size = ByteCountFormatter.string(fromByteCount: confirm.reduce(0) { $0 + $1.size }, countStyle: .file)
        var m = "Frees \(size). Reading progress and notes for \(confirm.count == 1 ? "it" : "them") are removed too. The copies on this Mac are not touched."
        if confirm.contains(where: { $0.kind == "store" }) { m += " Store books can be downloaded again from your Kindle library." }
        if confirm.contains(where: { $0.kind == "dictionary" }) { m += " Deleting a dictionary turns off word lookup in that language." }
        return m
    }
    private func kindLabel(_ b: DeviceBook) -> String {
        switch b.kind {
        case "store": return "Store book"
        case "dictionary": return "Dictionary"
        case "document": return b.ext.uppercased()
        default: return b.ext.uppercased()
        }
    }
}
