import SwiftUI

extension View {
    // keyboardFocusable(): Leave fixture views unchanged; tests do not exercise focus.
    func keyboardFocusable() -> some View { self }
}

/// Replaces preferences so the test never changes the workstation's user settings.
final class TrialPreferences {
    var values: [String: Any] = [:]
    // bool(forKey key): Read a saved disclosure flag.
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    // integer(forKey key): Read the saved daily count.
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    // object(forKey key): Read a saved local trial date.
    func object(forKey key: String) -> Any? { values[key] }
    // set(value, forKey key): Save trial state only in this fixture's memory.
    func set(_ value: Any, forKey key: String) { values[key] = value }
}

/// Supplies verified app transactions, with optional suspension or lookup failure. The driver
/// rewrites the store's AppTransaction lookup to read `shared` here.
@MainActor enum TrialFixture {
    enum Environment { case production, sandbox }
    /// The fields of the signed app transaction that the store reads; a sandbox purchase at the
    /// epoch by default.
    struct Transaction {
        var bundleID = AgeminEdition.bundleIdentifier
        var environment = Environment.sandbox
        var originalPurchaseDate = Date(timeIntervalSince1970: 0)
    }
    /// Stands in for StoreKit's verification result; the fixture never yields an unverified one.
    enum Verification { case verified(Transaction) }
    /// Thrown in place of a StoreKit lookup error.
    struct Failure: Error {}
    static let defaults = TrialPreferences()
    static var transaction = Transaction()
    static var shouldFail = false
    static var shouldSuspend = false
    /// Resumes a lookup that `shouldSuspend` paused, so the test controls when it answers.
    static var continuation: CheckedContinuation<Void, Never>?
    static var shared: Verification {
        get async throws {
            // Pause the post-welcome read so the test can inspect the intermediate state.
            if shouldSuspend {
                await withCheckedContinuation { continuation = $0 }
            }
            // A failed signed lookup must never grant a local App Store trial.
            if shouldFail { throw Failure() }
            return .verified(transaction)
        }
    }
}

