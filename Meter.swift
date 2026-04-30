#!/usr/bin/env swift

import AppKit
import Foundation

private let environment = ProcessInfo.processInfo.environment
private let overlayRoot = environment["METER_ROOT"] ?? FileManager.default.currentDirectoryPath
private let meterCommand = environment["METER_COMMAND"] ?? "usage-hud"
private let logoPaths = [
    "codex": [
        "/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png",
        "/Applications/Codex.app/Contents/Resources/codexTemplate.png",
        "\(overlayRoot)/assets/codex.png",
    ],
    "claude": [
        "\(overlayRoot)/assets/claude.png",
    ],
    "cursor": [
        "/Applications/Cursor.app/Contents/Resources/app/out/vs/glass/browser/media/cursor-splash-logo-normal.png",
        "/Applications/Cursor.app/Contents/Resources/app/out/vs/glass/browser/media/cursor-splash-logo-glass.png",
        "/Applications/Cursor.app/Contents/Resources/Cursor.icns",
        "\(overlayRoot)/assets/cursor.png",
    ],
]

struct UsageState: Decodable {
    let providers: [Provider]
}

struct Provider: Decodable {
    let provider: String
    let displayName: String
    let plan: String?
    let error: String?
    let windows: [UsageWindow]
}

struct UsageWindow: Decodable {
    let label: String
    let leftPercent: Double
    let resetAt: Double?
    let used: Double?
    let limit: Double?
}

