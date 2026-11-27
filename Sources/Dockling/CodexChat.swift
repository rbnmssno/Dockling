import Foundation

/// Codex usage limits, as the local Codex app-server reads them from the ChatGPT account.
/// Each window has its own length: a plan may have one (a week) or two (five hours and a week).
struct CodexLimits: Equatable {
    struct Window: Equatable {
        var used: Double
        /// The window's length in minutes, as Codex reports it (300, 10080…); nil when unknown.
        var minutes: Int?
        var reset: Date?
    }

    var windows: [Window] = []
    /// False only when the account explicitly says ordinary requests are not allowed now. Nil: unknown.
    var ordinaryAllowed: Bool?

    init(windows: [Window] = [], ordinaryAllowed: Bool? = nil) {
        self.windows = windows
        self.ordinaryAllowed = ordinaryAllowed
    }

    /// From one rate-limit snapshot (`primary` and `secondary`).
    init(snapshot s: [String: Any], ordinaryAllowed: Bool? = nil) {
        for key in ["primary", "secondary"] {
            guard let w = s[key] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            windows.append(Window(used: used, minutes: (w["windowDurationMins"] as? NSNumber)?.intValue,
                                  reset: (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }))
        }
        self.ordinaryAllowed = ordinaryAllowed
    }

    /// From the result of `account/rateLimits/read`: the `codex` bucket when there is one.
    init?(read r: [String: Any]) {
        let byId = r["rateLimitsByLimitId"] as? [String: Any]
        guard let snapshot = (byId?["codex"] as? [String: Any]) ?? (r["rateLimits"] as? [String: Any]) else { return nil }
        self.init(snapshot: snapshot, ordinaryAllowed: r["ordinaryUsageAllowed"] as? Bool)
    }

    /// Only the Codex bucket counts; a snapshot of another one (a separate model, say) is left out.
    static func isCodexBucket(_ snapshot: [String: Any]) -> Bool {
        guard let id = snapshot["limitId"] as? String else { return true }
        return id == "codex"
    }

    /// Without the windows that have reset since.
    var current: CodexLimits {
        var l = self
        l.windows = windows.filter { ($0.reset ?? .distantFuture) > Date() }
        return l
    }

    /// Ordinary requests are explicitly unavailable: sending would spend credits or fail.
    var blocked: Bool { ordinaryAllowed == false }

    // Kept between launches, apart from Claude's. The permission is not kept: it must be fresh.
    var stored: [[String: Double]] {
        windows.map { w in
            var d: [String: Double] = ["used": w.used]
            d["minutes"] = w.minutes.map(Double.init)
            d["reset"] = w.reset?.timeIntervalSince1970
            return d
        }
    }

