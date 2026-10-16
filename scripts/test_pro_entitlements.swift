import Foundation

/// Trial arithmetic, the Free tier's daily allowance, and entitlement decisions, compiled with
/// ProEntitlementLogic.swift alone so no StoreKit or Apple Account is involved.
@main
struct EntitlementTests {
    // A fixed clock keeps every date check deterministic.
    static let now = Date(timeIntervalSince1970: 2_000_000)
    static let later = now.addingTimeInterval(3_600)

    // check(condition, message): Stop at the first failed check with its message.
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    // transaction(product, [expiration = nil], [revoked = false], [shared = false], [trial = false]):
    // A summary purchased at now; a revoked one is revoked at now too.
    static func transaction(_ product: String, expiration: Date? = nil, revoked: Bool = false,
                            shared: Bool = false, trial: Bool = false) -> AgeminTransactionSummary {
        AgeminTransactionSummary(
            productID: product,
            purchaseDate: now,
            expirationDate: expiration,
            revocationDate: revoked ? now : nil,
            isFamilyShared: shared,
            isIntroductoryOffer: trial
        )
    }

    // main(): Run the trial, allowance, and entitlement checks.
    static func main() {
        // The app's own trial lasts 30 days from its start, counted in whole days.
        let trialStart = now
        check(AgeminFreeAccessPolicy.isTrialActive(
            startedAt: trialStart,
            now: trialStart.addingTimeInterval(29 * 24 * 60 * 60)
        ), "The app trial lasts through day 29")
        check(!AgeminFreeAccessPolicy.isTrialActive(
            startedAt: trialStart,
            now: trialStart.addingTimeInterval(30 * 24 * 60 * 60)
        ), "The app trial expires after 30 days")
        check(AgeminFreeAccessPolicy.trialDaysRemaining(startedAt: trialStart, now: trialStart) == 30,
              "A new trial reports 30 days remaining")

        // TestFlight's receipt or Apple's fixed sandbox purchase date overrides an app
        // transaction that reports production.
        let sandboxPurchaseDate = Date(timeIntervalSince1970: 1_375_340_400)
        check(AgeminFreeAccessPolicy.usesLocalTrialClock(
            transactionIsProduction: true,
            hasSandboxReceipt: true,
            originalPurchaseDate: now
        ), "TestFlight uses a local trial clock")
        check(AgeminFreeAccessPolicy.usesLocalTrialClock(
            transactionIsProduction: true,
            hasSandboxReceipt: false,
            originalPurchaseDate: sandboxPurchaseDate
        ), "The fixed sandbox purchase date identifies TestFlight on macOS")
        check(!AgeminFreeAccessPolicy.usesLocalTrialClock(
            transactionIsProduction: true,
            hasSandboxReceipt: false,
            originalPurchaseDate: now
        ), "The production App Store uses Apple's signed acquisition date")
        check(AgeminFreeAccessPolicy.usesLocalTrialClock(
            transactionIsProduction: false,
            hasSandboxReceipt: false,
            originalPurchaseDate: now
        ), "StoreKit sandbox and Xcode environments use a local trial clock")
        check(AgeminFreeAccessPolicy.shouldRestartLocalTrial(
            firstAcceptance: false,
            isTestEnvironment: true,
            didMigrateTestClock: false
        ), "An existing TestFlight install receives the corrected trial clock once")
        check(!AgeminFreeAccessPolicy.shouldRestartLocalTrial(
            firstAcceptance: false,
            isTestEnvironment: true,
            didMigrateTestClock: true
        ), "A migrated TestFlight install keeps its existing local clock")

        // Only usesAppStoreDate selects Apple's signed date; it never falls back to local state.
        let localStart = now.addingTimeInterval(24 * 60 * 60)
        check(AgeminFreeAccessPolicy.authoritativeTrialStartDate(
            appStoreOriginalPurchaseDate: now,
            localStartedAt: localStart,
            usesAppStoreDate: true
        ) == now, "The signed App Store date overrides local state")
        check(AgeminFreeAccessPolicy.authoritativeTrialStartDate(
            appStoreOriginalPurchaseDate: nil,
            localStartedAt: localStart,
            usesAppStoreDate: true
        ) == nil, "A missing signed date never falls back to local state")
        check(AgeminFreeAccessPolicy.authoritativeTrialStartDate(
            appStoreOriginalPurchaseDate: nil,
            localStartedAt: localStart,
            usesAppStoreDate: false
        ) == localStart, "Source builds retain their local trial date")

        // The Free tier allows one operation per local calendar day; a fixed UTC calendar keeps
        // the day boundary independent of the machine's time zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let yesterday = now.addingTimeInterval(-24 * 60 * 60)
        check(AgeminFreeAccessPolicy.operationsUsedToday(storedDay: nil, storedCount: 3, now: now, calendar: calendar) == 0,
              "No stored day means nothing was used")
        check(AgeminFreeAccessPolicy.operationsUsedToday(storedDay: now, storedCount: 1, now: now, calendar: calendar) == 1,
              "Today's stored count applies")
        check(AgeminFreeAccessPolicy.operationsUsedToday(storedDay: yesterday, storedCount: 3, now: now, calendar: calendar) == 0,
              "A new day resets the count")
        check(AgeminFreeAccessPolicy.operationsUsedToday(storedDay: now, storedCount: 9, now: now, calendar: calendar) == 1
              && AgeminFreeAccessPolicy.operationsUsedToday(storedDay: now, storedCount: -2, now: now, calendar: calendar) == 0,
              "Stored counts are clamped to the allowance")
        check(AgeminFreeAccessPolicy.operationsRemaining(used: 0) == 1
              && AgeminFreeAccessPolicy.operationsRemaining(used: 2) == 0,
              "Remaining operations never go negative")
        check(AgeminFreeAccessPolicy.countAfterStartingOperation(used: 0) == 1
              && AgeminFreeAccessPolicy.countAfterStartingOperation(used: 1) == nil,
              "The second operation of a day is refused")

        // Evaluation ignores unknown and revoked products and ranks the rest: lifetime over a
        // subscription, an owned subscription over a family-shared one.
        check(!AgeminEntitlementLogic.evaluate([]).isPro, "No transaction is free")
        check(!AgeminEntitlementLogic.evaluate([transaction("unknown")]).isPro, "Unknown products are ignored")
        check(!AgeminEntitlementLogic.evaluate([
            transaction(AgeminProductID.lifetime, revoked: true)
        ]).isPro, "Revoked purchases are ignored")
        let lifetime = AgeminEntitlementLogic.evaluate([
            transaction(AgeminProductID.yearly, expiration: later),
            transaction(AgeminProductID.lifetime)
        ])
        check(lifetime.kind == .lifetime, "Lifetime access wins over subscription access")
        let owned = AgeminEntitlementLogic.evaluate([
            transaction(AgeminProductID.yearly, expiration: later, shared: true),
            transaction(AgeminProductID.yearly, expiration: later.addingTimeInterval(-10))
        ])
        check(!owned.isFamilyShared, "An owned subscription wins over a shared subscription")
        // Status lines for a StoreKit introductory offer follow the renewal flag. The products
        // configure no such offer; this keeps the status logic correct should one ever appear.
        var trial = AgeminEntitlementLogic.evaluate([
            transaction(AgeminProductID.yearly, expiration: later, trial: true)
        ])
        trial.willAutoRenew = true
        check(AgeminEntitlementLogic.statusKind(for: trial, now: now) == .trialRenews(later),
              "A renewing trial reports its first payment date")
        trial.willAutoRenew = false
        check(AgeminEntitlementLogic.statusKind(for: trial, now: now) == .trialEnds(later),
              "A canceled trial reports its end date")
        print("Agemin trial, daily allowance, and Pro entitlement decisions passed")
    }
}
