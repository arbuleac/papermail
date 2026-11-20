import Foundation
import os
import SSCore

/// One running CLI: its pipes, timers and private folder. Built and started by `CLIProcessRunner.run(_:)`.
///
/// Every piece of state is touched on `queue` only, so the readers, the exit, the timers and a stop from the consumer
/// never race. The object keeps itself alive until the process has exited and both pipes are drained (the termination
/// handler holds it); only then is the folder removed and the exit delivered.
final class CLIProcess: @unchecked Sendable {
    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "ai")

    private let queue = DispatchQueue(label: "io.supersparrow.mac.ai.cli", qos: .userInitiated)
    private let command: CLICommand
    private let limits: CLILimits
    private let folder: URL
    private let environment: [String: String]
    private let process = Process()

    private var onLine: ((Data) -> Void)?
    private var onExit: ((CLIExit) -> Void)?
    private var reader = JSONLineReader()
    private var stderrTail = Data()
    private var channels: [DispatchIO] = []
    private var stdoutOpen = true
    private var stderrOpen = true
    private var status: CLIExit.Status?
    private var launched = false
    private var stopRequested = false
    private var terminating = false
    private var timedOut = false
    private var ended = false
    private var startedAt = DispatchTime.now()
    private var lastOutput = DispatchTime.now()
    private var idleTimer: DispatchSourceTimer?
    private var totalTimer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var drainTimer: DispatchSourceTimer?
    private var lineCount = 0

    init(command: CLICommand, limits: CLILimits, folder: URL, environment: [String: String],
         onLine: @escaping (Data) -> Void, onExit: @escaping (CLIExit) -> Void) {
        self.command = command
        self.limits = limits
        self.folder = folder
        self.environment = environment
        self.onLine = onLine
        self.onExit = onExit
    }

    /// Launches the process in `folder` and writes the input. A launch failure removes the folder and throws
    /// `AIError.notInstalled`: whatever the reason, the CLI cannot be run from where it was found.
    func start() throws {
        var descriptors: [Int32] = []
        do {
            let input = try Self.makePipe(&descriptors)
            let output = try Self.makePipe(&descriptors)
            let errors = try Self.makePipe(&descriptors)
            process.executableURL = command.executable
            process.arguments = command.arguments(folder)
            process.environment = environment
            process.currentDirectoryURL = folder
            // Raw descriptors rather than `Pipe`, so which end is closed when is ours to say: the child's ends close in
            // this process right after the launch (or stdout would never reach end of file), ours when read or written.
            process.standardInput = FileHandle(fileDescriptor: input.read, closeOnDealloc: false)
            process.standardOutput = FileHandle(fileDescriptor: output.write, closeOnDealloc: false)
            process.standardError = FileHandle(fileDescriptor: errors.write, closeOnDealloc: false)
            process.terminationHandler = { [self] process in
                let status: CLIExit.Status = process.terminationReason == .uncaughtSignal
                    ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
                queue.async { self.exited(status) }
            }
            try process.run()
            close(input.read)
            close(output.write)
            close(errors.write)
            let channels = [
                channel(reading: output.read, chunk: { [self] in received($0) }, end: { [self] in stdoutEnded() }),
                channel(reading: errors.read, chunk: { [self] in receivedErrors($0) }, end: { [self] in stderrEnded() }),
            ]
            queue.async { [self] in
                self.channels = channels
                didLaunch()
            }
            write(command.input, to: input.write)
        } catch {
            process.terminationHandler = nil
            for descriptor in descriptors { close(descriptor) }
            try? FileManager.default.removeItem(at: folder)
            Self.log.debug("CLI did not start: \(self.command.executable.lastPathComponent, privacy: .public)")
            throw AIError.notInstalled
        }
    }

    /// The consumer left: nothing more is delivered, and the process is ended (SIGTERM, then SIGKILL after the grace).
    /// The folder is still removed once it has exited.
    func stop() {
        queue.async { [self] in
            onLine = nil
            onExit = nil
            if launched { terminate() } else { stopRequested = true }
        }
    }

    // MARK: Lifecycle (on `queue`)

    private func didLaunch() {
        launched = true
        startedAt = .now()
        lastOutput = .now()
        Self.log.debug("CLI started: \(self.command.executable.lastPathComponent, privacy: .public), pid \(self.process.processIdentifier, privacy: .public)")
        guard status == nil else { return }
        if stopRequested {
            terminate()
            return
        }
        totalTimer = after(command.totalTimeout) { [self] in timeOut() }
        armIdleTimer(after: command.idleTimeout)
    }

    private func armIdleTimer(after delay: Duration) {
        idleTimer?.cancel()
        idleTimer = after(delay) { [self] in
            let silent = Duration.nanoseconds(Int64(DispatchTime.now().uptimeNanoseconds - lastOutput.uptimeNanoseconds))
            if silent >= command.idleTimeout {
                timeOut()
            } else {
                armIdleTimer(after: command.idleTimeout - silent)
            }
        }
    }

    private func received(_ chunk: Data) {
        lastOutput = .now()
        for line in reader.feed(chunk) {
            lineCount += 1
            onLine?(line)
        }
    }

    private func stdoutEnded() {
        guard stdoutOpen else { return }
        stdoutOpen = false
        for line in reader.finish() {
            lineCount += 1
            onLine?(line)
        }
        endIfDone()
    }

    private func receivedErrors(_ chunk: Data) {
        stderrTail.append(chunk)
        if stderrTail.count > limits.stderrBytes {
            stderrTail = Data(stderrTail.suffix(limits.stderrBytes))
        }
    }

    private func stderrEnded() {
        guard stderrOpen else { return }
        stderrOpen = false
        endIfDone()
    }

    private func exited(_ status: CLIExit.Status) {
        self.status = status
        idleTimer?.cancel()
        totalTimer?.cancel()
        killTimer?.cancel()
        if stdoutOpen || stderrOpen {
            // A helper the CLI started may still hold the pipes; what the CLI itself wrote is in them already.
            drainTimer = after(limits.drain) { [self] in
                for channel in channels { channel.close(flags: .stop) }
            }
        }
        endIfDone()
    }

    private func endIfDone() {
        guard let status, !stdoutOpen, !stderrOpen, !ended else { return }
        ended = true
        // The timers' handlers and the channels hold this object: let them go.
        for timer in [idleTimer, totalTimer, killTimer, drainTimer] { timer?.cancel() }
        idleTimer = nil
        totalTimer = nil
        killTimer = nil
        drainTimer = nil
        channels = []
        let kept = command.keepFile.flatMap(readKeptFile)
        try? FileManager.default.removeItem(at: folder)
        process.terminationHandler = nil
        let exit = CLIExit(status: status, timedOut: timedOut, stderr: stderrTail, keptFile: kept)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1e9
        Self.log.debug("CLI ended: \(self.command.executable.lastPathComponent, privacy: .public), code \(exit.code, privacy: .public), timed out \(self.timedOut, privacy: .public), \(self.lineCount, privacy: .public) lines, \(self.stderrTail.count, privacy: .public) stderr bytes, \(elapsed, format: .fixed(precision: 3), privacy: .public) s")
        let deliver = onExit
        onLine = nil
        onExit = nil
        deliver?(exit)
    }

    private func timeOut() {
        guard status == nil else { return }
        timedOut = true
        terminate()
    }

    private func terminate() {
        guard status == nil, !terminating else { return }
        terminating = true
        process.terminate()
        killTimer = after(limits.killGrace) { [self] in
            guard status == nil, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: Pipes

    private func channel(reading descriptor: Int32, chunk: @escaping (Data) -> Void,
                         end: @escaping () -> Void) -> DispatchIO {
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue,
                                 cleanupHandler: { _ in close(descriptor) })
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, _ in
            if let data, !data.isEmpty {
                var bytes = Data(capacity: data.count)
                data.enumerateBytes { buffer, _, _ in bytes.append(buffer) }
                chunk(bytes)
            }
            if done {
                channel.close()
                end()
            }
        }
        return channel
    }

    /// Writes the input without blocking a thread, then closes stdin so the CLI sees the end of the request. A CLI
    /// that exits without reading makes the write fail with EPIPE instead of raising SIGPIPE in the app.
    private func write(_ input: Data?, to descriptor: Int32) {
        guard let input, !input.isEmpty else {
            close(descriptor)
            return
        }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue,
                                 cleanupHandler: { _ in close(descriptor) })
        let bytes = input.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: bytes, queue: queue) { done, _, _ in
            if done { channel.close() }
        }
    }

    private func readKeptFile(_ name: String) -> Data? {
        let url = folder.appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limits.captureBytes)
    }

    private func after(_ delay: Duration, _ body: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay.dispatchInterval)
        timer.setEventHandler(handler: body)
        timer.resume()
        return timer
    }

    private static func makePipe(_ opened: inout [Int32]) throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw AIError.badResponse(code: 0) }
        opened += descriptors
        // Only the ends handed to the child as 0, 1 and 2 may cross into it (the dup clears this flag there).
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        return (descriptors[0], descriptors[1])
    }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(clamping: seconds * 1_000_000_000 + attoseconds / 1_000_000_000))
    }
}
