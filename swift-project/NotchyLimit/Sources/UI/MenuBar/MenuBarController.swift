import AppKit
import SwiftUI
import Combine

/// Manages the `NSStatusItem` (menu bar icon) and the `NSPopover` that
/// expands to show usage details when the user clicks the icon.
///
/// Premium design goals:
/// - Icon shows a colored status dot + percentage text mirroring the notch pill aesthetic.
/// - Popover reuses the same glass-card design language as the expanded notch panel.
/// - No separate menu: click = toggle popover (clean, single-action).
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    // MARK: - Lifecycle

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateButtonAppearance()

        // Rebuild icon whenever usage data changes
        appState.$latestSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButtonAppearance() }
            .store(in: &cancellables)

        appState.$syncStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButtonAppearance() }
            .store(in: &cancellables)

        appState.$incidents
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButtonAppearance() }
            .store(in: &cancellables)

        // Build the popover
        let popoverView = MenuBarPopoverView(appState: appState) { [weak self] in
            self?.closePopover()
        }
        let vc = NSHostingController(rootView: popoverView)
        vc.view.frame = NSRect(x: 0, y: 0, width: 300, height: 360)
        // Let the popover grow/shrink to fit the SwiftUI content (one row per provider).
        if #available(macOS 13.0, *) {
            vc.sizingOptions = [.preferredContentSize]
        }

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = NSSize(width: 300, height: 360)
        pop.behavior = .transient
        pop.animates = true
        self.popover = pop
    }

    func teardown() {
        popover?.performClose(nil)
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover = nil
        cancellables.removeAll()
    }

    // MARK: - Icon rendering

    /// Clean, Apple-native menu-bar look: a monochrome template glyph of the
    /// Notchy mascot that auto-adapts to the menu bar (light/dark, selected),
    /// followed by a compact value. Colour appears only when it carries meaning
    /// — a warning/critical level or an active outage — the way macOS tints the
    /// battery red when it's low.
    private func updateButtonAppearance() {
        guard let button = statusItem?.button else { return }

        // Trailing value next to the glyph.
        let value: String
        if case .syncing = appState.syncStatus {
            value = ""
        } else if appState.authStatus == .notConfigured || appState.authStatus == .expired {
            value = ""
        } else if !appState.activeShowsPercentBar {
            value = appState.activeShortLabel                       // "$110" / "Active"
        } else {
            value = "\(Int((appState.sessionPercent * 100).rounded()))%"
        }

        // Tint: nil = monochrome (adapts to the menu bar). Colour only when meaningful.
        let tint: NSColor?
        if appState.activeIncident != nil {
            tint = .systemOrange
        } else {
            switch appState.combinedStatus {
            case .warning:  tint = NSColor(red: 1.00, green: 0.78, blue: 0.20, alpha: 1)
            case .critical: tint = NSColor(red: 1.00, green: 0.40, blue: 0.38, alpha: 1)
            default:        tint = nil
            }
        }

        // Render the glyph directly rather than tinting via `button.contentTintColor`.
        // A non-nil `contentTintColor` overrides the status bar's automatic template
        // tinting — the mechanism that makes the glyph render white over a dark or
        // translucent menu bar (e.g. Light mode sitting on a dark wallpaper) and black
        // over a light one. When the colour carries meaning we bake it into a
        // non-template copy instead; otherwise we hand the menu bar a clean template
        // image and let it adapt on its own. We never assign `contentTintColor` so the
        // template path is always honoured.
        if let tint {
            button.image = NotchyStatusGlyph.coloredImage(tint)
        } else {
            button.image = NotchyStatusGlyph.image()
        }

        // Respect the user's chosen menu-bar style. Value-only with no value
        // falls back to the icon so the item never goes invisible.
        let style = appState.menuBarStyle
        let showValue = style != .iconOnly && !value.isEmpty
        let showIcon  = style != .valueOnly || value.isEmpty

        let title = NSAttributedString(string: showValue ? " \(value)" : "", attributes: [
            .foregroundColor: tint ?? NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        ])
        button.attributedTitle = title

        if showIcon && showValue { button.imagePosition = .imageLeading }
        else if showIcon         { button.imagePosition = .imageOnly }
        else                     { button.imagePosition = .noImage }

        if let incident = appState.activeIncident {
            button.toolTip = "\(appState.activeProviderId.displayName): \(incident.summary)"
        } else {
            button.toolTip = toolTipString
        }
    }

    private var toolTipString: String {
        guard let snap = appState.latestSnapshot else { return "Notchy — no data yet" }
        if snap.isStatusOnly { return "\(snap.providerId.displayName): Connected" }
        if snap.isBalance    { return "\(snap.providerId.displayName): \(snap.shortLabel) left" }
        let pct = Int((snap.primaryWindow.percentUsed * 100).rounded())
        let reset = snap.primaryWindow.timeToResetString() ?? ""
        return "\(snap.providerId.displayName): \(pct)%\(reset.isEmpty ? "" : " · \(reset)")"
    }

    // MARK: - Popover toggle

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let pop = popover, let button = statusItem?.button else { return }
        if pop.isShown {
            pop.performClose(sender)
        } else {
            // Activate so the popover can become key (receives keyboard input)
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }
}

