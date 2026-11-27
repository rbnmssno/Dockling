import AppKit
import Combine
import SwiftUI

/// Runs the chat: the window over the character's head, Claude and Codex, voice, attachments and reminders.
/// Each provider has its own conversation; events always go to the conversation they belong to, whichever
/// tab is showing.
final class ChatController {
    let model = ChatModel()
    private let claude = ClaudeChat()
    private let probe = LimitsProbe()
    private let codex = CodexChat()
    private let voice = Voice()
    private let prefs: Preferences
    private weak var brain: PetBrain?
    private weak var stage: PetStage?
    private var panel: ChatPanel?
    private var box: GlassBox?
    /// The conversations whose current question was asked by voice, to read the answer aloud.
    private var voiceAsked: Set<Provider> = []
    /// The conversation the microphone is recording for.
    private var voiceTarget: Provider?
    private var flagsMonitor: Any?
    private var resignObserver: Any?
    private var lastClipboard = NSPasteboard.general.changeCount
    private var warned: Set<String> = []
    /// Extra lines the model gets before each message: the time and today's calendar.
    var context: () -> String = { "" }
    var onLimits: ((PlanLimits) -> Void)?
    var onCodexLimits: ((CodexLimits) -> Void)?

    var isOpen: Bool { panel?.isVisible == true }

    init(prefs: Preferences, brain: PetBrain, stage: PetStage) {
        self.prefs = prefs
        self.brain = brain
        self.stage = stage
        claude.binaryOverride = { [weak prefs] in prefs?.claudePath ?? "" }
        claude.onEvent = { [weak self] in self?.handle($0) }
        probe.binaryOverride = { [weak prefs] in prefs?.claudePath ?? "" }
        codex.binaryOverride = { [weak prefs] in prefs?.codexPath ?? "" }
        codex.onEvent = { [weak self] in self?.handle($0) }
        model.limits = prefs.lastLimits.current
        model.codexLimits = prefs.lastCodexLimits.current
        model.provider = prefs.chatProvider
        voice.onText = { [weak self] text in
            guard let self, let p = self.voiceTarget else { return }
            self.model.update(p) { $0.input = text }
        }
        model.update(.claude) { $0.messages = [ChatMessage(role: .bot, text: tr("Привет. Я живу у тебя на Dock. Спрашивай что угодно.", "Hi. I live on your Dock. Ask me anything."))] }
        model.update(.codex) { $0.messages = [ChatMessage(role: .bot, text: tr("Привет, это Codex. Чем помочь?", "Hi, it's Codex. How can I help?"))] }
        refreshStatus()
    }

    private func refreshStatus() {
        model.update(.claude) { $0.status = ClaudeChat.locate(custom: prefs.claudePath) == nil ? ChatModel.noClaude : ChatModel.online }
        let codexFound = CodexChat.locate(custom: prefs.codexPath) != nil
        model.update(.codex) { t in
            if !codexFound { t.status = ChatModel.noCodex } else if t.status == ChatModel.noCodex { t.status = ChatModel.online }
        }
    }

