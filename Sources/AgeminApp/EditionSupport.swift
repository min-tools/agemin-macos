import Foundation

/// A feature the Free tier does not include, named when the Pro panel opens. The raw value is the
/// English phrase that completes the panel's "Unlock …" sentence; it is localized before display.
enum AgeminProFeature: String {
    /// Encrypting and decrypting without the daily allowance.
    case unlimitedOperations = "unlimited encryption and decryption"
}
