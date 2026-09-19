import Foundation
import Testing
@testable import MoDict

struct UsageLedgerTests {

    private static let usLocale = Locale(identifier: "en_US")

    private func usd(_ string: String) -> Decimal {
        Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MoDictUsageTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ledger.jsonl", isDirectory: false)
    }

    private func prepareDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test
    func recordsRoundTripThroughDisk() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }

        let ledger = UsageLedger(fileURL: url)
        let record = UsageRecord(
            modelID: SpeechModel.gptTranscribe.rawValue,
            isCloud: true,
            audioSeconds: 3.5,
            processingSeconds: 0.9,
            inputTokens: 12,
            outputTokens: 4,
            costUSD: usd("0.0002625")
        )
        let snapshot = await ledger.record(record)
        #expect(snapshot.totalCount == 1)
        #expect(snapshot.totalUSD == record.costUSD)
        #expect(snapshot.todayUSD == record.costUSD)

        let reloaded = await UsageLedger(fileURL: url).snapshot()
        #expect(reloaded.totalCount == 1)
        #expect(reloaded.models.count == 1)
        #expect(reloaded.models.first?.modelID == SpeechModel.gptTranscribe.rawValue)
        let cost = try #require(reloaded.models.first?.costUSD)
        #expect(UsageFormat.cost(cost, locale: Self.usLocale) == "$0.0003")
    }

    @Test
    func toleratesTruncatedAndUnknownLines() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        try prepareDirectory(for: url)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let good = try encoder.encode(UsageRecord(
            modelID: SpeechModel.parakeetV3.rawValue,
            isCloud: false,
            audioSeconds: 2,
            processingSeconds: 0.3
        ))
        var data = Data()
        data.append(good)
        data.append(0x0A)
        data.append(Data(#"{"text":"not a usage record"}"#.utf8))
        data.append(0x0A)
        data.append(Data(#"{"schemaVersion":1,"date":"2026-09-19T10:00:00"#.utf8))
        data.append(0x0A)
        data.append(0x0A)
        try data.write(to: url)

        let snapshot = await UsageLedger(fileURL: url).snapshot()
        #expect(snapshot.totalCount == 1)
        #expect(snapshot.models.first?.modelID == SpeechModel.parakeetV3.rawValue)
        #expect(snapshot.totalUSD == 0)
    }

    @Test
    func missingFieldsFallBackToSafeDefaults() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        try prepareDirectory(for: url)
        try Data(#"{"date":"2026-09-19T10:00:00Z"}"#.utf8).write(to: url)

        let snapshot = await UsageLedger(fileURL: url).snapshot()
        #expect(snapshot.totalCount == 1)
        #expect(snapshot.models.first?.modelID == "unknown")
        #expect(snapshot.totalUSD == 0)
    }

    @Test
    func aggregatesSplitTodayFromOlderRecordsAndSortModelsBySpend() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)
            ?? now.addingTimeInterval(-86_400)

        let ledger = UsageLedger(fileURL: url)
        await ledger.record(UsageRecord(
            date: now, modelID: SpeechModel.maiTranscribe2.rawValue, isCloud: true,
            audioSeconds: 10, processingSeconds: 1, costUSD: usd("0.0003")))
        await ledger.record(UsageRecord(
            date: yesterday, modelID: SpeechModel.gptTranscribe.rawValue, isCloud: true,
            audioSeconds: 20, processingSeconds: 2, costUSD: usd("0.0012")))
        await ledger.record(UsageRecord(
            date: now, modelID: SpeechModel.parakeetV3.rawValue, isCloud: false,
            audioSeconds: 5, processingSeconds: 0.2))

        let snapshot = await ledger.snapshot()
        #expect(snapshot.totalCount == 3)
        #expect(snapshot.todayCount == 2)
        #expect(snapshot.todayUSD == usd("0.0003"))
        #expect(snapshot.totalUSD == usd("0.0015"))
        #expect(snapshot.models.map(\.modelID) == [
            SpeechModel.gptTranscribe.rawValue,
            SpeechModel.maiTranscribe2.rawValue,
            SpeechModel.parakeetV3.rawValue,
        ])
        #expect(snapshot.models.last?.isCloud == false)
        #expect(snapshot.models.last?.costUSD == 0)

        let unpriced = await ledger.record(UsageRecord(
            date: now, modelID: SpeechModel.museVoiceTranscribe.rawValue, isCloud: true,
            audioSeconds: 4, processingSeconds: 0.4))
        #expect(unpriced.unpricedCount == 1)
        #expect(unpriced.totalUSD == usd("0.0015"))
    }

    @Test
    func serializesConcurrentWritesWithoutLosingLines() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let ledger = UsageLedger(fileURL: url)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    await ledger.record(UsageRecord(
                        modelID: SpeechModel.museVoiceTranscribe.rawValue,
                        isCloud: true,
                        audioSeconds: 1,
                        processingSeconds: 0.1,
                        costUSD: usd("0.00005")
                    ))
                }
            }
        }

        let snapshot = await UsageLedger(fileURL: url).snapshot()
        #expect(snapshot.totalCount == 24)
        #expect(snapshot.totalUSD == usd("0.0012"))
    }

    @Test
    func resetClearsMemoryAndDisk() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let ledger = UsageLedger(fileURL: url)
        await ledger.record(UsageRecord(
            modelID: SpeechModel.gptTranscribe.rawValue, isCloud: true,
            audioSeconds: 1, processingSeconds: 0.1, costUSD: usd("0.001")))
        await ledger.reset()

        let afterReset = await ledger.snapshot()
        #expect(afterReset.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func formatsSubCentAmountsWithoutCollapsingToZero() {
        let locale = Self.usLocale
        #expect(UsageFormat.cost(0, locale: locale) == "$0.00")
        #expect(UsageFormat.cost(usd("0.00001"), locale: locale) == "<$0.0001")
        #expect(UsageFormat.cost(usd("0.00005"), locale: locale) == "<$0.0001")
        #expect(UsageFormat.cost(usd("0.0001"), locale: locale) == "$0.0001")
        #expect(UsageFormat.cost(usd("0.000508"), locale: locale) == "$0.0005")
        #expect(UsageFormat.cost(usd("0.0121"), locale: locale) == "$0.012")
        #expect(UsageFormat.cost(usd("1.24"), locale: locale) == "$1.24")
        #expect(UsageFormat.cost(usd("1234.5"), locale: locale) == "$1,234.50")
    }
}
