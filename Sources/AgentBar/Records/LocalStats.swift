import Foundation

/// The local half of a usage record: today, the last week, and all-time totals by model.
/// Field names and shapes are the collectors' (`scan_projects` in omarchy-agent-usage-claude,
/// `local_stats` in omarchy-agent-usage-codex).
struct LocalStats: Codable, Equatable, Sendable {
    var todayPrompts = 0
    var todaySessions = 0
    var todayTotalTokens = 0
    var todayTokensByModel: [String: Int] = [:]
    var recentDays: [UsageRecord.RecentDay] = []
    var modelUsage: [String: UsageRecord.TokenBucket] = [:]
    var totalPrompts = 0
    var totalSessions = 0
    var activeDays = 0
    var activeDates: [String] = []

    /// `merge_stats`: counts add up, the week is unioned by date, and active days are a union
    /// of dates since sources overlap in time.
    func merged(with extra: LocalStats) -> LocalStats {
        var merged = self
        merged.todayPrompts += extra.todayPrompts
        merged.todaySessions += extra.todaySessions
        merged.todayTotalTokens += extra.todayTotalTokens
        merged.totalPrompts += extra.totalPrompts
        merged.totalSessions += extra.totalSessions
        for (model, count) in extra.todayTokensByModel {
            merged.todayTokensByModel[model, default: 0] += count
        }
        for (model, bucket) in extra.modelUsage {
            merged.modelUsage[model, default: .init()] += bucket
        }
        var byDate: [String: Int] = [:]
        for day in recentDays + extra.recentDays where !day.date.isEmpty {
            byDate[day.date, default: 0] += day.messageCount
        }
        merged.recentDays = byDate.keys.sorted().map { UsageRecord.RecentDay(date: $0, messageCount: byDate[$0]!) }
        let dates = Set(activeDates).union(extra.activeDates)
        merged.activeDates = dates.sorted()
        merged.activeDays = max(dates.count, activeDays, extra.activeDays)
        return merged
    }
}

extension UsageRecord {
    /// `record.update(stats)` in the collectors.
    mutating func apply(_ stats: LocalStats) {
        todayPrompts = stats.todayPrompts
        todaySessions = stats.todaySessions
        todayTotalTokens = stats.todayTotalTokens
        todayTokensByModel = stats.todayTokensByModel
        recentDays = stats.recentDays
        modelUsage = stats.modelUsage
        totalPrompts = stats.totalPrompts
        totalSessions = stats.totalSessions
        activeDays = stats.activeDays
        activeDates = stats.activeDates
    }
}

extension UsageRecord.TokenBucket {
    static func += (lhs: inout Self, rhs: Self) {
        lhs.inputTokens += rhs.inputTokens
        lhs.outputTokens += rhs.outputTokens
        lhs.cacheReadInputTokens += rhs.cacheReadInputTokens
        lhs.cacheCreationInputTokens += rhs.cacheCreationInputTokens
    }
}

/// Tallies usage entries the way the collectors' scans do (`add_usage`, and the loop bodies of
/// `scan_projects`, `scan_pi_usage` and `scan_opencode_usage`).
struct StatsAccumulator {
    let today: String
    let recentDates: [String]
    private(set) var prompts = 0
    private var recent: [String: Int]
    private var sessions: Set<String> = []
    private var activeDays: Set<String> = []
    private var todaySessions: Set<String> = []
    private var todayTokens: [String: Int] = [:]
    private var usage: [String: UsageRecord.TokenBucket] = [:]
    private var todayPrompts = 0
    private var todayTotal = 0

    init(now: Date, calendar: Calendar) {
        today = LocalDay.string(now, calendar: calendar)
        recentDates = (0...6).reversed().map {
            LocalDay.string(calendar.date(byAdding: .day, value: -$0, to: now)!, calendar: calendar)
        }
        recent = Dictionary(uniqueKeysWithValues: recentDates.map { ($0, 0) })
    }

