import Foundation

final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func runOnce(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        action()
    }
}
