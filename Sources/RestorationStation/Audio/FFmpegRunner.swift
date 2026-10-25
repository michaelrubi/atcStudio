import Foundation
import Synchronization

/// Finds and runs the `ffmpeg` binary as a child process.
public struct FFmpegRunner: Sendable {
    public enum Failure: LocalizedError {
        case notFound(String)
        case failed(status: Int32, log: String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let tool):
                "Restoration Station could not find \(tool). For development, run: brew install ffmpeg"
            case .failed(let status, let log):
                "ffmpeg stopped with code \(status).\n\(log)"
            }
        }
    }

    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// Looks in `<App>.app/Contents/Resources/bin/` first, then Homebrew.
    public static func locate(tool: String = "ffmpeg", bundle: Bundle = .main) throws -> FFmpegRunner {
        var candidates: [URL] = []
        if let resources = bundle.resourceURL {
            candidates.append(resources.appending(path: "bin").appending(path: tool))
        }
        candidates += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(filePath: $0).appending(path: tool) }
        guard let url = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw Failure.notFound(tool)
        }
        return FFmpegRunner(executableURL: url)
    }

    /// Runs ffmpeg with `arguments` and returns everything it wrote to stderr.
    ///
    /// Progress comes from `-progress pipe:1`. When `duration` (seconds of output) is given,
    /// `progress` receives the finished fraction, 0...1. Cancelling the task stops ffmpeg.
    @discardableResult
    public func run(
        _ arguments: [String],
        duration: Double? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> String {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-hide_banner", "-nostdin", "-nostats", "-progress", "pipe:1"] + arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let state = RunState()
        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading

        outHandle.readabilityHandler = { handle in
            for seconds in state.progressSeconds(in: handle.availableData) {
                if let duration, duration > 0 { progress(min(1, seconds / duration)) }
            }
        }
        errHandle.readabilityHandler = { handle in
            state.appendLog(handle.availableData)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    state.appendLog(errHandle.readDataToEndOfFile())
                    let log = state.log
                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if finished.terminationReason == .exit, finished.terminationStatus == 0 {
                        continuation.resume(returning: log)
                    } else {
                        continuation.resume(throwing: Failure.failed(
                            status: finished.terminationStatus, log: String(log.suffix(4000))))
                    }
                }
                do {
                    try process.run()
                    state.setProcess(process)
                } catch {
                    process.terminationHandler = nil
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Shared between the pipe handlers, the termination handler, and cancellation.
private final class RunState: Sendable {
    private struct Storage {
        var log = Data()
        var pendingLine = ""
        var process: Process?
        var cancelled = false
    }

    private let storage = Mutex(Storage())

    var log: String { storage.withLock { String(decoding: $0.log, as: UTF8.self) } }
    var isCancelled: Bool { storage.withLock { $0.cancelled } }

    func appendLog(_ data: Data) {
        storage.withLock { $0.log.append(data) }
    }

    /// Parses `out_time_us=` lines from `-progress` output into seconds.
    func progressSeconds(in data: Data) -> [Double] {
        storage.withLock { s in
            s.pendingLine += String(decoding: data, as: UTF8.self)
            var lines = s.pendingLine.split(separator: "\n", omittingEmptySubsequences: false)
            s.pendingLine = String(lines.removeLast())
            return lines.compactMap { line in
                guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return nil }
                return us / 1_000_000
            }
        }
    }

    func setProcess(_ process: Process) {
        let cancelled = storage.withLock { s in
            s.process = process
            return s.cancelled
        }
        if cancelled { process.terminate() }
    }

    func cancel() {
        let process = storage.withLock { s in
            s.cancelled = true
            return s.process
        }
        if let process, process.isRunning { process.terminate() }
    }
}
