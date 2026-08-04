import Foundation
import CoreFoundation

/// Reads the requested Europe/Berlin calendar day's local Codex rollout files,
/// including adjacent storage days for cross-midnight rollouts. It is
/// intentionally a simple, read-only collector: the menu app and CLI reparse
/// today's eligible files on their 30-second refresh cadence.
public final class UsageCollector: @unchecked Sendable {
    public static func defaultDataRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [SolUsageDataRoot]
    {
        let codex: URL
        if let configuredHome = environment["CODEX_HOME"], !configuredHome.isEmpty {
            codex = URL(fileURLWithPath: (configuredHome as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            codex = home.appendingPathComponent(".codex", isDirectory: true)
        }
        return [
            SolUsageDataRoot(url: codex.appendingPathComponent("sessions", isDirectory: true), recursive: true),
            SolUsageDataRoot(url: codex.appendingPathComponent("archived_sessions", isDirectory: true), recursive: false)
        ]
    }

    private let dataRoots: [SolUsageDataRoot]

    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let typeProbeLimit = 2 * 1024
    private static let linePrefixLimit = 64 * 1024
    private static let maximumCandidateLineBytes = 2 * 1024 * 1024
    private static let readChunkBytes = 64 * 1024

    public init(dataRoots: [SolUsageDataRoot] = UsageCollector.defaultDataRoots()) {
        self.dataRoots = dataRoots
    }

    /// Reports today through the current instant, or one exact Berlin day
    /// when `requestedDate` is supplied. No other period is supported.
    public func report(for requestedDate: String? = nil, generatedAt: Date = Date()) -> UsageReport {
        let date = requestedDate ?? SolUsageDates.today(now: generatedAt)
        let interval: UsageInterval?

        if requestedDate == nil {
            interval = SolUsageDates.startOfDay(for: date).map {
                UsageInterval(
                    rangeIdentifier: "today",
                    start: $0,
                    end: generatedAt,
                    dateLabel: date
                )
            }
        } else {
            interval = SolUsageDates.startOfDay(for: date).flatMap { start in
                SolUsageDates.endOfDay(for: date).map { end in
                    UsageInterval(
                        rangeIdentifier: "date:\(date)",
                        start: start,
                        end: end,
                        dateLabel: date
                    )
                }
            }
        }

        guard let interval else {
            return emptyReport(date: date, rangeIdentifier: requestedDate == nil ? "today" : "date:\(date)", generatedAt: generatedAt)
        }
        return report(for: interval, generatedAt: generatedAt)
    }

    public func report(for interval: UsageInterval, generatedAt: Date = Date()) -> UsageReport {
        let files = discoverFiles(for: interval.dateLabel)
        var totalsByLane: [UsageLane: LaneTotals] = [
            .advisor: .zero,
            .worker: .zero,
            .other: .zero
        ]
        var totalsByModel: [UsageModelKey: LaneTotals] = [:]

        for file in files {
            let parsed = parseRollout(at: file.url, interval: interval)
            for (lane, totals) in parsed.totals {
                totalsByLane[lane, default: .zero].add(totals)
            }
            for (key, totals) in parsed.modelTotals {
                totalsByModel[key, default: .zero].add(totals)
            }
            for lane in parsed.contributingLanes {
                totalsByLane[lane, default: .zero].taskCount += 1
            }
            for key in parsed.contributingModels {
                totalsByModel[key, default: .zero].taskCount += 1
            }
        }

        var advisor = totalsByLane[.advisor] ?? .zero
        var worker = totalsByLane[.worker] ?? .zero
        var other = totalsByLane[.other] ?? .zero
        advisor.apiEquivalentCostUSD = SolUsagePricing.estimate(for: advisor, lane: .advisor)
        worker.apiEquivalentCostUSD = SolUsagePricing.estimate(for: worker, lane: .worker)
        other.apiEquivalentCostUSD = nil

        var combined = LaneTotals.zero
        combined.add(advisor)
        combined.add(worker)

        let modelUsage = totalsByModel.keys.sorted {
            $0.model == $1.model ? $0.intelligence < $1.intelligence : $0.model < $1.model
        }.map { key -> ModelUsage in
            var totals = totalsByModel[key] ?? .zero
            totals.apiEquivalentCostUSD = SolUsagePricing.estimate(for: totals, model: key.model)
            return ModelUsage(key: key, totals: totals)
        }

        return UsageReport(
            date: interval.dateLabel,
            rangeIdentifier: interval.rangeIdentifier,
            startAt: SolUsageDates.isoString(for: interval.start),
            endAt: SolUsageDates.isoString(for: interval.end),
            generatedAt: SolUsageDates.isoString(for: generatedAt),
            advisor: advisor,
            worker: worker,
            combined: combined,
            other: other,
            modelUsage: modelUsage
        )
    }

    private func emptyReport(date: String, rangeIdentifier: String, generatedAt: Date) -> UsageReport {
        UsageReport(
            date: date,
            rangeIdentifier: rangeIdentifier,
            startAt: "",
            endAt: "",
            generatedAt: SolUsageDates.isoString(for: generatedAt),
            advisor: .zero,
            worker: .zero,
            combined: .zero,
            other: .zero,
            modelUsage: []
        )
    }

    private struct FileMetadata {
        let url: URL
        let path: String
    }

    private struct ParsedRollout {
        var totals: [UsageLane: LaneTotals] = [:]
        var contributingLanes: Set<UsageLane> = []
        var modelTotals: [UsageModelKey: LaneTotals] = [:]
        var contributingModels: Set<UsageModelKey> = []
    }

    private struct SnapshotCounters {
        var input: Int64?
        var cachedInput: Int64?
        var cacheWriteInput: Int64?
        var output: Int64?
        var reasoningOutput: Int64?
        var total: Int64?

        static let empty = SnapshotCounters(
            input: nil,
            cachedInput: nil,
            cacheWriteInput: nil,
            output: nil,
            reasoningOutput: nil,
            total: nil
        )

        init(
            input: Int64?,
            cachedInput: Int64?,
            cacheWriteInput: Int64?,
            output: Int64?,
            reasoningOutput: Int64?,
            total: Int64?
        ) {
            self.input = input
            self.cachedInput = cachedInput
            self.cacheWriteInput = cacheWriteInput
            self.output = output
            self.reasoningOutput = reasoningOutput
            self.total = total
        }

        init(dictionary: [String: Any]) {
            let input = Self.nonnegativeInt(dictionary["input_tokens"])
            let output = Self.nonnegativeInt(dictionary["output_tokens"])
            let total = Self.nonnegativeInt(dictionary["total_tokens"]) ?? {
                guard let input, let output else { return nil }
                return input + output
            }()
            self.init(
                input: input,
                cachedInput: Self.nonnegativeInt(dictionary["cached_input_tokens"]),
                cacheWriteInput: Self.nonnegativeInt(dictionary["cache_write_input_tokens"]),
                output: output,
                reasoningOutput: Self.nonnegativeInt(dictionary["reasoning_output_tokens"]),
                total: total
            )
        }

        func delta(from previous: inout SnapshotCounters) -> SnapshotCounters {
            SnapshotCounters(
                input: Self.delta(input, previous: &previous.input),
                cachedInput: Self.delta(cachedInput, previous: &previous.cachedInput),
                cacheWriteInput: Self.delta(cacheWriteInput, previous: &previous.cacheWriteInput),
                output: Self.delta(output, previous: &previous.output),
                reasoningOutput: Self.delta(reasoningOutput, previous: &previous.reasoningOutput),
                total: Self.delta(total, previous: &previous.total)
            )
        }

        var laneTotals: LaneTotals {
            LaneTotals(
                totalTokens: total ?? 0,
                inputTokens: input ?? 0,
                cachedInputTokens: cachedInput ?? 0,
                cacheWriteInputTokens: cacheWriteInput ?? 0,
                outputTokens: output ?? 0,
                reasoningOutputTokens: reasoningOutput ?? 0
            )
        }

        private static func delta(_ current: Int64?, previous: inout Int64?) -> Int64? {
            guard let current else { return nil }
            let result: Int64
            if let previous {
                result = current >= previous ? current - previous : current
            } else {
                result = current
            }
            previous = current
            return max(0, result)
        }

        private static func nonnegativeInt(_ value: Any?) -> Int64? {
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
                return max(0, number.int64Value)
            }
            if value is Bool { return nil }
            if let value = value as? Int64 { return max(0, value) }
            if let value = value as? Int { return Int64(max(0, value)) }
            return nil
        }
    }

    private enum RecordKind {
        case turnContext(model: String?, effort: String?)
        case tokenCount(SnapshotCounters)
    }

    private struct RolloutRecord {
        let timestamp: Date
        let kind: RecordKind
    }

    private enum FastRecordKind: Equatable {
        case unknown
        case other
        case turnContext
        case eventMessage
    }

    private struct LineState {
        private enum Mode {
            case undecided
            case candidate(FastRecordKind)
            case skip
        }

        private var mode: Mode = .undecided
        private var data = Data()
        private var lineLength = 0

        var hasBytes: Bool { lineLength > 0 }

        mutating func append(_ byte: UInt8) {
            lineLength += 1
            switch mode {
            case .skip:
                return
            case .undecided:
                if data.count < UsageCollector.linePrefixLimit {
                    data.append(byte)
                }
                if data.count == UsageCollector.typeProbeLimit || data.count == UsageCollector.linePrefixLimit {
                    inspect()
                }
            case .candidate(let candidateKind):
                guard data.count < UsageCollector.maximumCandidateLineBytes else {
                    mode = .skip
                    data = Data()
                    return
                }
                data.append(byte)
                if data.count == UsageCollector.linePrefixLimit,
                   candidateKind == .eventMessage,
                   !UsageCollector.containsASCII(UsageCollector.tokenCountMarker, in: data) {
                    mode = .skip
                    data = Data()
                }
            }

            if lineLength > UsageCollector.maximumCandidateLineBytes {
                mode = .skip
                data = Data()
            }
        }

        mutating func finish() -> Data? {
            if case .undecided = mode {
                inspect()
            }
            guard case .candidate = mode else { return nil }
            return data
        }

        mutating func reset() {
            mode = .undecided
            data = Data()
            lineLength = 0
        }

        private mutating func inspect() {
            guard case .undecided = mode else { return }
            switch UsageCollector.fastRecordKind(in: data) {
            case .turnContext:
                mode = .candidate(.turnContext)
            case .eventMessage:
                mode = .candidate(.eventMessage)
                if data.count >= UsageCollector.linePrefixLimit,
                   !UsageCollector.containsASCII(UsageCollector.tokenCountMarker, in: data) {
                    mode = .skip
                    data = Data()
                }
            case .other:
                mode = .skip
                data = Data()
            case .unknown:
                if data.count >= UsageCollector.linePrefixLimit {
                    mode = .skip
                    data = Data()
                }
            }
        }
    }

    private func discoverFiles(for date: String) -> [FileMetadata] {
        var paths: Set<String> = []
        var result: [FileMetadata] = []

        for root in dataRoots {
            let rootName = root.url.lastPathComponent.lowercased()
            let urls: [URL]
            let dateScoped: Bool

            if root.url.pathExtension.lowercased() == "jsonl" {
                urls = [root.url]
                dateScoped = true
            } else if rootName == "sessions" {
                // A rollout is stored under the day it started. If it crosses
                // midnight, later token snapshots remain in that same folder,
                // so inspect only the neighboring storage days and filter by
                // the requested Berlin day below.
                urls = sessionDayDirectories(for: date, root: root.url)
                    .flatMap { dayDirectory in
                        let enumerator = FileManager.default.enumerator(
                            at: dayDirectory,
                            includingPropertiesForKeys: nil,
                            options: [.skipsPackageDescendants]
                        )
                        return enumerator?.compactMap { $0 as? URL } ?? []
                    }
                dateScoped = false
            } else if rootName == "archived_sessions" {
                urls = (try? FileManager.default.contentsOfDirectory(
                    at: root.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsPackageDescendants]
                )) ?? []
                dateScoped = false
            } else if root.recursive {
                let enumerator = FileManager.default.enumerator(
                    at: root.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsPackageDescendants]
                )
                urls = enumerator?.compactMap { $0 as? URL } ?? []
                dateScoped = false
            } else {
                urls = (try? FileManager.default.contentsOfDirectory(
                    at: root.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsPackageDescendants]
                )) ?? []
                dateScoped = false
            }

