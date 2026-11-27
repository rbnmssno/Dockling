import XCTest
@testable import Dockling

final class CodexLimitsTests: XCTestCase {
    /// The shape of a real `account/rateLimits/read` answer: one weekly window, no second one.
    private let weekOnly: [String: Any] = [
        "ordinaryUsageAllowed": true,
        "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 2, "windowDurationMins": 10080, "resetsAt": 4_102_444_800], "secondary": NSNull()],
        "rateLimitsByLimitId": ["codex": ["limitId": "codex", "primary": ["usedPercent": 2, "windowDurationMins": 10080, "resetsAt": 4_102_444_800], "secondary": NSNull()]],
    ]

    func testOneWeeklyWindow() throws {
        let l = try XCTUnwrap(CodexLimits(read: weekOnly))
        XCTAssertEqual(l.windows.count, 1)
        XCTAssertEqual(l.windows[0].used, 2)
        XCTAssertEqual(l.windows[0].minutes, 10080)
        XCTAssertEqual(l.windows[0].reset, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertEqual(l.ordinaryAllowed, true)
        XCTAssertFalse(l.blocked)
        XCTAssertEqual(CodexLimits.label(minutes: 10080), tr("Неделя", "Week"))
    }

    func testTwoWindowsKeepTheirRealLengths() throws {
        let r: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 40.5, "windowDurationMins": 300, "resetsAt": 4_102_444_800],
                                               "secondary": ["usedPercent": 12, "windowDurationMins": 10080, "resetsAt": 4_102_444_900]]]
        let l = try XCTUnwrap(CodexLimits(read: r))
        XCTAssertEqual(l.windows.map(\.minutes), [300, 10080])
        XCTAssertNil(l.ordinaryAllowed)
        XCTAssertFalse(l.blocked, "no data about permission must not block the chat")
        XCTAssertEqual(CodexLimits.label(minutes: 300), tr("5 ч", "5 h"))
        XCTAssertEqual(CodexLimits.label(minutes: 4320), tr("3 дн", "3 d"))
        XCTAssertEqual(CodexLimits.label(minutes: 90), tr("90 мин", "90 min"))
        XCTAssertEqual(CodexLimits.label(minutes: nil), tr("Лимит", "Limit"))
    }

    func testNoWindows() throws {
        let l = try XCTUnwrap(CodexLimits(read: ["rateLimits": ["primary": NSNull(), "secondary": NSNull()]]))
        XCTAssertTrue(l.windows.isEmpty)
        let model = ChatModel()
        model.provider = .codex
        model.codexLimits = l
        XCTAssertEqual(model.limitRows.count, 1)
        XCTAssertNil(model.limitRows[0].value)
    }

    func testOnlyAnExplicitRefusalBlocks() throws {
        var r = weekOnly
        r["ordinaryUsageAllowed"] = false
        XCTAssertTrue(try XCTUnwrap(CodexLimits(read: r)).blocked)
        r["ordinaryUsageAllowed"] = NSNull()
        XCTAssertFalse(try XCTUnwrap(CodexLimits(read: r)).blocked)
        // Another bucket at 100% does not block, and is not the one shown.
        r["rateLimitsByLimitId"] = ["codex": ["limitId": "codex", "primary": ["usedPercent": 50, "windowDurationMins": 10080]],
                                    "other": ["limitId": "other", "primary": ["usedPercent": 100, "windowDurationMins": 300]]]
        let l = try XCTUnwrap(CodexLimits(read: r))
        XCTAssertFalse(l.blocked)
        XCTAssertEqual(l.windows.map(\.used), [50])
        XCTAssertFalse(CodexLimits.isCodexBucket(["limitId": "other"]))
        XCTAssertTrue(CodexLimits.isCodexBucket(["limitId": NSNull()]))
    }

    func testStoredRoundTripAndExpiry() {
        let future = Date(timeIntervalSince1970: 4_102_444_800)
        let l = CodexLimits(windows: [.init(used: 30, minutes: 300, reset: future), .init(used: 5, minutes: 10080, reset: Date(timeIntervalSince1970: 1_000_000_000))],
                            ordinaryAllowed: false)
        let back = CodexLimits(stored: l.stored)
        XCTAssertEqual(back.windows, l.windows)
        XCTAssertNil(back.ordinaryAllowed, "the permission is never taken from the cache")
        XCTAssertEqual(back.current.windows.map(\.minutes), [300])
    }

    func testClaudeLimitsUnchanged() {
        let e: [String: Any] = ["type": "rate_limit_event", "rate_limit_info": ["unifiedWindows": [
            "five_hour": ["utilization": 0.25, "resetsAt": 4_102_444_800.0], "seven_day": ["utilization": 0.5]]]]
        let l = PlanLimits(event: e)
        XCTAssertEqual(l?.session, 25)
        XCTAssertEqual(l?.week, 50)
    }

    func testDurationText() {
        XCTAssertEqual(durationText(minutes: 133), tr("2 ч 13 мин", "2 h 13 min"))
        XCTAssertEqual(durationText(minutes: 6 * 1440 + 3 * 60 + 5), tr("6 дн 3 ч", "6 d 3 h"))
        XCTAssertEqual(durationText(minutes: 2 * 1440), tr("2 дн", "2 d"))
    }
}

