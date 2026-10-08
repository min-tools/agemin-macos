import Foundation

/// A cancellation flag shared between the main thread and a background task.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    /// Whether cancellation was requested.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    // cancel(): Request cancellation.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Runs one encryption or decryption at a time on a background queue and publishes its progress.
@MainActor
final class OperationRunner: ObservableObject {
    /// What is running, for the progress text.
    enum Kind: Equatable { case encrypt, decrypt }

    @Published private(set) var kind: Kind?
    @Published private(set) var bytesDone: Int64 = 0
    @Published private(set) var bytesTotal: Int64 = 0
    @Published private(set) var startedAt: Date?

    private var flag: CancellationFlag?
    /// Runs once the current work has finished, for a quit that waits for the cleanup.
    private var afterFinish: (() -> Void)?
    /// When progress was last published, to throttle updates from the background thread.
    private var lastPublished = Date.distantPast

    /// Whether work is in flight.
    var isRunning: Bool { kind != nil }

    /// Progress from 0 to 1, or nil when the total is unknown.
    var fraction: Double? {
        guard bytesTotal > 0 else { return nil }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    // run(kind, work, completion): Start the work on a background thread. The work receives a
    // progress callback and a cancellation check; its result or error reaches completion on the
    // main thread. A second call while one runs is ignored.
    func run<T: Sendable>(
        _ kind: Kind,
        work: @escaping @Sendable (_ progress: @escaping AgeEngine.Progress, _ isCancelled: @escaping AgeEngine.Cancellation) throws -> T,
        completion: @escaping @MainActor (Result<T, Error>) -> Void
    ) {
        guard !isRunning else { return }
        let flag = CancellationFlag()
        self.flag = flag
        self.kind = kind
        bytesDone = 0
        bytesTotal = 0
        startedAt = Date()
        lastPublished = .distantPast
        // Progress hops to the main actor; the cancellation flag is read directly on the worker.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try work({ done, total in
                Task { @MainActor [weak self] in self?.publish(done: done, total: total) }
            }, { flag.isCancelled }) }
            // Clear the running state before completion, so a handler sees the runner as idle.
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.kind = nil
                self.flag = nil
                completion(result)
                // A quit that waited for the work and its cleanup continues now.
                if let afterFinish = self.afterFinish {
                    self.afterFinish = nil
                    afterFinish()
                }
            }
        }
    }

    // cancel(): Ask the running work to stop at its next chunk.
    func cancel() {
        flag?.cancel()
    }

    // cancel(then): Cancel, then run the closure on the main thread once the work has stopped
    // and removed its partial output. Nothing running: the closure runs at once.
    func cancel(then: @escaping () -> Void) {
        guard isRunning else {
            then()
            return
        }
        afterFinish = then
        cancel()
    }

    // publish(done, total): Record progress, at most a few times per second plus the final value.
    private func publish(done: Int64, total: Int64) {
        // Progress that arrives after the work finished is dropped.
        guard isRunning else { return }
        let now = Date()
        // Throttle intermediate updates; the last chunk always lands.
        guard done >= total || now.timeIntervalSince(lastPublished) > 0.08 else { return }
        lastPublished = now
        bytesDone = done
        bytesTotal = total
    }
}

/// Byte counts in words, as Finder shows them.
enum ByteCountText {
    /// Finder's file-size style, with digits for zero instead of the word.
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    // string(bytes): A human-readable size such as "1.2 MB".
    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}
