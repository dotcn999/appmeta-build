import Foundation
import Darwin

/// Splits a byte stream on newlines without dropping a trailing partial line or a UTF-8 character split across reads.
struct UTF8LineSplitter {
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending.prefix(upTo: newline)
            pending.removeSubrange(0...newline)
            if line.last == 0x0D { line.removeLast() }
            lines.append(String(decoding: line, as: UTF8.self))
        }
        return lines
    }

    mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: false)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

enum LogDiagnostics {
    static let failureMarkers = ["EXPORT FAILED", "ARCHIVE FAILED", "ITMS-", "error:", "ERROR:"]

    /// First matching line inside the tail, which is where xcodebuild and Transporter put the actionable error.
    static func summarizeFailure(in text: String, tailLines: Int = 200) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines.suffix(tailLines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if failureMarkers.contains(where: { trimmed.contains($0) }) {
                return trimmed
            }
        }
        return nil
    }

    static func tail(_ text: String, maxLines: Int) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    static func failureMessage(status: Int32, arguments: [String], stdout: Data, stderr: Data) -> String {
        let errText = String(decoding: stderr, as: UTF8.self)
        let outText = String(decoding: stdout, as: UTF8.self)
        let combined = errText + (errText.isEmpty || outText.isEmpty ? "" : "\n") + outText
        if let summary = summarizeFailure(in: combined) {
            return summary
        }
        let tailText = tail(combined, maxLines: 20)
        if !tailText.isEmpty { return tailText }
        return "command failed (\(status)): \(arguments.joined(separator: " "))"
    }
}

enum JSONPayload {
    static func object(from data: Data) throws -> [String: Any] {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            throw BuildError.message(preview(text))
        }
        let slice = Data(text[start...end].utf8)
        if let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
            return obj
        }
        throw BuildError.message(preview(text))
    }

    static func array(from data: Data) -> [[String: Any]]? {
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end else { return nil }
        let slice = Data(text[start...end].utf8)
        return try? JSONSerialization.jsonObject(with: slice) as? [[String: Any]]
    }

    private static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return L10n.t("Could not read xcodebuild output.", "无法读取 xcodebuild 的输出。")
        }
        return String(trimmed.suffix(500))
    }
}

protocol CommandExecuting: AnyObject {
    func prepareForNewOperation()
    func cancel()
    var isCancelled: Bool { get }
    func run(
        arguments: [String],
        directory: String,
        extraEnvironment: [String: String],
        onLog: ((String) -> Void)?,
        logFile: URL?
    ) throws -> CommandOutput
}

struct CommandOutput {
    var stdout: Data
    var stderr: Data
}

