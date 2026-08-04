import Foundation

public enum UsageLane: String, Codable, CaseIterable, Hashable, Sendable {
    case advisor
    case worker
    case other
}

public struct UsageModelKey: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let model: String
    public let intelligence: String

    public init(model: String, intelligence: String) {
        self.model = model
        self.intelligence = intelligence
    }

    public var id: String { "\(model)|\(intelligence)" }

    public var displayName: String {
        let modelName = model.replacingOccurrences(of: "gpt-", with: "GPT-")
        return "\(modelName) · \(intelligence)"
    }
}

public struct ModelUsage: Codable, Equatable, Sendable, Identifiable {
    public let key: UsageModelKey
    public var totals: LaneTotals

    public init(key: UsageModelKey, totals: LaneTotals) {
        self.key = key
        self.totals = totals
    }

    public var id: String { key.id }
}

public struct UsageInterval: Equatable, Sendable {
    public let rangeIdentifier: String
    public let start: Date
    public let end: Date
    public let dateLabel: String

    public init(rangeIdentifier: String, start: Date, end: Date, dateLabel: String) {
        self.rangeIdentifier = rangeIdentifier
        self.start = start
        self.end = end
        self.dateLabel = dateLabel
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

public struct LaneTotals: Codable, Equatable, Sendable {
    public var totalTokens: Int64
    public var inputTokens: Int64
    public var cachedInputTokens: Int64
    public var cacheWriteInputTokens: Int64
    public var outputTokens: Int64
    public var reasoningOutputTokens: Int64
    public var taskCount: Int
    public var apiEquivalentCostUSD: Double?

    public init(
        totalTokens: Int64 = 0,
        inputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        cacheWriteInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        taskCount: Int = 0,
        apiEquivalentCostUSD: Double? = nil
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.taskCount = taskCount
        self.apiEquivalentCostUSD = apiEquivalentCostUSD
    }

    public static let zero = LaneTotals()

    public var isZero: Bool {
        totalTokens == 0 && inputTokens == 0 && cachedInputTokens == 0 &&
            cacheWriteInputTokens == 0 && outputTokens == 0 &&
            reasoningOutputTokens == 0 && taskCount == 0
    }

    public var compactTokenCount: String {
        CompactTokenFormatter.string(for: totalTokens)
    }

    public var uncachedInputTokens: Int64 {
        max(0, inputTokens - cachedInputTokens - cacheWriteInputTokens)
    }

    public mutating func add(_ other: LaneTotals) {
        totalTokens += max(0, other.totalTokens)
        inputTokens += max(0, other.inputTokens)
        cachedInputTokens += max(0, other.cachedInputTokens)
        cacheWriteInputTokens += max(0, other.cacheWriteInputTokens)
        outputTokens += max(0, other.outputTokens)
        reasoningOutputTokens += max(0, other.reasoningOutputTokens)
        taskCount += max(0, other.taskCount)
        if let cost = other.apiEquivalentCostUSD {
            apiEquivalentCostUSD = (apiEquivalentCostUSD ?? 0) + cost
        }
    }

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case taskCount = "task_count"
        case apiEquivalentCostUSD = "api_equivalent_cost_usd"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalTokens, forKey: .totalTokens)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try container.encode(cacheWriteInputTokens, forKey: .cacheWriteInputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(reasoningOutputTokens, forKey: .reasoningOutputTokens)
        try container.encode(taskCount, forKey: .taskCount)
        try container.encodeIfPresent(apiEquivalentCostUSD, forKey: .apiEquivalentCostUSD)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try container.decode(Int64.self, forKey: .totalTokens)
        inputTokens = try container.decode(Int64.self, forKey: .inputTokens)
        cachedInputTokens = try container.decode(Int64.self, forKey: .cachedInputTokens)
        cacheWriteInputTokens = try container.decode(Int64.self, forKey: .cacheWriteInputTokens)
        outputTokens = try container.decode(Int64.self, forKey: .outputTokens)
        reasoningOutputTokens = try container.decode(Int64.self, forKey: .reasoningOutputTokens)
        taskCount = try container.decode(Int.self, forKey: .taskCount)
        apiEquivalentCostUSD = try container.decodeIfPresent(Double.self, forKey: .apiEquivalentCostUSD)
    }
}

public struct UsageCostBreakdown: Equatable, Sendable {
    public let uncachedInputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheWriteInputTokens: Int64
    public let outputTokens: Int64
    public let uncachedInputCostUSD: Double
    public let cachedInputCostUSD: Double
    public let cacheWriteCostUSD: Double
    public let outputCostUSD: Double

    public var totalCostUSD: Double {
        uncachedInputCostUSD + cachedInputCostUSD + cacheWriteCostUSD + outputCostUSD
    }

