import AppKit

/// Developer aid: `DISKVIEW_SNAPSHOT=<dir> DISKVIEW_SNAPSHOT_PATH=<folder> DiskView`
/// walks through the app's screens and saves a PNG of the window at each step.
@MainActor
enum SnapshotDriver {
    static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["DISKVIEW_STRESS"] { runStress(model: model, path: path); return }
        guard let dir = env["DISKVIEW_SNAPSHOT"] else { return }
        let scanPath = env["DISKVIEW_SNAPSHOT_PATH"] ?? "/Applications"
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        Task { @MainActor in
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            @MainActor func shot(_ name: String) {
                guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let view = win.contentView?.superview ?? win.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "\(name).png"))
            }
            // DISKVIEW_SNAPSHOT_APP=<name.app>: collect that app and capture its leftovers sheet.
            if let appName = ProcessInfo.processInfo.environment["DISKVIEW_SNAPSHOT_APP"] {
                await wait(1)
                model.scan(folder: URL(fileURLWithPath: scanPath))
                while model.phase != .result { await wait(0.2) }
                guard let app = model.root?.children.first(where: { $0.name == appName }) else { NSApp.terminate(nil); return }
                await wait(1.0); shot("L0-before-collect")
                model.collect(app)
                while case .searching? = model.leftovers[app.id] { await wait(0.2) }
                await wait(0.8); shot("L1-collector-badge")
                let pending = model.pendingLeftovers(for: app)
                print("badge: \(pending.count) pending, \(Format.bytes(pending.reduce(0) { $0 + $1.node.size }))")
                fflush(stdout)
                model.findLeftovers(for: app, show: true)
                await wait(1.2)
                for (i, w) in NSApp.windows.enumerated() where w.isVisible && w.isSheet {
                    if let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "L2-sheet-\(i).png"))
                    }
                }
                model.leftoverSheet = nil // macOS won't quit while a sheet is open
                await wait(0.6)
                NSApp.terminate(nil)
                return
            }
            await wait(1.5); shot("1-welcome")
            model.scan(folder: URL(fileURLWithPath: scanPath))
            await wait(0.35); shot("2-scanning")
            while model.phase != .result { await wait(0.2) }
            await wait(1.0); shot("3-result")
            if let big = model.focus?.children.first(where: { $0.canDrillIn }) {
                model.hovered = big; await wait(0.3); shot("4-hover")
                model.drill(into: big); await wait(0.25); shot("5-zooming")
                await wait(1.0); shot("6-zoomed")
                for c in big.children.prefix(3) where c.isReal { model.collect(c) }
                await wait(0.8); shot("7-collector")
            }
            NSApp.terminate(nil)
        }
    }

    /// `DISKVIEW_STRESS=<path>`: scan, then zoom in/out, hover and scroll for a while, and report
    /// how often the main thread missed a frame. Run `sample` alongside to see why.
    static func runStress(model: AppModel, path: String) {
        Task { @MainActor in
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            await wait(1)
            model.scan(folder: URL(fileURLWithPath: path))
            while model.phase != .result { await wait(0.2) }
            await wait(1)
            print("STRESS-START"); fflush(stdout)

            // Frame-gap monitor: a 120 Hz timer on the main run loop; long gaps = dropped frames.
            var last = CACurrentMediaTime(), gaps: [Double] = []
            final class Box { var action = "idle" }
            let state = Box()
            var stallsBy: [String: (count: Int, worstMs: Double)] = [:]
            let monitor = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                let now = CACurrentMediaTime(); let gap = now - last
                gaps.append(gap); last = now
                if gap > 0.033 {
                    let e = stallsBy[state.action] ?? (0, 0)
                    stallsBy[state.action] = (e.count + 1, max(e.worstMs, gap * 1000))
                }
            }
            RunLoop.main.add(monitor, forMode: .common)

            @MainActor func scrollViews(_ v: NSView) -> [NSScrollView] {
                (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews)
            }
            let root = model.root!
            let targets = root.children.filter(\.canDrillIn).prefix(4)
            let end = Date().addingTimeInterval(8)
            var phase = 0
            while Date() < end {
                let t = targets[targets.index(targets.startIndex, offsetBy: phase % targets.count)]
                state.action = "zoom in"; model.drill(into: t); await wait(0.6)
                // hover a few things while the zoom runs
                state.action = "hover"
                for c in t.children.prefix(6) { model.hovered = c; await wait(0.05) }
                // scroll the item list (the widest-content vertical scroll view on the right)
                if let content = NSApp.windows.first?.contentView,
                   let list = scrollViews(content).filter({ $0.frame.width > 250 && $0.frame.width < 450 }).first {
                    state.action = "scroll"
                    for _ in 0..<20 {
                        let clip = list.contentView
                        var o = clip.bounds.origin; o.y += 40
                        clip.scroll(to: o); list.reflectScrolledClipView(clip)
                        await wait(1.0 / 60)
                    }
                }
                state.action = "zoom out"; model.goUp(); await wait(0.2)
                await wait(0.4)
                phase += 1
            }
            monitor.invalidate()
            let frame = 1.0 / 60
            let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / frame).rounded(.down)) - 1) }
            let worst = (gaps.max() ?? 0) * 1000
            let long = gaps.filter { $0 > 0.05 }.count
            print(String(format: "STRESS-RESULT ticks=%d dropped≈%d worst=%.0fms hitches>50ms=%d",
                         gaps.count, dropped, worst, long))
            for (k, v) in stallsBy.sorted(by: { $0.value.count > $1.value.count }) {
                print(String(format: "  stalls after %@: %d (worst %.0f ms)", k, v.count, v.worstMs))
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }
}
