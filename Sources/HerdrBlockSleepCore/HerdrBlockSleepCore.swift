import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

public struct Config {
    let herdrBin: String
    let socketPath: String
    let stateDir: URL
    let lidCheckSeconds: UInt32
    let reconcileSeconds: TimeInterval
    let maxFailures: Int
    let logURL: URL
    let pidURL: URL
    let statusURL: URL

    public init(environment: [String: String]) {
        herdrBin = environment["HERDR_BIN_PATH"] ?? "herdr"
        socketPath = environment["HERDR_SOCKET_PATH"] ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/herdr/herdr.sock").path
        let defaultState = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/state/herdr-block-sleep")
        stateDir = URL(fileURLWithPath: environment["HERDR_PLUGIN_STATE_DIR"] ?? defaultState.path)
        lidCheckSeconds = UInt32(environment["HERDR_BLOCK_SLEEP_LID_CHECK_SECONDS"] ?? "15") ?? 15
        reconcileSeconds = TimeInterval(Int(environment["HERDR_BLOCK_SLEEP_RECONCILE_SECONDS"] ?? "300") ?? 300)
        maxFailures = Int(environment["HERDR_BLOCK_SLEEP_MAX_FAILURES"] ?? environment["HERDR_PREVENT_SLEEP_MAX_FAILURES"] ?? "4") ?? 4
        logURL = stateDir.appendingPathComponent("block-sleep.log")
        pidURL = stateDir.appendingPathComponent("daemon.pid")
        statusURL = stateDir.appendingPathComponent("status.json")
    }
}

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct AgentSnapshot {
    let workingCount: Int
    let paneIDs: [String]
}

struct AssertionDecision: Equatable {
    let desired: Bool
    let reason: String
}

func assertionDecision(lid: String?, workingCount: Int) -> AssertionDecision {
    if lid == "Yes" {
        return AssertionDecision(desired: false, reason: "lid-closed")
    }
    if workingCount > 0 {
        return AssertionDecision(desired: true, reason: "working-agents=\(workingCount)")
    }
    return AssertionDecision(desired: false, reason: "idle")
}

func parseAgentSnapshot(_ agents: [[String: Any]]) -> AgentSnapshot {
    var working = 0
    var panes: [String] = []
    for agent in agents {
        if let paneID = agent["pane_id"] as? String { panes.append(paneID) }
        if (agent["agent_status"] as? String) == "working" { working += 1 }
    }
    return AgentSnapshot(workingCount: working, paneIDs: Array(Set(panes)).sorted())
}

struct MonitorError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
    return formatter.string(from: Date())
}

func readPID(from url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    return pid_t(value)
}

func pidAlive(_ pid: pid_t?) -> Bool {
    guard let pid else { return false }
    return kill(pid, 0) == 0
}

func currentExecutableURL() -> URL {
    let arg0 = CommandLine.arguments[0]
    if arg0.hasPrefix("/") {
        return URL(fileURLWithPath: arg0).standardizedFileURL
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(arg0)
        .standardizedFileURL
}

func executableURL(for executable: String) throws -> URL {
    if executable.contains("/") {
        return URL(fileURLWithPath: executable).standardizedFileURL
    }

    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for directory in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executable)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }
    }

    throw MonitorError("executable not found in PATH: \(executable)")
}

public final class Termination {
    public static var requested = false
}

final class SocketClient {
    private let path: String
    private var fd: Int32 = -1

    init(path: String) {
        self.path = path
    }

    deinit {
        closeSocket()
    }

