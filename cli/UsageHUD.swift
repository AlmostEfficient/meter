import Foundation
import Darwin

private let providerNames = ["codex", "claude", "cursor", "crof", "openrouter", "openai", "anthropic"]
private let arguments = Array(CommandLine.arguments.dropFirst())
private let argumentSet = Set(arguments)
private let cacheVersion = 1
private let cacheTTL: TimeInterval = 180
private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/meter/state.json")
private let lockURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/meter/state.lock")

private struct CLIState: Encodable {
    let timestamp: String
    let providers: [CLIProvider]
}

private struct CLIProvider: Encodable {
    let provider: String
    let displayName: String
    let plan: String?
    let error: String?
    let windows: [UsageWindow]
    let stale: Bool?

    init(_ provider: Provider, stale: Bool = false) {
        self.provider = provider.provider
        self.displayName = provider.displayName
        self.plan = provider.plan
        self.error = provider.error
        self.windows = provider.windows
        self.stale = stale ? true : nil
    }
}

private struct CacheEntry: Codable {
    let ok: Bool
    let timestamp: Double
    let data: Provider
}

private struct CacheFile: Codable {
    let version: Int
    var entries: [String: CacheEntry]

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }

    init(version: Int = cacheVersion, entries: [String: CacheEntry] = [:]) {
        self.version = version
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var version = cacheVersion
        var entries: [String: CacheEntry] = [:]

        for key in container.allKeys {
            if key.stringValue == "_version" {
                version = (try? container.decode(Int.self, forKey: key)) ?? cacheVersion
            } else if providerNames.contains(key.stringValue),
                      let entry = try? container.decode(CacheEntry.self, forKey: key) {
                entries[key.stringValue] = entry
            }
        }

        self.version = version
        self.entries = entries
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(self.version, forKey: DynamicKey(stringValue: "_version")!)
        for (key, entry) in self.entries {
            try container.encode(entry, forKey: DynamicKey(stringValue: key)!)
        }
    }
}

private struct LoadedProvider {
    let provider: Provider
    let stale: Bool
}

private func fetcher(for provider: String) -> (() -> Provider)? {
    switch provider {
    case "codex": return fetchCodex
    case "claude": return fetchClaude
    case "cursor": return fetchCursor
    case "crof": return fetchCrof
    case "openrouter": return fetchOpenRouter
    case "openai": return fetchOpenAI
    case "anthropic": return fetchAnthropicAPI
    default: return nil
    }
}

private func loadCache() -> CacheFile {
    guard let data = try? Data(contentsOf: cacheURL),
          let cache = try? JSONDecoder().decode(CacheFile.self, from: data) else {
        return CacheFile()
    }
    return cache
}

private func saveCache(_ cache: CacheFile) {
    guard let data = try? JSONEncoder().encode(cache) else { return }
    try? FileManager.default.createDirectory(
        at: cacheURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let tempURL = cacheURL.deletingLastPathComponent()
        .appendingPathComponent(".state.\(UUID().uuidString).tmp")
    do {
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            _ = try FileManager.default.replaceItemAt(cacheURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: cacheURL)
        }
    } catch {
        try? FileManager.default.removeItem(at: tempURL)
    }
}

private func isFresh(_ entry: CacheEntry, now: Date) -> Bool {
    return now.timeIntervalSince1970 - entry.timestamp < cacheTTL
}

private func withCacheLock<T>(_ body: () -> T) -> T {
    try? FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { return body() }
    flock(fd, LOCK_EX)
    defer {
        flock(fd, LOCK_UN)
        close(fd)
    }
    return body()
}

private func loadProvider(name: String, bypassCache: Bool) -> LoadedProvider? {
    guard let fetch = fetcher(for: name) else { return nil }

    if bypassCache {
        return LoadedProvider(provider: fetch(), stale: false)
    }

    return withCacheLock {
        let now = Date()
        var cache = loadCache()

        if let entry = cache.entries[name], isFresh(entry, now: now) {
            return LoadedProvider(provider: entry.data, stale: !entry.ok && !entry.data.windows.isEmpty)
        }

        let previousGood = cache.entries[name]?.data
        let live = fetch()
        if live.error == nil || !live.windows.isEmpty {
            cache.entries[name] = CacheEntry(
                ok: true,
                timestamp: now.timeIntervalSince1970,
                data: live
            )
            saveCache(cache)
            return LoadedProvider(provider: live, stale: false)
        }

        if let previousGood, !previousGood.windows.isEmpty {
            cache.entries[name] = CacheEntry(
                ok: false,
                timestamp: now.timeIntervalSince1970,
                data: previousGood
            )
            saveCache(cache)
            return LoadedProvider(provider: previousGood, stale: true)
        }

        cache.entries[name] = CacheEntry(
            ok: false,
            timestamp: now.timeIntervalSince1970,
            data: live
        )
        saveCache(cache)
        return LoadedProvider(provider: live, stale: false)
    }
}

