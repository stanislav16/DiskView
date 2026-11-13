import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private var folders: [(String, String, URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            ("Home", "house", home),
            ("Desktop", "menubar.dock.rectangle", home.appending(path: "Desktop")),
            ("Documents", "doc", home.appending(path: "Documents")),
            ("Downloads", "arrow.down.circle", home.appending(path: "Downloads")),
            ("Applications", "square.grid.2x2", URL(fileURLWithPath: "/Applications")),
            ("Library", "building.columns", home.appending(path: "Library")),
        ]
    }

    var body: some View {
        List {
            Section("Disks") {
                ForEach(model.volumes) { vol in
                    Button { model.scan(volume: vol) } label: { VolumeRow(volume: vol, active: isActive(vol.url)) }
                        .buttonStyle(.plain)
                }
            }
            Section("Folders") {
                ForEach(folders, id: \.0) { name, icon, url in
                    Button { model.scan(folder: url) } label: {
                        Label(name, systemImage: icon)
                            .fontWeight(isActive(url) ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { model.pickFolder() } label: {
                    Label("Choose Folder…", systemImage: "plus.circle")
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !FullDiskAccess.isGranted {
                Button { AppModel.openFullDiskAccessSettings() } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield").font(.system(size: 15, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow Full Disk Access").font(.system(size: 12, weight: .semibold))
                            Text("Lets DiskView see protected folders like Mail and Messages.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                .padding(10)
            }
        }
        .onAppear { model.refreshVolumes() }
    }

    private func isActive(_ url: URL) -> Bool {
        model.phase != .welcome && model.target?.url.standardizedFileURL == url.standardizedFileURL
    }
}

private struct VolumeRow: View {
    let volume: Volume
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: volume.isRoot ? "internaldrive" : volume.isInternal ? "internaldrive" : "externaldrive")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(volume.name).fontWeight(active ? .semibold : .regular).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.bytes(volume.available) + " free")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                CapacityBar(volume: volume).frame(height: 4)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct CapacityBar: View {
    let volume: Volume
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let total = Double(max(volume.total, 1))
            let usedW = w * Double(volume.used - volume.purgeable) / total
            let purgeW = w * Double(volume.purgeable) / total
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                HStack(spacing: 0) {
                    Rectangle().fill(volume.usedFraction > 0.9 ? Color.orange.gradient : Color.accentColor.gradient)
                        .frame(width: max(0, usedW))
                    Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: max(0, purgeW))
                }
                .clipShape(Capsule())
            }
        }
    }
}

enum FullDiskAccess {
    nonisolated(unsafe) private static var cached = false
    nonisolated(unsafe) private static var checkedAt = Date.distantPast

    /// Reading a TCC-protected folder is the standard way to probe for the grant.
    /// Views ask often, so the answer is reused for a few seconds.
    static var isGranted: Bool {
        if Date().timeIntervalSince(checkedAt) > 5 {
            let probe = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari").path
            cached = (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
            checkedAt = Date()
        }
        return cached
    }
}
