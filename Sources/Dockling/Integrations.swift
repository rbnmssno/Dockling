import AppKit
import EventKit
import IOKit.ps

/// Everything outside the app that the character reacts to. Each source wakes the app only when
/// something happens; the one exception is the clipboard's change counter, read once a second.
final class Integrations {
    private unowned let app: AppDelegate
    private let hookServer = HookServer()
    private var watcher: ClaudeCodeWatcher?
    private let calendar = CalendarWatcher()
    private var power: PowerWatcher?
    private var screenshots: ScreenshotWatcher?
    private let services = ServiceProvider()
    private let music = MusicWatcher()
    private let clipboard = ClipboardWatcher()

    init(app: AppDelegate) {
        self.app = app
    }

    /// With the setting on, the limits are asked for shortly after anything Claude Code does and every
    /// ten minutes while it works, so the warnings at 85% and 98% come without the chat.
    private let limitsCheck = OneShot()

    private func watchLimits(after delay: TimeInterval) {
        guard app.prefs.watchLimits else { return }
        limitsCheck.schedule(after: delay) { [weak self] in
            guard let self, self.app.prefs.watchLimits else { return }
            self.app.chat.refreshLimits(ifOlderThan: 240)
            if self.app.brain.claude != .none { self.watchLimits(after: 600) }
        }
    }

    /// The pet went out of sight: Claude Code's open permission questions go to its own dialog.
    func releaseClaudeQuestions() {
        watcher?.releasePending()
    }

    func start() {
        let brain = app.brain!
        // Claude Code, through the hooks the user switched on in Settings.
        let watcher = ClaudeCodeWatcher(brain: brain)
        watcher.canAsk = { [unowned app] in app.petVisible }
        self.watcher = watcher
        hookServer.onEvent = { [weak self] event, raw, reply in
            watcher.handle(event, raw, reply: reply)
            self?.watchLimits(after: 20)
        }
        hookServer.start()
        watchLimits(after: 5)

        // Music: Spotify and Apple Music announce every play and pause.
        music.onChange = { playing in brain.music = playing }
        music.start()

        // Waking up and opening the lid.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            brain.wake()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { brain.react("wave", duration: 1.5) }
        }

        // Charger and battery.
        power = PowerWatcher { event in
            switch event {
            case .connected: brain.react("charge_on")
            case .disconnected: brain.react("charge_off")
            case .low(let percent):
                brain.upset()
                brain.notify(Card(icon: .battery, color: Card.red, text: tr("Осталось \(percent)% заряда", "\(percent)% battery left"), duration: 6, tag: "battery"))
            }
        }

        // Calendar: meetings 10 minutes ahead, and today's list for the chat.
        calendar.onSoon = { event in
            guard self.app.prefs.calendarReminders else { return }
            var card = Card(icon: .calendar, color: Card.blue, text: event.title, meta: event.when + tr(", через 10 мин", ", in 10 min"), hold: true, call: true, tag: "meeting")
            card.duration = 14
            var actions: [CardAction] = []
            if let url = event.link { actions.append(CardAction(title: tr("Открыть", "Open"), primary: true) { NSWorkspace.shared.open(url) }) }
            actions.append(CardAction(title: tr("Позже", "Later")) { self.calendar.snooze(event, minutes: 5) })
            card.actions = actions
            brain.notify(card)
        }
        let dev = CommandLine.arguments.contains("--dev")
        if app.prefs.calendarReminders && !dev { calendar.start() }
        app.chat.context = { [weak self] in
            let f = DateFormatter()
            f.locale = Language.locale
            f.setLocalizedDateFormatFromTemplate("EEEEdMMMMjmm")
            var line = tr("Сейчас ", "Now: ") + f.string(from: Date())
            if let agenda = self?.calendar.todayText(), !agenda.isEmpty { line += tr(". Календарь на сегодня: ", ". Today's calendar: ") + agenda }
            return line
        }