private func loadProviders(filter: String?, bypassCache: Bool) -> [LoadedProvider] {
    let names = filter.map { [$0] } ?? providerNames
    let group = DispatchGroup()
    let lock = NSLock()
    var providers = Array<LoadedProvider?>(repeating: nil, count: names.count)

    for (index, name) in names.enumerated() {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let provider = loadProvider(name: name, bypassCache: bypassCache)
            lock.lock()
            providers[index] = provider
            lock.unlock()
            group.leave()
        }
    }

    group.wait()
    return providers.compactMap { $0 }
}

private func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

private func formatDateTime(_ epochMilliseconds: Double) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d 'at' HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: epochMilliseconds / 1000))
}

private func bar(leftPercent: Double, width: Int = 16) -> String {
    let filled = Int((leftPercent / 100 * Double(width)).rounded())
    return String(repeating: "#", count: max(0, min(width, filled)))
        + String(repeating: "-", count: max(0, width - filled))
}

private func providerLines(_ provider: Provider) -> [String] {
    let plan = provider.plan.map { " (\($0))" } ?? ""
    if let error = provider.error, provider.windows.isEmpty {
        return ["\(provider.displayName)\(plan): \(error)"]
    }

    var lines = ["\(provider.displayName)\(plan)"]
    for window in provider.windows {
        if provider.provider == "openrouter" {
            let remaining = window.used.map { String(format: "$%.2f remaining", $0) } ?? "No data"
            lines.append("  \(remaining)")
        } else if provider.provider == "openai" || provider.provider == "anthropic" {
            let spent = window.used.map { String(format: "$%.2f spent", $0) } ?? "No data"
            lines.append("  \(window.label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(spent)")
        } else {
            let reset = window.resetAt.map { ", resets \(formatDateTime($0))" } ?? ""
            let usage: String
            if let used = window.used, let limit = window.limit {
                usage = " (\(Int(used))/\(Int(limit)))"
            } else {
                usage = ""
            }
            lines.append(
                "  \(window.label.padding(toLength: 9, withPad: " ", startingAt: 0)) [\(bar(leftPercent: window.leftPercent))] \(Int(window.leftPercent.rounded()))% left\(usage)\(reset)"
            )
        }
    }

    if let error = provider.error {
        lines.append("  warning: \(error)")
    }
    return lines
}

private func renderText(_ providers: [LoadedProvider]) -> String {
    providers.flatMap { loaded in
        var lines = providerLines(loaded.provider)
        if loaded.stale, !lines.isEmpty {
            lines[0] += " stale"
        }
        return lines
    }.joined(separator: "\n")
}

private func renderCompact(_ providers: [LoadedProvider]) -> String {
    providers.map { provider in
        let suffix = provider.stale ? " stale" : ""
        guard let window = provider.provider.windows.first else { return "\(provider.provider.displayName) ?\(suffix)" }
        if provider.provider.provider == "openai" || provider.provider.provider == "anthropic" {
            return "\(provider.provider.displayName) \(window.used.map { String(format: "$%.2f", $0) } ?? "?")\(suffix)"
        }
        return "\(provider.provider.displayName) \(Int(window.leftPercent.rounded()))%\(suffix)"
    }.joined(separator: " | ")
}

private func renderOnce(filter: String?, jsonMode: Bool, compactMode: Bool, bypassCache: Bool) {
    let providers = loadProviders(filter: filter, bypassCache: bypassCache)
    if jsonMode {
        let state = CLIState(
            timestamp: timestamp(),
            providers: providers.map { CLIProvider($0.provider, stale: $0.stale) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state), let output = String(data: data, encoding: .utf8) {
            print(output)
        }
        return
    }

    print(compactMode ? renderCompact(providers) : renderText(providers))
}

private func printHelp() {
    print("""
    usage-hud [\(providerNames.joined(separator: "|"))] [--json] [--compact] [--watch|-w] [--no-cache]

    Config files:
      ~/.config/meter/cursor-cookie
      ~/.config/meter/crof
      ~/.config/meter/openrouter
      ~/.config/meter/openai
      ~/.config/meter/anthropic
    """)
}

@main
private enum UsageHUD {
    static func main() {
        if argumentSet.contains("--help") || argumentSet.contains("-h") {
            printHelp()
        } else {
            let filter = arguments.first { providerNames.contains($0) }
            let jsonMode = argumentSet.contains("--json")
            let compactMode = argumentSet.contains("--compact")
            let watchMode = argumentSet.contains("--watch") || argumentSet.contains("-w")
            let bypassCache = argumentSet.contains("--no-cache")

            if watchMode {
                while true {
                    print("\u{001B}c", terminator: "")
                    renderOnce(filter: filter, jsonMode: jsonMode, compactMode: compactMode, bypassCache: bypassCache)
                    Thread.sleep(forTimeInterval: 30)
                }
            } else {
                renderOnce(filter: filter, jsonMode: jsonMode, compactMode: compactMode, bypassCache: bypassCache)
            }
        }
    }
}
