import AppKit

/// What Claude Code is doing across all sessions.
enum ClaudeActivity {
    case none, work, wait
}

protocol PetHost: AnyObject {
    var isChatOpen: Bool { get }
    func toggleChat()
    func openSettings()
    func hidePetForAWhile()
    func quit()
    func receivedFiles(_ urls: [URL])
    func chatNote(_ card: Card)
    /// He was moved by hand; `fallDuration` > 0 while he drops back to the Dock.
    func petMoved(fallDuration: TimeInterval)
}

/// Decides what the character does: the steady state for the situation, the rows that lead in and out
/// of it, one-off reactions, strolls, sleep, being carried and dropped. Timing comes from the sheet's
/// frame counts, so the app wakes only when a row ends.
final class PetBrain: PetStageDelegate {
    private let stage: PetStage
    private let prefs: Preferences
    let cards: CardPresenter
    weak var host: PetHost?
    var dock: DockInfo

    // The situation.
    private(set) var asleep = false
    var listening = false { didSet { if listening != oldValue { touch(); settle() } } }
    var talking = false { didSet { if talking != oldValue { settle() } } }
    var thinking = false { didSet { if thinking != oldValue { touch(); settle() } } }
    var music = false { didSet { if music != oldValue { settle() } } }
    var claude: ClaudeActivity = .none {
        didSet {
            guard claude != oldValue else { return }
            if claude != .none { wake() }
            settle()
        }
    }
    private var sadUntil = Date.distantPast

    private enum Movement { case none, walking, held, falling }
    private var movement = Movement.none
    private(set) var base: String?
    private var act: (name: String, base: String?, next: [String])?
    private let actEnd = OneShot()
    private let sadEnd = OneShot()
    private let strollTimer = OneShot()
    private let sleepTimer = OneShot()
    private let returnCheck = OneShot()
    /// Asleep because nobody touched the Mac for a while: the next mouse move or key press wakes him.
    /// Put to bed from the menu, he sleeps until clicked.
    private var dozedOff = false

    /// He dozes off after this long without mouse or keyboard input anywhere on the Mac.
    static var sleepAfter: TimeInterval = 300

