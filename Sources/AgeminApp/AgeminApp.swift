import AppKit
import SwiftUI

/// The small About panel shared by the min.tools apps: icon, name, version, copyright, and a link
/// to the author's profile.
@MainActor
private final class MinToolsAboutPanelController: NSWindowController {
    static let shared = MinToolsAboutPanelController()

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let copyrightLabel = NSTextField(labelWithString: "")
    private let profileButton = NSButton()

    // init(): Build the fixed-size panel and stack the icon, labels, and link vertically.
    private init() {
        let size = NSSize(width: 280, height: 174)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        // A title-less panel pinned to one size and draggable anywhere, kept alive when closed so
        // it can be shown again.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        panel.standardWindowButton(.zoomButton)?.isEnabled = false

        // The icon and three centered labels.
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        versionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        copyrightLabel.font = .systemFont(ofSize: 11, weight: .medium)
        for label in [nameLabel, versionLabel, copyrightLabel] {
            label.alignment = .center
            label.textColor = .labelColor
        }

        // The profile link is a borderless button drawn as a hyperlink.
        profileButton.isBordered = false
        profileButton.attributedTitle = NSAttributedString(
            string: "GitHub.com/iliaross",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        profileButton.target = self
        profileButton.action = #selector(openProfile(_:))

        // Stack everything vertically with hand-tuned gaps.
        let stack = NSStackView(views: [
            iconView,
            nameLabel,
            versionLabel,
            copyrightLabel,
            profileButton
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(8, after: iconView)
        stack.setCustomSpacing(7, after: nameLabel)
        stack.setCustomSpacing(8, after: versionLabel)
        stack.setCustomSpacing(0, after: copyrightLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Pin the icon size and center the stack near the top of the panel.
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 54),
            iconView.heightAnchor.constraint(equalToConstant: 54),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10)
        ])
    }

    // init(coder): Unsupported; the panel is only built in code.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // show(applicationName): Refresh the bundle details and present the About panel.
    func show(applicationName: String) {
        // Version, build, and copyright come from Info.plist; the copyright has a fallback.
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let copyright = bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 Ilia Ross"

        iconView.image = NSApp.applicationIconImage
        nameLabel.stringValue = applicationName
        versionLabel.stringValue = "Version \(version) (\(build))"
        copyrightLabel.stringValue = copyright

        // Bring the app forward and center the panel before showing it.
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // openProfile(sender): Open the author's public GitHub profile.
    @objc private func openProfile(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/iliaross") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Owns the model, the launch-time setup, files opened from Finder, and the app menu's actions.
@MainActor
final class AgeminAppDelegate: NSObject, NSApplicationDelegate {
    private static let didShowTrialWelcomeKey = "AgeminDidShowTrialWelcome"
    let model = AppModel()

    // applicationDidFinishLaunching(notification): Set the Dock icon, start the Pro store, and show
    // the trial welcome when it has not been shown yet.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.make()
        // Store setup and the welcome alert run after this method returns and launch completes.
        Task { @MainActor in
            AgeminProStore.shared.start()
            presentTrialWelcomeIfNeeded()
        }
    }

    // applicationShouldTerminateAfterLastWindowClosed(sender): Quit when the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // application(application, open urls): Take a file opened with Agemin from Finder: an age
    // file goes to Decrypt, anything else to Encrypt. Agemin works on one file at a time, so
    // only the first of several is taken, and a folder is refused.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        // Replacing the input while its bytes are being processed would make the visible state
        // disagree with the running operation.
        guard !model.isBusy else {
            model.presentError(
                localized("Wait for the current operation to finish."),
                detail: ""
            )
            return
        }
        var isDirectory: ObjCBool = false
        // Folders cannot be encrypted directly; the user archives them first.
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            model.presentError(localized("Agemin encrypts files, not folders."), detail: localized("Compress the folder into an archive first, then open the archive."))
            return
        }
        // The scope opened here travels with the file and is closed when the file is replaced.
        let file = ChosenFile(url: url, size: AgeEngine.fileSize(url), accessed: url.startAccessingSecurityScopedResource())
        // The age suffix, or an age header, means the file is one to decrypt.
        if url.pathExtension.lowercased() == "age" || (try? AgeEngine.inspect(url: url)) != nil {
            model.setDecryptInput(file)
        } else {
            // Anything else is plain data to encrypt.
            model.setEncryptInput(file)
        }
    }

