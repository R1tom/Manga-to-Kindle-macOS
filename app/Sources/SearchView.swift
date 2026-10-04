import SwiftUI
import AppKit

struct SearchView: View {
    @ObservedObject var haru = Haru.shared

    var body: some View {
        VStack(spacing: 0) {
            SearchBar()
            Divider()
            VerifyBanner()
            switch haru.state {
            case .connected:
                HSplitView {
                    ResultsList().frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
                    MangaPane().frame(minWidth: 560)
                }
            case .starting, .idle:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting HaruNeko in the background…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let m):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(m).multilineTextAlignment(.center)
                    Button("Try Again") { haru.state = .idle; haru.start() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { haru.start() }
    }
}

struct SearchBar: View {
    @ObservedObject var haru = Haru.shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search any manga, or paste a manga link", text: $haru.query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { haru.search() }
                if haru.searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
            Picker("", selection: $haru.language) {
                ForEach(["en", "es", "fr", "pt-br", "id", "it", "de", "ru", "tr", "ja"], id: \.self) { Text(LangName.of($0)).tag($0) }
            }.labelsHidden().frame(width: 170)
            Button("Search") { haru.search() }.keyboardShortcut(.defaultAction)
                .disabled(haru.state != .connected || haru.query.trimmingCharacters(in: .whitespaces).isEmpty)
            Divider().frame(height: 22)
            IndexStatus()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .onAppear { focused = true }
    }
}

struct IndexStatus: View {
    @ObservedObject var haru = Haru.shared
    var body: some View {
        HStack(spacing: 8) {
            if haru.indexing {
                ProgressView(value: Double(haru.indexDone), total: Double(max(haru.indexTotal, 1))).frame(width: 90)
                Text("Loading sources \(haru.indexDone)/\(haru.indexTotal)").font(.caption).monospacedDigit()
                    .help(haru.indexCurrent.joined(separator: ", "))
                Button { haru.stopIndex() } label: { Image(systemName: "stop.fill") }.buttonStyle(.borderless).help("Stop")
            } else {
                Text("\(haru.sourcesIndexed) sources · \(haru.titles.formatted()) titles").font(.caption)
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("Update Sources") { haru.updateIndex() }
                    .help("Loads the manga lists of every \(LangName.of(haru.language)) source (first time takes a while; HaruNeko keeps them)")
                    .disabled(haru.state != .connected)
            }
            Menu {
                Button("Show HaruNeko Window") { haru.showHaruNeko() }
                Button("Open Downloads Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: haru.mediaDir)) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 30)
        }
    }
}

struct ResultsList: View {
    @ObservedObject var haru = Haru.shared
    var body: some View {
        VStack(spacing: 0) {
            if let e = haru.searchError {
                Text(e).font(.callout).foregroundStyle(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            List(haru.results, selection: Binding(get: { haru.picked?.id }, set: { id in
                if let g = haru.results.first(where: { $0.id == id }), g.id != haru.picked?.id { haru.pick(g) }
            })) { g in
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.title).font(.body.weight(.medium)).lineLimit(2)
                    Text(sourcesText(g)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 3).padding(.horizontal, 6).tag(g.id)
            }
            .overlay {
                if haru.results.isEmpty && haru.searchError == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass").font(.system(size: 36)).foregroundStyle(.tertiary)
                        Text("Type a manga name and press Return").foregroundStyle(.secondary)
                        if haru.sourcesIndexed < 20 && !haru.indexing {
                            Text("Tip: click “Update Sources” once so every source can be searched.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }.padding()
                }
            }
        }
    }
    private func sourcesText(_ g: SearchGroup) -> String {
        let names = Array(Set(g.sources.map(\.sourceTitle))).sorted()
        return "\(names.count) source\(names.count == 1 ? "" : "s"): " + names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " …" : "")
    }
}

struct MangaPane: View {
    @ObservedObject var haru = Haru.shared
    var body: some View {
        if let g = haru.picked {
            VSplitView {
                SourcesTable(group: g).frame(minHeight: 150, idealHeight: 200)
                ChaptersPane().frame(minHeight: 240)
            }
        } else {
            Text("Pick a result to see which source has it best")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SourcesTable: View {
    @ObservedObject var haru = Haru.shared
    let group: SearchGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(group.title).font(.title2.weight(.semibold)).lineLimit(1)
                Spacer()
                if haru.ranking {
                    ProgressView().controlSize(.small)
                    Text("Checking \(group.sources.count) source\(group.sources.count == 1 ? "" : "s")…").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Table(haru.ranked, selection: Binding(get: { haru.source?.id }, set: { id in
                if let r = haru.ranked.first(where: { $0.id == id }), r.ok, r.id != haru.source?.id { haru.open(r) }
            })) {
                TableColumn("Source") { r in
                    HStack(spacing: 6) {
                        if r.best == true {
                            Label("Best", systemImage: "star.fill").labelStyle(.titleAndIcon).font(.caption.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.yellow.opacity(0.25))).foregroundStyle(.orange)
                        }
                        Text(r.sourceTitle).fontWeight(r.best == true ? .semibold : .regular)
                        if r.official == true { Text("official").font(.caption2).foregroundStyle(.blue) }
                    }
                }.width(min: 160, ideal: 230)
                TableColumn("\(LangName.short(haru.language)) chapters") { r in
                    Text(r.ok ? "\(r.distinct ?? 0)" : "—").monospacedDigit()
                }.width(min: 70, ideal: 90)
                TableColumn("Latest") { r in Text(r.ok ? r.latestText : "—").monospacedDigit() }.width(min: 50, ideal: 60)
                TableColumn("All chapters") { r in
                    Text(r.ok ? "\(r.total ?? 0)" : "—").monospacedDigit().foregroundStyle(.secondary)
                }.width(min: 70, ideal: 80)
                TableColumn("Note") { r in
                    Text(r.ok ? (r.tagged == true ? "multi-language" : "") : (r.error ?? "unavailable"))
                        .font(.caption).foregroundStyle(r.ok ? Color.secondary : Color.red).lineLimit(1)
                }
            }
        }
    }
}

struct ChaptersPane: View {
    @ObservedObject var haru = Haru.shared
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        VStack(spacing: 0) {
            if haru.loadingChapters {
                ProgressView("Loading chapters…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let list = haru.chapterList {
                let rows = haru.visibleChapters(list)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("\(list.sourceTitle) · \(haru.chosen.count) of \(rows.count) chapters selected")
                            .font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if list.tagged { Toggle("All languages", isOn: $haru.showAllLanguages).toggleStyle(.checkbox).fixedSize() }
                    }
                    HStack(spacing: 8) {
                        TextField("from", text: $from).frame(width: 52)
                        TextField("to", text: $to).frame(width: 52)
                        Button("Select Range") { selectRange(rows) }
                            .disabled(Double(from) == nil && Double(to) == nil).fixedSize()
                        Spacer(minLength: 4)
                        Button("Best Picks") { haru.chosen = haru.defaultSelection(list) }
                            .help("Every chapter once, in your language").fixedSize()
                        Button("None") { haru.chosen = [] }.fixedSize()
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                List(rows) { c in
                    Toggle(isOn: Binding(get: { haru.chosen.contains(c.id) },
                                         set: { on in if on { haru.chosen.insert(c.id) } else { haru.chosen.remove(c.id) } })) {
                        HStack {
                            Text(c.numText).monospacedDigit().frame(width: 52, alignment: .leading).fontWeight(.medium)
                            Text(c.title).lineLimit(1)
                            Spacer()
                        }
                    }.toggleStyle(.checkbox)
                }
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Convert for Kindle when downloaded", isOn: $haru.convertAfter).toggleStyle(.checkbox).fixedSize()
                        Toggle("Get failed chapters from other sources", isOn: $haru.autoFallback).toggleStyle(.checkbox).fixedSize()
                            .help("If a source fails or blocks some chapters, only those chapters are fetched from the next best source")
                    }
                    Spacer(minLength: 8)
                    Button {
                        haru.download(convert: haru.convertAfter)
                    } label: {
                        Label(haru.convertAfter ? "Download & Convert \(haru.chosen.count)" : "Download \(haru.chosen.count)",
                              systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(haru.chosen.isEmpty).fixedSize()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            } else if haru.ranking {
                Text("Finding the best source…").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Pick a source").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func selectRange(_ rows: [ChapterInfo]) {
        let lo = Double(from) ?? -.infinity, hi = Double(to) ?? .infinity
        guard let list = haru.chapterList else { return }
        let best = haru.defaultSelection(list)
        haru.chosen = Set(rows.filter { c in
            guard let n = c.num else { return false }
            return n >= lo && n <= hi && (best.contains(c.id) || haru.showAllLanguages)
        }.map(\.id))
    }
}

struct DownloadsBar: View {
    @ObservedObject var haru = Haru.shared
    @State private var expanded = false
    @State private var fixing: FixRequest?
    var body: some View {
        let active = haru.tasks.filter { !$0.finished }
        let failed = haru.stillFailed
        let done = haru.tasks.filter { $0.status == "completed" }
        VStack(spacing: 0) {
            ForEach(haru.fixes) { f in FixBanner(fix: f) { fixing = f } }
            if !haru.tasks.isEmpty { bar(active, failed, done) }
        }
        .sheet(item: $fixing) { f in FixSheet(fix: f) }
    }

    @ViewBuilder private func bar(_ active: [DLTask], _ failed: [DLTask], _ done: [DLTask]) -> some View {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: active.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(active.isEmpty ? .green : .accentColor)
                    if !active.isEmpty {
                        let p = active.reduce(0.0) { $0 + max(0, $1.progress) } / Double(active.count)
                        Text("Downloading \(active.count) chapter\(active.count == 1 ? "" : "s")")
                        ProgressView(value: min(1, max(0, p))).frame(width: 160)
                        if let cur = active.first(where: { $0.status == "downloading" }) {
                            Text("\(cur.manga ?? "") – \(cur.chapter)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else {
                        Text("\(done.count) downloaded").foregroundStyle(.secondary)
                    }
                    if !failed.isEmpty {
                        Text("\(failed.count) chapter\(failed.count == 1 ? "" : "s") failed").foregroundStyle(.red)
                            .help(failed.map { ($0.manga ?? "") + " – " + $0.chapter }.joined(separator: "\n"))
                    }
                    let orphans = haru.orphanFailed
                    if !orphans.isEmpty && haru.fixes.isEmpty {
                        Button("Find Failed on Other Sources…") { haru.fixFromTasks(orphans) }
                            .help("Look for the failed chapters on the other sources that have this manga")
                    }
                    Spacer()
                    Button(expanded ? "Hide" : "Details") { expanded.toggle() }
                    if !active.isEmpty { Button("Cancel All") { haru.cancel(active.map(\.id)) } }
                    Button("Clear Finished") { haru.clearFinished() }
                        .disabled(done.isEmpty && !haru.tasks.contains { $0.status == "failed" })
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                if expanded {
                    List(haru.tasks) { t in
                        HStack {
                            Text(t.manga ?? "").foregroundStyle(.secondary).frame(width: 180, alignment: .leading).lineLimit(1)
                            Text(t.chapter).lineLimit(1)
                            Spacer()
                            if t.status == "downloading" {
                                ProgressView(value: min(1, max(0, t.progress))).frame(width: 100)
                            } else {
                                let fixedElsewhere = t.status == "failed" && !failed.contains(where: { $0.id == t.id })
                                    && haru.tasks.contains { $0.status == "completed" && $0.manga == t.manga && haru.number(of: $0) == haru.number(of: t) }
                                Text(fixedElsewhere ? "got from another source" : t.status).font(.caption)
                                    .foregroundStyle(t.status == "failed" && !fixedElsewhere ? .red : .secondary)
                            }
                            if !t.errors.isEmpty { Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).help(t.errors.joined(separator: "\n")) }
                        }
                    }.frame(height: 160)
                }
            }
    }
}

/// "3 chapters failed" — shown when a batch finished with failures.
struct FixBanner: View {
    @ObservedObject var haru = Haru.shared
    let fix: FixRequest
    let open: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(fix.mangaTitle): \(fix.missing.count) chapter\(fix.missing.count == 1 ? "" : "s") failed on \(fix.failedSource)")
                    .lineLimit(1)
                Text(FixSheet.numList(fix.missing)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if fix.convert { Text("· book is waiting").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Get from Other Sources…", action: open).buttonStyle(.borderedProminent)
                if fix.convert { Button("Convert Without Them") { haru.convertWithout(fix) } }
                Button { haru.dismissFix(fix) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.10))
        }
    }
}

/// Pick, for every failed chapter, another source that has it.
struct FixSheet: View {
    @ObservedObject var haru = Haru.shared
    @Environment(\.dismiss) private var dismiss
    let fix: FixRequest
    @State private var loading = true
    @State private var error: String?
    @State private var alts: [AltSource] = []
    @State private var picks: [Double: String] = [:]     // chapter → AltSource.id ("" = skip)

    static func numList(_ ns: [Double]) -> String {
        let s = ns.prefix(12).map(AltSource.key).joined(separator: ", ")
        return "Ch. " + s + (ns.count > 12 ? " …" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get failed chapters from other sources").font(.title3.weight(.semibold))
            Text("\(fix.mangaTitle) — \(fix.missing.count) chapter\(fix.missing.count == 1 ? "" : "s") failed on \(fix.failedSource).")
                .foregroundStyle(.secondary)
            if loading {
                HStack { ProgressView().controlSize(.small); Text("Checking the other sources for these chapters…") }
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if let e = error {
                Text(e).foregroundStyle(.red).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                let found = fix.missing.filter { n in alts.contains { $0.chapter(n) != nil } }.count
                Text("\(found) of \(fix.missing.count) found elsewhere. Choose a source for each chapter:").font(.callout)
                List(fix.missing, id: \.self) { n in
                    HStack {
                        Text("Ch. " + AltSource.key(n)).monospacedDigit().fontWeight(.medium).frame(width: 80, alignment: .leading)
                        let opts = alts.filter { $0.chapter(n) != nil }
                        if opts.isEmpty {
                            Text("not found on any source").foregroundStyle(.red)
                        } else {
                            Picker("", selection: Binding(get: { picks[n] ?? "" }, set: { picks[n] = $0 })) {
                                Text("Skip").tag("")
                                ForEach(opts) { a in
                                    Text(label(a, n)).tag(a.id)
                                }
                            }.labelsHidden()
                        }
                    }
                }.frame(minHeight: 220)
                let checked = alts.filter { $0.source != fix.failedSourceId }
                Text("Checked \(checked.count) other source\(checked.count == 1 ? "" : "s")" +
                     (checked.contains { !$0.ok } ? " (\(checked.filter { !$0.ok }.count) didn't answer)" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if fix.convert {
                    Button("Convert Without Them") { haru.convertWithout(fix); dismiss() }
                }
                let n = picks.values.filter { !$0.isEmpty }.count
                Button(fix.convert ? "Download \(n) & Convert" : "Download \(n)") {
                    var sel: [Double: AltSource] = [:]
                    for (ch, id) in picks where !id.isEmpty { sel[ch] = alts.first { $0.id == id } }
                    haru.downloadReplacements(fix, picks: sel)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(n == 0 || loading)
            }
        }
        .padding(20).frame(width: 620)
        .task { await load() }
    }

    private func label(_ a: AltSource, _ n: Double) -> String {
        let retry = a.source == fix.failedSourceId ? " (try again)" : ""
        let t = a.chapter(n)?.title ?? ""
        return "\(a.sourceTitle)\(retry) — \(t)"
    }

    private func load() async {
        do {
            alts = try await haru.alternatives(for: fix)
            // default: the other source that has the most of the missing chapters; the failed source last
            let order = alts.filter(\.ok).sorted { a, b in
                let fa = a.source == fix.failedSourceId, fb = b.source == fix.failedSourceId
                if fa != fb { return !fa }
                return a.has.count > b.has.count
            }
            for n in fix.missing { picks[n] = order.first { $0.chapter(n) != nil }?.id ?? "" }
            if alts.isEmpty { error = "No other source with this manga was found. Try “Update Sources” or search for it again." }
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

extension LangName {
    static func short(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

struct VerifyBanner: View {
    @ObservedObject var haru = Haru.shared
    var body: some View {
        if let c = haru.checks.first {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.shield.checkmark").foregroundStyle(.orange)
                Text("\(c.host) wants a quick “are you human” check\(haru.checks.count > 1 ? " (+\(haru.checks.count - 1) more)" : "").")
                Text("Only needed if you want chapters from that site.").foregroundStyle(.secondary)
                Spacer()
                Button("Verify Now") { haru.verify(c) }
            }
            .font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            Divider()
        }
    }
}