// MARK: - Status item glyph

/// Draws the Notchy mascot as a crisp monochrome template image for the menu bar:
/// a rounded "screen" with a little notch tab on top and two eye cut-outs.
/// Rendered as a template so macOS handles light/dark + selection automatically.
///
/// The glyph is backed by an `NSBitmapImageRep` rather than the block-based
/// `NSImage(size:flipped:drawingHandler:)` initializer. That initializer yields
/// an `NSCustomImageRep`, which the status bar does not always tint as a template
/// — so on a dark or translucent menu bar (for example Light mode over a dark
/// wallpaper) the glyph could render black and become invisible. A bitmap-backed
/// template image is tinted reliably (issue #13).
enum NotchyStatusGlyph {
    // `updateButtonAppearance()` runs on every published state change, so the glyph
    // is requested far more often than it actually changes. Cache the rendered
    // images (all on the main thread) to avoid repeated bitmap allocation + drawing.
    private static var templateCache: NSImage?
    private static var coloredCache: [NSColor: NSImage] = [:]

    /// Monochrome template image — the menu bar tints it (white over a dark bar,
    /// black over a light one, dimmed when the app is inactive) automatically.
    static func image(pointSize: CGFloat = 15) -> NSImage {
        if let cached = templateCache { return cached }
        let rendered = renderImage(pointSize: pointSize, fill: .black, isTemplate: true)
        templateCache = rendered
        return rendered
    }

    /// Solid-colour, non-template copy used when the colour carries meaning
    /// (warning / critical / outage). Baking the colour in keeps us off
    /// `contentTintColor`, which would otherwise disable template tinting.
    static func coloredImage(_ color: NSColor, pointSize: CGFloat = 15) -> NSImage {
        if let cached = coloredCache[color] { return cached }
        let rendered = renderImage(pointSize: pointSize, fill: color, isTemplate: false)
        coloredCache[color] = rendered
        return rendered
    }

    private static func renderImage(pointSize: CGFloat, fill: NSColor, isTemplate: Bool) -> NSImage {
        let size = NSSize(width: ceil(pointSize * 1.15), height: pointSize)
        let scale: CGFloat = 2 // render @2x so the glyph stays crisp on Retina displays

        // Round pixel dimensions up so a non-integer point size never under-allocates
        // the backing store (which would clip the glyph).
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            // If the bitmap rep can't be allocated, fall back to a drawing-handler
            // image. Its template tinting is less reliable, but a visible glyph beats
            // an empty one — the status icon must never disappear entirely (issue #13).
            return fallbackImage(size: size, fill: fill, isTemplate: isTemplate)
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        // The freshly allocated buffer isn't guaranteed to be zeroed, so clear it to
        // transparent before drawing — otherwise the area outside the glyph could
        // contain garbage instead of the transparency a template image relies on.
        NSColor.clear.set()
        rect.fill()
        draw(in: rect, fill: fill)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = isTemplate
        return image
    }