    // MARK: - Window

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard let stage, let window = stage.window else { return }
        brain?.wake()
        if panel == nil { build() }
        guard let panel else { return }
        // The face from the current sheet (it may have been replaced in Settings).
        model.avatar = stage.skin?.faceImage().map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }
        offerClipboard()
        refreshStatus()
        // The numbers are there before the first message, and fresh.
        refreshSelectedLimits()
        restyle()
        place(over: stage, in: window)
        brain?.cards.hide()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.optionKey(event)
            return event
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        if voiceTarget != nil { stopListening() }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        lastClipboard = NSPasteboard.general.changeCount
        panel.orderOut(nil)
        brain?.settle()
        brain?.cards.setStanding(brain?.cards.standing)
        if !model.thread(.codex).busy { codex.scheduleIdle() }
    }

    /// Shows the other conversation. A reply running in the one left keeps going there.
    func select(_ provider: Provider) {
        guard model.provider != provider else { return }
        model.provider = provider
        prefs.chatProvider = provider
        refreshStatus()
        if isOpen { refreshSelectedLimits() }
        resize()
    }

    func shutdown() {
        codex.shutdown()
    }

    /// For DevTools: the Stop button of the conversation on screen.
    func stopForDemo() { stopReply() }

    private func build() {
        let panel = ChatPanel()
        let view = ChatView(model: model,
                            send: { [weak self] in self?.sendInput() },
                            stop: { [weak self] in self?.stopReply() },
                            startListening: { [weak self] in self?.startListening() },
                            stopListening: { [weak self] in self?.stopListening() },
                            quick: { [weak self] text in self?.send(text) },
                            dropAttachment: { [weak self] in self?.model.attachment = nil; self?.resize() },
                            select: { [weak self] in self?.select($0) },
                            close: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        let box = GlassBox(content: host, cornerRadius: 26)
        panel.contentView = box
        panel.onEscape = { [weak self] in self?.close() }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Clicking anywhere else closes the chat, as with a popover.
            // A scripted showcase runs while another app has the focus, so there it stays open.
            guard let self, self.voiceTarget == nil, !DevTools.scripted else { return }
            Log.debug("chat lost focus, closing")
            self.close()
        }
        self.panel = panel
        self.box = box
    }

    func restyle() {
        box?.apply(dark: prefs.isDark, transparency: prefs.transparency)
        model.clarity = GlassBox.look(prefs.transparency).clarity
    }

    // For DevTools: look at the glass at other settings without saving them.
    var panelFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }
    func bringToFront() { panel?.orderFrontRegardless() }
    func previewGlass(dark: Bool, transparency: Double) {
        box?.apply(dark: dark, transparency: transparency)
        model.clarity = GlassBox.look(transparency).clarity
    }

    private var height: CGFloat { model.attachment == nil ? 352 : 404 }

    /// Above his head: where he is now on screen, or (`resting`) where he will stand once a fall ends.
    private func frame(over stage: PetStage, in window: NSWindow, resting: Bool = false) -> CGRect {
        let screen = window.screen?.visibleFrame ?? window.frame
        let w: CGFloat = 348, h = height
        let cx = resting ? stage.restingCenterX : stage.centerX
        let top = resting ? stage.restingHeadTop : stage.headTop
        let x = (window.frame.minX + cx - w / 2).clamped(screen.minX + 8, screen.maxX - w - 8)
        let y = min(window.frame.minY + top + 10, screen.maxY - h - 8)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func place(over stage: PetStage, in window: NSWindow) {
        panel?.setFrame(frame(over: stage, in: window), display: true)
    }

    private func resize() {
        guard let stage, let window = stage.window, isOpen else { return }
        place(over: stage, in: window)
    }

    func reposition() {
        resize()
    }

    /// Keeps the open chat over him while he is carried, and brings it down with him when he falls,
    /// on the same curve and in the same time.
    func follow(fallDuration: TimeInterval = 0) {
        guard isOpen, let stage, let window = stage.window, let panel else { return }
        // Carried: where he was just put (what is on screen lags a frame behind).
        guard fallDuration > 0.02 else { panel.setFrame(frame(over: stage, in: window, resting: true), display: true); return }
        let target = frame(over: stage, in: window, resting: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fallDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1.0 / 3)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Messages

    private func sendInput() {
        let text = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.busy else { return }
        model.input = ""
        send(text)
    }

    /// Sends to the selected conversation, or to `provider`.
    func send(_ text: String, viaVoice: Bool = false, to provider: Provider? = nil) {
        let p = provider ?? model.provider
        guard !model.thread(p).busy else { return }
        voice.hush()
        if viaVoice { voiceAsked.insert(p) } else { voiceAsked.remove(p) }
        model.update(p) { $0.messages.append(ChatMessage(role: .me, text: text)) }
        if handleReminder(text, in: p) { return }
        let att = model.thread(p).attachment
        var message = text
        var image: Data?
        if let att {
            switch att.kind {
            case .file: message = tr("Файл «\(att.label)»:\n\(att.text ?? "")\n\nВопрос: \(text)",
                                    "File \"\(att.label)\":\n\(att.text ?? "")\n\nQuestion: \(text)")
            case .text: message = tr("Текст, о котором речь:\n«\(att.text ?? "")»\n\nПросьба: \(text)",
                                    "The text in question:\n\"\(att.text ?? "")\"\n\nRequest: \(text)")
            case .screenshot: message = tr("К вопросу приложен скриншот экрана.\n\nВопрос: \(text)",
                                          "A screenshot is attached to the question.\n\nQuestion: \(text)"); image = att.image
            }
        }
        let ctx = context()
        if !ctx.isEmpty { message = "[" + ctx + "]\n\n" + message }
        model.update(p) { t in
            t.messages.append(ChatMessage(role: .bot, text: "", thinking: true))
            t.busy = true
        }
        brain?.thinking = true
        switch p {
        case .claude: claude.send(text: message, image: image)
        case .codex: codex.send(text: message, image: image)
        }
    }

    private func stopReply() {
        switch model.provider {
        case .claude: claude.stop()
        case .codex: codex.stop()
        }
    }

    private func handle(_ event: ClaudeChat.Event) {
        if case .partial = event {} else { Log.debug("claude event \(event)") }
        switch event {
        case .partial(let text): partial(text, in: .claude)
        case .finished(let text): finished(text, in: .claude)
        case .failed(let text): failed(text, in: .claude)
        case .limits(let limits): took(limits)
        }
    }

    private func handle(_ event: CodexChat.Event) {
        if case .partial = event {} else { Log.debug("codex event \(event)") }
        switch event {
        case .partial(let text): partial(text, in: .codex)
        case .finished(let text): finished(text, in: .codex)
        case .failed(let text): failed(text, in: .codex)
        case .limits(let limits): tookCodex(limits)
        case .status(let status): model.update(.codex) { $0.status = status }
        }
    }

    private func partial(_ text: String, in p: Provider) {
        guard model.thread(p).busy else { return }
        updateLast(text, in: p)
        brain?.thinking = false
        brain?.talking = true
    }

    private func finished(_ text: String, in p: Provider) {
        updateLast(text.isEmpty ? tr("Остановлено.", "Stopped.") : text, in: p)
        finishReply(in: p)
        if voiceAsked.contains(p) && prefs.speakVoiceReplies && !text.isEmpty { voice.speak(text) }
        voiceAsked.remove(p)
    }

    private func failed(_ text: String, in p: Provider) {
        model.update(p) { t in
            if let last = t.messages.last, last.role == .bot, last.text.isEmpty { t.messages.removeLast() }
            t.messages.append(ChatMessage(role: .note, text: text))
        }
        finishReply(in: p)
        voiceAsked.remove(p)
    }

    private func took(_ limits: PlanLimits) {
        model.limits = limits
        model.update(.claude) { $0.checkingLimits = false }
        prefs.lastLimits = limits
        onLimits?(limits)
    }

    private func tookCodex(_ limits: CodexLimits) {
        model.codexLimits = limits
        model.update(.codex) { $0.checkingLimits = false }
        prefs.lastCodexLimits = limits
        onCodexLimits?(limits)
    }

    /// The limits of the conversation on screen. Codex's come from its app-server without asking the model;
    /// Claude's need the smallest request, so they are only asked for while Claude's tab is showing.
    private func refreshSelectedLimits() {
        switch model.provider {
        case .claude: refreshLimits(ifOlderThan: 90)
        case .codex: refreshCodexLimits(ifOlderThan: 60)
        }
    }

    /// Asks Claude Code for the limits, unless they were heard within `maxAge` seconds.
    func refreshLimits(ifOlderThan maxAge: TimeInterval) {
        model.limits = model.limits.current
        let asking = probe.run(ifOlderThan: maxAge) { [weak self] limits in
            if let limits { self?.took(limits) } else { self?.model.update(.claude) { $0.checkingLimits = false } }
        }
        model.update(.claude) { $0.checkingLimits = asking }
    }

    /// Reads Codex's limits from its app-server, unless they were read within `maxAge` seconds.
    func refreshCodexLimits(ifOlderThan maxAge: TimeInterval) {
        guard CodexChat.locate(custom: prefs.codexPath) != nil else { return }
        model.codexLimits = model.codexLimits.current
        let asking = codex.refreshLimits(ifOlderThan: maxAge) { [weak self] limits in
            if let limits { self?.tookCodex(limits) } else { self?.model.update(.codex) { $0.checkingLimits = false } }
        }
        if asking { model.update(.codex) { $0.checkingLimits = true } }
    }

    private func updateLast(_ text: String, in p: Provider) {
        model.update(p) { t in
            guard let i = t.messages.lastIndex(where: { $0.role == .bot }) else { return }
            t.messages[i].text = text
            t.messages[i].thinking = false
        }
    }

    private func finishReply(in p: Provider) {
        model.update(p) { $0.busy = false }
        let anyBusy = Provider.allCases.contains { model.thread($0).busy }
        if !anyBusy {
            brain?.thinking = false
            brain?.talking = false
        }
    }

    /// Puts a card that arrived while the chat is open into the conversation on screen. A card with
    /// buttons is drawn apart from the bubbles, under the name of where it came from, so a Claude Code
    /// permission request never looks like a question from the conversation it landed in.
    func note(_ card: Card) {
        let p = model.provider
        if card.actions.isEmpty {
            let source = card.source.map { $0 + ": " } ?? ""
            model.update(p) { $0.messages.append(ChatMessage(role: .note, text: source + card.text + (card.meta.map { " · " + $0 } ?? ""))) }
        } else {
            var message = ChatMessage(role: .card, text: card.text + (card.meta.map { "\n" + $0 } ?? ""), source: card.source)
            let id = message.id
            message.actions = card.actions.map { action in
                CardAction(title: action.title, primary: action.primary) { [weak self] in
                    action.run()
                    self?.model.update(p) { t in
                        if let i = t.messages.firstIndex(where: { $0.id == id }) { t.messages[i].actions = [] }
                    }
                }
            }
            model.update(p) { $0.messages.append(message) }
        }
    }

    // MARK: - Voice

    private func startListening() {
        let p = model.provider
        guard voiceTarget == nil, !model.thread(p).busy else { return }
        voice.hush()
        voiceTarget = p
        model.update(p) { t in t.input = ""; t.listening = true }
        brain?.listening = true
        voice.start { [weak self] problem in
            guard let self else { return }
            self.voiceTarget = nil
            self.model.update(p) { t in t.listening = false; t.messages.append(ChatMessage(role: .note, text: problem)) }
            self.brain?.listening = false
        }
    }

    /// The question goes to the conversation it was started in, even if the other tab is showing now.
    private func stopListening() {
        guard let p = voiceTarget else { return }
        voiceTarget = nil
        model.update(p) { $0.listening = false }
        brain?.listening = false
        voice.stop { [weak self] text in
            guard let self else { return }
            self.model.update(p) { $0.input = "" }
            if text.isEmpty {
                self.model.update(p) { $0.messages.append(ChatMessage(role: .note, text: tr("Ничего не расслышал. Зажми кнопку и говори.", "I didn't catch that. Hold the button and speak."))) }
            } else {
                self.send(text, viaVoice: true, to: p)
            }
        }
    }

    /// Holding Option alone while the chat is open is the same as holding the microphone button.
    private func optionKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .option {
            if model.buttonMode == .mic { startListening() }
        } else if voiceTarget != nil {
            stopListening()
        }
    }

    // MARK: - Attachments

    func attach(_ attachment: ChatAttachment) {
        model.attachment = attachment
        if !isOpen { open() } else { resize() }
    }

    func attachFiles(_ urls: [URL]) {
        guard let url = urls.first else { return }
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"].contains(ext), let image = NSImage(contentsOf: url), let png = image.pngForClaude() {
            attach(ChatAttachment(kind: .screenshot, label: url.lastPathComponent, image: png, thumbnail: image,
                                  quick: [(tr("Что тут?", "What's This?"), tr("Что на этой картинке?", "What's in this picture?"))]))
            return
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 400_000,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) else {
            attach(ChatAttachment(kind: .file, label: url.lastPathComponent, text: tr("(файл не текстовый, прочитать его не получилось)", "(not a text file, it could not be read)"), quick: []))
            model.messages.append(ChatMessage(role: .note, text: tr("Я читаю текстовые файлы и картинки. Этот файл не получилось прочитать.", "I can read text files and pictures. This file could not be read.")))
            return
        }
        attach(ChatAttachment(kind: .file, label: url.lastPathComponent, text: String(text.prefix(60_000)),
                              quick: [(tr("Перескажи", "Summarize"), tr("Перескажи коротко, что в этом файле.", "Briefly sum up what this file says.")),
                                      (tr("Что главное?", "Key Points"), tr("Что тут самое важное?", "What matters most here?"))]))
    }

    static let textActions = [(tr("Объясни", "Explain"), tr("Объясни этот текст простыми словами.", "Explain this text in plain words.")),
                              (tr("Переведи", "Translate"), ChatController.translatePrompt),
                              (tr("Исправь", "Fix"), tr("Исправь ошибки в этом тексте.", "Fix the mistakes in this text."))]
    static let translatePrompt = tr("Переведи этот текст.", "Translate this text.")

    func attachText(_ text: String, label: String) {
        let short = text.count > 24 ? String(text.prefix(23)) + "…" : text
        attach(ChatAttachment(kind: .text, label: label + ": " + quoted(short), text: String(text.prefix(20_000)), quick: Self.textActions))
    }

    func attachImage(_ image: NSImage, label: String) {
        guard let png = image.pngForClaude() else { return }
        attach(ChatAttachment(kind: .screenshot, label: label, image: png, thumbnail: image,
                              quick: Self.screenshotActions))
    }

    static let clipboardScreenshotLabel = tr("Скриншот из буфера", "Clipboard screenshot")
    static let screenshotActions = [(tr("Что тут?", "What's This?"), tr("Что на этом скриншоте?", "What's in this screenshot?"))]

    /// A picture alone on the clipboard, the way a screenshot taken with Control (⌃⇧⌘3, ⌃⇧⌘4) leaves it.
    /// A picture copied from a page or a file comes with a link, text or a file name and does not count.
    static func clipboardScreenshot(_ pb: NSPasteboard = .general) -> NSImage? {
        let types = Set(pb.types ?? [])
        guard types.contains(.png) || types.contains(.tiff) else { return nil }
        let other: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .html, .string, .rtf, .init("com.apple.webarchive")]
        guard !other.contains(where: types.contains) else { return nil }
        return NSImage(pasteboard: pb)
    }

    /// If something new was copied since the chat was last closed, offers to work with it.
    private func offerClipboard() {
        let pb = NSPasteboard.general
        defer { lastClipboard = pb.changeCount }
        guard pb.changeCount != lastClipboard, model.attachment == nil, !DevTools.scripted else { return }
        if let image = Self.clipboardScreenshot(pb), let png = image.pngForClaude() {
            model.attachment = ChatAttachment(kind: .screenshot, label: ChatController.clipboardScreenshotLabel, image: png, thumbnail: image,
                                              quick: Self.screenshotActions)
            return
        }
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let short = text.count > 24 ? String(text.prefix(23)) + "…" : text
        model.attachment = ChatAttachment(kind: .text, label: tr("Из буфера", "Clipboard") + ": " + quoted(short), text: String(text.prefix(20_000)), quick: Self.textActions)
    }

    // MARK: - Reminders

    /// "Напомни через 20 минут позвонить маме", "remind me in 20 minutes to call mom" and "remind me to call mom
    /// in 20 minutes" are handled here, without asking Claude. The answer is in the language of the request.
    private func handleReminder(_ text: String, in p: Provider) -> Bool {
        guard let r = Self.parseReminder(text) else { return false }
        let what = r.what.isEmpty ? (r.russian ? "ты просил напомнить" : "You asked me to remind you") : r.what
        model.update(p) { $0.messages.append(ChatMessage(role: .bot, text: r.russian ? "Хорошо, напомню через \(r.when)." : "OK, I'll remind you in \(r.when).")) }
        Reminders.shared.add(after: r.seconds, text: what)
        return true
    }

    struct ParsedReminder: Equatable {
        var seconds: Double
        var when: String
        var what: String
        var russian: Bool
    }

    static func parseReminder(_ text: String) -> ParsedReminder? {
        func match(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        }
        // Russian: "напомни (мне) через 20 минут позвонить".
        if let g = match(#"^\s*напомни\s+(?:мне\s+)?через\s+(\d+)\s*(сек|мин|ч)[а-яё]*\.?\s*(.*)$"#) {
            let n = Int(g[0]) ?? 1, unit = g[1].lowercased()
            let seconds = Double(n) * (unit.hasPrefix("ч") ? 3600 : unit.hasPrefix("мин") ? 60 : 1)
            let when = unit.hasPrefix("ч") ? "\(n) ч" : unit.hasPrefix("мин") ? "\(n) мин" : "\(n) сек"
            return ParsedReminder(seconds: seconds, when: when, what: clean(g[2]), russian: true)
        }
        // English: "remind me in 20 minutes (to) call mom" or "remind me to call mom in 20 minutes".
        let unit = #"(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b"#
        var n = 0, u = "", what = ""
        if let g = match(#"^\s*remind\s+me\s+in\s+(\d+)\s*"# + unit + #"\.?\s*(?:to\s+|that\s+|about\s+)?(.*)$"#) {
            n = Int(g[0]) ?? 1; u = g[1].lowercased(); what = g[2]
        } else if let g = match(#"^\s*remind\s+me\s+(?:to\s+|that\s+|about\s+)?(.+?)\s+in\s+(\d+)\s*"# + unit + #"\s*\.?\s*$"#) {
            what = g[0]; n = Int(g[1]) ?? 1; u = g[2].lowercased()
        } else {
            return nil
        }
        let hours = u.hasPrefix("h"), minutes = u.hasPrefix("m")
        let seconds = Double(n) * (hours ? 3600 : minutes ? 60 : 1)
        let word = hours ? "hour" : minutes ? "minute" : "second"
        return ParsedReminder(seconds: seconds, when: "\(n) \(word)\(n == 1 ? "" : "s")", what: clean(what), russian: false)
    }

    // MARK: - Limits

    /// Cards when Claude's session limit crosses 85% and 98%.
    func warnAboutLimits(_ limits: PlanLimits, brain: PetBrain) {
        guard let s = limits.session else { return }
        let resetKey = limits.sessionReset.map { String(Int($0.timeIntervalSince1970)) } ?? "?"
        let mins = limits.sessionReset.map { max(0, Int($0.timeIntervalSinceNow / 60)) }
        let meta = mins.map { tr("Сброс через ", "Resets in ") + durationText(minutes: $0) }
        let text = tr("Лимит сессии Claude: \(Int(s))%", "Claude session limit: \(Int(s))%")
        if s >= 98, !warned.contains("98-" + resetKey) {
            warned.insert("98-" + resetKey)
            brain.upset()
            brain.notify(Card(icon: .limit, color: Card.red, text: text, meta: meta, duration: 6, tag: "limit"))
        } else if s >= 85, !warned.contains("85-" + resetKey) {
            warned.insert("85-" + resetKey)
            brain.notify(Card(icon: .limit, color: Card.amber, text: text, meta: meta, duration: 5, tag: "limit"))
        }
    }

    /// Cards when a Codex window crosses 85% and 98%, named by the window, each once per window and reset.
    func warnAboutCodexLimits(_ limits: CodexLimits, brain: PetBrain) {
        for w in limits.windows {
            let key = "codex-\(w.minutes ?? 0)-" + (w.reset.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "?")
            let meta = w.reset.map { tr("Сброс через ", "Resets in ") + durationText(minutes: max(0, Int($0.timeIntervalSinceNow / 60))) }
            let name = CodexLimits.label(minutes: w.minutes).lowercased()
            let text = tr("Лимит Codex (\(name)): \(Int(w.used))%", "Codex limit (\(name)): \(Int(w.used))%")
            if w.used >= 98, !warned.contains(key + "-98") {
                warned.insert(key + "-98")
                brain.upset()
                brain.notify(Card(icon: .limit, color: Card.red, text: text, meta: meta, duration: 6, tag: "codex-limit"))
                return
            } else if w.used >= 85, w.used < 98, !warned.contains(key + "-85") {
                warned.insert(key + "-85")
                brain.notify(Card(icon: .limit, color: Card.amber, text: text, meta: meta, duration: 5, tag: "codex-limit"))
                return
            }
        }
    }
}

