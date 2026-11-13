import AppKit
import UniformTypeIdentifiers
import SwiftUI

enum Format {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ n: Int64) -> String { formatter.string(fromByteCount: max(0, n)) }

    static func count(_ n: Int) -> String { n.formatted(.number) }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "0%" }
        let p = Double(part) / Double(whole)
        return p < 0.001 ? "<0.1%" : p.formatted(.percent.precision(.fractionLength(p < 0.1 ? 1 : 0)))
    }

    static func duration(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.1fs", t) : "\(Int(t) / 60)m \(Int(t) % 60)s"
    }
}

enum Palette {
    /// Hue comes from where the segment sits around the ring; depth fades it outward.
    static func color(hue: Double, depth: Int, kind: FileNode.Kind, highlighted: Bool, dimmed: Bool,
                      collected: Bool = false) -> Color {
        var h = hue, s: Double, b: Double
        switch kind {
        case .hidden: h = 0; s = 0; b = 0.55
        case .purgeable: h = 0; s = 0; b = 0.72
        case .smallItems: h = 0; s = 0; b = 0.62
        case .file:
            s = max(0.18, 0.42 - Double(depth) * 0.04); b = min(0.97, 0.86 + Double(depth) * 0.015)
        default:
            s = max(0.30, 0.72 - Double(depth) * 0.07); b = min(0.98, 0.84 + Double(depth) * 0.025)
        }
        if highlighted { b = min(1, b + 0.1); s = max(0, s - 0.08) }
        let c = Color(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b)
        if collected { return c.opacity(0.28) }
        return dimmed ? c.opacity(0.6) : c
    }

    static func hue(forFraction f: Double) -> Double {
        // Start at a warm coral and rotate through the wheel; skip murky greens slightly.
        (0.98 + f * 0.85).truncatingRemainder(dividingBy: 1)
    }
}

/// File icons, cached by path. Looking an icon up hits the disk, so it never happens on the
/// main thread: rows show a generic folder/document icon at once and swap in the real one.
enum IconCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.countLimit = 4000; return c
    }()
    private static let folder = flatten(NSWorkspace.shared.icon(for: .folder))
    private static let document = flatten(NSWorkspace.shared.icon(for: .data))

    /// System icons carry many representations; picking and scaling one on every draw shows up
    /// in profiles. Render once to a single 64 px bitmap (32 pt @2x), which covers every use here.
    private static func flatten(_ image: NSImage) -> NSImage {
        let px = 64
        var rect = NSRect(x: 0, y: 0, width: px, height: px)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil,
                                     hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: 2))]),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
        guard let flat = ctx.makeImage() else { return image }
        return NSImage(cgImage: flat, size: NSSize(width: px / 2, height: px / 2))
    }
    private static let queue = DispatchQueue(label: "DiskView.icons", qos: .userInitiated, attributes: .concurrent)

    static func cached(_ path: String) -> NSImage? { cache.object(forKey: path as NSString) }

    static func placeholder(for node: FileNode) -> NSImage {
        node.kind == .file ? document : folder
    }

    static func load(_ path: String) async -> NSImage {
        if let img = cached(path) { return img }
        return await withCheckedContinuation { cont in
            queue.async {
                let img = flatten(NSWorkspace.shared.icon(forFile: path))
                cache.setObject(img, forKey: path as NSString)
                cont.resume(returning: img)
            }
        }
    }
}

struct NodeIcon: View {
    let node: FileNode
    var size: CGFloat = 20
    @State private var loaded: NSImage?

    var body: some View {
        if node.isReal {
            let path = node.path
            Image(nsImage: loaded ?? IconCache.cached(path) ?? IconCache.placeholder(for: node))
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
                .task(id: path) {
                    guard IconCache.cached(path) == nil else { return }
                    let img = await IconCache.load(path)
                    if !Task.isCancelled { loaded = img }
                }
        } else {
            Image(systemName: node.kind == .hidden ? "eye.slash" : node.kind == .purgeable ? "sparkles" : "square.grid.3x3")
                .font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

extension FileNode {
    var kindDescription: String {
        switch kind {
        case .file: return "File"
        case .directory: return "Folder"
        case .package: return "Package"
        case .hidden: return "Space macOS uses that isn't visible as files: system volumes, snapshots, VM"
        case .purgeable: return "Caches and data macOS can free automatically when needed"
        case .smallItems: return "Many small items"
        }
    }
}
