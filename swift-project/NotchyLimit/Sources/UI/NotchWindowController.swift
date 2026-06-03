import SwiftUI
import AppKit
import Combine

/// Owns the borderless, non-activating NSPanel that hosts the notch UI.
///
/// Hover strategy: Timer polling NSEvent.mouseLocation every 40 ms.
/// NSTrackingArea.mouseExited is unreliable on non-activating panels during
/// resize. NSEvent.addGlobalMonitorForEvents only fires for OTHER apps' events,
/// not our own panel's events. A polling timer is the only approach that works
/// reliably at any window level regardless of activation state.
final class NotchWindowController: NSObject {
    private let panel: NSPanel
    private let appState: AppState
    private var hostingController: NSHostingController<RootNotchView>?
    private var cancellables = Set<AnyCancellable>()
    private var hoverTimer: Timer?
    private var isCurrentlyHovering = false
    private var clickOutsideMonitor: Any?

    // Panel heights include safeAreaInsets.top (the hardware notch height,
    // ~37 pt on MBP 14/16").  The panel is anchored at screen.frame.maxY so
    // the top portion sits inside the notch (invisible — black blends with
    // hardware) and only the lower "visible extension" is seen by the user.
    // This is identical to how the iOS Dynamic Island works.
    private var notchH: CGFloat { ScreenUtils.notchScreen().safeAreaInsets.top }
    // Single provider in the notch — a steady, compact pill width.
    private var compactSize:  NSSize {
        NSSize(width: 220, height: notchH + 22)
    }
    private var expandedSize: NSSize { NSSize(width: 380, height: notchH + 300) }

    init(appState: AppState) {
        self.appState = appState
        self.panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 220, height: 30)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        // .popUpMenu (101) sits above the menu bar compositor (mainMenu = 24),
        // which is required to render inside the notch area on MacBook.
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.popUpMenu.rawValue))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque         = false
        panel.backgroundColor  = .clear
        panel.hasShadow        = false  // SwiftUI views manage their own shadows
        panel.isMovable        = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        appState.$notchState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.applyState(state) }
            .store(in: &cancellables)
    }

    deinit {
        teardown()
    }

    /// Explicitly remove the notch panel from screen and stop all observers.
    /// Called when the display mode no longer includes the notch — relying on
    /// `deinit` alone is unreliable because AppKit can keep an on-screen window
    /// alive, leaving a ghost pill behind.
    func teardown() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
        cancellables.removeAll()
        panel.orderOut(nil)
        panel.contentView = nil
        hostingController = nil
    }

    func present() {
        let root = RootNotchView(appState: appState, controller: self)
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        self.hostingController = hosting
        panel.contentView = hosting.view

        applyState(appState.notchState)
        panel.orderFrontRegardless()

        startHoverTimer()
        startClickOutsideMonitor()
    }

    // MARK: - Click-outside to dismiss

    private func startClickOutsideMonitor() {
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m) }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            guard self.appState.notchState == .expandedPinned else { return }
            // If the click landed outside the panel, collapse.
            if !self.panel.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async { self.appState.notchState = .compactIdle }
            }
        }
    }

    // MARK: - Hover polling (Timer — the only reliable approach)

    private func startHoverTimer() {
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.pollHover()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func pollHover() {
        // Expand the hit-rect slightly so the cursor moving to the expanded
        // panel doesn't immediately trigger a hover-out during the resize.
        let hitRect = panel.frame.insetBy(dx: -4, dy: -4)
        let hovering = hitRect.contains(NSEvent.mouseLocation)
        guard hovering != isCurrentlyHovering else { return }
        isCurrentlyHovering = hovering
        if hovering { userHoveredIn()  }
        else        { userHoveredOut() }
    }

    // MARK: - State transitions

    func userHoveredIn() {
        switch appState.notchState {
        case .compactIdle, .compactHover:
            appState.notchState = .compactHover
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                if self.appState.notchState == .compactHover {
                    self.appState.notchState = .expandedHover
                }
            }
        default: break
        }
    }

    func userHoveredOut() {
        guard appState.notchState != .expandedPinned else { return }
        appState.notchState = .compactIdle
    }

    func userClicked() {
        switch appState.notchState {
        case .expandedPinned: appState.notchState = .compactIdle
        default:              appState.notchState = .expandedPinned
        }
    }

    func userPressedEscape() {
        appState.notchState = .compactIdle
    }

    // MARK: - Layout

    private func applyState(_ state: NotchState) {
        let targetSize: NSSize
        switch state {
        case .hidden:                         targetSize = NSSize(width: 1, height: 1)
        case .compactIdle, .compactHover:     targetSize = compactSize
        case .expandedHover, .expandedPinned: targetSize = expandedSize
        }

        let isExpanding = (state == .expandedHover || state == .expandedPinned)
                       && panel.frame.height < (notchH + 80)  // currently compact

        if isExpanding {
            // Phase 1: stretch width first (pill → wide strip, ~0.16 s)
            let midSize   = NSSize(width: expandedSize.width, height: compactSize.height)
            let midOrigin = ScreenUtils.topCenteredOrigin(forPanelSize: midSize)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(NSRect(origin: midOrigin, size: midSize), display: true)
            }
            // Phase 2: drop height after stretch settles (~0.12 s later)
            let finalOrigin = ScreenUtils.topCenteredOrigin(forPanelSize: targetSize)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.34
                    // Springy overshoot (2nd control-point y > 1) so the panel
                    // "settles" like liquid instead of easing flatly.
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.40, 0.5, 1.0)
                    self.panel.animator().setFrame(NSRect(origin: finalOrigin, size: targetSize), display: true)
                }
            }
        } else {
            // Collapse or hidden: single smooth transition
            let origin = ScreenUtils.topCenteredOrigin(forPanelSize: targetSize)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(NSRect(origin: origin, size: targetSize), display: true)
            }
        }
    }
}

// MARK: - Root SwiftUI view

struct RootNotchView: View {
    @ObservedObject var appState: AppState
    let controller: NotchWindowController

    var body: some View {
        Group {
            switch appState.notchState {
            case .hidden:
                Color.clear
            case .compactIdle, .compactHover:
                // Always one provider in the notch (the active one). Switch which
                // provider via the expanded panel's provider switcher.
                CompactView(appState: appState)
                .onTapGesture { controller.userClicked() }
                .contextMenu {
                        Button { (NSApp.delegate as? AppDelegate)?.coordinator?.refreshNow() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        Button { appState.showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                        Button {
                            NotificationService.shared.sendTest()
                        } label: {
                            Label("Send test notification", systemImage: "bell.fill")
                        }
                        Divider()
                        Button(role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            Label("Quit Notchy Limit", systemImage: "power")
                        }
                    }
            case .expandedHover, .expandedPinned:
                ExpandedPanelView(appState: appState, controller: controller)
            }
        }
        // Settings / Onboarding / Diagnostics are presented as standalone windows
        // by AppDelegate so they work in every display mode (incl. menu-bar-only).
    }
}
