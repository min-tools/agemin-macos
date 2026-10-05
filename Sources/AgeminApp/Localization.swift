import Foundation

// localized(english): The translation of an English source string from Agemin's bundled strings,
// or the English text itself when there is none. The English text is the key, so SwiftUI literals
// and AppKit-created views share one localization catalog.
func localized(_ english: String) -> String {
    // The Swift Package build keeps resources in its own module bundle; the Xcode app uses the
    // main bundle.
    #if AGEMIN_SWIFTPM
    Bundle.module.localizedString(forKey: english, value: english, table: nil)
    #else
    // Xcode places the app's localization catalog in the main bundle.
    Bundle.main.localizedString(forKey: english, value: english, table: nil)
    #endif
}
