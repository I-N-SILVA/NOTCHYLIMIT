import SwiftUI
import AppKit

/// Horizontal row of tappable provider chips shown at the top of the expanded panel
/// when 2 or more providers are active. Tapping a chip switches `appState.activeProviderId`
/// so the cards below update to that provider's data.
struct ProviderSwitcherRow: View {
    @ObservedObject var appState: AppState

    private var activeSnaps: [ProviderId] {
        appState.enabledProviders.filter { appState.snapshots[$0] != nil }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(activeSnaps, id: \.self) { pid in
                chip(for: pid)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func chip(for pid: ProviderId) -> some View {
        let isActive = pid == appState.activeProviderId
        let snap     = appState.snapshots[pid]
        let status   = snap?.combinedStatus ?? .unknown
        let value    = snap?.shortLabel ?? "…"

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                appState.activeProviderId = pid
                appState.latestSnapshot   = appState.snapshots[pid]
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                Text(pid.displayName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Text(value)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(status.color)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isActive ? Theme.surfaceElevated : Theme.surface)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive ? Theme.accentWarm.opacity(0.45) : Theme.stroke,
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(.borderless)
        .foregroundColor(Theme.textPrimary)
        .scaleEffect(isActive ? 1.0 : 0.95)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)
        .contextMenu {
            if let url = pid.dashboardURL {
                Button("Open \(pid.displayName) dashboard") { NSWorkspace.shared.open(url) }
            }
        }
    }
}
