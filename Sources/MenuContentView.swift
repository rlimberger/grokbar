import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(12)
        .frame(width: 220)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loaded(let snap):
            loadedContent(snap)

        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadedContent(_ snap: UsageSnapshot) -> some View {
        // Depend on clock tick so countdown stays live while the panel is open.
        let _ = model.clockTick

        return VStack(alignment: .leading, spacing: 10) {
            // Plan + total used
            HStack(alignment: .firstTextBaseline) {
                Text(snap.subscriptionLabel)
                    .font(.headline)
                Spacer(minLength: 8)
                Text("\(Int(snap.usedPercent.rounded()))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Weekly reset
            VStack(alignment: .leading, spacing: 4) {
                if let end = snap.periodEnd {
                    labeledRow("Resets", Formatters.resetDateTime.string(from: end))
                }
                labeledRow("In", formatCountdown(snap.resetsIn) ?? "—")
            }

            // Usage split by product
            if snap.productUsage.isEmpty {
                Text("No product breakdown")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(snap.productUsage) { item in
                        HStack(spacing: 8) {
                            Text(item.displayName)
                                .font(.callout)
                            Spacer(minLength: 4)
                            Text("\(Int(item.usagePercent.rounded()))%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            Button("Quit") {
                model.quit()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
            .focusEffectDisabled()
            .keyboardShortcut("q")
        }
    }

    private func labeledRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout)
                .multilineTextAlignment(.trailing)
        }
    }
}