        // Screenshots: saved as files (⇧⌘3, ⇧⌘4) or copied (with Control).
        if app.prefs.screenshotOffers && !dev {
            screenshots = ScreenshotWatcher { url in
                guard self.app.prefs.screenshotOffers, self.app.petVisible else { return }
                Log.note("screenshot file seen")
                brain.notify(Card(icon: .camera, color: Card.blue, text: tr("Скриншот сохранён", "Screenshot saved"), meta: tr("Спросить про него?", "Ask about it?"),
                                  actions: [CardAction(title: tr("Спросить", "Ask"), primary: true) { self.app.chat.attachFiles([url]) }, CardAction(title: tr("Нет", "No")) {}],
                                  duration: 9, tag: "screenshot"))
            }
        }
        clipboard.onScreenshot = { image in
            // With the chat open the card lands in the chat itself, with the same buttons.
            guard self.app.prefs.screenshotOffers, self.app.petVisible else { return }
            Log.note("screenshot on clipboard seen")
            brain.notify(Card(icon: .camera, color: Card.blue, text: tr("Скриншот в буфере", "Screenshot copied"), meta: tr("Спросить про него?", "Ask about it?"),
                              actions: [CardAction(title: tr("Спросить", "Ask"), primary: true) { self.app.chat.attachImage(image, label: ChatController.clipboardScreenshotLabel) },
                                        CardAction(title: tr("Нет", "No")) {}],
                              duration: 9, tag: "screenshot"))
        }
        if !dev || CommandLine.arguments.contains("--clipboard") { clipboard.start() }

        // "Ask the Ghost" and "Translate with the Ghost" in the Services menu of any app (ServicesMenu.strings).
        services.ask = { text in self.app.chat.attachText(text, label: tr("Выделено", "Selection")) }
        services.translate = { text in
            self.app.chat.attachText(text, label: tr("Выделено", "Selection"))
            self.app.chat.send(ChatController.translatePrompt)
        }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }
}

// MARK: - Music

/// Spotify and Apple Music send a distributed notification on every play and pause. It must be
/// delivered immediately, or a background app would only get it when it next becomes active.
final class MusicWatcher: NSObject {
    var onChange: ((Bool) -> Void)?

    func start() {
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            dnc.addObserver(self, selector: #selector(changed(_:)), name: Notification.Name(name), object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    @objc private func changed(_ note: Notification) {
        let playing = (note.userInfo?["Player State"] as? String) == "Playing"
        Log.note("music \(playing ? "playing" : "stopped")")
        DispatchQueue.main.async { self.onChange?(playing) }
    }
}

// MARK: - Battery

final class PowerWatcher {
    enum Event { case connected, disconnected, low(Int) }
    private let callback: (Event) -> Void
    private var source: CFRunLoopSource?
    private var onAC: Bool?
    private var warnedAt: Int?

    init(_ callback: @escaping (Event) -> Void) {
        self.callback = callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerWatcher>.fromOpaque(ctx).takeUnretainedValue().check()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
        check(silent: true)
    }

    private func check(silent: Bool = false) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any] else { return }
        let ac = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let percent = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
        if let onAC, onAC != ac, !silent { callback(ac ? .connected : .disconnected) }
        onAC = ac
        if ac { warnedAt = nil; return }
        for level in [10, 5] where percent <= level && (warnedAt ?? 101) > level {
            warnedAt = level
            if !silent || percent <= 10 { callback(.low(percent)) }
            break
        }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}

// MARK: - Calendar

final class CalendarWatcher {
    struct Upcoming {
        let id: String
        let title: String
        let when: String
        let link: URL?
    }

    var onSoon: ((Upcoming) -> Void)?
    private let store = EKEventStore()
    private let timer = OneShot()
    private var alerted: Set<String> = []
    private var granted = false