            for url in urls where url.pathExtension.lowercased() == "jsonl" {
                let standardized = url.standardizedFileURL
                guard paths.insert(standardized.path).inserted,
                      (dateScoped || matchesDate(standardized, date: date)),
                      let metadata = metadata(for: standardized) else {
                    continue
                }
                result.append(metadata)
            }
        }

        return result.sorted { $0.path < $1.path }
    }

    private func sessionDayDirectories(for date: String, root: URL) -> [URL] {
        guard let start = SolUsageDates.startOfDay(for: date) else { return [] }
        return (-1...1).compactMap { offset in
            guard let day = SolUsageDates.calendar.date(byAdding: .day, value: offset, to: start) else {
                return nil
            }
            let components = SolUsageDates.calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                return nil
            }
            return root
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
    }

    private func metadata(for url: URL) -> FileMetadata? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular else {
            return nil
        }
        return FileMetadata(url: url, path: url.path)
    }

    private func matchesDate(_ url: URL, date: String) -> Bool {
        if let rolloutDate = rolloutStartDate(from: url),
           SolUsageDates.dateKey(for: rolloutDate) == date {
            return true
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return false
        }
        return SolUsageDates.dateKey(for: modificationDate) == date
    }

    private func rolloutStartDate(from url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let marker = name.range(of: "rollout-"),
              let dateEnd = name.index(marker.upperBound, offsetBy: 10, limitedBy: name.endIndex),
              dateEnd <= name.endIndex else {
            return nil
        }
        return SolUsageDates.startOfDay(for: String(name[marker.upperBound..<dateEnd]))
    }

    private func parseRollout(at url: URL, interval: UsageInterval) -> ParsedRollout {
        var contribution = ParsedRollout()
        var previous = SnapshotCounters.empty
        var activeModel: String?
        var activeEffort: String?
        var absoluteOffset: UInt64 = 0
        var lineState = LineState()

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return contribution
        }
        defer { try? handle.close() }

        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: Self.readChunkBytes), !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }

            for byte in chunk {
                absoluteOffset += 1
                if byte == 0x0A {
                    if let line = lineState.finish() {
                        processLine(
                            line,
                            interval: interval,
                            previous: &previous,
                            activeModel: &activeModel,
                            activeEffort: &activeEffort,
                            contribution: &contribution
                        )
                    }
                    lineState.reset()
                } else {
                    lineState.append(byte)
                }
            }
        }

        if let line = lineState.finish(), lineState.hasBytes {
            processLine(
                line,
                interval: interval,
                previous: &previous,
                activeModel: &activeModel,
                activeEffort: &activeEffort,
                contribution: &contribution
            )
        }
        _ = absoluteOffset
        return contribution
    }

    private func processLine(
        _ line: Data,
        interval: UsageInterval,
        previous: inout SnapshotCounters,
        activeModel: inout String?,
        activeEffort: inout String?,
        contribution: inout ParsedRollout
    ) {
        guard let record: RolloutRecord = autoreleasepool(invoking: { parseRecord(line) }) else {
            return
        }

        switch record.kind {
        case let .turnContext(model, effort):
            activeModel = model
            activeEffort = effort
        case let .tokenCount(snapshot):
            let delta = snapshot.delta(from: &previous)
            let metrics = delta.laneTotals
            guard !metrics.isZero, interval.contains(record.timestamp) else { return }
            let lane = UsageLane.classify(model: activeModel, effort: activeEffort)
            contribution.totals[lane, default: .zero].add(metrics)
            let modelKey = UsageModelKey(
                model: activeModel ?? "unknown",
                intelligence: activeEffort ?? "unknown"
            )
            contribution.modelTotals[modelKey, default: .zero].add(metrics)
            if metrics.totalTokens > 0 {
                contribution.contributingLanes.insert(lane)
                contribution.contributingModels.insert(modelKey)
            }
        }
    }

    private static func fastRecordKind(in data: Data) -> FastRecordKind {
        guard let type = topLevelType(in: data) else { return .unknown }
        switch type {
        case "turn_context": return .turnContext
        case "event_msg": return .eventMessage
        default: return .other
        }
    }

    private static func topLevelType(in data: Data) -> String? {
        let bytes = Array(data)
        var index = 0
        skipWhitespace(in: bytes, index: &index)
        guard index < bytes.count, bytes[index] == 0x7B else { return nil }
        index += 1

        while index < bytes.count {
            skipWhitespaceAndCommas(in: bytes, index: &index)
            guard index < bytes.count, bytes[index] != 0x7D else { return nil }
            guard let key = readJSONString(in: bytes, index: &index) else { return nil }
            skipWhitespace(in: bytes, index: &index)
            guard index < bytes.count, bytes[index] == 0x3A else { return nil }
            index += 1
            skipWhitespace(in: bytes, index: &index)
            if key == "type" {
                return readJSONString(in: bytes, index: &index)
            }
            skipJSONValue(in: bytes, index: &index)
        }
        return nil
    }

    private static func readJSONString(in bytes: [UInt8], index: inout Int) -> String? {
        guard index < bytes.count, bytes[index] == 0x22 else { return nil }
        index += 1
        let start = index
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                let value = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return escaped ? nil : value
            }
            if byte == 0x5C {
                escaped = true
                index += 2
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func skipJSONValue(in bytes: [UInt8], index: inout Int) {
        guard index < bytes.count else { return }
        if bytes[index] == 0x22 {
            _ = readJSONString(in: bytes, index: &index)
            return
        }
        if bytes[index] == 0x7B || bytes[index] == 0x5B {
            var depth = 0
            var inString = false
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        inString = false
                    }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B || byte == 0x5B {
                    depth += 1
                } else if byte == 0x7D || byte == 0x5D {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        return
                    }
                }
                index += 1
            }
            return
        }
        while index < bytes.count,
              bytes[index] != 0x2C,
              bytes[index] != 0x7D,
              bytes[index] != 0x5D {
            index += 1
        }
    }

    private static func skipWhitespace(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09 ||
              bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }

    private static func skipWhitespaceAndCommas(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count {
            if bytes[index] == 0x2C {
                index += 1
            } else if bytes[index] == 0x20 || bytes[index] == 0x09 ||
                        bytes[index] == 0x0A || bytes[index] == 0x0D {
                index += 1
            } else {
                break
            }
        }
    }

    private static func containsASCII(_ needle: Data, in haystack: Data) -> Bool {
        haystack.range(of: needle) != nil
    }

    private func parseRecord(_ line: Data) -> RolloutRecord? {
        let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D })
        guard !trimmed.isEmpty else { return nil }
        let trimmedData = Data(trimmed)
        let kind = Self.fastRecordKind(in: trimmedData)
        if case .eventMessage = kind,
           !Self.containsASCII(Self.tokenCountMarker, in: trimmedData) {
            return nil
        }

        guard let object = try? JSONSerialization.jsonObject(with: trimmedData, options: []),
              let envelope = object as? [String: Any],
              let type = envelope["type"] as? String,
              let timestampString = envelope["timestamp"] as? String,
              let timestamp = SolUsageDates.isoDate(from: timestampString) else {
            return nil
        }

        if type == "turn_context" {
            let payload = envelope["payload"] as? [String: Any]
            let model = payload?["model"] as? String
            let effort = ((payload?["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any])?["reasoning_effort"] as? String
            return RolloutRecord(timestamp: timestamp, kind: .turnContext(model: model, effort: effort))
        }

        guard type == "event_msg",
              let payload = envelope["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any] else {
            return nil
        }
        return RolloutRecord(timestamp: timestamp, kind: .tokenCount(SnapshotCounters(dictionary: usage)))
    }
}

private extension UsageLane {
    static func classify(model: String?, effort: String?) -> UsageLane {
        switch (model, effort) {
        case ("gpt-5.6-sol", "high"):
            return .advisor
        case ("gpt-5.6-luna", "max"):
            return .worker
        default:
            return .other
        }
    }
}