    private static func fallbackImage(size: NSSize, fill: NSColor, isTemplate: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, fill: fill)
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    private static func draw(in rect: NSRect, fill: NSColor) {
        // Head / screen
        let head = NSRect(
            x: rect.width * 0.06,
            y: rect.height * 0.02,
            width: rect.width * 0.88,
            height: rect.height * 0.74
        )
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        path.append(NSBezierPath(roundedRect: head,
                                 xRadius: rect.height * 0.22,
                                 yRadius: rect.height * 0.22))

        // Notch tab on top (the logo's red bit), touching the head edge.
        let tabW = rect.width * 0.30
        let tabH = rect.height * 0.18
        let tab = NSRect(x: rect.midX - tabW / 2, y: head.maxY - 0.5, width: tabW, height: tabH)
        path.append(NSBezierPath(roundedRect: tab, xRadius: tabH * 0.45, yRadius: tabH * 0.45))

        // Two eyes, punched out via even-odd winding.
        let eyeR = rect.height * 0.105
        let eyeY = head.midY - eyeR
        let dx = rect.width * 0.18
        path.append(NSBezierPath(ovalIn: NSRect(x: rect.midX - dx - eyeR, y: eyeY, width: eyeR * 2, height: eyeR * 2)))
        path.append(NSBezierPath(ovalIn: NSRect(x: rect.midX + dx - eyeR, y: eyeY, width: eyeR * 2, height: eyeR * 2)))

        fill.setFill()
        path.fill()
    }
}

// MARK: - Popover content view

/// Minimal menu-bar popover: one compact row per enabled provider, on a glass
/// panel. The menu bar is the place to see everything at a glance, so unlike the
/// notch (which focuses on the active provider) this lists them all.
private struct MenuBarPopoverView: View {
    @ObservedObject var appState: AppState
    let onClose: () -> Void
    @State private var expandedProvider: ProviderId?

