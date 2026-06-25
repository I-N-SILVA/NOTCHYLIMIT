import SwiftUI

struct ActionsRow: View {
    @ObservedObject var appState: AppState
    let controller: NotchWindowController

    var body: some View {
        HStack(spacing: 8) {
            actionButton(label: "Refresh", icon: "arrow.clockwise") {
                (NSApp.delegate as? AppDelegate)?.coordinator?.refreshNow()
            }
            actionButton(label: "Cookie", icon: "key.fill") {
                controller.userPressedEscape()
                appState.showOnboarding = true
            }
            actionButton(label: "Alerts", icon: "bell.fill") {
                controller.userPressedEscape()
                appState.showSettings = true
            }
            actionButton(label: "Diagnostics", icon: "stethoscope") {
                controller.userPressedEscape()
                appState.showDiagnostics = true
            }
            actionButton(label: "Quit", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    @ViewBuilder
    private func actionButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            )
        }
        .buttonStyle(.plain)
    }
}
