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

/// One page in the list: an icon tile, the page name, and an optional count.
private struct PageRow: View {
    let symbol: String
    let title: String
    /// Items on the page; nil or zero shows nothing.
    let count: Int?
    let selected: Bool
    /// Whether the pointer is over the row, for the hover fill.
    @State private var hovering = false

    /// The rounded fill shared by the background and the hit area.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 11) {
            IconTile(symbol: symbol, size: 28, tint: selected ? Theme.accent : Theme.textSecondary)
            Text(localized(title))
                .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            // Only a positive count is worth a number.
            if let count, count > 0 {
                Text(String(count))
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        // Rows draw their own selection and hover fill; the table's highlight is turned off.
        .background(
            selected ? Theme.sidebarSelection
                : hovering ? Theme.sidebarHover : Color.clear,
            in: shape
        )
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

/// SwiftUI's sidebar list supplies native selection and keyboard behavior, while this public
/// AppKit setting leaves the selected-row drawing to the rows instead of adding a solid fill.
private struct SidebarListSelectionAppearance: NSViewRepresentable {
    /// Called once, after the table has been configured, so the list can enable selection.
    let onConfigured: () -> Void

    // makeNSView(context): Create the invisible view that will look for the table.
    func makeNSView(context: Context) -> ConfigurationView {
        let view = ConfigurationView()
        view.onConfigured = onConfigured
        return view
    }

    // updateNSView(nsView, context): Re-apply the table settings on every SwiftUI update, in
    // case the list rebuilt its table.
    func updateNSView(_ nsView: ConfigurationView, context: Context) {
        nsView.onConfigured = onConfigured
        nsView.configureTable()
    }

    /// An empty view placed inside a section header, so it sits in the list's table hierarchy.
    final class ConfigurationView: NSView {
        /// Forwarded from the representable; runs once, when the table is first found.
        var onConfigured: (() -> Void)?
        /// Guards the one-time callback; the settings themselves may be applied again.
        private var configuredTable = false

        /// No intrinsic size, so the view never affects the header layout.
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        // viewDidMoveToSuperview(): Configure as soon as the view is attached to the list.
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureTable()
        }

        // configureTable(): Find the enclosing table on the next run loop turn, when the view is
        // fully attached, then turn off its selection highlight and focus ring.
        func configureTable() {
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let view = ancestor {
                    // The first table up the chain is the sidebar list's own.
                    if let table = view as? NSTableView {
                        table.selectionHighlightStyle = .none
                        table.focusRingType = .none
                        // Tell the list once; it can now enable selection safely.
                        if self?.configuredTable == false {
                            self?.configuredTable = true
                            self?.onConfigured?()
                        }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}