    public init(
        uncachedInputTokens: Int64,
        cachedInputTokens: Int64,
        cacheWriteInputTokens: Int64,
        outputTokens: Int64,
        uncachedInputCostUSD: Double,
        cachedInputCostUSD: Double,
        cacheWriteCostUSD: Double,
        outputCostUSD: Double
    ) {
        self.uncachedInputTokens = uncachedInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.uncachedInputCostUSD = uncachedInputCostUSD
        self.cachedInputCostUSD = cachedInputCostUSD
        self.cacheWriteCostUSD = cacheWriteCostUSD
        self.outputCostUSD = outputCostUSD
    }
}

public struct UsageReport: Codable, Equatable, Sendable {
    public let date: String
    public let timezone: String
    public let rangeIdentifier: String
    public let startAt: String
    public let endAt: String
    public let generatedAt: String
    public let advisor: LaneTotals
    public let worker: LaneTotals
    public let combined: LaneTotals
    public let other: LaneTotals
    public let modelUsage: [ModelUsage]
    public let attributionNote: String

    public init(
        date: String,
        timezone: String = SolUsageDates.timezoneIdentifier,
        rangeIdentifier: String,
        startAt: String,
        endAt: String,
        generatedAt: String,
        advisor: LaneTotals,
        worker: LaneTotals,
        combined: LaneTotals,
        other: LaneTotals,
        modelUsage: [ModelUsage] = [],
        attributionNote: String = SolUsageDates.attributionNote
    ) {
        self.date = date
        self.timezone = timezone
        self.rangeIdentifier = rangeIdentifier
        self.startAt = startAt
        self.endAt = endAt
        self.generatedAt = generatedAt
        self.advisor = advisor
        self.worker = worker
        self.combined = combined
        self.other = other
        self.modelUsage = modelUsage
        self.attributionNote = attributionNote
    }

    enum CodingKeys: String, CodingKey {
        case date
        case timezone
        case rangeIdentifier = "range"
        case startAt = "start_at"
        case endAt = "end_at"
        case generatedAt = "generated_at"
        case advisor
        case worker
        case combined
        case other
        case modelUsage = "model_usage"
        case attributionNote = "attribution_note"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone) ?? SolUsageDates.timezoneIdentifier
        rangeIdentifier = try container.decode(String.self, forKey: .rangeIdentifier)
        startAt = try container.decode(String.self, forKey: .startAt)
        endAt = try container.decode(String.self, forKey: .endAt)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        advisor = try container.decode(LaneTotals.self, forKey: .advisor)
        worker = try container.decode(LaneTotals.self, forKey: .worker)
        combined = try container.decode(LaneTotals.self, forKey: .combined)
        other = try container.decode(LaneTotals.self, forKey: .other)
        modelUsage = try container.decodeIfPresent([ModelUsage].self, forKey: .modelUsage) ?? []
        attributionNote = try container.decodeIfPresent(String.self, forKey: .attributionNote) ?? SolUsageDates.attributionNote
    }
}

public enum SolUsagePricing {
    public struct Rates: Equatable, Sendable {
        public let regularInputPerMillion: Double
        public let cachedInputPerMillion: Double
        public let cacheWritePerMillion: Double
        public let outputPerMillion: Double

        public init(
            regularInputPerMillion: Double,
            cachedInputPerMillion: Double,
            cacheWritePerMillion: Double,
            outputPerMillion: Double
        ) {
            self.regularInputPerMillion = regularInputPerMillion
            self.cachedInputPerMillion = cachedInputPerMillion
            self.cacheWritePerMillion = cacheWritePerMillion
            self.outputPerMillion = outputPerMillion
        }
    }

    public static let advisor = Rates(
        regularInputPerMillion: 5.00,
        cachedInputPerMillion: 0.50,
        cacheWritePerMillion: 6.25,
        outputPerMillion: 30.00
    )

    public static let worker = Rates(
        regularInputPerMillion: 0.20,
        cachedInputPerMillion: 0.02,
        cacheWritePerMillion: 0.25,
        outputPerMillion: 1.20
    )

    public static let terra = Rates(
        regularInputPerMillion: 2.50,
        cachedInputPerMillion: 0.25,
        cacheWritePerMillion: 3.125,
        outputPerMillion: 15.00
    )

    public static func rates(for model: String) -> Rates? {
        switch model.lowercased() {
        case "gpt-5.6-sol", "gpt-5.6": return advisor
        case "gpt-5.6-luna": return worker
        case "gpt-5.6-terra": return terra
        default: return nil
        }
    }

    public static func estimate(for totals: LaneTotals, model: String) -> Double? {
        guard let rates = rates(for: model) else { return nil }
        return breakdown(for: totals, rates: rates).totalCostUSD
    }

    public static func estimate(for totals: LaneTotals, lane: UsageLane) -> Double {
        let rates: Rates
        switch lane {
        case .advisor: rates = advisor
        case .worker: rates = worker
        case .other: return 0
        }

        return breakdown(for: totals, rates: rates).totalCostUSD
    }

