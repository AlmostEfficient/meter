#!/usr/bin/env swift

import AppKit
import Foundation

private let environment = ProcessInfo.processInfo.environment
private let overlayRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
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

struct UsageState {
    let providers: [Provider]
}

struct Provider: Codable {
    let provider: String
    let displayName: String
    let plan: String?
    let error: String?
    let windows: [UsageWindow]
}

struct UsageWindow: Codable {
    let label: String
    let leftPercent: Double
    let resetAt: Double?
    let used: Double?
    let limit: Double?
}

// MARK: - Fetch helpers

private func syncFetch(url: URL, headers: [String: String] = [:]) throws -> Data {
    var result: Result<Data, Error>?
    let sem = DispatchSemaphore(value: 0)
    var request = URLRequest(url: url, timeoutInterval: 5)
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            result = .failure(error)
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(NSError(domain: "Meter", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
        } else if let data = data {
            result = .success(data)
        } else {
            result = .failure(NSError(domain: "Meter", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data"]))
        }
        sem.signal()
    }.resume()
    sem.wait()
    return try result!.get()
}

private func clampPercent(_ v: Double) -> Double { max(0, min(100, v)) }

private func isoToEpochMs(_ s: String?) -> Double? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s).map { $0.timeIntervalSince1970 * 1000 }
}

private func epochSecToMs(_ v: Double?) -> Double? {
    guard let v, v > 0 else { return nil }
    return v * 1000
}

private func titleCase(_ s: String) -> String {
    s.prefix(1).uppercased() + s.dropFirst()
}

private func window(label: String, usedPercent: Double, resetAtMs: Double?, used: Double? = nil, limit: Double? = nil) -> UsageWindow {
    UsageWindow(label: label, leftPercent: clampPercent(100 - clampPercent(usedPercent)), resetAt: resetAtMs, used: used, limit: limit)
}

// MARK: - Claude

private struct ClaudeCredFile: Decodable {
    struct OAuth: Decodable {
        let accessToken: String?
        let subscriptionType: String?
        let expiresAt: Double?
    }
    let claudeAiOauth: OAuth?
}

private func claudePlan(_ subscriptionType: String?) -> String? {
    guard let s = subscriptionType, !s.isEmpty else { return nil }
    let lower = s.lowercased()
    if lower.contains("api") { return nil }
    if lower.contains("max") { return "Max" }
    if lower.contains("pro") { return "Pro" }
    if lower.contains("team") { return "Team" }
    return titleCase(s)
}

private func readClaudeCredentials() -> (token: String, subscriptionType: String?)? {
    let now = Date().timeIntervalSince1970 * 1000
    let decoder = JSONDecoder()

    func parse(_ data: Data) -> ClaudeCredFile.OAuth? {
        guard let f = try? decoder.decode(ClaudeCredFile.self, from: data),
              let oauth = f.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty else { return nil }
        if let exp = oauth.expiresAt, exp <= now { return nil }
        return oauth
    }

    var keychainOAuth: ClaudeCredFile.OAuth?
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    if (try? proc.run()) != nil {
        proc.waitUntilExit()
        if proc.terminationStatus == 0,
           let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           let data = raw.data(using: .utf8) {
            keychainOAuth = parse(data)
        }
    }

    var fileOAuth: ClaudeCredFile.OAuth?
    let filePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    if let data = try? Data(contentsOf: filePath) {
        fileOAuth = parse(data)
    }

    if let oauth = keychainOAuth {
        return (oauth.accessToken!, oauth.subscriptionType ?? fileOAuth?.subscriptionType)
    }
    if let oauth = fileOAuth {
        return (oauth.accessToken!, oauth.subscriptionType)
    }
    return nil
}

private struct ClaudeHudCache: Decodable {
    struct Payload: Decodable {
        let fiveHour: Double?
        let fiveHourResetAt: String?
        let sevenDay: Double?
        let sevenDayResetAt: String?
        let planName: String?
    }
    let data: Payload?
}

private func readClaudeHudFallback() -> Provider? {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/plugins/claude-hud/.usage-cache.json")
    guard let data = try? Data(contentsOf: path),
          let cache = try? JSONDecoder().decode(ClaudeHudCache.self, from: data),
          let d = cache.data else { return nil }
    var windows: [UsageWindow] = []
    if let pct = d.fiveHour {
        windows.append(window(label: "5h", usedPercent: pct, resetAtMs: isoToEpochMs(d.fiveHourResetAt)))
    }
    if let pct = d.sevenDay {
        windows.append(window(label: "Week", usedPercent: pct, resetAtMs: isoToEpochMs(d.sevenDayResetAt)))
    }
    guard !windows.isEmpty else { return nil }
    return Provider(provider: "claude", displayName: "Claude", plan: d.planName, error: nil, windows: windows)
}

