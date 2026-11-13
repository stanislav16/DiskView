import Foundation

/// One entry in the scanned tree. Directories own their children, sorted largest first.
final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    enum Kind: UInt8 { case file, directory, package, hidden, purgeable, smallItems }

    let name: String
    var kind: Kind
    /// Allocated bytes on disk (aggregated for directories).
    var size: Int64
    /// Number of files beneath (1 for a file).
    var fileCount: Int
    var children: [FileNode]
    weak var parent: FileNode?
    /// Only the root knows its absolute path; everything else derives it.
    var rootPath: String?

    init(name: String, kind: Kind, size: Int64 = 0, parent: FileNode? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.fileCount = kind == .file ? 1 : 0
        self.children = []
        self.parent = parent
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    static func == (a: FileNode, b: FileNode) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isContainer: Bool { kind == .directory || kind == .package }
    /// Real filesystem objects can be revealed, collected and deleted; synthetic ones can't.
    var isReal: Bool { kind == .file || kind == .directory || kind == .package }
    var canDrillIn: Bool { isContainer && !children.isEmpty }
    var isApp: Bool { kind == .package && name.lowercased().hasSuffix(".app") }

    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let p = parent.path
        return p.hasSuffix("/") ? p + name : p + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: isContainer) }

    var depth: Int {
        var d = 0, n = parent
        while let x = n { d += 1; n = x.parent }
        return d
    }

    /// Chain from root down to (and including) self.
    var lineage: [FileNode] {
        var out: [FileNode] = [self]
        var n = parent
        while let x = n { out.append(x); n = x.parent }
        return out.reversed()
    }

    func isDescendant(of other: FileNode) -> Bool {
        var n: FileNode? = self
        while let x = n { if x === other { return true }; n = x.parent }
        return false
    }

    /// Absolute angular extent of this node inside the root, as fractions 0...1.
    var absoluteRange: (Double, Double) {
        guard let parent else { return (0, 1) }
        let (p0, p1) = parent.absoluteRange
        guard parent.size > 0 else { return (p0, p0) }
        var before: Int64 = 0
        for c in parent.children { if c === self { break }; before += c.size }
        let span = p1 - p0
        let a = p0 + span * Double(before) / Double(parent.size)
        return (a, a + span * Double(size) / Double(parent.size))
    }

    /// Finds a descendant by absolute path (used when items are dropped on the collector).
    func find(path target: String) -> FileNode? {
        let base = path
        if target == base { return self }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard target.hasPrefix(prefix) else { return nil }
        let rest = target.dropFirst(base.count).split(separator: "/")
        var node = self
        for comp in rest {
            guard let next = node.children.first(where: { $0.name == comp }) else { return nil }
            node = next
        }
        return node
    }

    /// Post-order: total sizes and counts, sort children descending.
    func finalize() {
        var stack: [(FileNode, Bool)] = [(self, false)]
        while let (n, visited) = stack.popLast() {
            if visited {
                guard n.isContainer || n.kind == .smallItems else { continue }
                var s: Int64 = 0, c = 0
                for ch in n.children { s += ch.size; c += ch.fileCount }
                n.size = s; n.fileCount = c
                n.children.sort { $0.size > $1.size }
            } else {
                stack.append((n, true))
                for ch in n.children where ch.isContainer { stack.append((ch, false)) }
            }
        }
    }

    /// Detach from parent and subtract our weight from every ancestor.
    func removeFromTree() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var n: FileNode? = parent
        while let x = n {
            x.size -= size
            x.fileCount -= fileCount
            x.children.sort { $0.size > $1.size }
            n = x.parent
        }
        self.parent = nil
    }
}
