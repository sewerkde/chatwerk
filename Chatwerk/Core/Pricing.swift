import Foundation

/// Estimated Claude API pricing, $ per million tokens. Longest prefix wins.
/// Costs shown in the app are estimates: cache writes are billed at 1.25×
/// input (5m TTL) and cache reads at 0.1× input; actual invoices can differ
/// (introductory pricing, batch discounts, negotiated rates).
enum Pricing {

    struct Rate {
        let input: Double   // $ / MTok
        let output: Double  // $ / MTok
        var cacheRead: Double { input * 0.1 }
        var cacheWrite: Double { input * 1.25 }
    }

    /// Ordered longest-prefix-first so specific versions match before families.
    private static let rates: [(prefix: String, rate: Rate)] = [
        ("claude-fable-5", Rate(input: 10, output: 50)),
        ("claude-mythos", Rate(input: 10, output: 50)),
        ("claude-opus-4-1", Rate(input: 15, output: 75)),
        ("claude-opus-4-0", Rate(input: 15, output: 75)),
        ("claude-opus-4-2", Rate(input: 15, output: 75)),   // dated claude-opus-4-2025… ids
        ("claude-opus", Rate(input: 5, output: 25)),        // opus-4-5 … opus-5
        ("claude-sonnet", Rate(input: 3, output: 15)),
        ("claude-3-7-sonnet", Rate(input: 3, output: 15)),
        ("claude-3-5-sonnet", Rate(input: 3, output: 15)),
        ("claude-haiku-4-5", Rate(input: 1, output: 5)),
        ("claude-3-5-haiku", Rate(input: 0.8, output: 4)),
        ("claude-3-haiku", Rate(input: 0.25, output: 1.25)),
    ]

    static func rate(for model: String) -> Rate? {
        rates.first { model.hasPrefix($0.prefix) }?.rate
    }

    /// Estimated cost in dollars; nil when the model is unknown.
    static func cost(model: String, input: Int64, output: Int64,
                     cacheRead: Int64, cacheWrite: Int64) -> Double? {
        guard let r = rate(for: model) else { return nil }
        let m = 1_000_000.0
        return Double(input) / m * r.input
            + Double(output) / m * r.output
            + Double(cacheRead) / m * r.cacheRead
            + Double(cacheWrite) / m * r.cacheWrite
    }

    static func dollars(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value)
            : value >= 1 ? String(format: "$%.2f", value)
            : String(format: "$%.3f", value)
    }
}

extension Int64 {
    /// Compact token formatting: 1.2k, 45M …
    var tokenString: String {
        switch self {
        case ..<1_000: return "\(self)"
        case ..<1_000_000: return String(format: "%.1fk", Double(self) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(self) / 1_000_000)
        default: return String(format: "%.2fB", Double(self) / 1_000_000_000)
        }
    }
}
