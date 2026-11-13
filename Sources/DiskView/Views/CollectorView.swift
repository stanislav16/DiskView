import SwiftUI

/// Floating glass tray. Drag anything from the chart or list onto it,
/// review what's gathered, then move it all to the Trash in one go.
struct CollectorBar: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var confirming = false

    var body: some View {
        let empty = model.collected.isEmpty
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(targeted ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.full")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(targeted || !empty ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 38, height: 38)

            if empty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Collector").font(.system(size: 13, weight: .semibold))
                    Text(targeted ? "Drop to collect" : "Drag files and folders here to clean them up together")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.collected) { node in
                            CollectedChip(node: node)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))

                VStack(alignment: .trailing, spacing: 0) {
                    Text(Format.bytes(model.collectedSize))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("\(model.collected.count) item\(model.collected.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .animation(.spring(duration: 0.35, bounce: 0), value: model.collectedSize)

                Button("Clear", systemImage: "xmark") { model.clearCollector() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .help("Empty the collector (nothing is deleted)")

                Button { confirming = true } label: {
                    if model.isDeleting {
                        ProgressView().controlSize(.small).frame(width: 110)
                    } else {
                        Label("Move to Trash", systemImage: "trash")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(model.isDeleting)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: empty ? 520 : .infinity)
        .glassEffect(targeted ? .regular.tint(.accentColor.opacity(0.25)) : .regular, in: .rect(cornerRadius: 22))
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(duration: 0.45, bounce: 0.12), value: model.collected.count)
        .animation(.spring(duration: 0.25, bounce: 0), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let root = model.root else { return false }
            var any = false
            for url in urls {
                if let node = root.find(path: url.standardizedFileURL.path) { model.collect(node); any = true }
            }
            return any
        } isTargeted: { targeted = $0 }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.trashCollected() }
            if let app = appWithLeftovers {
                Button("Review Leftovers First") { model.findLeftovers(for: app, show: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let app = appWithLeftovers {
                let left = model.pendingLeftovers(for: app)
                Text("\(app.name) leaves \(left.count) item\(left.count == 1 ? "" : "s") (\(Format.bytes(left.reduce(0) { $0 + $1.node.size }))) behind in your Library. You can put everything back from the Trash until you empty it.")
            } else {
                Text("You can put them back from the Trash until you empty it.")
            }
        }
    }

    /// A collected app whose own leftovers aren't in the Collector yet.
    private var appWithLeftovers: FileNode? {
        model.collected.first { $0.isApp && !model.pendingLeftovers(for: $0).isEmpty }
    }

    private var confirmTitle: String {
        let n = model.collected.count
        return "Move \(n) item\(n == 1 ? "" : "s") (\(Format.bytes(model.collectedSize))) to the Trash?"
    }
}

private struct CollectedChip: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            NodeIcon(node: node, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(Format.bytes(node.size)).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: 150, alignment: .leading)
            if node.isApp { LeftoverBadge(app: node) }
            Button { model.uncollect(node) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
            .opacity(hovering ? 1 : 0.0)
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 5)
        .background(.primary.opacity(hovering ? 0.10 : 0.06), in: Capsule())
        .onHover { h in withAnimation(.spring(duration: 0.2, bounce: 0)) { hovering = h } }
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(node) }
            Button("Remove from Collector", systemImage: "minus.circle") { model.uncollect(node) }
        }
        .help(node.path)
    }
}

/// On a collected app: shows how much it leaves behind, and opens the review sheet.
private struct LeftoverBadge: View {
    @Environment(AppModel.self) private var model
    let app: FileNode

    var body: some View {
        switch model.leftovers[app.id] {
        case .searching?:
            ProgressView().controlSize(.mini)
                .help("Looking for leftovers…")
        case .done?:
            let pending = model.pendingLeftovers(for: app)
            if !pending.isEmpty {
                Button { model.findLeftovers(for: app, show: true) } label: {
                    Text("+\(Format.bytes(pending.reduce(0) { $0 + $1.node.size }))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(.tint)
                }
                .buttonStyle(PressableStyle())
                .help("This app leaves \(pending.count) item\(pending.count == 1 ? "" : "s") in your Library. Click to review.")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        case nil:
            EmptyView()
        }
    }
}
