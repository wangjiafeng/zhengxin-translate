import Foundation

actor JobControl {
    private var paused = false
    private var cancelled = false

    func pause() { paused = true }
    func resume() { paused = false }
    func cancel() { cancelled = true; paused = false }

    func checkpoint() async throws {
        while paused && !cancelled {
            try await Task.sleep(for: .milliseconds(150))
        }
        if cancelled || Task.isCancelled { throw CancellationError() }
    }
}

