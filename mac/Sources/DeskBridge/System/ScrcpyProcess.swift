import Darwin
import DeskBridgeCore
import Foundation

enum ScrcpyError: Error {
    case notInstalled
    case launchFailed(Int32)
    case cancelled
    case alreadyStarted
}

struct ScrcpyLaunchConfiguration: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]

    static func prepare(adbPath: String, serial: String) throws -> Self {
        try prepare(adbPath: adbPath, serial: serial, environment: ProcessInfo.processInfo.environment)
    }

    static func prepare(adbPath: String, serial: String, environment: [String: String],
                        searchDirectories: [String]? = nil,
                        bundleURL: URL = Bundle.main.bundleURL) throws -> Self
    {
        let executable: URL
        var childEnvironment = environment
        if bundleURL.pathExtension.lowercased() == "app" {
            let contents = bundleURL.standardizedFileURL.appendingPathComponent("Contents")
            executable = contents.appendingPathComponent("Helpers/scrcpy")
            let resources = contents.appendingPathComponent("Resources/scrcpy")
            let server = resources.appendingPathComponent("scrcpy-server")
            let requiredFiles = [server, resources.appendingPathComponent("scrcpy.png"),
                                 resources.appendingPathComponent("disconnected.png")]
            let hasResources = requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            guard FileManager.default.isExecutableFile(atPath: executable.path), hasResources else {
                throw ScrcpyError.notInstalled
            }
            childEnvironment["SCRCPY_SERVER_PATH"] = server.path
            childEnvironment["SCRCPY_ICON_DIR"] = resources.path
        } else {
            let directories = searchDirectories ?? ["/opt/homebrew/bin", "/usr/local/bin"]
                + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            guard let found = directories.filter({ $0.hasPrefix("/") })
                .map({ URL(fileURLWithPath: $0).appendingPathComponent("scrcpy").standardizedFileURL })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
            else {
                throw ScrcpyError.notInstalled
            }
            executable = found
        }
        let adb = URL(fileURLWithPath: adbPath).standardizedFileURL
        if adb.path == ManagedADB.executable.standardizedFileURL.path {
            try ManagedADB.ensureServerCompatible(adb)
        }
        childEnvironment["ADB"] = adb.path
        return Self(executableURL: executable, arguments: ["--serial=\(serial)", "--max-size=1600",
                                                           "--max-fps=60", "--video-bit-rate=6M", "--no-audio",
                                                           "--no-clipboard-autosync",
                                                           "--window-title=DeskBridge"],
                    environment: childEnvironment)
    }
}

struct ScrcpyExit: Sendable {
    let status: Int32
    let wasSignalled: Bool
}

/// All waitpid and signal operations run on one queue. The child stays unreaped until
/// that queue observes its exit, so a signal can never target a reused PID.
private final class ScrcpyChild: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DeskBridge.scrcpy.child")
    private let pid: pid_t
    private let onExit: @Sendable (ScrcpyExit) -> Void
    private var exitSource: DispatchSourceProcess?
    private var exited = false
    private var stopping = false

    init(pid: pid_t, onExit: @escaping @Sendable (ScrcpyExit) -> Void) {
        self.pid = pid
        self.onExit = onExit
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource = source
        source.setEventHandler { [self] in reap(waitForExit: true) }
        source.resume()
        // A child can exit before the watcher is registered.
        queue.async { [self] in reap() }
    }

    func stop() {
        queue.async { [self] in
            reap()
            guard !exited, !stopping else { return }
            stopping = true
            kill(pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + .seconds(1)) { [self] in
                reap()
                if !exited {
                    kill(pid, SIGKILL)
                    // The exit notification can already have been delivered. Finish the wait
                    // on this child's private queue so closing the mirror always resumes handoff.
                    reap(waitForExit: true)
                }
            }
        }
    }

    private func reap(waitForExit: Bool = false) {
        guard !exited else { return }
        var status: Int32 = 0
        let options = waitForExit ? 0 : WNOHANG
        var result = waitpid(pid, &status, options)
        while result < 0, errno == EINTR {
            result = waitpid(pid, &status, options)
        }
        guard result == pid || (result < 0 && errno == ECHILD) else { return }
        exited = true
        exitSource?.cancel()
        exitSource = nil
        let signal = status & 0x7F
        onExit(ScrcpyExit(status: result < 0 ? 1 : signal == 0 ? (status >> 8) & 0xFF : signal,
                          wasSignalled: signal != 0))
    }
}

actor ScrcpyProcess {
    private var child: ScrcpyChild?
    private var finished = false
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func start(_ configuration: ScrcpyLaunchConfiguration,
               onExit: @escaping @Sendable (ScrcpyExit) -> Void) throws -> pid_t
    {
        guard !finished else { throw ScrcpyError.cancelled }
        guard !started else { throw ScrcpyError.alreadyStarted }
        started = true
        var actions: posix_spawn_file_actions_t?
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else { finished = true; throw ScrcpyError.launchFailed(result) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            result = posix_spawn_file_actions_addopen(&actions, fd, "/dev/null",
                                                      fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
            guard result == 0 else { finished = true; throw ScrcpyError.launchFailed(result) }
        }
        let arguments = [configuration.executableURL.path] + configuration.arguments
        let environment = configuration.environment.map { "\($0.key)=\($0.value)" }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in argv {
                free(pointer)
            }
            for pointer in envp {
                free(pointer)
            }
        }
        var pid: pid_t = 0
        result = posix_spawn(&pid, configuration.executableURL.path, &actions, nil, &argv, &envp)
        guard result == 0 else { finished = true; throw ScrcpyError.launchFailed(result) }
        child = ScrcpyChild(pid: pid) { [weak self] exit in
            Task { await self?.didExit(exit, callback: onExit) }
        }
        return pid
    }

    func stop() async {
        guard !finished else { return }
        guard let child else { finished = true; return }
        child.stop()
        await withCheckedContinuation { waiters.append($0) }
    }

    private func didExit(_ exit: ScrcpyExit, callback: @Sendable (ScrcpyExit) -> Void) {
        finished = true
        child = nil
        let pending = waiters
        waiters.removeAll()
        callback(exit)
        for waiter in pending {
            waiter.resume()
        }
    }
}
