import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("See what's taking up space")
                        .font(.system(size: 34, weight: .bold))
                        .tracking(-0.8)
                    Text("Pick a disk to scan. You'll get a map of every folder, sized by how much space it uses.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360, maximum: 460), spacing: 18)],
                          alignment: .leading, spacing: 18) {
                    ForEach(model.volumes) { VolumeCard(volume: $0) }
                    dropCard
                }
            }
            .padding(36)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.scan(folder: url)
            return true
        } isTargeted: { t in withAnimation(.spring(duration: 0.25, bounce: 0)) { dropTargeted = t } }
    }

    private var dropCard: some View {
        Button { model.pickFolder() } label: {
            VStack(spacing: 12) {
                Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "folder.badge.plus")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
                Text(dropTargeted ? "Drop to scan" : "Scan a folder")
                    .font(.system(size: 15, weight: .semibold))
                Text("Choose one, or drag it here")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 210)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(dropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            }
            .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .scaleEffect(dropTargeted ? 1.02 : 1)
        }
        .buttonStyle(PressableStyle())
    }
}

struct VolumeCard: View {
    @Environment(AppModel.self) private var model
    let volume: Volume
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                CapacityDonut(volume: volume)
                    .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 6) {
                    Text(volume.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text("\(Format.bytes(volume.used)) of \(Format.bytes(volume.total)) used")
                        .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.85)
                    VStack(alignment: .leading, spacing: 3) {
                        legend(.accentColor, "Used", volume.used - volume.purgeable)
                        if volume.purgeable > 0 { legend(.accentColor.opacity(0.4), "Purgeable", volume.purgeable) }
                        legend(Color.secondary.opacity(0.25), "Free", volume.available)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            Button { model.scan(volume: volume) } label: {
                Label("Scan", systemImage: "viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.primary.opacity(0.06))
        }
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 18 : 8, y: hovering ? 8 : 3)
        .scaleEffect(hovering ? 1.01 : 1)
        .onHover { h in withAnimation(.spring(duration: 0.3, bounce: 0)) { hovering = h } }
    }

    private func legend(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Text(Format.bytes(bytes)).monospacedDigit().lineLimit(1).fixedSize()
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: 200)
    }
}

struct CapacityDonut: View {
    let volume: Volume
    @State private var appeared = false

    var body: some View {
        let total = Double(max(1, volume.total))
        let used = Double(volume.used - volume.purgeable) / total
        let purge = Double(volume.purgeable) / total
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 12)
            Circle()
                .trim(from: 0, to: appeared ? used + purge : 0)
                .stroke(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: appeared ? used : 0)
                .stroke(AngularGradient(colors: [.accentColor.opacity(0.75), .accentColor], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(used, 0.01))),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(volume.usedFraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                Text("used").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0).delay(0.05)) { appeared = true } }
    }
}

/// Instant feedback on press, released with a critically damped spring.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: configuration.isPressed ? 0.1 : 0.3, bounce: 0), value: configuration.isPressed)
    }
}
