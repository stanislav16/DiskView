import SwiftUI

/// Review an app's leftovers and choose which to add to the Collector.
/// Nothing is removed here; the Collector's Move to Trash is still the only delete.
struct LeftoversSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: FileNode

    @State private var selected: Set<UUID> = []
    @State private var didPreselect = false

    private var report: LeftoverReport? {
        if case .done(let r)? = model.leftovers[app.id] { return r }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 620, height: 520)
        .onChange(of: report?.items.count, initial: true) { _, _ in preselect() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            NodeIcon(node: app, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Leftovers from \(report?.appName ?? app.name.replacingOccurrences(of: ".app", with: ""))")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                Text("Files the app keeps in your Library. They stay behind when you delete only the app.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if let report {
            if let note = report.note {
                message(icon: "hand.raised", note)
            } else if report.items.isEmpty {
                message(icon: "checkmark.circle", "No leftovers found. This app doesn't keep data in the usual places.")
            } else {
                LeftoverReviewList(items: report.items, selected: $selected)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking through your Library…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func message(icon: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
    }

    private var chosen: [Leftover] {
        (report?.items ?? []).filter { selected.contains($0.id) && !model.isCollected($0.node) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let total = chosen.reduce(Int64(0)) { $0 + $1.node.size }
            VStack(alignment: .leading, spacing: 1) {
                Text(chosen.isEmpty ? "Nothing selected" : "\(chosen.count) selected · \(Format.bytes(total))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text("Added items go to the Collector. Nothing is deleted yet.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add to Collector") {
                model.collectLeftovers(chosen)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Only items named after the app's identifier start selected; anything less certain is opt-in.
    private func preselect() {
        guard !didPreselect, let report else { return }
        didPreselect = true
        selected = Set(report.items.filter { $0.confidence == .certain && $0.canDelete }.map(\.id))
    }
}

/// Leftovers grouped by how sure we are, with a checkbox each. Shared by the review sheet
/// and the window that appears after an app is dragged to the Trash.
struct LeftoverReviewList: View {
    let items: [Leftover]
    @Binding var selected: Set<UUID>

    var body: some View {
        List {
            ForEach([Leftover.Confidence.certain, .likely, .shared], id: \.self) { level in
                let group = items.filter { $0.confidence == level }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { item in LeftoverRow(item: item, selected: $selected) }
                    } header: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(level.title).font(.system(size: 12, weight: .semibold))
                            Text(level.explanation).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct LeftoverRow: View {
    @Environment(AppModel.self) private var model
    let item: Leftover
    @Binding var selected: Set<UUID>

    var body: some View {
        let inCollector = model.isCollected(item.node)
        let isOn = Binding(
            get: { inCollector || selected.contains(item.id) },
            set: { on in if on { selected.insert(item.id) } else { selected.remove(item.id) } }
        )
        HStack(spacing: 10) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(inCollector || !item.canDelete)
            NodeIcon(node: item.node, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.node.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(item.location) · \(item.displayPath)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !item.canDelete {
                Label("Needs admin", systemImage: "lock.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("Removing this needs administrator rights. Reveal it in Finder to remove it there.")
            } else if inCollector {
                Text("In Collector").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(Format.bytes(item.node.size))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if !inCollector && item.canDelete { isOn.wrappedValue.toggle() } }
    }
}
