import AppKit
import SwiftUI

/// Developer aid: `DiskView --bench <path>` scans, then times chart frames the way a zoom draws them.
@MainActor
enum Bench {
    static func run(path: String) {
        let scanner = DiskScanner()
        let root = scanner.scan(path: path, displayName: path)
        guard let target = root.children.first(where: { $0.canDrillIn }) else { print("nothing to zoom"); return }
        let (t0, t1) = target.absoluteRange
        let frames = 40
        func time(_ label: String, hovered: FileNode?) {
            var total = 0.0, worst = 0.0
            SunburstCanvas.drawnSegments = 0
            for i in 0...frames {
                let p = Double(i) / Double(frames)
                let view = SunburstCanvas(root: root,
                                          viewStart: t0 * p, viewEnd: 1 + (t1 - 1) * p,
                                          viewDepth: p, collected: [], version: 0)
                    .frame(width: 900, height: 900)
                let r = ImageRenderer(content: view)
                r.scale = 2
                let s = CFAbsoluteTimeGetCurrent()
                _ = r.cgImage
                let ms = (CFAbsoluteTimeGetCurrent() - s) * 1000
                total += ms; worst = max(worst, ms)
            }
            print(String(format: "%@: avg %.1f ms/frame, worst %.1f ms, %d segments/frame (budget at 60fps: 16.7 ms)",
                         label, total / Double(frames + 1), worst, SunburstCanvas.drawnSegments / (frames + 1)))
        }
        time("zoom", hovered: nil)
    }
}
