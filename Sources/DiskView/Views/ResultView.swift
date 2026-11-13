import SwiftUI

struct ResultView: View {
    @Environment(AppModel.self) private var model
    let root: FileNode
    let focus: FileNode

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                BreadcrumbBar(focus: focus)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                SunburstView(root: root, focus: focus)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.deniedCount > 0 && !FullDiskAccess.isGranted {
                    AccessNotice(count: model.deniedCount)
                        .padding(.bottom, 10)
                }
                // The collector lives under the chart so it never covers the list.
                CollectorBar()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
            .frame(minWidth: 460)

            ItemListView(focus: focus)
                .frame(width: 370)
                .background(.background.secondary.opacity(0.6))
                .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 0.5) }
        }
        // Attached here rather than on the window's root split view: a sheet modifier there
        // broke how the whole window draws.
        .sheet(item: Binding(get: { model.leftoverSheet }, set: { model.leftoverSheet = $0 })) { app in
            LeftoversSheet(app: app).environment(model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { model.goBack() }
                    .disabled(!model.nav.canGoBack)
                Button("Forward", systemImage: "chevron.right") { model.goForward() }
                    .disabled(!model.nav.canGoForward)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Rescan", systemImage: "arrow.clockwise") { model.rescan() }
                    .help("Scan again")
                Button("Close", systemImage: "xmark") { model.closeResults() }
                    .help("Close this scan")
            }
        }
    }
}

private struct BreadcrumbBar: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode

    var body: some View {
        let chain = focus.lineage
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(chain.enumerated()), id: \.element.id) { i, node in
                        if i > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button { model.drill(into: node) } label: {
                            HStack(spacing: 5) {
                                NodeIcon(node: node, size: 16)
                                Text(node.name).lineLimit(1)
                            }
                            .font(.system(size: 12.5, weight: node === focus ? .semibold : .regular))
                            .foregroundStyle(node === focus ? .primary : .secondary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Capsule())
                            .transaction { $0.animation = nil }
                        }
                        .buttonStyle(PressableStyle())
                        .id(node.id)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
            }
            .glassEffect(.regular, in: .capsule)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: focus.id) { _, id in
                withAnimation(.spring(duration: 0.4, bounce: 0)) { proxy.scrollTo(id, anchor: .trailing) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccessNotice: View {
    let count: Int
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text("\(Format.count(count)) protected items couldn't be read, so some space shows as hidden.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Allow Access") { AppModel.openFullDiskAccessSettings() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}