    // applicationShouldTerminate(sender): Do not quit in the middle of writing a file.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.runner.isRunning else { return .terminateNow }
        // Ask before canceling the work.
        let alert = NSAlert()
        alert.messageText = localized("A file is still being processed.")
        alert.informativeText = localized("Quitting now cancels it and removes the partial output.")
        alert.addButton(withTitle: localized("Quit Anyway"))
        alert.addButton(withTitle: localized("Keep Working"))
        // Quit Anyway is the first button.
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        // The operation can finish while the alert is open. If it did, return immediately. AppKit
        // does not expect a callback before this delegate returns terminateLater.
        guard model.runner.isRunning else { return .terminateNow }
        // Quit once the work has stopped and removed its partial output, not before.
        model.runner.cancel { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    // presentTrialWelcomeIfNeeded(): Explain the trial once and resolve its clock.
    // Later launches resolve quietly; production keeps Apple's acquisition date.
    private func presentTrialWelcomeIfNeeded() {
        let store = AgeminProStore.shared
        // Unlocked private builds and expired-trial previews skip the explanation and the trial.
        guard !store.isLocalBuild,
              !AgeminEdition.isExpiredTrialPreview else {
            return
        }
        // Already shown: begin or resume the trial quietly. This also resolves the trial for
        // preferences carried over from an earlier build.
        if UserDefaults.standard.bool(forKey: Self.didShowTrialWelcomeKey) {
            store.beginAppTrial()
            return
        }
        // First launch: disclose the trial and Free tier before resolving access.
        // This starts a local trial where allowed; it does not reset a signed date.
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = localized("30 days of full access")
        let trialDetails = [
            localized("Agemin is fully unlocked for your first 30 days. No subscription starts, and you will not be charged."),
            localized("After the trial, you can still encrypt or decrypt one file per day. Reading keys, inspecting files, and creating keys stay unlimited."),
            localized("Choose a yearly subscription or lifetime purchase at any time to remove the daily limit."),
        ]
        alert.informativeText = trialDetails.joined(separator: "\n\n")
        alert.addButton(withTitle: localized("Continue"))
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
        store.beginAppTrial()
        UserDefaults.standard.set(true, forKey: Self.didShowTrialWelcomeKey)
    }

    // showAbout(): Show the About panel with the bundle details and the author link.
    func showAbout() {
        MinToolsAboutPanelController.shared.show(applicationName: "Agemin")
    }

    // showPrivacyPolicy(sender): Show the privacy policy window.
    @objc func showPrivacyPolicy(_ sender: Any?) {
        PrivacyPolicyController.shared.show()
    }

    // forgetAccess(): Confirm and drop the saved folder and file permissions.
    func forgetAccess() {
        guard !model.isBusy else { return }
        // Explain what is dropped and that no file is deleted before asking.
        let alert = NSAlert()
        alert.messageText = localized("Forget access to the key folders?")
        alert.informativeText = localized("Agemin removes its saved permissions for the recipients folder, the identities folder, and any key files added individually. Nothing is deleted. Choose them again to keep using them.")
        alert.addButton(withTitle: localized("Forget Access"))
        alert.addButton(withTitle: localized("Cancel"))
        // Forget Access is the first button.
        if alert.runModal() == .alertFirstButtonReturn { model.forgetAccess() }
    }
}

// Menus are declared through SwiftUI so they survive the menu rebuilds SwiftUI performs when
// focus moves, which would drop items inserted through AppKit. Each group observes the model so
// enabled states and checkmarks stay current.

/// The window panels attach to as sheets; any window will do when none is key.
private var keyWindow: NSWindow? { NSApp.keyWindow ?? NSApp.windows.first }

/// The File menu's file and key commands, replacing the standard New group.
private struct FileCommands: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button(localized("Choose File to Encrypt…")) { model.chooseEncryptInput(in: keyWindow) }
            .keyboardShortcut("o", modifiers: .command)
        Button(localized("Choose File to Decrypt…")) { model.chooseDecryptInput(in: keyWindow) }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        Divider()
        Button(localized("New age Key…")) { model.generateIdentity(in: keyWindow) }
            .keyboardShortcut("n", modifiers: .command)
    }
}

