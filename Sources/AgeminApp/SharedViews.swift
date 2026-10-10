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

/// A scrolling page with the standard margins.
struct PageScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            // The content column is capped and stays left-aligned in wider windows.
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Where a file lands: a dashed target while empty, the chosen file's details once one is set.
/// Files can be dropped from Finder or picked with the button.
struct FileDropZone: View {
    let file: ChosenFile?
    let prompt: String
    let symbol: String
    let onChoose: () -> Void
    let onClear: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    @State private var targeted = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous) }

    var body: some View {
        Group {
            // A chosen file shows its name, path, and size with Change and Clear.
            if let file {
                HStack(spacing: 14) {
                    IconTile(symbol: "doc.fill", size: 40, tint: Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(file.displayPath)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.url.path)
                    }
                    Spacer(minLength: 12)
                    Text(file.sizeText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                    Button(localized("Change")) { onChoose() }
                        .buttonStyle(.agemin(.secondary, size: .small))
                        .keyboardFocusable()
                    IconButton(symbol: "xmark", help: "Clear the file", size: .small, action: onClear)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: shape)
                .overlay(shape.stroke(targeted ? Theme.accent : Theme.border, lineWidth: targeted ? 2 : 1))
            } else {
                // Empty: a dashed target with the prompt and a Choose button.
                VStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(targeted ? Theme.accent : Theme.textTertiary)
                    Text(localized(prompt))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Button(localized("Choose File")) { onChoose() }
                        .buttonStyle(.agemin(.secondary, shortcut: "⌘O"))
                        .keyboardFocusable()
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 150)
                .background(targeted ? Theme.accent.opacity(0.06) : Theme.surfaceSunken, in: shape)
                .overlay(
                    shape.strokeBorder(
                        style: StrokeStyle(lineWidth: targeted || contrast == .increased ? 2 : 1.5, dash: [7, 5])
                    )
                    .foregroundStyle(targeted ? Theme.accent : Theme.inputBorder)
                )
            }
        }
        .contentShape(shape)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in onDrop(providers) }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

/// The chip that names a key's kind, or its problem.
struct KeyKindChip: View {
    let kind: AgeKeyKind?
    var usable = true

    var body: some View {
        // Unsupported and unreadable keys are marked in amber; usable ones are neutral.
        if let kind, kind.isSupported, usable {
            Chip(text: kind.label, compact: true)
        } else if let kind {
            // A known kind that age cannot use, or one the caller marked unusable.
            Chip(text: kind.label, tone: .warning, compact: true)
        } else {
            // No kind at all: the line or file is not a key.
            Chip(text: localized("not a key"), mono: false, tone: .warning, compact: true)
        }
    }
}

/// One line of a result or information card: a label on the left, a value on the right.
struct DetailRow<Trailing: View>: View {
    let label: String
    let value: String
    var mono = false
    @ViewBuilder let trailing: Trailing

    // init(label, value, [mono = false], trailing): A row with optional controls after the value.
    init(label: String, value: String, mono: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.value = value
        self.mono = mono
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(localized(label))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(mono ? Theme.mono(12) : .system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension DetailRow where Trailing == EmptyView {
    // init(label, value, [mono = false]): A row without trailing controls.
    init(label: String, value: String, mono: Bool = false) {
        self.init(label: label, value: value, mono: mono) { EmptyView() }
    }
}

/// A card's heading row: a section label and optional controls on the right.
struct CardHeading<Trailing: View>: View {
    let text: String
    @ViewBuilder let trailing: Trailing

    // init(text, trailing): A heading with controls after it.
    init(_ text: String, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            SectionLabel(text)
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension CardHeading where Trailing == EmptyView {
    // init(text): A plain heading.
    init(_ text: String) {
        self.init(text) { EmptyView() }
    }
}

/// The run row of a page: the action button and its blocker while idle, the progress bar and
/// Cancel while the runner works.
struct ActionBar: View {
    @ObservedObject var runner: OperationRunner
    let title: String
    let blocker: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // The running state shows progress and lets the user stop between chunks.
            if runner.isRunning {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: runner.fraction ?? 0)
                        .progressViewStyle(.linear)
                    Text(progressText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                Button(localized("Cancel")) { runner.cancel() }
                    .buttonStyle(.agemin(.secondary, shortcut: "esc"))
                    .keyboardFocusable()
                    .keyboardShortcut(.cancelAction)
            } else {
                // Idle: the action button, disabled while something is still missing.
                Button(localized(title)) { action() }
                    .buttonStyle(.agemin(.primary, shortcut: "⌘⏎"))
                    .keyboardFocusable()
                    .disabled(blocker != nil)
                    .keyboardShortcut(.return, modifiers: .command)
                // The blocker says what is still missing.
                if let blocker {
                    Text(blocker)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: Theme.controlHeight)
    }

    /// What the runner is doing and how far it got.
    private var progressText: String {
        let verb = runner.kind == .decrypt ? localized("Decrypting") : localized("Encrypting")
        // Without a known total only the verb shows.
        guard runner.bytesTotal > 0 else { return verb + "…" }
        return localizedFormat("%@ %@ of %@", verb, ByteCountText.string(runner.bytesDone), ByteCountText.string(runner.bytesTotal))
    }
}

/// A row that explains a missing folder and offers to choose it.
struct FolderPrompt: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: "folder.badge.questionmark", size: 36, tint: Theme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(localized(title))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(localized(detail))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(localized(buttonTitle)) { action() }
                .buttonStyle(.agemin(.primary))
                .keyboardFocusable()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The chosen folder's path with Change, Reveal, and Refresh.
struct FolderRow: View {
    let url: URL
    let onChange: () -> Void
    let onReveal: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(KeyStore.abbreviate(url.path))
                .font(Theme.mono(12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
            Spacer(minLength: 12)
            Button(localized("Change")) { onChange() }
                .buttonStyle(.agemin(.secondary, size: .small))
                .keyboardFocusable()
            Button(localized("Reveal")) { onReveal() }
                .buttonStyle(.agemin(.secondary, size: .small))
                .keyboardFocusable()
            IconButton(symbol: "arrow.clockwise", help: "Read the folder again", size: .small, action: onRefresh)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// A modal prompt for a short name, such as a recipient's file name.
enum NamePrompt {
    // ask(title, message, placeholder, [initial = ""], in window): The typed name, or nil.
    @MainActor static func ask(title: String, message: String, placeholder: String, initial: String = "", in window: NSWindow?) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: localized("Save"))
        alert.addButton(withTitle: localized("Cancel"))
        // A text field is the alert's accessory and takes focus when the alert opens.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Save is the first button.
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

/// A secure field in the app's input chrome.
struct PassphraseField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        SecureField(localized(placeholder), text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($isFocused)
            .padding(.horizontal, 10)
            .frame(height: Theme.smallControlHeight + 2)
            .background(Theme.inputBackground, in: shape)
            .overlay(shape.stroke(isFocused ? Theme.accent : Theme.inputBorder, lineWidth: isFocused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