    func start() {
        let done: (Bool, Error?) -> Void = { [weak self] ok, _ in
            DispatchQueue.main.async {
                Log.note("calendar access \(ok ? "granted" : "denied")")
                guard let self, ok else { return }
                self.granted = true
                NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: self.store, queue: .main) { [weak self] _ in self?.plan() }
                NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.plan()
                }
                self.plan()
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: done)
        } else {
            store.requestAccess(to: .event, completion: done)
        }
    }

    private func events(from: Date, to: Date) -> [EKEvent] {
        guard granted else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).filter { !$0.isAllDay && $0.status != .canceled }.sorted { $0.startDate < $1.startDate }
    }

    /// Sets a timer for the next meeting's ten-minute warning.
    private func plan() {
        let now = Date()
        let coming = events(from: now, to: now.addingTimeInterval(36 * 3600))
        let next = coming.first { !alerted.contains($0.eventIdentifier ?? "") && $0.startDate.timeIntervalSince(now) > 60 }
        guard let next else {
            Log.note("calendar: \(coming.count) events in the next 36 h, none to warn about")
            timer.schedule(after: 3600, wallClock: true) { [weak self] in self?.plan() }
            return
        }
        let fire = next.startDate.addingTimeInterval(-600).timeIntervalSince(now)
        Log.note("calendar: \(coming.count) events in the next 36 h, next warning in \(max(0, Int(fire / 60))) min")
        timer.schedule(after: max(0, min(fire, 3600)), wallClock: true) { [weak self] in
            guard let self else { return }
            let now = Date()
            // Not once it has started (the Mac may have slept through the warning).
            if now >= next.startDate.addingTimeInterval(-605) && now < next.startDate {
                self.alerted.insert(next.eventIdentifier ?? "")
                self.onSoon?(self.upcoming(next))
            }
            self.plan()
        }
    }

    func snooze(_ event: Upcoming, minutes: Double) {
        let t = OneShot()
        t.schedule(after: minutes * 60, wallClock: true) { [weak self] in
            _ = t
            self?.onSoon?(event)
        }
    }

    private func upcoming(_ e: EKEvent) -> Upcoming {
        let f = DateFormatter()
        f.locale = Language.locale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return Upcoming(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? tr("Встреча", "Meeting"), when: f.string(from: e.startDate), link: Self.link(in: e))
    }

    /// A video call link from the event, if it has one.
    private static func link(in e: EKEvent) -> URL? {
        if let url = e.url { return url }
        let text = [e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let found = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
        return found.first { ["zoom.us", "meet.google", "teams.microsoft", "telemost", "facetime"].contains(where: $0.absoluteString.contains) } ?? found.first
    }

    /// Today's meetings as one line, for Claude.
    func todayText() -> String {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let f = DateFormatter()
        f.locale = Language.locale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return events(from: start, to: start.addingTimeInterval(86400)).map { f.string(from: $0.startDate) + " " + ($0.title ?? "") }.joined(separator: "; ")
    }
}

// MARK: - Screenshots

/// Notices a screenshot copied to the clipboard. macOS has no clipboard notification, so the change
/// counter (one cheap number) is read once a second.
final class ClipboardWatcher {
    var onScreenshot: ((NSImage) -> Void)?
    private var timer: DispatchSourceTimer?
    private var last = NSPasteboard.general.changeCount

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(300))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != last else { return }
        last = pb.changeCount
        if let image = ChatController.clipboardScreenshot(pb) { onScreenshot?(image) }
    }
}

/// Watches the screenshot folder and reports new screenshots.
final class ScreenshotWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let folder: URL
    private var seen: Set<String> = []
    private let callback: (URL) -> Void

    init(_ callback: @escaping (URL) -> Void) {
        self.callback = callback
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        folder = URL(fileURLWithPath: (custom.map { ($0 as NSString).expandingTildeInPath }) ?? NSHomeDirectory() + "/Desktop")
        seen = Set(current().map(\.lastPathComponent))
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            // Usually: no permission for the Desktop folder (System Settings → Privacy → Files and Folders).
            Log.note("screenshot folder not readable: errno \(errno)")
            return
        }
        Log.note("watching screenshot folder (\(seen.count) screenshots there)")
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func current() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return names.filter { url in
            let n = url.lastPathComponent
            return ["png", "jpg", "heic"].contains(url.pathExtension.lowercased())
                && (n.hasPrefix("Снимок экрана") || n.hasPrefix("Screenshot") || n.hasPrefix("Screen Shot"))
        }
    }

    private func scan() {
        for url in current() where !seen.contains(url.lastPathComponent) {
            seen.insert(url.lastPathComponent)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if Date().timeIntervalSince(created) < 20 {
                // The file is written in steps; give it a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.callback(url) }
            }
        }
    }

    deinit { source?.cancel() }
}

// MARK: - Services menu

/// Handles "Ask the Ghost" and "Translate with the Ghost" from the Services menu.
final class ServiceProvider: NSObject {
    var ask: ((String) -> Void)?
    var translate: ((String) -> Void)?

    @objc func askGhost(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else { return }
        Log.note("service: ask")
        ask?(text)
    }

    @objc func translateWithGhost(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else { return }
        Log.note("service: translate")
        translate?(text)
    }
}
