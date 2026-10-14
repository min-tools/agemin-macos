/// Checks that a public source or App Store build keeps the shared identity and the normal access
/// rules. Compiled with BuildEdition.swift alone. Usage: test [source|app-store], naming the flag
/// the binary was compiled with.
@main
struct EditionTests {
    // main(): Compare the compiled edition with the one named on the command line.
    static func main() {
        // The runner names the edition it compiled; a plain source build is the default.
        let expected = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "source"
        precondition(AgeminEdition.bundleIdentifier == "tools.min.agemin")
        precondition(AgeminEdition.displayName == "Agemin")
        precondition(AgeminEdition.isAppStoreBuild == (expected == "app-store"))
        // Local overrides must be absent from both public editions.
        precondition(AgeminEdition.localProAccess == nil)
        precondition(AgeminEdition.localAccessStatus == nil)
        precondition(AgeminEdition.forcedTrialStartedAt == nil)
        precondition(!AgeminEdition.isExpiredTrialPreview)
        // The policy is the app's own page; the terms are Apple's standard EULA.
        precondition(AppLinks.privacyPolicy.host == "min.tools")
        precondition(AppLinks.termsOfUse.host == "www.apple.com")
        print("\(expected) build keeps the shared identity and normal access rules")
    }
}