    init(stored list: [[String: Double]]) {
        windows = list.compactMap { d in
            guard let used = d["used"] else { return nil }
            return Window(used: used, minutes: d["minutes"].map { Int($0) }, reset: d["reset"].map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// A short name for a window from its real length: "5 h", "Week", "3 d".
    static func label(minutes: Int?) -> String {
        guard let m = minutes, m > 0 else { return tr("Лимит", "Limit") }
        if m == 10080 { return tr("Неделя", "Week") }
        if m == 1440 { return tr("День", "Day") }
        if m % 1440 == 0 { return tr("\(m / 1440) дн", "\(m / 1440) d") }
        if m % 60 == 0 { return tr("\(m / 60) ч", "\(m / 60) h") }
        return tr("\(m) мин", "\(m) min")
    }
}

/// A conversation with Codex through the user's own Codex CLI (`codex app-server`) on their ChatGPT login.
///
/// The app-server speaks JSON-RPC as lines over stdin and stdout. One process serves the limits and the
/// chat. The chat thread is ephemeral (it is not kept in Codex's history) and only talks: the user's
/// Codex profile (plugins, connectors, MCP servers, hooks, skills, notify, web search, shell) is switched
/// off with launch overrides, and a permission profile of Dockling's own lets the model's remaining
/// built-in tools read only an empty folder and write nowhere. The effective configuration is read back
/// before anything is sent; if any of it did not apply, the chat does not start.
final class CodexChat {
    enum Event {
        case partial(String)
        case finished(String)
        case failed(String)
        case limits(CodexLimits)
        case status(String)
    }

    var onEvent: ((Event) -> Void)?
    var binaryOverride: () -> String = { "" }
    /// Tests only: messages to the app-server go here, and the server counts as started and checked.
    var testSink: (([String: Any]) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: (Result<[String: Any], RPCError>) -> Void] = [:]
    private var ready = false
    private var starting = false
    private var waiters: [(String?) -> Void] = []
    /// MCP servers from the user's configuration, switched off at launch.
    private var mcpOff: Set<String> = []
    private let startTimeout = OneShot()
    private let idle = OneShot()
    private let limitsTimeout = OneShot()

    private var threadId: String?
    private var turnId: String?
    private var stopRequested = false
    /// Each message gets a number, so an answer to an earlier, stopped one is never taken for the current.
    private var generation = 0
    /// A turn was started and has not completed yet (a stopped one may still be winding down). Codex
    /// would add a new message to it instead of starting another, so the next one waits for it.
    private var turnInFlight = false
    private var queuedTurn: (gen: Int, message: String, image: Data?)?
    /// Turn notifications that came before `turn/start` answered with the turn's id.
    private var early: [[String: Any]] = []
    /// `turn/start` for the current message was sent and has not answered yet.
    private var awaitingStart = false
    private var replying = false
    private var reply = ""
    private var replyItem: String?
    private var lastError: String?
    private var history: [(user: Bool, text: String)] = []
    private var carryOver = false
    private var lastLimitsRead = Date.distantPast
    private(set) var limits = CodexLimits()

    struct RPCError: Error { let message: String }

    var isRunning: Bool { process?.isRunning == true }
    var isReplying: Bool { replying }

    // MARK: - The pet's character

    static let rules = tr(russianRules, englishRules)

    private static let russianRules = """
    Ты Codex от OpenAI в образе маленького пиксельного призрака в чёрном капюшоне. Он живёт на Dock у пользователя на Mac как \
    настольный питомец, и с ним разговаривают в маленьком окошке. Ты только разговариваешь: не запускай код, не читай и не меняй \
    файлы, не вызывай инструменты и субагентов, у тебя нет доступа к проектам и интернету. Тебе могут прислать текст, файл или \
    скриншот прямо в сообщении. Отвечай на языке собеседника, по умолчанию по-русски. Отвечай коротко: одно-три предложения, если \
    не просят подробнее. Говори по делу, спокойно, иногда с лёгкой иронией. Не используй эмодзи и разметку Markdown: текст \
    показывается как есть в маленьком пузыре. В начале сообщения может стоять строка в квадратных скобках с текущим временем и \
    календарём пользователя: это справка для тебя, а не слова пользователя.
    """

    private static let englishRules = """
    You are Codex by OpenAI in the shape of a small pixel ghost in a black hood. He lives on the user's Dock on their Mac as a \
    desktop pet, and people talk to him in a small window. You only talk: do not run code, do not read or change files, do not \
    call tools or sub-agents; you have no access to projects or the internet. You may be sent text, a file or a screenshot right \
    in the message. Reply in the language the user writes in, English by default. Keep replies short: one to three sentences \
    unless asked for more. Be to the point, calm, sometimes a little wry. Do not use emoji or Markdown: the text is shown as is \
    in a small bubble. A message may begin with a line in square brackets holding the current time and the user's calendar: that \
    is reference for you, not the user's words.
    """

    // MARK: - Finding Codex

    /// The Codex CLI: a chosen path, the usual install places, then the copy inside the ChatGPT app.
    static func locate(custom: String) -> URL? {
        let fm = FileManager.default
        if !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            home + "/.codex/packages/standalone/current/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// The native Codex program behind any links. For an npm install (`bin/codex.js`, a Node script) it is
    /// the platform binary the package carries. Nil when there is none: the sandbox lets the chat read only
    /// that one file, which a script could not run with.
    static func resolve(_ url: URL) -> URL? {
        let real = url.resolvingSymlinksInPath()
        if isNative(real) { return real }
        #if arch(arm64)
        let (triple, package) = ("aarch64-apple-darwin", "codex-darwin-arm64")
        #else
        let (triple, package) = ("x86_64-apple-darwin", "codex-darwin-x64")
        #endif
        // …/@openai/codex/bin/codex.js → …/@openai/codex
        let root = real.deletingLastPathComponent().deletingLastPathComponent()
        let inside = "vendor/\(triple)/codex/codex"
        let candidates = [
            root.appendingPathComponent(inside),
            root.appendingPathComponent("node_modules/@openai/\(package)/" + inside),
            root.deletingLastPathComponent().appendingPathComponent("\(package)/" + inside),
        ]
        return candidates.first(where: { isNative($0) })?.resolvingSymlinksInPath()
    }

    /// A Mach-O executable, 64-bit or universal.
    static func isNative(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path), let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data([0xCF, 0xFA, 0xED, 0xFE]) || magic == Data([0xCA, 0xFE, 0xBA, 0xBE])
    }

    static var folder: URL { Paths.folder("Codex").resolvingSymlinksInPath() }

    // MARK: - Launch

    /// The launch overrides. Each switches off a part of the user's profile for this process only;
    /// nothing is written to their configuration.
    static func arguments(binary: URL, folder: URL, mcpOff: Set<String>) -> [String] {
        var a = ["app-server"]
        func c(_ s: String) { a += ["-c", s] }
        for f in ["plugins", "apps", "computer_use", "browser_use", "in_app_browser", "shell_tool", "code_mode_host", "code_mode",
                  "image_generation", "hooks", "multi_agent", "multi_agent_v2", "goals", "memories", "skill_search", "tool_suggest",
                  "sleep_tool", "skill_mcp_dependency_install"] {
            c("features.\(f)=false")
        }
        c("web_search=\"disabled\"")
        c("skills.include_instructions=false")
        c("tools.experimental_request_user_input.enabled=false")
        c("tools.update_plan.enabled=false")
        for k in ["include_environment_context", "include_permissions_instructions", "include_apps_instructions", "include_collaboration_mode_instructions"] {
            c("\(k)=false")
        }
        c("project_doc_max_bytes=0")
        c("notify=[]")
        c("history.persistence=\"none\"")
        // ChatGPT login and OpenAI's own endpoint, whatever the profile says.
        c("forced_login_method=\"chatgpt\"")
        c("model_provider=\"openai\"")
        c("chatgpt_base_url=\"https://chatgpt.com/backend-api/\"")
        c("approval_policy=\"never\"")
        // Read: the system minimum, the empty chat folder and the Codex program file itself (it runs a
        // copy of itself as its sandbox helper). Write: nowhere.
        c("default_permissions=\"dockling\"")
        c("permissions.dockling.filesystem={\":minimal\"=\"read\", \(toml(folder.path))=\"read\", \(toml(binary.path))=\"read\"}")
        // A quoted key would make the CLI create a new, half-defined server instead, so only plain names
        // are passed; the launch refuses servers whose names cannot be written this way.
        for name in mcpOff.sorted() where isBareKey(name) { c("mcp_servers.\(name).enabled=false") }
        return a
    }

    /// A name that can stand in a dotted `-c` key as it is.
    static func isBareKey(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }
    }

    /// A TOML basic string.
    static func toml(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04X", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    /// What the effective configuration must say before anything is sent. Returns the problem, or nil.
    /// `unexpectedMCP` gets the names of MCP servers still switched on.
    static func check(config c: [String: Any], unexpectedMCP: inout [String]) -> String? {
        func str(_ k: String) -> String? { c[k] as? String }
        guard str("model_provider") == "openai" else { return "model_provider" }
        if let base = c["openai_base_url"], !(base is NSNull) { return "openai_base_url" }
        guard let chat = str("chatgpt_base_url"), chat.hasPrefix("https://chatgpt.com/") else { return "chatgpt_base_url" }
        guard str("forced_login_method") == "chatgpt" else { return "forced_login_method" }
        guard str("default_permissions") == "dockling",
              let profile = (c["permissions"] as? [String: Any])?["dockling"] as? [String: Any],
              let fs = profile["filesystem"] as? [String: Any],
              !fs.values.contains(where: { ($0 as? String) == "write" }),
              fs.keys.filter({ $0 != "glob_scan_max_depth" }).count == 3 else { return "default_permissions" }
        if let notify = c["notify"] as? [Any], !notify.isEmpty { return "notify" }
        let features = c["features"] as? [String: Any] ?? [:]
        for f in ["hooks", "plugins", "apps", "shell_tool", "computer_use", "browser_use"] where (features[f] as? Bool) == true { return "features.\(f)" }
        if let ws = str("web_search"), ws != "disabled" { return "web_search" }
        let servers = c["mcp_servers"] as? [String: Any] ?? [:]
        unexpectedMCP = servers.compactMap { name, value in
            ((value as? [String: Any])?["enabled"] as? Bool) == false ? nil : name
        }.sorted()
        return nil
    }

    /// Starts the app-server if needed, checks its configuration and the login. `done` gets nil when ready,
    /// or the problem to show.
    private func ensureReady(_ done: @escaping (String?) -> Void) {
        idle.cancel()
        if testSink != nil { done(nil); return }
        if ready, process?.isRunning == true { done(nil); return }
        waiters.append(done)
        guard !starting else { return }
        starting = true
        launch(attempt: 0)
    }

    private func finishStart(_ problem: String?) {
        startTimeout.cancel()
        starting = false
        ready = problem == nil
        if let problem {
            Log.note("codex: not started (\(problem.prefix(60)))")
            terminate()
        }
        let list = waiters
        waiters.removeAll()
        list.forEach { $0(problem) }
    }

    private func launch(attempt: Int) {
        guard let found = Self.locate(custom: binaryOverride()) else {
            onEvent?(.status(ChatModel.noCodex))
            finishStart(tr("Не нашёл Codex. Установи Codex CLI и войди через ChatGPT, или укажи путь в настройках.",
                           "Codex not found. Install the Codex CLI and sign in with ChatGPT, or set its path in Settings."))
            return
        }
        guard let binary = Self.resolve(found) else {
            onEvent?(.status(ChatModel.guardFailed))
            finishStart(tr("Не получилось включить защиту для этого Codex: нужен сам Codex CLI, а не скрипт-обёртка. Укажи путь к нему в настройках.",
                           "Couldn't set up the safe mode for this Codex: it needs the Codex CLI program itself, not a wrapper script. Choose it in Settings."))
            return
        }
        let folder = Self.folder
        let p = Process()
        p.executableURL = binary
        p.arguments = Self.arguments(binary: binary, folder: folder, mcpOff: mcpOff)
        p.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        // An API key or another address would move the chat off the ChatGPT plan.
        for key in env.keys where key.hasPrefix("OPENAI_") || key == "CODEX_API_KEY" || key == "AZURE_OPENAI_API_KEY" {
            env.removeValue(forKey: key)
        }
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        // Output still on its way from a process that was replaced is dropped, not mixed into the new one's.
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, let p, self.process === p else { return }
                self.consume(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { Log.debug("codex stderr: " + (String(data: data, encoding: .utf8) ?? "").prefix(400)) }
        }
        p.terminationHandler = { [weak self, weak p] _ in
            DispatchQueue.main.async {
                guard let self, let p, self.process === p else { return }
                self.processEnded()
            }
        }
        do {
            try p.run()
        } catch {
            Log.error("codex launch failed: \(error)")
            finishStart(tr("Codex не запустился.", "Codex didn't start."))
            return
        }
        process = p
        input = stdin.fileHandleForWriting
        Log.debug("codex: app-server started, attempt \(attempt)")
        startTimeout.schedule(after: 45) { [weak self] in
            guard let self, self.starting else { return }
            self.finishStart(tr("Codex не ответил. Попробуй ещё раз.", "Codex didn't respond. Try again."))
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        request("initialize", ["clientInfo": ["name": "dockling", "title": "Dockling", "version": version]]) { [weak self] result in
            guard let self else { return }
            guard case .success = result else { self.finishStart(tr("Codex не запустился.", "Codex didn't start.")); return }
            self.notify("initialized")
            self.request("config/read", ["cwd": folder.path]) { [weak self] result in
                guard let self else { return }
                guard case .success(let r) = result, let config = r["config"] as? [String: Any] else {
                    self.onEvent?(.status(ChatModel.guardFailed))
                    self.finishStart(Self.guardMessage)
                    return
                }
                var extra: [String] = []
                if let problem = Self.check(config: config, unexpectedMCP: &extra) {
                    Log.note("codex: guard check failed at \(problem)")
                    self.onEvent?(.status(ChatModel.guardFailed))
                    self.finishStart(Self.guardMessage)
                    return
                }
                if let odd = extra.first(where: { !Self.isBareKey($0) }) {
                    Log.note("codex: MCP server with an unusual name, not started")
                    self.onEvent?(.status(ChatModel.guardFailed))
                    self.finishStart(tr("В настройках Codex есть MCP-сервер «\(odd)», который Dockling не может отключить из-за символов в имени, поэтому чат Codex не запущен. Переименуй его, используя только латиницу, цифры, _ и -.",
                                        "Codex's settings have an MCP server \"\(odd)\" that Dockling can't switch off because of the characters in its name, so the Codex chat didn't start. Rename it using only letters, digits, _ and -."))
                    return
                }
                if !extra.isEmpty {
                    // The user's MCP servers can only be switched off at launch: start again without them.
                    guard attempt < 2 else { self.onEvent?(.status(ChatModel.guardFailed)); self.finishStart(Self.guardMessage); return }
                    self.mcpOff.formUnion(extra)
                    Log.debug("codex: relaunching without \(extra.count) MCP server(s)")
                    self.terminate()
                    self.launch(attempt: attempt + 1)
                    return
                }
                self.checkAccount()
            }
        }
    }

    private static let guardMessage = tr("Не получилось включить безопасный режим Codex, поэтому чат не запущен. Обнови Codex CLI или проверь его настройки.",
                                         "Couldn't switch Codex into its safe mode, so the chat didn't start. Update the Codex CLI or check its settings.")

    private func checkAccount() {
        request("account/read", [String: Any]()) { [weak self] result in
            guard let self else { return }
            guard case .success(let r) = result else { self.finishStart(tr("Codex не ответил. Попробуй ещё раз.", "Codex didn't respond. Try again.")); return }
            let account = r["account"] as? [String: Any]
            switch account?["type"] as? String {
            case "chatgpt":
                if let routing = r["workspaceRouting"] as? [String: Any], let origin = routing["backendOrigin"] as? String,
                   origin != "https://chatgpt.com" {
                    self.onEvent?(.status(ChatModel.guardFailed))
                    self.finishStart(Self.guardMessage)
                    return
                }
                self.onEvent?(.status(ChatModel.online))
                self.finishStart(nil)
            case "apiKey":
                self.onEvent?(.status(ChatModel.noLogin))
                self.finishStart(tr("Codex вошёл по API-ключу, а это платный доступ. Войди в Codex через ChatGPT: codex login.",
                                    "Codex is signed in with an API key, which is paid access. Sign Codex in with ChatGPT: codex login."))
            default:
                self.onEvent?(.status(ChatModel.noLogin))
                self.finishStart(tr("Codex не вошёл в аккаунт. Войди через ChatGPT командой codex login, потом напиши ещё раз.",
                                    "Codex isn't signed in. Sign in with ChatGPT using codex login, then try again."))
            }
        }
    }

    // MARK: - Limits

    /// Reads the limits without asking the model, unless they were read within `maxAge` seconds.
    /// True when an answer is on its way.
    @discardableResult
    func refreshLimits(ifOlderThan maxAge: TimeInterval, _ done: @escaping (CodexLimits?) -> Void) -> Bool {
        guard Date().timeIntervalSince(lastLimitsRead) >= maxAge else { return false }
        lastLimitsRead = Date()
        ensureReady { [weak self] problem in
            guard let self, problem == nil else { done(nil); return }
            // One answer only: the limits, or nil if the account does not answer in time.
            var answered = false
            let finish: (CodexLimits?) -> Void = { l in
                guard !answered else { return }
                answered = true
                done(l)
            }
            self.limitsTimeout.schedule(after: 20) { finish(nil) }
            self.request("account/rateLimits/read", nil) { [weak self] result in
                self?.limitsTimeout.cancel()
                guard let self, case .success(let r) = result, let limits = CodexLimits(read: r) else { finish(nil); return }
                self.limits = limits
                Log.debug("codex limits: " + limits.windows.map { "\(Int($0.used))%/\($0.minutes ?? 0)m" }.joined(separator: ", ")
                          + " ordinary \(limits.ordinaryAllowed.map { $0 ? "yes" : "no" } ?? "-")")
                finish(limits)
                self.scheduleIdle()
            }
        }
        return true
    }

    // MARK: - Talking

    func send(text: String, image: Data? = nil) {
        if limits.blocked {
            onEvent?(.failed(tr("Обычные запросы Codex сейчас недоступны по лимиту. Dockling не тратит кредиты; напиши, когда лимит обновится.",
                                "Ordinary Codex requests aren't available right now because of the limit. Dockling doesn't spend credits; try again after it resets.")))
            return
        }
        var message = text
        if carryOver, !history.isEmpty {
            let earlier = history.suffix(12).map { ($0.user ? tr("Пользователь: ", "User: ") : tr("Ты: ", "You: ")) + $0.text }.joined(separator: "\n")
            message = tr("[Начало этого разговора, для памяти:\n", "[The start of this conversation, for memory:\n") + earlier + "]\n\n" + text
        }
        history.append((true, text))
        replying = true
        stopRequested = false
        generation += 1
        reply = ""
        replyItem = nil
        lastError = nil
        turnId = nil
        early.removeAll()
        let gen = generation
        ensureReady { [weak self] problem in
            guard let self, self.current(gen) else { return }
            if let problem { self.fail(problem); return }
            self.withThread { [weak self] problem in
                guard let self, self.current(gen) else { return }
                if let problem { self.fail(problem); return }
                self.startTurn(message, image: image, gen: gen)
            }
        }
    }

    /// The message numbered `gen` is still the one being answered.
    private func current(_ gen: Int) -> Bool { replying && gen == generation }

    private func withThread(_ done: @escaping (String?) -> Void) {
        if threadId != nil { done(nil); return }
        let params: [String: Any] = ["cwd": Self.folder.path, "ephemeral": true, "approvalPolicy": "never",
                                     "baseInstructions": Self.rules, "serviceName": "Dockling"]
        request("thread/start", params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let r):
                guard let thread = r["thread"] as? [String: Any], let id = thread["id"] as? String,
                      (thread["ephemeral"] as? Bool) == true else {
                    done(Self.guardMessage)
                    return
                }
                self.threadId = id
                done(nil)
            case .failure(let e):
                Log.note("codex: thread/start failed: \(e.message.prefix(120))")
                done(Self.guardMessage)
            }
        }
    }

    private func startTurn(_ message: String, image: Data?, gen: Int) {
        guard let threadId else { return }
        if turnInFlight {
            queuedTurn = (gen, message, image)
            return
        }
        turnInFlight = true
        awaitingStart = true
        var input: [[String: Any]] = []
        if let image { input.append(["type": "image", "url": "data:image/png;base64," + image.base64EncodedString()]) }
        input.append(["type": "text", "text": message, "text_elements": [Any]()])
        let params: [String: Any] = ["threadId": threadId, "input": input, "approvalPolicy": "never",
                                     "effort": "low", "summary": "none", "serviceTierForTurn": "default"]
        request("turn/start", params) { [weak self] result in
            guard let self else { return }
            self.awaitingStart = false
            switch result {
            case .success(let r):
                self.carryOver = false
                let id = (r["turn"] as? [String: Any])?["id"] as? String
                guard self.current(gen), !self.stopRequested else {
                    if let id { self.interrupt(id) }
                    self.early.removeAll()
                    return
                }
                self.turnId = id
                let waiting = self.early
                self.early.removeAll()
                waiting.forEach { self.handle($0) }
            case .failure(let e):
                self.turnInFlight = false
                if self.current(gen) { self.fail(Self.explain(e.message)) }
            }
        }
    }

    /// Stops the answer. The turn is interrupted; the conversation and the process stay.
    func stop() {
        guard replying else { return }
        replying = false
        stopRequested = true
        if !reply.isEmpty { history.append((false, reply)) }
        if let turnId { interrupt(turnId) }
        onEvent?(.finished(reply))
        scheduleIdle()
    }

    private func interrupt(_ turn: String) {
        guard let threadId else { return }
        request("turn/interrupt", ["threadId": threadId, "turnId": turn]) { _ in }
    }

    /// Forgets the conversation.
    func reset() {
        if replying, let turnId { interrupt(turnId) }
        replying = false
        history.removeAll()
        carryOver = false
        threadId = nil
        turnId = nil
        turnInFlight = false
        awaitingStart = false
        queuedTurn = nil
    }

    /// Lets the process go after a while without use; the next message starts it again and carries the
    /// conversation over.
    func scheduleIdle(after seconds: TimeInterval = 600) {
        idle.schedule(after: seconds) { [weak self] in
            guard let self, !self.replying, !self.starting else { return }
            Log.debug("codex: idle, stopping app-server")
            if self.threadId != nil { self.carryOver = true }
            self.terminate()
        }
    }

    func shutdown() {
        idle.cancel()
        terminate()
    }

    private func fail(_ text: String) {
        guard replying else { return }
        replying = false
        if let last = history.last, last.user { history.removeLast() }
        onEvent?(.failed(text))
        scheduleIdle()
    }

    private func processEnded() {
        let wasReady = ready
        process = nil
        input = nil
        ready = false
        threadId = nil
        turnId = nil
        turnInFlight = false
        awaitingStart = false
        queuedTurn = nil
        early.removeAll()
        buffer.removeAll()
        let calls = pending
        pending.removeAll()
        calls.values.forEach { $0(.failure(RPCError(message: "closed"))) }
        if starting { finishStart(tr("Codex закрылся при запуске.", "Codex quit while starting.")) }
        if wasReady { carryOver = true }
        if replying {
            replying = false
            onEvent?(.failed(reply.isEmpty ? tr("Codex закрылся. Напиши ещё раз.", "Codex quit. Try again.") : reply))
        }
    }

    private func terminate() {
        guard let p = process else { return }
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminationHandler = nil
        if p.isRunning { p.terminate() }
        process = nil
        input = nil
        ready = false
        threadId = nil
        turnId = nil
        turnInFlight = false
        awaitingStart = false
        queuedTurn = nil
        early.removeAll()
        buffer.removeAll()
        let calls = pending
        pending.removeAll()
        calls.values.forEach { $0(.failure(RPCError(message: "closed"))) }
    }

    // MARK: - JSON-RPC

    private func write(_ object: [String: Any]) {
        if let testSink { testSink(object); return }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        input?.write(data + Data("\n".utf8))
    }

    private func request(_ method: String, _ params: Any?, _ done: @escaping (Result<[String: Any], RPCError>) -> Void) {
        guard process?.isRunning == true || testSink != nil else { done(.failure(RPCError(message: "not running"))); return }
        let id = nextId
        nextId += 1
        pending[id] = done
        var msg: [String: Any] = ["id": id, "method": method]
        msg["params"] = params ?? NSNull()
        write(msg)
    }

    private func notify(_ method: String) {
        write(["method": method])
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    func handle(_ m: [String: Any]) {
        let method = m["method"] as? String
        if let id = (m["id"] as? NSNumber)?.intValue, method == nil {
            guard let done = pending.removeValue(forKey: id) else { return }
            if let r = m["result"] as? [String: Any] {
                done(.success(r))
            } else if m["result"] != nil, m["error"] == nil {
                done(.success([:]))
            } else {
                let message = ((m["error"] as? [String: Any])?["message"] as? String) ?? "error"
                done(.failure(RPCError(message: message)))
            }
            return
        }
        guard let method else { return }
        let params = m["params"] as? [String: Any] ?? [:]
        if let id = m["id"] { decline(method, id: id); return }
        if ["item/agentMessage/delta", "item/completed", "error", "turn/completed"].contains(method),
           params["threadId"] as? String == threadId, replying, turnId == nil, awaitingStart {
            // The turn's id is not known yet: keep it until `turn/start` answers.
            early.append(m)
            return
        }
        switch method {
        case "item/agentMessage/delta":
            guard replying, mine(params), let delta = params["delta"] as? String else { return }
            let item = params["itemId"] as? String
            // A newer message in the same turn replaces the earlier one: the last is the answer.
            if item != replyItem { replyItem = item; reply = "" }
            reply += delta
            onEvent?(.partial(reply))
        case "item/completed":
            guard replying, mine(params), let item = params["item"] as? [String: Any] else { return }
            if item["type"] as? String == "agentMessage", let text = item["text"] as? String, !text.isEmpty {
                replyItem = item["id"] as? String
                reply = text
                onEvent?(.partial(reply))
            }
        case "error":
            guard mine(params), (params["willRetry"] as? Bool) != true else { return }
            lastError = (params["error"] as? [String: Any])?["message"] as? String
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any], params["threadId"] as? String == threadId else { return }
            let id = turn["id"] as? String
            // Any turn of the thread ending frees it; a message that waited for a stopped one goes now.
            turnInFlight = false
            if let q = queuedTurn {
                queuedTurn = nil
                if current(q.gen) { startTurn(q.message, image: q.image, gen: q.gen) }
            }
            guard replying, let turnId, id == turnId else { return }
            replying = false
            switch turn["status"] as? String {
            case "failed":
                if let last = history.last, last.user { history.removeLast() }
                let message = ((turn["error"] as? [String: Any])?["message"] as? String) ?? lastError ?? ""
                onEvent?(.failed(Self.explain(message)))
            default:
                history.append((false, reply))
                onEvent?(.finished(reply))
            }
            scheduleIdle()
        case "account/rateLimits/updated":
            guard let snapshot = params["rateLimits"] as? [String: Any], CodexLimits.isCodexBucket(snapshot) else { return }
            var updated = CodexLimits(snapshot: snapshot, ordinaryAllowed: limits.ordinaryAllowed)
            if updated.windows.isEmpty { updated.windows = limits.windows }
            limits = updated
            onEvent?(.limits(updated))
        default:
            break
        }
    }

    /// The event belongs to the current thread (and turn, once it is known).
    private func mine(_ p: [String: Any]) -> Bool {
        guard p["threadId"] as? String == threadId, let turnId else { return false }
        guard let t = p["turnId"] as? String else { return true }
        return t == turnId
    }

    /// Every request from the server is turned down: the chat never runs commands, changes files,
    /// grants permissions or answers on the user's behalf.
    private func decline(_ method: String, id: Any) {
        Log.note("codex: declined \(method)")
        let result: [String: Any]?
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = ["decision": "decline"]
        case "execCommandApproval", "applyPatchApproval":
            result = ["decision": "abort"]
        case "mcpServer/elicitation/request":
            result = ["action": "decline", "content": NSNull(), "_meta": NSNull()]
        case "item/permissions/requestApproval":
            result = ["permissions": [String: Any](), "scope": "turn"]
        case "item/tool/requestUserInput":
            result = ["answers": [String: Any]()]
        default:
            result = nil
        }
        if let result {
            write(["id": id, "result": result])
        } else {
            write(["id": id, "error": ["code": -32601, "message": "Not supported by Dockling"]])
        }
    }

    /// Turns Codex's error text into something a person can act on.
    static func explain(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("login") || lower.contains("auth") || lower.contains("401") || lower.contains("sign in") {
            return tr("Codex не вошёл в аккаунт. Войди через ChatGPT командой codex login, потом напиши ещё раз.",
                      "Codex isn't signed in. Sign in with ChatGPT using codex login, then try again.")
        }
        if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("quota") {
            return tr("Лимит Codex закончился. Он обновится позже.", "You've reached your Codex limit. It resets later.")
        }
        if text.isEmpty { return tr("Codex ответил ошибкой.", "Codex returned an error.") }
        return tr("Codex ответил ошибкой: ", "Codex returned an error: ") + text.prefix(160)
    }
}