extension NSImage {
    /// A PNG no larger than Claude needs (long side 1600 px).
    func pngForClaude() -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1600 / Double(max(cg.width, cg.height)))
        let w = Int(Double(cg.width) * scale), h = Int(Double(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}

/// Reminders set from the chat. They are kept in a file, so a restart does not lose them, and they
/// count real time, sleep included. One that came due while the app was not running fires at launch.
final class Reminders {
    static let shared = Reminders()
    /// Set once at launch; saved reminders are picked up a moment later.
    var fire: ((String) -> Void)? {
        didSet { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.restore() } }
    }

    private struct Item: Codable {
        let id: UUID
        let due: Date
        let text: String
    }

    private var items: [Item] = []
    private var timers: [UUID: OneShot] = [:]
    private var restored = false
    private let file = Paths.support.appendingPathComponent("reminders.json")

    func add(after seconds: TimeInterval, text: String) {
        restore()  // the saved ones first, or saving would drop them
        let item = Item(id: UUID(), due: Date().addingTimeInterval(seconds), text: text)
        items.append(item)
        save()
        arm(item)
        Log.note("reminder set for \(Int(seconds)) s")
    }

    private func arm(_ item: Item) {
        let t = OneShot()
        timers[item.id] = t
        t.schedule(after: item.due.timeIntervalSinceNow, wallClock: true) { [weak self] in
            guard let self else { return }
            self.timers[item.id] = nil
            self.items.removeAll { $0.id == item.id }
            self.save()
            Log.note("reminder fired")
            self.fire?(item.text)
        }
    }

    private func restore() {
        guard !restored else { return }
        restored = true
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Item].self, from: data) else { return }
        let known = Set(items.map(\.id))
        for item in saved where !known.contains(item.id) {
            items.append(item)
            arm(item)
        }
        if !saved.isEmpty { Log.note("reminders restored: \(saved.count)") }
    }

    private func save() {
        try? JSONEncoder().encode(items).write(to: file, options: .atomic)
    }
}
