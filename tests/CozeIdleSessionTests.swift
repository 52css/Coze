import Foundation
import Darwin

@main
struct CozeIdleSessionTests {
    static func main() throws {
        try testPreferencesMigrationAndNormalization()
        try testPreferencesRoundTrip()
        testCountdownRenewalAndOneShotExpiration()
        testDisabledCountdown()
        testTunnelTrafficResetsIdleDeadline()
        testTunnelTrafficCarriageReturnFraming()
        testExactTunnelCommandMatching()
        try testTunnelSettingsPermissions()
        testTrafficMonitorLaunchFailure()
        try testLocalTunnelCredentialsReadinessAndReconnect()
        print("PASS: preferences migration and tunnel idle session")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func testPreferencesMigrationAndNormalization() throws {
        let oldJSON = #"{"threshold":10000,"lidHours":2}"#.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(CozePreferences.self, from: oldJSON)
        expect(migrated.tunnelIdleMinutes == 30, "old preferences must default to 30 minutes")

        let invalidJSON = #"{"threshold":10000,"lidHours":2,"tunnelIdleMinutes":999}"#.data(using: .utf8)!
        let normalized = try JSONDecoder().decode(CozePreferences.self, from: invalidJSON)
        expect(normalized.tunnelIdleMinutes == 30, "invalid timeout must normalize to 30 minutes")
    }

    private static func testPreferencesRoundTrip() throws {
        for minutes in [0, 15, 30, 60] {
            let source = CozePreferences(threshold: 9_999, lidHours: 4, tunnelIdleMinutes: minutes)
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(CozePreferences.self, from: data)
            expect(decoded.tunnelIdleMinutes == minutes, "timeout \(minutes) must survive JSON round trip")
        }
    }

    private static func testCountdownRenewalAndOneShotExpiration() {
        let start = Date(timeIntervalSince1970: 1_000)
        var session = TunnelIdleSession(minutes: 30)
        session.start(now: start)
        expect(session.tick(now: start.addingTimeInterval(1)) == .remaining(1_799), "countdown must use an absolute deadline")

        session.renew(now: start.addingTimeInterval(100))
        expect(session.tick(now: start.addingTimeInterval(101)) == .remaining(1_799), "renew must restore the full timeout")
        expect(session.tick(now: start.addingTimeInterval(1_900)) == .expired, "expiration must be emitted at the deadline")
        expect(session.tick(now: start.addingTimeInterval(1_901)) == .inactive, "expiration must be emitted only once")
    }

    private static func testDisabledCountdown() {
        let start = Date(timeIntervalSince1970: 1_000)
        var session = TunnelIdleSession(minutes: 0)
        session.start(now: start)
        expect(session.tick(now: start.addingTimeInterval(99_999)) == .inactive, "disabled timeout must never expire")
    }

    private static func testTunnelTrafficResetsIdleDeadline() {
        let start = Date(timeIntervalSince1970: 1_000)
        var session = TunnelIdleSession(minutes: 30)
        var traffic = TunnelTrafficActivityTracker()
        session.start(now: start)

        expect(!traffic.observe(csvLine: ",bytes_in,bytes_out,"), "CSV header must not count as traffic")
        expect(!traffic.observe(csvLine: "ssh.4242,0,0,"), "zero-byte baseline must not count as traffic")
        expect(traffic.observe(csvLine: "ssh.4242,420,730,"), "new loopback bytes must count as traffic")
        session.renew(now: start.addingTimeInterval(100))

        expect(!traffic.observe(csvLine: "ssh.4242,420,730,"), "unchanged totals must remain idle")
        expect(session.tick(now: start.addingTimeInterval(101)) == .remaining(1_799), "traffic must restore the full timeout")
        expect(traffic.observe(csvLine: "ssh.4242,421,730,"), "either traffic direction must count as activity")
        expect(!traffic.observe(csvLine: "ssh.4242,0,0,"), "counter reset alone must not count as activity")
    }

    private static func testTunnelTrafficCarriageReturnFraming() {
        var lines = TunnelTrafficLineBuffer()
        expect(lines.append(",bytes_in,bytes_out,\rPython.4242,0,0,\r") == [",bytes_in,bytes_out,", "Python.4242,0,0,"], "PTY carriage returns must delimit CSV records")
        expect(lines.append("Python.4242,78") == [], "partial CSV records must remain buffered")
        expect(lines.append(",804,\r") == ["Python.4242,78,804,"], "a later chunk must complete the buffered record")

        var crlfLines = TunnelTrafficLineBuffer()
        expect(crlfLines.append(",bytes_in,bytes_out,\r\nPython.4242,78,804,\r\n") == [",bytes_in,bytes_out,", "Python.4242,78,804,"], "PTY CRLF pairs must delimit CSV records")
    }

    private static func testExactTunnelCommandMatching() {
        let settings = TunnelSettings(host: "bastion.example.com", port: 22, username: "demo", identityFile: "/tmp/demo key", routes: [
            TunnelRoute(name: "内部看板", localPort: 8080, targetHost: "10.0.0.8", targetPort: 80, path: "/")
        ])
        let exact = ["/usr/bin/ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-p", "22", "-L", "127.0.0.1:8080:10.0.0.8:80", "-i", "/tmp/demo key", "demo@bastion.example.com"]
        expect(TunnelCommandMatcher.matches(arguments: exact, settings: settings), "exact SSH argv must match the configured tunnel")

        var wrongPort = exact
        wrongPort[wrongPort.firstIndex(of: "22")!] = "2222"
        expect(!TunnelCommandMatcher.matches(arguments: wrongPort, settings: settings), "SSH port 2222 must not match port 22")

        var extraForward = exact
        extraForward.insert(contentsOf: ["-L", "127.0.0.1:9090:10.0.0.9:90"], at: extraForward.count - 1)
        expect(!TunnelCommandMatcher.matches(arguments: extraForward, settings: settings), "an SSH process with extra forwards must not be adopted")

        var wrongEndpoint = exact
        wrongEndpoint[wrongEndpoint.count - 1] = "demo@bastion.example.com.invalid"
        expect(!TunnelCommandMatcher.matches(arguments: wrongEndpoint, settings: settings), "endpoint matching must not use substrings")
    }

    private static func testTunnelSettingsPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coze-settings-test-\(UUID().uuidString)")
        let file = root.appendingPathComponent("nested/tunnel.json")
        setenv("COZE_TUNNEL_CONFIG", file.path, 1)
        defer {
            unsetenv("COZE_TUNNEL_CONFIG")
            try? FileManager.default.removeItem(at: root)
        }
        let settings = TunnelSettings(host: "bastion.example.com", port: 22, username: "demo", identityFile: "", routes: [TunnelRoute(name: "服务", localPort: 8080, targetHost: "10.0.0.8", targetPort: 80, path: "/")])
        TunnelSettingsStore.save(settings)
        expect(TunnelSettingsStore.load() == settings, "saved tunnel settings must round trip")
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        expect(directoryMode == 0o700, "tunnel configuration directory must be private")
        expect(fileMode == 0o600, "tunnel configuration file must be private")
    }

