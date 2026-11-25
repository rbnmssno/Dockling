import Foundation

/// Asks Claude Code for the plan's limits without waiting for a chat message.
///
/// Claude Code reports the limits only together with an answer, and keeps no live copy an app could
/// read: its own cache in `~/.claude.json` can be hours behind. So the smallest possible request goes
/// through the same Claude Code as the chat: the cheapest model, a one-word answer, no tools. It takes
/// about a second and a thousand tokens, and the process is ended as soon as the limits have arrived.
final class LimitsProbe {
    var binaryOverride: () -> String = { "" }

    private var process: Process?
    private var done: ((PlanLimits?) -> Void)?
    private var buffer = Data()
    private var lastRun = Date.distantPast
    private let giveUp = OneShot()

    /// Asks unless an answer is on its way or the last one is younger than `maxAge` seconds; true when
    /// an answer is on its way. `done` then runs once on the main queue, with the limits or with nil.
    @discardableResult
    func run(ifOlderThan maxAge: TimeInterval, _ done: @escaping (PlanLimits?) -> Void) -> Bool {
        if process != nil { return true }
        guard Date().timeIntervalSince(lastRun) >= maxAge, let binary = ClaudeChat.locate(custom: binaryOverride()) else { return false }
        lastRun = Date()
        let p = ClaudeChat.command(binary, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                            "--tools", "", "--safe-mode", "--no-session-persistence", "--model", "haiku",
                                            "--system-prompt", "Reply with the single word: ok"])
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.finish(nil) } }
        do { try p.run() } catch { return false }
        process = p
        self.done = done
        buffer.removeAll()
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": "."]]
        if let data = try? JSONSerialization.data(withJSONObject: line) { stdin.fileHandleForWriting.write(data + Data("\n".utf8)) }
        giveUp.schedule(after: 25) { [weak self] in self?.finish(nil) }
        Log.debug("limits: asking Claude Code")
        return true
    }

    private func consume(_ data: Data) {
        guard process != nil else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let limits = PlanLimits(event: event) else { continue }
            Log.debug("limits: session \(limits.session.map { String(Int($0)) } ?? "-")%, week \(limits.week.map { String(Int($0)) } ?? "-")%")
            finish(limits)
            return
        }
    }

    private func finish(_ limits: PlanLimits?) {
        giveUp.cancel()
        guard let p = process else { return }
        process = nil
        let done = self.done
        self.done = nil
        defer { done?(limits) }
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminationHandler = nil
        if p.isRunning { p.terminate() }
    }
}
