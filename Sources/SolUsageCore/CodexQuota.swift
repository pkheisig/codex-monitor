import Foundation

/// A Codex subscription quota window as returned by the authenticated
/// `wham/usage` endpoint. This is intentionally separate from local token
/// usage: subscription limits are account telemetry, not API-equivalent cost.
public struct CodexQuotaWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let windowSeconds: Int?
    public let resetsAt: Date?
    public let usageKnown: Bool

    public init(
        id: String,
        title: String,
        usedPercent: Double,
        windowSeconds: Int?,
        resetsAt: Date?,
        usageKnown: Bool = true)
    {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.windowSeconds = windowSeconds
        self.resetsAt = resetsAt
        self.usageKnown = usageKnown
    }

    public var remainingPercent: Double {
        guard usageKnown else { return 0 }
        return max(0, min(100, 100 - usedPercent))
    }

    public func pace(now: Date = Date()) -> CodexQuotaPace? {
        guard usageKnown,
              let resetsAt,
              let windowSeconds,
              windowSeconds > 0
        else { return nil }

        let duration = TimeInterval(windowSeconds)
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0, timeUntilReset <= duration else { return nil }

        let elapsed = max(0, min(duration, duration - timeUntilReset))
        let expected = elapsed / duration * 100
        let actual = max(0, min(100, usedPercent))
        let deficit = max(0, actual - expected)

        var runsOutIn: TimeInterval?
        if actual >= 100 {
            runsOutIn = 0
        } else if elapsed > 0, actual > 0 {
            let exhaustion = (100 - actual) / (actual / elapsed)
            if exhaustion < timeUntilReset {
                runsOutIn = exhaustion
            }
        }

        return CodexQuotaPace(
            expectedUsedPercent: expected,
            deficitPercent: deficit,
            runsOutIn: runsOutIn,
            willLastToReset: runsOutIn == nil)
    }
}

public struct CodexQuotaPace: Equatable, Sendable {
    public let expectedUsedPercent: Double
    public let deficitPercent: Double
    public let runsOutIn: TimeInterval?
    public let willLastToReset: Bool

    public init(
        expectedUsedPercent: Double,
        deficitPercent: Double,
        runsOutIn: TimeInterval?,
        willLastToReset: Bool)
    {
        self.expectedUsedPercent = expectedUsedPercent
        self.deficitPercent = deficitPercent
        self.runsOutIn = runsOutIn
        self.willLastToReset = willLastToReset
    }
}

public struct CodexQuotaSnapshot: Codable, Equatable, Sendable {
    /// Stable Codex account identifier from the authenticated response. It is
    /// stored only in the local snapshot so a switched account never displays
    /// the previous account's cached limits.
    public let accountID: String?
    public let accountEmail: String?
    public let plan: String?
    public let windows: [CodexQuotaWindow]
    public let codeReview: CodexQuotaWindow?
    public let creditsRemaining: Double?
    public let fetchedAt: Date

    public init(
        accountID: String? = nil,
        accountEmail: String?,
        plan: String?,
        windows: [CodexQuotaWindow],
        codeReview: CodexQuotaWindow? = nil,
        creditsRemaining: Double?,
        fetchedAt: Date)
    {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.plan = plan
        self.windows = windows
        self.codeReview = codeReview
        self.creditsRemaining = creditsRemaining
        self.fetchedAt = fetchedAt
    }

    public var weekly: CodexQuotaWindow? {
        windows.first { $0.id == "codex-weekly" }
            ?? windows.first { ($0.windowSeconds ?? 0) >= 6 * 24 * 60 * 60 }
    }

    public var sparkWeekly: CodexQuotaWindow? {
        windows.first { $0.id == "codex-spark-weekly" }
    }
}

/// Persists the most recent successful account-quota response so the panel
/// can still show the last known limits when the network is temporarily down.
public final class CodexQuotaStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager = FileManager.default

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let support = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SolUsageMonitor", isDirectory: true)
        self.fileURL = support.appendingPathComponent("codex-quota.json")
        protectLocalStorage()
    }

    public func load() -> CodexQuotaSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexQuotaSnapshot.self, from: data)
    }

    public func save(_ snapshot: CodexQuotaSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fileURL.deletingLastPathComponent().path)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Quota persistence is supplemental; a failed write must not stop monitoring.
        }
    }

    private func protectLocalStorage() {
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}

