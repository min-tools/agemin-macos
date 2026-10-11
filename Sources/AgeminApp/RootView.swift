import AppKit
import SwiftUI

/// The window's content: the sidebar and the current page, with the Pro access banner under them.
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 250)
                    // Key preparation captures the current input and identity list.
                    .disabled(model.isPreparingDecryption)
                Rectangle().fill(Theme.border).frame(width: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Shown only after the trial ends without a verified purchase.
            AgeminAccessBanner()
        }
        .background(Theme.background)
        // Invisible background views give the window its standard title bar and remembered frame.
        .background(StandardWindowChrome())
        .background(WindowFrameMemory(key: "AgeminWindowFrame", restores: true))
        .tint(Theme.accent)
    }

    /// The page the sidebar selected.
    @ViewBuilder private var content: some View {
        switch model.page {
        case .encrypt:
            EncryptView(model: model)
        case .decrypt:
            DecryptView(model: model)
        case .recipients:
            RecipientsView(model: model)
        case .identities:
            IdentitiesView(model: model)
        }
    }
}
