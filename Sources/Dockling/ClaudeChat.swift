import Foundation

/// Limits of the Claude plan, as Claude Code reports them with each answer.
struct PlanLimits: Equatable {
    var session: Double?
    var week: Double?
    var sessionReset: Date?
    var weekReset: Date?

    init(session: Double? = nil, week: Double? = nil, sessionReset: Date? = nil, weekReset: Date? = nil) {
        self.session = session
        self.week = week
        self.sessionReset = sessionReset
        self.weekReset = weekReset
    }

    /// From a `rate_limit_event` line of Claude Code's output; nil for any other line.
    init?(event e: [String: Any]) {
        guard e["type"] as? String == "rate_limit_event", let info = e["rate_limit_info"] as? [String: Any],
              let windows = info["unifiedWindows"] as? [String: Any] else { return nil }
        if let s = windows["five_hour"] as? [String: Any] {
            session = (s["utilization"] as? Double).map { $0 * 100 }
            sessionReset = (s["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        }
        if let w = windows["seven_day"] as? [String: Any] {
            week = (w["utilization"] as? Double).map { $0 * 100 }
            weekReset = (w["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// Without the windows that have reset since: their numbers are no longer true.
    var current: PlanLimits {
        var l = self
        if let r = sessionReset, r < Date() { l.session = nil; l.sessionReset = nil }
        if let r = weekReset, r < Date() { l.week = nil; l.weekReset = nil }
        return l
    }

    // Kept between launches, so the chat has numbers the moment it opens.
    var stored: [String: Double] {
        var d: [String: Double] = [:]
        d["session"] = session
        d["week"] = week
        d["sessionReset"] = sessionReset?.timeIntervalSince1970
        d["weekReset"] = weekReset?.timeIntervalSince1970
        return d
    }

    init(stored d: [String: Double]) {
        session = d["session"]
        week = d["week"]
        sessionReset = d["sessionReset"].map { Date(timeIntervalSince1970: $0) }
        weekReset = d["weekReset"].map { Date(timeIntervalSince1970: $0) }
    }
}

/// A conversation with Claude through the user's own Claude Code, on their subscription login.
/// One `claude -p` process stays open for the whole conversation; messages go in and the answer
/// streams out as JSON lines. It has no tools: it only talks.
final class ClaudeChat {
    enum Event {
        case partial(String)
        case finished(String)
        case failed(String)
        case limits(PlanLimits)
    }

    var onEvent: ((Event) -> Void)?
    var binaryOverride: () -> String = { "" }

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var reply = ""
    private var replying = false
    /// The conversation so far, to carry it over when the process has to be restarted.
    private var history: [(user: Bool, text: String)] = []
    private var carryOver = false

    /// The system prompt, in the interface language. The pet answers in whatever language the user writes in.
    static let rules = tr(russianRules, englishRules)

    private static let russianRules = """
    Ты Claude в образе маленького пиксельного призрака в чёрном капюшоне. Он живёт на Dock у пользователя на Mac как настольный питомец, \
    и с ним разговаривают в маленьком окошке. Ты только разговариваешь: у тебя нет доступа к файлам, терминалу и интернету, \
    но тебе могут прислать текст, файл или скриншот прямо в сообщении. Отвечай на языке собеседника, по умолчанию по-русски. \
    Отвечай коротко: одно-три предложения, если не просят подробнее. Говори по делу, спокойно, иногда с лёгкой иронией. \
    Не используй эмодзи и разметку Markdown: текст показывается как есть в маленьком пузыре. \
    В начале сообщения может стоять строка в квадратных скобках с текущим временем и календарём пользователя: это справка для тебя, \
    а не слова пользователя.
    """

    private static let englishRules = """
    You are Claude in the shape of a small pixel ghost in a black hood. He lives on the user's Dock on their Mac as a desktop pet, \
    and people talk to him in a small window. You only talk: you have no access to files, the terminal or the internet, \
    but you may be sent text, a file or a screenshot right in the message. Reply in the language the user writes in, English by default. \
    Keep replies short: one to three sentences unless asked for more. Be to the point, calm, sometimes a little wry. \
    Do not use emoji or Markdown: the text is shown as is in a small bubble. \
    A message may begin with a line in square brackets holding the current time and the user's calendar: that is reference for you, \
    not the user's words.
    """

    var isRunning: Bool { process?.isRunning == true }

    // MARK: - Finding Claude Code

    /// Claude Code on PATH-like places first, then the copy the VS Code extension carries.
    static func locate(custom: String) -> URL? {
        let fm = FileManager.default
        if !custom.isEmpty, fm.isExecutableFile(atPath: (custom as NSString).expandingTildeInPath) {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.local/bin/claude", home + "/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        if let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        for dir in [home + "/.vscode/extensions", home + "/.cursor/extensions", home + "/.windsurf/extensions"] {
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            let newest = names.filter { $0.hasPrefix("anthropic.claude-code-") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for name in newest {
                let path = dir + "/" + name + "/resources/native-binary/claude"
                if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    // MARK: - Talking

    /// Sends one message. `parts` are content blocks: text and, for screenshots, images.
    func send(text: String, image: Data? = nil) {
        guard ensureProcess() else { return }
        var message = text
        if carryOver, !history.isEmpty {
            let earlier = history.suffix(12).map { ($0.user ? tr("Пользователь: ", "User: ") : tr("Ты: ", "You: ")) + $0.text }.joined(separator: "\n")
            message = tr("[Начало этого разговора, для памяти:\n", "[The start of this conversation, for memory:\n") + earlier + "]\n\n" + text
            carryOver = false
        }
        var content: [[String: Any]] = []
        if let image {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image.base64EncodedString()]])
        }
        content.append(["type": "text", "text": message])
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard let data = try? JSONSerialization.data(withJSONObject: line) else { return }
        history.append((true, text))
        reply = ""
        replying = true
        input?.write(data + Data("\n".utf8))
    }

    /// Stops the answer. The command-line mode has no "stop" message, so the process ends; the next
    /// message starts a new one and carries the conversation over.
    func stop() {
        guard replying else { return }
        replying = false
        if !reply.isEmpty { history.append((false, reply)) }
        let partial = reply
        terminate()
        carryOver = true
        onEvent?(.finished(partial))
    }

    /// Forgets the conversation.
    func reset() {
        replying = false
        history.removeAll()
        carryOver = false
        terminate()
    }

    private func terminate() {
        guard let process else { return }
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
        input = nil
        buffer.removeAll()
    }

    // MARK: - The process

    /// Claude Code, set up to run on the subscription login in the chat's own empty folder.
    static func command(_ binary: URL, _ arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = binary
        p.arguments = arguments
        p.currentDirectoryURL = Paths.folder("Chat")
        var env = ProcessInfo.processInfo.environment
        // Any of these would quietly switch Claude Code from the subscription to paid API access.
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            env.removeValue(forKey: key)
        }
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        p.environment = env
        return p
    }

    private func ensureProcess() -> Bool {
        if process?.isRunning == true { return true }
        guard let binary = Self.locate(custom: binaryOverride()) else {
            onEvent?(.failed(tr("Не нашёл Claude Code. Установи его или укажи путь в настройках.", "Claude Code not found. Install it or set its path in Settings.")))
            return false
        }
        let p = Self.command(binary, ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                      "--include-partial-messages", "--verbose", "--tools", "", "--safe-mode",
                                      "--no-session-persistence", "--system-prompt", Self.rules])
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { Log.debug("claude stderr: " + (String(data: data, encoding: .utf8) ?? "")) }
        }
        p.terminationHandler = { [weak self, weak p] _ in
            DispatchQueue.main.async {
                guard let self, let p, self.process === p else { return }
                self.process = nil
                self.input = nil
                self.carryOver = true
                if self.replying {
                    self.replying = false
                    self.onEvent?(.failed(self.reply.isEmpty ? tr("Claude Code закрылся. Напиши ещё раз.", "Claude Code quit. Try again.") : self.reply))
                }
            }
        }
        do {
            try p.run()
        } catch {
            onEvent?(.failed(tr("Claude Code не запустился.", "Claude Code didn't start.")))
            Log.error("claude launch failed: \(error)")
            return false
        }
        process = p
        input = stdin.fileHandleForWriting
        return true
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "stream_event":
            guard replying, let ev = e["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let piece = delta["text"] as? String else { return }
            reply += piece
            onEvent?(.partial(reply))
        case "rate_limit_event":
            if let limits = PlanLimits(event: e) { onEvent?(.limits(limits)) }
        case "result":
            guard replying else { return }
            replying = false
            let text = (e["result"] as? String) ?? reply
            if (e["is_error"] as? Bool) == true {
                onEvent?(.failed(Self.explain(text)))
            } else {
                history.append((false, text))
                onEvent?(.finished(text))
            }
        default:
            break
        }
    }

    /// Turns Claude Code's error text into something a person can act on.
    private static func explain(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("login") || lower.contains("auth") || lower.contains("api key") {
            return tr("Claude Code не вошёл в аккаунт. Открой Claude Code и войди в свою подписку, потом напиши ещё раз.",
                      "Claude Code isn't signed in. Open Claude Code, sign in with your subscription, then try again.")
        }
        if lower.contains("limit") { return tr("Лимит Claude закончился. Он обновится позже.", "You've reached your Claude limit. It resets later.") }
        return tr("Claude Code ответил ошибкой: ", "Claude Code returned an error: ") + text.prefix(160)
    }
}
