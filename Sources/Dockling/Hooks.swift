import AppKit
import Darwin

/// Adds and removes the app's hooks in ~/.claude/settings.json. Other hooks in the file stay as they
/// are, and the file is backed up before the first change.
final class HookInstaller: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var problem: String?

    static let events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]
    private let settingsURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
    static var scriptURL: URL { Paths.support.appendingPathComponent("claude-hook.sh") }
    static var socketPath: String { Paths.support.appendingPathComponent("hook.sock").path }

    init() { refresh() }

    func refresh() {
        installed = (try? String(contentsOf: settingsURL, encoding: .utf8))?.contains(Self.scriptURL.path) ?? false
    }

    private func command(for event: String) -> String { "\"\(Self.scriptURL.path)\" \(event)" }

    func setInstalled(_ on: Bool) {
        problem = nil
        do {
            try writeScript()
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: settingsURL) {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    problem = "~/.claude/settings.json не читается как JSON, поэтому я его не трогаю."
                    return
                }
                root = parsed
                let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.dockling-backup")
                if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
            }
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in Self.events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                // Drop our earlier entries, keep everyone else's.
                groups = groups.compactMap { group in
                    var g = group
                    let inner = (g["hooks"] as? [[String: Any]] ?? []).filter { ($0["command"] as? String)?.contains(Self.scriptURL.path) != true }
                    if inner.isEmpty { return nil }
                    g["hooks"] = inner
                    return g
                }
                if on {
                    var hook: [String: Any] = ["type": "command", "command": command(for: event)]
                    if event == "PermissionRequest" { hook["timeout"] = 600 }
                    groups.append(["hooks": [hook]])
                }
                hooks[event] = groups.isEmpty ? nil : groups
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: settingsURL, options: .atomic)
        } catch {
            problem = "Не получилось изменить ~/.claude/settings.json."
            Log.error("hook install failed: \(error)")
        }
        refresh()
    }

    /// The hook: hands the event to the app over a local socket. Permission requests wait for the
    /// answer. When the app is not running the hook says nothing and Claude Code asks as usual.
    func writeScript() throws {
        let script = """
        #!/bin/sh
        # Dockling: passes Claude Code events to the pet. Removing this file or the app changes nothing in Claude Code.
        e=$1
        d=$(cat | tr -d '\\n')
        s="$HOME/Library/Application Support/Dockling/hook.sock"
        [ -S "$s" ] || exit 0
        m=$(printf '{"event":"%s","raw":%s}' "$e" "$d")
        if [ "$e" = "PermissionRequest" ]; then
          printf '%s\\n' "$m" | /usr/bin/nc -U -w 600 "$s" 2>/dev/null
        else
          printf '%s\\n' "$m" | /usr/bin/nc -U -w 1 "$s" >/dev/null 2>&1
        fi
        exit 0

        """
        try script.write(to: Self.scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.scriptURL.path)
    }
}

/// Listens on a Unix socket for the hook's messages.
final class HookServer {
    /// Called on the main queue with the event name, its JSON and, for questions, a way to answer.
    var onEvent: ((String, [String: Any], ((Data?) -> Void)?) -> Void)?
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dockling.hooks")

    func start() {
        let path = HookInstaller.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 16) == 0 else { close(fd); Log.error("hook socket failed"); return }
        chmod(path, 0o600)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    private func accept() {
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        // The hook sends one line.
        while !data.contains(0x0A) {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.count > 4_000_000 { break }
        }
        guard let line = data.split(separator: 0x0A).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let event = obj["event"] as? String else { close(client); return }
        let raw = obj["raw"] as? [String: Any] ?? [:]
        if event == "PermissionRequest" {
            var answered = false
            let reply: (Data?) -> Void = { [queue] answer in
                queue.async {
                    guard !answered else { return }
                    answered = true
                    if let answer { _ = answer.withUnsafeBytes { write(client, $0.baseAddress, answer.count) } }
                    close(client)
                }
            }
            DispatchQueue.main.async { self.onEvent?(event, raw, reply) }
        } else {
            close(client)
            DispatchQueue.main.async { self.onEvent?(event, raw, nil) }
        }
    }

    deinit {
        source?.cancel()
        if listenFD >= 0 { close(listenFD) }
        unlink(HookInstaller.socketPath)
    }
}

/// Turns Claude Code's hook events into the character's state and cards.
final class ClaudeCodeWatcher {
    private struct Session {
        var project: String
        var cwd: String
        var state: State = .idle
        var since = Date()
        enum State { case idle, work, wait, permission }
    }

    private weak var brain: PetBrain?
    private var sessions: [String: Session] = [:]
    private var pending: [(id: String, tool: String, detail: String, reply: (Data?) -> Void)] = []

    init(brain: PetBrain) {
        self.brain = brain
    }

