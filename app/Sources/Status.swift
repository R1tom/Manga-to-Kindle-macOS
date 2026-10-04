import SwiftUI

// MARK: - what happened to each manga: download → convert → send (kept on disk, newest first)

struct Step: Codable, Equatable {
    enum State: String, Codable { case waiting, active, done, failed, skipped }
    var state: State
    var detail: String
    var at: Date = Date()
}

struct Track: Codable, Identifiable, Equatable {
    var id: String                       // lowercased title
    var title: String
    var download: Step?
    var convert: Step?
    var send: Step?
    var books: [String] = []             // Kindle files made for it
    var updated = Date()

    var finished: Bool {
        let steps = [download, convert, send].compactMap { $0 }
        return !steps.isEmpty && steps.allSatisfy { $0.state == .done || $0.state == .skipped }
    }
    var failed: Bool { [download, convert, send].contains { $0?.state == .failed } }
}

@MainActor
final class Status: ObservableObject {
    static let shared = Status()
    @Published private(set) var tracks: [Track] = Status.load() { didSet { save() } }

    private static var url: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MangaToKindle")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("status.json")
    }
    private static func load() -> [Track] {
        guard let d = try? Data(contentsOf: url), var t = try? JSONDecoder().decode([Track].self, from: d) else { return [] }
        // the app was closed while something ran: say so instead of showing a spinner forever
        for i in t.indices {
            if t[i].convert?.state == .active { t[i].convert = Step(state: .failed, detail: "Interrupted — the app was closed while converting") }
            if t[i].send?.state == .active { t[i].send = Step(state: .failed, detail: "Interrupted — the app was closed while copying") }
        }
        return t
    }
    private func save() {
        if let d = try? JSONEncoder().encode(tracks) { try? d.write(to: Status.url, options: .atomic) }
    }

    static func key(_ title: String) -> String { title.trimmingCharacters(in: .whitespaces).lowercased() }

    /// change one step of a manga (creates its card, moves it to the top)
    func set(_ title: String, _ step: WritableKeyPath<Track, Step?>, _ state: Step.State, _ detail: String) {
        guard !title.isEmpty else { return }
        let k = Status.key(title)
        var t = tracks.first { $0.id == k } ?? Track(id: k, title: title)
        let new = Step(state: state, detail: detail, at: t[keyPath: step]?.state == state ? (t[keyPath: step]?.at ?? Date()) : Date())
        if t[keyPath: step]?.state == state && t[keyPath: step]?.detail == detail { return }
        t[keyPath: step] = new
        t.updated = Date()
        tracks.removeAll { $0.id == k }
        tracks.insert(t, at: 0)
        if tracks.count > 15 { tracks.removeLast(tracks.count - 15) }
    }

    /// a fresh run for this title: forget the old steps
    func start(_ title: String, download: Bool, convert: Bool) {
        let k = Status.key(title)
        tracks.removeAll { $0.id == k }
        if download { set(title, \.download, .active, "Starting download…") }
        set(title, \.convert, convert ? .waiting : .skipped, convert ? "Starts when the downloads finish" : "Not converting (turned off)")
        set(title, \.send, convert ? .waiting : .skipped, convert ? "After converting" : "—")
    }

    func setBooks(_ title: String, _ files: [String]) {
        let k = Status.key(title)
        guard let i = tracks.firstIndex(where: { $0.id == k }) else { return }
        tracks[i].books = files
    }

    func title(forFile f: String) -> String? {
        tracks.first { $0.books.contains(f) }?.title
    }

    func remove(_ id: String) { tracks.removeAll { $0.id == id } }
    func clearFinished() { tracks.removeAll { $0.finished } }
}

// MARK: - the panel

struct StatusSection: View {
    @ObservedObject var status = Status.shared
    @ObservedObject var job = Job.shared
    @ObservedObject var kindle = KindleDevice.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Status").font(.headline)
                Spacer()
                if status.tracks.contains(where: \.finished) {
                    Button("Clear Done") { status.clearFinished() }.buttonStyle(.borderless).font(.caption)
                }
            }
            if status.tracks.isEmpty {
                Text("Nothing yet — downloads, conversions and Kindle copies show up here step by step.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                let cards = VStack(spacing: 8) { ForEach(status.tracks) { t in TrackCard(track: t) } }
                ViewThatFits(in: .vertical) {
                    cards                                  // as tall as the cards, up to 300 pt
                    ScrollView { cards }                   // more than that: scroll
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
    }
}

struct TrackCard: View {
    @ObservedObject var job = Job.shared
    @ObservedObject var kindle = KindleDevice.shared
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(track.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                if track.finished {
                    Label("Done", systemImage: "checkmark.seal.fill").labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                } else if track.failed {
                    Label("Needs attention", systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                Text(track.updated, style: .time).font(.caption2).foregroundStyle(.secondary)
                Button { Status.shared.remove(track.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.caption2).foregroundStyle(.secondary).help("Remove from the list")
            }
            if let s = track.download { StepRow(name: "Download", icon: "arrow.down.circle", step: s, progress: nil) }
            if let s = track.convert { StepRow(name: "Convert", icon: "book.and.wrench", step: s, progress: convertProgress(s)) }
            if let s = track.send { StepRow(name: "Kindle", icon: "arrow.up.forward.app", step: s, progress: sendProgress(s)) }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(track.failed ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.18)))
    }

    private func convertProgress(_ s: Step) -> Double? {
        guard s.state == .active, job.running, job.total > 0 else { return s.state == .active ? -1 : nil }
        return Double(job.done) / Double(job.total)
    }
    private func sendProgress(_ s: Step) -> Double? {
        guard s.state == .active else { return nil }
        return kindle.sendTotal > 0 ? Double(kindle.sendDone) / Double(kindle.sendTotal) : -1
    }
}

struct StepRow: View {
    let name: String
    let icon: String
    let step: Step
    let progress: Double?          // nil = none, -1 = busy without a number

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                stateIcon.frame(width: 16)
                Text(name).font(.caption.weight(.medium)).frame(width: 58, alignment: .leading)
                Text(step.detail).font(.caption).foregroundStyle(color == .secondary ? .secondary : .primary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 0)
                if step.state == .done || step.state == .failed {
                    Text(step.at, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let p = progress {
                Group {
                    if p < 0 { ProgressView().progressViewStyle(.linear) } else { ProgressView(value: min(1, max(0, p))) }
                }
                .controlSize(.small).padding(.leading, 22)
            }
        }
    }

    private var color: Color {
        switch step.state {
        case .done: return .green
        case .failed: return .red
        case .active: return .accentColor
        default: return .secondary
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch step.state {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .active: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
