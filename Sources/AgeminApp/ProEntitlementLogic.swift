import Foundation

/// Product identifiers, which must match App Store Connect. The app's 30-day trial is independent
/// of them.
enum AgeminProductID {
    static let yearly = "tools.min.agemin.pro.yearly"
    static let lifetime = "tools.min.agemin.pro.lifetime"
    static let all = [yearly, lifetime]
}