    func handle(_ event: String, _ raw: [String: Any], reply: ((Data?) -> Void)?) {
        let id = raw["session_id"] as? String ?? "?"
        let cwd = raw["cwd"] as? String ?? ""
        let project = (cwd as NSString).lastPathComponent.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
        Log.note("hook \(event) session \(id.prefix(8)) project \(project)")
        if sessions[id] == nil, event != "SessionEnd" { sessions[id] = Session(project: project, cwd: cwd) }

        switch event {
        case "UserPromptSubmit":
            sessions[id]?.state = .work
            sessions[id]?.since = Date()
        case "PermissionRequest":
            guard let reply else { return }
            sessions[id]?.state = .permission
            let tool = raw["tool_name"] as? String ?? "?"
            let input = raw["tool_input"] as? [String: Any] ?? [:]
            let detail = (input["command"] as? String) ?? (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
                ?? (input["url"] as? String) ?? tool
            pending.append((id, tool, detail, reply))
        case "Notification":
            if (raw["notification_type"] as? String) == "idle_prompt" { sessions[id]?.state = .wait }
        case "Stop":
            let s = sessions[id]
            sessions[id]?.state = .idle
            finished(session: s, message: raw["last_assistant_message"] as? String)
        case "StopFailure":
            let s = sessions[id]
            sessions[id]?.state = .idle
            brain?.upset()
            brain?.notify(Card(icon: .fail, color: Card.red, text: "Claude остановился с ошибкой", meta: s?.project,
                               actions: [CardAction(title: "Открыть", primary: true) { [weak self] in self?.openProject(s?.cwd) }],
                               duration: 6.4, tag: "cc-fail"))
        case "SessionEnd":
            sessions[id] = nil
            pending.removeAll { item in
                guard item.id == id else { return false }
                item.reply(nil)
                return true
            }
        default:
            break
        }
        refresh()
    }

    /// Every finished turn gets the card. When the pet did not see the turn start (it was started
    /// later, or restarted), the card has no duration.
    private func finished(session: Session?, message: String?) {
        guard let session else { return }
        let sawStart = session.state != .idle
        let meta = sawStart ? "\(session.project) · \(max(1, Int(Date().timeIntervalSince(session.since) / 60))) мин" : session.project
        brain?.react("done")
        brain?.notify(Card(icon: .done, color: Card.green, text: Self.summary(message), meta: meta,
                           actions: [CardAction(title: "Открыть", primary: true) { [weak self] in self?.openProject(session.cwd) }],
                           duration: 8, tag: "cc-done"))
    }

    /// The first sentence of Claude's last message, short enough for a card.
    static func summary(_ text: String?) -> String {
        guard var t = text?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), !t.isEmpty else {
            return "Claude закончил задачу"
        }
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        if let end = t.firstIndex(where: { ".!?".contains($0) }) { t = String(t[...end]) }
        return t.count > 90 ? String(t.prefix(88)) + "…" : t
    }

    private func refresh() {
        guard let brain else { return }
        let states = sessions.values.map(\.state)
        brain.claude = states.contains(.permission) || states.contains(.wait) ? .wait : states.contains(.work) ? .work : .none
        let active = sessions.values.filter { $0.state != .idle }.count
        brain.setBadge(active >= 2 ? active : 0)

        if let first = pending.first {
            let session = sessions[first.id]
            let more = pending.count - 1
            let answer: (String?) -> Void = { [weak self] behavior in
                guard let self, let i = self.pending.firstIndex(where: { $0.id == first.id && $0.detail == first.detail }) else { return }
                let item = self.pending.remove(at: i)
                if let behavior {
                    let json: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": behavior]]]
                    item.reply(try? JSONSerialization.data(withJSONObject: json))
                    if behavior == "allow" { self.brain?.react("happy", duration: 1.7) }
                } else {
                    item.reply(nil)
                }
                if !self.pending.contains(where: { $0.id == item.id }) { self.sessions[item.id]?.state = .work }
                self.refresh()
            }
            brain.cards.setStanding(Card(icon: .lock, color: Card.amber, text: first.detail, meta: "\(first.tool) · \(session?.project ?? "Claude Code")" + (more > 0 ? " · ещё \(more)" : ""),
                                         mono: true,
                                         actions: [CardAction(title: "Разрешить", primary: true) { answer("allow") },
                                                   CardAction(title: "Отклонить") { answer("deny") },
                                                   CardAction(title: "В VS Code") { answer(nil) }],
                                         sticky: true, hold: true, tag: "cc-question"))
        } else if let waiting = sessions.values.first(where: { $0.state == .wait }) {
            brain.cards.setStanding(Card(icon: .code, color: Card.amber, text: "Claude ждёт ответа", meta: waiting.project,
                                         actions: [CardAction(title: "Открыть", primary: true) { [weak self] in self?.openProject(waiting.cwd) }],
                                         sticky: true, hold: true, tag: "cc-question"))
        } else {
            brain.cards.setStanding(nil)
        }
    }

    private func openProject(_ cwd: String?) {
        guard let cwd, !cwd.isEmpty else { return }
        let url = URL(fileURLWithPath: cwd)
        if let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            NSWorkspace.shared.open([url], withApplicationAt: vscode, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
