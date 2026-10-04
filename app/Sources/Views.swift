import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Left side when local chapter files are open (or chapters just downloaded): the chapter list.
struct FilesPane: View {
    @ObservedObject var job = Job.shared
    @AppStorage("mainMode") private var mode = "search"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { mode = "search" } label: { Label("Search", systemImage: "chevron.left") }
                Divider().frame(height: 18)
                Image(systemName: "folder")
                Text(job.title.isEmpty ? "Chapter files" : job.title).font(.headline).lineLimit(1)
                Text("\(job.selected.count) chapters · \(job.selectedPages) pages").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button { pickSources() } label: { Label("Open…", systemImage: "folder.badge.plus") }
                    .disabled(job.running)
                Button { job.open(job.sources) } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(job.running || job.scanning || job.sources.isEmpty)
                Button { job.clear(); mode = "search" } label: { Label("Close", systemImage: "xmark.circle") }
                    .disabled(job.running)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if job.chapters.isEmpty {
                DropZone(dropTarget: .constant(false))
            } else {
                ChapterTable()
            }
        }
    }
}

/// Accepts folders/files dropped anywhere in the window.
struct FileDrop: ViewModifier {
    @ObservedObject var job = Job.shared
    @AppStorage("mainMode") private var mode = "search"
    @State private var target = false
    func body(content: Content) -> some View {
        content
            .overlay {
                if target {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(6).allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $target) { providers in
                loadDropped(providers); return true
            }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        var urls: [String] = []
        let g = DispatchGroup()
        let lock = NSLock()
        for p in providers {
            g.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let u = url { lock.lock(); urls.append(u.path); lock.unlock() }
                g.leave()
            }
        }
        g.notify(queue: .main) { MainActor.assumeIsolated { job.open(urls.sorted()); mode = "files" } }
    }
}

@MainActor func pickSources() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.message = "Choose a manga folder (e.g. Documents/HARUNEKU/MangaDex/<series>) or chapter files"
    panel.prompt = "Open"
    let start = NSHomeDirectory() + "/Documents/HARUNEKU"
    if FileManager.default.fileExists(atPath: start) { panel.directoryURL = URL(fileURLWithPath: start) }
    if panel.runModal() == .OK {
        Job.shared.open(panel.urls.map(\.path))
        UserDefaults.standard.set("files", forKey: "mainMode")
    }
}

struct DropZone: View {
    @ObservedObject var job = Job.shared
    @Binding var dropTarget: Bool
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: job.scanning ? "hourglass" : "books.vertical")
                .font(.system(size: 64, weight: .light)).foregroundStyle(.secondary)
            if job.scanning {
                ProgressView("Reading chapters…")
            } else {
                Text("Drop a manga folder or chapter files here").font(.title2.weight(.semibold))
                Text("CBZ · ZIP · CBR · RAR · CB7 · 7Z · PDF · EPUB · image folders\nAll chapters are put in order (1, 2, 3, 3.5 …), merged into one book\nand converted with Kindle Comic Converter for Kindle Paperwhite 11th gen.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Choose Folder or Files…") { pickSources() }.controlSize(.large).keyboardShortcut("o")
            }
            if let e = job.scanError {
                Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled).frame(maxWidth: 560)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(dropTarget ? Color.accentColor : Color.secondary.opacity(0.35)).padding(24))
    }
}

// MARK: - chapter list

struct ChapterTable: View {
    @ObservedObject var job = Job.shared
    @State private var showAll = false
    @State private var selection = Set<String>()
    @State private var editing: Chapter?

