import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The heading of a page: a symbol tile, the title, and one line of explanation.
struct PageHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(localized(title))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(localized(subtitle))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