    func connect() throws {
        closeSocket()
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MonitorError("socket failed: \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let copied = withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer -> Bool in
            guard pathBytes.count <= rawBuffer.count else { return false }
            rawBuffer.copyBytes(from: pathBytes)
            return true
        }
        guard copied else { throw MonitorError("socket path too long: \(path)") }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw MonitorError("connect \(path) failed: \(errno)") }
    }

    func closeSocket() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    func request(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        try connect()
        defer { closeSocket() }
        try send(method: method, params: params)
        guard let line = try readLine(timeoutSeconds: 10) else {
            throw MonitorError("timed out waiting for \(method) response")
        }
        return try parseResponse(line)
    }

    func subscribe(subscriptions: [[String: Any]]) throws {
        try connect()
        try send(method: "events.subscribe", params: ["subscriptions": subscriptions])
        guard let line = try readLine(timeoutSeconds: 10) else {
            throw MonitorError("timed out waiting for subscription ack")
        }
        _ = try parseResponse(line)
    }

    func waitForEvent(timeoutSeconds: UInt32) throws -> Bool {
        guard let line = try readLine(timeoutSeconds: timeoutSeconds) else {
            return false
        }
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonitorError("invalid event JSON")
        }
        if let error = object["error"] as? [String: Any] {
            throw MonitorError("subscription error: \(error)")
        }
        return true
    }

    private func send(method: String, params: [String: Any]) throws {
        let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: request)
        var bytes = Array(data)
        bytes.append(10)
        var sent = 0
        while sent < bytes.count {
            let count = Darwin.write(fd, bytes.withUnsafeBytes { $0.baseAddress!.advanced(by: sent) }, bytes.count - sent)
            if count < 0 { throw MonitorError("socket write failed: \(errno)") }
            sent += count
        }
    }

    private func parseResponse(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonitorError("invalid response JSON")
        }
        if let error = object["error"] as? [String: Any] {
            throw MonitorError("socket API error: \(error)")
        }
        return object
    }

    private func readLine(timeoutSeconds: UInt32) throws -> String? {
        var timeout = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1)
        while true {
            let n = Darwin.read(fd, &buffer, 1)
            if n == 0 { throw MonitorError("socket closed") }
            if n < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
                throw MonitorError("socket read failed: \(errno)")
            }
            if buffer[0] == 10 { break }
            bytes.append(buffer[0])
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

public final class Monitor {
    private let config: Config
    private let fileManager = FileManager.default
    private var assertionIDs: [IOPMAssertionID] = []
    private var running = true

    public init(config: Config) {
        self.config = config
    }

    public func stop() {
        running = false
    }

    public func run() -> Int32 {
        do {
            try fileManager.createDirectory(at: config.stateDir, withIntermediateDirectories: true)
            try String(ProcessInfo.processInfo.processIdentifier).write(to: config.pidURL, atomically: true, encoding: .utf8)
        } catch {
            fputs("failed to initialize state directory: \(error)\n", stderr)
            return 1
        }

        log("native monitor started lid_check_seconds=\(config.lidCheckSeconds) reconcile_seconds=\(Int(config.reconcileSeconds)) socket=\(config.socketPath)")
        var failures = 0

        while running && !Termination.requested {
            do {
                let snapshot = try refreshAndApply(reason: "bootstrap")
                failures = 0
                try eventLoop(snapshot: snapshot)
            } catch {
                failures += 1
                releaseAssertion()
                writeStatus(lid: lidState(), workingAgents: nil, assertionActive: false, reason: "herdr-api-failed")
                log("event client failed failures=\(failures) error=\(error)")
                if failures >= config.maxFailures {
                    log("exiting after repeated Herdr API failures")
                    cleanup()
                    return 0
                }
                sleep(config.lidCheckSeconds)
            }
        }

        cleanup()
        log("native monitor stopped")
        return 0
    }

