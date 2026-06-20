import SwiftUI

/// Pace indicator. Prefers a real burn-rate forecast ("limit in ~3h 20m") when
/// the trend supports one, falls back to a status-derived label, and flags a
/// stale reading rather than presenting an old number as current.
struct PaceRow: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: paceIcon)
                .foregroundColor(paceColor)
            Text(paceLabel)
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var paceLabel: String {
        if appState.activeIsBalance { return "Credit balance — usage % not provided." }
        if appState.activeIsStatusOnly { return "Connected — no usage data exposed." }
        // A stale reading takes priority: don't pass off an old number as live.
        if appState.isActiveStale, let age = appState.activeSnapshotAgeString {
            return "Last updated \(age) ago — reconnecting…"
        }
        if appState.isAtSessionLimit { return limitLabel }
        // Prefer a real forecast when the trend gives us one.
        if let forecast = appState.sessionForecast { return forecast.paceLabel }
        switch appState.sessionStatus {
        case .critical: return "Heavy usage — consider pausing."
        case .warning:  return "Slightly above pace."
        case .healthy:  return "On track."
        case .unknown:  return "Waiting for first sync…"
        }
    }

    private var limitLabel: String {
        switch appState.latestSnapshot?.primaryWindow.type {
        case .monthly:  return "Monthly spend limit reached."
        case .daily:    return "Daily limit reached."
        case .weekly, .weeklyModel: return "Weekly limit reached."
        default:        return "Session blocked — awaiting reset."
        }
    }

    private var paceIcon: String {
        if appState.activeIsBalance { return "creditcard.fill" }
        if appState.activeIsStatusOnly { return "checkmark.circle.fill" }
        if appState.isActiveStale { return "clock.arrow.circlepath" }
        switch appState.sessionStatus {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning:  return "hare.fill"
        case .healthy:  return "tortoise.fill"
        case .unknown:  return "clock"
        }
    }

    private var paceColor: Color {
        appState.sessionStatus.color
    }
}