final class CodexGuardTests: XCTestCase {
    private func goodConfig(fs extra: [String: Any] = [:]) -> [String: Any] {
        var fs: [String: Any] = [":minimal": "read", "/chat": "read", "/codex/bin/codex": "read", "glob_scan_max_depth": NSNull()]
        fs.merge(extra) { $1 }
        return ["model_provider": "openai", "openai_base_url": NSNull(), "chatgpt_base_url": "https://chatgpt.com/backend-api/",
                "forced_login_method": "chatgpt", "default_permissions": "dockling",
                "permissions": ["dockling": ["filesystem": fs]], "notify": [Any](), "web_search": "disabled",
                "features": ["hooks": false, "plugins": false, "apps": false, "shell_tool": false, "computer_use": false, "browser_use": false],
                "mcp_servers": ["node_repl": ["enabled": false]]]
    }

    private func problem(_ c: [String: Any]) -> (String?, [String]) {
        var mcp: [String] = []
        let p = CodexChat.check(config: c, unexpectedMCP: &mcp)
        return (p, mcp)
    }

    func testGoodConfigPasses() {
        let (p, mcp) = problem(goodConfig())
        XCTAssertNil(p)
        XCTAssertEqual(mcp, [])
    }

    func testEndpointCannotBeRedirected() {
        var c = goodConfig(); c["openai_base_url"] = "https://example.invalid/v1"
        XCTAssertEqual(problem(c).0, "openai_base_url")
        c = goodConfig(); c["chatgpt_base_url"] = "https://example.invalid/"
        XCTAssertEqual(problem(c).0, "chatgpt_base_url")
        c = goodConfig(); c["model_provider"] = "custom"
        XCTAssertEqual(problem(c).0, "model_provider")
        c = goodConfig(); c["forced_login_method"] = "api"
        XCTAssertEqual(problem(c).0, "forced_login_method")
    }

    func testProfileMustBeExactlyOurs() {
        var c = goodConfig(); c["default_permissions"] = ":workspace"
        XCTAssertEqual(problem(c).0, "default_permissions")
        XCTAssertEqual(problem(goodConfig(fs: ["/Users/someone": "read"])).0, "default_permissions", "an extra path merged in from the user's profile")
        XCTAssertEqual(problem(goodConfig(fs: ["/chat": "write"])).0, "default_permissions")
    }

    func testCommandsAndToolsFromTheProfileStayOff() {
        var c = goodConfig(); c["notify"] = ["/some/app", "turn-ended"]
        XCTAssertEqual(problem(c).0, "notify")
        c = goodConfig(); c["features"] = ["hooks": true]
        XCTAssertEqual(problem(c).0, "features.hooks")
        c = goodConfig(); c["web_search"] = "live"
        XCTAssertEqual(problem(c).0, "web_search")
        c = goodConfig(); c["mcp_servers"] = ["node_repl": ["enabled": false], "other": ["command": "x"], "third": ["enabled": true]]
        let (p, mcp) = problem(c)
        XCTAssertNil(p)
        XCTAssertEqual(mcp, ["other", "third"])
    }

