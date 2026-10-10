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
