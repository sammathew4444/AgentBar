import Foundation

/// One agent's usage record: the JSON an `omarchy-agent-usage-<agent>` collector prints and
/// `omarchy-agent-usage-update` writes to `<usage dir>/<id>.json`.
///
/// Fields and defaults follow the collectors (reference/source/bin/omarchy-agent-usage-*) and how
/// the panel reads them (reference/source/shell/plugins/agents/Main.qml, `displayProvider`).
/// Decoding is as forgiving as the panel's JavaScript: a missing or mistyped field takes its
/// default, one bad entry in a list is dropped on its own, and `schemaVersion` is carried but
/// never gates decoding. Only a record without an `id` is rejected, as Main.qml skips those.
struct UsageRecord: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var id: String
    var name: String
    /// ISO 8601, as Python's `datetime.isoformat()` writes it. See `OmarchyDate`.
    var updatedAt: String
    var ready: Bool
    var hasLocalStats: Bool
    /// False for billing-API agents, which never count prompts.
    var hasPromptStats: Bool
    /// `"device"` stats add up across synced machines; `"account"` stats are the same everywhere.
    var scope: String
    var tierLabel: String
    var usageStatusText: String
    var authHelpText: String
    /// Set by a collector that couldn't reach its limits endpoint at all.
    var retryAdvised: Bool
    var limits: [Limit]
    /// Prepaid agents only.
    var balance: Balance?

    var todayPrompts: Int
    var todaySessions: Int
    var todayTotalTokens: Int
    var todayTokensByModel: [String: Int]
    var recentDays: [RecentDay]
    var totalPrompts: Int
    var totalSessions: Int
    var activeDays: Int
    var activeDates: [String]
    var modelUsage: [String: TokenBucket]

    init(
        id: String,
        name: String,
        schemaVersion: Int = 1,
        updatedAt: String = "",
        ready: Bool = false,
        hasLocalStats: Bool = true,
        hasPromptStats: Bool = true,
        scope: String = "device",
        tierLabel: String = "",
        usageStatusText: String = "",
        authHelpText: String = "",
        retryAdvised: Bool = false,
        limits: [Limit] = [],
        balance: Balance? = nil,
        todayPrompts: Int = 0,
        todaySessions: Int = 0,
        todayTotalTokens: Int = 0,
        todayTokensByModel: [String: Int] = [:],
        recentDays: [RecentDay] = [],
        totalPrompts: Int = 0,
        totalSessions: Int = 0,
        activeDays: Int = 0,
        activeDates: [String] = [],
        modelUsage: [String: TokenBucket] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
        self.ready = ready
        self.hasLocalStats = hasLocalStats
        self.hasPromptStats = hasPromptStats
        self.scope = scope
        self.tierLabel = tierLabel
        self.usageStatusText = usageStatusText
        self.authHelpText = authHelpText
        self.retryAdvised = retryAdvised
        self.limits = limits
        self.balance = balance
        self.todayPrompts = todayPrompts
        self.todaySessions = todaySessions
        self.todayTotalTokens = todayTotalTokens
        self.todayTokensByModel = todayTokensByModel
        self.recentDays = recentDays
        self.totalPrompts = totalPrompts
        self.totalSessions = totalSessions
        self.activeDays = activeDays
        self.activeDates = activeDates
        self.modelUsage = modelUsage
    }

    struct Limit: Codable, Sendable, Equatable {
        /// "Session (5-hour)", "Weekly (7-day)", "5h window", or a model-scoped name.
        var label: String
        /// Set when the collector already knows the window's display title.
        var title: String?
        /// Fraction of the allowance used, 0.0–1.0.
        var percent: Double
        /// ISO 8601, or empty when unknown.
        var resetsAt: String

        init(label: String, title: String? = nil, percent: Double, resetsAt: String = "") {
            self.label = label
            self.title = title
            self.percent = percent
            self.resetsAt = resetsAt
        }

        /// A limit without a usable percentage is dropped, as `limitWindows` in Panel.qml does.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let percent = try c.decode(Double.self, forKey: .percent)
            guard percent.isFinite, percent >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .percent, in: c, debugDescription: "percent must be >= 0")
            }
            self.percent = percent
            label = c.lenientString(.label)
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
            resetsAt = c.lenientString(.resetsAt)
        }
    }

    struct Balance: Codable, Sendable, Equatable {
        var remaining: Double
        var funded: Double
        var spent: Double
        var currency: String
        var estimated: Bool

        init(remaining: Double, funded: Double, spent: Double, currency: String = "USD", estimated: Bool) {
            self.remaining = remaining
            self.funded = funded
            self.spent = spent
            self.currency = currency
            self.estimated = estimated
        }

        /// Mirrors `balanceValue` in Main.qml: no usable `remaining`, no balance.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let remaining = try c.decode(Double.self, forKey: .remaining)
            guard remaining.isFinite, remaining >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .remaining, in: c, debugDescription: "remaining must be >= 0")
            }
            self.remaining = remaining
            let funded = c.lenientDouble(.funded)
            self.funded = funded.isFinite && funded > 0 ? funded : 0
            spent = max(0, c.lenientDouble(.spent))
            let currency = c.lenientString(.currency)
            self.currency = currency.isEmpty ? "USD" : currency
            estimated = c.lenientBool(.estimated, default: false)
        }
    }

    struct RecentDay: Codable, Sendable, Equatable {
        /// Local calendar date, `YYYY-MM-DD`.
        var date: String
        /// A token total, despite the name (see `scan_projects` in omarchy-agent-usage-claude).
        var messageCount: Int

        init(date: String, messageCount: Int) {
            self.date = date
            self.messageCount = messageCount
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = c.lenientString(.date)
            messageCount = c.lenientInt(.messageCount)
        }
    }

    struct TokenBucket: Codable, Sendable, Equatable {
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadInputTokens: Int
        var cacheCreationInputTokens: Int

        init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadInputTokens: Int = 0, cacheCreationInputTokens: Int = 0) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = c.lenientInt(.inputTokens)
            outputTokens = c.lenientInt(.outputTokens)
            cacheReadInputTokens = c.lenientInt(.cacheReadInputTokens)
            cacheCreationInputTokens = c.lenientInt(.cacheCreationInputTokens)
        }

        var total: Int { inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens }
    }

    enum RecordError: Error, Equatable {
        case missingID
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, updatedAt, ready, hasLocalStats, hasPromptStats, scope
        case tierLabel, usageStatusText, authHelpText, retryAdvised, limits, balance
        case todayPrompts, todaySessions, todayTotalTokens, todayTokensByModel, recentDays
        case totalPrompts, totalSessions, activeDays, activeDates, modelUsage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientString(.id)
        guard !id.isEmpty else { throw RecordError.missingID }

        schemaVersion = c.lenientInt(.schemaVersion)
        let name = c.lenientString(.name)
        self.name = name.isEmpty ? id : name
        updatedAt = c.lenientString(.updatedAt)
        ready = c.lenientBool(.ready, default: false)
        hasLocalStats = c.lenientBool(.hasLocalStats, default: true)
        hasPromptStats = c.lenientBool(.hasPromptStats, default: true)
        let scope = c.lenientString(.scope)
        self.scope = scope.isEmpty ? "device" : scope
        tierLabel = c.lenientString(.tierLabel)
        usageStatusText = c.lenientString(.usageStatusText)
        authHelpText = c.lenientString(.authHelpText)
        retryAdvised = c.lenientBool(.retryAdvised, default: false)
        limits = c.lossyArray(Limit.self, .limits)
        balance = (try? c.decodeIfPresent(Balance.self, forKey: .balance)) ?? nil

        todayPrompts = c.lenientInt(.todayPrompts)
        todaySessions = c.lenientInt(.todaySessions)
        todayTotalTokens = c.lenientInt(.todayTotalTokens)
        todayTokensByModel = c.lossyDictionary(LenientInt.self, .todayTokensByModel).mapValues(\.value)
        recentDays = c.lossyArray(RecentDay.self, .recentDays)
        totalPrompts = c.lenientInt(.totalPrompts)
        totalSessions = c.lenientInt(.totalSessions)
        activeDays = c.lenientInt(.activeDays)
        activeDates = c.lossyArray(String.self, .activeDates)
        modelUsage = c.lossyDictionary(TokenBucket.self, .modelUsage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(ready, forKey: .ready)
        try c.encode(hasLocalStats, forKey: .hasLocalStats)
        try c.encode(hasPromptStats, forKey: .hasPromptStats)
        try c.encode(scope, forKey: .scope)
        try c.encode(tierLabel, forKey: .tierLabel)
        try c.encode(usageStatusText, forKey: .usageStatusText)
        try c.encode(authHelpText, forKey: .authHelpText)
        // Collectors only write the flag when it is set.
        if retryAdvised { try c.encode(true, forKey: .retryAdvised) }
        try c.encode(limits, forKey: .limits)
        try c.encodeIfPresent(balance, forKey: .balance)
        try c.encode(todayPrompts, forKey: .todayPrompts)
        try c.encode(todaySessions, forKey: .todaySessions)
        try c.encode(todayTotalTokens, forKey: .todayTotalTokens)
        try c.encode(todayTokensByModel, forKey: .todayTokensByModel)
        try c.encode(recentDays, forKey: .recentDays)
        try c.encode(totalPrompts, forKey: .totalPrompts)
        try c.encode(totalSessions, forKey: .totalSessions)
        try c.encode(activeDays, forKey: .activeDays)
        try c.encode(activeDates, forKey: .activeDates)
        try c.encode(modelUsage, forKey: .modelUsage)
    }
}

