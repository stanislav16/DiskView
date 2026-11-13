import AppKit
import SwiftUI

/// Data an app leaves in the Library folders after the app itself is deleted.
struct Leftover: Identifiable {
    enum Confidence: Int, Comparable {
        /// Named after the app's bundle identifier: belongs to this app.
        case certain
        /// Named exactly like the app.
        case likely
        /// The developer's folder; other apps from the same developer may use it too.
        case shared

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .certain: return "Belongs to this app"
            case .likely: return "Probably belongs to this app"
            case .shared: return "May be shared with other apps"
            }
        }

        var explanation: String {
            switch self {
            case .certain: return "Named after the app's identifier."
            case .likely: return "Named like the app. Check before removing."
            case .shared: return "The developer's folder. Other apps from them may still need it."
            }
        }
    }

    let id = UUID()
    let path: String
    let location: String
    let confidence: Confidence
    /// False when removing it needs administrator rights.
    let canDelete: Bool
    var node: FileNode

    var url: URL { URL(fileURLWithPath: path) }
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct LeftoverReport {
    let appName: String
    let items: [Leftover]
    /// Set when the search was skipped on purpose, e.g. for Apple's own apps.
    let note: String?
}

enum LeftoverSearch {
    case searching
    case done(LeftoverReport)
}

/// Finds an app's leftovers by looking only in the well-known Library folders macOS apps use.
/// Matching is deliberately conservative: anything uncertain is reported, never preselected.
enum LeftoverFinder {
    struct Candidate {
        let path: String
        let location: String
        let confidence: Leftover.Confidence
        let isDirectory: Bool
    }

    private struct Location {
        let label: String
        let path: String
        /// Developer folders like "Google" only make sense where apps create named folders.
        var allowsVendorFolder = false
        var isGroupContainers = false
    }

    private static var locations: [Location] {
        let lib = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library").path
        return [
            Location(label: "Application Support", path: lib + "/Application Support", allowsVendorFolder: true),
            Location(label: "Caches", path: lib + "/Caches", allowsVendorFolder: true),
            Location(label: "Preferences", path: lib + "/Preferences"),
            Location(label: "Preferences", path: lib + "/Preferences/ByHost"),
            Location(label: "Containers", path: lib + "/Containers"),
            Location(label: "Group Containers", path: lib + "/Group Containers", isGroupContainers: true),
            Location(label: "Saved State", path: lib + "/Saved Application State"),
            Location(label: "Logs", path: lib + "/Logs", allowsVendorFolder: true),
            Location(label: "Cookies", path: lib + "/Cookies"),
            Location(label: "HTTP Storage", path: lib + "/HTTPStorages"),
            Location(label: "Web Data", path: lib + "/WebKit"),
            Location(label: "Launch Agents", path: lib + "/LaunchAgents"),
            Location(label: "App Scripts", path: lib + "/Application Scripts"),
            Location(label: "Application Support (all users)", path: "/Library/Application Support", allowsVendorFolder: true),
            Location(label: "Caches (all users)", path: "/Library/Caches"),
            Location(label: "Preferences (all users)", path: "/Library/Preferences"),
            Location(label: "Launch Agents (all users)", path: "/Library/LaunchAgents"),
            Location(label: "Launch Daemons", path: "/Library/LaunchDaemons"),
            Location(label: "Helper Tools", path: "/Library/PrivilegedHelperTools"),
        ]
    }

    /// Vendor names too generic to identify one developer's folder.
    private static let genericVendors: Set<String> = ["apple", "app", "apps", "company", "example", "github", "io", "org", "net", "com", "dev", "software", "inc", "mac", "macos"]

    private static let strippedSuffixes = [".plist", ".savedstate", ".binarycookies", ".lockfile"]

    static func appInfo(_ appURL: URL) -> (bundleID: String, name: String)? {
        guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        return (id, name)
    }

    /// Lowercased, letters and digits only: "Riot Games" and "riotgames" compare equal.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func find(appURL: URL) -> (name: String, candidates: [Candidate], note: String?) {
        let fallback = appURL.deletingPathExtension().lastPathComponent
        guard let (bundleID, name) = appInfo(appURL) else {
            return (fallback, [], "This app has no identifier, so its leftovers can't be told apart safely.")
        }
        let bid = bundleID.lowercased()
        if bid.hasPrefix("com.apple.") {
            return (fallback, [], "Apple's own apps keep data that macOS itself relies on, so DiskView doesn't touch it.")
        }

