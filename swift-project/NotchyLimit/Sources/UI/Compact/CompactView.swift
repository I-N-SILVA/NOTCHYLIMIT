import SwiftUI

/// Compact island pill.
///
/// The panel that hosts this view is taller than what's visible: the top
/// `safeAreaInsets.top` points sit inside the physical notch hardware
/// (invisible — black fill blends with the camera housing).  Content is
/// pushed to the bottom of the view with a Spacer so it appears in the
/// visible 22 pt strip just below the notch.  The result looks like the
/// notch grew a thin glowing status strip — identical to the Dynamic Island.
struct CompactView: View {
    @ObservedObject var appState: AppState
    @State private var appeared   = false
    @State private var glowPulse  = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-height black fill — top portion invisible (inside notch).
            NotchPillShape(topRadius: 0, bottomRadius: 14)
                .fill(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Visible content strip (bottom 22 pt, below the notch edge).
            HStack(spacing: 7) {
                // Which provider this pill is showing (switch via the expanded panel).
                ProviderIconView(id: appState.activeProviderId, size: 13, fallbackColor: .white.opacity(0.85))

                // Outage badge — appears only when the active provider has an incident.
                if let incident = appState.activeIncident {
                    Image(systemName: incident.level.glyph)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(incident.level.tint)
                }

                // Status dot with ambient pulse
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(glowPulse ? 0.32 : 0.12))
                        .frame(width: 12, height: 12)
                        .blur(radius: 3)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                }

                if appState.activeShowsPercentBar {
                    // Animated progress bar
                    CompactProgressBar(progress: appState.sessionPercent, color: statusColor)
                        .frame(height: 3)

                    // Percentage / reset countdown per the user's pill preference —
                    // always the reset countdown when the session is blocked.
                    Text(pillLabel)
                        .font(.system(size: 9,
                                      weight: appState.isAtSessionLimit ? .bold : .semibold,
                                      design: .monospaced))
                        .foregroundColor(.white.opacity(appState.isAtSessionLimit ? 1 : 0.88))
                        .frame(minWidth: 40, alignment: .trailing)
                } else {
                    // Balance ("$110.00") or connected-only ("Active") — no fake bar.
                    Text(appState.activeShortLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.88))
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
        }
        // Colour glow below the island echoes the current usage status.
        .shadow(color: statusColor.opacity(appeared ? 0.40 : 0), radius: 10, y: 5)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeIn(duration: 0.22)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true).delay(0.6)) {
                glowPulse = true
            }
        }
        .help(appState.sessionResetString ?? "Notchy Limit")
    }

    private var statusColor: Color { appState.sessionStatus.color }

    /// The pill's trailing text, honoring `AppState.pillContent` (#20).
    private var pillLabel: String {
        let percent = "\(Int((appState.sessionPercent * 100).rounded()))%"
        // At the limit, the reset countdown is the only useful thing to show.
        if appState.isAtSessionLimit {
            return appState.sessionResetShortString ?? "LIMIT"
        }
        switch appState.pillContent {
        case .percent:
            return percent
        case .reset:
            return appState.sessionResetShortString ?? percent
        case .auto:
            // Show the countdown once usage is high; otherwise the percentage.
            if appState.sessionStatus == .warning || appState.sessionStatus == .critical,
               let reset = appState.sessionResetShortString {
                return reset
            }
            return percent
        }
    }
}
