import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, PetHost {
    let prefs = Preferences(store: DevTools.isolated ? UserDefaults(suiteName: "app.dockling.Dockling.test")! : .standard)
    let loginItem = LoginItem()
    let hookInstaller = HookInstaller()
    private var petPanel: PetPanel!
    private(set) var stage: PetStage!
    private(set) var brain: PetBrain!
    private(set) var chat: ChatController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem?
    private var integrations: Integrations?
    private var bag = Set<AnyCancellable>()
    private let relayout = OneShot()
    private let comeBack = OneShot()
    /// Hidden from the menu ("Hide for 10 Minutes", or the menu bar icon).
    private var userHidden = false
    /// A full-screen app covers his screen: he steps aside, as the Dock does.
    private(set) var away = false
    private let fullScreenCheck = OneShot()
    private let fullScreenRecheck = OneShot()
    /// Counts Space changes, so a newer one ends the quick checks of an older one.
    private var spaceChanges = 0
    private var appearanceWatch: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.echo = CommandLine.arguments.contains("--log")
        // One pet is enough: a second copy hands over to the first and leaves.
        let mine = ProcessInfo.processInfo.processIdentifier
        if !DevTools.isolated, NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != mine }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        PixelFont.register()
        if let dir = DevTools.value(after: "--skin") { Skin.overrideFolder = URL(fileURLWithPath: dir) }
        try? hookInstaller.writeScript()

        petPanel = PetPanel()
        stage = PetStage(frame: .zero)
        stage.autoresizingMask = [.width, .height]
        petPanel.contentView = stage
        brain = PetBrain(stage: stage, prefs: prefs, dock: DockGeometry.current())
        brain.host = self
        brain.cards.look = { [unowned self] in (self.prefs.isDark, self.prefs.transparency) }
        chat = ChatController(prefs: prefs, brain: brain, stage: stage)
        chat.onLimits = { [unowned self] limits in self.chat.warnAboutLimits(limits, brain: self.brain) }
        Reminders.shared.fire = { [unowned self] text in self.remind(text) }
        settings = SettingsWindowController(app: self)

        stage.setScale(x: prefs.scaleX, y: prefs.scaleY)
        stage.setSkin(Skin.load())
        layout(initial: true)
        // Started while a full-screen app fills his screen: he waits for it to end.
        if !updateAway() { petPanel.orderFrontRegardless() }
        brain.settle()
        // The one greeting besides waking from sleep: when he starts with the Mac.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.brain.react("wave", duration: 1.5) }

        watch()
        updateStatusItem()
        // The README showcase runs with nothing real coming in: no hooks, calendar, music or watchers.
        if DevTools.showcase == nil {
            integrations = Integrations(app: self)
            integrations?.start()
        }

        if !DevTools.isolated { loginItem.ensure() }
        Log.debug("dock \(brain.dock) panel \(petPanel.frame) floor \(stage.floorY) sprite \(stage.spriteSize) x \(stage.centerX)")
        DevTools.run(self)
    }

    /// Opening the app again (from Applications, Spotlight or Launchpad) while it runs shows the settings;
    /// with the menu bar icon off this is the other way in besides his right-click menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: - Layout

    /// Puts the strip over the Dock's screen and the character on the Dock.
    func layout(initial: Bool = false) {
        // In full screen the Dock is hidden and the screen's areas change; he keeps his place meanwhile.
        if !initial, updateAway() { return }
        let old = brain.dock
        let dock = DockGeometry.current()
        let movedScreen = !initial && old.screen != dock.screen
        // Where along the Dock he stood, from 0 at its left end to 1 at its right end.
        let along = old.maxX > old.minX ? ((petPanel.frame.minX + stage.centerX - old.minX) / (old.maxX - old.minX)).clamped(0, 1) : 0.5
        if movedScreen {
            Log.debug("dock moved to screen \(dock.screen)")
            brain.stopWalking()
        }
        brain.dock = dock
        let height = min(dock.screen.height, dock.floorY - dock.screen.minY + 480)
        let strip = CGRect(x: dock.screen.minX, y: dock.screen.minY, width: dock.screen.width, height: height)
        // Left alone when nothing changed: touching the window can bring it onto a full-screen Space.
        if petPanel.frame != strip { petPanel.setFrame(strip, display: false) }
        stage.frame = petPanel.contentView?.bounds ?? .zero
        stage.setFloor(dock.floorY - dock.screen.minY)
        if initial {
            stage.place(x: dock.maxX - dock.screen.minX - stage.spriteSize.width / 2 - 30)
        } else if movedScreen {
            // Same spot on the Dock, now on the other display.
            stage.place(x: dock.minX + (dock.maxX - dock.minX) * along - dock.screen.minX)
            brain.settle()
        }
        brain.clampToDock()
        brain.cards.position()
        chat.reposition()
        dockSignature = Self.dockSignature()
    }

    private func scheduleLayout() {
        relayout.schedule(after: 0.4) { [weak self] in self?.layout() }
    }

    // The Dock can move to another display without any notice to apps. With two or more displays a
    // cheap look every two seconds (one window lookup) catches it; with one display nothing runs.
    private var dockWatch: DispatchSourceTimer?
    private var dockSignature = ""

    private static func dockSignature() -> String {
        let inset = NSScreen.screens.first { $0.visibleFrame.minY - $0.frame.minY > 20 }?.displayID
        return "\(inset.map(String.init) ?? "-")/\(DockGeometry.dockDisplay().map(String.init) ?? "-")"
    }

    private func updateDockWatch() {
        guard NSScreen.screens.count > 1 else {
            dockWatch?.cancel()
            dockWatch = nil
            return
        }
        guard dockWatch == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, Self.dockSignature() != self.dockSignature else { return }
            self.layout()
            // The screens' usable areas can lag a moment behind the Dock itself.
            self.relayout.schedule(after: 1.2) { [weak self] in self?.layout() }
        }
        timer.resume()
        dockWatch = timer
    }

    private func watch() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleLayout()
            self?.updateDockWatch()
        }
        updateDockWatch()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleLayout() }
        }
        // Going full screen, or swiping to a full-screen app, changes the Space; a game can also cover
        // the screen when it starts.
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.spaceChanged() }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.scheduleFullScreenCheck() }
        prefs.$scaleX.combineLatest(prefs.$scaleY).dropFirst().sink { [weak self] x, y in
            guard let self else { return }
            self.stage.setScale(x: x, y: y)
            self.brain.clampToDock()
            self.chat.reposition()
        }.store(in: &bag)
        prefs.$theme.combineLatest(prefs.$transparency).dropFirst().sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.restyle() }
        }.store(in: &bag)
        prefs.$showMenuBarIcon.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &bag)
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.restyle() }
        }
    }

    private func restyle() {
        chat.restyle()
        brain.cards.restyle()
    }


    // MARK: - Menu bar

    private func updateStatusItem() {
        if prefs.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = StatusIcon.image()
            let menu = NSMenu()
            menu.addItem(ActionMenuItem(title: tr("Поговорить", "Chat")) { [weak self] in self?.chat.open() })
            menu.addItem(ActionMenuItem(title: tr("Показать или спрятать", "Show or Hide")) { [weak self] in self?.togglePet() })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: tr("Настройки…", "Settings…")) { [weak self] in self?.openSettings() })
            menu.addItem(ActionMenuItem(title: tr("Выйти", "Quit")) { [weak self] in self?.quit() })
            item.menu = menu
            statusItem = item
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func togglePet() {
        if userHidden {
            userHidden = false
            comeBack.cancel()
            showPet()
        } else {
            userHidden = true
            putAway()
        }
    }

    /// Out of sight: the chat closes, and Claude Code asks its open questions in its own dialog.
    private func putAway() {
        chat.close()
        integrations?.releaseClaudeQuestions()
        petPanel.orderOut(nil)
    }

    private func showPet() {
        guard !userHidden, !away else { return }
        petPanel.orderFrontRegardless()
    }

    // MARK: - Full screen

    /// macOS reports a Space change once the switch is over, and the window list shows a full-screen
    /// app about 0.2 s later. So it is looked at every 50 ms for up to 1.5 s, and he is gone as soon as
    /// it shows; going back to the desktop brings him back at once.
    private func spaceChanged() {
        spaceChanges += 1
        let mine = spaceChanges
        let wasAway = away
        func look(_ n: Int) {
            guard mine == spaceChanges else { return }
            if updateAway() != wasAway || n == 0 { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { look(n - 1) }
        }
        look(30)
    }

    /// An app came to the front: it may fill the screen without a Space of its own (some games).
    private func scheduleFullScreenCheck() {
        fullScreenCheck.schedule(after: 0.3) { [weak self] in _ = self?.updateAway() }
        fullScreenRecheck.schedule(after: 1.2) { [weak self] in _ = self?.updateAway() }
    }

    /// Steps aside while a full-screen app covers his screen and comes back after; returns `away`.
    @discardableResult
    private func updateAway() -> Bool {
        guard DevTools.showcase == nil else { return false }
        let covered = FullScreen.covers(brain.dock.screen)
        Log.debug("full-screen check on \(brain.dock.screen): \(covered ? "covered" : "clear")")
        guard covered != away else { return away }
        away = covered
        if covered {
            Log.note("full screen on his screen: stepping aside")
            brain.stepAside()
            putAway()
        } else {
            Log.note("full screen ended: back on the Dock")
            layout()
            showPet()
            brain.comeBack()
        }
        return away
    }

    // MARK: - PetHost

    var isChatOpen: Bool { chat.isOpen }
    func toggleChat() { chat.toggle() }
    func openSettings() { settings.show() }
    func quit() { NSApp.terminate(nil) }
    func receivedFiles(_ urls: [URL]) { chat.attachFiles(urls) }
    func chatNote(_ card: Card) { chat.note(card) }
    func petMoved(fallDuration: TimeInterval) { chat.follow(fallDuration: fallDuration) }

    func hidePetForAWhile() {
        userHidden = true
        putAway()
        comeBack.schedule(after: 600) { [weak self] in
            self?.userHidden = false
            self?.showPet()
        }
    }

    var petVisible: Bool { petPanel.isVisible }

    // MARK: - Reminders

    private func remind(_ text: String) {
        let title = text.prefix(1).uppercased() + text.dropFirst()
        var card = Card(icon: .clock, color: Card.violet, text: title, hold: true, call: true, tag: "reminder")
        card.duration = 14
        card.actions = [
            CardAction(title: tr("Готово", "Done"), primary: true) { [weak self] in self?.brain.react("happy", duration: 1.7) },
            CardAction(title: tr("Позже", "Later")) { Reminders.shared.add(after: 300, text: text) },
        ]
        brain.notify(card)
    }
}

/// The menu bar icon: a small pixel speech bubble, drawn as a template so it follows the menu bar colour.
enum StatusIcon {
    static func image() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let cells: [(Int, Int, Int, Int)] = [
                (2, 3, 14, 1), (1, 4, 1, 7), (16, 4, 1, 7), (2, 11, 14, 1), (4, 12, 2, 1), (4, 13, 1, 1),
                (5, 7, 2, 2), (8, 7, 2, 2), (11, 7, 2, 2),
            ]
            for (x, y, w, h) in cells { NSRect(x: x, y: y, width: w, height: h).fill() }
            return true
        }
        img.isTemplate = true
        return img
    }
}
