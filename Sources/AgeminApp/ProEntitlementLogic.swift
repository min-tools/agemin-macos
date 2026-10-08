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