    func testLaunchArguments() {
        let a = CodexChat.arguments(binary: URL(fileURLWithPath: "/x/bin/codex"), folder: URL(fileURLWithPath: "/chat \"q\""), mcpOff: ["node_repl", "we.ird"])
        XCTAssertFalse(a.contains { $0.contains("we.ird") }, "a name that needs quoting is never passed")
        XCTAssertTrue(CodexChat.isBareKey("node_repl"))
        XCTAssertFalse(CodexChat.isBareKey("we.ird"))
        XCTAssertEqual(a.first, "app-server")
        let overrides = Set(stride(from: 2, to: a.count, by: 2).map { a[$0] })
        for o in ["features.shell_tool=false", "features.plugins=false", "features.hooks=false", "features.apps=false", "features.computer_use=false",
                  "web_search=\"disabled\"", "notify=[]", "forced_login_method=\"chatgpt\"", "model_provider=\"openai\"",
                  "default_permissions=\"dockling\"", "approval_policy=\"never\"", "skills.include_instructions=false",
                  "mcp_servers.node_repl.enabled=false"] {
            XCTAssertTrue(overrides.contains(o), o)
        }
        XCTAssertTrue(overrides.contains("permissions.dockling.filesystem={\":minimal\"=\"read\", \"/chat \\\"q\\\"\"=\"read\", \"/x/bin/codex\"=\"read\"}"))
        XCTAssertEqual(CodexChat.toml("a\\b\n"), "\"a\\\\b\\n\"")
    }

    func testResolveFindsTheNativeBinaryOfAnNpmInstall() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dockling-npm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        #if arch(arm64)
        let (triple, package) = ("aarch64-apple-darwin", "codex-darwin-arm64")
        #else
        let (triple, package) = ("x86_64-apple-darwin", "codex-darwin-x64")
        #endif
        let pkg = root.appendingPathComponent("lib/node_modules/@openai/codex")
        let script = pkg.appendingPathComponent("bin/codex.js")
        try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/usr/bin/env node\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let link = root.appendingPathComponent("bin/codex")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: script)
        XCTAssertNil(CodexChat.resolve(link), "a script with no native binary is refused")

        // The platform package hoisted next to @openai/codex.
        let native = root.appendingPathComponent("lib/node_modules/@openai/\(package)/vendor/\(triple)/codex/codex")
        try fm.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: native)
        XCTAssertEqual(CodexChat.resolve(link)?.path, native.resolvingSymlinksInPath().path)

        // A native binary is used as it is, and only that file is granted.
        let plain = URL(fileURLWithPath: "/bin/ls")
        XCTAssertEqual(CodexChat.resolve(plain)?.path, "/bin/ls")
        XCTAssertTrue(CodexChat.arguments(binary: plain, folder: URL(fileURLWithPath: "/c"), mcpOff: []).contains { $0.hasSuffix("\"/bin/ls\"=\"read\"}") })
    }
}

/// The chat against a scripted app-server: what is sent, and which answers count.
final class CodexConversationTests: XCTestCase {
    private var chat: CodexChat!
    private var sent: [[String: Any]] = []
    private var events: [String] = []

    override func setUp() {
        chat = CodexChat()
        sent = []
        events = []
        chat.testSink = { [unowned self] in self.sent.append($0) }
        chat.onEvent = { [unowned self] e in
            switch e {
            case .partial(let t): self.events.append("partial:" + t)
            case .finished(let t): self.events.append("finished:" + t)
            case .failed(let t): self.events.append("failed:" + t)
            case .limits(let l): self.events.append("limits:" + l.windows.map { "\(Int($0.used))" }.joined(separator: ","))
            case .status(let s): self.events.append("status:" + s)
            }
        }
    }

    private func last(_ method: String) -> [String: Any]? { sent.last { $0["method"] as? String == method } }
    private func all(_ method: String) -> [[String: Any]] { sent.filter { $0["method"] as? String == method } }
    private func id(_ m: [String: Any]?) -> Int { (m?["id"] as? Int) ?? -1 }
    private func answer(_ m: [String: Any]?, _ result: [String: Any]) { chat.handle(["id": id(m), "result": result]) }
    private func text(of turnStart: [String: Any]) -> String {
        let input = (turnStart["params"] as? [String: Any])?["input"] as? [[String: Any]] ?? []
        return input.compactMap { $0["text"] as? String }.joined()
    }
    private func note(_ method: String, _ params: [String: Any]) { chat.handle(["method": method, "params": params]) }

    private func startThread() {
        let start = last("thread/start")
        XCTAssertEqual((start?["params"] as? [String: Any])?["ephemeral"] as? Bool, true)
        answer(start, ["thread": ["id": "T", "ephemeral": true]])
    }

