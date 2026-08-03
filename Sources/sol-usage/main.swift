import Darwin
import Foundation
import SolUsageCore

private struct Options {
    var json = false
    var watch = false
    var date: String?
}

private let usageText = """
Usage: codex-monitor [--json] [--watch] [--date YYYY-MM-DD]

  --json              Emit the stable JSON report schema.
  --watch             Refresh every 30 seconds until interrupted.
  --date YYYY-MM-DD   Show a saved daily snapshot (today is refreshed live).
"""

private func fail(_ message: String) -> Never {
    let output = "codex-monitor: \(message)\n\n\(usageText)"
    FileHandle.standardError.write(Data(output.utf8))
    exit(2)
}

private func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--json":
            options.json = true
        case "--watch":
            options.watch = true
        case "--date":
            index += 1
            guard index < arguments.count else { fail("--date needs YYYY-MM-DD") }
            options.date = arguments[index]
        case "--help", "-h":
            print(usageText)
            exit(0)
        default:
            fail("unknown option \(arguments[index])")
        }
        index += 1
    }

    if let date = options.date, !SolUsageDates.isValidDate(date) {
        fail("invalid date \(date); expected a real YYYY-MM-DD date")
    }
    return options
}

private func number(_ value: Int64) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}

private func money(_ value: Double?) -> String? {
    guard let value else { return nil }
    if value < 1 { return String(format: "$%.4f", value) }
    return String(format: "$%.2f", value)
}

private func printLane(_ name: String, _ totals: LaneTotals, includeCost: Bool) {
    let cost = includeCost ? money(totals.apiEquivalentCostUSD) : nil
    if let cost {
        print("\(name): \(totals.compactTokenCount) tokens · \(cost) API-equivalent estimate")
    } else {
        print("\(name): \(totals.compactTokenCount) tokens")
    }
    print("  total tokens:          \(number(totals.totalTokens))")
    print("  input tokens:          \(number(totals.inputTokens))")
    print("  cached input tokens:   \(number(totals.cachedInputTokens))")
    print("  cache-write tokens:    \(number(totals.cacheWriteInputTokens))")
    print("  output tokens:         \(number(totals.outputTokens))")
    print("  reasoning output:      \(number(totals.reasoningOutputTokens))")
    print("  tasks:                 \(totals.taskCount)")
}

private func printHuman(_ report: UsageReport) {
    print("Codex Monitor — Today / \(report.date) (\(report.timezone))")
    print("Interval: \(report.startAt) through \(report.endAt)")
    printLane("Sol     [gpt-5.6-sol / high]", report.advisor, includeCost: true)
    printLane("Luna    [gpt-5.6-luna / max]", report.worker, includeCost: true)
    printLane("Combined", report.combined, includeCost: true)
    if !report.other.isZero {
        print("Other / excluded: \(report.other.compactTokenCount) tokens (not included above)")
    }
    print("Last refresh: \(report.generatedAt)")
    print("API-equivalent estimate; not Codex subscription billing.")
}

private func printJSON(_ report: UsageReport) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(report) else { fail("could not encode report") }
    var output = data
    output.append(0x0A)
    FileHandle.standardOutput.write(output)
}

private let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
private let collector = UsageCollector()
private let history = DailyHistoryStore()

while true {
    let now = Date()
    let requestedDate = options.date
    let today = SolUsageDates.today(now: now)
    let report: UsageReport
    if let requestedDate, requestedDate != today {
        guard let saved = history.report(for: requestedDate) else {
            fail("no saved snapshot for \(requestedDate); history starts when the monitor runs")
        }
        report = saved
    } else {
        report = collector.report(generatedAt: now)
        history.save(report)
    }
    if options.json {
        printJSON(report)
    } else {
        printHuman(report)
    }

    if !options.watch { break }
    Thread.sleep(forTimeInterval: 30)
}

exit(0)
