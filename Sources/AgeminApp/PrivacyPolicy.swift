import AppKit

/// The policy window. Escape closes it.
private final class PrivacyPolicyPanel: NSPanel {
    // cancelOperation(sender): Close on Escape.
    override func cancelOperation(_ sender: Any?) { close() }
}
