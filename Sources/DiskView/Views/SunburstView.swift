import SwiftUI
import UniformTypeIdentifiers

/// Geometry shared by drawing and hit-testing so they can never disagree.
struct SunburstGeometry {
    static let rings = 5
    let center: CGPoint
    let outer: CGFloat
    let hole: CGFloat
    let ringWidth: CGFloat

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        outer = max(40, min(size.width, size.height) / 2 - 6)
        hole = outer * 0.30
        ringWidth = (outer - hole) / CGFloat(Self.rings)
    }
}

enum SunburstHit: Equatable {
    case center
    case node(FileNode)
}

/// The interactive chart. `focus` changes are animated by springing the
/// visible angular window and depth rather than by swapping drawings.
struct SunburstView: View {
    @Environment(AppModel.self) private var model
    let root: FileNode
    let focus: FileNode

    @State private var pressed = false

    var body: some View {
        let range = focus.absoluteRange
        GeometryReader { proxy in
            let geo = SunburstGeometry(size: proxy.size)
            ZStack {
                ZStack {
                    SunburstCanvas(root: root,
                                   viewStart: range.0, viewEnd: range.1,
                                   viewDepth: Double(focus.depth),
                                   collected: model.collected,
                                   version: model.treeVersion)
                    // Hover lives in its own light layer so the chart above isn't redrawn.
                    SunburstHoverOverlay(hovered: model.hovered,
                                         viewStart: range.0, viewEnd: range.1,
                                         viewDepth: Double(focus.depth))
                        .allowsHitTesting(false)
                }
                .scaleEffect(pressed ? 0.985 : 1)
                .animation(.spring(duration: 0.25, bounce: 0), value: pressed)

                CenterLabel(node: model.hovered ?? focus, isFocus: model.hovered == nil || model.hovered === focus,
                            canGoUp: focus.parent != nil, total: focus.size)
                    .frame(width: geo.hole * 1.8, height: geo.hole * 1.8)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let hit = Self.hitTest(p, geo: geo, focus: focus)
                    let node: FileNode? = if case .node(let n) = hit { n } else { nil }
                    if model.hovered !== node { model.hovered = node }
                case .ended:
                    model.hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        switch Self.hitTest(value.location, geo: geo, focus: focus) {
                        case .center: model.goUp()
                        case .node(let n):
                            if n.canDrillIn { model.drill(into: n) } else if n.isReal { model.quickLook(n) }
                        case nil: break
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { _ in pressed = false }
            )
            .onDrag {
                guard let n = model.hovered, n.isReal else { return NSItemProvider() }
                return NSItemProvider(object: n.url as NSURL)
            }
            .contextMenu {
                if let n = model.hovered { NodeMenu(node: n) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Resolves a point against the settled (non-animating) layout of `focus`.
    static func hitTest(_ p: CGPoint, geo: SunburstGeometry, focus: FileNode) -> SunburstHit? {
        let dx = p.x - geo.center.x, dy = p.y - geo.center.y
        let r = (dx * dx + dy * dy).squareRoot()
        if r < geo.hole { return .center }
        if r > geo.outer { return nil }
        let ring = Int(((r - geo.hole) / geo.ringWidth).rounded(.down)) + 1
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        let a = Double(angle / (2 * .pi))

        var node = focus, lo = 0.0, hi = 1.0
        for level in 1...ring {
            guard node.size > 0 else { return nil }
            var cursor = lo
            var found: FileNode?
            for c in node.children {
                let w = (hi - lo) * Double(c.size) / Double(node.size)
                if a >= cursor && a < cursor + w { found = c; hi = cursor + w; lo = cursor; break }
                cursor += w
            }
            guard let c = found, (hi - lo) * 360 >= SunburstCanvas.minDegrees else { return nil }
            node = c
            if level < ring && !c.isContainer { return nil }
        }
        return .node(node)
    }
}

/// One visible segment, as produced by `SunburstLayout.walk`.
struct SunburstSegment {
    unowned(unsafe) let node: FileNode
    let a0: Double, a1: Double          // 0...1 around the ring
    let inner: CGFloat, outer: CGFloat
    let depthInView: Int                // 0 = innermost ring
    let fade: Double                    // < 1 while a ring slides in or out
    let inCollected: Bool
    let isSmallItems: Bool              // aggregated "too thin to draw" siblings
}

/// Walks the tree for a view window and reports each segment to draw. Shared by the
/// chart and its hover overlay so they always line up.
enum SunburstLayout {
    static let minDegrees = 0.6

    private struct Item {
        unowned(unsafe) let node: FileNode   // the tree outlives every draw; skip ARC traffic
        let n0: Double, n1: Double
        let depth: Int
        let inCollected: Bool
    }

    static func walk(from start: FileNode, range: (Double, Double), startDepth: Int,
                     viewStart: Double, viewEnd: Double, viewDepth: Double,
                     geo: SunburstGeometry, collectedIDs: Set<ObjectIdentifier>,
                     visit: (SunburstSegment) -> Void) {
        let span = max(1e-9, viewEnd - viewStart)
        let rings = Double(SunburstGeometry.rings)
        let baseDepth = Int(viewDepth.rounded(.down))

        func ring(_ depth: Int) -> (inner: CGFloat, outer: CGFloat, fade: Double)? {
            let d = Double(depth) - viewDepth
            guard d > 0, d < rings + 1 else { return nil }
            let inner = geo.hole + CGFloat(max(0, d - 1)) * geo.ringWidth
            let outer = min(geo.outer, geo.hole + CGFloat(d) * geo.ringWidth)
            guard inner < geo.outer, outer - inner > 0.5 else { return nil }
            return (inner, outer, d > rings ? max(0, 1 - (d - rings)) : 1)
        }

        var stack: [Item] = [Item(node: start, n0: range.0, n1: range.1, depth: startDepth,
                                  inCollected: collectedIDs.contains(start.id))]
        stack.reserveCapacity(512)
        while let item = stack.popLast() {
            let node = item.node, n0 = item.n0, n1 = item.n1, depth = item.depth
            guard Double(depth) - viewDepth < rings + 1 else { continue }
            if n1 <= viewStart || n0 >= viewEnd { continue }

            if let r = ring(depth) {
                let a0 = max(0, (n0 - viewStart) / span), a1 = min(1, (n1 - viewStart) / span)
                if (a1 - a0) * 360 < minDegrees { continue }
                visit(SunburstSegment(node: node, a0: a0, a1: a1, inner: r.inner, outer: r.outer,
                                      depthInView: depth - baseDepth - 1, fade: r.fade,
                                      inCollected: item.inCollected, isSmallItems: false))
            }

            guard node.isContainer || node.kind == .smallItems, node.size > 0 else { continue }
            var cursor = n0
            let scale = (n1 - n0) / Double(node.size)
            var tinyStart: Double?, tinyEnd = 0.0
            node.children.withUnsafeBufferPointer { kids in
                for c in kids {
                    let w = Double(c.size) * scale
                    if w / span * 360 < minDegrees {
                        if tinyStart == nil { tinyStart = cursor }
                        tinyEnd = cursor + w
                    } else if cursor + w > viewStart && cursor < viewEnd {
                        stack.append(Item(node: c, n0: cursor, n1: cursor + w, depth: depth + 1,
                                          inCollected: item.inCollected || (!collectedIDs.isEmpty && collectedIDs.contains(c.id))))
                    }
                    cursor += w
                }
            }
            // Siblings too thin to draw individually become one quiet "smaller items" arc.
            if let ts = tinyStart, (tinyEnd - ts) / span * 360 >= minDegrees, let r = ring(depth + 1) {
                let a0 = max(0, (ts - viewStart) / span), a1 = min(1, (tinyEnd - viewStart) / span)
                if a1 > a0 {
                    visit(SunburstSegment(node: node, a0: a0, a1: a1, inner: r.inner, outer: r.outer,
                                          depthInView: depth - baseDepth, fade: r.fade,
                                          inCollected: item.inCollected, isSmallItems: true))
                }
            }
        }
    }
}

/// The chart itself. It doesn't know about hover, so moving the pointer never redraws it.
struct SunburstCanvas: View, Animatable {
    static var minDegrees: Double { SunburstLayout.minDegrees }
    nonisolated(unsafe) static var drawnSegments = 0 // benchmark counter

    let root: FileNode
    var viewStart: Double
    var viewEnd: Double
    var viewDepth: Double
    let collected: [FileNode]
    let version: Int

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(viewStart, viewEnd), viewDepth) }
        set { viewStart = newValue.first.first; viewEnd = newValue.first.second; viewDepth = newValue.second }
    }

    var body: some View {
        Canvas { ctx, size in
            let geo = SunburstGeometry(size: size)
            let collectedIDs = Set(collected.map(\.id))
            let smallColor = Color(white: 0.5, opacity: 0.38)
            SunburstLayout.walk(from: root, range: (0, 1), startDepth: 0,
                                viewStart: viewStart, viewEnd: viewEnd, viewDepth: viewDepth,
                                geo: geo, collectedIDs: collectedIDs) { s in
                let seg = SunburstCanvas.segment(geo.center, inner: s.inner, outer: s.outer, a0: s.a0, a1: s.a1)
                ctx.opacity = s.fade
                if s.isSmallItems {
                    ctx.fill(seg.path, with: .color(smallColor))
                } else {
                    let color = Palette.color(hue: Palette.hue(forFraction: (s.a0 + s.a1) / 2),
                                              depth: s.depthInView, kind: s.node.kind,
                                              highlighted: false, dimmed: false, collected: s.inCollected)
                    SunburstCanvas.drawnSegments += 1
                    ctx.fill(seg.path, with: .color(color))
                    if seg.rounded {
                        // Stroking the inset shape with a round join restores its size with soft corners.
                        ctx.stroke(seg.path, with: .color(color), style: SunburstCanvas.cornerStroke)
                    }
                    if s.inCollected && collectedIDs.contains(s.node.id) {
                        ctx.stroke(seg.path, with: .color(.primary.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }
                }
                ctx.opacity = 1
            }
        }
        // Rasterize on the GPU instead of redrawing the layer on the CPU every frame.
        .drawingGroup()
    }

    static let corner: CGFloat = 2.5
    static let cornerStroke = StrokeStyle(lineWidth: corner * 2, lineJoin: .round)

    /// An annular wedge with hairline gaps. When `rounded`, the path is inset by `corner`
    /// and must also be stroked with `cornerStroke` to get its soft corners.
    static func segment(_ c: CGPoint, inner: CGFloat, outer: CGFloat, a0: Double, a1: Double) -> (path: Path, rounded: Bool) {
        let gapPx: CGFloat = 1.5
        let corner = Self.corner
        let rIn = inner + gapPx / 2 + corner
        let rOut = outer - gapPx / 2 - corner
        let full = a1 - a0 >= 0.9999
        let start = -Double.pi / 2 + a0 * 2 * .pi
        let end = -Double.pi / 2 + a1 * 2 * .pi
        var path = Path()

        if full {
            path.addArc(center: c, radius: outer - gapPx / 2, startAngle: .zero, endAngle: .radians(2 * .pi), clockwise: false)
            path.addArc(center: c, radius: max(0, inner + gapPx / 2), startAngle: .radians(2 * .pi), endAngle: .zero, clockwise: true)
            path.closeSubpath()
            return (path, false)
        }

        // Angular inset so the gap and the corner rounding are constant in pixels.
        let mid = (rIn + rOut) / 2
        let inset = Double((gapPx / 2 + corner) / max(mid, 1))
        let s = start + inset, e = end - inset
        guard rOut > rIn, e > s else {
            // Too small to round: draw a plain wedge.
            path.addArc(center: c, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
            path.addArc(center: c, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
            path.closeSubpath()
            return (path, false)
        }
        path.addArc(center: c, radius: rOut, startAngle: .radians(s), endAngle: .radians(e), clockwise: false)
        path.addArc(center: c, radius: rIn, startAngle: .radians(e), endAngle: .radians(s), clockwise: true)
        path.closeSubpath()
        return (path, true)
    }
}

/// Brightens the hovered folder and everything inside it. Draws only that subtree.
struct SunburstHoverOverlay: View, Animatable {
    let hovered: FileNode?
    var viewStart: Double
    var viewEnd: Double
    var viewDepth: Double

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(viewStart, viewEnd), viewDepth) }
        set { viewStart = newValue.first.first; viewEnd = newValue.first.second; viewDepth = newValue.second }
    }

    var body: some View {
        Canvas { ctx, size in
            guard let hovered, hovered.parent != nil else { return }
            let geo = SunburstGeometry(size: size)
            // Draw opaque shapes into one layer, then composite it at partial opacity, so the
            // fill and its corner stroke don't double up where they overlap.
            ctx.opacity = 0.32
            ctx.blendMode = .plusLighter
            ctx.drawLayer { layer in
                SunburstLayout.walk(from: hovered, range: hovered.absoluteRange, startDepth: hovered.depth,
                                    viewStart: viewStart, viewEnd: viewEnd, viewDepth: viewDepth,
                                    geo: geo, collectedIDs: []) { s in
                    let seg = SunburstCanvas.segment(geo.center, inner: s.inner, outer: s.outer, a0: s.a0, a1: s.a1)
                    layer.fill(seg.path, with: .color(.white))
                    if seg.rounded { layer.stroke(seg.path, with: .color(.white), style: SunburstCanvas.cornerStroke) }
                }
            }
        }
    }
}

private struct CenterLabel: View {
    let node: FileNode
    let isFocus: Bool
    let canGoUp: Bool
    let total: Int64

    var body: some View {
        VStack(spacing: 4) {
            NodeIcon(node: node, size: 30)
            Text(node.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
            Text(Format.bytes(node.size))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .tracking(-0.4)
                .monospacedDigit()
            Group {
                if isFocus {
                    if canGoUp { Label("Click to go up", systemImage: "arrow.up.circle") }
                    else { Text("\(Format.count(node.fileCount)) files") }
                } else {
                    Text(Format.percent(node.size, of: total) + " of view")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        // Text swaps instantly; only the chart animates. Animating text morphs glyphs on the CPU.
        .transaction { $0.animation = nil }
    }
}
