import Foundation

/// Runs JavaScript for Automation through `/usr/bin/osascript`, off the main thread, with a
/// timeout and prompt cancellation. A child process keeps a hung browser from blocking Wisp:
/// the worst case is the timeout, after which the process is terminated.
struct OSAScriptRunner: Sendable {
    var timeout: Duration = .seconds(2)

    func run(_ script: String, arguments: [String]) async throws -> Data {
        let job = ScriptJob(script: script, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await job.run()
        } onCancel: {
            job.cancel()
        }
    }
}

/// One osascript process. Its state is guarded by a lock; the blocking reads run on a utility queue.
private final class ScriptJob: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let timeout: Duration
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false
    private var errorData = Data()

    init(script: String, arguments: [String], timeout: Duration) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script] + arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        self.timeout = timeout
    }

    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    try launch()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let deadline = DispatchWorkItem { [self] in
                    lock.withLock { timedOut = true }
                    terminate()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.timeInterval, execute: deadline)

                // Read both pipes to the end so a large reply cannot fill a pipe and stall the child.
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async { [self] in
                    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                    lock.withLock { errorData = stderr }
                    group.leave()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                deadline.cancel()

                let (wasCancelled, wasTimedOut, stderrData) = lock.withLock { (cancelled, timedOut, errorData) }
                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if wasTimedOut {
                    continuation.resume(throwing: BrowserScriptError.timedOut)
                } else if process.terminationStatus != 0 {
                    // osascript reports Apple Event errors as text; only the error number is kept.
                    let message = String(decoding: stderrData, as: UTF8.self)
                    continuation.resume(throwing: message.contains("-1743") ? BrowserScriptError.notAuthorized
                        : BrowserScriptError.failed(status: process.terminationStatus))
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private func launch() throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        terminate()
    }

    /// SIGTERM, then SIGKILL a second later if the script is still there, so a stop that waits
    /// for it can never hang.
    private func terminate() {
        let pid: pid_t? = lock.withLock {
            guard process.isRunning else { return nil }
            process.terminate()
            return process.processIdentifier
        }
        guard let pid else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.withLock {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