    func testOrdinaryReply() {
        chat.send(text: "hello")
        startThread()
        let turn = last("turn/start")!
        XCTAssertEqual(text(of: turn), "hello")
        answer(turn, ["turn": ["id": "A"]])
        note("item/agentMessage/delta", ["threadId": "T", "turnId": "A", "itemId": "i1", "delta": "Hi"])
        note("item/agentMessage/delta", ["threadId": "T", "turnId": "A", "itemId": "i1", "delta": " there"])
        note("turn/completed", ["threadId": "T", "turn": ["id": "A", "status": "completed"]])
        XCTAssertEqual(events, ["partial:Hi", "partial:Hi there", "finished:Hi there"])
    }

    func testImageGoesAsDataURL() {
        chat.send(text: "what is this", image: Data([1, 2, 3]))
        startThread()
        let input = (last("turn/start")?["params"] as? [String: Any])?["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["type"] as? String, "image")
        XCTAssertEqual(input?.first?["url"] as? String, "data:image/png;base64,AQID")
    }

    func testStopThenNewQuestionBeforeTheOldTurnStarted() {
        chat.send(text: "one")
        startThread()
        let first = last("turn/start")!
        chat.stop()
        XCTAssertEqual(events, ["finished:"])
        chat.send(text: "two")
        XCTAssertEqual(all("turn/start").count, 1, "the new message waits while the stopped turn may still run")
        // The stopped turn answers late: it is interrupted, and nothing from it is shown.
        answer(first, ["turn": ["id": "A"]])
        XCTAssertEqual((last("turn/interrupt")?["params"] as? [String: Any])?["turnId"] as? String, "A")
        note("item/agentMessage/delta", ["threadId": "T", "turnId": "A", "itemId": "x", "delta": "old"])
        note("turn/completed", ["threadId": "T", "turn": ["id": "A", "status": "interrupted"]])
        let second = last("turn/start")!
        XCTAssertEqual(all("turn/start").count, 2)
        XCTAssertEqual(text(of: second), "two")
        answer(second, ["turn": ["id": "B"]])
        note("item/agentMessage/delta", ["threadId": "T", "turnId": "B", "itemId": "y", "delta": "new"])
        note("turn/completed", ["threadId": "T", "turn": ["id": "B", "status": "completed"]])
        XCTAssertEqual(events, ["finished:", "partial:new", "finished:new"])
    }

    func testStopWhileStartingNeverSendsTheOldText() {
        chat.send(text: "one")
        let firstThread = last("thread/start")
        chat.stop()
        chat.send(text: "two")
        answer(firstThread, ["thread": ["id": "T", "ephemeral": true]])
        // The second message's own thread request (sent while the first had no thread yet).
        let threads = all("thread/start")
        if threads.count > 1 { answer(threads.last, ["thread": ["id": "T", "ephemeral": true]]) }
        let turns = all("turn/start")
        XCTAssertEqual(turns.map { text(of: $0) }, ["two"])
    }

    func testNotificationsBeforeTheTurnIdAreKeptForIt() {
        chat.send(text: "q")
        startThread()
        let turn = last("turn/start")!
        note("item/agentMessage/delta", ["threadId": "T", "turnId": "C", "itemId": "i", "delta": "early"])
        XCTAssertEqual(events, [])
        answer(turn, ["turn": ["id": "C"]])
        XCTAssertEqual(events, ["partial:early"])
        note("turn/completed", ["threadId": "T", "turn": ["id": "C", "status": "completed"]])
        XCTAssertEqual(events.last, "finished:early")
    }

    func testFailedTurn() {
        chat.send(text: "q")
        startThread()
        answer(last("turn/start"), ["turn": ["id": "A"]])
        note("turn/completed", ["threadId": "T", "turn": ["id": "A", "status": "failed", "error": ["message": "boom"]]])
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].hasPrefix("failed:"))
    }

    func testThreadMustBeEphemeral() {
        chat.send(text: "q")
        answer(last("thread/start"), ["thread": ["id": "T", "ephemeral": false]])
        XCTAssertTrue(all("turn/start").isEmpty)
        XCTAssertTrue(events.first?.hasPrefix("failed:") == true)
    }

    func testEveryServerRequestIsDeclined() {
        let cases: [(String, String)] = [("item/commandExecution/requestApproval", "decision"), ("item/fileChange/requestApproval", "decision"),
                                         ("execCommandApproval", "decision"), ("applyPatchApproval", "decision"),
                                         ("mcpServer/elicitation/request", "action"), ("item/permissions/requestApproval", "permissions"),
                                         ("item/tool/requestUserInput", "answers")]
        for (n, (method, key)) in cases.enumerated() {
            chat.handle(["id": 100 + n, "method": method, "params": [String: Any]()])
            let reply = sent.last!
            XCTAssertEqual(reply["id"] as? Int, 100 + n)
            let result = reply["result"] as? [String: Any]
            XCTAssertNotNil(result?[key], method)
            if let d = result?["decision"] as? String { XCTAssertTrue(["decline", "abort"].contains(d)) }
            if let a = result?["action"] as? String { XCTAssertEqual(a, "decline") }
            XCTAssertTrue((result?["permissions"] as? [String: Any])?.isEmpty ?? true)
        }
        chat.handle(["id": 200, "method": "item/tool/call", "params": [String: Any]()])
        XCTAssertNotNil(sent.last?["error"])
    }

    func testLimitsReadAndBlocking() {
        var got: CodexLimits?
        chat.refreshLimits(ifOlderThan: 0) { got = $0 }
        answer(last("account/rateLimits/read"), ["ordinaryUsageAllowed": false,
                                                 "rateLimits": ["primary": ["usedPercent": 100, "windowDurationMins": 10080]]])
        XCTAssertEqual(got?.blocked, true)
        chat.send(text: "q")
        XCTAssertTrue(all("thread/start").isEmpty, "nothing is sent when ordinary requests are explicitly unavailable")
        XCTAssertTrue(events.last?.hasPrefix("failed:") == true)
    }

    func testUpdatesFromAnotherBucketAreIgnored() {
        note("account/rateLimits/updated", ["rateLimits": ["limitId": "other", "primary": ["usedPercent": 100, "windowDurationMins": 300]]])
        XCTAssertEqual(events, [])
        note("account/rateLimits/updated", ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 7, "windowDurationMins": 10080]]])
        XCTAssertEqual(events, ["limits:7"])
    }
}

