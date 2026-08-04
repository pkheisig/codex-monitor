import AppKit
import Combine
import SwiftUI
import SolUsageCore

private let allSelection = "__all__"

private final class MonitorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum MonitorView: String, CaseIterable, Identifiable {
    case ranking
    case overview
    case trend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ranking: return "Ranking"
        case .overview: return "Details"
        case .trend: return "Trend"
        }
    }
}

private enum RankingSort: String, CaseIterable, Identifiable {
    case totalTokens
    case apiCost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .totalTokens: return "Total tokens"
        case .apiCost: return "API cost"
        }
    }
}

private enum UsageMetric: String, CaseIterable, Identifiable {
    case totalTokens
    case apiCost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .totalTokens: return "Total tokens"
        case .apiCost: return "API cost"
        }
    }
}

private func displayModelName(_ model: String) -> String {
    switch model.lowercased() {
    case "gpt-5.6-sol": return "GPT-5.6 Sol"
    case "gpt-5.6-luna": return "GPT-5.6 Luna"
    case "gpt-5.6-terra": return "GPT-5.6 Terra"
    default: return model
    }
}

@MainActor
private struct UsagePopoverView: View {
    let report: UsageReport
    let savedReports: [UsageReport]
    let quota: CodexQuotaSnapshot?
    let quotaError: String?
    let dates: [String]
    let selectedDate: String
    let selectedModel: String
    let selectedIntelligence: String
    let selectedView: MonitorView
    let rankingSort: RankingSort
    let statusMetric: UsageMetric
    let trendMetric: UsageMetric
    let onDateChange: (String) -> Void
    let onModelChange: (String) -> Void
    let onIntelligenceChange: (String) -> Void
    let onViewChange: (MonitorView) -> Void
    let onRankingSortChange: (RankingSort) -> Void
    let onStatusMetricChange: (UsageMetric) -> Void
    let onTrendMetricChange: (UsageMetric) -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void
    let onResizeChanged: (CGSize) -> Void
    let onResizeEnded: () -> Void

    private var modelOptions: [String] {
        [allSelection] + Set(rankingEntries.map { $0.key.model }).sorted()
    }

    private var intelligenceOptions: [String] {
        [allSelection] + Set(rankingEntries.map { $0.key.intelligence }).sorted()
    }

    /// Older saved snapshots predate `model_usage`. Keep the ranking useful
    /// immediately after an upgrade by deriving the two exact lane entries
    /// from the totals that were already persisted.
    private var rankingEntries: [ModelUsage] {
        if !report.modelUsage.isEmpty { return report.modelUsage }

        var fallback: [ModelUsage] = []
        if !report.advisor.isZero {
            fallback.append(ModelUsage(
                key: UsageModelKey(model: "gpt-5.6-sol", intelligence: "high"),
                totals: report.advisor
            ))
        }
        if !report.worker.isZero {
            fallback.append(ModelUsage(
                key: UsageModelKey(model: "gpt-5.6-luna", intelligence: "max"),
                totals: report.worker
            ))
        }
        return fallback
    }

    private var filteredModelUsage: [ModelUsage] {
        rankingEntries.filter { usage in
            (selectedModel == allSelection || usage.key.model == selectedModel) &&
                (selectedIntelligence == allSelection || usage.key.intelligence == selectedIntelligence)
        }
    }

    private var selectedTotals: LaneTotals {
        var totals = LaneTotals.zero
        for usage in filteredModelUsage {
            totals.add(usage.totals)
        }
        return totals
    }

    private var hasSpecificSelection: Bool {
        selectedModel != allSelection || selectedIntelligence != allSelection
    }

    private var selectionSummary: String {
        let model = selectedModel == allSelection ? "All models" : modelLabel(selectedModel)
        let intelligence = selectedIntelligence == allSelection ? "all intelligence" : selectedIntelligence
        return "\(model) · \(intelligence)"
    }

