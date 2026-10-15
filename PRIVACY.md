# Agemin Privacy Policy

Effective and last updated: October 15, 2026

This policy explains what data Agemin handles, where it goes, and how you can control it.

Agemin encrypts and decrypts files on your Mac in the age format, using keys you choose. It has no advertising, analytics, tracking SDKs, account system, or developer-operated service, and it makes no network connections of its own.

## Data on your Mac

Agemin stores macOS security-scoped bookmarks for the folders and files you choose: the recipients folder that holds public keys, the identities folder that holds private keys, and any key file you add individually. These bookmarks stay in Agemin's app container and let it reopen the folders on later launches.

In the recipients folder, Agemin reads the `.pub` files to list the public keys you can encrypt for. It writes a new `.pub` file only when you add a recipient, and deletes one only when you ask. In the identities folder, Agemin reads the key files it finds to learn their type and public half. It never changes them. To list identity files and show their public halves, Agemin parses unprotected age identities and legacy RSA keys locally. OpenSSH private material and encrypted identity files are decoded only when you decrypt. Parsed private key material stays in memory only for the scan or operation and is discarded afterward. A passphrase you type, for a file or for a protected key, stays in memory only while it is used and is never stored.

When you create a new age key, Agemin writes the identity file where you choose in a save panel and shows the public key once so you can share it. The file is readable only by your user account.

Agemin reads an input file from the location you selected or dropped it from. It writes the result to the location you choose in a save panel. Agemin creates output files so only your user account can read them. If an operation fails or you cancel it, the partial output is removed. Agemin keeps no copies, history, or logs of the files, keys, or passphrases you use. Before decrypting, Agemin reads the file's header to show who it was encrypted for. The header holds no plaintext.

You can give each key an avatar: a drawn symbol, initials in a color, or an image you choose. The choice is stored in Agemin's app container, keyed by the key's fingerprint. Agemin copies an image you choose into its app container as a small square picture. It does not change the original file or your key folders. Avatars stay on your Mac and are never shared.

Text you copy, such as a public key, a path, or a checksum, is placed on the macOS general pasteboard.

Agemin stores its window position, trial state, and the current day's Free operation count in its app container. In production, the Mac App Store build uses Apple's verified original acquisition date for the 30-day Pro trial. Source builds and verified StoreKit test environments use a local start date. Trial information is not sent to the developer.

After the 30-day Pro trial, without a purchase, Agemin encrypts or decrypts one file per local calendar day. Reading keys, inspecting files, and creating keys are not counted.

Apple processes Agemin Pro purchases and does not share payment details with Agemin's developer. The app reads your Apple purchase status to unlock Pro, including purchases shared through Family Sharing.

## Network requests

Agemin itself makes no network requests and has no network entitlement. All encryption and decryption happens on your Mac. StoreKit, part of macOS, communicates with Apple for product information, purchases, and purchase status. Links in the app, such as those in the About panel, in the Pro panel, and in this policy, open in your browser only when you click them.

## Retention and deletion

The folder and file bookmarks remain in the app container until you choose **Agemin → Forget Folder Access…**, pick different folders, or remove the container. Forgetting access does not change or delete any key or file.

Encrypted and decrypted files remain where you saved them until you delete them. Keys remain in their folders. Avatars, the local trial start date when one is used, the daily count, and other preferences remain in the app container when you forget folder access. Choosing **Use Initials** for a key removes its stored avatar and any copied image. Removing Agemin and its app container deletes all app-managed data. Apple controls the purchase records associated with your Apple Account.

## Your choices

You choose which folders and files Agemin can see, which keys a file is encrypted for, and where every result is saved. Choose **Agemin → Forget Folder Access…** to stop it reopening the key folders on later launches. The age format is open, so files Agemin writes can be opened with the age command line tool and other compatible software, and nothing ties them to Agemin.

## Changes and contact

This policy and its date will be updated when material changes occur. For privacy questions or requests, visit [Agemin support](https://min.tools/agemin/support/).
