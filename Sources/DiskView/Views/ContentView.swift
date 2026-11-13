import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            ZStack {
                switch model.phase {
                case .welcome:
                    WelcomeView()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .scanning:
                    ScanningView()
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                case .result:
                    if let root = model.root, let focus = model.focus {
                        ResultView(root: root, focus: focus)
                            .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { ToastView() }
        }
        .navigationTitle(model.target?.name ?? "DiskView")
        .navigationSubtitle(subtitle)
        .quickLookPreview($model.previewURL)
    }

    private var subtitle: String {
        switch model.phase {
        case .welcome: return "Choose a disk or folder"
        case .scanning: return "Scanning…"
        case .result:
            guard let root = model.root else { return "" }
            return "\(Format.bytes(root.size)) · \(Format.count(root.fileCount)) files · scanned in \(Format.duration(model.scanDuration))"
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let text = model.toast {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { withAnimation(.spring(duration: 0.3, bounce: 0)) { model.toast = nil } }
        }
    }
}

/// Shared context menu for any node, in the chart or the list.
struct NodeMenu: View {
    @Environment(AppModel.self) private var model
    let node: FileNode

    var body: some View {
        if node.isReal {
            if node.canDrillIn {
                Button("Zoom In", systemImage: "plus.magnifyingglass") { model.drill(into: node) }
            }
            Button("Open", systemImage: "arrow.up.forward.app") { model.open(node) }
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(node) }
            Button("Quick Look", systemImage: "eye") { model.quickLook(node) }
            Button("Copy Path", systemImage: "doc.on.doc") { model.copyPath(node) }
            if node.isApp {
                Button("Find Leftovers…", systemImage: "sparkle.magnifyingglass") { model.findLeftovers(for: node, show: true) }
            }
            Divider()
            if model.collected.contains(where: { $0 === node }) {
                Button("Remove from Collector", systemImage: "minus.circle") { model.uncollect(node) }
            } else {
                Button("Add to Collector", systemImage: "tray.and.arrow.down") { model.collect(node) }
                    .disabled(model.isCollected(node) || node.parent == nil)
            }
        } else {
            Text(node.kindDescription)
        }
    }
}
