import XCTest
@testable import Dockling

final class BBActivityTests: XCTestCase {
    private var dir: URL!
    private var answers: [Int?] = []
    private var asked: [URL] = []
    private var alive = true
    private var seen: [Int] = []
    private var enabled = true
    private var watcher: BBActivityWatcher!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockling-bb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        answers = []
        asked = []
        alive = true
        seen = []
        enabled = true
        watcher = BBActivityWatcher(dataDir: dir, fetch: { [unowned self] url, done in
            self.asked.append(url)
            done(self.answers.isEmpty ? nil : self.answers.removeFirst())
        }, isAlive: { [unowned self] _ in self.alive })
        watcher.enabled = { [unowned self] in self.enabled }
        watcher.onChange = { [unowned self] in self.seen.append($0) }
    }

    override func tearDown() {
        watcher.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeRuntime(_ server: String = "http://127.0.0.1:38886", pid: Int = 4242, host: Bool = true) throws {
        if host { try "host_test1\n".write(to: dir.appendingPathComponent("host-id"), atomically: true, encoding: .utf8) }
        let json = try JSONSerialization.data(withJSONObject: ["serverUrl": server, "pid": pid, "version": "0.50.1"])
        try json.write(to: dir.appendingPathComponent("bb-app-runtime.json"))
    }

    /// Runs one check and lets the answer (delivered on the main queue) arrive.
    private func look() {
        watcher.check()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testRuntimeOnlyOnLoopbackHTTP() {
        XCTAssertEqual(BBActivityWatcher.runtime(from: ["serverUrl": "http://127.0.0.1:38886", "pid": 12])?.pid, 12)
        XCTAssertNotNil(BBActivityWatcher.runtime(from: ["serverUrl": "http://localhost:5000", "pid": 1]))
        XCTAssertNil(BBActivityWatcher.runtime(from: ["serverUrl": "http://example.com:38886", "pid": 12]), "never another machine")
        XCTAssertNil(BBActivityWatcher.runtime(from: ["serverUrl": "https://127.0.0.1:38886", "pid": 12]))
        XCTAssertNil(BBActivityWatcher.runtime(from: ["serverUrl": "http://127.0.0.1", "pid": 12]))
        XCTAssertNil(BBActivityWatcher.runtime(from: ["serverUrl": "http://127.0.0.1:38886", "pid": 0]))
        XCTAssertNil(BBActivityWatcher.runtime(from: ["serverUrl": "http://127.0.0.1:38886"]))
    }

    func testCountURLAndAnswer() throws {
        let url = BBActivityWatcher.countURL(server: URL(string: "http://127.0.0.1:38886")!, hostId: "host_abc")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:38886/api/v1/threads/count?status=active&providerId=codex&hostId=host_abc")
        XCTAssertEqual(BBActivityWatcher.parseCount(Data(#"{"total":4}"#.utf8)), 4)
        XCTAssertNil(BBActivityWatcher.parseCount(Data(#"{"error":"x"}"#.utf8)))
        XCTAssertNil(BBActivityWatcher.parseCount(Data("<html>".utf8)))
        XCTAssertNil(BBActivityWatcher.parseCount(Data(#"{"total":true}"#.utf8)))
        XCTAssertNil(BBActivityWatcher.parseCount(Data(#"{"total":2.5}"#.utf8)))
        XCTAssertNil(BBActivityWatcher.parseCount(Data(#"{"total":-1}"#.utf8)))
        XCTAssertNil(BBActivityWatcher.parseCount(Data(#"{"total":"3"}"#.utf8)))
        try "host_example01\n".write(to: dir.appendingPathComponent("host-id"), atomically: true, encoding: .utf8)
        XCTAssertEqual(BBActivityWatcher.hostId(in: dir), "host_example01")
        try "../../etc".write(to: dir.appendingPathComponent("host-id"), atomically: true, encoding: .utf8)
        XCTAssertNil(BBActivityWatcher.hostId(in: dir))
    }

    func testNothingIsAskedWhileBBIsNotRunning() {
        watcher.start()
        look()
        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(watcher.active, 0)
    }

    func testBBStartingLaterIsNoticed() throws {
        watcher.start()
        XCTAssertTrue(asked.isEmpty)
        try writeRuntime()
        answers = [2]
        // The folder event schedules a look; wait for it.
        let deadline = Date().addingTimeInterval(3)
        while watcher.active == 0, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(watcher.active, 2)
        XCTAssertEqual(asked.first?.path, "/api/v1/threads/count")
    }

    func testWorkEndsAndSeveralTasks() throws {
        try writeRuntime()
        answers = [1, 3, 0]
        watcher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        look()
        look()
        XCTAssertEqual(seen, [1, 3, 0])
    }

    func testBBQuittingStopsTheWork() throws {
        try writeRuntime()
        answers = [2]
        watcher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(watcher.active, 2)
        alive = false
        look()
        XCTAssertEqual(watcher.active, 0)
        XCTAssertEqual(asked.count, 1, "a dead bb is not asked")
        // The runtime file gone altogether works the same way.
        alive = true
        try FileManager.default.removeItem(at: dir.appendingPathComponent("bb-app-runtime.json"))
        look()
        XCTAssertEqual(watcher.active, 0)
    }

    func testLostConnectionStopsTheWorkAfterTwoMisses() throws {
        try writeRuntime()
        answers = [2, nil, nil]
        watcher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(watcher.active, 2)
        look()
        XCTAssertEqual(watcher.active, 2, "one missed answer is a hiccup")
        look()
        XCTAssertEqual(watcher.active, 0)
    }

    func testWithoutThisMacsIdNothingIsCounted() throws {
        try writeRuntime(host: false)
        answers = [5]
        watcher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(asked.isEmpty, "never counts every machine")
        XCTAssertEqual(watcher.active, 0)
        // The id appears later: the next look counts this Mac only.
        try "host_test1".write(to: dir.appendingPathComponent("host-id"), atomically: true, encoding: .utf8)
        look()
        XCTAssertEqual(watcher.active, 5)
        XCTAssertTrue(asked.last?.query?.contains("hostId=host_test1") == true)
    }

    func testRedirectsAreNotFollowed() throws {
        // A loopback server that answers with a redirect elsewhere.
        let server = try RedirectServer()
        defer { server.close() }
        let done = expectation(description: "answer")
        var result: Int? = -1
        BBActivityWatcher.httpFetch(URL(string: "http://127.0.0.1:\(server.port)/api/v1/threads/count?status=active&providerId=codex&hostId=h")!) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertNil(result)
        XCTAssertEqual(server.requests, 1, "the redirect target is never asked")
    }

    func testSettingOff() throws {
        try writeRuntime()
        answers = [2]
        watcher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        enabled = false
        look()
        XCTAssertEqual(watcher.active, 0)
        XCTAssertEqual(asked.count, 1)
    }

    func testSettingIsOnForUpdatingUsers() {
        let store = UserDefaults(suiteName: "dockling.tests.\(UUID().uuidString)")!
        store.set("claude", forKey: "chatProvider")  // someone who used an earlier version
        XCTAssertTrue(Preferences(store: store).bbActivity)
    }

    func testClaudeAndCodexTogether() {
        XCTAssertEqual(PetBrain.activity(claude: .none, codex: 0), .none)
        XCTAssertEqual(PetBrain.activity(claude: .none, codex: 1), .work)
        XCTAssertEqual(PetBrain.activity(claude: .work, codex: 0), .work)
        XCTAssertEqual(PetBrain.activity(claude: .work, codex: 2), .work)
        // Claude Code waiting for an answer still shows over Codex working.
        XCTAssertEqual(PetBrain.activity(claude: .wait, codex: 3), .wait)
        XCTAssertEqual(PetBrain.badge(claudeSessions: 0, codex: 1), 0)
        XCTAssertEqual(PetBrain.badge(claudeSessions: 1, codex: 1), 2)
        XCTAssertEqual(PetBrain.badge(claudeSessions: 0, codex: 3), 3)
        XCTAssertEqual(PetBrain.badge(claudeSessions: 2, codex: 0), 2)
    }
}

/// A one-port HTTP server on 127.0.0.1 that answers every request with a redirect to itself, counting requests.
final class RedirectServer {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0, listen(fd, 4) == 0 else { Darwin.close(fd); throw NSError(domain: "RedirectServer", code: 1) }
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)
        self.fd = fd
        self.port = port
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                var buf = [UInt8](repeating: 0, count: 2048)
                _ = read(c, &buf, buf.count)
                self?.lock.lock(); self?.count += 1; self?.lock.unlock()
                let reply = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = reply.withCString { write(c, $0, strlen($0)) }
                Darwin.close(c)
            }
        }
    }

    func close() { Darwin.close(fd) }
}
