import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A file the user chose or dropped, with the security scope that lets the sandbox read it.
struct ChosenFile: Equatable {
    let url: URL
    let size: Int64
    /// Whether the scope was opened for this file and must be closed when it is dropped.
    let accessed: Bool

    var name: String { url.lastPathComponent }
    var displayPath: String { KeyStore.abbreviate(url.path) }
    var sizeText: String { ByteCountText.string(size) }
}

/// The last finished encryption, shown until the next run.
struct EncryptResult: Equatable {
    let input: ChosenFile
    let output: URL
    let outcome: AgeEncryptOutcome
    let recipientNames: [String]
    let armored: Bool
    let usedPassphrase: Bool

    var overhead: Int64 { outcome.outputSize - outcome.inputSize }
}

/// The last finished decryption, shown until the next run.
struct DecryptResult: Equatable {
    let input: ChosenFile
    let output: URL
    let outcome: AgeDecryptOutcome
    let identityName: String
}
