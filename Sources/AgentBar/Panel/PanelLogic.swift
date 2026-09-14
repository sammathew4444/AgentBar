import Foundation

/// The display rules of agents/Panel.qml and Main.qml, as pure functions. Names follow the QML.
enum PanelLogic {
    struct Window: Equatable, Sendable {
        var title: String
        var percent: Double
        var resetAt: String
    }

    struct ModelRow: Equatable, Sendable {
        var name: String
        var total: Int
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
    }

    // MARK: - Providers (Main.qml)

    /// `providerHasData`: an agent earns a tab by having produced numbers.
    static func providerHasData(_ record: UsageRecord) -> Bool {
        record.totalPrompts > 0 || record.totalSessions > 0 || record.activeDays > 0
            || record.todayPrompts > 0 || record.todaySessions > 0 || !record.limits.isEmpty
            || record.balance != nil
    }

    // MARK: - Limits

    static func windowIsLong(_ text: String) -> Bool {
        text.contains("week") || text.contains("7-day") || text.contains("seven")
            || text.contains("month") || text.contains("30-day")
    }

    static func windowSpanMs(_ label: String) -> Double {
        let text = label.lowercased()
        if text.contains("month") || text.contains("30-day") { return 30 * 24 * 3600 * 1000 }
        if windowIsLong(text) { return 7 * 24 * 3600 * 1000 }
        if let match = text.firstMatch(of: /(\d+)\s*-?\s*h(?:our)?\b/.wordBoundaryKind(.simple)) {
            return (Double(String(match.1)) ?? 0) * 3600 * 1000
        }
        if let match = text.firstMatch(of: /(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/.wordBoundaryKind(.simple)) {
            return (Double(String(match.1)) ?? 0) * 60 * 1000
        }
        return 0
    }

    static func windowTitle(_ label: String) -> String {
        let text = label.lowercased()
        if text.contains("month") { return "Monthly" }
        if windowIsLong(text) { return "Weekly" }
        if text.contains("session") || windowSpanMs(label) > 0 { return "Session" }
        let plain = label.replacing(/\s*\(.*\)\s*/, with: "", maxReplacements: 1).trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? "Limit" : plain
    }

    /// `limitWindows`: a collector's explicit title beats reading one out of the label.
    static func limitWindows(_ record: UsageRecord?) -> [Window] {
        (record?.limits ?? []).filter { $0.percent >= 0 }.map { limit in
            let title = limit.title ?? ""
            return Window(title: title.isEmpty ? windowTitle(limit.label) : title, percent: limit.percent, resetAt: limit.resetsAt)
        }
    }

    /// `bindingWindow`: the fullest window, since that is what stops the next prompt.
    static func bindingWindow(_ record: UsageRecord?) -> Window? {
        var best: Window?
        for window in limitWindows(record) where best == nil || window.percent > best!.percent {
            best = window
        }
        return best
    }

    static func resetMs(_ window: Window, now: Date) -> Double {
        guard let resetsAt = OmarchyDate.parse(window.resetAt) else { return -1 }
        return (resetsAt.timeIntervalSince(now)) * 1000
    }

    static func formatDuration(_ ms: Double) -> String {
        guard ms > 0 else { return "now" }
        let minutes = Int((ms / 60000).rounded(.down))
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(max(1, minutes))m"
    }

    /// LimitRow's value text.
    static func percentText(_ window: Window) -> String {
        window.percent >= 0 ? "\(Int((window.percent * 100).rounded(.toNearestOrAwayFromZero)))%" : "—"
    }

    /// LimitRow's reset line.
    static func resetText(_ window: Window, now: Date) -> String {
        let remaining = resetMs(window, now: now)
        return remaining > 0 ? "Resets in " + formatDuration(remaining) : ""
    }

    // MARK: - Balance

    static func currencyPrefix(_ currency: String) -> String {
        let code = (currency.isEmpty ? "USD" : currency).uppercased()
        switch code {
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        default: return code + " "
        }
    }

    static func formatMoney(_ value: Double, currency: String) -> String {
        currencyPrefix(currency) + String(format: "%.2f", value.isFinite ? value : 0)
    }

    static func balanceDetailText(_ balance: UsageRecord.Balance?) -> String {
        guard let balance, balance.funded > 0 else { return "" }
        var text = formatMoney(balance.spent, currency: balance.currency) + " spent of "
            + formatMoney(balance.funded, currency: balance.currency) + " funded"
        if balance.estimated { text += " · estimated" }
        return text
    }

    /// The meter shows what is left: -1 when there is no funded amount to measure against.
    static func balanceRatio(_ balance: UsageRecord.Balance?) -> Double {
        guard let balance, balance.funded > 0 else { return -1 }
        return min(1, max(0, balance.remaining / balance.funded))
    }

    /// The last 10% of funded credits lights the same alarm as a 90% window.
    static func balanceAlarming(_ balance: UsageRecord.Balance?) -> Bool {
        guard let balance, balance.funded > 0 else { return false }
        return balance.remaining / balance.funded <= 0.1
    }

    static func alarming(_ record: UsageRecord?) -> Bool {
        (bindingWindow(record)?.percent ?? -1) >= 0.9 || balanceAlarming(record?.balance)
    }

    // MARK: - Hero

    static func heroMeta(_ record: UsageRecord?) -> String {
        guard let record else { return "" }
        if !record.usageStatusText.isEmpty { return record.usageStatusText }
        guard let first = record.tierLabel.first else { return "Subscription" }
        return first.uppercased() + record.tierLabel.dropFirst()
    }

    // MARK: - Days

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func todayDate(now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Local midnight of a `YYYY-MM-DD` date, or nil when it isn't one.
    private static func parseDay(_ date: String, calendar: Calendar) -> DateComponents? {
        guard let match = date.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/) else { return nil }
        var components = DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3))
        components.calendar = calendar
        guard components.isValidDate, let day = calendar.date(from: components) else { return nil }
        components.weekday = calendar.component(.weekday, from: day)
        return components
    }

    static func dayName(_ date: String, calendar: Calendar = .current) -> String {
        guard let day = parseDay(date, calendar: calendar), let weekday = day.weekday else { return date }
        return weekdays[weekday - 1]
    }

    static func dayLabel(_ date: String, today: Bool, calendar: Calendar = .current) -> String {
        today ? "Today" : dayName(date, calendar: calendar)
    }

    static func dayTooltip(_ day: UsageRecord.RecentDay, today: Bool, record: UsageRecord?, calendar: Calendar = .current) -> String {
        let label: String
        if let parsed = parseDay(day.date, calendar: calendar) {
            label = "\(dayName(day.date, calendar: calendar)) \(parsed.month!)/\(parsed.day!)"
        } else {
            label = day.date
        }
        var text = label + " · " + formatTokenCount(day.messageCount) + " tokens"
        // Prompt and session counts only exist for today, and billing-API agents never count them.
        if today, let record, record.hasPromptStats {
            text += " · \(record.todayPrompts) prompts · \(record.todaySessions) sessions"
        }
        return text
    }

    static func weekPeak(_ record: UsageRecord?) -> Int {
        (record?.recentDays ?? []).map(\.messageCount).max().map { max(0, $0) } ?? 0
    }

    // MARK: - Models

    /// The four heaviest models. Ties fall back to the model name so the order is stable.
    static func modelRows(_ record: UsageRecord?) -> [ModelRow] {
        let rows = (record?.modelUsage ?? [:]).map { id, bucket in
            ModelRow(
                name: friendlyModelName(id), total: bucket.total,
                input: bucket.inputTokens, output: bucket.outputTokens,
                cacheRead: bucket.cacheReadInputTokens, cacheWrite: bucket.cacheCreationInputTokens
            )
        }
        return Array(rows.sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }.prefix(4))
    }

    static func modelTooltip(_ row: ModelRow) -> String {
        "In " + formatTokenCount(row.input) + " · out " + formatTokenCount(row.output)
            + " · cache read " + formatTokenCount(row.cacheRead) + " · cache write " + formatTokenCount(row.cacheWrite)
    }

    // MARK: - Formatting (Main.qml)

    static func formatTokenCount(_ n: Int) -> String {
        let value = Double(n)
        if value >= 1e9 { return String(format: "%.1fB", value / 1e9) }
        if value >= 1e6 { return String(format: "%.1fM", value / 1e6) }
        if value >= 1e3 { return String(format: "%.1fK", value / 1e3) }
        return String(n)
    }

    private static func modelWordCase(_ word: String) -> String {
        if word == "gpt" { return "GPT" }
        if word == "deepseek" { return "DeepSeek" }
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// `claude-opus-4-8` → "Opus 4.8", `gpt-5.6-sol` → "GPT 5.6 Sol".
    static func friendlyModelName(_ id: String) -> String {
        guard !id.isEmpty else { return "Unknown" }
        let name = id.replacing(/^claude-/, with: "").replacing(/-\d{8}$/, with: "")
        var words: [String] = []
        var version: [String] = []
        for part in name.split(separator: "-", omittingEmptySubsequences: true).map(String.init) {
            if part.first?.isNumber == true, part.first?.isASCII == true {
                version.append(part)
                continue
            }
            if !version.isEmpty {
                words.append(version.joined(separator: "."))
                version = []
            }
            words.append(modelWordCase(part))
        }
        if !version.isEmpty { words.append(version.joined(separator: ".")) }
        return words.isEmpty ? "Unknown" : words.joined(separator: " ")
    }
}
