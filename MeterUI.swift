import AppKit
import Foundation

// MARK: - UI

final class UsageBarView: NSView {
    private let usedFraction: CGFloat
    private let color: NSColor

    init(usedFraction: CGFloat, color: NSColor) {
        self.usedFraction = max(0, min(1, usedFraction))
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 3) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
        let fillWidth = bounds.width * usedFraction
        guard fillWidth > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class OverlayView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.showContextMenu(with: event, for: self)
        }
    }
}

// MARK: - Clickable Stack View

final class ClickableStackView: NSStackView {
    var onTap: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        wantsLayer = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.10)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        wantsLayer = true
        let from = (layer?.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 0.96
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = from
        spring.toValue = 1.0
        spring.damping = 20
        spring.stiffness = 380
        spring.mass = 1
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        layer?.add(spring, forKey: "scale")
        layer?.transform = CATransform3DIdentity
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onTap?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
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
        static let enableClaude = "MeterEnableClaude"
        static let enableCursor = "MeterEnableCursor"
        static let enableCodex = "MeterEnableCodex"
        static let enableCrof = "MeterEnableCrof"
        static let enableOpenRouter = "MeterEnableOpenRouter"
        static let enableOpenAI = "MeterEnableOpenAI"
        static let enableAnthropic = "MeterEnableAnthropic"
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
    private var enableCrof = true
    private var enableOpenRouter = false
    private var enableOpenAI = false
    private var enableAnthropic = false
    private var showCursorOnDemand = false
    private var hideCodex5hLabel = true
    private var abbreviateCodexWeek = true
    private var lastSuccessfulState: UsageState?

    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/meter/providers.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadSettings()
        lastSuccessfulState = loadDiskCache()
        buildWindow()
        refreshNow()
        restartTimer()
    }

    private func loadDiskCache() -> UsageState? {
        guard let data = try? Data(contentsOf: cacheURL),
              let providers = try? JSONDecoder().decode([Provider].self, from: data) else { return nil }
        return UsageState(providers: providers)
    }

    private func saveDiskCache(_ state: UsageState) {
        guard let data = try? JSONEncoder().encode(state.providers) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
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
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 18, right: 14)
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
            SettingKey.enableCursor: false,
            SettingKey.enableCodex: true,
            SettingKey.enableCrof: false,
            SettingKey.enableOpenRouter: false,
            SettingKey.enableOpenAI: false,
            SettingKey.enableAnthropic: false,
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
        enableCrof = defaults.bool(forKey: SettingKey.enableCrof)
        enableOpenRouter = defaults.bool(forKey: SettingKey.enableOpenRouter)
        enableOpenAI = defaults.bool(forKey: SettingKey.enableOpenAI)
        enableAnthropic = defaults.bool(forKey: SettingKey.enableAnthropic)
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
        case "crof": return enableCrof
        case "openrouter": return enableOpenRouter
        case "openai": return enableOpenAI
        case "anthropic": return enableAnthropic
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

        menu.addItem(toggleItem("Flash on Refresh", action: #selector(toggleFlashOnRefresh), state: flashOnRefresh))
        menu.addItem(toggleItem("Opaque Background", action: #selector(toggleOpaqueBackground), state: opaqueBackground))
        menu.addItem(.separator())
        menu.addItem(toggleItem("Show Name", action: #selector(toggleShowProviderName), state: showProviderName))
        menu.addItem(toggleItem("Show Icon", action: #selector(toggleShowProviderIcon), state: showProviderIcon))
        menu.addItem(toggleItem("Show Usage Fraction", action: #selector(toggleShowUsageFraction), state: showUsageFraction))
        menu.addItem(toggleItem("Show Reset Countdown", action: #selector(toggleShowResetCountdown), state: showResetCountdown))
        menu.addItem(.separator())

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
        providersMenu.addItem(.separator())
        providersMenu.addItem(toggleItem("Crof", action: #selector(toggleEnableCrof), state: enableCrof))
        providersMenu.addItem(.separator())
        providersMenu.addItem(toggleItem("OpenAI API", action: #selector(toggleEnableOpenAI), state: enableOpenAI))
        providersMenu.addItem(toggleItem("Anthropic API", action: #selector(toggleEnableAnthropic), state: enableAnthropic))
        providersMenu.addItem(toggleItem("OpenRouter", action: #selector(toggleEnableOpenRouter), state: enableOpenRouter))

        providersItem.submenu = providersMenu
        menu.addItem(providersItem)
        menu.addItem(.separator())

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

    @objc private func toggleEnableCrof() {
        enableCrof.toggle()
        defaults.set(enableCrof, forKey: SettingKey.enableCrof)
        refreshNow()
    }

    @objc private func toggleEnableOpenRouter() {
        enableOpenRouter.toggle()
        defaults.set(enableOpenRouter, forKey: SettingKey.enableOpenRouter)
        refreshNow()
    }

    @objc private func toggleEnableOpenAI() {
        enableOpenAI.toggle()
        defaults.set(enableOpenAI, forKey: SettingKey.enableOpenAI)
        refreshNow()
    }

    @objc private func toggleEnableAnthropic() {
        enableAnthropic.toggle()
        defaults.set(enableAnthropic, forKey: SettingKey.enableAnthropic)
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
        var codex: Provider?
        var claude: Provider?
        var cursor: Provider?
        var crof: Provider?
        var openRouter: Provider?
        var openAI: Provider?
        var anthropic: Provider?
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async { codex = fetchCodex(); group.leave() }
        group.enter()
        DispatchQueue.global().async { claude = fetchClaude(); group.leave() }
        group.enter()
        DispatchQueue.global().async { cursor = fetchCursor(); group.leave() }
        group.enter()
        DispatchQueue.global().async { crof = fetchCrof(); group.leave() }
        group.enter()
        DispatchQueue.global().async { openRouter = fetchOpenRouter(); group.leave() }
        group.enter()
        DispatchQueue.global().async { openAI = fetchOpenAI(); group.leave() }
        group.enter()
        DispatchQueue.global().async { anthropic = fetchAnthropicAPI(); group.leave() }
        group.wait()

        let providers = [codex, claude, cursor, crof, openRouter, openAI, anthropic].compactMap { $0 }
        return .success(UsageState(providers: providers))
    }

    private func render(_ result: Result<UsageState, Error>) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch result {
        case .success(let state):
            let merge = mergedProviders(from: state)
            let providers = merge.providers
            let successfulState = updatedSuccessfulState(from: state)
            lastSuccessfulState = successfulState
            saveDiskCache(successfulState)
            let visible = providers.filter { isEnabled($0.provider) }
            for (i, provider) in visible.enumerated() {
                let isStale = merge.staleProviderIds.contains(provider.provider)
                addProviderRow(for: provider, isStale: isStale, staggerIndex: i)
            }
            if visible.isEmpty {
                stack.addArrangedSubview(textLabel("All providers disabled", size: 12, color: .secondaryLabelColor))
            }
        case .failure:
            if let stale = lastSuccessfulState {
                let visible = stale.providers.filter { isEnabled($0.provider) }
                for (i, provider) in visible.enumerated() {
                    addProviderRow(for: provider, staggerIndex: i)
                }
                stack.addArrangedSubview(staleFooter())
            } else {
                stack.addArrangedSubview(textLabel("Meter unavailable", size: 13, weight: .semibold))
            }
        }

        resizeToFit()
        flashUpdate()
    }

    private func addProviderRow(for provider: Provider, isStale: Bool = false, staggerIndex: Int = 0) {
        let providerRow = row(for: provider, isStale: isStale)
        providerRow.alphaValue = 0
        stack.addArrangedSubview(providerRow)
        let delay = TimeInterval(staggerIndex) * 0.04
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak providerRow] in
            guard let providerRow, providerRow.superview != nil else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                providerRow.animator().alphaValue = 1
            }
        }
    }

    private func mergedProviders(from state: UsageState) -> (providers: [Provider], staleProviderIds: Set<String>) {
        guard let staleProviders = lastSuccessfulState?.providers, !staleProviders.isEmpty else {
            return (state.providers, [])
        }

        var merged: [Provider] = []
        var staleProviderIds: Set<String> = []
        let freshByProvider = providersById(state.providers)
        let staleByProvider = providersById(staleProviders)
        let orderedProviderIds = state.providers.map(\.provider) + staleProviders.map(\.provider).filter { freshByProvider[$0] == nil }

        for providerId in orderedProviderIds {
            let fresh = freshByProvider[providerId]
            let stale = staleByProvider[providerId]

            if let fresh, !fresh.windows.isEmpty {
                merged.append(fresh)
            } else if let stale, !stale.windows.isEmpty {
                merged.append(stale)
                staleProviderIds.insert(providerId)
            } else if let fresh {
                merged.append(fresh)
            }
        }

        return (merged, staleProviderIds)
    }

    private func updatedSuccessfulState(from state: UsageState) -> UsageState {
        guard let previous = lastSuccessfulState?.providers, !previous.isEmpty else {
            return UsageState(providers: state.providers.filter { !$0.windows.isEmpty })
        }

        var byId = providersById(previous)
        for provider in state.providers where !provider.windows.isEmpty {
            byId[provider.provider] = provider
        }

        let freshIds = Set(state.providers.map(\.provider))
        let orderedProviderIds = state.providers.map(\.provider) + previous.map(\.provider).filter { !freshIds.contains($0) }
        let providers = orderedProviderIds.compactMap { byId[$0] }.filter { !$0.windows.isEmpty }
        return UsageState(providers: providers)
    }

    private func providersById(_ providers: [Provider]) -> [String: Provider] {
        var byId: [String: Provider] = [:]
        for provider in providers { byId[provider.provider] = provider }
        return byId
    }

    private func staleFooter() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        let clock = textLabel("⏱", size: 9, color: .tertiaryLabelColor)
        clock.toolTip = "All fetches failed — showing last known data"
        row.addArrangedSubview(clock)
        row.addArrangedSubview(textLabel("stale", size: 9, color: .tertiaryLabelColor))
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

    private func row(for provider: Provider, isStale: Bool = false) -> NSView {
        let row = ClickableStackView()
        row.onTap = { if let url = urlForProvider(provider.provider) { NSWorkspace.shared.open(url) } }
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        if showProviderIcon {
            row.addArrangedSubview(logoView(for: provider.provider))
        }

        let copy = NSStackView()
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 1
        copy.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        if showProviderName {
            let nameRow = NSStackView()
            nameRow.orientation = .horizontal
            nameRow.alignment = .centerY
            nameRow.spacing = 4
            nameRow.addArrangedSubview(textLabel(provider.displayName, size: 12, weight: .semibold))
            if isStale {
                let clock = textLabel("⏱", size: 9, color: .tertiaryLabelColor)
                clock.toolTip = "Live fetch failed — showing last known data"
                nameRow.addArrangedSubview(clock)
            }
            copy.addArrangedSubview(nameRow)
        }

        let visibleWindows = provider.windows.filter { w in
            !(provider.provider == "cursor" && w.label == "On-demand" && !showCursorOnDemand)
        }

        if visibleWindows.isEmpty {
            copy.addArrangedSubview(textLabel(provider.error ?? "No data", size: 11, color: .secondaryLabelColor))
        } else {
            let summary = summaryField(for: visibleWindows, provider: provider)
            copy.addArrangedSubview(summary)
            let barWindows: [UsageWindow] = (provider.provider == "openrouter" || provider.provider == "openai" || provider.provider == "anthropic") ? [] : provider.provider == "codex" ? Array(visibleWindows.prefix(1)) : visibleWindows
            if !barWindows.isEmpty {
                copy.setCustomSpacing(4, after: summary)
                let barContainer = NSView()
                barContainer.translatesAutoresizingMaskIntoConstraints = false
                copy.addArrangedSubview(barContainer)
                for w in barWindows {
                    let bar = UsageBarView(
                        usedFraction: CGFloat(1 - w.leftPercent / 100),
                        color: accentColor(forLeftPercent: w.leftPercent)
                    )
                    bar.translatesAutoresizingMaskIntoConstraints = false
                    barContainer.addSubview(bar)
                    NSLayoutConstraint.activate([
                        bar.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
                        bar.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor),
                        bar.topAnchor.constraint(equalTo: barContainer.topAnchor),
                        bar.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor),
                    ])
                }
                barContainer.widthAnchor.constraint(equalToConstant: providerBarWidth()).isActive = true
                copy.setCustomSpacing(2, after: barContainer)
            }
        }

        row.addArrangedSubview(copy)
        return row
    }

    private func providerBarWidth() -> CGFloat {
        let rowSpacing: CGFloat = showProviderIcon ? 12 : 0
        let iconWidth: CGFloat = showProviderIcon ? 20 : 0
        let horizontalInsets = stack.edgeInsets.left + stack.edgeInsets.right
        let available = window.frame.width - horizontalInsets - iconWidth - rowSpacing
        return max(120, available)
    }

    private let summaryLineFontSize: CGFloat = 11

    private func accentColor(forLeftPercent p: Double) -> NSColor {
        if p < 10 { return .systemRed }
        if p < 20 { return .systemOrange }
        return .labelColor
    }

    private func summaryMutedAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
    }

    private func codexWindowAttributed(_ w: UsageWindow, font: NSFont, muted: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let pct = Int((100 - w.leftPercent).rounded())
        let raw = w.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let isShort = hideCodex5hLabel && raw.caseInsensitiveCompare("5h") == .orderedSame
        let prefix: String = {
            if isShort { return "" }
            if abbreviateCodexWeek, raw.caseInsensitiveCompare("week") == .orderedSame { return "W " }
            return raw.isEmpty ? "" : "\(raw) "
        }()

        let out = NSMutableAttributedString()
        if !prefix.isEmpty {
            out.append(NSAttributedString(string: prefix, attributes: muted))
        }
        out.append(NSAttributedString(string: "\(pct)%", attributes: [
            .font: font,
            .foregroundColor: accentColor(forLeftPercent: w.leftPercent),
        ]))
        if showResetCountdown, let dur = durationText(for: w) {
            out.append(NSAttributedString(string: " \(dur)", attributes: muted))
        }
        return out
    }

    private func summaryField(for windows: [UsageWindow], provider: Provider) -> NSTextField {
        let font = NSFont.monospacedDigitSystemFont(ofSize: summaryLineFontSize, weight: .regular)
        let muted = summaryMutedAttributes(font: font)
        let attr: NSAttributedString = {
            if (provider.provider == "openrouter" || provider.provider == "openai" || provider.provider == "anthropic"), let w = windows.first, let cost = w.used {
                let formatted = String(format: "$%.2f", cost)
                return NSAttributedString(string: formatted, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            }
            if provider.provider == "codex", windows.count > 1 {
                let result = NSMutableAttributedString()
                for (i, w) in windows.enumerated() {
                    if i > 0 { result.append(NSAttributedString(string: "  ", attributes: muted)) }
                    result.append(codexWindowAttributed(w, font: font, muted: muted))
                }
                return result
            }
            guard let w = windows.first else {
                return NSAttributedString(string: provider.error ?? "No data", attributes: muted)
            }
            let out = NSMutableAttributedString()
            out.append(NSAttributedString(string: "\(Int((100 - w.leftPercent).rounded()))%", attributes: [
                .font: font,
                .foregroundColor: accentColor(forLeftPercent: w.leftPercent),
            ]))
            if showUsageFraction, let used = w.used, let limit = w.limit {
                out.append(NSAttributedString(string: "  \(Int(used))/\(Int(limit))", attributes: muted))
            }
            if showResetCountdown, let dur = durationText(for: w) {
                out.append(NSAttributedString(string: "  \(dur)", attributes: muted))
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

    private func durationText(for w: UsageWindow) -> String? {
        guard let resetAt = w.resetAt else { return nil }
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
        for path in logoPaths[provider] ?? [] {
            if let image = NSImage(contentsOfFile: path) {
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
        case "crof": return "⚡"
        case "openrouter": return "◈"
        case "openai": return "◉"
        case "anthropic": return "◆"
        default: return "•"
        }
    }

    private func formatDuration(until epochMilliseconds: Double) -> String {
        let seconds = max(0, Int((epochMilliseconds / 1000) - Date().timeIntervalSince1970))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func resizeToFit() {
        let width: CGFloat = 240
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
