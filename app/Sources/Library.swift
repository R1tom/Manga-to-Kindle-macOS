import SwiftUI
import AppKit

/// One downloaded series in HaruNeko's folder: <media dir>/<Source>/<Manga>/<chapter files>.
struct DownloadedSeries: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var title: String
    var source: String
    var chapters: Int
    var bytes: Int64
    var updated: Date
    var converted: [String]   // Kindle books with this title in the output folder
}

@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()
    @Published var series: [DownloadedSeries] = []
    @Published var loading = false

    nonisolated static let chapterExt: Set<String> = ["cbz", "zip", "cbr", "rar", "cb7", "7z", "cbt", "tar", "pdf", "epub"]
    nonisolated static let imageExt: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "bmp"]

    func refresh() {
        loading = true
        let root = Haru.shared.mediaDir, out = Job.shared.outputDir
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Downloads.scan(root: root, output: out)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.series = list; self.loading = false } }
        }
    }

    nonisolated static func scan(root: String, output: String) -> [DownloadedSeries] {
        let fm = FileManager.default
        let books = (try? fm.contentsOfDirectory(atPath: output))?.filter {
            ["azw3", "mobi", "kfx", "pdf"].contains(($0 as NSString).pathExtension.lowercased()) } ?? []
        func norm(_ s: String) -> String {
            s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        var result: [DownloadedSeries] = []
        for source in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !source.hasPrefix(".") {
            let sdir = root + "/" + source
            for manga in (try? fm.contentsOfDirectory(atPath: sdir)) ?? [] where !manga.hasPrefix(".") {
                let mdir = sdir + "/" + manga
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: mdir, isDirectory: &isDir), isDir.boolValue else { continue }
                var count = 0, bytes: Int64 = 0, newest = Date.distantPast
                for item in (try? fm.contentsOfDirectory(atPath: mdir)) ?? [] where !item.hasPrefix(".") {
                    let p = mdir + "/" + item
                    let attrs = try? fm.attributesOfItem(atPath: p)
                    let ext = (item as NSString).pathExtension.lowercased()
                    var d: ObjCBool = false
                    fm.fileExists(atPath: p, isDirectory: &d)
                    if d.boolValue {
                        // a folder of page images counts as one chapter
                        let pages = (try? fm.contentsOfDirectory(atPath: p))?.filter {
                            imageExt.contains(($0 as NSString).pathExtension.lowercased()) } ?? []
                        if pages.isEmpty { continue }
                        count += 1
                    } else if chapterExt.contains(ext) {
                        count += 1
                        bytes += (attrs?[.size] as? Int64) ?? 0
                    } else { continue }
                    if let m = attrs?[.modificationDate] as? Date, m > newest { newest = m }
                }
                guard count > 0 else { continue }
                let key = norm(manga)
                let done = books.filter { b in
                    let stem = norm(((b as NSString).deletingPathExtension).replacingOccurrences(
                        of: #"\s\d+$"#, with: "", options: .regularExpression))
                    return stem == key
                }.sorted()
                result.append(DownloadedSeries(path: mdir, title: manga, source: source, chapters: count, bytes: bytes,
                                               updated: newest, converted: done.map { output + "/" + $0 }))
            }
        }
        return result.sorted { $0.updated > $1.updated }
    }

    /// Every chapter file / image folder of a series, for the converter.
    nonisolated static func chapterPaths(_ s: DownloadedSeries) -> [String] { [s.path] }
}

struct DownloadsPane: View {
    @ObservedObject var lib = Downloads.shared
    @ObservedObject var job = Job.shared
    @ObservedObject var kindle = KindleDevice.shared
    @AppStorage("mainMode") private var mode = "search"
    @State private var selection = Set<String>()

    var picked: [DownloadedSeries] { lib.series.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { mode = "search" } label: { Label("Search", systemImage: "chevron.left") }
                Divider().frame(height: 18)
                Image(systemName: "tray.full")
                Text("Downloaded").font(.headline)
                Text(abbrev(Haru.shared.mediaDir)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if lib.loading { ProgressView().controlSize(.small) }
                Button { lib.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: Haru.shared.mediaDir)) } label: {
                    Label("Finder", systemImage: "folder") }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            Table(lib.series, selection: $selection) {
                TableColumn("Manga") { s in Text(s.title).fontWeight(.medium).lineLimit(1) }.width(min: 140, ideal: 200)
                TableColumn("Source") { s in Text(s.source).foregroundStyle(.secondary) }.width(min: 80, ideal: 110)
                TableColumn("Chapters") { s in Text("\(s.chapters)").monospacedDigit() }.width(min: 60, ideal: 70)
                TableColumn("Size") { s in
                    Text(s.bytes > 0 ? ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file) : "—")
                        .foregroundStyle(.secondary).monospacedDigit()
                }.width(min: 60, ideal: 80)
                TableColumn("Downloaded") { s in
                    Text(s.updated.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                }.width(min: 100, ideal: 125)
                TableColumn("Kindle book") { s in
                    if s.converted.isEmpty { Text("not converted").foregroundStyle(.tertiary) }
                    else {
                        Label(s.converted.count == 1 ? "converted" : "\(s.converted.count) parts", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }.width(min: 110, ideal: 130)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let items = lib.series.filter { ids.contains($0.id) }
                Button("Convert & Send to Kindle") { convert(items, send: true) }
                Button("Convert Only") { convert(items, send: false) }
                if items.count == 1, let s = items.first {
                    Button("Open Chapter List…") { job.open([s.path], title: s.title); mode = "files" }
                    if !s.converted.isEmpty {
                        Button("Send Existing Kindle Book") { kindle.send(s.converted) }
                    }
                    Divider()
                    Button("Show in Finder") { Tools.reveal(s.path) }
                }
            } primaryAction: { ids in
                if let s = lib.series.first(where: { ids.contains($0.id) }) { job.open([s.path], title: s.title); mode = "files" }
            }
            .overlay {
                if lib.series.isEmpty && !lib.loading {
                    VStack(spacing: 6) {
                        Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text("Nothing downloaded yet in \(abbrev(Haru.shared.mediaDir))").foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text(selection.isEmpty ? "Select one or more manga" :
                        "\(picked.count) selected · \(picked.reduce(0) { $0 + $1.chapters }) chapters")
                    .foregroundStyle(.secondary)
                if job.queuedCount > 0 {
                    Text("· \(job.queuedCount) waiting to convert").foregroundStyle(.orange)
                    Button("Cancel Queue") { job.cancelQueue() }
                }
                Spacer()
                Button("Open Chapter List") {
                    if let s = picked.first { job.open([s.path], title: s.title); mode = "files" }
                }
                .disabled(picked.count != 1 || job.running)
                Button("Send Kindle Book") { kindle.send(picked.flatMap(\.converted)) }
                    .disabled(picked.allSatisfy { $0.converted.isEmpty })
                    .help("Send the already-converted book(s) without converting again")
                Button {
                    convert(picked, send: true)
                } label: {
                    Label("Convert & Send to Kindle", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked.isEmpty)
                .help(kindle.connected ? "Convert with the settings on the right, then copy to the Kindle"
                                       : "Converts now; sends as soon as the Kindle is plugged in")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .onAppear { lib.refresh() }
        .onChange(of: job.running) { _, running in if !running { lib.refresh() } }
    }

    private func convert(_ items: [DownloadedSeries], send: Bool) {
        guard !items.isEmpty else { return }
        job.enqueue(items.map { (paths: [$0.path], title: $0.title) }, send: send)
    }

    private func abbrev(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}
