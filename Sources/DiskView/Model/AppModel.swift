import AppKit
import Observation
import SwiftUI

struct ScanTarget: Equatable {
    let url: URL
    let name: String
    let volume: Volume?
}

@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable { case welcome, scanning, result }

    var volumes: [Volume] = Volume.mounted()
    var phase: Phase = .welcome
    var target: ScanTarget?

    // Scan progress snapshot (polled from the scanner's atomics).
    var scannedFiles = 0
    var scannedBytes: Int64 = 0
    var scanningPath = ""
    var scanStarted = Date()
    var scanDuration: TimeInterval = 0
    var deniedCount = 0

    // Results
    var root: FileNode?
    var focus: FileNode?
    var hovered: FileNode?
    // History isn't observed directly: menus and toolbars read only `nav`, which changes
    // when a button actually becomes enabled or disabled, not on every zoom.
    @ObservationIgnored var backStack: [FileNode] = []
    @ObservationIgnored var forwardStack: [FileNode] = []
    struct NavState: Equatable { var canGoBack = false, canGoForward = false, canGoUp = false }
    var nav = NavState()
    /// Bumped whenever the (non-observable) tree mutates.
    var treeVersion = 0

    // Collector
    var collected: [FileNode] = []
    var isDeleting = false
    var toast: String?

    var previewURL: URL?

    // Leftovers: data apps keep in ~/Library after the app itself is gone.
    var leftovers: [ObjectIdentifier: LeftoverSearch] = [:]
    var leftoverSheet: FileNode?

    private var scanner: DiskScanner?
    private var pollTimer: Timer?

    var collectedSize: Int64 { collected.reduce(0) { $0 + $1.size } }

    // MARK: Scanning

    func refreshVolumes() { volumes = Volume.mounted() }

    func scan(volume: Volume) {
        scan(ScanTarget(url: volume.url, name: volume.name, volume: volume))
    }

    func scan(folder url: URL) {
        let vol = volumes.first { $0.url.path == url.standardizedFileURL.path }
        scan(ScanTarget(url: url, name: vol?.name ?? FileManager.default.displayName(atPath: url.path), volume: vol))
    }

    func scan(_ t: ScanTarget) {
        cancelScan()
        target = t
        root = nil; focus = nil; hovered = nil
        backStack = []; forwardStack = []; collected = []
        refreshNav()
        scannedFiles = 0; scannedBytes = 0; deniedCount = 0; scanningPath = t.url.path
        scanStarted = Date()
        withAnimation(.spring(duration: 0.4, bounce: 0)) { phase = .scanning }

        let scanner = DiskScanner()
        self.scanner = scanner
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollProgress() }
        }

        let path = t.url.path, name = t.name
        Thread.detachNewThread { [weak self] in
            let tree = scanner.scan(path: path, displayName: name)
            DispatchQueue.main.async {
                guard let self, self.scanner === scanner else { return }
                self.finishScan(tree)
            }
        }
    }

    private func pollProgress() {
        guard let p = scanner?.progress else { return }
        scannedFiles = p.files.load(ordering: .relaxed)
        scannedBytes = p.bytes.load(ordering: .relaxed)
        deniedCount = p.denied.load(ordering: .relaxed)
        scanningPath = p.currentPath.withLock { $0 }
    }

    private func finishScan(_ tree: FileNode) {
        let wasCancelled = scanner?.progress.cancelled.load(ordering: .relaxed) ?? false
        pollProgress()
        pollTimer?.invalidate(); pollTimer = nil
        scanner = nil
        if wasCancelled { withAnimation(.spring(duration: 0.4, bounce: 0)) { phase = .welcome }; return }

        if let vol = target?.volume { addSyntheticSpace(to: tree, volume: vol) }
        scanDuration = Date().timeIntervalSince(scanStarted)
        root = tree
        focus = tree
        refreshNav()
        treeVersion += 1
        withAnimation(.spring(duration: 0.5, bounce: 0)) { phase = .result }
    }

    func cancelScan() {
        scanner?.progress.cancelled.store(true, ordering: .relaxed)
    }

    func rescan() { if let target { scan(target) } }

    func closeResults() {
        cancelScan()
        refreshVolumes()
        withAnimation(.spring(duration: 0.4, bounce: 0)) {
            phase = .welcome
            root = nil; focus = nil; collected = []
        }
        backStack = []; forwardStack = []
        refreshNav()
    }

    /// Space macOS reports as used but that no visible file accounts for.
    private func addSyntheticSpace(to root: FileNode, volume: Volume) {
        let fresh = Volume.mounted().first { $0.url == volume.url } ?? volume
        let purgeable = fresh.purgeable
        let hidden = fresh.used - root.size - purgeable
        if purgeable > 0 {
            root.children.append(FileNode(name: "Purgeable space", kind: .purgeable, size: purgeable, parent: root))
        }
        if hidden > 0 {
            root.children.append(FileNode(name: "Hidden space", kind: .hidden, size: hidden, parent: root))
        }
        root.size = root.children.reduce(0) { $0 + $1.size }
        root.children.sort { $0.size > $1.size }
    }

    // MARK: Navigation

    func drill(into node: FileNode) {
        guard node.canDrillIn, node !== focus, let focus else { return }
        backStack.append(focus)
        forwardStack.removeAll()
        setFocus(node)
    }

    func goUp() {
        guard let parent = focus?.parent else { return }
        drill(into: parent)
    }

    func goBack() {
        guard let prev = backStack.popLast(), let focus else { return }
        forwardStack.append(focus)
        setFocus(prev)
    }

    func goForward() {
        guard let next = forwardStack.popLast(), let focus else { return }
        backStack.append(focus)
        setFocus(next)
    }

    private func setFocus(_ node: FileNode) {
        hovered = nil
        withAnimation(.spring(duration: 0.55, bounce: 0)) { focus = node }
        refreshNav()
    }

    func refreshNav() {
        let n = NavState(canGoBack: !backStack.isEmpty, canGoForward: !forwardStack.isEmpty,
                         canGoUp: focus?.parent != nil)
        if n != nav { nav = n }
    }

    // MARK: Collector

    func isCollected(_ node: FileNode) -> Bool {
        collected.contains { node.isDescendant(of: $0) }
    }

    func collect(_ node: FileNode) {
        // Anything real except the scan root itself. Leftovers found outside the scanned
        // folder arrive as standalone nodes (no parent) and are allowed too.
        guard node.isReal, node !== root, !isCollected(node) else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            collected.removeAll { $0.isDescendant(of: node) }
            collected.append(node)
        }
        if node.isApp { findLeftovers(for: node, show: false) }
    }

    func uncollect(_ node: FileNode) {
        withAnimation(.spring(duration: 0.35, bounce: 0)) { collected.removeAll { $0 === node } }
    }

    func clearCollector() {
        withAnimation(.spring(duration: 0.35, bounce: 0)) { collected.removeAll() }
    }

    /// Moves every collected item to the Trash (recoverable) and prunes the tree.
    func trashCollected() {
        let items = collected
        guard !items.isEmpty, !isDeleting else { return }
        isDeleting = true
        let urls = items.map(\.url)
        Task.detached(priority: .userInitiated) {
            var results: [Bool] = []
            for url in urls {
                results.append((try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil)
            }
            let outcome = results
            await MainActor.run { self.applyTrash(items: items, results: outcome) }
        }
    }

    private func applyTrash(items: [FileNode], results: [Bool]) {
        var freed: Int64 = 0, failed = 0
        withAnimation(.spring(duration: 0.55, bounce: 0)) {
            for (node, ok) in zip(items, results) {
                guard ok else { failed += 1; continue }
                freed += node.size
                if let f = focus, f.isDescendant(of: node) { focus = node.parent }
                backStack.removeAll { $0.isDescendant(of: node) }
                forwardStack.removeAll { $0.isDescendant(of: node) }
                if let h = hovered, h.isDescendant(of: node) { hovered = nil }
                node.removeFromTree()
            }
            collected.removeAll { item in zip(items, results).contains { $0.0 === item && $0.1 } }
            refreshNav()
            treeVersion += 1
        }
        isDeleting = false
        var msg = "Moved \(Format.bytes(freed)) to the Trash"
        if failed > 0 { msg += " · \(failed) item\(failed == 1 ? "" : "s") couldn't be moved" }
        showToast(msg)
        refreshVolumes()
    }

    func showToast(_ text: String) {
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { toast = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if toast == text { withAnimation(.spring(duration: 0.4, bounce: 0)) { toast = nil } }
        }
    }

    // MARK: Finder actions

    func reveal(_ node: FileNode) {
        guard node.isReal else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func open(_ node: FileNode) {
        guard node.isReal else { return }
        NSWorkspace.shared.open(node.url)
    }

    func quickLook(_ node: FileNode) {
        guard node.isReal else { return }
        previewURL = node.url
    }

    func copyPath(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
