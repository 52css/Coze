import Foundation
import Darwin

@main
struct TunnelTrafficMonitorIntegrationTests {
    static func main() {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let port = freeLoopbackPort()
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice

        do { try server.run() }
        catch { fail("could not start local HTTP server: \(error.localizedDescription)") }
        defer {
            if server.isRunning { server.terminate() }
        }

        Thread.sleep(forTimeInterval: 0.8)
        let activity = DispatchSemaphore(value: 0)
        let monitor = TunnelTrafficMonitor()
        guard monitor.start(processIdentifier: server.processIdentifier, onActivity: { activity.signal() }, onFailure: {}) else {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            fail("traffic monitor failed to start")
        }
        defer { monitor.stop() }

        Thread.sleep(forTimeInterval: 2.5)
        let request = Process()
        request.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        request.arguments = ["--silent", "--fail", "http://127.0.0.1:\(port)/"]
        request.standardOutput = FileHandle.nullDevice
        request.standardError = FileHandle.nullDevice
        do {
            try request.run()
            request.waitUntilExit()
        } catch {
            monitor.stop()
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            fail("could not send local HTTP request: \(error.localizedDescription)")
        }
        guard request.terminationStatus == 0 else {
            monitor.stop()
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            fail("local HTTP request failed")
        }

        guard activity.wait(timeout: .now() + 8) == .success else {
            monitor.stop()
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            fail("real loopback traffic was not reported by the monitor")
        }
        print("PASS: real loopback traffic triggers tunnel activity")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    private static func freeLoopbackPort() -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { fail("could not create a loopback socket") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { fail("could not reserve a dynamic loopback port") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        guard read == 0 else { fail("could not read the dynamic loopback port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
