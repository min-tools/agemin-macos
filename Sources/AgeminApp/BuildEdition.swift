import Foundation

/// Build-time identity and access switches. The identity is shared by public, App Store, and
/// private local builds; the flags below choose the trial and unlock rules.
enum AgeminEdition {
    static let bundleIdentifier = "tools.min.agemin"
    static let displayName = "Agemin"

    #if AGEMIN_APP_STORE
    // App Store builds resolve the trial clock through verified app transactions.
    static let isAppStoreBuild = true
    #else
    // Non-Store builds do not use Apple's signed acquisition date.
    static let isAppStoreBuild = false
    #endif

    // Only the ignored private input can bypass verified access locally. Every branch defines the
    // same four values: localProAccess (nil means the normal rules apply), localAccessStatus (the
    // panel's status text in unlocked builds), forcedTrialStartedAt (a trial start that is never
    // written to preferences), and isExpiredTrialPreview.
    #if AGEMIN_LOCAL_BUILD && AGEMIN_APP_STORE
    // Refuse an archive that combines distribution code with a local unlock.
    #error("Local access must not be included in an App Store build.")
    #elseif AGEMIN_LOCAL_BUILD && AGEMIN_EXPIRED_TRIAL_BUILD
    // Preview the public post-trial state without granting local Pro access.
    static let localProAccess: Bool? = nil
    static let localAccessStatus: String? = nil
    static let forcedTrialStartedAt: Date? = AgeminLocalAccess.expiredTrialStartedAt
    static let isExpiredTrialPreview = true
    #elseif AGEMIN_LOCAL_BUILD
    // The everyday Unlocked build: Pro on, trial and StoreKit skipped.
    static let localProAccess: Bool? = AgeminLocalAccess.isPro
    static let localAccessStatus: String? = AgeminLocalAccess.status
    static let forcedTrialStartedAt: Date? = nil
    static let isExpiredTrialPreview = false
    #else
    // Public source and App Store builds use the normal trial and purchase rules.
    static let localProAccess: Bool? = nil
    static let localAccessStatus: String? = nil
    static let forcedTrialStartedAt: Date? = nil
    static let isExpiredTrialPreview = false
    #endif
}

/// Pages the app links to. The release checker's online mode verifies that the website, privacy,
/// terms, and support pages are reachable.
enum AppLinks {
    static let website = URL(string: "https://min.tools/agemin/")!
    static let privacyPolicy = URL(string: "https://min.tools/agemin/privacy/")!
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let support = URL(string: "https://min.tools/agemin/support/")!
    static let ageProject = URL(string: "https://age-encryption.org/")!
}