/// The Action menu: run the current page's operation or cancel it.
private struct ActionCommands: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var runner: OperationRunner

    // init(model): Observe the model and the runner, so the items follow the running state.
    init(model: AppModel) {
        self.model = model
        _runner = ObservedObject(wrappedValue: model.runner)
    }

    var body: some View {
        // Running an operation also shows its page, so the result lands in view.
        Button(localized("Encrypt…")) {
            model.page = .encrypt
            model.encrypt(in: keyWindow)
        }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(!model.canEncrypt)
        Button(localized("Decrypt…")) {
            model.page = .decrypt
            model.decrypt(in: keyWindow)
        }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!model.canDecrypt)
        Divider()
        Button(localized("Cancel")) { runner.cancel() }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!runner.isRunning)
    }
}

/// The Keys menu: adding keys, choosing folders, and a rescan.
private struct KeysCommands: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: KeyStore

    // init(model): Observe the model and its key store.
    init(model: AppModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.store)
    }

    var body: some View {
        Button(localized("Add Recipient…")) { model.requestAddRecipient() }
            .disabled(model.isPreparingDecryption)
        Button(localized("Choose Recipients Folder…")) { store.chooseRecipientsFolder(in: keyWindow) }
            .disabled(model.isPreparingDecryption)
        Divider()
        Button(localized("Add Key File…")) { store.addIdentityFile(in: keyWindow) }
            .disabled(model.isPreparingDecryption)
        Button(localized("Choose Identities Folder…")) { store.chooseIdentitiesFolder(in: keyWindow) }
            .disabled(model.isPreparingDecryption)
        Divider()
        Button(localized("Refresh Keys")) { store.refresh() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isPreparingDecryption)
        Button(localized("Find…")) {
            // The filter fields live on the key pages; switch there when needed.
            if model.page != .recipients, model.page != .identities { model.page = .recipients }
            NotificationCenter.default.post(name: .focusSidebarSearch, object: keyWindow)
        }
            .keyboardShortcut("f", modifiers: .command)
    }
}

/// The View menu's page toggles, one per page, on ⌘1 to ⌘4.
private struct ViewCommands: View {
    @ObservedObject var model: AppModel

    // pageToggle(title, page, key): A checkmarked menu item that shows the page on ⌘ plus the key.
    private func pageToggle(_ title: String, _ page: AppModel.Page, key: KeyEquivalent) -> some View {
        Toggle(localized(title), isOn: Binding(
            get: { model.page == page },
            set: { selected in
                // Clicking the current page must not leave every page unselected.
                guard selected else { return }
                model.page = page
            }
        ))
        .keyboardShortcut(key, modifiers: .command)
        .disabled(model.isPreparingDecryption)
    }

    var body: some View {
        pageToggle("Encrypt", .encrypt, key: "1")
        pageToggle("Decrypt", .decrypt, key: "2")
        pageToggle("Recipients", .recipients, key: "3")
        pageToggle("Identities", .identities, key: "4")
        Divider()
    }
}

/// The SwiftUI scene: one main window and the menu bar commands.
@main
struct AgeminApplication: App {
    @NSApplicationDelegateAdaptor(AgeminAppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single main window; the root view restores its last frame.
        Window("Agemin", id: "main") {
            RootView(model: appDelegate.model)
                .frame(minWidth: AgeminWindow.minimumSize.width, minHeight: AgeminWindow.minimumSize.height)
        }
        .defaultSize(AgeminWindow.defaultSize)
        .windowStyle(.titleBar)
        .commands {
            // The app menu's own About, Pro, privacy, and forget-access items replace the standard
            // About item.
            CommandGroup(replacing: .appInfo) {
                Button(localized("About Agemin")) {
                    appDelegate.showAbout()
                }
                Divider()
                Button(localized("Agemin Pro…")) {
                    AgeminProStore.shared.present()
                }
                Button(localized("Privacy Policy…")) {
                    appDelegate.showPrivacyPolicy(nil)
                }
                Button(localized("Forget Folder Access…")) {
                    appDelegate.forgetAccess()
                }
            }
            // The File menu's file and key commands take the standard New group's place.
            CommandGroup(replacing: .newItem) {
                FileCommands(model: appDelegate.model)
            }
            // Action and Keys are the app's own menus.
            CommandMenu(localized("Action")) {
                ActionCommands(model: appDelegate.model)
            }
            CommandMenu(localized("Keys")) {
                KeysCommands(model: appDelegate.model)
            }
            // The page toggles sit at the top of the View menu.
            CommandGroup(before: .toolbar) {
                ViewCommands(model: appDelegate.model)
            }
        }
    }
}
