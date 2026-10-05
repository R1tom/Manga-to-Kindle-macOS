import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ app: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            Job.shared.open(urls.map(\.path))
            UserDefaults.standard.set("files", forKey: "mainMode")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        !MainActor.assumeIsolated { Job.shared.running || Haru.shared.tasks.contains { !$0.finished } }
    }

    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated {
            Haru.shared.shutdown()
            if KindleDevice.shared.autoEjectOnPower && KindleDevice.shared.poweringOff { KindleDevice.shared.ejectNow() }
        }
    }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        if MainActor.assumeIsolated({ KindleDevice.shared.sending }) {
            let a = NSAlert()
            a.messageText = "Books are still being copied to the Kindle"
            a.informativeText = "Quitting (or restarting the Mac) now would leave a half-copied book on the Kindle. Wait a moment, then try again."
            a.addButton(withTitle: "Wait"); a.addButton(withTitle: "Quit Anyway")
            if a.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        let downloading = MainActor.assumeIsolated { Haru.shared.tasks.contains { !$0.finished } }
        if downloading {
            let a = NSAlert()
            a.messageText = "Chapters are still downloading"
            a.informativeText = "Quitting stops the downloads (HaruNeko closes too)."
            a.addButton(withTitle: "Quit"); a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            MainActor.assumeIsolated { Haru.shared.tasks = [] }
        }
        if MainActor.assumeIsolated({ Job.shared.running }) {
            let a = NSAlert()
            a.messageText = "A book is still being converted"
            a.informativeText = "Quitting stops the conversion. Your chapter files are not touched."
            a.addButton(withTitle: "Quit"); a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            MainActor.assumeIsolated { Job.shared.stop() }
            Thread.sleep(forTimeInterval: 1.0)
        }
        return .terminateNow
    }
}

/// One window: search / chapters on the left, every setting + convert + send on the right.
struct ContentView: View {
    @AppStorage("mainMode") private var mode = "search"
    @ObservedObject var job = Job.shared
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                switch mode {
                case "files": FilesPane()
                case "library": DownloadsPane()
                case "device": DevicePane()
                case "books": BooksPane()
                default: SearchView()
                }
                DownloadsBar()
            }
            .frame(minWidth: 640)
            SidePanel().frame(minWidth: 340, idealWidth: 370, maxWidth: 460)
        }
        .modifier(FileDrop())
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if mode == "search" && !job.chapters.isEmpty {
                    Button { mode = "files" } label: { Label("Chapters (\(job.selected.count))", systemImage: "list.bullet") }
                        .help("Back to the chapter list that is ready to convert")
                }
                Button { mode = mode == "library" ? "search" : "library" } label: {
                    Label("Downloaded", systemImage: "tray.full")
                }
                .help("Manga already downloaded to the HaruNeko folder — convert and send them to the Kindle")
                Button { mode = mode == "books" ? "search" : "books" } label: {
                    Label("Books", systemImage: "book")
                }
                .help("Search books (not manga) — sent to the Kindle as AZW3, its own format")
                Button { mode = mode == "device" ? "search" : "device" } label: {
                    Label("On Kindle", systemImage: "books.vertical")
                }
                .help("Everything stored on the connected Kindle — select and delete")
                Button { pickSources() } label: { Label("Open Folder or Files…", systemImage: "folder.badge.plus") }
                    .help("Convert chapter files you already have (CBZ, PDF, CBR, EPUB, image folders…)")
                KindleChip()
                KindleEjectButton()
            }
        }
        .navigationTitle("Manga to Kindle")
        .navigationSubtitle(job.chapters.isEmpty ? "Kindle Paperwhite 11th gen" :
            "\(job.title) · \(job.selected.count) chapters · \(job.selectedPages) pages")
        .onReceive(NotificationCenter.default.publisher(for: .showConverter)) { _ in mode = "files" }
        .onAppear {
            Haru.shared.start(); _ = KindleDevice.shared
            // open -a "Manga to Kindle" --args --book-search "pride and prejudice"
            let a = CommandLine.arguments
            if let i = a.firstIndex(of: "--book-search"), i + 1 < a.count {
                mode = "books"; BookStore.shared.query = a[i + 1]; BookStore.shared.search()
            }
        }
    }
}

@main
struct MangaToKindleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Manga to Kindle", id: "main") {
            ContentView().frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandMenu("Kindle") {
                Button("Eject Kindle") { KindleDevice.shared.eject() }.keyboardShortcut("e", modifiers: .command)
                Button("Set Up KOReader for Manga") { KindleDevice.shared.setUpKOReader() }
                Button("Show Books on Kindle") { UserDefaults.standard.set("device", forKey: "mainMode") }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder or Files…") { pickSources() }.keyboardShortcut("o")
            }
        }
    }
}
