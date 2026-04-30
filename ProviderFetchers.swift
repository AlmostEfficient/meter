import Foundation

private func nextDailyResetMs(hour: Int) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = hour; comps.minute = 0; comps.second = 0
    var date = cal.date(from: comps)!
    if date <= Date() { date = cal.date(byAdding: .day, value: 1, to: date)! }
    return date.timeIntervalSince1970 * 1000
}

private func readKeychainPassword(service: String, account: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    if (try? proc.run()) != nil {
        proc.waitUntilExit()
        if proc.terminationStatus == 0,
           let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
    }
    return nil
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

func fetchClaude() -> Provider {
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

func fetchCodex() -> Provider {
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

func fetchCursor() -> Provider {
    let cookiePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/meter/cursor-cookie")
    let cookie = environment["CURSOR_COOKIE"]
        ?? (try? String(contentsOf: cookiePath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let cookie, !cookie.isEmpty else {
        return Provider(provider: "cursor", displayName: "Cursor", plan: nil,
                        error: "No cookie — save to ~/.config/meter/cursor-cookie or set CURSOR_COOKIE env var", windows: [])
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

// MARK: - Crof

private struct CrofUsageResponse: Decodable {
    let usableRequests: Int?
    let credits: Double?
    enum CodingKeys: String, CodingKey {
        case usableRequests = "usable_requests"
        case credits
    }
}

func fetchCrof() -> Provider {
    let sessionPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/meter/crof")
    let keychainSession = readKeychainPassword(service: "Crof-credentials", account: "crof")
    let session = keychainSession
        ?? environment["CROF_SESSION"]
        ?? environment["CROF_API_KEY"]
        ?? (try? String(contentsOf: sessionPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let session, !session.isEmpty else {
        return Provider(provider: "crof", displayName: "Crof", plan: nil,
                         error: "No session — set CROF_SESSION or save to ~/.config/meter/crof", windows: [])
    }

    do {
        let data = try syncFetch(
            url: URL(string: "https://crof.ai/usage_api/")!,
            headers: [
                "Authorization": "Bearer \(session)",
                "Accept": "application/json",
                "Referer": "https://crof.ai/dashboard",
                "User-Agent": "Meter",
            ]
        )
        let resp = try JSONDecoder().decode(CrofUsageResponse.self, from: data)

        var windows: [UsageWindow] = []
        if let remaining = resp.usableRequests {
            let limit = 500.0
            let leftPct = Double(remaining) / 500.0 * 100.0
            windows.append(UsageWindow(label: "Requests", leftPercent: leftPct, resetAt: nextDailyResetMs(hour: 5), used: limit - Double(remaining), limit: limit))
        }
        return Provider(provider: "crof", displayName: "Crof", plan: "hobby", error: nil, windows: windows)
    } catch {
        return Provider(provider: "crof", displayName: "Crof", plan: nil, error: error.localizedDescription, windows: [])
    }
}

// MARK: - OpenRouter

private struct OpenRouterCreditsResponse: Decodable {
    struct Data: Decodable {
        let totalCredits: Double?
        let totalUsage: Double?
        enum CodingKeys: String, CodingKey {
            case totalCredits = "total_credits"
            case totalUsage = "total_usage"
        }
    }
    let data: Data?
}

func fetchOpenRouter() -> Provider {
    let keyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/meter/openrouter")
    let apiKey = environment["OPENROUTER_API_KEY"]
        ?? (try? String(contentsOf: keyPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let apiKey, !apiKey.isEmpty else {
        return Provider(provider: "openrouter", displayName: "OpenRouter", plan: nil,
                        error: "No key — set OPENROUTER_API_KEY or save to ~/.config/meter/openrouter", windows: [])
    }

    do {
        let data = try syncFetch(
            url: URL(string: "https://openrouter.ai/api/v1/credits")!,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json",
                "User-Agent": "Meter",
            ]
        )
        let resp = try JSONDecoder().decode(OpenRouterCreditsResponse.self, from: data)
        guard let total = resp.data?.totalCredits, let usage = resp.data?.totalUsage, total > 0 else {
            return Provider(provider: "openrouter", displayName: "OpenRouter", plan: nil, error: "No data", windows: [])
        }
        let remaining = total - usage
        let usedPct = (usage / total) * 100
        let w = UsageWindow(label: "Credits", leftPercent: clampPercent(100 - usedPct), resetAt: nil,
                            used: (remaining * 100).rounded() / 100, limit: (total * 100).rounded() / 100)
        return Provider(provider: "openrouter", displayName: "OpenRouter", plan: nil, error: nil, windows: [w])
    } catch {
        return Provider(provider: "openrouter", displayName: "OpenRouter", plan: nil, error: error.localizedDescription, windows: [])
    }
}

// MARK: - OpenAI API

private func startOfMonthUnix() -> Int {
    let cal = Calendar(identifier: .gregorian)
    var comps = cal.dateComponents([.year, .month], from: Date())
    comps.day = 1; comps.hour = 0; comps.minute = 0; comps.second = 0
    return Int(cal.date(from: comps)!.timeIntervalSince1970)
}

private func startOfMonthISO() -> String {
    let cal = Calendar(identifier: .gregorian)
    var comps = cal.dateComponents([.year, .month], from: Date())
    comps.day = 1; comps.hour = 0; comps.minute = 0; comps.second = 0
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: cal.date(from: comps)!)
}

private func nowISO() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date())
}

private struct OpenAICostsResponse: Decodable {
    struct Bucket: Decodable {
        let results: [CostResult]?
    }
    struct CostResult: Decodable {
        struct Amount: Decodable {
            let value: String?
        }
        let amount: Amount?
    }
    let data: [Bucket]?
}

func fetchOpenAI() -> Provider {
    let keyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/meter/openai")
    let apiKey = environment["OPENAI_ADMIN_KEY"]
        ?? readKeychainPassword(service: "OpenAI-Admin", account: "openai")
        ?? (try? String(contentsOf: keyPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let apiKey, !apiKey.isEmpty else {
        return Provider(provider: "openai", displayName: "OpenAI", plan: nil,
                        error: "No key — set OPENAI_ADMIN_KEY or save to ~/.config/meter/openai", windows: [])
    }

    let start = startOfMonthUnix()
    let now = Int(Date().timeIntervalSince1970)

    do {
        let data = try syncFetch(
            url: URL(string: "https://api.openai.com/v1/organization/costs?start_time=\(start)&end_time=\(now)&bucket_width=1d&limit=31")!,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "User-Agent": "Meter",
            ],
            timeoutInterval: 15
        )
        let resp = try JSONDecoder().decode(OpenAICostsResponse.self, from: data)
        let results = resp.data?.flatMap { $0.results ?? [] } ?? []
        let total = results.compactMap { Double($0.amount?.value ?? "") }.reduce(0.0, +)
        let w = UsageWindow(label: "Month", leftPercent: 0, resetAt: nil,
                            used: (total * 100).rounded() / 100, limit: nil)
        return Provider(provider: "openai", displayName: "OpenAI", plan: nil, error: nil, windows: [w])
    } catch {
        return Provider(provider: "openai", displayName: "OpenAI", plan: nil, error: error.localizedDescription, windows: [])
    }
}

// MARK: - Anthropic API

private struct AnthropicCostResponse: Decodable {
    struct Bucket: Decodable {
        let results: [CostResult]?
    }
    struct CostResult: Decodable {
        let amount: String?
        let currency: String?
    }
    let data: [Bucket]?
}

func fetchAnthropicAPI() -> Provider {
    let keyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/meter/anthropic")
    let apiKey = environment["ANTHROPIC_ADMIN_KEY"]
        ?? readKeychainPassword(service: "meter-claude-admin-key", account: "meter-claude-admin-key")
        ?? (try? String(contentsOf: keyPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let apiKey, !apiKey.isEmpty else {
        return Provider(provider: "anthropic", displayName: "Anthropic", plan: nil,
                        error: "No key — set ANTHROPIC_ADMIN_KEY or save to ~/.config/meter/anthropic", windows: [])
    }

    do {
        let data = try syncFetch(
            url: URL(string: "https://api.anthropic.com/v1/organizations/cost_report?starting_at=\(startOfMonthISO())&ending_at=\(nowISO())")!,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "Accept": "application/json",
                "User-Agent": "Meter",
            ]
        )
        let resp = try JSONDecoder().decode(AnthropicCostResponse.self, from: data)
        let totalCents = resp.data?.flatMap { $0.results ?? [] }.compactMap { Double($0.amount ?? "") }.reduce(0, +) ?? 0
        let totalDollars = (totalCents / 100.0 * 100).rounded() / 100
        let w = UsageWindow(label: "Month", leftPercent: 0, resetAt: nil,
                            used: totalDollars, limit: nil)
        return Provider(provider: "anthropic", displayName: "Anthropic", plan: nil, error: nil, windows: [w])
    } catch {
        return Provider(provider: "anthropic", displayName: "Anthropic", plan: nil, error: error.localizedDescription, windows: [])
    }
}