@main enum TrialStartupTests {
    // waitFor(condition): Poll for up to two seconds, sleeping between checks so the store's
    // main-actor task can run; a broken transition fails clearly instead of hanging.
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            // Stop polling as soon as the expected asynchronous transition occurs.
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Trial startup did not complete")
    }

    // checkAllowance(store, now): After the trial, one operation passes, the second is refused,
    // and the next day starts over.
    @MainActor static func checkAllowance(_ store: AgeminProStore, now: Date) {
        precondition(store.isLimitedToFreeOperations)
        precondition(store.beginOperation(now: now), "One operation is allowed")
        precondition(!store.beginOperation(now: now), "The second operation is refused")
        precondition(store.freeOperationsRemainingToday == 0)
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)
        precondition(store.beginOperation(now: tomorrow), "A new day allows operations again")
    }

    // main(): Check welcome, delayed lookup, expiry, the allowance, production dates, and failed
    // verification. The source and App Store editions take different paths after the setup.
    @MainActor static func main() async throws {
        // A start 31 days back is past the 30-day trial. The keys are the store's own preference
        // keys, written straight into the fixture to stage a returning user.
        let now = Date()
        let old = now.addingTimeInterval(-31 * 24 * 60 * 60)
        let startKey = "AgeminAppTrialStartedAt"
        let acceptedKey = "AgeminAppTrialDisclosureAccepted"
        // A launch-time operation is allowed without spending a Free slot while StoreKit still
        // has not answered whether the customer already owns Pro.
        let unresolved = AgeminProStore()
        unresolved.appTrialStartedAt = old
        unresolved.hasResolvedAppTrial = true
        unresolved.isTrialWelcomePending = false
        precondition(!unresolved.hasResolvedEntitlement && !unresolved.isLimitedToFreeOperations)
        precondition(unresolved.beginOperation(now: now))
        precondition(unresolved.freeOperationsUsedToday == 0,
                     "An unresolved entitlement must not spend a Free operation")
        // Every store below pretends StoreKit's entitlement read has finished with no purchase,
        // which the Free limit waits for; the driver strips the setter's access control.
        let store = AgeminProStore()
        store.hasResolvedEntitlement = true

        // A source build starts its local trial synchronously after the welcome.
        if !AgeminEdition.isAppStoreBuild {
            precondition(!store.hasPreparedFreeAccess && !store.isLimitedToFreeOperations)
            store.beginAppTrial(now: now)
            precondition(store.hasPreparedFreeAccess && store.hasFullAccess)
            precondition(store.appTrialStartedAt == now)
            // Full access never counts operations.
            for _ in 0..<7 { precondition(store.beginOperation(now: now)) }
            precondition(store.freeOperationsUsedToday == 0)
            // An expired local trial falls to the daily allowance.
            TrialFixture.defaults.values = [startKey: old, acceptedKey: true]
            let expired = AgeminProStore()
            expired.hasResolvedEntitlement = true
            expired.beginAppTrial(now: now)
            precondition(expired.appTrialStartedAt == old)
            checkAllowance(expired, now: now)
            print("Source trial startup and daily allowance passed")
            return
        }

        // StoreKit may finish its startup read while the welcome alert is still open.
        await store.refreshAppTrial(now: now)
        precondition(store.hasResolvedAppTrial && store.appTrialStartedAt == nil)
        precondition(!store.hasPreparedFreeAccess && !store.isLimitedToFreeOperations,
                     "A sandbox trial awaiting consent must not look expired")

        // Dismissing the alert must not briefly unlock the expired banner during a slow read.
        TrialFixture.shouldSuspend = true
        store.beginAppTrial(now: now)
        try await waitFor { TrialFixture.continuation != nil }
        precondition(!store.hasPreparedFreeAccess && !store.isLimitedToFreeOperations,
                     "The post-welcome trial lookup is still pending")
        // Let the lookup answer; the welcome stays pending until the store has applied it.
        TrialFixture.shouldSuspend = false
        TrialFixture.continuation?.resume()
        TrialFixture.continuation = nil
        try await waitFor { !store.isTrialWelcomePending }
        precondition(store.hasPreparedFreeAccess && store.hasFullAccess)
        precondition(store.appTrialStartedAt == now,
                     "Sandbox uses the accepted local clock, not Apple's fixed test date")

        // A returning sandbox user keeps the original clock and receives Free limits after expiry.
        TrialFixture.defaults.values = [startKey: old, acceptedKey: true]
        let expired = AgeminProStore()
        expired.hasResolvedEntitlement = true
        expired.beginAppTrial(now: now)
        try await waitFor { !expired.isTrialWelcomePending }
        precondition(expired.appTrialStartedAt == old && expired.isLimitedToFreeOperations)
        checkAllowance(expired, now: now)

        // Production must use its signed date even if local preferences claim a fresh trial.
        TrialFixture.defaults.values = [startKey: now]
        TrialFixture.transaction.environment = .production
        TrialFixture.transaction.originalPurchaseDate = old
        let production = AgeminProStore()
        production.hasResolvedEntitlement = true
        await production.refreshAppTrial(now: now)
        precondition(!production.hasPreparedFreeAccess,
                     "Even an expired production trial waits for the welcome to close")
        production.beginAppTrial(now: now)
        try await waitFor { !production.isTrialWelcomePending }
        precondition(production.appTrialStartedAt == old && production.isLimitedToFreeOperations)

        // A failed signed lookup grants no trial and never falls back to the resettable local
        // clock; the user gets the Free limit.
        TrialFixture.shouldFail = true
        let failed = AgeminProStore()
        failed.hasResolvedEntitlement = true
        failed.beginAppTrial(now: now)
        try await waitFor { !failed.isTrialWelcomePending }
        precondition(failed.appTrialStartedAt == nil && !failed.hasFullAccess)
        precondition(failed.isLimitedToFreeOperations)
        print("App Store trial startup, delayed lookup, expiry, allowance, and verification failure passed")
    }
}
