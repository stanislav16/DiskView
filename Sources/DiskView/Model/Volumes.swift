import AppKit

struct Volume: Identifiable, Hashable {
    let url: URL
    let name: String
    let total: Int64
    /// Truly free right now.
    let available: Int64
    /// Free once macOS purges caches and other reclaimable data.
    let availableImportant: Int64
    let isInternal: Bool
    let isRoot: Bool

    var id: URL { url }
    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, availableImportant - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsBrowsable ?? true,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let avail = Int64(v.volumeAvailableCapacity ?? 0)
            return Volume(
                url: url,
                name: v.volumeLocalizedName ?? url.lastPathComponent,
                total: Int64(total),
                available: avail,
                availableImportant: max(avail, v.volumeAvailableCapacityForImportantUsage ?? avail),
                isInternal: v.volumeIsInternal ?? false,
                isRoot: url.path == "/"
            )
        }
        .sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }
}