    public static func breakdown(for totals: LaneTotals, model: String) -> UsageCostBreakdown? {
        guard let rates = rates(for: model) else { return nil }
        return breakdown(for: totals, rates: rates)
    }

    public static func breakdown(for totals: LaneTotals, lane: UsageLane) -> UsageCostBreakdown? {
        let rates: Rates
        switch lane {
        case .advisor: rates = advisor
        case .worker: rates = worker
        case .other: return nil
        }
        return breakdown(for: totals, rates: rates)
    }

    private static func breakdown(for totals: LaneTotals, rates: Rates) -> UsageCostBreakdown {
        let uncachedInput = totals.uncachedInputTokens
        let divisor = 1_000_000.0
        return UsageCostBreakdown(
            uncachedInputTokens: uncachedInput,
            cachedInputTokens: max(0, totals.cachedInputTokens),
            cacheWriteInputTokens: max(0, totals.cacheWriteInputTokens),
            outputTokens: max(0, totals.outputTokens),
            uncachedInputCostUSD: Double(uncachedInput) * rates.regularInputPerMillion / divisor,
            cachedInputCostUSD: Double(max(0, totals.cachedInputTokens)) * rates.cachedInputPerMillion / divisor,
            cacheWriteCostUSD: Double(max(0, totals.cacheWriteInputTokens)) * rates.cacheWritePerMillion / divisor,
            outputCostUSD: Double(max(0, totals.outputTokens)) * rates.outputPerMillion / divisor
        )
    }
}

public enum CompactTokenFormatter {
    public static func string(for value: Int64) -> String {
        let number = Double(max(0, value))
        switch number {
        case 1_000_000_000...:
            return String(format: "%.1fB", number / 1_000_000_000).replacingOccurrences(of: ".0B", with: "B")
        case 1_000_000...:
            return String(format: "%.1fM", number / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        case 1_000...:
            return String(format: "%.1fK", number / 1_000).replacingOccurrences(of: ".0K", with: "K")
        default:
            return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
        }
    }
}

public enum SolUsageDates {
    public static let timezoneIdentifier = "Europe/Berlin"

    public static let attributionNote =
        "Exact model/effort pairs only; token deltas are assigned to the event timestamp in Europe/Berlin. Cross-midnight rollouts follow event time, not task start time. API-equivalent estimates are not Codex subscription billing and exclude tool-call fees, priority/batch adjustments, and the >272K long-context multiplier."

    public static func today(now: Date = Date()) -> String {
        dateKey(for: now)
    }

    public static func isValidDate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = startOfDay(for: value) else {
            return false
        }
        return dateKey(for: date) == value
    }

    public static func dateKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    public static func startOfDay(for value: String) -> Date? {
        guard isDateShape(value),
              let year = Int(value.prefix(4)),
              let month = Int(value.dropFirst(5).prefix(2)),
              let day = Int(value.dropFirst(8).prefix(2)) else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public static func endOfDay(for value: String) -> Date? {
        guard let start = startOfDay(for: value) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: start)
    }

    internal static func isoDate(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public static func isoString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timezone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Human-readable Berlin-local timestamp for the menu-bar UI.
    public static func displayTimestamp(_ value: String) -> String {
        guard let date = isoDate(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timezone
        formatter.dateFormat = "dd MMM yyyy, HH:mm"
        return "\(formatter.string(from: date)) (Berlin)"
    }

    /// Human-readable Berlin-local calendar date for day selectors.
    public static func displayDate(_ value: String) -> String {
        guard let date = startOfDay(for: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timezone
        formatter.dateFormat = "dd MMM yyyy"
        return formatter.string(from: date)
    }

    internal static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    internal static let timezone = TimeZone(identifier: timezoneIdentifier)!

    private static func isDateShape(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

public struct SolUsageDataRoot: Sendable, Equatable {
    public let url: URL
    public let recursive: Bool

    public init(url: URL, recursive: Bool = true) {
        self.url = url.standardizedFileURL
        self.recursive = recursive
    }
}

/// Persists only derived daily reports. Raw rollout contents never enter this file.
public final class DailyHistoryStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager = FileManager.default

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let support = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("SolUsageMonitor", isDirectory: true)
        self.fileURL = support.appendingPathComponent("daily-history.json")
    }

    public func report(for date: String) -> UsageReport? {
        load()[date]
    }

    public func dates() -> [String] {
        load().keys.sorted(by: >)
    }

    public func reports() -> [UsageReport] {
        load().values.sorted { $0.date < $1.date }
    }

    public func save(_ report: UsageReport) {
        var reports = load()
        reports[report.date] = report
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.history.encode(reports)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // History is supplemental; a failed snapshot must not stop monitoring.
        }
    }

    private func load() -> [String: UsageReport] {
        guard let data = try? Data(contentsOf: fileURL),
              let reports = try? JSONDecoder().decode([String: UsageReport].self, from: data) else {
            return [:]
        }
        return reports
    }
}

private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