private struct ClaudeUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
    let fiveHour: Window?
    let sevenDay: Window?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private func fetchClaude() -> Provider {
    let fallback = readClaudeHudFallback()

    guard let creds = readClaudeCredentials() else {
        return fallback ?? Provider(provider: "claude", displayName: "Claude", plan: nil, error: "No credentials", windows: [])
    }
    let plan = claudePlan(creds.subscriptionType) ?? fallback?.plan
    guard plan != nil else {
        return fallback ?? Provider(provider: "claude", displayName: "Claude", plan: nil, error: "No subscription", windows: [])
    }

    do {
        let data = try syncFetch(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: [
                "Authorization": "Bearer \(creds.token)",
                "Accept": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "Meter",
            ]
        )
        let resp = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        var windows: [UsageWindow] = []
        if let w = resp.fiveHour, let pct = w.utilization {
            windows.append(window(label: "5h", usedPercent: pct, resetAtMs: isoToEpochMs(w.resetsAt)))
        }
        if let w = resp.sevenDay, let pct = w.utilization {
            windows.append(window(label: "Week", usedPercent: pct, resetAtMs: isoToEpochMs(w.resetsAt)))
        }
        return Provider(provider: "claude", displayName: "Claude", plan: plan, error: nil, windows: windows)
    } catch {
        return Provider(provider: "claude", displayName: "Claude", plan: plan, error: error.localizedDescription, windows: [])
    }
}

// MARK: - Codex

private struct CodexAuthFile: Decodable {
    struct Tokens: Decodable {
        let accessToken: String?
        let accountId: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
        }
    }
    let tokens: Tokens?
    let accessToken: String?
    enum CodingKeys: String, CodingKey {
        case tokens
        case accessToken = "access_token"
    }
}

private func jwtAccountId(_ token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let pad = b64.count % 4
    if pad > 0 { b64 += String(repeating: "=", count: 4 - pad) }
    guard let data = Data(base64Encoded: b64),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let auth = json["https://api.openai.com/auth"] as? [String: Any],
          let id = auth["chatgpt_account_id"] as? String else { return nil }
    return id
}

private struct CodexUsageResponse: Decodable {
    struct RateLimit: Decodable {
        let primaryWindow: WindowData?
        let secondaryWindow: WindowData?
        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }
    struct WindowData: Decodable {
        let usedPercent: Double?
        let resetAt: Double?
        let limitWindowSeconds: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }
    let rateLimit: RateLimit?
    let planType: String?
    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case planType = "plan_type"
    }
}

private func fetchCodex() -> Provider {
    let authPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    guard let authData = try? Data(contentsOf: authPath),
          let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: authData) else {
        return Provider(provider: "codex", displayName: "Codex", plan: nil, error: "No auth file", windows: [])
    }
    guard let token = auth.tokens?.accessToken ?? auth.accessToken else {
        return Provider(provider: "codex", displayName: "Codex", plan: nil, error: "No token", windows: [])
    }
    let accountId = auth.tokens?.accountId ?? jwtAccountId(token)

    do {
        var headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": "Meter",
        ]
        if let id = accountId { headers["ChatGPT-Account-Id"] = id }

        let data = try syncFetch(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
        let resp = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        let plan = resp.planType.map { titleCase($0) }

        var windows: [UsageWindow] = []
        if let w = resp.rateLimit?.primaryWindow, let pct = w.usedPercent {
            let secs = w.limitWindowSeconds ?? 18_000
            windows.append(window(label: "\(Int(secs / 3600))h", usedPercent: pct, resetAtMs: epochSecToMs(w.resetAt)))
        }
        if let w = resp.rateLimit?.secondaryWindow, let pct = w.usedPercent {
            let secs = w.limitWindowSeconds ?? 604_800
            let label = secs >= 604_800 ? "Week" : secs >= 86_400 ? "Day" : "\(Int(secs / 3600))h"
            windows.append(window(label: label, usedPercent: pct, resetAtMs: epochSecToMs(w.resetAt)))
        }
        return Provider(provider: "codex", displayName: "Codex", plan: plan, error: nil, windows: windows)
    } catch {
        return Provider(provider: "codex", displayName: "Codex", plan: nil, error: error.localizedDescription, windows: [])
    }
}

// MARK: - Cursor

