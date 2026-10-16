import Foundation

/// Product identifiers, which must match App Store Connect. The app's 30-day trial is independent
/// of them.
enum AgeminProductID {
    static let yearly = "tools.min.agemin.pro.yearly"
    static let lifetime = "tools.min.agemin.pro.lifetime"
    static let all = [yearly, lifetime]
}

/// Public builds start with a full-access trial, then drop to the Free tier: one encryption or
/// decryption per local calendar day. Reading keys, inspecting a file's recipients, and
/// generating keys are never counted. The trial start choice and the date arithmetic live here
/// so tests can check them without StoreKit.
enum AgeminFreeAccessPolicy {
    static let trialLengthDays = 30
    static let dailyOperationLimit = 1
    static let trialDuration: TimeInterval = TimeInterval(trialLengthDays * 24 * 60 * 60)

    /// Apple's fixed `AppTransaction.originalPurchaseDate` in the sandbox, in seconds since 1970.
    private static let sandboxOriginalPurchaseTime: TimeInterval = 1_375_340_400

    // isSandboxOriginalPurchaseDate(date): Detect Apple's documented fixed sandbox acquisition
    // date. A one-second tolerance avoids depending on subsecond serialization details.
    static func isSandboxOriginalPurchaseDate(_ date: Date) -> Bool {
        abs(date.timeIntervalSince1970 - sandboxOriginalPurchaseTime) < 1
    }

    // usesLocalTrialClock(transactionIsProduction, hasSandboxReceipt, originalPurchaseDate): True
    // for StoreKit test environments. The fixed sandbox date is authoritative when macOS
    // TestFlight stores its receipt under a production-style filename.
    static func usesLocalTrialClock(
        transactionIsProduction: Bool,
        hasSandboxReceipt: Bool,
        originalPurchaseDate: Date
    ) -> Bool {
        !transactionIsProduction || hasSandboxReceipt
            || isSandboxOriginalPurchaseDate(originalPurchaseDate)
    }

    // shouldRestartLocalTrial(firstAcceptance, isTestEnvironment, didMigrateTestClock): Start at
    // the current time after first consent, and migrate existing test installs once so a fixed
    // sandbox acquisition date cannot leave them expired.
    static func shouldRestartLocalTrial(
        firstAcceptance: Bool,
        isTestEnvironment: Bool,
        didMigrateTestClock: Bool
    ) -> Bool {
        firstAcceptance || (isTestEnvironment && !didMigrateTestClock)
    }

    // authoritativeTrialStartDate(appStoreOriginalPurchaseDate, localStartedAt, usesAppStoreDate):
    // Pick the trial start: Apple's signed date when usesAppStoreDate, otherwise the local clock.
    // A missing signed date never falls back to resettable local state.
    static func authoritativeTrialStartDate(
        appStoreOriginalPurchaseDate: Date?,
        localStartedAt: Date?,
        usesAppStoreDate: Bool
    ) -> Date? {
        usesAppStoreDate ? appStoreOriginalPurchaseDate : localStartedAt
    }

    // isTrialActive(startedAt, [now = Date()]): True while now is before the trial's end.
    static func isTrialActive(startedAt: Date, now: Date = Date()) -> Bool {
        now < startedAt.addingTimeInterval(trialDuration)
    }

    // trialDaysRemaining(startedAt, [now = Date()]): Whole days left, rounded up, never negative.
    static func trialDaysRemaining(startedAt: Date, now: Date = Date()) -> Int {
        let seconds = startedAt.addingTimeInterval(trialDuration).timeIntervalSince(now)
        return max(0, Int(ceil(seconds / (24 * 60 * 60))))
    }

    // operationsUsedToday(storedDay, storedCount, [now = Date()], [calendar]): The stored count
    // when it was recorded today in the user's calendar, otherwise zero; never above the limit.
    static func operationsUsedToday(
        storedDay: Date?,
        storedCount: Int,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        guard let storedDay, calendar.isDate(storedDay, inSameDayAs: now) else { return 0 }
        return min(max(0, storedCount), dailyOperationLimit)
    }

    // operationsRemaining(used): How many Free operations are left today.
    static func operationsRemaining(used: Int) -> Int {
        max(0, dailyOperationLimit - min(max(0, used), dailyOperationLimit))
    }

