import AppKit
import CryptoKit
import SwiftUI

/// Renders the README hero images and the Mac App Store screenshots: the main window with
/// fictional keys, a finished encryption, and a finished decryption, drawn offscreen at 2x with
/// the real title bar, active traffic lights, and a window shadow.
///
/// Usage: render-hero <output directory> <scratch directory> [--app-store <directory>]
@main
enum RenderHero {
    // Window sizes in points for the README and the App Store, the canvas margin that holds the
    // README shadow, and its corner radius. The App Store window is shorter so it fits under a
    // caption; its long pages are scrolled to their result.
    static let windowSize = NSSize(width: 1080, height: 960)
    static let appStoreWindowSize = NSSize(width: 1080, height: 760)
    static let margin: CGFloat = 56
    static let cornerRadius: CGFloat = 10

    /// A Mac App Store screenshot: the page to show, whether it is scrolled to its end, the
    /// appearance, and the caption.
    struct Screenshot {
        let file: String
        let dark: Bool
        let page: AppModel.Page
        let scrollsToEnd: Bool
        let caption: HeroCanvas.Caption
    }

    // The App Store set, in listing order: encrypt, decrypt, recipients, and identities.
    static let screenshots = [
        Screenshot(
            file: "agemin-1-encrypt-light.png", dark: false, page: .encrypt, scrollsToEnd: true,
            caption: HeroCanvas.Caption(
                headline: "Encrypt a file for the people who should read it.",
                subtitle: "Pick recipients by name, press Encrypt, and get a standard age file."
            )
        ),
        Screenshot(
            file: "agemin-2-decrypt-dark.png", dark: true, page: .decrypt, scrollsToEnd: true,
            caption: HeroCanvas.Caption(
                headline: "Decrypt with your key or a passphrase.",
                subtitle: "Agemin reads the file header and picks the matching identity for you."
            )
        ),
        Screenshot(
            file: "agemin-3-recipients-light.png", dark: false, page: .recipients, scrollsToEnd: false,
            caption: HeroCanvas.Caption(
                headline: "Public keys, with names and faces.",
                subtitle: "Keep SSH and age recipients in one list and choose them by name."
            )
        ),
        Screenshot(
            file: "agemin-4-identities-dark.png", dark: true, page: .identities, scrollsToEnd: false,
            caption: HeroCanvas.Caption(
                headline: "Your private keys never leave this Mac.",
                subtitle: "Agemin works offline, with no account and no server."
            )
        ),
    ]