    private var cacheBreakdownLines: [CacheBreakdownLine] {
        if !filteredModelUsage.isEmpty {
            let lines: [CacheBreakdownLine] = filteredModelUsage.compactMap { usage in
                guard let breakdown = SolUsagePricing.breakdown(for: usage.totals, model: usage.key.model) else {
                    return nil
                }
                return CacheBreakdownLine(
                    id: usage.key.id,
                    label: "\(displayModelName(usage.key.model)) · \(usage.key.intelligence)",
                    breakdown: breakdown
                )
            }
            if !lines.isEmpty { return lines }
        }

        if selectedModel != allSelection,
           let breakdown = SolUsagePricing.breakdown(for: selectedTotals, model: selectedModel),
           !breakdownIsEmpty(breakdown) {
            return [CacheBreakdownLine(
                id: selectedModel,
                label: selectionSummary,
                breakdown: breakdown
            )]
        }

        if selectedModel == allSelection && selectedIntelligence == allSelection {
            return [
                ("GPT-5.6 Sol · high", SolUsagePricing.breakdown(for: report.advisor, lane: .advisor)),
                ("GPT-5.6 Luna · max", SolUsagePricing.breakdown(for: report.worker, lane: .worker))
            ].compactMap { label, breakdown in
                guard let breakdown, !breakdownIsEmpty(breakdown) else { return nil }
                return CacheBreakdownLine(id: label, label: label, breakdown: breakdown)
            }
        }

        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Codex Monitor")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text(report.date == SolUsageDates.today() ? "Today" : report.date)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Picker("Day", selection: Binding(
                    get: { selectedDate },
                    set: onDateChange
                )) {
                    ForEach(dates, id: \.self) { date in
                        Text(dayLabel(date)).tag(date)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("saved")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Picker("View", selection: Binding(
                    get: { selectedView },
                    set: onViewChange
                )) {
                    ForEach(MonitorView.allCases) { view in
                        Text(view.title).tag(view)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Text("Menu bar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Menu bar metric", selection: Binding(
                    get: { statusMetric },
                    set: onStatusMetricChange
                )) {
                    ForEach(UsageMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    CodexQuotaView(snapshot: quota, errorMessage: quotaError)

                    if selectedView == .overview {
                        HStack(spacing: 8) {
                            Picker("Model", selection: Binding(
                                get: { selectedModel },
                                set: onModelChange
                            )) {
                                Text("All models").tag(allSelection)
                                ForEach(modelOptions.dropFirst(), id: \.self) { model in
                                    Text(modelLabel(model)).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Picker("Intelligence", selection: Binding(
                                get: { selectedIntelligence },
                                set: onIntelligenceChange
                            )) {
                                Text("All intelligence").tag(allSelection)
                                ForEach(intelligenceOptions.dropFirst(), id: \.self) { intelligence in
                                    Text(intelligence).tag(intelligence)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if hasSpecificSelection {
                            UsageLaneCard(
                                title: "Selected usage",
                                subtitle: selectionSummary,
                                totals: selectedTotals
                            )
                        } else {
                            UsageLaneCard(
                                title: "GPT-5.6 Sol",
                                subtitle: "high",
                                totals: report.advisor
                            )
                            UsageLaneCard(
                                title: "GPT-5.6 Luna",
                                subtitle: "max",
                                totals: report.worker
                            )
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hasSpecificSelection ? "Selected total" : "Combined")
                                    .font(.headline)
                                Text("API-equivalent estimate")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                let totals = hasSpecificSelection ? selectedTotals : report.combined
                                Text(totals.compactTokenCount)
                                    .font(.headline.monospacedDigit())
                                Text(money(totals.apiEquivalentCostUSD))
                                    .font(.subheadline.monospacedDigit())
                            }
                        }

                        CacheBreakdownView(lines: cacheBreakdownLines)
                    } else if selectedView == .ranking {
                        ModelRankingView(
                            entries: rankingEntries,
                            sort: rankingSort,
                            onSortChange: onRankingSortChange
                        )
                    } else {
                        DailyTrendView(
                            reports: savedReports,
                            metric: trendMetric,
                            onMetricChange: onTrendMetricChange
                        )
                    }

                    if !report.other.isZero {
                        Text("Other / excluded: \(report.other.compactTokenCount) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The AppKit panel owns the height. Keeping this view flexible
            // makes the native resize handle reveal more or less of the list
            // instead of forcing the panel back to a fixed SwiftUI height.
            .frame(maxHeight: .infinity, alignment: .top)

            Text("Updated \(SolUsageDates.displayTimestamp(report.generatedAt))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("Estimate is not Codex subscription billing.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Refresh", action: onRefresh)
                    .keyboardShortcut("r", modifiers: [.command])
                Spacer()
                Button("Quit", action: onQuit)
                    .keyboardShortcut("q")
            }
        }
        .font(.system(size: 14))
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in onResizeChanged(value.translation) }
                        .onEnded { _ in onResizeEnded() }
                )
                .help("Resize Codex Monitor")
        }
    }

    private func dayLabel(_ date: String) -> String {
        date == SolUsageDates.today()
            ? "Today · \(SolUsageDates.displayDate(date))"
            : SolUsageDates.displayDate(date)
    }

    private func modelLabel(_ model: String) -> String {
        switch model.lowercased() {
        case "gpt-5.6-sol": return "GPT-5.6 Sol"
        case "gpt-5.6-luna": return "GPT-5.6 Luna"
        case "gpt-5.6-terra": return "GPT-5.6 Terra"
        default: return model
        }
    }

    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }
}

private struct CodexQuotaView: View {
    let snapshot: CodexQuotaSnapshot?
    let errorMessage: String?

    private var visibleWindows: [CodexQuotaWindow] {
        guard let snapshot else { return [] }
        var result: [CodexQuotaWindow] = []
        if let weekly = snapshot.weekly { result.append(weekly) }
        if let spark = snapshot.sparkWeekly, !result.contains(where: { $0.id == spark.id }) {
            result.append(spark)
        }
        for window in snapshot.windows where !result.contains(where: { $0.id == window.id }) {
            result.append(window)
        }
        if let codeReview = snapshot.codeReview,
           !result.contains(where: { $0.id == codeReview.id })
        {
            result.append(codeReview)
        }
        return result
    }

    var body: some View {
        GroupBox {
            if let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let email = snapshot.accountEmail, !email.isEmpty {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let plan = snapshot.plan, !plan.isEmpty {
                            Text(plan.capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(visibleWindows) { window in
                        quotaWindow(window)
                    }

                    if let credits = snapshot.creditsRemaining {
                        Divider()
                        HStack {
                            Text("Credits")
                            Spacer()
                            Text(String(format: "%.2f left", credits))
                                .font(.subheadline.monospacedDigit())
                        }
                    }

                    HStack {
                        Text("Updated \(SolUsageDates.displayTimestamp(SolUsageDates.isoString(for: snapshot.fetchedAt)))")
                        Spacer()
                        if let errorMessage, !errorMessage.isEmpty {
                            Text("stale")
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex limits")
                        .font(.subheadline.weight(.semibold))
                    Text(errorMessage ?? "Waiting for the authenticated Codex usage response…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("Codex limits")
                .font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder
    private func quotaWindow(_ window: CodexQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.body.weight(.semibold))
                Spacer()
                if window.usageKnown {
                    Text("\(percent(window.remainingPercent))% left")
                        .font(.subheadline.monospacedDigit())
                } else {
                    Text("Usage unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if window.usageKnown {
                ProgressView(value: window.remainingPercent, total: 100)
                    .tint(.accentColor)
            }

            HStack(alignment: .firstTextBaseline) {
                if let pace = window.pace() {
                    if pace.deficitPercent >= 0.5 {
                        Text("\(percent(pace.deficitPercent))% in deficit")
                    } else {
                        Text("On pace")
                    }
                }
                Spacer()
                if let resetsAt = window.resetsAt {
                    Text("Resets in \(duration(until: resetsAt))")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if let pace = window.pace(), let runsOutIn = pace.runsOutIn {
                HStack {
                    Spacer()
                    Text(runsOutIn == 0 ? "Exhausted" : "Runs out in \(duration(seconds: runsOutIn))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func percent(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private func duration(until date: Date) -> String {
        duration(seconds: max(0, date.timeIntervalSinceNow))
    }

    private func duration(seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

private struct CacheBreakdownLine: Identifiable {
    let id: String
    let label: String
    let breakdown: UsageCostBreakdown
}

private func breakdownIsEmpty(_ breakdown: UsageCostBreakdown) -> Bool {
    breakdown.uncachedInputTokens == 0 &&
        breakdown.cachedInputTokens == 0 &&
        breakdown.cacheWriteInputTokens == 0 &&
        breakdown.outputTokens == 0
}

private struct CacheBreakdownView: View {
    let lines: [CacheBreakdownLine]

    var body: some View {
        GroupBox {
            if lines.isEmpty {
                Text("No priced cache data for this selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.label)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            cacheRow("Uncached input", line.breakdown.uncachedInputTokens, line.breakdown.uncachedInputCostUSD)
                            cacheRow("Cached input", line.breakdown.cachedInputTokens, line.breakdown.cachedInputCostUSD)
                            cacheRow("Cache writes", line.breakdown.cacheWriteInputTokens, line.breakdown.cacheWriteCostUSD)
                            cacheRow("Output", line.breakdown.outputTokens, line.breakdown.outputCostUSD)
                        }
                        if index < lines.count - 1 {
                            Divider()
                        }
                    }
                    Text("Cached input and cache writes use their own API rates.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        } label: {
            HStack {
                Text("Cache breakdown")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("tokens · cost")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cacheRow(_ label: String, _ tokens: Int64, _ cost: Double) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption)
            Spacer(minLength: 4)
            Text(CompactTokenFormatter.string(for: tokens))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(money(cost))
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func money(_ value: Double) -> String {
        if value < 1 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }
}

private struct DailyTrendView: View {
    let reports: [UsageReport]
    let metric: UsageMetric
    let onMetricChange: (UsageMetric) -> Void

    private var orderedReports: [UsageReport] {
        reports.sorted { $0.date < $1.date }
    }

    private var maximumValue: Double {
        max(orderedReports.map(metricValue).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily trend")
                        .font(.headline)
                    Text("Combined saved usage · \(orderedReports.count) day\(orderedReports.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Trend metric", selection: Binding(
                    get: { metric },
                    set: onMetricChange
                )) {
                    ForEach(UsageMetric.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if orderedReports.isEmpty {
                Text("The trend starts after the monitor saves its first day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(orderedReports, id: \.date) { report in
                            DailyTrendBar(
                                value: metricValue(report),
                                maximumValue: maximumValue,
                                valueLabel: metricLabel(report),
                                dateLabel: String(report.date.suffix(5))
                            )
                        }
                    }
                    .frame(minWidth: max(CGFloat(orderedReports.count) * 66, 328), alignment: .leading)
                    .padding(.horizontal, 2)
                }
                .frame(height: 156)

                HStack {
                    Text("Each bar is one saved Berlin calendar day.")
                    Spacer()
                    Text(metric.title)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func metricValue(_ report: UsageReport) -> Double {
        switch metric {
        case .totalTokens: return Double(report.combined.totalTokens)
        case .apiCost: return report.combined.apiEquivalentCostUSD ?? 0
        }
    }

    private func metricLabel(_ report: UsageReport) -> String {
        switch metric {
        case .totalTokens: return CompactTokenFormatter.string(for: report.combined.totalTokens)
        case .apiCost: return money(report.combined.apiEquivalentCostUSD)
        }
    }

    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }
}

private struct DailyTrendBar: View {
    let value: Double
    let maximumValue: Double
    let valueLabel: String
    let dateLabel: String

    private var barHeight: CGFloat {
        max(4, CGFloat(value / maximumValue) * 100)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(valueLabel)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .frame(width: 58)
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.82))
                .frame(width: 28, height: barHeight)
            Text(dateLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 58, height: 150, alignment: .bottom)
    }
}

private struct ModelRankingView: View {
    let entries: [ModelUsage]
    let sort: RankingSort
    let onSortChange: (RankingSort) -> Void

    private var rankedEntries: [ModelUsage] {
        entries.sorted { lhs, rhs in
            switch sort {
            case .totalTokens:
                if lhs.totals.totalTokens != rhs.totals.totalTokens {
                    return lhs.totals.totalTokens > rhs.totals.totalTokens
                }
            case .apiCost:
                let leftCost = lhs.totals.apiEquivalentCostUSD ?? -Double.infinity
                let rightCost = rhs.totals.apiEquivalentCostUSD ?? -Double.infinity
                if leftCost != rightCost {
                    return leftCost > rightCost
                }
            }
            return lhs.key.id < rhs.key.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model ranking")
                        .font(.headline)
                    Text("Each row is one model + reasoning pair")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Rank by", selection: Binding(
                    get: { sort },
                    set: onSortChange
                )) {
                    ForEach(RankingSort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if rankedEntries.isEmpty {
                Text("No attributed model usage for this day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rankedEntries.enumerated()), id: \.offset) { index, entry in
                        ModelRankingRow(rank: index + 1, entry: entry)
                    }
                }
            }
        }
    }
}

private struct ModelRankingRow: View {
    let rank: Int
    let entry: ModelUsage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("#\(rank)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(displayModelName(entry.key.model)) · \(entry.key.intelligence)")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text("In \(CompactTokenFormatter.string(for: entry.totals.inputTokens)) · Out \(CompactTokenFormatter.string(for: entry.totals.outputTokens))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.totals.compactTokenCount)
                    .font(.body.monospacedDigit())
                Text(money(entry.totals.apiEquivalentCostUSD))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }
}

private struct UsageLaneCard: View {
    let title: String
    let subtitle: String
    let totals: LaneTotals

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Total tokens")
                    Spacer()
                    Text(totals.compactTokenCount)
                        .font(.headline.monospacedDigit())
                }
                HStack {
                    Text("API-equivalent")
                    Spacer()
                    Text(money(totals.apiEquivalentCostUSD))
                        .font(.subheadline.monospacedDigit())
                }
                Divider()
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 4
                ) {
                    metric("Input", totals.inputTokens)
                    metric("Cached", totals.cachedInputTokens)
                    metric("Cache writes", totals.cacheWriteInputTokens)
                    metric("Output", totals.outputTokens)
                    metric("Reasoning", totals.reasoningOutputTokens)
                    metric("Tasks", Int64(totals.taskCount))
                }
            }
        } label: {
            HStack {
                Text(title)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func metric(_ label: String, _ value: Int64) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal))
                .monospacedDigit()
        }
        .font(.caption)
    }

    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject, @unchecked Sendable {
    private static let selectedViewDefaultsKey = "selectedView.v2"
    private static let statusItemAutosaveName = "com.pkheisig.codexmonitor.primary-status-item"
    private static let defaultPanelSize = NSSize(width: 300, height: 560)
    private static let minimumPanelSize = NSSize(width: 280, height: 320)
    private static let maximumPanelSize = NSSize(width: 520, height: 980)
    private static let panelWidthDefaultsKey = "panelWidth"
    private static let panelHeightDefaultsKey = "panelHeight"
    private static let panelSizeConfiguredKey = "panelSizeConfigured.v1"

    private let collector: UsageCollector
    private let historyStore: DailyHistoryStore
    private let quotaFetcher: CodexQuotaFetcher
    private let quotaStore: CodexQuotaStore
    private let refreshQueue = DispatchQueue(
        label: "com.pkheisig.codexmonitor.refresh",
        qos: .utility
    )
    private var timer: Timer?
    private var statusItem: NSStatusItem!
    private var panel: MonitorPanel!
    private var hostingController: NSHostingController<UsagePopoverView>!
    private var outsideClickMonitor: Any?
    private var resizeStartFrame: NSRect?
    private var suppressPanelPersistence = true
    @Published private(set) var report: UsageReport
    @Published private(set) var todayReport: UsageReport
    @Published private(set) var savedReports: [UsageReport]
    @Published private(set) var availableDates: [String]
    @Published private(set) var quota: CodexQuotaSnapshot?
    @Published private(set) var quotaError: String?
    @Published private(set) var selectedDate: String
    @Published private(set) var selectedModel = allSelection
    @Published private(set) var selectedIntelligence = allSelection
    @Published private(set) var selectedView: MonitorView
    @Published private(set) var rankingSort: RankingSort
    @Published private(set) var statusMetric: UsageMetric
    @Published private(set) var trendMetric: UsageMetric

    override init() {
        let now = Date()
        let date = SolUsageDates.today(now: now)
        let history = DailyHistoryStore()
        let quotaStore = CodexQuotaStore()
        let localAccountID = CodexQuotaFetcher.localAccountID()
        let start = SolUsageDates.startOfDay(for: date) ?? now
        let empty = UsageReport(
            date: date,
            rangeIdentifier: "today",
            startAt: SolUsageDates.isoString(for: start),
            endAt: SolUsageDates.isoString(for: now),
            generatedAt: SolUsageDates.isoString(for: now),
            advisor: .zero,
            worker: .zero,
            combined: .zero,
            other: .zero
        )
        let initial = history.report(for: date) ?? empty
        collector = UsageCollector()
        historyStore = history
        quotaFetcher = CodexQuotaFetcher()
        self.quotaStore = quotaStore
        report = initial
        todayReport = initial
        savedReports = history.reports()
        availableDates = history.dates()
        // Never show a cached account's limits before the active Codex auth
        // has been identified. This prevents a second account on the same Mac
        // from briefly seeing the previous account's quota.
        quota = quotaStore.load().flatMap { cached in
            guard let localAccountID,
                  let cachedAccountID = cached.accountID,
                  cachedAccountID == localAccountID
            else { return nil }
            return cached
        }
        quotaError = nil
        selectedDate = date
        selectedView = MonitorView(
            rawValue: UserDefaults.standard.string(forKey: Self.selectedViewDefaultsKey) ?? ""
        ) ?? .ranking
        rankingSort = RankingSort(
            rawValue: UserDefaults.standard.string(forKey: "rankingSort") ?? ""
        ) ?? .totalTokens
        statusMetric = UsageMetric(
            rawValue: UserDefaults.standard.string(forKey: "statusMetric") ?? ""
        ) ?? .totalTokens
        trendMetric = UsageMetric(
            rawValue: UserDefaults.standard.string(forKey: "trendMetric") ?? ""
        ) ?? .totalTokens
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Use the same native status-item lifecycle as Parrot. The panel is
        // intentionally resizable; unlike a SwiftUI MenuBarExtra popover,
        // AppKit keeps the user's chosen height instead of restoring a
        // remembered natural size.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.statusItemAutosaveName
        statusItem.behavior = []
        statusItem.isVisible = true
        configureStatusButton()

        let panelSize = Self.savedPanelSize()
        let panel = MonitorPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = Self.minimumPanelSize
        panel.maxSize = Self.maximumPanelSize
        panel.contentMinSize = Self.minimumPanelSize
        panel.contentMaxSize = Self.maximumPanelSize
        panel.delegate = self
        self.panel = panel

        hostingController = NSHostingController(rootView: makePopoverView())
        // Let the panel, not SwiftUI's preferred content size, own resizing.
        hostingController.sizingOptions = []
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hostingController
        panel.setFrame(
            NSRect(origin: panel.frame.origin, size: panelSize),
            display: false
        )
        suppressPanelPersistence = false
        installOutsideClickMonitor()

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestRefresh()
            }
        }
        requestRefresh()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: "chart.bar.fill",
            accessibilityDescription: "Codex Monitor"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleProportionallyDown
        button.title = statusLabel
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Codex Monitor"
        button.setAccessibilityTitle("Codex Monitor")
        button.setAccessibilityLabel("Codex Monitor: \(statusLabel)")
        button.appearsDisabled = false
    }

    @objc private func togglePopover(_ sender: Any?) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func requestRefresh() {
        let now = Date()
        let activeAccountID = CodexQuotaFetcher.localAccountID()
        let collector = self.collector
        let history = self.historyStore
        let quotaFetcher = self.quotaFetcher
        let quotaStore = self.quotaStore
        refreshQueue.async { [weak self] in
            guard self != nil else { return }
            let next = collector.report(generatedAt: now)
            history.save(next)
            let reports = history.reports()
            let dates = reports.map(\.date)
            Task.detached(priority: .utility) { [weak self] in
                var freshQuota: CodexQuotaSnapshot?
                var quotaError: String?
                do {
                    freshQuota = try await quotaFetcher.fetch(now: now)
                    if let freshQuota {
                        quotaStore.save(freshQuota)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    quotaError = error.localizedDescription
                }
                await MainActor.run {
                    self?.applyToday(
                        next,
                        savedDates: dates,
                        savedReports: reports,
                        quota: freshQuota,
                        quotaError: quotaError,
                        activeAccountID: activeAccountID)
                }
            }
        }
    }

    private func applyToday(
        _ next: UsageReport,
        savedDates: [String],
        savedReports: [UsageReport],
        quota: CodexQuotaSnapshot?,
        quotaError: String?,
        activeAccountID: String?)
    {
        // An account switch can happen while the monitor is running. Never
        // leave the previous account's cached limits visible while the new
        // session is offline or the first refresh is still in flight.
        if let quota, let activeAccountID, quota.accountID == activeAccountID {
            self.quota = quota
        } else if activeAccountID == nil || self.quota?.accountID != activeAccountID {
            self.quota = nil
        }
        let oldToday = SolUsageDates.today()
        let wasViewingToday = selectedDate == oldToday
        self.quotaError = quotaError
        todayReport = next
        self.savedReports = normalizedReports(savedReports, including: next)
        availableDates = normalizedDates(savedDates, including: next.date)
        if wasViewingToday {
            selectedDate = next.date
            report = next
        }
        normalizeSelections()
        refreshPanel()
        updateStatusItem()
    }

    private func selectDate(_ date: String) {
        guard availableDates.contains(date) else { return }
        selectedDate = date
        UserDefaults.standard.set(date, forKey: "selectedDate")

        if date == SolUsageDates.today() {
            report = todayReport
            requestRefresh()
        } else if let saved = historyStore.report(for: date) {
            report = saved
        } else {
            return
        }
        normalizeSelections()
        refreshPanel()
    }

    private func selectModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedModel")
        refreshPanel()
    }

    private func selectIntelligence(_ intelligence: String) {
        selectedIntelligence = intelligence
        UserDefaults.standard.set(intelligence, forKey: "selectedIntelligence")
        refreshPanel()
    }

    private func selectView(_ view: MonitorView) {
        selectedView = view
        UserDefaults.standard.set(view.rawValue, forKey: Self.selectedViewDefaultsKey)
        refreshPanel()
    }

    private func selectRankingSort(_ sort: RankingSort) {
        rankingSort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: "rankingSort")
        refreshPanel()
    }

    private func selectStatusMetric(_ metric: UsageMetric) {
        statusMetric = metric
        UserDefaults.standard.set(metric.rawValue, forKey: "statusMetric")
        refreshPanel()
        updateStatusItem()
    }

    private func selectTrendMetric(_ metric: UsageMetric) {
        trendMetric = metric
        UserDefaults.standard.set(metric.rawValue, forKey: "trendMetric")
        refreshPanel()
    }

    private func normalizeSelections() {
        let models = Set(report.modelUsage.map { $0.key.model })
        let intelligence = Set(report.modelUsage.map { $0.key.intelligence })
        if selectedModel != allSelection && !models.contains(selectedModel) {
            selectedModel = allSelection
        }
        if selectedIntelligence != allSelection && !intelligence.contains(selectedIntelligence) {
            selectedIntelligence = allSelection
        }
    }

    private func normalizedDates(_ dates: [String], including today: String) -> [String] {
        Array(Set(dates + [today])).sorted(by: >)
    }

    private func normalizedReports(_ reports: [UsageReport], including today: UsageReport) -> [UsageReport] {
        var byDate = Dictionary(uniqueKeysWithValues: reports.map { ($0.date, $0) })
        byDate[today.date] = today
        return byDate.values.sorted { $0.date < $1.date }
    }

    fileprivate var statusLabel: String {
        switch statusMetric {
        case .totalTokens:
            return todayReport.combined.compactTokenCount
        case .apiCost:
            return money(todayReport.combined.apiEquivalentCostUSD)
        }
    }

    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }

    fileprivate func makePopoverView() -> UsagePopoverView {
        UsagePopoverView(
            report: report,
            savedReports: savedReports,
            quota: quota,
            quotaError: quotaError,
            dates: availableDates,
            selectedDate: selectedDate,
            selectedModel: selectedModel,
            selectedIntelligence: selectedIntelligence,
            selectedView: selectedView,
            rankingSort: rankingSort,
            statusMetric: statusMetric,
            trendMetric: trendMetric,
            onDateChange: { [weak self] date in self?.selectDate(date) },
            onModelChange: { [weak self] model in self?.selectModel(model) },
            onIntelligenceChange: { [weak self] intelligence in self?.selectIntelligence(intelligence) },
            onViewChange: { [weak self] view in self?.selectView(view) },
            onRankingSortChange: { [weak self] sort in self?.selectRankingSort(sort) },
            onStatusMetricChange: { [weak self] metric in self?.selectStatusMetric(metric) },
            onTrendMetricChange: { [weak self] metric in self?.selectTrendMetric(metric) },
            onRefresh: { [weak self] in self?.requestRefresh() },
            onQuit: { [weak self] in self?.quit() },
            onResizeChanged: { [weak self] translation in self?.resizePanel(by: translation) },
            onResizeEnded: { [weak self] in self?.finishPanelResize() }
        )
    }

    private func refreshPanel() {
        guard hostingController != nil else { return }
        hostingController.rootView = makePopoverView()
        hostingController.view.needsLayout = true
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.title = statusLabel
        button.setAccessibilityLabel("Codex Monitor: \(statusLabel)")
        button.appearsDisabled = false
    }

    private func showPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        refreshPanel()

        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        var screen = NSScreen.main
        for candidate in NSScreen.screens {
            if candidate.frame.contains(NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)) {
                screen = candidate
                break
            }
        }
        let visibleFrame = screen?.visibleFrame ?? .zero
        var origin = NSPoint(
            x: buttonFrame.midX - panel.frame.width / 2,
            y: buttonFrame.minY - panel.frame.height - 8
        )
        origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - panel.frame.width - 8)
        origin.y = max(origin.y, visibleFrame.minY + 8)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel.orderOut(nil)
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible, self.resizeStartFrame == nil else { return }
                let mouseLocation = NSEvent.mouseLocation
                if self.panel.frame.contains(mouseLocation) { return }
                if let button = self.statusItem?.button,
                   let buttonWindow = button.window,
                   buttonWindow.convertToScreen(button.frame).contains(mouseLocation) {
                    return
                }
                self.hidePanel()
            }
        }
    }

    private static func savedPanelSize() -> NSSize {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: panelSizeConfiguredKey) else { return defaultPanelSize }
        let width = defaults.double(forKey: panelWidthDefaultsKey)
        let height = defaults.double(forKey: panelHeightDefaultsKey)
        guard width > 0, height > 0 else { return defaultPanelSize }
        return NSSize(
            width: min(max(width, minimumPanelSize.width), maximumPanelSize.width),
            height: min(max(height, minimumPanelSize.height), maximumPanelSize.height)
        )
    }

    private func resizePanel(by translation: CGSize) {
        guard let panel else { return }
        if resizeStartFrame == nil {
            resizeStartFrame = panel.frame
        }
        guard let startFrame = resizeStartFrame else { return }

        let width = min(
            max(startFrame.width + translation.width, Self.minimumPanelSize.width),
            Self.maximumPanelSize.width
        )
        let height = min(
            max(startFrame.height + translation.height, Self.minimumPanelSize.height),
            Self.maximumPanelSize.height
        )
        var frame = startFrame
        frame.size = NSSize(width: width, height: height)
        // Keep the top edge anchored below the menu bar while the bottom edge
        // follows the drag, just like a native bottom-right resize handle.
        frame.origin.y = startFrame.maxY - height
        panel.setFrame(frame, display: true)
    }

    private func finishPanelResize() {
        persistPanelSize()
        resizeStartFrame = nil
    }

    private func persistPanelSize() {
        guard let panel, !suppressPanelPersistence else { return }
        let defaults = UserDefaults.standard
        defaults.set(panel.frame.width, forKey: Self.panelWidthDefaultsKey)
        defaults.set(panel.frame.height, forKey: Self.panelHeightDefaultsKey)
        defaults.set(true, forKey: Self.panelSizeConfiguredKey)
    }

    func windowDidResize(_ notification: Notification) {
        persistPanelSize()
    }

    private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }
}

@main
private struct SolUsageMonitorMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