    private static func testTrafficMonitorLaunchFailure() {
        let monitor = TunnelTrafficMonitor(scriptPath: "/missing/script", nettopPath: "/missing/nettop")
        expect(!monitor.start(processIdentifier: getpid(), onActivity: {}, onFailure: {}), "missing traffic tools must fail monitoring startup")
    }

    private static func testLocalTunnelCredentialsReadinessAndReconnect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coze-fake-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ssh")
        let fakeSSH = #"""
#!/usr/bin/python3
import os, signal, socket, subprocess, sys, time

password = subprocess.check_output([os.environ["SSH_ASKPASS"]], text=True).rstrip("\n")
if password != "test-password" or "test-password" in os.environ.values():
    sys.exit(41)

ports = []
arguments = sys.argv[1:]
for index, argument in enumerate(arguments):
    if argument == "-L":
        ports.append(int(arguments[index + 1].split(":")[1]))
if arguments[-1].endswith("@occupied.fixture"):
    ports = []

listeners = []
for port in ports:
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen()
    listeners.append(listener)

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    time.sleep(0.1)
"""#
        expect(FileManager.default.createFile(atPath: executable.path, contents: Data(fakeSSH.utf8), attributes: [.posixPermissions: 0o700]), "fake SSH executable must be created")

        let artifactsBefore = credentialArtifactNames()
        let tunnel = LocalSSHTunnel(sshExecutable: executable.path, readinessTimeout: 1.5)
        let firstSettings = makeLocalSettings(port: try freeLoopbackPort())
        let first = waitForStart(tunnel: tunnel, settings: firstSettings, password: "test-password")
        if case .failure(let error) = first { expect(false, "fake SSH should become ready: \(error.localizedDescription)") }
        expect(tunnel.isRunning, "tunnel must report running only after its local forward listens")
        expect(credentialArtifactNames().subtracting(artifactsBefore).isEmpty, "successful authentication must not leave credential artifacts")

        tunnel.stopOwned()
        waitUntilStopped(tunnel)
        expect(!tunnel.isRunning, "owned tunnel must stop cleanly")

        let secondSettings = makeLocalSettings(port: try freeLoopbackPort())
        let second = waitForStart(tunnel: tunnel, settings: secondSettings, password: "test-password")
        if case .failure(let error) = second { expect(false, "tunnel must reconnect immediately after cleanup: \(error.localizedDescription)") }
        tunnel.stopOwned()
        waitUntilStopped(tunnel)

        let occupied = try occupyLoopbackPort()
        defer { Darwin.close(occupied.descriptor) }
        var occupiedSettings = makeLocalSettings(port: occupied.port)
        occupiedSettings.host = "occupied.fixture"
        let wrongOwner = waitForStart(tunnel: tunnel, settings: occupiedSettings, password: "test-password")
        if case .success = wrongOwner { expect(false, "a local port owned by another process must not be treated as SSH readiness") }
        waitUntilStopped(tunnel)

        let rejected = waitForStart(tunnel: tunnel, settings: makeLocalSettings(port: try freeLoopbackPort()), password: "wrong-password")
        if case .success = rejected { expect(false, "a rejected askpass credential must not be reported as connected") }
        expect(credentialArtifactNames().subtracting(artifactsBefore).isEmpty, "failed authentication must clean askpass resources")
    }

    private static func makeLocalSettings(port: Int) -> TunnelSettings {
        TunnelSettings(host: "fixture.invalid", port: 22, username: "demo", identityFile: "", routes: [TunnelRoute(name: "测试服务", localPort: port, targetHost: "127.0.0.1", targetPort: 80, path: "/")])
    }

    private static func waitForStart(tunnel: LocalSSHTunnel, settings: TunnelSettings, password: String) -> Result<Void, Error> {
        let signal = DispatchSemaphore(value: 0)
        let result = LockedResult()
        tunnel.start(settings: settings, password: password) { value in result.set(value); signal.signal() }
        expect(signal.wait(timeout: .now() + 6) == .success, "tunnel start completion must not hang")
        return result.value!
    }

    private static func waitUntilStopped(_ tunnel: LocalSSHTunnel) {
        for _ in 0..<50 {
            if !tunnel.isRunning { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func credentialArtifactNames() -> Set<String> {
        let values = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(values.filter { $0.hasPrefix("coze-ssh-askpass-") || $0.hasPrefix("coze-ssh-password-") })
    }

    private static func freeLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: "CozeTests", code: 1) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw NSError(domain: "CozeTests", code: 2) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        guard read == 0 else { throw NSError(domain: "CozeTests", code: 3) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func occupyLoopbackPort() throws -> (descriptor: Int32, port: Int) {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: "CozeTests", code: 4) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else { Darwin.close(descriptor); throw NSError(domain: "CozeTests", code: 5) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        guard read == 0 else { Darwin.close(descriptor); throw NSError(domain: "CozeTests", code: 6) }
        return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
    }
}

private final class LockedResult {
    private let lock = NSLock()
    private var storage: Result<Void, Error>?
    func set(_ value: Result<Void, Error>) { lock.lock(); storage = value; lock.unlock() }
    var value: Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return storage }
}
