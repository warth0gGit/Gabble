import Foundation

/// Waits for `operation` but gives up after `seconds`, returning nil.
/// The operation is cancelled when time runs out; if it ignores cancellation it
/// finishes in the background and its result is thrown away. Used so a slow
/// speech or cleanup model can never leave Warble stuck.
func withDeadline<T: Sendable>(seconds: Double,
                               _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = OnceGate()
        let work = Task {
            let value = await operation()
            if gate.claim() { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if gate.claim() {
                work.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}

/// Lets exactly one caller through.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