public enum CodexQuotaFetchError: LocalizedError, Sendable {
    case credentialsUnavailable
    case invalidCredentials
    case unauthorized
    case server(Int)
    case invalidResponse
    case network

    public var errorDescription: String? {
        switch self {
        case .credentialsUnavailable:
            return "Codex account limits unavailable: auth.json was not found."
        case .invalidCredentials:
            return "Codex account limits unavailable: auth.json has no access token."
        case .unauthorized:
            return "Codex account limits unavailable: Codex authentication needs refresh."
        case let .server(code):
            return "Codex account limits unavailable (HTTP \(code))."
        case .invalidResponse:
            return "Codex account limits unavailable: invalid usage response."
        case .network:
            return "Codex account limits unavailable: network request failed."
        }
    }
}

/// Reads the current Codex OAuth token from the normal local auth file and
/// fetches the same account quota endpoint used by CodexBar.
public struct CodexQuotaFetcher: Sendable {
    public init() {}

    /// Returns only the non-secret account id from the local auth file. This
    /// lets the app validate a cached snapshot after an account switch; the
    /// access token is never returned or persisted here.
    public static func localAccountID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        try? Self.loadCredentials(environment: environment).accountID
    }

    public func fetch(now: Date = Date()) async throws -> CodexQuotaSnapshot {
        let credentials = try Self.loadCredentials()
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexMonitor", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexQuotaFetchError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexQuotaFetchError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CodexQuotaFetchError.unauthorized
            }
            throw CodexQuotaFetchError.server(http.statusCode)
        }

        let decoder = JSONDecoder()
        let payload: UsagePayload
        do {
            payload = try decoder.decode(UsagePayload.self, from: data)
        } catch {
            throw CodexQuotaFetchError.invalidResponse
        }
        return payload.snapshot(now: now, accountID: credentials.accountID)
    }

    /// Pure parser hook used by tests and by future offline fixture support.
    public static func parse(_ data: Data, now: Date = Date()) throws -> CodexQuotaSnapshot {
        let payload: UsagePayload
        do {
            payload = try JSONDecoder().decode(UsagePayload.self, from: data)
        } catch {
            throw CodexQuotaFetchError.invalidResponse
        }
        return payload.snapshot(now: now)
    }

    private struct Credentials: Sendable {
        let accessToken: String
        let accountID: String?
    }

    private static func loadCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Credentials
    {
        let base: URL
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            base = URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        let url = base.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else {
            throw CodexQuotaFetchError.credentialsUnavailable
        }
        let json: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexQuotaFetchError.invalidCredentials
            }
            json = object
        } catch let error as CodexQuotaFetchError {
            throw error
        } catch {
            throw CodexQuotaFetchError.invalidCredentials
        }

        guard let tokens = json["tokens"] as? [String: Any],
              let token = (tokens["access_token"] as? String)
                ?? (tokens["accessToken"] as? String),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexQuotaFetchError.invalidCredentials
        }
        let accountID = (tokens["account_id"] as? String) ?? (tokens["accountId"] as? String)
        return Credentials(accessToken: token, accountID: accountID)
    }
}

