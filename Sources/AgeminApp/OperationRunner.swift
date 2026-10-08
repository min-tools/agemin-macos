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
