import XCTest
@testable import SolUsageCore

final class UsageCollectorTests: XCTestCase {
    func testCumulativeDeltasAndExactLaneMatching() throws {
        let file = try fixtureFile(named: "rollout-2026-08-03T08-00-00-fixture.jsonl")
        let report = UsageCollector(dataRoots: [SolUsageDataRoot(url: file, recursive: false)])
            .report(for: "2026-08-03", generatedAt: fixedGenerationDate)

        XCTAssertEqual(report.advisor.totalTokens, 19)
        XCTAssertEqual(report.advisor.inputTokens, 16)
        XCTAssertEqual(report.advisor.cachedInputTokens, 10)
        XCTAssertEqual(report.advisor.cacheWriteInputTokens, 0)
        XCTAssertEqual(report.advisor.outputTokens, 3)
        XCTAssertEqual(report.advisor.reasoningOutputTokens, 2)
        XCTAssertEqual(report.advisor.taskCount, 1)

        XCTAssertEqual(report.worker.totalTokens, 6)
        XCTAssertEqual(report.worker.inputTokens, 4)
        XCTAssertEqual(report.worker.cachedInputTokens, 2)
        XCTAssertEqual(report.worker.outputTokens, 2)
        XCTAssertEqual(report.worker.reasoningOutputTokens, 1)
        XCTAssertEqual(report.worker.taskCount, 1)

        XCTAssertEqual(report.other.totalTokens, 16)
        XCTAssertEqual(report.other.taskCount, 1)
        XCTAssertEqual(report.combined.totalTokens, 25)
        XCTAssertEqual(report.combined.taskCount, 2)
        XCTAssertTrue(report.modelUsage.contains {
            $0.key == UsageModelKey(model: "gpt-5.6-sol", intelligence: "high") &&
                $0.totals.totalTokens == 19
        })
        XCTAssertTrue(report.modelUsage.contains {
            $0.key == UsageModelKey(model: "gpt-5.6-luna", intelligence: "max") &&
                $0.totals.totalTokens == 6
        })
    }

    func testBerlinDayBoundaryMalformedLinesMissingFieldsAndReset() throws {
        let file = try fixtureFile(named: "rollout-2026-08-02T23-59-00-fixture.jsonl")
        let collector = UsageCollector(dataRoots: [SolUsageDataRoot(url: file, recursive: false)])

        let previousDay = collector.report(for: "2026-08-02", generatedAt: fixedGenerationDate)
        XCTAssertEqual(previousDay.advisor.totalTokens, 100)
        XCTAssertEqual(previousDay.advisor.taskCount, 1)

        let nextDay = collector.report(for: "2026-08-03", generatedAt: fixedGenerationDate)
        XCTAssertEqual(nextDay.advisor.totalTokens, 38)
        XCTAssertEqual(nextDay.advisor.inputTokens, 28)
        XCTAssertEqual(nextDay.advisor.cachedInputTokens, 12)
        XCTAssertEqual(nextDay.advisor.outputTokens, 10)
        XCTAssertEqual(nextDay.advisor.reasoningOutputTokens, 2)
        XCTAssertEqual(nextDay.advisor.taskCount, 1)
        XCTAssertEqual(nextDay.other.totalTokens, 0)
    }

    func testTodayAndExactDateUseBerlinCalendarBoundaries() throws {
        let generatedAt = try isoDate("2026-08-03T12:00:00Z")
        let file = try fixtureFile(named: "rollout-2026-08-03T08-00-00-fixture.jsonl")
        let collector = UsageCollector(dataRoots: [SolUsageDataRoot(url: file, recursive: false)])

        let today = collector.report(generatedAt: generatedAt)
        XCTAssertEqual(today.rangeIdentifier, "today")
        XCTAssertEqual(today.date, "2026-08-03")
        XCTAssertEqual(today.startAt, "2026-08-03T00:00:00.000+02:00")
        XCTAssertEqual(today.endAt, "2026-08-03T14:00:00.000+02:00")

        let exact = collector.report(for: "2026-08-03", generatedAt: generatedAt)
        XCTAssertEqual(exact.rangeIdentifier, "date:2026-08-03")
        XCTAssertEqual(exact.startAt, "2026-08-03T00:00:00.000+02:00")
        XCTAssertEqual(exact.endAt, "2026-08-04T00:00:00.000+02:00")
    }

    func testCostIncludesCacheWritesAndUsesCurrentLunaRates() throws {
        let advisor = try fixtureFile(named: "rollout-2026-03-26T00-00-00-cost-advisor.jsonl")
        let worker = try fixtureFile(named: "rollout-2026-03-29T11-30-00-cost-worker.jsonl")
        let collector = UsageCollector(dataRoots: [
            SolUsageDataRoot(url: advisor, recursive: false),
            SolUsageDataRoot(url: worker, recursive: false)
        ])
        let now = try isoDate("2026-03-29T12:00:00Z")
        let interval = UsageInterval(
            rangeIdentifier: "test",
            start: try isoDate("2026-03-29T11:00:00Z"),
            end: now,
            dateLabel: "2026-03-29"
        )

        let report = collector.report(for: interval, generatedAt: now)
        XCTAssertEqual(report.advisor.totalTokens, 57)
        XCTAssertEqual(report.advisor.inputTokens, 50)
        XCTAssertEqual(report.advisor.cachedInputTokens, 10)
        XCTAssertEqual(report.advisor.cacheWriteInputTokens, 5)
        XCTAssertEqual(report.advisor.outputTokens, 7)
        XCTAssertEqual(report.advisor.taskCount, 1)
        XCTAssertEqual(report.worker.totalTokens, 57)
        XCTAssertEqual(report.worker.taskCount, 1)

        let advisorCost = (35 * 5.00 + 10 * 0.50 + 5 * 6.25 + 7 * 30.00) / 1_000_000
        let workerCost = (35 * 0.20 + 10 * 0.02 + 5 * 0.25 + 7 * 1.20) / 1_000_000
        XCTAssertEqual(report.advisor.apiEquivalentCostUSD ?? -1, advisorCost, accuracy: 0.0000000001)
        XCTAssertEqual(report.worker.apiEquivalentCostUSD ?? -1, workerCost, accuracy: 0.0000000001)
        XCTAssertEqual(report.combined.apiEquivalentCostUSD ?? -1, advisorCost + workerCost, accuracy: 0.0000000001)
    }