    mutating func add(day: String, session: String, model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
        let total = input + output + cacheRead + cacheWrite
        prompts += 1
        sessions.insert(session)
        activeDays.insert(day)
        usage[model, default: .init()] += .init(inputTokens: input, outputTokens: output, cacheReadInputTokens: cacheRead, cacheCreationInputTokens: cacheWrite)
        // recentDays.messageCount is a token total, despite the legacy name.
        if recent[day] != nil { recent[day]! += total }
        if day == today {
            todayPrompts += 1
            todaySessions.insert(session)
            todayTotal += total
            todayTokens[model, default: 0] += total
        }
    }

    var stats: LocalStats {
        LocalStats(
            todayPrompts: todayPrompts,
            todaySessions: todaySessions.count,
            todayTotalTokens: todayTotal,
            todayTokensByModel: todayTokens,
            recentDays: recentDates.map { .init(date: $0, messageCount: recent[$0] ?? 0) },
            modelUsage: usage,
            totalPrompts: prompts,
            totalSessions: sessions.count,
            activeDays: activeDays.count,
            activeDates: activeDays.sorted()
        )
    }
}

/// Local calendar dates from the timestamps usage logs carry (`local_date_from_timestamp` in the
/// Claude collector, `local_day` in the Codex one).
enum LocalDay {
    static func string(_ date: Date, calendar: Calendar) -> String {
        PanelLogic.todayDate(now: date, calendar: calendar)
    }

    /// Epoch seconds or milliseconds, an ISO timestamp (converted to local time when it has an
    /// offset, taken as written when it hasn't), or today when there is nothing usable.
    static func from(_ value: Any?, now: Date, calendar: Calendar) -> String {
        let today = string(now, calendar: calendar)
        switch value {
        case let number as NSNumber:
            var seconds = number.doubleValue
            if seconds > 10_000_000_000 { seconds /= 1000 }
            guard seconds.isFinite, abs(seconds) < 1e12 else { return today }
            return string(Date(timeIntervalSince1970: seconds), calendar: calendar)
        case let text as String:
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil {
                return OmarchyDate.parse(raw).map { string($0, calendar: calendar) } ?? today
            }
            if raw.range(of: #"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?)?$"#, options: .regularExpression) != nil {
                return String(raw.prefix(10))
            }
            return today
        default:
            return today
        }
    }
}

/// The collectors' two `number()` helpers.
enum PyNumber {
    /// omarchy-agent-usage-claude: `round(float(value or 0))`, 0 when that fails. Python rounds
    /// half to even.
    static func rounded(_ value: Any?) -> Int {
        let n: Double
        switch value {
        case let number as NSNumber: n = number.doubleValue
        case let string as String: n = Double(string.trimmingCharacters(in: .whitespaces)) ?? .nan
        default: return 0
        }
        guard n.isFinite, abs(n) < 9e18 else { return 0 }
        return Int(n.rounded(.toNearestOrEven))
    }

    /// omarchy-agent-usage-codex: `int(value or 0)`, which truncates floats and rejects "3.5".
    static func truncated(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber:
            let d = number.doubleValue
            return d.isFinite && abs(d) < 9e18 ? Int(d.rounded(.towardZero)) : 0
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespaces)) ?? 0
        default:
            return 0
        }
    }

    /// Python truthiness for an id or name: a non-empty string, or a non-zero number.
    static func truthyString(_ value: Any?) -> String? {
        switch value {
        case let string as String where !string.isEmpty: return string
        case let number as NSNumber where number != 0: return number.stringValue
        default: return nil
        }
    }
}

/// Line-by-line access to JSONL logs, memory-mapped so large transcripts cost little.
enum JSONLines {
    /// Calls `body` with each line of a file and its 1-based number. Nothing when unreadable.
    static func forEach(in file: URL, _ body: (Data, Int) -> Void) {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return }
        var number = 0
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            number += 1
            body(data[start..<end], number)
            start = end < data.endIndex ? data.index(after: end) : end
        }
    }

    static func object(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }

    /// Every `*.jsonl` below `root`, in path order so a repeated message counts in the same place every time.
    static func files(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "jsonl" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }
}