// MARK: - Lenient decoding

/// Main.qml reads numbers with `Math.round(Number(value || 0))`, so a float, a numeric string,
/// or nothing at all are all acceptable.
private struct LenientInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self), n.isFinite {
            value = Int(n.rounded())
        } else if let s = try? c.decode(String.self), let n = Double(s), n.isFinite {
            value = Int(n.rounded())
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number")
        }
    }
}

/// Decodes to nil instead of throwing, so one bad element doesn't sink its whole collection.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil ?? ""
    }

    func lenientInt(_ key: Key) -> Int {
        ((try? decodeIfPresent(LenientInt.self, forKey: key)) ?? nil)?.value ?? 0
    }

    func lenientDouble(_ key: Key) -> Double {
        (try? decodeIfPresent(Double.self, forKey: key)) ?? nil ?? 0
    }

    /// Main.qml tests flags with `=== true` or `!== false`; `default` is what a missing flag means.
    func lenientBool(_ key: Key, default fallback: Bool) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil ?? fallback
    }

    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        let items = (try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil
        return items?.compactMap(\.value) ?? []
    }

    func lossyDictionary<T: Decodable>(_ type: T.Type, _ key: Key) -> [String: T] {
        let items = (try? decodeIfPresent([String: Lossy<T>].self, forKey: key)) ?? nil
        return items?.compactMapValues(\.value) ?? [:]
    }
}