    private var providers: [ProviderId] {
        appState.enabledProviders.isEmpty
            ? ProviderId.allCases.filter { appState.snapshots[$0] != nil }
            : appState.enabledProviders
    }

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.stroke)

                if providers.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(providers, id: \.self) { id in
                                VStack(spacing: 0) {
                                    providerRow(id)
                                    if expandedProvider == id {
                                        providerDetail(id)
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 400)
                }

                Divider().overlay(Theme.stroke)
                footer
            }
        }
        .frame(width: 300)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            RetroMascot(size: 20, usagePercent: appState.peakUsagePercent, noData: appState.hasNoData)
            VStack(alignment: .leading, spacing: 1) {
                Text("Notchy")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundColor(Theme.textPrimary)
                // Cross-provider dollar total — the at-a-glance number.
                if let summary = appState.dollarSummary {
                    Text(summary)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            Spacer()
            if let incident = appState.worstIncident {
                Image(systemName: incident.level.glyph)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(incident.level.tint)
                    .help(incident.summary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: Provider row

    @ViewBuilder
    private func providerRow(_ id: ProviderId) -> some View {
        let snap = appState.snapshots[id]
        let incident = appState.incidents[id].flatMap { $0.level.isActive ? $0 : nil }
        let isActive = id == appState.activeProviderId
        let tint = incident?.level.tint ?? (snap?.combinedStatus.color ?? Theme.statusUnknown)

        Button {
            appState.activeProviderId = id
            if let snap { appState.latestSnapshot = snap }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                expandedProvider = (expandedProvider == id) ? nil : id
            }
        } label: {
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    // Icon bubble tinted with the provider's brand color (identity).
                    // The brand logo always stays visible — even during an outage —
                    // with an issue shown as a small corner badge (issue #13/#14),
                    // while health stays in the status dot/value on the right.
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((incident == nil ? id.brandColor : tint).opacity(0.18))
                            .frame(width: 30, height: 30)
                        ProviderIconView(id: id, size: 18, fallbackColor: tint)
                    }
                    .overlay(alignment: .topTrailing) {
                        if let incident {
                            Image(systemName: incident.level.glyph)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(incident.level.tint)
                                .padding(2)
                                .background(
                                    Circle()
                                        .fill(Color.black.opacity(0.85))
                                        .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 0.5))
                                )
                                .offset(x: 4, y: -4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(id.displayName)
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .foregroundColor(Theme.textPrimary)
                        Text(subline(id: id, snap: snap, incident: incident))
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text(snap?.shortLabel ?? "…")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(snap == nil ? Theme.textSecondary : tint)
                }

                // Slim usage bar — only for providers that report a percentage.
                if let snap, snap.showsPercentBar {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(LinearGradient(colors: [tint.opacity(0.7), tint],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(3, geo.size.width * min(snap.primaryWindow.percentUsed, 1)))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? Theme.surfaceElevated : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isActive ? tint.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Pin to notch") {
                appState.activeProviderId = id
                if let snap { appState.latestSnapshot = snap }
            }
            if let url = id.billingURL {
                Button("Open \(id.displayName) billing") { NSWorkspace.shared.open(url) }
            }
            Button("Copy usage") {
                let text = "\(id.displayName): \(snap?.shortLabel ?? "no data")"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Button("Refresh \(id.displayName)") {
                UsageService.shared.refreshNow(providerId: id)
            }
            Divider()
            Button("Move up")   { move(id, by: -1) }
                .disabled(appState.enabledProviders.firstIndex(of: id) ?? 0 == 0)
            Button("Move down") { move(id, by: 1) }
                .disabled((appState.enabledProviders.firstIndex(of: id) ?? 0) >= appState.enabledProviders.count - 1)
        }
    }

    /// Reorder a provider within the enabled list (persists via AppState.didSet).
    private func move(_ id: ProviderId, by delta: Int) {
        var list = appState.enabledProviders
        guard let i = list.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < list.count else { return }
        list.swapAt(i, j)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            appState.enabledProviders = list
        }
    }

    // MARK: Inline detail (sparkline + reset + quick actions)

    @ViewBuilder
    private func providerDetail(_ id: ProviderId) -> some View {
        let snap = appState.snapshots[id]
        let history = UsageHistory.shared.series(for: id)
        VStack(alignment: .leading, spacing: 8) {
            Sparkline(values: history, color: id.brandColor)
                .frame(height: 36)

            HStack(spacing: 10) {
                if let reset = snap?.primaryWindow.timeToResetString() {
                    Label(reset, systemImage: "clock")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                if let url = id.billingURL {
                    iconButton("creditcard", help: "Open billing") { NSWorkspace.shared.open(url) }
                }
                iconButton("doc.on.doc", help: "Copy usage") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(id.displayName): \(snap?.shortLabel ?? "no data")", forType: .string)
                }
                iconButton("arrow.clockwise", help: "Refresh") {
                    UsageService.shared.refreshNow(providerId: id)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private func subline(id: ProviderId, snap: ServiceUsageSnapshot?, incident: ServiceIncident?) -> String {
        if let incident { return incident.summary }
        if snap == nil, let err = appState.providerErrors[id] {
            if err.isAuthIssue { return "Sign in again" }
            return err.description
        }
        guard let snap else { return "Waiting for data…" }
        if snap.isBalance { return "Credit balance" }
        if snap.isStatusOnly { return "Connected — no usage quota" }
        if let reset = snap.primaryWindow.timeToResetString() { return reset }
        return "\(Int((snap.primaryWindow.percentUsed * 100).rounded()))% used"
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            RetroMascot(size: 40, usagePercent: 0)
            Text("No providers yet")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Connect Claude, OpenAI, Gemini and more to see your limits here.")
                .font(Theme.captionFont)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Add a provider") {
                appState.showOnboarding = true
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentWarm)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let updated = lastUpdatedString {
                Text(updated)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            iconButton("arrow.clockwise", help: "Refresh") {
                (NSApp.delegate as? AppDelegate)?.coordinator?.refreshNow()
            }
            iconButton("gearshape", help: "Settings") {
                appState.showSettings = true
            }
            iconButton("power", help: "Quit Notchy") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var lastUpdatedString: String? {
        let dates = appState.snapshots.values.map(\.capturedAt)
        guard let latest = dates.max() else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "Updated \(f.string(from: latest))"
    }
}