    var visible: [Chapter] {
        let rows = job.chapters.filter { c in
            showAll || c.selected || (job.language == "*" || (c.lang ?? "") == job.language)
        }
        return rows.sorted { ($0.chapterSort, $0.duplicate ? 1 : 0, $0.name) < ($1.chapterSort, $1.duplicate ? 1 : 0, $1.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Language", selection: $job.language) {
                    ForEach(job.languages, id: \.code) { l in
                        Text("\(LangName.of(l.code)) (\(l.count))").tag(l.code)
                    }
                    if job.languages.count > 1 { Divider(); Text("All languages").tag("*") }
                }
                .frame(maxWidth: 260)
                Toggle("Show other languages", isOn: $showAll).toggleStyle(.checkbox)
                Spacer()
                Button("Auto-pick") { job.autoSelect() }
                    .help("One file per chapter: chosen language, the scan group with the most chapters")
                Button("All") { job.setAll(true, visible: visible) }
                Button("None") { job.setAll(false, visible: visible) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            Table(visible, selection: $selection) {
                TableColumn("") { c in
                    Toggle("", isOn: binding(c)).labelsHidden().toggleStyle(.checkbox)
                }.width(22)
                TableColumn("Ch.") { c in
                    Text(c.chapterDisplay).monospacedDigit().fontWeight(c.selected ? .semibold : .regular)
                }.width(min: 40, ideal: 52)
                TableColumn("Vol") { c in Text(c.volDisplay).foregroundStyle(.secondary) }.width(min: 28, ideal: 34)
                TableColumn("Title") { c in
                    Text(c.title.isEmpty ? "—" : c.title).lineLimit(1)
                        .foregroundStyle(c.title.isEmpty ? .secondary : .primary)
                }.width(min: 120, ideal: 240)
                TableColumn("Lang") { c in Text(c.langDisplay).foregroundStyle(.secondary) }.width(min: 34, ideal: 44)
                TableColumn("Group") { c in Text(c.groupDisplay).lineLimit(1).foregroundStyle(.secondary) }.width(min: 60, ideal: 120)
                TableColumn("Pages") { c in
                    Text("\(c.pages)").monospacedDigit().foregroundStyle(c.pages == 0 ? .red : .secondary)
                }.width(min: 36, ideal: 44)
                TableColumn("Type") { c in Text(c.format.uppercased()).font(.caption).foregroundStyle(.secondary) }.width(min: 36, ideal: 48)
                TableColumn("File") { c in
                    Text(c.name).lineLimit(1).truncationMode(.middle).font(.caption).foregroundStyle(.secondary)
                        .help(c.path)
                }.width(min: 100, ideal: 220)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let c = job.chapters.first(where: { $0.id == id }) {
                    Button("Use This Version for Chapter \(c.chapterDisplay)") { job.useOnly(c) }
                    Button("Edit Chapter Name…") { editing = c }
                    Divider()
                    Button("Show in Finder") { Tools.reveal(c.path) }
                }
                if ids.count > 1 {
                    Divider()
                    Button("Tick \(ids.count) Selected") { for id in ids { set(id, true) } }
                    Button("Untick \(ids.count) Selected") { for id in ids { set(id, false) } }
                }
            } primaryAction: { ids in
                if let id = ids.first, let c = job.chapters.first(where: { $0.id == id }) { job.useOnly(c) }
            }
            Divider()
            WarningsBar()
        }
        .sheet(item: $editing) { c in EditChapterSheet(chapter: c) }
    }

    private func binding(_ c: Chapter) -> Binding<Bool> {
        Binding(get: { job.chapters.first(where: { $0.id == c.id })?.selected ?? false },
                set: { set(c.id, $0) })
    }

    private func set(_ id: String, _ on: Bool) {
        if let i = job.chapters.firstIndex(where: { $0.id == id }) { job.chapters[i].selected = on }
    }
}

struct EditChapterSheet: View {
    @ObservedObject var job = Job.shared
    let chapter: Chapter
    @State private var number = ""
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Text(chapter.name).font(.caption).foregroundStyle(.secondary)
            TextField("Chapter number", text: $number)
            TextField("Chapter title", text: $title)
            Text("Shown in the Kindle's table of contents as “Chapter \(number.isEmpty ? "?" : number)\(title.isEmpty ? "" : " - " + title)”. The number also sets the order.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { number = chapter.chText ?? ""; title = chapter.title }
    }
    private func save() {
        guard let i = job.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
        let n = number.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let v = Double(n) {
            job.chapters[i].ch = v
            job.chapters[i].chText = v == v.rounded() ? String(Int(v)) : String(v)
        } else if n.isEmpty {
            job.chapters[i].ch = nil; job.chapters[i].chText = nil
        }
        job.chapters[i].title = title.trimmingCharacters(in: .whitespaces)
    }
}

struct WarningsBar: View {
    @ObservedObject var job = Job.shared
    var body: some View {
        let missing = job.missing, dups = job.duplicateChapters
        let unnumbered = job.selected.filter { $0.ch == nil }.count
        HStack(spacing: 14) {
            if missing.isEmpty && dups.isEmpty && unnumbered == 0 {
                Label("Order looks complete", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            if !missing.isEmpty {
                Label("Missing: " + compress(missing), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).help("No selected file for these chapter numbers")
            }
            if !dups.isEmpty {
                Label("Ticked twice: " + dups.prefix(12).joined(separator: ", "), systemImage: "doc.on.doc")
                    .foregroundStyle(.orange).help("More than one file ticked for the same chapter — right-click → Use This Version")
            }
            if unnumbered > 0 {
                Label("\(unnumbered) without chapter number (placed at the end)", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.callout).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func compress(_ n: [Int]) -> String {
        var parts: [String] = [], i = 0
        while i < n.count {
            var j = i
            while j + 1 < n.count && n[j + 1] == n[j] + 1 { j += 1 }
            parts.append(i == j ? "\(n[i])" : "\(n[i])–\(n[j])")
            i = j + 1
        }
        return parts.prefix(10).joined(separator: ", ") + (parts.count > 10 ? " …" : "")
    }
}

// MARK: - right side: options, convert, progress

struct SidePanel: View {
    @ObservedObject var job = Job.shared
    @State private var showLog = false
    @ObservedObject var kindle = KindleDevice.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusSection().fixedSize(horizontal: false, vertical: true)
            Divider()
            Form {
                Section("Book") {
                    TextField("Title", text: $job.title)
                    TextField("Author", text: $job.author, prompt: Text("optional"))
                }
                Section("Kindle") {
                    LabeledContent("Device", value: "Paperwhite 11th gen (KPW5, 1236×1648)")
                    Picker("Format", selection: $job.format) {
                        Text("AZW3").tag("azw3")
                        Text("MOBI").tag("mobi")
                        Text("Both").tag("both")
                    }.pickerStyle(.segmented)
                    Toggle("Manga (right-to-left)", isOn: $job.manga)
                    Toggle("Webtoon / long strip", isOn: $job.webtoon)
                    Picker("Image", selection: $job.imageMode) {
                        Text("Best – lossless 16-gray").tag("best")
                        Text("JPEG high (90)").tag("jpeg90")
                        Text("JPEG small (70)").tag("jpeg70")
                    }
                    .help("Best: pages reduced to exactly the 16 grays the Paperwhite shows, no JPEG artifacts — usually also the smallest file")
                    Picker("Double-page spreads", selection: $job.spreads) {
                        Text("Both – whole spread + halves").tag("both")
                        Text("Split into halves").tag("split")
                        Text("Rotate whole spread").tag("rotate")
                    }
                    .help("Both: the full spread turned sideways (rotate the Kindle to see it), then each half as a normal page")
                    Picker("Crop margins", selection: $job.crop) {
                        Text("Strong").tag("strong")
                        Text("Normal").tag("normal")
                    }
                    .help("Trims white edges and page numbers so the art fills more of the screen")
                    Picker("Borders", selection: $job.borders) {
                        Text("Automatic").tag("auto")
                        Text("Black").tag("black")
                        Text("White").tag("white")
                    }
                    .help("Colour of the empty space around a page. Black suits very dark series.")
                    Picker("Page tone", selection: $job.tone) {
                        Text("Automatic").tag("auto")
                        Text("Darker").tag("darker")
                        Text("Lighter").tag("lighter")
                    }
                    .help("Darker helps faded/grey scans; Lighter helps very dark, muddy scans")
                    Toggle("Deep blacks (auto-level)", isOn: $job.autolevel)
                        .help("Makes faded/grey scans print true black")
                    Toggle("Sharper Panel View zoom", isOn: $job.hq)
                        .help("Stores pages at 1.5× resolution for zooming into panels. About twice the file size.")
                }
                Section("Output") {
                    HStack {
                        Text(abbreviate(job.outputDir)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Change…") { chooseOutput() }
                    }
                    Toggle("Also save merged CBZ", isOn: $job.keepCbz)
                    Toggle("Send to Kindle when done", isOn: $kindle.autoSend)
                        .help("Copies the book to the Kindle's documents/\(kindle.folder) folder. If the Kindle isn't plugged in, it's sent as soon as it is.")
                }
            }
            .formStyle(.grouped)
            .disabled(job.running)

            VStack(alignment: .leading, spacing: 10) {
                if job.running || !job.stage.isEmpty {
                    Text(job.stage).font(.headline)
                    if job.running {
                        if job.total > 0 {
                            ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                            Text("\(job.done) of \(job.total) chapters").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                            Text("Resizing pages and building the Kindle file — this takes a while for big books.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let e = job.errorMessage {
                    Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled).lineLimit(8)
                }
                if !job.resultFiles.isEmpty {
                    if let s = job.summary { Text(s).font(.callout).foregroundStyle(.secondary) }
                    ForEach(job.resultFiles, id: \.self) { f in
                        HStack {
                            Image(systemName: f.hasSuffix(".cbz") ? "doc.zipper" : "book.closed.fill")
                            Text(URL(fileURLWithPath: f).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(sizeOf(f)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Show in Finder") { Tools.reveal(job.resultFiles.last!) }
                        Button {
                            kindle.send(job.kindleFiles)
                        } label: {
                            Label(kindle.connected ? "Send to Kindle" : "Send When Kindle Connects", systemImage: "arrow.up.forward.app")
                        }
                        .disabled(kindle.sending || job.kindleFiles.isEmpty)
                    }
                    if kindle.sending { SendProgress() }
                    if let m = kindle.message {
                        Text(m).font(.caption).foregroundStyle(kindle.messageIsError ? .red : .secondary)
                    }
                }
                if job.chapters.isEmpty && !job.running && job.resultFiles.isEmpty {
                    Text("Search and download a manga on the left (it converts automatically), or open chapter files you already have.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if job.running {
                        Button(role: .destructive) { job.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                            .controlSize(.large)
                    } else {
                        Button { kindle.message = nil; job.convert() } label: {
                            Label("Merge & Convert \(job.selected.count) Chapters", systemImage: "book.and.wrench")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large).buttonStyle(.borderedProminent)
                        .disabled(job.selected.isEmpty || job.scanning)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                DisclosureGroup("Log", isExpanded: $showLog) {
                    LogView().frame(minHeight: 160, maxHeight: 260)
                }
            }
            .padding(14)
        }
    }

    private func chooseOutput() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: job.outputDir)
        if p.runModal() == .OK, let u = p.url { job.outputDir = u.path }
    }

    private func abbreviate(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private func sizeOf(_ f: String) -> String {
        let n = ((try? FileManager.default.attributesOfItem(atPath: f))?[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

struct LogView: View {
    @ObservedObject var job = Job.shared
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(job.log) { l in
                        Text(l.text).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(l.isError ? .red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading).id(l.id)
                    }
                }.textSelection(.enabled).padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: job.log.count) { _, _ in
                if let last = job.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

enum LangName {
    static func of(_ code: String) -> String {
        if code.isEmpty { return "No language tag" }
        if code == "*" { return "All languages" }
        let name = Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        return "\(name) [\(code)]"
    }
}
