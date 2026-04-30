import Foundation

let environment = ProcessInfo.processInfo.environment
let overlayRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let logoPaths = [
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
    "crof": [
        "\(overlayRoot)/assets/crof.png",
    ],
    "openrouter": [
        "\(overlayRoot)/assets/openrouter.png",
    ],
    "openai": [
        "\(overlayRoot)/assets/openai.png",
    ],
    "anthropic": [
        "\(overlayRoot)/assets/anthropic.png",
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

func syncFetch(url: URL, headers: [String: String] = [:], timeoutInterval: TimeInterval = 5) throws -> Data {
    var result: Result<Data, Error>?
    let sem = DispatchSemaphore(value: 0)
    var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
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

func clampPercent(_ v: Double) -> Double { max(0, min(100, v)) }

func isoToEpochMs(_ s: String?) -> Double? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s).map { $0.timeIntervalSince1970 * 1000 }
}

func epochSecToMs(_ v: Double?) -> Double? {
    guard let v, v > 0 else { return nil }
    return v * 1000
}

func titleCase(_ s: String) -> String {
    s.prefix(1).uppercased() + s.dropFirst()
}

func window(label: String, usedPercent: Double, resetAtMs: Double?, used: Double? = nil, limit: Double? = nil) -> UsageWindow {
    UsageWindow(label: label, leftPercent: clampPercent(100 - clampPercent(usedPercent)), resetAt: resetAtMs, used: used, limit: limit)
}

// MARK: - Provider URLs

let providerURLs: [String: URL] = [
    "codex": URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!,
    "claude": URL(string: "https://claude.ai/settings/usage")!,
    "cursor": URL(string: "https://cursor.com/dashboard/usage")!,
    "crof": URL(string: "https://crof.ai/dashboard")!,
    "openrouter": URL(string: "https://openrouter.ai/settings/credits")!,
    "openai": URL(string: "https://platform.openai.com/settings/organization/billing/overview")!,
    "anthropic": URL(string: "https://platform.claude.com/settings/billing")!
]

func urlForProvider(_ providerID: String) -> URL? {
    return providerURLs[providerID]
}