private struct UsagePayload: Decodable, Sendable {
    let planType: String?
    let email: String?
    let rateLimit: RateLimitPayload?
    let additionalRateLimits: [AdditionalRateLimitPayload]?
    let codeReviewRateLimit: RateLimitPayload?
    let credits: CreditPayload?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case planType = "plan_type"
        case email
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case codeReviewRateLimit = "code_review_rate_limit"
        case credits
    }

    let accountID: String?

    func snapshot(now: Date, accountID: String? = nil) -> CodexQuotaSnapshot {
        var windows: [CodexQuotaWindow] = []
        if let primary = rateLimit?.primaryWindow {
            let weekly = primary.windowSeconds >= 6 * 24 * 60 * 60
            windows.append(primary.window(
                id: weekly ? "codex-weekly" : "codex-session",
                title: weekly ? "Weekly" : "Session"))
        }
        if let secondary = rateLimit?.secondaryWindow {
            let weekly = secondary.windowSeconds >= 6 * 24 * 60 * 60
            windows.append(secondary.window(
                id: weekly ? "codex-weekly" : "codex-secondary",
                title: weekly ? "Weekly" : "Codex secondary"))
        }

        for additional in additionalRateLimits ?? [] {
            let name = additional.limitName ?? additional.meteredFeature ?? "Codex extra limit"
            if let primary = additional.rateLimit?.primaryWindow {
                let nameIsSpark = name.lowercased().contains("spark")
                let isWeekly = primary.windowSeconds >= 6 * 24 * 60 * 60
                let title = nameIsSpark
                    ? (isWeekly ? "Codex Spark Weekly" : "Codex Spark 5-hour")
                    : name
                let id = nameIsSpark
                    ? (isWeekly ? "codex-spark-weekly" : "codex-spark")
                    : slugID(name)
                windows.append(primary.window(id: id, title: title))
            }
            if let secondary = additional.rateLimit?.secondaryWindow {
                let nameIsSpark = name.lowercased().contains("spark")
                let title = nameIsSpark ? "Codex Spark Weekly" : "\(name) secondary"
                let id = nameIsSpark ? "codex-spark-secondary" : "\(slugID(name))-secondary"
                windows.append(secondary.window(id: id, title: title))
            }
        }

        // Some API variants expose code review as its own rate-limit object.
        let codeReview = codeReviewRateLimit?.primaryWindow?.window(
            id: "code-review",
            title: "Code review")

        return CodexQuotaSnapshot(
            accountID: accountID ?? self.accountID,
            accountEmail: email?.trimmingCharacters(in: .whitespacesAndNewlines),
            plan: planType?.trimmingCharacters(in: .whitespacesAndNewlines),
            windows: deduplicate(windows),
            codeReview: codeReview,
            creditsRemaining: credits?.balance,
            fetchedAt: now)
    }

    private func deduplicate(_ values: [CodexQuotaWindow]) -> [CodexQuotaWindow] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private func slugID(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars
        var result = "codex-"
        var needsDash = false
        for scalar in scalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                needsDash = false
            } else if !needsDash {
                result.append("-")
                needsDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private struct RateLimitPayload: Decodable, Sendable {
    let primaryWindow: WindowPayload?
    let secondaryWindow: WindowPayload?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primary = try? container.decodeIfPresent(WindowPayload.self, forKey: .primaryWindow)
        let secondary = try? container.decodeIfPresent(WindowPayload.self, forKey: .secondaryWindow)
        if primary == nil, secondary == nil {
            // `code_review_rate_limit` has appeared both as a normal
            // rate-limit object and as a single window in the API.
            self.primaryWindow = try? WindowPayload(from: decoder)
            self.secondaryWindow = nil
        } else {
            self.primaryWindow = primary ?? nil
            self.secondaryWindow = secondary ?? nil
        }
    }
}

private struct WindowPayload: Decodable, Sendable {
    let usedPercent: Double
    let windowSeconds: Int
    let resetAt: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }

    func window(id: String, title: String) -> CodexQuotaWindow {
        CodexQuotaWindow(
            id: id,
            title: title,
            usedPercent: usedPercent,
            windowSeconds: windowSeconds > 0 ? windowSeconds : nil,
            resetsAt: resetAt > 0 ? Date(timeIntervalSince1970: TimeInterval(resetAt)) : nil)
    }
}

private struct AdditionalRateLimitPayload: Decodable, Sendable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: RateLimitPayload?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

private struct CreditPayload: Decodable, Sendable {
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Double.self, forKey: .balance) {
            balance = value
        } else if let value = try? container.decode(Int.self, forKey: .balance) {
            balance = Double(value)
        } else if let value = try? container.decode(String.self, forKey: .balance) {
            balance = Double(value)
        } else {
            balance = nil
        }
    }
}
