import SwiftUI
import UniformTypeIdentifiers

// MARK: - ebooks (not manga): search free legal sources, get them as AZW3 for the Kindle's own reader

struct BookHit: Codable, Identifiable, Hashable {
    var id: String { source + "|" + bookId }
    var source: String
    var bookId: String
    var title: String
    var author: String
    var year: String?
    var cover: String?
    var azw3: String?
    var epub: String?
    var language: String?
    var note: String?
    var files: [String: String]?

    enum CodingKeys: String, CodingKey {
        case source, title, author, year, cover, azw3, epub, language, note, files
        case bookId = "id"
    }
    var coverURL: URL? {
        guard let c = cover else { return nil }
        return c.hasPrefix("http") ? URL(string: c) : URL(fileURLWithPath: c)
    }
}

@MainActor
final class BookStore: ObservableObject {
    static let shared = BookStore()
    nonisolated static let outputDir = NSHomeDirectory() + "/Documents/Kindle/Books"

    @Published var query = ""
    @Published var searching = false
    @Published var results: [BookHit] = []
    @Published var errors: [String] = []
    @Published var getting: Set<String> = []          // hit ids being downloaded/converted
    @Published var got: [String: String] = [:]          // hit id → AZW3 path
    @Published var failed: [String: String] = [:]

    private func engine(_ args: [String], onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Tools.python)
                p.arguments = [Tools.res + "/engine/books.py"] + args
                p.environment = Tools.env
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe
                var all = Data(), buf = Data()
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    all.append(d); buf.append(d)
                    while let i = buf.firstIndex(of: 10) {
                        onLine(String(decoding: buf[buf.startIndex..<i], as: UTF8.self))
                        buf.removeSubrange(buf.startIndex...i)
                    }
                }
                do { try p.run() } catch { cont.resume(returning: (-1, "")); return }
                p.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                all.append(pipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: (p.terminationStatus, String(decoding: all, as: UTF8.self)))
            }
        }
    }

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true; errors = []
        Task {
            defer { searching = false }
            struct R: Decodable { var results: [BookHit]; var errors: [String] }
            let (_, out) = await engine(["search", q, "en"])
            if let r = try? JSONDecoder().decode(R.self, from: Data(out.utf8)) {
                results = r.results; errors = r.errors
            } else {
                results = []; errors = ["Search failed: " + String(out.suffix(200))]
            }
        }
    }

    nonisolated static let bookExtensions: Set<String> = ["epub", "mobi", "azw", "azw3", "kfx", "prc", "docx", "doc", "txt", "fb2",
                                                         "rtf", "htm", "html", "odt", "lit", "pdb", "htmlz", "txtz", "pdf"]
    @Published var importing: [String] = []            // file names being added

    /// Books from the user's drive: AZW3 (converted with calibre) or kept as is (AZW3/KFX/PDF) → Kindle documents/Books
    func addLocal(_ paths: [String]) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard BookStore.bookExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            importing.append(url.lastPathComponent)
            Status.shared.start(stem, download: false, convert: true)
            Status.shared.set(stem, \.convert, .active, ["azw3", "kfx", "pdf"].contains(url.pathExtension.lowercased())
                              ? "Already a Kindle format — copying" : "Converting to AZW3 (Kindle format)…")
            Task {
                let (code, out) = await engine(["local", path])
                importing.removeAll { $0 == url.lastPathComponent }
                let line = out.split(separator: "\n").last { $0.hasPrefix("@@{\"type\": \"done\"") || $0.contains("\"error\"") }
                let o = line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(2).utf8)) as? [String: Any] }
                guard code == 0, let file = (o?["files"] as? [String])?.first else {
                    Status.shared.set(stem, \.convert, .failed, o?["message"] as? String ?? "Couldn't add \(url.lastPathComponent)")
                    Status.shared.set(stem, \.send, .skipped, "—")
                    return
                }
                let title = (o?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem
                if title != stem { Status.shared.remove(Status.key(stem)); Status.shared.start(title, download: false, convert: true) }
                let size = ByteCountFormatter.string(fromByteCount: (o?["size"] as? NSNumber)?.int64Value ?? 0, countStyle: .file)
                Status.shared.set(title, \.convert, .done, "\(URL(fileURLWithPath: file).pathExtension.uppercased()) · \(size) · from \(url.lastPathComponent)")
                Status.shared.setBooks(title, [file])
                if KindleDevice.shared.autoSend { KindleDevice.shared.send([file]) }
                else { Status.shared.set(title, \.send, .skipped, "Auto-send is off — use “Send”") }
            }
        }
    }

    func pickLocal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = BookStore.bookExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose books to add to the Kindle (EPUB, MOBI, AZW3, PDF, DOCX, TXT…)"
        panel.prompt = "Add to Kindle"
        if panel.runModal() == .OK { addLocal(panel.urls.map(\.path)) }
    }

    /// download (or copy from Calibre) → AZW3 → send to the Kindle's Books folder
    func get(_ hit: BookHit) {
        guard !getting.contains(hit.id) else { return }
        getting.insert(hit.id); failed[hit.id] = nil
        let title = hit.title
        Status.shared.start(title, download: true, convert: true)
        Status.shared.set(title, \.download, .active, "Getting it from \(hit.source)…")
        guard let json = try? JSONEncoder().encode(hit) else { return }
        Task {
            let (code, out) = await engine(["get", String(decoding: json, as: UTF8.self)]) { line in
                guard line.hasPrefix("@@"),
                      let o = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(2).utf8)) as? [String: Any] else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch o["stage"] as? String {
                        case "convert" where (o["type"] as? String) == "stage":
                            Status.shared.set(title, \.download, .done, "Downloaded from \(hit.source)")
                            Status.shared.set(title, \.convert, .active, "Converting to AZW3 (Kindle format)…")
                        default: break
                        }
                    }
                }
            }
            getting.remove(hit.id)
            let done = out.split(separator: "\n").last { $0.hasPrefix("@@{\"type\": \"done\"") }
            guard code == 0, let d = done,
                  let o = try? JSONSerialization.jsonObject(with: Data(d.dropFirst(2).utf8)) as? [String: Any],
                  let file = (o["files"] as? [String])?.first else {
                let err = out.split(separator: "\n").last { $0.contains("\"error\"") }
                    .flatMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(2).utf8)) as? [String: Any] }?["message"] as? String
                failed[hit.id] = err ?? "Failed (exit \(code))"
                Status.shared.set(title, \.download, .failed, err ?? "Failed")
                Status.shared.set(title, \.convert, .skipped, "—"); Status.shared.set(title, \.send, .skipped, "—")
                return
            }
            got[hit.id] = file
            let size = ByteCountFormatter.string(fromByteCount: (o["size"] as? NSNumber)?.int64Value ?? 0, countStyle: .file)
            Status.shared.set(title, \.download, .done, "Downloaded from \(hit.source)")
            Status.shared.set(title, \.convert, .done, "AZW3 · \(size)" + (hit.azw3 != nil ? " (Standard Ebooks' own Kindle edition)" : ""))
            Status.shared.setBooks(title, [file])
            if KindleDevice.shared.autoSend { KindleDevice.shared.send([file]) }
            else { Status.shared.set(title, \.send, .skipped, "Auto-send is off — use “Send”") }
        }
    }
}

