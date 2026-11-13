import AppKit
import SwiftUI

@main
struct DiskViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let shared = AppModel()
        _model = State(initialValue: shared)
        SmartDelete.shared.model = shared

        // Headless benchmark: DiskView --scan <path>
        let args = CommandLine.arguments
        // Headless check: DiskView --inspect-trashed <path to .app>
        if let i = args.firstIndex(of: "--inspect-trashed"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            if let info = LeftoverFinder.appInfo(url), let other = SmartDelete.installedCopy(bundleID: info.bundleID, excluding: url) {
                print("still installed at \(other.path): would stay quiet")
            } else if let r = SmartDelete.inspect(url) {
                print("would offer \(r.items.count) leftovers for \(r.appName):")
                for item in r.items { print("  [\(item.confidence)] \(Format.bytes(item.node.size)) \(item.displayPath)") }
            } else {
                print("nothing to offer")
            }
            exit(0)
        }
        // Headless check: DiskView --leftovers <path to .app>
        if let i = args.firstIndex(of: "--leftovers"), i + 1 < args.count {
            let r = LeftoverFinder.find(appURL: URL(fileURLWithPath: args[i + 1]))
            print("app: \(r.name)" + (r.note.map { "  note: \($0)" } ?? ""))
            for c in r.candidates {
                let n = LeftoverFinder.measure(c)
                print("  [\(c.confidence)] \(Format.bytes(n.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(c.location): \(c.path)\(FileManager.default.isDeletableFile(atPath: c.path) ? "" : "  (needs admin)")")
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--bench"), i + 1 < args.count {
            Bench.run(path: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
            let start = Date()
            let scanner = DiskScanner()
            let root = scanner.scan(path: args[i + 1], displayName: args[i + 1])
            print("bytes=\(root.size) files=\(root.fileCount) folders=\(scanner.progress.folders.load(ordering: .relaxed)) denied=\(scanner.progress.denied.load(ordering: .relaxed)) time=\(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            exit(0)
        }
    }

    var body: some Scene {
        Window("DiskView", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 660)
                .onAppear { SnapshotDriver.runIfRequested(model: model) }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1240, height: 800)

        Settings {
            SettingsView()
        }

        // While DiskView watches the Trash it keeps running after its window closes,
        // with this menu bar icon as the way back in.
        MenuBarExtra("DiskView", systemImage: "internaldrive",
                     isInserted: Binding(get: { SmartDelete.shared.isEnabled }, set: { _ in })) {
            MenuBarContent()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { model.pickFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.target == nil || model.phase == .scanning)
                Button("Close Scan") { model.closeResults() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.phase == .welcome)
            }
            CommandMenu("Go") {
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!model.nav.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]")
                    .disabled(!model.nav.canGoForward)
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow)
                    .disabled(!model.nav.canGoUp)
                Divider()
                // These act on whatever is under the pointer. They deliberately don't read the hover
                // state to decide enabled-ness: that would rebuild the menu bar on every mouse move.
                Button("Quick Look") { if let n = model.hovered { model.quickLook(n) } }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Add to Collector") { if let n = model.hovered { model.collect(n) } }
                    .keyboardShortcut("c", modifiers: [])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        SmartDelete.shared.start()
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the close finishes, so the closing window no longer counts as open.
                DispatchQueue.main.async { MainActor.assumeIsolated { Self.updateDockPresence() } }
            }
        }
        // Started at login: just watch the Trash, don't open a window.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem,
           SmartDelete.shared.isEnabled {
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.styleMask.contains(.titled) }.forEach { $0.close() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep watching the Trash in the background instead of quitting.
        !SmartDelete.shared.isEnabled
    }

    /// Show the Dock icon while a real window is open; hide it when only the menu bar icon is left.
    static func updateDockPresence() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        let policy: NSApplication.ActivationPolicy = hasWindow || !SmartDelete.shared.isEnabled ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}

extension AppModel {
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to scan"
        if panel.runModal() == .OK, let url = panel.url { scan(folder: url) }
    }
}
