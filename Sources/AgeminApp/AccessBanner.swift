import SwiftUI

/// Offers purchase and restore after the full-access trial has ended.
struct AgeminAccessBanner: View {
    @ObservedObject private var store = AgeminProStore.shared
    @State private var isRestoring = false
    /// Replaces the detail line after a restore that found nothing or failed.
    @State private var restoreMessage: String?

    var body: some View {
        // Wait for StoreKit and trial state so the expired banner cannot flash during launch.
        if store.hasResolvedEntitlement && store.hasPreparedFreeAccess && !store.hasFullAccess {
            // Headline and detail on the left, Restore and Purchase on the right.
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(restoreMessage ?? detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Button(isRestoring ? localized("Restoring…") : localized("Restore Purchases"), action: restore)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRestoring)
                    .keyboardFocusable()
                Button(localized("Purchase")) { store.present() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRestoring)
                    .keyboardFocusable()
            }
            .tint(nil)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .background(Color(nsColor: .systemOrange).opacity(0.16))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .systemOrange).opacity(0.48)).frame(height: 1)
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// The headline only states the transition; the buttons say what to do next.
    private var title: String {
        localized("Trial ended")
    }

    /// The detail names the allowance that now applies and how much of it is left today.
    private var detail: String {
        localizedFormat("You can still encrypt or decrypt one file per day. Available today: %lld.", Int64(store.freeOperationsRemainingToday))
    }

    // restore(): Sync verified purchases once and keep failure feedback inside the banner.
    private func restore() {
        // Ignore repeated clicks while StoreKit is synchronizing the account.
        guard !isRestoring else { return }
        isRestoring = true
        restoreMessage = nil
        Task { @MainActor in
            defer { isRestoring = false }
            do {
                // Sync with the App Store; a verified purchase lifts the banner on its own.
                let restored = try await store.restore()
                // Nothing came back: keep the banner and say so in place of the detail line.
                if !restored {
                    restoreMessage = localized("No active purchase was found.")
                }
            } catch {
                // StoreKit supplies a user-readable message for synchronization failures.
                restoreMessage = error.localizedDescription
            }
        }
    }
}