/// Spawns a child in its own process group so cancel can signal xcodebuild and the compilers it starts.
final class CommandSession: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var pgid: pid_t = 0
    private var cancelled = false

    func prepareForNewOperation() {
        lock.lock()
        cancelled = false
        pgid = 0
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let group = pgid
        lock.unlock()
        guard group > 0 else { return }
        kill(-group, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = self.pgid == group
            self.lock.unlock()
            if stillRunning {
                kill(-group, SIGKILL)
            }
        }
    }

    func run(
        arguments: [String],
        directory: String,
        extraEnvironment: [String: String],
        onLog: ((String) -> Void)?,
        logFile: URL?
    ) throws -> CommandOutput {
        if isCancelled { throw BuildError.cancelled }
        guard let executable = arguments.first, !executable.isEmpty else {
            throw BuildError.message("Missing command.")
        }

        let mergeStreams = onLog != nil
        let outPipe = try Self.makePipe()
        var openFds = [outPipe[0], outPipe[1]]
        let errPipe: [Int32]
        if mergeStreams {
            errPipe = outPipe
        } else {
            do {
                errPipe = try Self.makePipe()
            } catch {
                openFds.forEach { close($0) }
                throw error
            }
            openFds.append(contentsOf: [errPipe[0], errPipe[1]])
        }
        defer { openFds.forEach { close($0) } }

        let pid: pid_t
        do {
            pid = try Self.spawn(
                executable: executable,
                arguments: arguments,
                directory: directory,
                environment: Self.mergedEnvironment(extraEnvironment),
                stdoutWrite: outPipe[1],
                stderrWrite: errPipe[1],
                closeFds: openFds
            )
        } catch {
            throw error
        }

        lock.lock()
        let shouldKillImmediately = cancelled
        pgid = pid
        lock.unlock()
        if shouldKillImmediately {
            kill(-pid, SIGTERM)
        }

        // Parent drops the write ends so readers see EOF after the child exits.
        for writeFd in Set([outPipe[1], errPipe[1]]) {
            if let index = openFds.firstIndex(of: writeFd) {
                close(writeFd)
                openFds.remove(at: index)
            }
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let writer = LineLog(url: logFile)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.drain(
                fd: outPipe[0],
                into: stdoutBox,
                keepAll: onLog == nil,
                onLog: onLog,
                writer: writer
            )
            group.leave()
        }
        if !mergeStreams {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                Self.drain(fd: errPipe[0], into: stderrBox, keepAll: false, onLog: nil, writer: nil)
                group.leave()
            }
        }

        let status = Self.waitPid(pid)
        group.wait()
        writer?.close()

        lock.lock()
        if pgid == pid { pgid = 0 }
        let didCancel = cancelled
        lock.unlock()

        if didCancel {
            throw BuildError.cancelled
        }
        if stdoutBox.exceeded || stderrBox.exceeded {
            throw BuildError.message("Command output exceeded the capture limit: \(arguments.joined(separator: " "))")
        }
        let exitedNormally = (status & 0x7f) == 0
        if !exitedNormally {
            let signal = status & 0x7f
            throw BuildError.message("command failed (signal \(signal)): \(arguments.joined(separator: " "))")
        }
        let exitCode = (status >> 8) & 0xff
        if exitCode != 0 {
            throw BuildError.message(LogDiagnostics.failureMessage(
                status: exitCode,
                arguments: arguments,
                stdout: stdoutBox.data,
                stderr: stderrBox.data
            ))
        }
        return CommandOutput(stdout: stdoutBox.data, stderr: stderrBox.data)
    }

    private static func drain(
        fd: Int32,
        into box: DataBox,
        keepAll: Bool,
        onLog: ((String) -> Void)?,
        writer: LineLog?
    ) {
        var splitter = UTF8LineSplitter()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let cap = keepAll ? 64 * 1024 * 1024 : 256 * 1024
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count))
            box.append(chunk, cap: cap, keepTail: !keepAll)
            if onLog != nil || writer != nil {
                for line in splitter.append(chunk) where !line.isEmpty {
                    writer?.write(line)
                    onLog?(line)
                }
            }
        }
        if let tail = splitter.flush() {
            writer?.write(tail)
            onLog?(tail)
        }
    }

    private static func waitPid(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { return status }
            if result < 0 && errno == EINTR { continue }
            return status
        }
    }

    private static func mergedEnvironment(_ extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extra { env[key] = value }
        return env
    }

    private static func makePipe() throws -> [Int32] {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw BuildError.message("Could not create a pipe: \(String(cString: strerror(errno)))")
        }
        return fds
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        directory: String,
        environment: [String: String],
        stdoutWrite: Int32,
        stderrWrite: Int32,
        closeFds: [Int32]
    ) throws -> pid_t {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            throw BuildError.message("posix_spawnattr_init failed.")
        }
        defer { posix_spawnattr_destroy(&attr) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw BuildError.message("posix_spawn_file_actions_init failed.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        if !directory.isEmpty {
            guard posix_spawn_file_actions_addchdir_np(&actions, directory) == 0 else {
                throw BuildError.message("Could not set the working directory.")
            }
        }
        guard posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO) == 0 else {
            throw BuildError.message("Could not attach command output.")
        }
        for fd in Set(closeFds) {
            posix_spawn_file_actions_addclose(&actions, fd)
        }

        let envPairs = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawnResult: Int32 = withCStrings(arguments) { argv in
            withCStrings(envPairs) { envp in
                posix_spawn(&pid, executable, &actions, &attr, argv, envp)
            }
        }
        guard spawnResult == 0 else {
            throw BuildError.message("Could not start \(executable): \(String(cString: strerror(spawnResult)))")
        }
        return pid
    }

    private static func withCStrings<R>(
        _ values: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        let cStrings = values.map { strdup($0) }
        var pointers: [UnsafeMutablePointer<CChar>?] = cStrings
        pointers.append(nil)
        defer { cStrings.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var didExceed = false

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var exceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceed
    }

    func append(_ chunk: Data, cap: Int, keepTail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(chunk)
        guard storage.count > cap else { return }
        if keepTail {
            storage.removeFirst(storage.count - cap)
        } else {
            didExceed = true
            storage.removeLast(storage.count - cap)
        }
    }
}

final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init?(url: URL?) {
        guard let url else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return nil }
        handle.seekToEndOfFile()
        self.handle = handle
    }

    func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        handle.write(data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}