    // countAfterStartingOperation(used): The new count after starting one more operation, or nil
    // when the allowance is already spent.
    static func countAfterStartingOperation(used: Int) -> Int? {
        let normalized = min(max(0, used), dailyOperationLimit)
        guard normalized < dailyOperationLimit else { return nil }
        return normalized + 1
    }
}

/// The fields of a StoreKit transaction that the entitlement decision needs, so tests can build
/// them without StoreKit.
struct AgeminTransactionSummary: Equatable {
    var productID: String
    var purchaseDate: Date
    var expirationDate: Date?
    var revocationDate: Date?
    var isFamilyShared: Bool
    var isIntroductoryOffer: Bool
}

/// The access a verified purchase grants. `willAutoRenew` stays nil until the renewal lookup
/// answers; `isTrial` marks a StoreKit introductory offer, not the app's own trial.
struct AgeminEntitlement: Equatable {
    enum Kind: Equatable { case none, lifetime, subscription }
    var kind: Kind = .none
    var expirationDate: Date?
    var isTrial = false
    var isFamilyShared = false
    var willAutoRenew: Bool?
    var isPro: Bool { kind != .none }
    static let free = AgeminEntitlement()
}

/// The status line the Pro panel shows, with the date it mentions. The trial cases describe a
/// StoreKit introductory offer, which the products do not configure; the app's 30-day trial is
/// reported separately by the store.
enum AgeminStatusKind: Equatable {
    case free
    case active
    case lifetime
    case familyShared
    case trialRenews(Date)
    case trialEnds(Date)
    case trialUntil(Date)
    case renews(Date)
    case ends(Date)
    case activeUntil(Date)
}

/// Pure decisions over transaction summaries, kept free of StoreKit so tests can drive them.
enum AgeminEntitlementLogic {
    // evaluate(transactions): Reduce the current entitlements to one access level, ignoring
    // revoked and unknown products. StoreKit's current-entitlement sequence already accounts for
    // expiry and billing grace.
    static func evaluate(_ transactions: [AgeminTransactionSummary]) -> AgeminEntitlement {
        let live = transactions.filter {
            $0.revocationDate == nil && AgeminProductID.all.contains($0.productID)
        }
        // A lifetime purchase outranks any subscription.
        if let lifetime = preferred(live.filter { $0.productID == AgeminProductID.lifetime }) {
            return AgeminEntitlement(kind: .lifetime, isFamilyShared: lifetime.isFamilyShared)
        }
        guard let subscription = preferred(live.filter { $0.productID == AgeminProductID.yearly }) else {
            return .free
        }
        return AgeminEntitlement(
            kind: .subscription,
            expirationDate: subscription.expirationDate,
            isTrial: subscription.isIntroductoryOffer,
            isFamilyShared: subscription.isFamilyShared
        )
    }

    // preferred(candidates): The transaction that represents a product: an owned one over a
    // family-shared one, then the later expiry.
    private static func preferred(_ candidates: [AgeminTransactionSummary]) -> AgeminTransactionSummary? {
        candidates.max { first, second in
            // Ownership outranks expiry; a shared transaction sorts lower.
            if first.isFamilyShared != second.isFamilyShared { return first.isFamilyShared }
            return (first.expirationDate ?? .distantFuture) < (second.expirationDate ?? .distantFuture)
        }
    }

    // statusKind(for entitlement, [now = Date()]): Choose the status and its date.
    // now prevents showing a renewal or expiry date that has already passed.
    static func statusKind(for entitlement: AgeminEntitlement, now: Date = Date()) -> AgeminStatusKind {
        switch entitlement.kind {
        case .none:
            return .free
        case .lifetime:
            return entitlement.isFamilyShared ? .familyShared : .lifetime
        case .subscription:
            // Family members cannot see or manage the owner's renewal.
            if entitlement.isFamilyShared { return .familyShared }
            // A missing or elapsed expiry has no future billing date to show.
            guard let date = entitlement.expirationDate, date > now else { return .active }
            // Trial here is a StoreKit introductory offer, not the app's own trial.
            switch (entitlement.isTrial, entitlement.willAutoRenew) {
            case (true, .some(true)): return .trialRenews(date)
            case (true, .some(false)): return .trialEnds(date)
            case (true, .none): return .trialUntil(date)
            case (false, .some(true)): return .renews(date)
            case (false, .some(false)): return .ends(date)
            case (false, .none): return .activeUntil(date)
            }
        }
    }
}
