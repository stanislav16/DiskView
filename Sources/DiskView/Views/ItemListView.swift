import SwiftUI

struct ItemListView: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode

    private struct Row: Identifiable {
        let node: FileNode
        let hue: Double
        var id: ObjectIdentifier { node.id }
    }

    /// Hues match the chart: each child's colour comes from its midpoint around the ring.
    private func makeRows() -> [Row] {
        guard focus.size > 0 else { return focus.children.map { Row(node: $0, hue: 0) } }
        var cursor = 0.0
        return focus.children.map { c in
            let w = Double(c.size) / Double(focus.size)
            defer { cursor += w }
            return Row(node: c, hue: Palette.hue(forFraction: cursor + w / 2))
        }
    }

    var body: some View {
        let _ = model.treeVersion // rebuild after deletions
        let rows = makeRows()
        // Read hover/collector state once here and hand each row plain values, so a hover
        // change only redraws the two rows whose highlight actually changed.
        let hovered = model.hovered
        let collected = model.collected
        VStack(spacing: 0) {
            ListHeader(name: focus.name, size: focus.size,
                       items: focus.children.count, files: focus.fileCount)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        ItemRow(node: row.node, hue: row.hue, total: focus.size, size: row.node.size,
                                isHovered: hovered === row.node,
                                isCollected: collected.contains { row.node.isDescendant(of: $0) })
                            .equatable()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .padding(.bottom, 16)
            }
            // A fresh scroll view per folder starts at the top; it swaps in instantly
            // (no fade) because building rows mid-animation was the main cost of a zoom.
            .id(focus.id)
            .transaction { $0.animation = nil }
        }
    }

}

private struct ListHeader: View {
    let name: String
    let size: Int64
    let items: Int
    let files: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(1)
                Text("\(Format.count(items)) item\(items == 1 ? "" : "s") · \(Format.count(files)) files")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.bytes(size))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .transaction { $0.animation = nil }
    }
}

/// A rounded bar of `fraction` width. A Shape is laid out for free, unlike a GeometryReader per row.
private struct BarShape: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        let w = max(rect.height, rect.width * min(1, max(0, fraction)))
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                    cornerRadius: rect.height / 2)
    }
}

private struct ItemRow: View, Equatable {
    @Environment(AppModel.self) private var model
    let node: FileNode
    let hue: Double
    let total: Int64
    let size: Int64
    let isHovered: Bool
    let isCollected: Bool

    nonisolated static func == (a: ItemRow, b: ItemRow) -> Bool {
        a.node === b.node && a.hue == b.hue && a.total == b.total && a.size == b.size
            && a.isHovered == b.isHovered && a.isCollected == b.isCollected
    }

    var body: some View {
        let fraction = total > 0 ? Double(size) / Double(total) : 0
        let tint = Palette.color(hue: hue, depth: 0, kind: node.kind, highlighted: false, dimmed: false)

        HStack(spacing: 10) {
            NodeIcon(node: node, size: 26)
                .opacity(isCollected ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(isCollected, color: .secondary)
                    Spacer(minLength: 6)
                    Text(Format.bytes(size))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.5))
                    BarShape(fraction: fraction).fill(tint)
                }
                .frame(height: 4)
            }
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(isHovered ? 0.07 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { h in
            if h { model.hovered = node } else if model.hovered === node { model.hovered = nil }
        }
        .onTapGesture { if node.canDrillIn { model.drill(into: node) } else if node.isReal { model.quickLook(node) } }
        .onDrag { node.isReal ? NSItemProvider(object: node.url as NSURL) : NSItemProvider() }
        .contextMenu { NodeMenu(node: node) }
    }

    @ViewBuilder
    private var trailing: some View {
        ZStack {
            if node.isReal && (isHovered || isCollected) {
                Button {
                    isCollected ? model.uncollect(node) : model.collect(node)
                } label: {
                    Image(systemName: isCollected ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isCollected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(PressableStyle())
                .help(isCollected ? "Remove from Collector" : "Add to Collector")
            } else if node.canDrillIn {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 20)
    }
}
