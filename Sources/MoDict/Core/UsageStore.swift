import Foundation
import Combine

/// Main-actor façade over `UsageLedger`: the UI observes `snapshot`, the
/// controller appends records. Reading and aggregation always happen inside the
/// ledger actor, never on the main actor.
@MainActor
final class UsageStore: ObservableObject {

    @Published private(set) var snapshot = UsageSnapshot()

    private let ledger: UsageLedger

    init(ledger: UsageLedger = UsageLedger()) {
        self.ledger = ledger
    }

    /// Load from disk and publish. Cheap to call on every popover open — the
    /// ledger only touches the file when it has not loaded yet.
    func refresh() async {
        snapshot = await ledger.snapshot()
    }

    /// Append one finished dictation and publish the refreshed aggregates.
    func record(_ record: UsageRecord) async {
        snapshot = await ledger.record(record)
    }

    func reset() async {
        await ledger.reset()
        snapshot = UsageSnapshot()
    }
}