final class OverlayView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.showContextMenu(with: event, for: self)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum SettingKey {
        static let refreshInterval = "MeterRefreshInterval"
        static let flashOnRefresh = "MeterFlashOnRefresh"
        static let showProviderName = "MeterShowProviderName"
        static let showProviderIcon = "MeterShowProviderIcon"
        static let showUsageFraction = "MeterShowUsageFraction"
        static let showResetCountdown = "MeterShowResetCountdown"
        static let opaqueBackground = "MeterOpaqueBackground"
        // per-provider enabled
        static let enableClaude = "MeterEnableClaude"
        static let enableCursor = "MeterEnableCursor"
        static let enableCodex = "MeterEnableCodex"
        // provider-specific display
        static let showCursorOnDemand = "MeterShowCursorOnDemand"
        static let hideCodex5hLabel = "MeterHideCodex5hLabel"
        static let abbreviateCodexWeek = "MeterAbbreviateCodexWeek"
    }

    private var window: NSPanel!
    private var stack: NSStackView!
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let frameKey = "MeterFrame"
    private var refreshInterval: TimeInterval = 60
    private var flashOnRefresh = true
    private var showProviderName = true
    private var showProviderIcon = true
    private var showUsageFraction = true
    private var showResetCountdown = true
    private var opaqueBackground = true
    private var enableClaude = true
    private var enableCursor = true
    private var enableCodex = true
    private var showCursorOnDemand = false
    private var hideCodex5hLabel = true
    private var abbreviateCodexWeek = true
    private var lastSuccessfulState: UsageState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadSettings()
        buildWindow()
        refreshNow()
        restartTimer()
    }

    private func buildWindow() {
        let content = OverlayView(frame: NSRect(x: 0, y: 0, width: 250, height: 118))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.8).cgColor
        content.layer?.borderWidth = 1
        content.layer?.shadowColor = NSColor.black.cgColor
        content.layer?.shadowOpacity = 0.30
        content.layer?.shadowRadius = 20
        content.layer?.shadowOffset = CGSize(width: 0, height: -8)

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window = NSPanel(
            contentRect: content.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = content
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        applyBackgroundStyle()

        if let saved = defaults.string(forKey: frameKey) {
            window.setFrame(NSRectFromString(saved), display: false)
        } else if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.maxX - 270, y: visible.maxY - 140))
        }

        window.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.saveFrame() }
    }

    private func saveFrame() {
        defaults.set(NSStringFromRect(window.frame), forKey: frameKey)
    }

    private func loadSettings() {
        defaults.register(defaults: [
            SettingKey.refreshInterval: 60.0,
            SettingKey.flashOnRefresh: true,
            SettingKey.showProviderName: true,
            SettingKey.showProviderIcon: true,
            SettingKey.showUsageFraction: true,
            SettingKey.showResetCountdown: true,
            SettingKey.opaqueBackground: true,
            SettingKey.enableClaude: true,
            SettingKey.enableCursor: true,
            SettingKey.enableCodex: true,
            SettingKey.showCursorOnDemand: false,
            SettingKey.hideCodex5hLabel: true,
            SettingKey.abbreviateCodexWeek: true,
        ])

        refreshInterval = max(5, defaults.double(forKey: SettingKey.refreshInterval))
        flashOnRefresh = defaults.bool(forKey: SettingKey.flashOnRefresh)
        showProviderName = defaults.bool(forKey: SettingKey.showProviderName)
        showProviderIcon = defaults.bool(forKey: SettingKey.showProviderIcon)
        showUsageFraction = defaults.bool(forKey: SettingKey.showUsageFraction)
        showResetCountdown = defaults.bool(forKey: SettingKey.showResetCountdown)
        opaqueBackground = defaults.bool(forKey: SettingKey.opaqueBackground)
        enableClaude = defaults.bool(forKey: SettingKey.enableClaude)
        enableCursor = defaults.bool(forKey: SettingKey.enableCursor)
        enableCodex = defaults.bool(forKey: SettingKey.enableCodex)
        showCursorOnDemand = defaults.bool(forKey: SettingKey.showCursorOnDemand)
        hideCodex5hLabel = defaults.bool(forKey: SettingKey.hideCodex5hLabel)
        abbreviateCodexWeek = defaults.bool(forKey: SettingKey.abbreviateCodexWeek)
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    private func applyBackgroundStyle() {
        let alpha: CGFloat = opaqueBackground ? 1.0 : 0.86
        window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(alpha).cgColor
    }

    private func isEnabled(_ providerID: String) -> Bool {
        switch providerID {
        case "claude": return enableClaude
        case "cursor": return enableCursor
        case "codex": return enableCodex
        default: return true
        }
    }

    @objc func refreshNow() {
        DispatchQueue.global(qos: .utility).async {
            let result = self.loadState()
            DispatchQueue.main.async {
                self.render(result)
            }
        }
    }

    func showContextMenu(with event: NSEvent, for view: NSView) {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        // Display
        menu.addItem(toggleItem("Flash on Refresh", action: #selector(toggleFlashOnRefresh), state: flashOnRefresh))
        menu.addItem(toggleItem("Opaque Background", action: #selector(toggleOpaqueBackground), state: opaqueBackground))
        menu.addItem(.separator())
        menu.addItem(toggleItem("Show Name", action: #selector(toggleShowProviderName), state: showProviderName))
        menu.addItem(toggleItem("Show Icon", action: #selector(toggleShowProviderIcon), state: showProviderIcon))
        menu.addItem(toggleItem("Show Usage Fraction", action: #selector(toggleShowUsageFraction), state: showUsageFraction))
        menu.addItem(toggleItem("Show Reset Countdown", action: #selector(toggleShowResetCountdown), state: showResetCountdown))
        menu.addItem(.separator())

        // Providers submenu
        let providersItem = NSMenuItem(title: "Providers", action: nil, keyEquivalent: "")
        let providersMenu = NSMenu()

        providersMenu.addItem(toggleItem("Claude", action: #selector(toggleEnableClaude), state: enableClaude))
        providersMenu.addItem(.separator())

        providersMenu.addItem(toggleItem("Cursor", action: #selector(toggleEnableCursor), state: enableCursor))
        let cursorOnDemand = toggleItem("  Show On-demand Usage", action: #selector(toggleShowCursorOnDemand), state: showCursorOnDemand)
        cursorOnDemand.isEnabled = enableCursor
        providersMenu.addItem(cursorOnDemand)
        providersMenu.addItem(.separator())

        providersMenu.addItem(toggleItem("Codex", action: #selector(toggleEnableCodex), state: enableCodex))
        let abbreviate = toggleItem("  Abbreviate Week to W", action: #selector(toggleAbbreviateCodexWeek), state: abbreviateCodexWeek)
        abbreviate.isEnabled = enableCodex
        providersMenu.addItem(abbreviate)
        let hide5h = toggleItem("  Hide 5h Label", action: #selector(toggleHideCodex5hLabel), state: hideCodex5hLabel)
        hide5h.isEnabled = enableCodex
        providersMenu.addItem(hide5h)

        providersItem.submenu = providersMenu
        menu.addItem(providersItem)
        menu.addItem(.separator())

        // Refresh interval submenu
        let intervalItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        [15, 30, 60, 120].forEach { seconds in
            let item = NSMenuItem(title: "\(seconds)s", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = Int(refreshInterval.rounded()) == seconds ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Meter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func toggleItem(_ title: String, action: Selector, state: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = state ? .on : .off
        return item
    }

    @objc private func toggleFlashOnRefresh() {
        flashOnRefresh.toggle()
        defaults.set(flashOnRefresh, forKey: SettingKey.flashOnRefresh)
    }

    @objc private func toggleOpaqueBackground() {
        opaqueBackground.toggle()
        defaults.set(opaqueBackground, forKey: SettingKey.opaqueBackground)
        applyBackgroundStyle()
    }

    @objc private func toggleShowProviderName() {
        showProviderName.toggle()
        defaults.set(showProviderName, forKey: SettingKey.showProviderName)
        refreshNow()
    }

    @objc private func toggleShowProviderIcon() {
        showProviderIcon.toggle()
        defaults.set(showProviderIcon, forKey: SettingKey.showProviderIcon)
        refreshNow()
    }

    @objc private func toggleShowUsageFraction() {
        showUsageFraction.toggle()
        defaults.set(showUsageFraction, forKey: SettingKey.showUsageFraction)
        refreshNow()
    }

    @objc private func toggleShowResetCountdown() {
        showResetCountdown.toggle()
        defaults.set(showResetCountdown, forKey: SettingKey.showResetCountdown)
        refreshNow()
    }

    @objc private func toggleEnableClaude() {
        enableClaude.toggle()
        defaults.set(enableClaude, forKey: SettingKey.enableClaude)
        refreshNow()
    }

    @objc private func toggleEnableCursor() {
        enableCursor.toggle()
        defaults.set(enableCursor, forKey: SettingKey.enableCursor)
        refreshNow()
    }

    @objc private func toggleEnableCodex() {
        enableCodex.toggle()
        defaults.set(enableCodex, forKey: SettingKey.enableCodex)
        refreshNow()
    }

    @objc private func toggleShowCursorOnDemand() {
        showCursorOnDemand.toggle()
        defaults.set(showCursorOnDemand, forKey: SettingKey.showCursorOnDemand)
        refreshNow()
    }

    @objc private func toggleHideCodex5hLabel() {
        hideCodex5hLabel.toggle()
        defaults.set(hideCodex5hLabel, forKey: SettingKey.hideCodex5hLabel)
        refreshNow()
    }

    @objc private func toggleAbbreviateCodexWeek() {
        abbreviateCodexWeek.toggle()
        defaults.set(abbreviateCodexWeek, forKey: SettingKey.abbreviateCodexWeek)
        refreshNow()
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        let seconds = max(5, sender.tag)
        refreshInterval = TimeInterval(seconds)
        defaults.set(refreshInterval, forKey: SettingKey.refreshInterval)
        restartTimer()
        refreshNow()
    }

    private func loadState() -> Result<UsageState, Error> {
        do {
            let process = Process()
            // `usage-hud` is `#!/usr/bin/env node`. GUI launches (Finder, open -a) get a
            // minimal PATH, so `env` never finds `node` and the script exits 127. A login
            // shell loads the usual profile and restores Homebrew / nvm / etc.
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "\(meterCommand) --json"]

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            try process.run()
            process.waitUntilExit()

            let data = output.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus != 0 {
                let errorData = error.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8) ?? "usage-hud failed"
                throw NSError(domain: "Meter", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines),
                ])
            }

            return .success(try JSONDecoder().decode(UsageState.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    private func render(_ result: Result<UsageState, Error>) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch result {
        case .success(let state):
            lastSuccessfulState = state
            let visible = state.providers.filter { isEnabled($0.provider) }
            for provider in visible {
                stack.addArrangedSubview(row(for: provider))
            }
            if visible.isEmpty {
                stack.addArrangedSubview(textLabel("All providers disabled", size: 12, color: .secondaryLabelColor))
            }
        case .failure:
            if let stale = lastSuccessfulState {
                let visible = stale.providers.filter { isEnabled($0.provider) }
                for provider in visible {
                    stack.addArrangedSubview(row(for: provider))
                }
                stack.addArrangedSubview(staleFooter())
            } else {
                stack.addArrangedSubview(textLabel("Meter unavailable", size: 13, weight: .semibold))
            }
        }

        resizeToFit()
        flashUpdate()
    }

    private func staleFooter() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        let icon = textLabel("⏱", size: 9, color: .tertiaryLabelColor)
        let label = textLabel("stale", size: 9, color: .tertiaryLabelColor)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        return row
    }

    private func flashUpdate() {
        guard flashOnRefresh else { return }
        guard let layer = window.contentView?.layer else { return }
        layer.removeAnimation(forKey: "meterFlash")

        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 0.8
        flash.toValue = 1.0
        flash.duration = 0.16
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(flash, forKey: "meterFlash")
    }

    private func row(for provider: Provider) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        if showProviderIcon {
            let icon = logoView(for: provider.provider)
            row.addArrangedSubview(icon)
        }

        let copy = NSStackView()
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 1

        if showProviderName {
            copy.addArrangedSubview(textLabel(provider.displayName, size: 12, weight: .semibold))
        }

        let visibleWindows = provider.windows.filter { window in
            if provider.provider == "cursor", window.label == "On-demand", !showCursorOnDemand {
                return false
            }
            return true
        }

        if visibleWindows.isEmpty {
            copy.addArrangedSubview(textLabel(provider.error ?? "No data", size: 11, color: .secondaryLabelColor))
        } else {
            copy.addArrangedSubview(summaryField(for: visibleWindows, provider: provider))
        }

        row.addArrangedSubview(copy)
        return row
    }

    private let summaryLineFontSize: CGFloat = 11

    /// Under 10%: red; under 20%: orange; otherwise full label color for readability.
    private func accentColor(forLeftPercent p: Double) -> NSColor {
        if p < 10 { return .systemRed }
        if p < 20 { return .systemOrange }
        return .labelColor
    }

    private func summaryMutedAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
    }

    /// Codex multi-window: omit the short-window label ("5h"); show weekly bucket as `W`.
    private func codexWindowAttributed(_ window: UsageWindow, font: NSFont, muted: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let pct = Int(window.leftPercent.rounded())
        let pctStr = "\(pct)%"
        let dur = durationText(for: window)
        let raw = window.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let isShort = hideCodex5hLabel && raw.caseInsensitiveCompare("5h") == .orderedSame
        let prefixStr: String = {
            if isShort { return "" }
            if abbreviateCodexWeek, raw.caseInsensitiveCompare("week") == .orderedSame { return "W " }
            return raw.isEmpty ? "" : "\(raw) "
        }()

        let out = NSMutableAttributedString()
        if !prefixStr.isEmpty {
            out.append(NSAttributedString(string: prefixStr, attributes: muted))
        }
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: accentColor(forLeftPercent: window.leftPercent),
        ]
        out.append(NSAttributedString(string: pctStr, attributes: pctAttrs))
        if showResetCountdown {
            out.append(NSAttributedString(string: " \(dur)", attributes: muted))
        }
        return out
    }

    private func summaryField(for windows: [UsageWindow], provider: Provider) -> NSTextField {
        let font = NSFont.systemFont(ofSize: summaryLineFontSize, weight: .regular)
        let muted = summaryMutedAttributes(font: font)
        let attr: NSAttributedString = {
            if provider.provider == "codex", windows.count > 1 {
                let result = NSMutableAttributedString()
                for (i, w) in windows.enumerated() {
                    if i > 0 { result.append(NSAttributedString(string: "  ", attributes: muted)) }
                    result.append(codexWindowAttributed(w, font: font, muted: muted))
                }
                return result
            }
            guard let usageWindow = windows.first else {
                return NSAttributedString(string: provider.error ?? "No data", attributes: muted)
            }
            let pctStr = "\(Int(usageWindow.leftPercent.rounded()))%"
            let out = NSMutableAttributedString()
            out.append(NSAttributedString(
                string: pctStr,
                attributes: [
                    .font: font,
                    .foregroundColor: accentColor(forLeftPercent: usageWindow.leftPercent),
                ]
            ))
            if showUsageFraction, let used = usageWindow.used, let limit = usageWindow.limit {
                out.append(NSAttributedString(string: "  \(Int(used))/\(Int(limit))", attributes: muted))
            }
            if showResetCountdown {
                out.append(NSAttributedString(string: "  \(durationText(for: usageWindow))", attributes: muted))
            }
            return out
        }()

        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = attr
        label.font = font
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    private func durationText(for usageWindow: UsageWindow) -> String {
        guard let resetAt = usageWindow.resetAt else {
            return "unknown"
        }
        return formatDuration(until: resetAt)
    }

    private func logoView(for provider: String) -> NSView {
        if let image = logoImage(for: provider) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.contentTintColor = provider == "codex" ? .labelColor : nil
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 20).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 20).isActive = true
            return imageView
        }

        let fallback = textLabel(iconText(for: provider), size: 15, weight: .semibold)
        fallback.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return fallback
    }

    private func logoImage(for provider: String) -> NSImage? {
        for logoPath in logoPaths[provider] ?? [] {
            if let image = NSImage(contentsOfFile: logoPath) {
                image.isTemplate = provider == "codex"
                return image
            }
        }
        return nil
    }

    private func textLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    private func iconText(for provider: String) -> String {
        switch provider {
        case "codex": return ">"
        case "claude": return "✳"
        case "cursor": return "⌬"
        default: return "•"
        }
    }

    private func formatDuration(until epochMilliseconds: Double) -> String {
        let seconds = max(0, Int((epochMilliseconds / 1000) - Date().timeIntervalSince1970))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func resizeToFit() {
        let width: CGFloat = 250
        let screenHeight = window.screen?.visibleFrame.height ?? 600
        let height = min(max(82, stack.fittingSize.height), screenHeight - 40)
        let newSize = NSSize(width: width, height: height)
        guard window.frame.size != newSize else { return }
        var frame = window.frame
        frame.size = newSize
        window.setFrame(frame, display: true)
        saveFrame()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
