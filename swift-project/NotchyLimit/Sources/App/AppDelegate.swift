import SwiftUI
import AppKit
import Combine
import ServiceManagement

/// Root application controller. Wires AppState, NotchWindowController, MenuBarController,
/// and the polling pipeline.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appState = AppState()
    var notchController: NotchWindowController?
    var menuBarController: MenuBarController?
    var coordinator: UsageCoordinator?
    var cancellables = Set<AnyCancellable>()

    // Standalone aux windows — work in every display mode (incl. menu-bar-only).
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[NotchyLimit] launched — v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")

        ProviderRegistry.shared.bootstrap()

        coordinator = UsageCoordinator(
            appState: appState,
            authService: AuthService.shared,
            usageService: UsageService.shared,
            notifications: NotificationService.shared
        )
        coordinator?.start()

        syncLaunchAtLoginState()

        appState.$launchAtLogin
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in self?.setLaunchAtLogin(enabled) }
            .store(in: &cancellables)

        // Apply initial display mode, then react to changes.
        applyDisplayMode(appState.displayMode)
        appState.$displayMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in self?.applyDisplayMode(mode) }
            .store(in: &cancellables)

        // Present aux screens as standalone windows whenever their flag flips.
        appState.$showOnboarding.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] show in self?.presentAux(.onboarding, show: show) }
            .store(in: &cancellables)
        appState.$showSettings.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] show in self?.presentAux(.settings, show: show) }
            .store(in: &cancellables)
        appState.$showDiagnostics.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] show in self?.presentAux(.diagnostics, show: show) }
            .store(in: &cancellables)

        if !AuthService.shared.hasAnyConfiguredProvider() {
            appState.showOnboarding = true
        }
    }

    // MARK: - Aux windows (Onboarding / Settings / Diagnostics)

    private enum AuxKind { case onboarding, settings, diagnostics }

    private func presentAux(_ kind: AuxKind, show: Bool) {
        let current: NSWindow? = {
            switch kind {
            case .onboarding:  return onboardingWindow
            case .settings:    return settingsWindow
            case .diagnostics: return diagnosticsWindow
            }
        }()

        guard show else {
            current?.close()
            return
        }
        if let current {
            bringAuxWindowForward(current)
            return
        }

        let content: NSView
        let size: NSSize
        let title: String
        switch kind {
        case .onboarding:
            content = NSHostingView(rootView: OnboardingView(appState: appState))
            size = NSSize(width: 420, height: 480); title = "Welcome to Notchy"
        case .settings:
            content = NSHostingView(rootView: SettingsView(appState: appState))
            size = NSSize(width: 460, height: 540); title = "Notchy Settings"
        case .diagnostics:
            content = NSHostingView(rootView: DiagnosticsView(appState: appState))
            size = NSSize(width: 420, height: 360); title = "Diagnostics"
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = content
        window.delegate = self
        window.center()

        switch kind {
        case .onboarding:  onboardingWindow = window
        case .settings:    settingsWindow = window
        case .diagnostics: diagnosticsWindow = window
        }

        bringAuxWindowForward(window)
    }

    private func bringAuxWindowForward(_ window: NSWindow) {
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        switch w {
        case onboardingWindow:  onboardingWindow = nil;  appState.showOnboarding = false
        case settingsWindow:    settingsWindow = nil;    appState.showSettings = false
        case diagnosticsWindow: diagnosticsWindow = nil; appState.showDiagnostics = false
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        menuBarController?.teardown()
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Display mode

    private func applyDisplayMode(_ mode: DisplayMode) {
        // Notch
        if mode.shouldShowNotch() {
            if notchController == nil {
                notchController = NotchWindowController(appState: appState)
                notchController?.present()
            }
        } else {
            notchController?.teardown()   // explicitly remove the panel from screen
            notchController = nil
        }

        // Menu bar
        if mode.shouldShowMenuBar() {
            if menuBarController == nil {
                menuBarController = MenuBarController(appState: appState)
                menuBarController?.setup()
            }
        } else {
            menuBarController?.teardown()
            menuBarController = nil
        }
    }

    // MARK: - Launch at login

    private func syncLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            appState.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register()   }
                else       { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("[NotchyLimit] Launch at login toggle failed: \(error.localizedDescription)")
                appState.launchAtLogin = !enabled
            }
        }
    }
}