    // main(): Create the fixture keys and files in a scratch home, load them into the model, run
    // one real encryption and decryption for the result cards, and write the images.
    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var arguments = Array(CommandLine.arguments.dropFirst())
        let usage = "usage: render-hero <output directory> <scratch directory> [--app-store <directory>]"
        guard arguments.count >= 2 else {
            print(usage)
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
        let scratch = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
        var appStore: URL?
        if arguments.first == "--app-store", arguments.count == 2 {
            appStore = URL(fileURLWithPath: arguments[1], isDirectory: true)
        } else if !arguments.isEmpty {
            print(usage)
            exit(2)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)

        // This process has its own defaults domain; anything the views store is removed at the end.
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        // A throwaway home with the folders a user would have, so paths read ~/.age, ~/Documents,
        // and ~/Downloads.
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let recipients = home.appendingPathComponent(".age", isDirectory: true)
        let identities = home.appendingPathComponent(".ssh", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let own = X25519Identity.generate()
        do {
            for folder in [recipients, identities, documents, downloads] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            // Fictional recipients: two SSH Ed25519 keys and one age key, generated here.
            for name in ["alice", "dave"] {
                let signing = Curve25519.Signing.PrivateKey()
                var wire = SSHWire.string(Data("ssh-ed25519".utf8))
                wire.append(SSHWire.string(signing.publicKey.rawRepresentation))
                let line = "ssh-ed25519 " + wire.base64EncodedString() + " \(name)@example.com\n"
                try Data(line.utf8).write(to: recipients.appendingPathComponent("\(name).pub"), options: [])
            }
            let carol = X25519Identity.generate()
            try Data((carol.recipient!.line + "\n").utf8).write(to: recipients.appendingPathComponent("carol.pub"), options: [])
            // The user's own age identity, so the Identities count is not zero.
            try Data(AgeIdentityFile.identityFileText(for: own).utf8).write(to: identities.appendingPathComponent("agemin-key.txt"), options: [])
            try Data((own.recipient!.line + "\n").utf8).write(to: recipients.appendingPathComponent("me.pub"), options: [])
            // A fictional document of a believable size.
            try Data(count: 2_418_392).write(to: documents.appendingPathComponent("Board report Q3.pdf"), options: [])
        } catch {
            print("could not stage the fixtures: \(error)")
            exit(1)
        }
        // The override must match the paths as the files report them, so no standardizing here:
        // that would drop the /private prefix of the scratch directory.
        KeyStore.displayHomeOverride = home.path

        // Load the folders like chosen ones, without bookmarks, and pick the file.
        let model = AppModel()
        model.store.adoptWithoutBookmarks(recipientsFolder: recipients, identitiesFolder: identities)
        model.selectAllUsableRecipients()
        let input = documents.appendingPathComponent("Board report Q3.pdf")
        model.setEncryptInput(ChosenFile(url: input, size: AgeEngine.fileSize(input), accessed: false))
        // Resolve the trial as a fresh install would, and give the fictional keys drawn avatars.
        AgeminProStore.shared.beginAppTrial()
        for (entry, symbol) in zip(model.store.recipients.filter { $0.name != "me" }, [AvatarSymbol.orbit, .waves, .hex]) {
            model.avatars.set(.symbol(symbol), for: entry.avatarKey)
        }

        // Encrypt the file for real so the result card shows true numbers.
        let outputFile = documents.appendingPathComponent("Board report Q3.pdf.age")
        do {
            let entries = model.selectedRecipients
            let recipientKeys = entries.compactMap { $0.recipient() }
            let outcome = try AgeEngine.encrypt(input: input, output: outputFile, recipients: recipientKeys, armor: false)
            model.showEncryptResult(EncryptResult(
                input: model.encryptInput!, output: outputFile, outcome: outcome,
                recipientNames: entries.map(\.name), armored: false, usedPassphrase: false
            ))
        } catch {
            print("the fixture encryption failed: \(error)")
            exit(1)
        }

        // Decrypt a received copy for real too, so the Decrypt page shows a finished result.
        let received = downloads.appendingPathComponent("Board report Q3.pdf.age")
        let decrypted = downloads.appendingPathComponent("Board report Q3.pdf")
        do {
            try FileManager.default.copyItem(at: outputFile, to: received)
            model.setDecryptInput(ChosenFile(url: received, size: AgeEngine.fileSize(received), accessed: false))
            // Identity matching checks the private keys off the main thread.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
            let outcome = try AgeEngine.decrypt(input: received, output: decrypted, identities: [own])
            model.showDecryptResult(DecryptResult(
                input: model.decryptInput!, output: decrypted, outcome: outcome, identityName: "agemin-key"
            ))
        } catch {
            print("the fixture decryption failed: \(error)")
            exit(1)
        }

        // The README heroes show the Encrypt page.
        model.page = .encrypt
        for dark in [false, true] {
            let name = dark ? "hero-dark.png" : "hero-light.png"
            HeroCanvas.write(render(model: model, dark: dark), to: output.appendingPathComponent(name))
        }

        // The App Store set at 2880x1800, each scene over the wallpaper with its caption.
        if let appStore {
            try? FileManager.default.createDirectory(at: appStore, withIntermediateDirectories: true)
            for screenshot in screenshots {
                model.page = screenshot.page
                let window = capture(model: model, dark: screenshot.dark, size: appStoreWindowSize, scrollsToEnd: screenshot.scrollsToEnd)
                let canvas = HeroCanvas.appStoreScreenshot(
                    window: window, windowSize: window.size, caption: screenshot.caption, dark: screenshot.dark
                )
                HeroCanvas.write(HeroCanvas.png(canvas, opaque: true), to: appStore.appendingPathComponent(screenshot.file))
            }
        }
    }

    // capture(model, dark, size, scrollsToEnd): Host the root view in an offscreen window of the
    // given content size in the requested appearance and draw its frame view, title bar
    // included, into a 2x bitmap.
    @MainActor static func capture(model: AppModel, dark: Bool, size: NSSize, scrollsToEnd: Bool) -> NSBitmapImageRep {
        // An offscreen window in the requested appearance; a short run loop lets SwiftUI lay out.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // The window is closed after capture while this function still holds it, so AppKit must
        // not free it on close.
        window.isReleasedWhenClosed = false
        window.title = "Agemin"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: RootView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        if scrollsToEnd {
            scrollPageToEnd(in: host)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        }

        // The frame view draws the title bar and content together, as the window looks on screen.
        guard let frameView = window.contentView?.superview else { fatalError("no window frame view") }
        let frameRect = frameView.bounds
        let frameImage = HeroCanvas.bitmap(size: frameRect.size)
        frameView.cacheDisplay(in: frameRect, to: frameImage)
        overdrawTrafficLights(of: window, in: frameView, onto: frameImage)
        window.close()
        return frameImage
    }

    // scrollPageToEnd(in host): Scroll the page, the largest scroll view right of the sidebar, to
    // its last content, so a result card is in view.
    @MainActor static func scrollPageToEnd(in host: NSView) {
        let pages = scrollViews(in: host).filter { $0.convert($0.bounds, to: host).minX >= 250 }
        guard let page = pages.max(by: { $0.bounds.height < $1.bounds.height }),
              let document = page.documentView else {
            print("no page scroll view to scroll")
            return
        }
        let overflow = max(0, document.frame.height - page.contentView.bounds.height)
        // A flipped document scrolls down by raising y; an unflipped one by lowering it.
        page.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? overflow : 0))
        page.reflectScrolledClipView(page.contentView)
    }

    // scrollViews(in view): Every scroll view in the hierarchy, depth first.
    static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView { found.append(scrollView) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }

    // render(model, dark): Draw the window into a bitmap, compose it with a shadow and hairline on
    // a transparent canvas, and return the PNG data.
    @MainActor static func render(model: AppModel, dark: Bool) -> Data {
        let frameImage = capture(model: model, dark: dark, size: windowSize, scrollsToEnd: false)
        let frameRect = NSRect(origin: .zero, size: frameImage.size)

        // A canvas with room for the shadow; all drawing goes through its bitmap context.
        let canvasSize = NSSize(width: frameRect.width + margin * 2, height: frameRect.height + margin * 2)
        let canvas = HeroCanvas.bitmap(size: canvasSize)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { fatalError("no drawing context") }
        NSGraphicsContext.current = context
        let cg = context.cgContext
        let windowRect = NSRect(x: margin, y: margin, width: frameRect.width, height: frameRect.height)
        let shape = NSBezierPath(roundedRect: windowRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // A key window's shadow: soft, large, and slightly below the window.
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 54, color: NSColor.black.withAlphaComponent(dark ? 0.62 : 0.45).cgColor)
        NSColor.black.setFill()
        shape.fill()
        cg.restoreGState()

        // The window image, clipped to its rounded corners.
        shape.addClip()
        frameImage.draw(in: windowRect)
        cg.resetClip()

        // The hairline macOS draws around every window.
        let border = NSBezierPath(roundedRect: windowRect.insetBy(dx: 0.25, dy: 0.25), xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 0.5
        (dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.28)).setStroke()
        border.stroke()

        // PNG keeps the transparent margin, so the shadow blends with the README's background.
        guard let data = canvas.representation(using: .png, properties: [:]) else { fatalError("no png") }
        return data
    }

    // overdrawTrafficLights(of window, in frameView, onto image): Paint active button
    // colors onto the bitmap; AppKit draws this offscreen window's buttons gray.
    @MainActor static func overdrawTrafficLights(of window: NSWindow, in frameView: NSView, onto image: NSBitmapImageRep) {
        // Fill and edge colors of the close, minimize, and zoom buttons of a key window.
        let buttons: [(NSWindow.ButtonType, NSColor, NSColor)] = [
            (.closeButton, NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1), NSColor(srgbRed: 0.88, green: 0.28, blue: 0.25, alpha: 1)),
            (.miniaturizeButton, NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1), NSColor(srgbRed: 0.87, green: 0.62, blue: 0.11, alpha: 1)),
            (.zoomButton, NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.11, green: 0.65, blue: 0.19, alpha: 1)),
        ]
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: image) else { return }
        NSGraphicsContext.current = context
        // Each button's frame is converted into the frame view, which the bitmap was drawn from;
        // a button AppKit did not create is skipped rather than guessed.
        for (type, fill, stroke) in buttons {
            guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
            let frame = superview.convert(button.frame, to: frameView)
            let diameter: CGFloat = 12
            let circle = NSBezierPath(ovalIn: NSRect(x: frame.midX - diameter / 2, y: frame.midY - diameter / 2, width: diameter, height: diameter))
            fill.setFill()
            circle.fill()
            stroke.setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
        }
    }
}