    private func eventLoop(snapshot: AgentSnapshot) throws {
        let client = SocketClient(path: config.socketPath)
        var subscriptions: [[String: Any]] = []
        for paneID in snapshot.paneIDs {
            subscriptions.append(["type": "pane.agent_status_changed", "pane_id": paneID])
        }

        try client.subscribe(subscriptions: subscriptions)
        log("subscribed to Herdr events panes=\(snapshot.paneIDs.count)")
        let started = Date()
        let subscribedPaneIDs = Set(snapshot.paneIDs)
        var currentSnapshot = snapshot

        while running && !Termination.requested {
            let gotEvent = try client.waitForEvent(timeoutSeconds: config.lidCheckSeconds)
            if gotEvent {
                log("received Herdr event; refreshing agent snapshot")
                let refreshed = try refreshAndApply(reason: "event")
                currentSnapshot = refreshed
                if Set(refreshed.paneIDs) != subscribedPaneIDs {
                    log("pane set changed; rebuilding event subscription")
                    return
                }
                continue
            }

            apply(workingCount: currentSnapshot.workingCount, trigger: "lid-check")
            if Date().timeIntervalSince(started) >= config.reconcileSeconds {
                log("reconcile interval elapsed; refreshing agent snapshot")
                return
            }
        }
    }

    @discardableResult
    private func refreshAndApply(reason: String) throws -> AgentSnapshot {
        let snapshot = try agentSnapshot()
        apply(workingCount: snapshot.workingCount, trigger: reason)
        return snapshot
    }

    private func apply(workingCount: Int, trigger: String) {
        let lid = lidState()
        let decision = assertionDecision(lid: lid, workingCount: workingCount)
        let reason = decision.reason

        if decision.desired {
            acquireAssertion(reason: reason)
        } else {
            releaseAssertion()
        }

        writeStatus(lid: lid, workingAgents: workingCount, assertionActive: !assertionIDs.isEmpty, reason: reason)
        log("tick trigger=\(trigger) lid=\(lid ?? "unknown") working=\(workingCount) assertion=\(!assertionIDs.isEmpty ? 1 : 0) reason=\(reason)")
    }

    private func cleanup() {
        releaseAssertion()
        try? fileManager.removeItem(at: config.pidURL)
    }

    private func log(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if fileManager.fileExists(atPath: config.logURL.path), let handle = try? FileHandle(forWritingTo: config.logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: config.logURL, options: .atomic)
        }
    }

    private func writeStatus(lid: String?, workingAgents: Int?, assertionActive: Bool, reason: String) {
        let status: [String: Any] = [
            "daemon_pid": ProcessInfo.processInfo.processIdentifier,
            "assertion_active": assertionActive,
            "assertion_ids": assertionIDs,
            "lid": lid ?? NSNull(),
            "working_agents": workingAgents ?? NSNull(),
            "reason": reason,
            "updated_at": timestamp(),
            "log": config.logURL.path,
            "mode": "events.subscribe",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: config.statusURL, options: .atomic)
        }
    }

    private func acquireAssertion(reason: String) {
        guard assertionIDs.isEmpty else { return }

        let name = "Herdr agents working (\(reason))" as CFString
        let types = [
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionTypePreventSystemSleep,
        ]

        var created: [IOPMAssertionID] = []
        for type in types {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id)
            if result == kIOReturnSuccess {
                created.append(id)
            } else {
                for existing in created { IOPMAssertionRelease(existing) }
                log("failed to create power assertion type=\(type) result=\(result)")
                return
            }
        }

        assertionIDs = created
        log("created native assertions ids=\(created.map(String.init).joined(separator: ","))")
    }

    private func releaseAssertion() {
        guard !assertionIDs.isEmpty else { return }
        let ids = assertionIDs
        assertionIDs.removeAll()
        for id in ids { IOPMAssertionRelease(id) }
        log("released native assertions ids=\(ids.map(String.init).joined(separator: ","))")
    }

    private func lidState() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let closed = (property as? NSNumber)?.boolValue else {
            return nil
        }

        return closed ? "Yes" : "No"
    }

    private func agentSnapshot() throws -> AgentSnapshot {
        do {
            let response = try SocketClient(path: config.socketPath).request(method: "agent.list")
            guard let result = response["result"] as? [String: Any],
                  let agents = result["agents"] as? [[String: Any]] else {
                throw MonitorError("unexpected agent.list response")
            }
            return parseAgentSnapshot(agents)
        } catch {
            log("socket agent.list failed; falling back to CLI: \(error)")
            return try cliAgentSnapshot()
        }
    }


    private func cliAgentSnapshot() throws -> AgentSnapshot {
        let result = try run(config.herdrBin, ["agent", "list"])
        guard result.exitCode == 0 else {
            throw MonitorError("exit=\(result.exitCode) stderr=\(result.stderr)")
        }
        guard let data = result.stdout.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObject = object["result"] as? [String: Any],
              let agents = resultObject["agents"] as? [[String: Any]] else {
            throw MonitorError("unexpected Herdr agent list JSON")
        }
        return parseAgentSnapshot(agents)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = try executableURL(for: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(exitCode: process.terminationStatus, stdout: String(data: stdoutData, encoding: .utf8) ?? "", stderr: String(data: stderrData, encoding: .utf8) ?? "")
    }
}

