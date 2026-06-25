import SwiftUI

/// Expanded notch panel.
///
/// Panel frame is `notchH + 300` tall, anchored at screen top.
/// The top `notchH` points are pure black and overlap the hardware notch.
/// Everything visible lives in the lower 300 pt glass card.
///
/// Content reveal is delayed by 0.14 s so it fades in after the
/// stretchy width animation settles (phase 1 of the frame morph).
struct ExpandedPanelView: View {
    @ObservedObject var appState: AppState
    let controller: NotchWindowController
    @State private var appeared = false

    private var statusColor: Color { appState.sessionStatus.color }
    private var notchH: CGFloat    { ScreenUtils.notchScreen().safeAreaInsets.top }

    var body: some View {
        let visibleHeight = NotchPanelLayout.expandedVisibleHeight(for: appState)
        let cardShape = NotchPillShape(topRadius: 10, bottomRadius: 20)

        ZStack(alignment: .bottom) {
            // Black notch-overlap fill — limited to the hidden hardware notch area.
            VStack(spacing: 0) {
                Color.black
                    .frame(width: NotchPanelLayout.expandedWidth, height: notchH)
                Spacer(minLength: 0)
            }

            // Glass card — the 300 pt visible portion below the notch.
            ZStack(alignment: .topTrailing) {
                NotchGlassBackground(topRadius: 10, bottomRadius: 20, tintColor: statusColor)

                Button {
                    controller.userPressedEscape()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.textSecondary.opacity(0.78))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help("Close")
                .padding(.top, 10)
                .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 10) {
                    HeaderRow(appState: appState, controller: controller)

                    // Provider switcher — only shown when 2+ providers are active.
                    if appState.isMultiProvider {
                        ProviderSwitcherRow(appState: appState)
                    }

                    // Outage banner for the active provider, if any.
                    if let incident = appState.activeIncident {
                        IncidentBanner(providerName: appState.activeProviderId.displayName,
                                       incident: incident)
                    }

                    SessionCard(appState: appState)
                    PaceRow(appState: appState)

                    if let weekly = appState.latestSnapshot?.secondaryWindow {
                        WeeklyCard(window: weekly)
                    }
                    if let weeklySonnet = appState.latestSnapshot?.tertiaryWindow {
                        WeeklyCard(window: weeklySonnet,
                                   title: "Weekly Sonnet",
                                   subtitle: "Pro plan")
                    }

                    Spacer(minLength: 0)
                    ActionsRow(appState: appState, controller: controller)
                    FooterRow()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16 + NotchPanelLayout.expandedTopContentClearance)
                .padding(.bottom, 16)
            }
            .frame(width: NotchPanelLayout.expandedWidth, height: visibleHeight)
            .clipShape(cardShape)
            .shadow(color: statusColor.opacity(0.18), radius: 18, y: 6)
            .shadow(color: .black.opacity(0.55), radius: 28, y: 10)
            // Grows downward from the notch — anchored at top edge.
            .scaleEffect(appeared ? 1 : 0.90, anchor: .top)
            .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Delay content reveal so it syncs with phase-2 of the frame stretch.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                    appeared = true
                }
            }
        }
        .background(KeyEventCatcher { key in
            if key == "\u{1B}" { controller.userPressedEscape() }
        })
    }
}

/// AppKit shim to catch the Escape key while the panel is up.
struct KeyEventCatcher: NSViewRepresentable {
    var handler: (String) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.handler = handler
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class KeyView: NSView {
        var handler: ((String) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if let chars = event.charactersIgnoringModifiers { handler?(chars) }
        }
    }
}