final class ChatModelTests: XCTestCase {
    func testEachProviderKeepsItsOwnSide() {
        let m = ChatModel()
        m.provider = .claude
        m.input = "draft for claude"
        m.busy = true
        m.provider = .codex
        XCTAssertEqual(m.input, "")
        XCTAssertFalse(m.busy)
        m.input = "draft for codex"
        m.update(.claude) { $0.messages.append(ChatMessage(role: .bot, text: "late reply")) }
        XCTAssertTrue(m.messages.isEmpty, "a reply for Claude does not show in Codex's tab")
        m.provider = .claude
        XCTAssertEqual(m.input, "draft for claude")
        XCTAssertEqual(m.messages.last?.text, "late reply")
        XCTAssertEqual(m.buttonMode, .stop)
    }

    func testLimitRowsPerProvider() {
        let m = ChatModel()
        m.limits = PlanLimits(session: 10, week: 20)
        m.codexLimits = CodexLimits(windows: [.init(used: 2, minutes: 10080, reset: Date(timeIntervalSinceNow: 6 * 86400))])
        m.provider = .claude
        XCTAssertEqual(m.limitRows.map(\.value), [10, 20])
        m.provider = .codex
        XCTAssertEqual(m.limitRows.map(\.label), [tr("Неделя", "Week")])
        XCTAssertTrue(m.limitNote.contains(tr("сброс", "resets")))
        m.codexLimits.ordinaryAllowed = false
        XCTAssertEqual(m.limitNote, tr("Лимит Codex исчерпан: обычные запросы недоступны.", "Codex limit reached: ordinary requests are unavailable."))
    }

    func testProviderPreferenceDefaultsToClaude() {
        let store = UserDefaults(suiteName: "dockling.tests.\(UUID().uuidString)")!
        let prefs = Preferences(store: store)
        XCTAssertEqual(prefs.chatProvider, .claude)
        prefs.chatProvider = .codex
        XCTAssertEqual(Preferences(store: store).chatProvider, .codex)
        XCTAssertTrue(Preferences(store: store).lastLimits == PlanLimits())
        prefs.lastCodexLimits = CodexLimits(windows: [.init(used: 3, minutes: 300, reset: nil)])
        XCTAssertEqual(Preferences(store: store).lastCodexLimits.windows.first?.minutes, 300)
    }
}
