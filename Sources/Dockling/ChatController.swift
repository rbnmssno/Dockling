import AppKit
import Combine
import SwiftUI

/// Runs the chat: the window over the character's head, Claude, voice, attachments and reminders.
final class ChatController {
    let model = ChatModel()
    private let claude = ClaudeChat()
    private let voice = Voice()
    private let prefs: Preferences
    private weak var brain: PetBrain?
    private weak var stage: PetStage?
    private var panel: ChatPanel?
    private var box: GlassBox?
    private var voiceQuestion = false
    private var flagsMonitor: Any?
    private var resignObserver: Any?
    private var lastClipboard = NSPasteboard.general.changeCount
    private var warned: Set<String> = []
    /// Extra lines Claude gets before each message: the time and today's calendar.
    var context: () -> String = { "" }
    var onLimits: ((PlanLimits) -> Void)?

    var isOpen: Bool { panel?.isVisible == true }

    init(prefs: Preferences, brain: PetBrain, stage: PetStage) {
        self.prefs = prefs
        self.brain = brain
        self.stage = stage
        claude.binaryOverride = { [weak prefs] in prefs?.claudePath ?? "" }
        claude.onEvent = { [weak self] in self?.handle($0) }
        voice.onText = { [weak self] text in self?.model.input = text }
        model.messages = [ChatMessage(role: .bot, text: "Привет. Я живу у тебя на Dock. Спрашивай что угодно.")]
        model.status = ClaudeChat.locate(custom: prefs.claudePath) == nil ? "нет claude code" : "на связи"
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
        model.status = ClaudeChat.locate(custom: prefs.claudePath) == nil ? "нет claude code" : "на связи"
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
        if model.listening { stopListening() }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        lastClipboard = NSPasteboard.general.changeCount
        panel.orderOut(nil)
        brain?.settle()
        brain?.cards.setStanding(brain?.cards.standing)
    }