private struct CursorUsageResponse: Decodable {
    struct IndividualUsage: Decodable {
        let plan: PlanData?
        let onDemand: PlanData?
    }
    struct PlanData: Decodable {
        let enabled: Bool?
        let used: Double?
        let limit: Double?
        let totalPercentUsed: Double?
    }
    let individualUsage: IndividualUsage?
    let billingCycleEnd: String?
    let membershipType: String?
}

private func fetchCursor() -> Provider {
    let cookiePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/usage-hud/cursor-cookie")
    let cookie = environment["CURSOR_COOKIE"]
        ?? (try? String(contentsOf: cookiePath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let cookie, !cookie.isEmpty else {
        return Provider(provider: "cursor", displayName: "Cursor", plan: nil,
                        error: "No cookie — save to ~/.config/usage-hud/cursor-cookie", windows: [])
    }

    do {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let data = try syncFetch(
            url: URL(string: "https://cursor.com/api/usage-summary?ts=\(ts)")!,
            headers: [
                "Accept": "application/json",
                "Cookie": cookie,
                "Cache-Control": "no-cache",
                "Pragma": "no-cache",
                "Referer": "https://cursor.com/dashboard/usage",
                "User-Agent": "Meter",
            ]
        )
        let resp = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
        let plan = resp.membershipType.map { titleCase($0) }
        let resetMs = isoToEpochMs(resp.billingCycleEnd)

        var windows: [UsageWindow] = []
        if let p = resp.individualUsage?.plan, p.enabled == true {
            let used = p.used ?? 0
            let limit = p.limit ?? 0
            let pct = limit > 0 ? (used / limit) * 100 : (p.totalPercentUsed ?? 0)
            windows.append(window(label: "Month", usedPercent: pct, resetAtMs: resetMs,
                                  used: used, limit: limit > 0 ? limit : nil))
        }
        if let od = resp.individualUsage?.onDemand, od.enabled == true {
            let used = od.used ?? 0
            let limit = od.limit ?? 0
            let pct = limit > 0 ? (used / limit) * 100 : 0
            windows.append(window(label: "On-demand", usedPercent: pct, resetAtMs: resetMs,
                                  used: used, limit: limit > 0 ? limit : nil))
        }
        return Provider(provider: "cursor", displayName: "Cursor", plan: plan, error: nil, windows: windows)
    } catch {
        return Provider(provider: "cursor", displayName: "Cursor", plan: nil, error: error.localizedDescription, windows: [])
    }
}

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
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async { codex = fetchCodex(); group.leave() }
        group.enter()
        DispatchQueue.global().async { claude = fetchClaude(); group.leave() }
        group.enter()
        DispatchQueue.global().async { cursor = fetchCursor(); group.leave() }
        group.wait()

        let providers = [codex, claude, cursor].compactMap { $0 }
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
            for provider in visible {
                let isStale = merge.staleProviderIds.contains(provider.provider)
                stack.addArrangedSubview(row(for: provider, isStale: isStale))
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
        row.addArrangedSubview(textLabel("⏱", size: 9, color: .tertiaryLabelColor))
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
        let row = NSStackView()
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

        if showProviderName {
            let nameRow = NSStackView()
            nameRow.orientation = .horizontal
            nameRow.alignment = .centerY
            nameRow.spacing = 4
            nameRow.addArrangedSubview(textLabel(provider.displayName, size: 12, weight: .semibold))
            if isStale {
                nameRow.addArrangedSubview(textLabel("⏱", size: 9, color: .tertiaryLabelColor))
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
            copy.setCustomSpacing(4, after: summary)
            let barWindows = provider.provider == "codex" ? Array(visibleWindows.prefix(1)) : visibleWindows
            for w in barWindows {
                let bar = UsageBarView(
                    usedFraction: CGFloat(1 - w.leftPercent / 100),
                    color: accentColor(forLeftPercent: w.leftPercent)
                )
                bar.translatesAutoresizingMaskIntoConstraints = false
                copy.addArrangedSubview(bar)
                bar.widthAnchor.constraint(equalTo: copy.widthAnchor).isActive = true
                copy.setCustomSpacing(2, after: bar)
            }
        }

        row.addArrangedSubview(copy)
        return row
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
        if showResetCountdown {
            out.append(NSAttributedString(string: " \(durationText(for: w))", attributes: muted))
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
            if showResetCountdown {
                out.append(NSAttributedString(string: "  \(durationText(for: w))", attributes: muted))
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

    private func durationText(for w: UsageWindow) -> String {
        guard let resetAt = w.resetAt else { return "unknown" }
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
