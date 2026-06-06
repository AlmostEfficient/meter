import Foundation

private let providerNames = ["codex", "claude", "cursor", "crof", "openrouter", "openai", "anthropic"]
private let arguments = Array(CommandLine.arguments.dropFirst())
private let argumentSet = Set(arguments)

private struct CLIState: Encodable {
    let timestamp: String
    let providers: [Provider]
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

private func loadProviders(filter: String?) -> [Provider] {
    let names = filter.map { [$0] } ?? providerNames
    let group = DispatchGroup()
    let lock = NSLock()
    var providers = Array<Provider?>(repeating: nil, count: names.count)

    for (index, name) in names.enumerated() {
        guard let fetch = fetcher(for: name) else { continue }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let provider = fetch()
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

private func renderText(_ providers: [Provider]) -> String {
    providers.flatMap(providerLines).joined(separator: "\n")
}

private func renderCompact(_ providers: [Provider]) -> String {
    providers.map { provider in
        guard let window = provider.windows.first else { return "\(provider.displayName) ?" }
        if provider.provider == "openai" || provider.provider == "anthropic" {
            return "\(provider.displayName) \(window.used.map { String(format: "$%.2f", $0) } ?? "?")"
        }
        return "\(provider.displayName) \(Int(window.leftPercent.rounded()))%"
    }.joined(separator: " | ")
}

private func renderOnce(filter: String?, jsonMode: Bool, compactMode: Bool) {
    let providers = loadProviders(filter: filter)
    if jsonMode {
        let state = CLIState(timestamp: timestamp(), providers: providers)
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
    usage-hud [\(providerNames.joined(separator: "|"))] [--json] [--compact] [--watch|-w]

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

            if watchMode {
                while true {
                    print("\u{001B}c", terminator: "")
                    renderOnce(filter: filter, jsonMode: jsonMode, compactMode: compactMode)
                    Thread.sleep(forTimeInterval: 30)
                }
            } else {
                renderOnce(filter: filter, jsonMode: jsonMode, compactMode: compactMode)
            }
        }
    }
}