struct BooksPane: View {
    @ObservedObject var store = BookStore.shared
    @ObservedObject var kindle = KindleDevice.shared

    var body: some View {
        VStack(spacing: 0) {
            if !store.importing.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Adding \(store.importing.joined(separator: ", "))…").lineLimit(1).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(Color.accentColor.opacity(0.08))
            }
            HStack(spacing: 10) {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
                TextField("Search books by title or author (Project Gutenberg, Standard Ebooks, your Calibre library)",
                          text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.search() }
                Button("Search") { store.search() }.keyboardShortcut(.defaultAction)
                    .disabled(store.query.trimmingCharacters(in: .whitespaces).isEmpty || store.searching)
                Divider().frame(height: 18)
                Button { store.pickLocal() } label: { Label("Add Files…", systemImage: "plus.circle") }
                    .help("Add books from your drive (EPUB, MOBI, AZW3, PDF, DOCX, TXT…) — or drag them here")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if store.searching {
                ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(store.query.isEmpty ? "Find a book — it's sent to the Kindle as AZW3 (the Kindle's own format)."
                                             : "No books found. Try the author's name or a shorter title.")
                        .foregroundStyle(.secondary)
                    Text("Free, legal sources: public-domain books from Project Gutenberg and Standard Ebooks, plus your own Calibre library.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Or drop book files here (EPUB, MOBI, AZW3, PDF, DOCX, TXT…) — they're converted to AZW3 and sent to the Kindle.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6)
                    ForEach(store.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.results) { hit in BookRow(hit: hit) }
                if !store.errors.isEmpty {
                    Text(store.errors.joined(separator: " · ")).font(.caption).foregroundStyle(.orange).padding(6)
                }
            }
        }
    }
}

struct BookRow: View {
    @ObservedObject var store = BookStore.shared
    let hit: BookHit

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: hit.coverURL) { img in img.resizable().scaledToFit() } placeholder: {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
            }
            .frame(width: 44, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title).font(.body.weight(.medium)).lineLimit(2)
                Text(hit.author.isEmpty ? "Unknown author" : hit.author).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(hit.source).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
                    if let n = hit.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer()
            if store.getting.contains(hit.id) {
                ProgressView().controlSize(.small)
            } else if store.got[hit.id] != nil {
                Label("Got it", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                Button { store.get(hit) } label: { Label("Get Book", systemImage: "arrow.down.circle") }
                    .help("Download as AZW3 and send it to the Kindle (documents/Books)")
            }
        }
        .padding(.vertical, 3)
        .overlay(alignment: .bottomTrailing) {
            if let e = store.failed[hit.id] { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(1) }
        }
    }

    private var color: Color {
        switch hit.source {
        case "Standard Ebooks": return .teal
        case "Calibre library": return .purple
        default: return .blue
        }
    }
}
