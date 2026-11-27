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
    private let dockWatch = DockWatch()
    private let comeBack = OneShot()
    /// Hidden from the menu ("Hide for 10 Minutes", or the menu bar icon).
    private var userHidden = false
    /// A full-screen Space is showing on his screen: he is out of sight on his desktop, as the Dock is.
    private(set) var away = false
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
        chat.onCodexLimits = { [unowned self] limits in self.chat.warnAboutCodexLimits(limits, brain: self.brain) }
        Reminders.shared.fire = { [unowned self] text in self.remind(text) }
        settings = SettingsWindowController(app: self)

        stage.setScale(x: prefs.scaleX, y: prefs.scaleY)
        stage.setSkin(Skin.load())
        refresh(initial: true)
        if DevTools.showcase == nil { dockWatch.onMove = { [weak self] in self?.refresh() } }
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
    func applicationWillTerminate(_ notification: Notification) {
        chat?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: - Where he is

    /// The one place that decides where he is: on the Dock's display, on the desktop it shows.
    ///
    /// He belongs to a desktop like any window (see `PetPanel`), so swipes to a full-screen app and
    /// back carry him with the desktop, and nothing here hides or shows him for that. What is left:
    /// while a full-screen Space shows on his screen he is "away" (no strolls, cards wait, Claude Code
    /// asks in its own dialog); when a desktop shows he stands on the Dock there, brought over if he
    /// was on another desktop; when the Dock went to another display he dives below the edge and
    /// comes up on the Dock there.
    func refresh(initial: Bool = false) {
        let old = brain.dock
        let dock = DockGeometry.current()
        let moved = !initial && dock.screen != old.screen
        let fullScreen = DevTools.showcase == nil && FullScreen.isShowing(on: dock.screen)
        setAway(fullScreen)
        // In front of the user right now: shown, and on the Space his screen is showing.
        let inSight = petPanel.isVisible && petPanel.isOnActiveSpace
        Log.debug("refresh: Dock on \(dock.screen.origin), was \(old.screen.origin), full screen \(fullScreen), in sight \(inSight)")
        if moved {
            brain.stopWalking()
            if inSight {
                // Down below the edge first; from there this runs again and finds him out of sight.
                if !stage.isDiving {
                    stage.dive { [weak self] in
                        self?.petPanel.orderOut(nil)
                        self?.refresh()
                    }
                }
                return
            }
            Log.note("followed the Dock to the display at \(Int(dock.screen.minX)),\(Int(dock.screen.minY))")
        } else if fullScreen && !initial {
            // He waits on his desktop. Only if he is on this very Space does he leave it.
            if inSight { petPanel.orderOut(nil) }
            return
        }

        // Where along the Dock he stood, from 0 at its left end to 1 at its right end.
        let along = old.maxX > old.minX ? ((petPanel.frame.minX + stage.centerX - old.minX) / (old.maxX - old.minX)).clamped(0, 1) : 0.5
        brain.dock = dock
        if DevTools.showcase == nil { dockWatch.dockScreen = dock.screen }
        let height = min(dock.screen.height, dock.floorY - dock.screen.minY + 480)
        let strip = CGRect(x: dock.screen.minX, y: dock.screen.minY, width: dock.screen.width, height: height)
        if petPanel.frame != strip { petPanel.setFrame(strip, display: false) }
        stage.frame = petPanel.contentView?.bounds ?? .zero
        stage.setFloor(dock.floorY - dock.screen.minY)
        let show = !fullScreen && !userHidden
        if initial {
            stage.place(x: dock.maxX - dock.screen.minX - stage.spriteSize.width / 2 - 30)
        } else if moved {
            // The same spot along the Dock, now on the other display.
            let x = dock.minX + (dock.maxX - dock.minX) * along - dock.screen.minX
            if show { stage.surface(at: x) } else { stage.place(x: x) }
            brain.settle()
        }
        // Onto the desktop his screen shows, if he is not there already.
        if show && !inSight { petPanel.orderFrontRegardless() }
        brain.clampToDock()
        brain.cards.position()
        chat.reposition()
    }

    private func setAway(_ value: Bool) {
        guard value != away else { return }
        away = value
        if value {
            Log.note("full screen on his screen: stepping aside")
            brain.stepAside()
            chat.close()
            integrations?.releaseClaudeQuestions()
        } else {
            Log.note("full screen ended: back on the Dock")
            brain.comeBack()
        }
    }

    /// For changes that come in bursts or settle a moment later (screens, the Dock's width, a Space).
    private func scheduleRefresh() {
        relayout.schedule(after: 0.4) { [weak self] in self?.refresh() }
    }

    /// macOS reports a Space change when the switch is over, and the window server already knows what
    /// each display shows then. One more look shortly after covers a late update. (His window can only
    /// be brought to the new desktop from here on: macOS moves it to the Space it has announced.)
    private func spaceChanged() {
        if FullScreen.exact { refresh() }
        scheduleRefresh()
    }

    private func watch() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
            self?.dockWatch.screensChanged()
        }
        let ws = NSWorkspace.shared.notificationCenter
        // Apps starting and quitting make the Dock wider or narrower.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() }
        }
        // A swipe to another desktop or to a full-screen app, or an app going full screen.
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.spaceChanged() }
        if DevTools.isolated {
            // Development: move his Dock while running, as if the real one moved
            // (post app.dockling.Dockling.devDock with object "main" or "external").
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.dockling.Dockling.devDock"), object: nil, queue: .main) { [weak self] note in
                DockGeometry.devDisplay = note.object as? String
                self?.refresh()
            }
        }
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
            refresh()
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
            self?.refresh()
        }
    }

    var petVisible: Bool { petPanel.isVisible && !away }

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