    /// Seconds since the last mouse or keyboard input on the Mac. Needs no permission.
    static var idleTime: TimeInterval {
        idleOverride?() ?? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    /// For DevTools: pretend nobody is at the Mac.
    static var idleOverride: (() -> TimeInterval?)?
    private let exits: Set<String> = ["work_out", "wake"]

    init(stage: PetStage, prefs: Preferences, dock: DockInfo) {
        self.stage = stage
        self.prefs = prefs
        self.dock = dock
        cards = CardPresenter(stage: stage)
        stage.delegate = self
        cards.onChange = { [weak self] in self?.settle() }
    }

    private var skin: Skin? { stage.skin }

    // MARK: - Choosing rows

    private func baseState() -> String {
        if asleep { return "sleep" }
        if listening { return "listen" }
        if talking { return "talk" }
        if thinking { return "think" }
        if sadUntil > Date() { return "error" }
        if cards.current?.call == true { return "call" }
        if cards.current?.hold == true { return "wait" }
        switch claude {
        case .wait: return "wait"
        case .work: return "work"
        case .none: return music ? "music" : "idle"
        }
    }

    /// The loop row for a state, with stand-ins when the sheet lacks a row.
    private func loopRow(_ state: String) -> String {
        let fallbacks: [String: [String]] = [
            "listen": ["listen", "wait", "idle"], "music": ["music", "idle"], "call": ["call", "wait", "wave", "idle"],
            "talk": ["talk", "idle"], "think": ["think", "wait", "idle"], "work": ["work", "think", "idle"],
            "wait": ["wait", "idle"], "error": ["error", "idle"], "sleep": ["sleep", "idle"], "idle": ["idle"],
        ]
        return (fallbacks[state] ?? [state, "idle"]).first(where: { skin?.has($0) == true }) ?? "idle"
    }

    private func transitions(from: String, to: String) -> [String] {
        var seq: [String] = []
        if from == "sleep" && to != "sleep" { seq.append("wake") }
        if from == "work" && to != "work" { seq.append("work_out") }
        if to == "sleep" && from != "sleep" { seq.append("sleep_in") }
        if to == "work" && from != "work" { seq.append("work_in") }
        if to == "error" && from != "error" { seq.append("error_in") }
        return seq.filter { skin?.has($0) == true }
    }

    /// Brings the character to the steady state for the current situation.
    func settle() {
        recoverIfStuck()
        // A stroll is the least important thing he does: anything else that comes up stops it.
        if movement == .walking, !["idle", "music"].contains(baseState()) {
            stopWalking()
            return
        }
        guard movement == .none, skin != nil else { return }
        // A one-off reaction finishes first; it settles when it ends.
        if let act, act.base == nil, actEnd.isPending { return }
        let target = baseState()
        if let act, act.base == target { return }
        let seq = transitions(from: base ?? "idle", to: target) + [loopRow(target)]
        base = target
        if let act, exits.contains(act.name), actEnd.isPending {
            self.act = (act.name, target, seq.filter { !exits.contains($0) })
            return
        }
        start(seq, base: target)
        scheduleCalm()
    }

    private func start(_ seq: [String], base: String?) {
        guard let first = seq.first else { act = nil; return }
        let rest = Array(seq.dropFirst())
        guard let row = skin?[first] else { start(rest, base: base); return }
        Log.debug("row \(first) (base \(base ?? "-"), then \(rest))")
        act = (first, base, rest)
        stage.show(row, loop: row.loop)
        if row.loop {
            actEnd.cancel()
        } else {
            actEnd.schedule(after: row.duration) { [weak self] in self?.rowEnded() }
        }
    }

    private func rowEnded() {
        guard let act else { return }
        if !act.next.isEmpty {
            start(act.next, base: act.base)
        } else {
            self.act = nil
            settle()
        }
    }

    /// A one-off reaction over whatever he was doing. Looping rows play for `duration`.
    /// Which one-off wins when two meet. Events the user caused or should notice (charger, a finished
    /// task, a caught file) outrank a landing or joy, and those outrank a greeting.
    private static func priority(_ name: String) -> Int {
        switch name {
        case "charge_on", "charge_off", "done", "catch": return 3
        case "land", "happy": return 2
        default: return 1
        }
    }

    /// A reaction that came while he was held or falling; it plays once he is down.
    private var queued: (name: String, duration: TimeInterval?)?

    func react(_ name: String, duration: TimeInterval? = nil) {
        guard let row = skin?[name] else { return }
        if asleep && name != "wave" { return }
        switch movement {
        case .held, .falling:
            if queued == nil || Self.priority(name) >= Self.priority(queued!.name) { queued = (name, duration) }
            return
        case .walking:
            // He stops running for it.
            stopWalking()
        case .none:
            break
        }
        // A more important reaction that is still playing is not cut short by a lesser one.
        if let act, act.base == nil, actEnd.isPending, Self.priority(act.name) > Self.priority(name) {
            Log.debug("react \(name) skipped, \(act.name) is playing")
            return
        }
        Log.debug("react \(name)")
        act = (name, nil, [])
        stage.show(row, loop: row.loop)
        actEnd.schedule(after: duration ?? (row.loop ? 1.6 : row.duration)) { [weak self] in
            guard let self else { return }
            self.act = nil
            if let next = self.queued {
                self.queued = nil
                self.react(next.name, duration: next.duration)
            } else {
                self.settle()
            }
        }
    }

    private var isCalm: Bool {
        movement == .none && act?.base != nil && (base == "idle" || base == "music") && cards.current == nil && host?.isChatOpen != true
    }

    // MARK: - Sleep and strolls

    func touch() {
        scheduleCalm()
    }

    private func scheduleCalm() {
        scheduleSleepCheck()
        if (base == "idle" || base == "music") && !strollTimer.isPending {
            scheduleStroll()
        }
    }

    /// Rests between walks: usually a couple of seconds, now and then a little longer.
    private func scheduleStroll(after delay: TimeInterval? = nil) {
        let rest = delay ?? (Double.random(in: 0..<1) < 0.2 ? .random(in: 8...14) : .random(in: 2...6))
        strollTimer.schedule(after: rest) { [weak self] in self?.stroll() }
    }

    /// One timer, set for the moment the Mac would reach the idle limit; it wakes the app about once
    /// every five minutes while the user is around.
    private func scheduleSleepCheck(after delay: TimeInterval? = nil) {
        guard !asleep, !sleepTimer.isPending else { return }
        let wait = delay ?? max(5, Self.sleepAfter - Self.idleTime + 1)
        sleepTimer.schedule(after: wait) { [weak self] in self?.sleepCheck() }
    }

    /// Sets the sleep check again, for a changed idle limit.
    func restartSleepCheck() {
        sleepTimer.cancel()
        scheduleSleepCheck()
    }

    private func sleepCheck() {
        guard !asleep else { return }
        Log.debug("sleep check: idle \(Int(Self.idleTime)) s, calm \(isCalm), base \(base ?? "-")")
        guard Self.idleTime >= Self.sleepAfter else { scheduleSleepCheck(); return }
        // Nobody around, but something is going on (Claude working, a card, the chat, music): look later.
        guard isCalm, base == "idle", claude == .none else { scheduleSleepCheck(after: 30); return }
        Log.debug("no input for \(Int(Self.idleTime)) s, dozing off")
        setAsleep(true, dozing: true)
    }

    /// While he dozes, a cheap look at the idle counter every second and a half; the first input wakes him.
    private func watchForReturn() {
        returnCheck.schedule(after: 1.5) { [weak self] in
            guard let self, self.asleep, self.dozedOff else { return }
            if Self.idleTime < 2 {
                Log.debug("input again, waking")
                self.setAsleep(false)
            } else {
                self.watchForReturn()
            }
        }
    }

    func setAsleep(_ value: Bool, dozing: Bool = false) {
        guard value != asleep else { return }
        asleep = value
        dozedOff = value && dozing
        if value {
            sleepTimer.cancel()
            cards.hide()
            sadUntil = .distantPast
            if dozedOff { watchForReturn() }
        } else {
            returnCheck.cancel()
            scheduleStroll(after: 4)
        }
        settle()
    }

    /// A walk cut short without the brain hearing of it would leave him running on the spot for good.
    @discardableResult
    private func recoverIfStuck() -> Bool {
        guard movement == .walking, !stage.isMoving else { return false }
        Log.debug("walk was cut short, standing again")
        movement = .none
        act = nil
        return true
    }

    func wake() {
        if asleep { setAsleep(false) }
        touch()
    }

    private func stroll() {
        if recoverIfStuck() { settle() }
        let again = { [weak self] in self?.scheduleStroll() }
        // Not while the cursor rests on him: he would only run off from under it.
        guard prefs.strolls, !DevTools.scripted, isCalm, skin != nil, !stage.mouseIsOver, let window = stage.window else {
            // Walking reschedules on arrival, waking up restarts strolls.
            if movement != .walking && !asleep { again() }
            return
        }
        let half = stage.spriteSize.width / 2
        let lo = dock.minX - window.frame.minX + half
        let hi = dock.maxX - window.frame.minX - half
        guard hi > lo else { again(); return }
        // Mostly short hops, sometimes a longer run, rarely across half the Dock.
        let roll = Double.random(in: 0..<1)
        let distance: CGFloat = roll < 0.6 ? .random(in: 50...200) : roll < 0.9 ? .random(in: 200...420) : .random(in: 420...700)
        let here = stage.centerX.clamped(lo, hi)
        var right = Bool.random()
        if right && hi - here < 50 { right = false } else if !right && here - lo < 50 { right = true }
        let target = (right ? here + distance : here - distance).clamped(lo, hi)
        guard abs(target - stage.centerX) >= 40 else { again(); return }
        walk(to: target) { again() }
    }

    /// Walks somewhere along the Dock, then goes back to the steady state.
    func walk(to x: CGFloat, then: (() -> Void)? = nil) {
        guard let skin else { return }
        let right = x > stage.centerX
        guard let row = skin[right ? "walk_right" : "walk_left"] ?? skin["walk_right"] ?? skin["walk_left"] else { then?(); return }
        movement = .walking
        actEnd.cancel()
        act = (row.name, nil, [])
        stage.show(row, loop: true)
        // The row he will stand in on arrival, so the switch happens on time without the app.
        let arrive = skin[loopRow(baseState())]
        let started = Date()
        Log.debug("walk \(Int(abs(x - stage.centerX))) pt, \(String(format: "%.1f", Double(abs(x - stage.centerX)) / prefs.walkSpeed)) s")
        stage.walk(to: x, speed: CGFloat(prefs.walkSpeed), arrive: arrive) { [weak self] in
            guard let self else { return }
            Log.debug("arrived after \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            self.movement = .none
            self.act = nil
            self.settle()
            then?()
        }
    }

    /// Stops a walk where he is now; he stands in the steady state.
    func stopWalking() {
        guard movement == .walking else { return }
        stage.stopMoving()
        movement = .none
        act = nil
        settle()
    }

    /// Keeps him on the Dock after the Dock or the screen changed.
    func clampToDock() {
        guard movement == .none, let window = stage.window else { return }
        let half = stage.spriteSize.width / 2
        let lo = dock.minX - window.frame.minX + half
        let hi = max(lo, dock.maxX - window.frame.minX - half)
        let x = stage.centerX
        if x < lo || x > hi || x == 0 { stage.place(x: x == 0 ? hi : x.clamped(lo, hi)) }
        cards.position()
    }

    // MARK: - Events

    /// A number over his head while several Claude Code sessions are busy; 0 hides it.
    func setBadge(_ count: Int) {
        stage.setBadge(count)
    }

    func upset(for seconds: TimeInterval = 5.6) {
        wake()
        sadUntil = Date().addingTimeInterval(seconds)
        sadEnd.schedule(after: seconds + 0.05) { [weak self] in self?.settle() }
        settle()
    }

    /// Shows a card, or puts it into the chat while the chat is open.
    func notify(_ card: Card) {
        if host?.isChatOpen == true {
            host?.chatNote(card)
            return
        }
        wake()
        cards.show(card)
    }

    // MARK: - PetStageDelegate

    func stagePressed() {
        switch movement {
        case .walking:
            // Stopped mid-walk: he stands where he is, as after arriving.
            stopWalking()
        case .falling:
            // Caught in the air: he hangs from the cursor until let go.
            stage.stopMoving()
            movement = .held
            if let row = skin?["held"] ?? skin?["fall"] {
                act = (row.name, nil, [])
                stage.show(row, loop: true)
            }
        case .none, .held:
            break
        }
    }

    func stageClicked() {
        // Caught in the air and let go without dragging: he falls on.
        if movement == .held { stageDropped(); return }
        touch()
        host?.toggleChat()
    }

    /// The cursor is on him. He waves only as a greeting when the Mac starts or wakes, never on hover;
    /// on the run he stops and stands.
    func stageHovered() {
        if movement == .walking { stopWalking() }
    }

    func stageDragBegan() {
        touch()
        actEnd.cancel()
        strollTimer.cancel()
        cards.hide()
        if asleep { asleep = false; dozedOff = false; returnCheck.cancel(); base = nil }
        movement = .held
        if let row = skin?["held"] ?? skin?["fall"] {
            act = (row.name, nil, [])
            stage.show(row, loop: true)
        }
    }

    func stageCarried() {
        host?.petMoved(fallDuration: 0)
    }

    func stageDropped() {
        movement = .falling
        if let row = skin?["fall"] { stage.show(row, loop: true) }
        let duration = stage.fall { [weak self] in
            guard let self else { return }
            self.movement = .none
            self.act = nil
            self.clampToDock()
            self.host?.petMoved(fallDuration: 0)
            if self.skin?.has("land") == true {
                // Anything that came while he was in the air plays after the landing.
                self.react("land")
            } else if let next = self.queued {
                self.queued = nil
                self.react(next.name, duration: next.duration)
            } else {
                self.settle()
            }
            self.scheduleStroll()
        }
        host?.petMoved(fallDuration: duration)
    }

    func stageMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(title: "Поговорить") { [weak self] in self?.host?.toggleChat() })
        menu.addItem(ActionMenuItem(title: asleep ? "Разбудить" : "Уложить спать") { [weak self] in
            guard let self else { return }
            self.setAsleep(!self.asleep)
        })
        menu.addItem(ActionMenuItem(title: "Спрятаться на 10 минут") { [weak self] in self?.host?.hidePetForAWhile() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Настройки…") { [weak self] in self?.host?.openSettings() })
        menu.addItem(ActionMenuItem(title: "Выйти") { [weak self] in self?.host?.quit() })
        return menu
    }

    func stageReceivedFiles(_ urls: [URL]) {
        wake()
        host?.receivedFiles(urls)
        react("catch")
    }

    func stageFileHover(_ inside: Bool) {
        // A file dragged over him: he waits for it (no reaction until it is dropped, then "catch").
        if inside { stopWalking() }
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
