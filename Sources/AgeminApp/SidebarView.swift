import AppKit
import SwiftUI

/// The left pane: the two file pages and the two key pages with their counts. Access status lives
/// in the Pro panel and the post-trial banner, not here.
struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: KeyStore
    /// True once the native table's own selection highlight is turned off. Until then the list
    /// gets no selection, so the default blue fill can never flash before the rows take over.
    @State private var listAppearanceReady = false

    // init(model): Observe the model and its key store, so counts stay current.
    init(model: AppModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.store)
    }

    var body: some View {
        VStack(spacing: 0) {
            // A native selection list is one Tab stop and owns arrow-key navigation, focus
            // transfer and accessibility.
            List(selection: listAppearanceReady ? selection : .constant(nil)) {
                Section {
                    pageRow("lock.fill", "Encrypt", .encrypt, count: nil)
                    pageRow("lock.open.fill", "Decrypt", .decrypt, count: nil)
                } header: {
                    SectionLabel("Files")
                        .padding(.leading, 4)
                        .padding(.vertical, 6)
                        // The hook that turns off the table's own highlight rides in this header.
                        .background(SidebarListSelectionAppearance {
                            listAppearanceReady = true
                        })
                }
                // The key pages show how many usable keys they hold.
                Section {
                    pageRow("person.2.fill", "Recipients", .recipients, count: store.recipients.filter(\.isUsable).count)
                    pageRow("key.fill", "Identities", .identities, count: store.identities.filter(\.isUsable).count)
                } header: {
                    SectionLabel("Keys")
                        .padding(.leading, 4)
                        .padding(.vertical, 10)
                }
            }
            // The list draws no background or focus ring of its own, and the selection switch-on
            // is not animated.
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contentMargins(.trailing, 4, for: .scrollContent)
            .focusEffectDisabled()
            .accessibilityLabel(localized("Pages"))
            .animation(nil, value: listAppearanceReady)
        }
        .background(Theme.sidebarBackground)
    }

    // pageRow(symbol, title, page, count): One page row, tagged so the list selection maps back to
    // the page. A nil or zero count shows no number.
    private func pageRow(_ symbol: String, _ title: String, _ page: AppModel.Page, count: Int?) -> some View {
        PageRow(symbol: symbol, title: title, count: count, selected: model.page == page)
            .tag(page)
            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            .listRowSeparator(.hidden)
    }

    /// Mirrors the model's page as the list selection.
    private var selection: Binding<AppModel.Page?> {
        Binding(
            get: { model.page },
            set: { page in
                // Clicking the selected row again gives nil; the page stays.
                if let page { model.page = page }
            }
        )
    }
}