public final class CLI {
    private let config: Config
    private let fileManager = FileManager.default

    public init(config: Config) {
        self.config = config
    }

    public func start() -> Int32 {
        do {
            try fileManager.createDirectory(at: config.stateDir, withIntermediateDirectories: true)
        } catch {
            fputs("failed to create state directory: \(error)\n", stderr)
            return 1
        }

        let existingPID = readPID(from: config.pidURL)
        if pidAlive(existingPID) {
            print("block-sleep monitor already running: pid \(existingPID!)")
            return 0
        }
        try? fileManager.removeItem(at: config.pidURL)

        let executable = currentExecutableURL()
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            fputs("missing executable: \(executable.path)\n", stderr)
            return 1
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["daemon"]
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice

        fileManager.createFile(atPath: config.logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: config.logURL) else {
            fputs("failed to open log: \(config.logURL.path)\n", stderr)
            return 1
        }
        _ = try? logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            fputs("failed to start monitor: \(error)\n", stderr)
            return 1
        }
        try? logHandle.close()

        try? String(process.processIdentifier).write(to: config.pidURL, atomically: true, encoding: .utf8)
        print("block-sleep native monitor started: pid \(process.processIdentifier)")
        return 0
    }

    public func stop() -> Int32 {
        let pid = readPID(from: config.pidURL)
        if pidAlive(pid), let pid {
            if kill(pid, SIGTERM) == 0 {
                for _ in 0..<20 {
                    if !pidAlive(pid) { break }
                    usleep(100_000)
                }
                if pidAlive(pid) {
                    _ = kill(pid, SIGKILL)
                }
                try? fileManager.removeItem(at: config.pidURL)
                print("block-sleep native monitor stopped: pid \(pid)")
                return 0
            }
            perror("kill")
            return 1
        }

        try? fileManager.removeItem(at: config.pidURL)
        print("block-sleep monitor was not running")
        return 0
    }

    public func status() -> Int32 {
        let pid = readPID(from: config.pidURL)
        if pidAlive(pid), let pid { print("daemon: running pid \(pid)") } else { print("daemon: stopped") }

        guard let data = try? Data(contentsOf: config.statusURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("native_assertion: unknown")
            print("status: no status file yet")
            print("log: \(config.logURL.path)")
            return 0
        }

        let active = (object["assertion_active"] as? Bool) == true
        let assertionIDs = (object["assertion_ids"] as? [Any] ?? []).map { String(describing: $0) }.joined(separator: ",")
        print("native_assertion: \(active ? "active" : "inactive")")
        print("assertion_ids: \(assertionIDs)")
        print("lid: \(stringValue(object["lid"]))")
        print("working_agents: \(stringValue(object["working_agents"]))")
        print("reason: \(stringValue(object["reason"]))")
        print("mode: \(stringValue(object["mode"]))")
        print("updated_at: \(stringValue(object["updated_at"]))")
        print("log: \(stringValue(object["log"], fallback: config.logURL.path))")
        return 0
    }

    private func stringValue(_ value: Any?, fallback: String = "unknown") -> String {
        switch value {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        case _ as NSNull: return fallback
        case .none: return fallback
        case let value?: return String(describing: value)
        }
    }
}

public func usage() {
    print("usage: herdr-block-sleep [start|stop|status|daemon]")
}