    func testCostBreakdownSeparatesUncachedCachedAndWriteInput() {
        let totals = LaneTotals(
            inputTokens: 50,
            cachedInputTokens: 10,
            cacheWriteInputTokens: 5,
            outputTokens: 7
        )

        let breakdown = SolUsagePricing.breakdown(for: totals, model: "gpt-5.6-luna")

        XCTAssertEqual(breakdown?.uncachedInputTokens, 35)
        XCTAssertEqual(breakdown?.cachedInputTokens, 10)
        XCTAssertEqual(breakdown?.cacheWriteInputTokens, 5)
        XCTAssertEqual(breakdown?.outputTokens, 7)
        XCTAssertEqual(breakdown?.uncachedInputCostUSD ?? -1, 35 * 0.20 / 1_000_000, accuracy: 0.0000000001)
        XCTAssertEqual(breakdown?.cachedInputCostUSD ?? -1, 10 * 0.02 / 1_000_000, accuracy: 0.0000000001)
        XCTAssertEqual(breakdown?.cacheWriteCostUSD ?? -1, 5 * 0.25 / 1_000_000, accuracy: 0.0000000001)
        XCTAssertEqual(breakdown?.outputCostUSD ?? -1, 7 * 1.20 / 1_000_000, accuracy: 0.0000000001)
        let expectedCost = (35 * 0.20 + 10 * 0.02 + 5 * 0.25 + 7 * 1.20) / 1_000_000
        XCTAssertEqual(breakdown?.totalCostUSD ?? -1, expectedCost, accuracy: 0.0000000001)
    }

    func testHugeIrrelevantLineIsRejectedBeforeJSONDecoding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sol-usage-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("rollout-2026-08-03T00-00-00-filter.jsonl")
        let context = "{\"timestamp\":\"2026-08-03T10:00:00Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\",\"collaboration_mode\":{\"settings\":{\"reasoning_effort\":\"high\"}}}}\n"
        let token = "{\"timestamp\":\"2026-08-03T10:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":10,\"output_tokens\":2,\"total_tokens\":12}}}}\n"
        let irrelevant = "{\"timestamp\":\"2026-08-03T10:00:02Z\",\"type\":\"response_item\",\"payload\":{\"body\":\"" + String(repeating: "x", count: 3_000_000) + "\"}}\n"
        try Data((context + token + irrelevant).utf8).write(to: file)

        let report = UsageCollector(dataRoots: [SolUsageDataRoot(url: file, recursive: false)])
            .report(for: "2026-08-03", generatedAt: fixedGenerationDate)
        XCTAssertEqual(report.advisor.totalTokens, 12)
    }

    func testStableJSONSchemaUsesSnakeCaseFields() throws {
        let file = try fixtureFile(named: "rollout-2026-08-03T08-00-00-fixture.jsonl")
        let report = UsageCollector(dataRoots: [SolUsageDataRoot(url: file, recursive: false)])
            .report(for: "2026-08-03", generatedAt: fixedGenerationDate)

        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["advisor", "attribution_note", "combined", "date", "end_at", "generated_at", "model_usage", "other", "range", "start_at", "timezone", "worker"])
        let advisor = try XCTUnwrap(object["advisor"] as? [String: Any])
        XCTAssertEqual(Set(advisor.keys), ["api_equivalent_cost_usd", "cached_input_tokens", "cache_write_input_tokens", "input_tokens", "output_tokens", "reasoning_output_tokens", "task_count", "total_tokens"])
        let other = try XCTUnwrap(object["other"] as? [String: Any])
        XCTAssertNil(other["api_equivalent_cost_usd"])
    }

    func testDailyHistoryStoresOnlyDerivedReportsAndSortsDays() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sol-usage-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = DailyHistoryStore(home: home)
        let first = UsageReport(
            date: "2026-08-01",
            rangeIdentifier: "today",
            startAt: "",
            endAt: "",
            generatedAt: "",
            advisor: .zero,
            worker: .zero,
            combined: .zero,
            other: .zero
        )
        let second = UsageReport(
            date: "2026-08-03",
            rangeIdentifier: "today",
            startAt: "",
            endAt: "",
            generatedAt: "",
            advisor: .zero,
            worker: .zero,
            combined: .zero,
            other: .zero
        )

        store.save(first)
        store.save(second)

        XCTAssertEqual(store.dates(), ["2026-08-03", "2026-08-01"])
        XCTAssertEqual(store.report(for: "2026-08-01"), first)
        XCTAssertEqual(store.reports().map(\.date), ["2026-08-01", "2026-08-03"])
    }

    private func fixtureFile(named name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent(name))
    }

    private func isoDate(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: value))
    }

    private var fixedGenerationDate: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try! XCTUnwrap(formatter.date(from: "2026-08-03T12:00:00Z"))
    }
}
