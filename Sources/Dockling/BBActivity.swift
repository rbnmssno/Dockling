import Foundation

/// How many Codex threads are working right now in the bb app on this Mac.
///
/// bb runs a local service and writes where it is to `~/.bb/bb-app-runtime.json` (its address and
/// process id; no keys). Its thread counter answers on the loopback address with one number and
/// nothing from the conversations. While bb runs, the counter is asked every few seconds, which costs
/// a local request of a few milliseconds and no model use. While bb is not running nothing is asked:
/// the folder is watched, and bb appearing (the file being written) starts the checks again.
///
/// The count drops to zero when bb quits, when its process is gone, or when two checks in a row fail,
/// so the pet never stays at the laptop for work that is no longer there.
final class BBActivityWatcher {
    struct Runtime: Equatable {
        var server: URL
        var pid: Int32
    }

    var onChange: ((Int) -> Void)?
    var enabled: () -> Bool = { true }
    private(set) var active = 0

    private let dataDir: URL
    private let fetch: (URL, @escaping (Int?) -> Void) -> Void
    private let isAlive: (Int32) -> Bool
    private let next = OneShot()
    private let settleDir = OneShot()
    private var dirSource: DispatchSourceFileSystemObject?
    private var failures = 0
    private var asking = false
    private var started = false

    /// Seconds between checks while some Codex thread works, and while none does.
    static let busyInterval: TimeInterval = 3
    static let idleInterval: TimeInterval = 5
    /// A safety look while bb is not running, in case the folder event was missed.
    static let absentInterval: TimeInterval = 60

    init(dataDir: URL = BBActivityWatcher.defaultDataDir,
         fetch: ((URL, @escaping (Int?) -> Void) -> Void)? = nil,
         isAlive: @escaping (Int32) -> Bool = BBActivityWatcher.processAlive) {
        self.dataDir = dataDir
        self.fetch = fetch ?? BBActivityWatcher.httpFetch
        self.isAlive = isAlive
    }

    static var defaultDataDir: URL {
        if let dir = ProcessInfo.processInfo.environment["BB_DATA_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bb", isDirectory: true)
    }

    func start() {
        started = true
        check()
    }

    func stop() {
        started = false
        next.cancel()
        settleDir.cancel()
        unwatchFolder()
        set(0)
    }

    /// Looks now. Called on start, on a timer, when bb's folder changes and when the setting changes.
    func check() {
        guard started else { return }
        guard enabled() else {
            next.cancel()
            unwatchFolder()
            failures = 0
            set(0)
            return
        }
        guard let runtime = Self.runtime(in: dataDir), isAlive(runtime.pid) else {
            // bb is not running: nothing to count, and nothing to ask until it starts.
            failures = 0
            set(0)
            watchFolder()
            next.schedule(after: Self.absentInterval) { [weak self] in self?.check() }
            return
        }
        unwatchFolder()
        guard let host = Self.hostId(in: dataDir) else {
            // Without this Mac's id the count would include other machines: count nothing, look again later.
            failures = 0
            set(0)
            next.schedule(after: Self.idleInterval) { [weak self] in self?.check() }
            return
        }
        guard !asking else { return }
        asking = true
        let url = Self.countURL(server: runtime.server, hostId: host)
        fetch(url) { [weak self] count in
            DispatchQueue.main.async { self?.took(count) }
        }
    }

    private func took(_ count: Int?) {
        asking = false
        guard started, enabled() else { return }
        if let count {
            failures = 0
            set(count)
        } else {
            failures += 1
            // One lost answer can be a hiccup; two in a row mean bb is gone or not answering.
            if failures >= 2 { set(0) }
        }
        next.schedule(after: active > 0 ? Self.busyInterval : Self.idleInterval) { [weak self] in self?.check() }
    }

    private func set(_ count: Int) {
        guard count != active else { return }
        Log.note("bb: codex threads working \(count)")
        active = count
        onChange?(count)
    }

    // MARK: - Where bb is

    /// bb's own record of its local service. Only an http address on this Mac's loopback is accepted.
    static func runtime(in dir: URL) -> Runtime? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("bb-app-runtime.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return runtime(from: obj)
    }

    static func runtime(from obj: [String: Any]) -> Runtime? {
        guard let s = obj["serverUrl"] as? String, let url = URL(string: s), url.scheme == "http",
              let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host), url.port != nil,
              let pid = (obj["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return Runtime(server: url, pid: pid)
    }

    /// This Mac's id in bb, so threads running on other machines are not counted.
    static func hostId(in dir: URL) -> String? {
        guard let raw = try? String(contentsOf: dir.appendingPathComponent("host-id"), encoding: .utf8) else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return id
    }

    static func countURL(server: URL, hostId: String) -> URL {
        var c = URLComponents()
        c.scheme = server.scheme
        c.host = server.host
        c.port = server.port
        c.path = "/api/v1/threads/count"
        c.queryItems = [URLQueryItem(name: "status", value: "active"), URLQueryItem(name: "providerId", value: "codex"),
                        URLQueryItem(name: "hostId", value: hostId)]
        return c.url!
    }

    private struct Count: Decodable { let total: Int }

    /// `{"total": 3}` → 3. A fraction, a boolean or a negative number is not a count.
    static func parseCount(_ data: Data) -> Int? {
        guard let count = try? JSONDecoder().decode(Count.self, from: data), count.total >= 0 else { return nil }
        return count.total
    }

    static func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 3
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.connectionProxyDictionary = [:]
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// The counter is asked on the loopback address only; a redirect anywhere is not followed.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func httpFetch(_ url: URL, _ done: @escaping (Int?) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { done(nil); return }
            done(parseCount(data))
        }.resume()
    }

    // MARK: - Waiting for bb to start

    private func watchFolder() {
        guard dirSource == nil else { return }
        let fd = open(dataDir.path, O_EVTONLY)
        guard fd >= 0 else { return }  // no bb folder yet: the safety look covers it
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // bb writes several files as it starts; look once they have settled.
            self?.settleDir.schedule(after: 0.7) { [weak self] in self?.check() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    private func unwatchFolder() {
        dirSource?.cancel()
        dirSource = nil
    }
}
