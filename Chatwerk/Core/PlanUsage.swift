import Foundation
import Security

/// Fetches the same plan-limit numbers Claude Code's `/usage` shows — the
/// 5-hour window and weekly utilization — from Anthropic's OAuth usage
/// endpoint, authenticated with Claude Code's own login token (read from the
/// Keychain with the user's one-time consent).
///
/// Strictly opt-in: nothing here runs unless the Settings toggle is on.
/// The token is used only for this one request to api.anthropic.com and is
/// never stored or sent anywhere else.
enum PlanUsage {

    struct Window: Decodable {
        var utilization: Double?
        var resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct Snapshot: Decodable {
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
        var sevenDaySonnet: Window?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
        }
    }

    enum FetchError: LocalizedError {
        case noToken
        case http(Int)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .noToken:
                return "Claude Code login not found — open Claude Code once, then try again."
            case .http(401), .http(403):
                return "Claude Code login expired — run any `claude` command to refresh it."
            case .http(let code):
                return "Anthropic returned HTTP \(code)."
            case .badResponse:
                return "Unexpected response from Anthropic."
            }
        }
    }

    /// Claude Code's OAuth access token from the login keychain.
    /// macOS shows a one-time consent prompt for the "Claude Code-credentials"
    /// item; "Always Allow" keeps it silent afterwards.
    private static func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")

    static func fetch() async throws -> Snapshot {
        guard let endpoint else { throw FetchError.badResponse }
        guard let token = accessToken() else { throw FetchError.noToken }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // The endpoint expects a claude-code user agent; identify ourselves in the comment.
        request.setValue("claude-code/2.0 (Chatwerk)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            throw FetchError.badResponse
        }
        return snapshot
    }
}