    private func build() {
        let panel = ChatPanel()
        let view = ChatView(model: model,
                            send: { [weak self] in self?.sendInput() },
                            stop: { [weak self] in self?.stopReply() },
                            startListening: { [weak self] in self?.startListening() },
                            stopListening: { [weak self] in self?.stopListening() },
                            quick: { [weak self] text in self?.send(text) },
                            dropAttachment: { [weak self] in self?.model.attachment = nil; self?.resize() },
                            close: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        let box = GlassBox(content: host, cornerRadius: 26)
        panel.contentView = box
        panel.onEscape = { [weak self] in self?.close() }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Clicking anywhere else closes the chat, as with a popover.
            guard let self, !self.model.listening else { return }
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

    func send(_ text: String, viaVoice: Bool = false) {
        guard !model.busy else { return }
        voice.hush()
        voiceQuestion = viaVoice
        model.messages.append(ChatMessage(role: .me, text: text))
        if handleReminder(text) { return }
        let att = model.attachment
        var message = text
        var image: Data?
        if let att {
            switch att.kind {
            case .file: message = "Файл «\(att.label)»:\n\(att.text ?? "")\n\nВопрос: \(text)"
            case .text: message = "Текст, о котором речь:\n«\(att.text ?? "")»\n\nПросьба: \(text)"
            case .screenshot: message = "К вопросу приложен скриншот экрана.\n\nВопрос: \(text)"; image = att.image
            }
        }
        let ctx = context()
        if !ctx.isEmpty { message = "[" + ctx + "]\n\n" + message }
        model.messages.append(ChatMessage(role: .bot, text: "", thinking: true))
        model.busy = true
        brain?.thinking = true
        claude.send(text: message, image: image)
    }

    private func stopReply() {
        claude.stop()
    }

    private func handle(_ event: ClaudeChat.Event) {
        switch event {
        case .partial: break
        default: Log.debug("chat event \(event)")
        }
        switch event {
        case .partial(let text):
            updateLast(text)
            brain?.thinking = false
            brain?.talking = true
        case .finished(let text):
            updateLast(text.isEmpty ? "Остановлено." : text)
            finishReply()
            if voiceQuestion && prefs.speakVoiceReplies && !text.isEmpty { voice.speak(text) }
        case .failed(let text):
            if let last = model.messages.last, last.role == .bot, last.text.isEmpty { model.messages.removeLast() }
            model.messages.append(ChatMessage(role: .note, text: text))
            finishReply()
        case .limits(let limits):
            model.limits = limits
            onLimits?(limits)
        }
    }

    private func updateLast(_ text: String) {
        guard let i = model.messages.lastIndex(where: { $0.role == .bot }) else { return }
        model.messages[i].text = text
        model.messages[i].thinking = false
    }

    private func finishReply() {
        model.busy = false
        brain?.thinking = false
        brain?.talking = false
    }

    /// Puts a card that arrived while the chat is open into the conversation.
    func note(_ card: Card) {
        if card.actions.isEmpty {
            model.messages.append(ChatMessage(role: .note, text: card.text + (card.meta.map { " · " + $0 } ?? "")))
        } else {
            var message = ChatMessage(role: .bot, text: card.text + (card.meta.map { "\n" + $0 } ?? ""))
            let id = message.id
            message.actions = card.actions.map { action in
                CardAction(title: action.title, primary: action.primary) { [weak self] in
                    action.run()
                    if let i = self?.model.messages.firstIndex(where: { $0.id == id }) { self?.model.messages[i].actions = [] }
                }
            }
            model.messages.append(message)
        }
    }

    // MARK: - Voice

    private func startListening() {
        guard !model.listening, !model.busy else { return }
        voice.hush()
        model.input = ""
        model.listening = true
        brain?.listening = true
        voice.start { [weak self] problem in
            guard let self else { return }
            self.model.listening = false
            self.brain?.listening = false
            self.model.messages.append(ChatMessage(role: .note, text: problem))
        }
    }

    private func stopListening() {
        guard model.listening else { return }
        model.listening = false
        brain?.listening = false
        voice.stop { [weak self] text in
            guard let self else { return }
            self.model.input = ""
            if text.isEmpty {
                self.model.messages.append(ChatMessage(role: .note, text: "Ничего не расслышал. Зажми кнопку и говори."))
            } else {
                self.send(text, viaVoice: true)
            }
        }
    }

    /// Holding Option alone while the chat is open is the same as holding the microphone button.
    private func optionKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .option {
            if model.buttonMode == .mic { startListening() }
        } else if model.listening {
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
                                  quick: [("Что тут?", "Что на этой картинке?")]))
            return
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 400_000,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) else {
            attach(ChatAttachment(kind: .file, label: url.lastPathComponent, text: "(файл не текстовый, прочитать его не получилось)", quick: []))
            model.messages.append(ChatMessage(role: .note, text: "Я читаю текстовые файлы и картинки. Этот файл не получилось прочитать."))
            return
        }
        attach(ChatAttachment(kind: .file, label: url.lastPathComponent, text: String(text.prefix(60_000)),
                              quick: [("Перескажи", "Перескажи коротко, что в этом файле."), ("Что главное?", "Что тут самое важное?")]))
    }

    static let textActions = [("Объясни", "Объясни этот текст простыми словами."), ("Переведи", "Переведи этот текст."), ("Исправь", "Исправь ошибки в этом тексте.")]

    func attachText(_ text: String, label: String) {
        let short = text.count > 24 ? String(text.prefix(23)) + "…" : text
        attach(ChatAttachment(kind: .text, label: label + ": «" + short + "»", text: String(text.prefix(20_000)), quick: Self.textActions))
    }

    func attachImage(_ image: NSImage, label: String) {
        guard let png = image.pngForClaude() else { return }
        attach(ChatAttachment(kind: .screenshot, label: label, image: png, thumbnail: image,
                              quick: [("Что тут?", "Что на этом скриншоте?")]))
    }

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
            model.attachment = ChatAttachment(kind: .screenshot, label: "Скриншот из буфера", image: png, thumbnail: image,
                                              quick: [("Что тут?", "Что на этом скриншоте?")])
            return
        }
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let short = text.count > 24 ? String(text.prefix(23)) + "…" : text
        model.attachment = ChatAttachment(kind: .text, label: "Из буфера: «" + short + "»", text: String(text.prefix(20_000)), quick: Self.textActions)
    }

    // MARK: - Reminders

    /// "Напомни через 20 минут позвонить маме" is handled here, without asking Claude.
    private func handleReminder(_ text: String) -> Bool {
        let pattern = #"^\s*напомни\s+(?:мне\s+)?через\s+(\d+)\s*(сек|мин|ч)[а-яё]*\.?\s*(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nRange = Range(m.range(at: 1), in: text), let uRange = Range(m.range(at: 2), in: text) else { return false }
        let n = Int(text[nRange]) ?? 1
        let unit = text[uRange].lowercased()
        let seconds = Double(n) * (unit.hasPrefix("ч") ? 3600 : unit.hasPrefix("мин") ? 60 : 1)
        var what = Range(m.range(at: 3), in: text).map { String(text[$0]) } ?? ""
        what = what.trimmingCharacters(in: .whitespacesAndNewlines)
        if what.isEmpty { what = "ты просил напомнить" }
        let when = unit.hasPrefix("ч") ? "\(n) ч" : unit.hasPrefix("мин") ? "\(n) мин" : "\(n) сек"
        model.messages.append(ChatMessage(role: .bot, text: "Хорошо, напомню через \(when)."))
        Reminders.shared.add(after: seconds, text: what)
        return true
    }

    // MARK: - Limits

    /// Cards when the session limit crosses 85% and 98%.
    func warnAboutLimits(_ limits: PlanLimits, brain: PetBrain) {
        guard let s = limits.session else { return }
        let resetKey = limits.sessionReset.map { String(Int($0.timeIntervalSince1970)) } ?? "?"
        let mins = limits.sessionReset.map { max(0, Int($0.timeIntervalSinceNow / 60)) }
        let meta = mins.map { "Сброс через " + ($0 >= 60 ? "\($0 / 60) ч \($0 % 60) мин" : "\($0) мин") }
        if s >= 98, !warned.contains("98-" + resetKey) {
            warned.insert("98-" + resetKey)
            brain.upset()
            brain.notify(Card(icon: .limit, color: Card.red, text: "Лимит сессии: \(Int(s))%", meta: meta, duration: 6, tag: "limit"))
        } else if s >= 85, !warned.contains("85-" + resetKey) {
            warned.insert("85-" + resetKey)
            brain.notify(Card(icon: .limit, color: Card.amber, text: "Лимит сессии: \(Int(s))%", meta: meta, duration: 5, tag: "limit"))
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
