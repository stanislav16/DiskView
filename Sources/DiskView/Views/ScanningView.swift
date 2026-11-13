import SwiftUI

struct ScanningView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Determinate when scanning a whole disk (we know how much is used), otherwise indeterminate.
    private var fraction: Double? {
        guard let vol = model.target?.volume else { return nil }
        let expected = Double(max(1, vol.used - vol.purgeable))
        return min(0.99, Double(model.scannedBytes) / expected)
    }

    var body: some View {
        VStack(spacing: 34) {
            TimelineView(.animation(paused: reduceMotion)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ScanRing(fraction: fraction, phase: reduceMotion ? 0 : t)
            }
            .frame(width: 240, height: 240)
            .overlay {
                VStack(spacing: 2) {
                    Text(Format.bytes(model.scannedBytes))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .tracking(-0.6)
                        .monospacedDigit()
                    Text("\(Format.count(model.scannedFiles)) files")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(spacing: 8) {
                Text("Scanning \(model.target?.name ?? "")")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
                Text(model.scanningPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 460)
            }

            Button("Stop Scan", systemImage: "stop.fill") { model.cancelScan() }
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .padding(40)
    }
}

private struct ScanRing: View {
    let fraction: Double?
    let phase: Double

    var body: some View {
        let colors = (0...6).map { Color(hue: Palette.hue(forFraction: Double($0) / 6), saturation: 0.6, brightness: 0.95) }
        ZStack {
            Circle().stroke(.quaternary.opacity(0.6), lineWidth: 16)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.01, fraction))
                    .stroke(AngularGradient(colors: colors, center: .center),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.5, bounce: 0), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(AngularGradient(colors: colors, center: .center),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.radians(phase * 2.4))
            }
            // A soft sheen that orbits the ring so progress always feels alive.
            Circle()
                .trim(from: 0, to: 0.08)
                .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .blur(radius: 3)
                .rotationEffect(.radians(phase * 1.3))
                .blendMode(.plusLighter)
        }
    }
}
