import Foundation

/// One finished dictation, persisted as a single JSON line in the usage ledger.
/// Metrics only — never transcript text: this file is the cost/usage memory,
/// while `HistoryStore` stays deliberately in-memory.
struct UsageRecord: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var date: Date
    /// Local calendar day of `date` ("2026-09-19"), frozen at write time so
    /// "today" totals never move when the user changes time zone.
    var day: String
    /// `SpeechModel.rawValue` — stable, like everywhere else it is persisted.
    var modelID: String
    var isCloud: Bool
    var audioSeconds: Double
    var processingSeconds: Double
    var inputTokens: Int?
    var outputTokens: Int?
    /// The exact amount OpenRouter charged for this request. nil for local
    /// models, and for cloud responses that carried no usage block.
    var costUSD: Decimal?

    init(date: Date = Date(),
         calendar: Calendar = .current,
         modelID: String,
         isCloud: Bool,
         audioSeconds: Double,
         processingSeconds: Double,
         inputTokens: Int? = nil,
         outputTokens: Int? = nil,
         costUSD: Decimal? = nil) {
        self.schemaVersion = 1
        self.date = date
        self.day = Self.localDay(for: date, calendar: calendar)
        self.modelID = modelID
        self.isCloud = isCloud
        self.audioSeconds = audioSeconds
        self.processingSeconds = processingSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }

    /// Tolerant decoder: every field added after v1 must be optional here, even
    /// when it has a default, or one missing key would drop the whole line —
    /// and with it the rest of the user's history.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        date = try container.decode(Date.self, forKey: .date)
        day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? "unknown"
        isCloud = try container.decodeIfPresent(Bool.self, forKey: .isCloud) ?? false
        audioSeconds = try container.decodeIfPresent(Double.self, forKey: .audioSeconds) ?? 0
        processingSeconds = try container.decodeIfPresent(Double.self, forKey: .processingSeconds) ?? 0
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        costUSD = try container.decodeIfPresent(Decimal.self, forKey: .costUSD)
    }

    static func localDay(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Aggregates the menu bar and Settings read. Recomputed in one pass whenever
/// the ledger changes — a few thousand rows cost microseconds, so no database
/// and no cached indices are needed (see Docs/research/usage-cost-tracking.md).
struct UsageSnapshot: Sendable, Equatable {

    struct ModelUsage: Sendable, Equatable, Identifiable {
        let modelID: String
        let isCloud: Bool
        var count = 0
        var audioSeconds: Double = 0
        var costUSD: Decimal = 0
        /// Cloud requests whose response carried no cost (totals are then a lower bound).
        var unpricedCount = 0

        var id: String { modelID }
    }

    var totalCount = 0
    var todayCount = 0
    var totalUSD: Decimal = 0
    var todayUSD: Decimal = 0
    var unpricedCount = 0
    /// Sorted by spend, then by number of dictations.
    var models: [ModelUsage] = []

    var isEmpty: Bool { totalCount == 0 }
    /// True once any cloud model has actually cost money.
    var hasSpend: Bool { totalUSD > 0 }

    init() {}

    init(records: [UsageRecord], today: String = UsageRecord.localDay(for: Date())) {
        var byModel: [String: ModelUsage] = [:]
        for record in records {
            totalCount += 1
            let cost = record.costUSD ?? 0
            totalUSD += cost
            if record.day == today {
                todayCount += 1
                todayUSD += cost
            }
            var entry = byModel[record.modelID] ?? ModelUsage(modelID: record.modelID, isCloud: record.isCloud)
            entry.count += 1
            entry.audioSeconds += record.audioSeconds
            if let recordCost = record.costUSD {
                entry.costUSD += recordCost
            } else if record.isCloud {
                entry.unpricedCount += 1
                unpricedCount += 1
            }
            byModel[record.modelID] = entry
        }
        models = byModel.values.sorted {
            if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.modelID < $1.modelID
        }
    }
}

/// Append-only JSON Lines ledger on disk. One `record(_:)` costs a single
/// append plus fsync (~1–2 ms measured); a corrupt or truncated line only ever
/// loses that line, never the file. All access is actor-serialized, and every
/// public method is synchronous inside the actor so writes keep arrival order.
actor UsageLedger {

    static var defaultFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("MoDict", isDirectory: true)
            .appendingPathComponent("Usage", isDirectory: true)
            .appendingPathComponent("ledger.jsonl", isDirectory: false)
    }

    private let fileURL: URL
    private var records: [UsageRecord] = []
    private var didLoad = false
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL = UsageLedger.defaultFileURL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func snapshot() -> UsageSnapshot {
        loadIfNeeded()
        return UsageSnapshot(records: records)
    }

    /// Append one dictation and return the refreshed aggregates. A failed write
    /// is logged, never thrown: losing a usage line must not break dictation.
    @discardableResult
    func record(_ record: UsageRecord) -> UsageSnapshot {
        loadIfNeeded()
        do {
            try append(record)
            records.append(record)
        } catch {
            NSLog("MoDict: usage ledger write failed: \(error)")
        }
        return UsageSnapshot(records: records)
    }

    func reset() {
        records.removeAll()
        didLoad = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        records = data.split(separator: 0x0A).compactMap { line in
            line.isEmpty ? nil : try? decoder.decode(UsageRecord.self, from: Data(line))
        }
    }

    private func append(_ record: UsageRecord) throws {
        var data = try encoder.encode(record)
        data.append(0x0A)
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } else {
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}

/// Money formatting for the menu bar and Settings. `Decimal` only, USD only
/// (OpenRouter bills in USD), with adaptive precision so a real sub-cent cost
/// never renders as "$0.00".
enum UsageFormat {

    static let oneCent: Decimal = Decimal(sign: .plus, exponent: -2, significand: 1)
    /// The smallest amount the UI ever shows; anything below renders "<$0.0001".
    static let smallestDisplayed: Decimal = Decimal(sign: .plus, exponent: -4, significand: 1)

    static func cost(_ value: Decimal, locale: Locale = .current) -> String {
        guard value > 0 else { return formatted(0, digits: 2, locale: locale) }
        guard value >= smallestDisplayed else {
            return "<" + formatted(smallestDisplayed, digits: 4, locale: locale)
        }
        if value >= 1 { return formatted(value, digits: 2, locale: locale) }
        if value >= oneCent { return formatted(value, digits: 3, locale: locale) }
        return formatted(value, digits: 4, locale: locale)
    }

    private static func formatted(_ value: Decimal, digits: Int, locale: Locale) -> String {
        value.formatted(
            Decimal.FormatStyle.Currency(code: "USD")
                .locale(locale)
                .precision(.fractionLength(digits))
        )
    }
}
