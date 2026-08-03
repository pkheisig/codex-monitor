import AppKit
import SwiftUI
import SolUsageCore

private let allSelection = "__all__"

@MainActor
private struct UsagePopoverView: View {
    let report: UsageReport
    let dates: [String]
    let selectedDate: String
    let selectedModel: String
    let selectedIntelligence: String
    let onDateChange: (String) -> Void
    let onModelChange: (String) -> Void
    let onIntelligenceChange: (String) -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void

    private var modelOptions: [String] {
        [allSelection] + Set(report.modelUsage.map { $0.key.model }).sorted()
    }

    private var intelligenceOptions: [String] {
        [allSelection] + Set(report.modelUsage.map { $0.key.intelligence }).sorted()
    }

    private var filteredModelUsage: [ModelUsage] {
        report.modelUsage.filter { usage in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Codex Monitor")
                    .font(.headline)
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
                    title: "Sol",
                    subtitle: "GPT-5.6 Sol · high",
                    totals: report.advisor
                )
                UsageLaneCard(
                    title: "Luna",
                    subtitle: "GPT-5.6 Luna · max",
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

            if !report.other.isZero {
                Text("Other / excluded: (report.other.compactTokenCount) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Updated (report.generatedAt)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("Estimate is not Codex subscription billing.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Refresh", action: onRefresh)
                    .keyboardShortcut("r")
                Spacer()
                Button("Quit", action: onQuit)
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func dayLabel(_ date: String) -> String {
        date == SolUsageDates.today() ? "Today · \(date)" : date
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
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(subtitle)
                    .font(.caption2)
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
        .font(.caption2)
    }

    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private static let popoverWidth: CGFloat = 360

    private let collector: UsageCollector
    private let historyStore: DailyHistoryStore
    private let refreshQueue = DispatchQueue(
        label: "com.pkheisig.codex-monitor.refresh",
        qos: .utility
    )
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<UsagePopoverView>!
    private var timer: Timer?
    private var report: UsageReport
    private var todayReport: UsageReport
    private var availableDates: [String]
    private var selectedDate: String
    private var selectedModel = allSelection
    private var selectedIntelligence = allSelection

    override init() {
        let now = Date()
        let date = SolUsageDates.today(now: now)
        let history = DailyHistoryStore()
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
        report = initial
        todayReport = initial
        availableDates = history.dates()
        selectedDate = date
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.toolTip = "Codex Monitor"
        updateStatusTitle()

        popover = NSPopover()
        // A transient popover closes automatically when the user clicks
        // anywhere outside it, including another app.
        popover.behavior = .transient
        popover.animates = false
        hostingController = NSHostingController(rootView: makePopoverView())
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        resizePopover()

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestRefresh()
            }
        }
        requestRefresh()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        resizePopover()
        // .minY anchors the panel below the menu-bar item. Animations are off
        // so it never briefly draws at an oversized position above the bar.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func requestRefresh() {
        let now = Date()
        let collector = self.collector
        let history = self.historyStore
        refreshQueue.async { [weak self] in
            guard self != nil else { return }
            let next = collector.report(generatedAt: now)
            history.save(next)
            let dates = history.dates()
            Task { @MainActor [weak self] in
                self?.applyToday(next, savedDates: dates)
            }
        }
    }

    private func applyToday(_ next: UsageReport, savedDates: [String]) {
        let oldToday = SolUsageDates.today()
        let wasViewingToday = selectedDate == oldToday
        todayReport = next
        availableDates = normalizedDates(savedDates, including: next.date)
        if wasViewingToday {
            selectedDate = next.date
            report = next
        }
        normalizeSelections()
        updateStatusTitle()
        hostingController?.rootView = makePopoverView()
        resizePopover()
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
        hostingController?.rootView = makePopoverView()
        resizePopover()
    }

    private func selectModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedModel")
        hostingController?.rootView = makePopoverView()
        resizePopover()
    }

    private func selectIntelligence(_ intelligence: String) {
        selectedIntelligence = intelligence
        UserDefaults.standard.set(intelligence, forKey: "selectedIntelligence")
        hostingController?.rootView = makePopoverView()
        resizePopover()
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

    private func updateStatusTitle() {
        statusItem?.button?.title = todayReport.combined.compactTokenCount
        statusItem?.button?.setAccessibilityLabel(
            "Today's combined Codex tokens: \(todayReport.combined.totalTokens)"
        )
    }

    private func makePopoverView() -> UsagePopoverView {
        UsagePopoverView(
            report: report,
            dates: availableDates,
            selectedDate: selectedDate,
            selectedModel: selectedModel,
            selectedIntelligence: selectedIntelligence,
            onDateChange: { [weak self] date in self?.selectDate(date) },
            onModelChange: { [weak self] model in self?.selectModel(model) },
            onIntelligenceChange: { [weak self] intelligence in self?.selectIntelligence(intelligence) },
            onRefresh: { [weak self] in self?.requestRefresh() },
            onQuit: { [weak self] in self?.quit() }
        )
    }

    private func resizePopover() {
        guard let hostingController else { return }
        let view = hostingController.view
        view.invalidateIntrinsicContentSize()
        view.layoutSubtreeIfNeeded()
        let preferredHeight = hostingController.preferredContentSize.height
        let fittingHeight = max(1, preferredHeight > 1 ? preferredHeight : view.fittingSize.height)
        popover?.contentSize = NSSize(width: Self.popoverWidth, height: fittingHeight)
    }

    private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
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
