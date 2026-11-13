import AppKit
import Observation
import SwiftUI

/// Watches the Trash. When an app is dragged there, finds what it left in the Library
/// and offers to remove that too.
@Observable
@MainActor
final class SmartDelete {
    static let shared = SmartDelete()
    static let enabledKey = "watchTrashForApps"

    /// Set at launch so the pop-up can share the app's model (icons, collector state).
    @ObservationIgnored weak var model: AppModel?

    var isEnabled: Bool = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }
    /// Why watching isn't working, if it isn't.
    var problem: String?
    /// Apps whose leftovers are being looked up right now.
    var checking: Set<String> = []

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var known: Set<String> = []
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private var windows: [NSWindow] = []

    nonisolated static var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
    }

    func start() {
        guard isEnabled, source == nil else { return }
        let path = Self.trashURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0, let current = Self.trashedApps() else {
            if fd >= 0 { close(fd) }
            problem = "DiskView needs Full Disk Access to see what's in the Trash."
            NSLog("DiskView SmartDelete: can't read the Trash (no Full Disk Access)")
            return
        }
        problem = nil
        NSLog("DiskView SmartDelete: watching the Trash (%d apps already there)", current.count)
        known = current // only apps trashed from now on count
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleCheck() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        pending?.cancel()
    }

    /// Top-level apps in the Trash, or nil when the Trash can't be read.
    nonisolated static func trashedApps() -> Set<String>? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trashURL.path) else { return nil }
        return Set(names.filter { $0.lowercased().hasSuffix(".app") })
    }

    /// Finder writes to the Trash in several steps; wait for it to settle before looking.
    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func check() {
        guard let now = Self.trashedApps() else { return }
        let added = now.subtracting(known)
        known = now
        for name in added.sorted() {
            handle(Self.trashURL.appending(path: name))
        }
    }

    /// Exposed for testing: treat `appURL` as just trashed.
    func handle(_ appURL: URL) {
        let key = appURL.path
        guard !checking.contains(key) else { return }
        checking.insert(key)
        Task.detached(priority: .utility) {
            let outcome = Self.inspect(appURL)
            await MainActor.run {
                self.checking.remove(key)
                if let report = outcome { self.present(report, appURL: appURL) }
            }
        }
    }

    /// Returns leftovers worth offering, or nil when there's nothing to say.
    nonisolated static func inspect(_ appURL: URL) -> LeftoverReport? {
        guard let info = LeftoverFinder.appInfo(appURL) else { return nil }
        // Still installed somewhere else (e.g. an updater just trashed the old copy):
        // its data is in use, so stay quiet.
        if let other = installedCopy(bundleID: info.bundleID, excluding: appURL) {
            NSLog("DiskView: %@ is still installed at %@; not offering leftovers", info.bundleID, other.path)
            return nil
        }
        let result = LeftoverFinder.find(appURL: appURL)
        guard result.note == nil else { return nil }
        let items = result.candidates.map { c in
            Leftover(path: c.path, location: c.location, confidence: c.confidence,
                     canDelete: FileManager.default.isDeletableFile(atPath: c.path),
                     node: LeftoverFinder.measure(c))
        }
        // Only interrupt when something removable is actually taking space.
        guard items.contains(where: { $0.canDelete && $0.node.size > 0 }) else { return nil }
        return LeftoverReport(appName: result.name, items: items, note: nil)
    }

    nonisolated static func installedCopy(bundleID: String, excluding trashed: URL) -> URL? {
        let trashPath = trashURL.path
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).first { url in
            let p = url.standardizedFileURL.path
            return p != trashed.standardizedFileURL.path
                && !p.hasPrefix(trashPath + "/")
                && !p.contains("/.Trashes/")
                && FileManager.default.fileExists(atPath: p)
        }
    }

    // MARK: Pop-up

    private func present(_ report: LeftoverReport, appURL: URL) {
        guard let model else { return }
        NSLog("DiskView SmartDelete: offering %d leftovers for %@", report.items.count, report.appName)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = NSHostingController(
            rootView: TrashedAppLeftoversView(report: report, appURL: appURL) { [weak window] in window?.close() }
                .environment(model)
        )
        window.center()
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.windows.removeAll { $0 === note.object as? NSWindow }
                AppDelegate.updateDockPresence()
            }
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// The window that appears after an app is dragged to the Trash.
struct TrashedAppLeftoversView: View {
    let report: LeftoverReport
    let appURL: URL
    let close: () -> Void

    @State private var selected: Set<UUID> = []
    @State private var result: String?
    @State private var working = false

    private var chosen: [Leftover] { report.items.filter { selected.contains($0.id) && $0.canDelete } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("You moved \(report.appName) to the Trash")
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                    Text("It left these files in your Library. Move them to the Trash as well?")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 16)
            Divider()
            if let result {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green)
                    Text(result).font(.system(size: 14, weight: .medium)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LeftoverReviewList(items: report.items, selected: $selected)
            }
            Divider()
            HStack(spacing: 12) {
                let total = chosen.reduce(Int64(0)) { $0 + $1.node.size }
                Text(chosen.isEmpty ? "Nothing selected" : "\(chosen.count) selected · \(Format.bytes(total))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Spacer()
                if result == nil {
                    Button("Keep Files") { close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Move to Trash") { trash() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(chosen.isEmpty || working)
                } else {
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 600, height: 480)
        .onAppear {
            selected = Set(report.items.filter { $0.confidence == .certain && $0.canDelete }.map(\.id))
        }
    }

    private func trash() {
        let items = chosen
        working = true
        Task.detached(priority: .userInitiated) {
            var freed: Int64 = 0, failed = 0
            for item in items {
                if (try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)) != nil {
                    freed += item.node.size
                } else {
                    failed += 1
                }
            }
            let message = "Moved \(Format.bytes(freed)) to the Trash."
                + (failed > 0 ? "\n\(failed) item\(failed == 1 ? "" : "s") couldn't be moved." : "")
            await MainActor.run {
                working = false
                withAnimation(.spring(duration: 0.35, bounce: 0)) { result = message }
            }
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run { close() }
        }
    }
}