        let appKeys = Set([normalize(name), normalize(fallback)].filter { $0.count >= 4 })
        let parts = bid.split(separator: ".").map(String.init)
        let vendor = parts.count >= 3 ? normalize(parts[1]) : ""
        let product = parts.count >= 3 ? normalize(parts[parts.count - 1]) : ""
        let fm = FileManager.default
        var out: [Candidate] = []
        var seen = Set<String>()

        func add(_ path: String, _ loc: Location, _ c: Leftover.Confidence) {
            guard !seen.contains(path), !path.hasPrefix(appURL.path + "/") else { return }
            seen.insert(path)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)
            out.append(Candidate(path: path, location: loc.label, confidence: c, isDirectory: isDir.boolValue))
        }

        for loc in locations {
            guard let names = try? fm.contentsOfDirectory(atPath: loc.path) else { continue }
            for entry in names {
                var base = entry.lowercased()
                for suffix in strippedSuffixes where base.hasSuffix(suffix) { base.removeLast(suffix.count) }
                let path = loc.path + "/" + entry

                // Named after the bundle identifier (or a helper/extension of it).
                if base == bid || base.hasPrefix(bid + ".") {
                    add(path, loc, .certain); continue
                }
                // Group containers: "TEAMID.com.vendor.app" or "group.com.vendor.app".
                if loc.isGroupContainers && (base.hasSuffix("." + bid) || base == "group." + bid) {
                    add(path, loc, .certain); continue
                }
                let norm = normalize(entry.replacingOccurrences(of: ".plist", with: ""))
                // Named exactly like the app.
                if appKeys.contains(norm) {
                    add(path, loc, .likely); continue
                }
                // The developer's folder, e.g. "Google" for com.google.Chrome.
                if loc.allowsVendorFolder, vendor.count >= 4, !genericVendors.contains(vendor), norm == vendor {
                    // Prefer the app's own subfolder inside it, e.g. Google/Chrome.
                    let inner = (try? fm.contentsOfDirectory(atPath: path)) ?? []
                    let match = inner.first { let n = normalize($0); return appKeys.contains(n) || (product.count >= 4 && n == product) }
                    if let match {
                        add(path + "/" + match, loc, .likely)
                    } else {
                        add(path, loc, .shared)
                    }
                }
            }
        }
        // Titles use the name shown in Finder; the bundle's own name is only used for matching.
        return (fallback, out.sorted { ($0.confidence, $0.path) < ($1.confidence, $1.path) }, nil)
    }

    /// Size of a candidate as a standalone tree (it may lie outside the scanned folder).
    static func measure(_ c: Candidate) -> FileNode {
        let name = (c.path as NSString).lastPathComponent
        if c.isDirectory {
            let node = DiskScanner().scan(path: c.path, displayName: name)
            node.kind = name.lowercased().hasSuffix(".app") ? .package : .directory
            return node
        }
        let size = (try? URL(fileURLWithPath: c.path)
            .resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        let node = FileNode(name: name, kind: .file, size: Int64(size))
        node.rootPath = c.path
        return node
    }
}

extension AppModel {
    /// Searches for an app's leftovers in the background. With `show`, opens the review sheet.
    func findLeftovers(for app: FileNode, show: Bool) {
        guard app.isApp else { return }
        if show { leftoverSheet = app }
        if let existing = leftovers[app.id], case .done = existing { return }
        if case .searching? = leftovers[app.id] { return }
        leftovers[app.id] = .searching
        let appURL = app.url
        Task.detached(priority: .userInitiated) {
            let result = LeftoverFinder.find(appURL: appURL)
            let measured = result.candidates.map { ($0, LeftoverFinder.measure($0)) }
            await MainActor.run {
                let items = measured.map { c, standalone in
                    // Prefer the node from the scan so the chart and collector stay in sync.
                    Leftover(path: c.path, location: c.location, confidence: c.confidence,
                             canDelete: FileManager.default.isDeletableFile(atPath: c.path),
                             node: self.root?.find(path: c.path) ?? standalone)
                }
                self.leftovers[app.id] = .done(LeftoverReport(appName: result.name, items: items, note: result.note))
            }
        }
    }

    /// Leftovers of `app` that are found, removable, preselected-worthy and not yet collected.
    func pendingLeftovers(for app: FileNode) -> [Leftover] {
        guard case .done(let report)? = leftovers[app.id] else { return [] }
        return report.items.filter { $0.confidence == .certain && $0.canDelete && !isCollected($0.node) && $0.node.size > 0 }
    }

    func collectLeftovers(_ items: [Leftover]) {
        for item in items where item.canDelete { collect(item.node) }
    }
}
