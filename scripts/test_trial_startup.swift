import SwiftUI

extension View {
    // keyboardFocusable(): Leave fixture views unchanged; tests do not exercise focus.
    func keyboardFocusable() -> some View { self }
}
