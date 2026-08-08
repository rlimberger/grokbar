import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasActiveOutage {
                outageBanner
            }
            content
        }
        .padding(12)
        .frame(width: 220)
    }

    @ViewBuilder
    private var outageBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("xAI status issue")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if let headline = model.serviceStatus?.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.serviceStatus {
                ForEach(status.activeIncidents.prefix(3)) { incident in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let service = incident.service {
                            Text(service)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(incident.status.capitalized)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Button("Open status.x.ai") {
                model.openStatusPage()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .focusEffectDisabled()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loaded(let snap):
            loadedContent(snap)

        case .unavailable(let title, let hint):
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                quitButton
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.hasActiveOutage {
                    Text("xAI is reporting a service issue — this may be global.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Will retry automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                quitButton
            }

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
            quitButton
        }
    }

    private var quitButton: some View {
        Button("Quit") {
            model.quit()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.callout)
        .focusEffectDisabled()
        .keyboardShortcut("q")
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
