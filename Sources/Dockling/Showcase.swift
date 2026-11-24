import AppKit

/// `--showcase <folder>`: the pictures and the animation for the README, made from the real app.
///
/// A backdrop window of our own (a plain gradient and a Dock shelf with Apple's apps) covers the area
/// that is captured, so nothing of the real screen gets in. Claude Code hooks, the calendar, music,
/// the clipboard and the screenshot watcher stay off, and every text in the pictures is made up here.
/// Saved settings are not changed: themes are previewed, the scale is set on the stage only.
enum Showcase {
    static func run(_ app: AppDelegate, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let brain = app.brain!
        let stage = app.stage!
        guard let window = stage.window, let screen = window.screen else { return }
        let at: (Double, @escaping () -> Void) -> Void = { t, f in DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        let dock = brain.dock
        let speed = max(20, app.prefs.walkSpeed)

        stage.setScale(x: 1, y: 1)
        brain.clampToDock()
        let sprite = stage.spriteSize
        // Global x of the walk: from the right of the Dock's middle to the left of it.
        let middle = (dock.minX + dock.maxX) / 2
        let startX = middle + 150, endX = middle - 170
        stage.place(x: startX - window.frame.minX)

        let back = Backdrop(dock: dock, screen: screen.frame)
        back.order(.below, relativeTo: window.windowNumber)

        app.chat.model.limits = PlanLimits(session: 23, week: 41,
                                           sessionReset: Date().addingTimeInterval(2 * 3600 + 14 * 60),
                                           weekReset: Date().addingTimeInterval(3 * 86400 + 5 * 3600))
        let conversation = [
            ChatMessage(role: .me, text: "Как по-английски «руки не доходят»?"),
            ChatMessage(role: .bot, text: "I haven't gotten around to it. Например: I still haven't gotten around to the README."),
            ChatMessage(role: .me, text: "Сколько секунд в неделе?"),
            ChatMessage(role: .bot, text: "604 800."),
        ]

        // The animation: everything happens between the right end of the walk and a chat that opens
        // above the left end, so the region is fixed before the recording starts.
        let chatW: CGFloat = 348, chatH: CGFloat = 352
        let floor = dock.floorY
        let movie = CGRect(x: endX - chatW / 2 - 36, y: screen.frame.minY,
                           width: (startX + sprite.width / 2 + 60) - (endX - chatW / 2 - 36),
                           height: floor - screen.frame.minY + sprite.height + 10 + chatH + 24)
        Log.debug("showcase: movie region \(movie)")
        let walkTime = Double(abs(startX - endX) / speed)

        var t = 1.5
        let movieSeconds = (24 + walkTime).rounded(.up)
        let movieEnd = t + movieSeconds
        at(t) { record(movie, seconds: movieSeconds, to: dir.appendingPathComponent("tour.mov")) }
        t += 1.0; at(t) { brain.react("wave", duration: 1.5) }
        t += 2.4; at(t) { brain.walk(to: endX - window.frame.minX) }
        t += walkTime + 0.8; at(t) { brain.claude = .work }
        t += 4.0; at(t) {
            brain.claude = .none
            brain.notify(Card(icon: .done, color: Card.green, text: "Тесты прошли: 42 из 42", meta: "Monobrow · 3 мин",
                              actions: [CardAction(title: "Открыть", primary: true) {}], duration: 3.6))
        }
        t += 4.6; at(t) { brain.stagePressed(); brain.stageDragBegan() }
        for i in 1...8 {
            at(t + 0.05 * Double(i)) { stage.sprite.position.y += 16; brain.stageCarried() }
        }
        t += 1.2; at(t) { brain.stageDropped() }
        t += 2.2; at(t) {
            app.chat.model.messages = conversation
            app.chat.open()
            app.chat.previewGlass(dark: true, transparency: app.prefs.transparency)
        }
        // While a recording runs macOS dims the screen around it, so the stills wait for it to end.
        t = max(t + 4.5, movieEnd + 1.2)

        // Still pictures: the chat in both themes, then the cards, then the settings window.
        let chatRegion = { () -> CGRect in
            let c = app.chat.panelFrame ?? .zero
            return CGRect(x: c.minX - 40, y: screen.frame.minY, width: c.width + 80, height: c.maxY + 24 - screen.frame.minY)
        }
        at(t) { shoot(chatRegion(), to: dir.appendingPathComponent("chat-dark.png")) }
        t += 0.6; at(t) { app.chat.previewGlass(dark: false, transparency: app.prefs.transparency) }
        t += 0.8; at(t) { shoot(chatRegion(), to: dir.appendingPathComponent("chat-light.png")) }
        t += 0.4; at(t) { app.chat.close() }

        let cardRegion = { () -> CGRect in
            let x = stage.centerX + window.frame.minX
            return CGRect(x: x - 210, y: screen.frame.minY, width: 420, height: floor - screen.frame.minY + sprite.height + 96)
        }
        t += 1.0; at(t) {
            brain.claude = .wait
            brain.cards.setStanding(Card(icon: .lock, color: Card.amber, text: "npm test", meta: "Bash · Monobrow", mono: true,
                                         actions: [CardAction(title: "Разрешить", primary: true) {}, CardAction(title: "Отклонить") {}],
                                         sticky: true, hold: true, tag: "cc-question"))
        }
        t += 1.6; at(t) { shoot(cardRegion(), to: dir.appendingPathComponent("card-permission.png")) }
        t += 0.4; at(t) {
            brain.cards.setStanding(nil)
            brain.claude = .none
            brain.notify(Card(icon: .calendar, color: Card.blue, text: "Созвон через 10 минут", meta: "Планирование, 15:00",
                              actions: [CardAction(title: "Открыть", primary: true) {}, CardAction(title: "Позже") {}], duration: 6))
        }
        t += 1.6; at(t) { shoot(cardRegion(), to: dir.appendingPathComponent("card-meeting.png")) }
        t += 0.4; at(t) { brain.cards.hide(); app.openSettings() }
        t += 2.0; at(t) {
            for w in NSApp.windows where w.isVisible && w.title == "Dockling" {
                capture(["-o", "-l", String(w.windowNumber)], to: dir.appendingPathComponent("settings.png"))
            }
        }
        t += 1.0; at(t) { back.orderOut(nil); Log.debug("showcase: end"); NSApp.terminate(nil) }
    }

    // MARK: - Capturing

    /// screencapture takes rectangles from the top left of the main display.
    private static func topLeft(_ r: CGRect) -> String {
        let top = (NSScreen.screens.first?.frame.maxY ?? r.maxY) - r.maxY
        return "\(Int(r.minX.rounded())),\(Int(top.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))"
    }

    private static func shoot(_ r: CGRect, to url: URL) {
        capture(["-R" + topLeft(r)], to: url)
    }

    private static func record(_ r: CGRect, seconds: Double, to url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-v", "-V", String(Int(seconds)), "-R" + topLeft(r), url.path]
        try? p.run()
        Log.debug("showcase: recording \(Int(seconds)) s")
    }

    private static func capture(_ args: [String], to url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x"] + args + [url.path]
        try? p.run()
        p.waitUntilExit()
        Log.debug("showcase: \(url.lastPathComponent)")
    }

    // MARK: - The backdrop

    /// A plain wallpaper and a Dock shelf with Apple's own apps, at the real Dock's place and height.
    final class Backdrop: NSWindow {
        init(dock: DockInfo, screen: CGRect) {
            let frame = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: min(screen.height, dock.floorY - screen.minY + 520))
            super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
            isOpaque = true
            contentView = Scene(dock: dock, origin: frame.origin)
            orderFrontRegardless()
        }
    }

    final class Scene: NSView {
        let dock: DockInfo
        let origin: CGPoint
        private let icons: [NSImage]

        init(dock: DockInfo, origin: CGPoint) {
            self.dock = dock
            self.origin = origin
            let apps = ["/System/Library/CoreServices/Finder.app", "/System/Applications/Apps.app", "/Applications/Safari.app",
                        "/System/Applications/Messages.app", "/System/Applications/Mail.app", "/System/Applications/Maps.app",
                        "/System/Applications/Photos.app", "/System/Applications/FaceTime.app", "/System/Applications/Calendar.app",
                        "/System/Applications/Contacts.app", "/System/Applications/Reminders.app", "/System/Applications/Notes.app",
                        "/System/Applications/Freeform.app", "/System/Applications/Music.app", "/System/Applications/Podcasts.app",
                        "/System/Applications/TV.app", "/System/Applications/App Store.app", "/System/Applications/Weather.app",
                        "/System/Applications/Preview.app", "/System/Applications/Utilities/Terminal.app",
                        "/System/Applications/Calculator.app", "/System/Applications/System Settings.app"]
            icons = apps.filter { FileManager.default.fileExists(atPath: $0) }.map { NSWorkspace.shared.icon(forFile: $0) }
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

        override func draw(_ dirty: NSRect) {
            let top = NSColor(red: 0.20, green: 0.22, blue: 0.40, alpha: 1)
            let bottom = NSColor(red: 0.62, green: 0.55, blue: 0.82, alpha: 1)
            NSGradient(starting: bottom, ending: top)?.draw(in: bounds, angle: 75)

            let floor = dock.floorY - origin.y
            let shelf = CGRect(x: dock.minX - origin.x, y: 6, width: dock.maxX - dock.minX, height: floor - 6)
            let path = NSBezierPath(roundedRect: shelf, xRadius: 26, yRadius: 26)
            NSColor(white: 1, alpha: 0.20).setFill()
            path.fill()
            NSColor(white: 1, alpha: 0.42).setStroke()
            path.lineWidth = 1
            path.stroke()

            guard !icons.isEmpty else { return }
            let size = shelf.height - 18
            let step = size + 8
            let count = min(icons.count, Int((shelf.width - 16) / step))
            let x0 = shelf.midX - CGFloat(count) * step / 2 + 4
            for i in 0..<count {
                icons[i].draw(in: CGRect(x: x0 + CGFloat(i) * step, y: shelf.minY + 9, width: size, height: size))
            }
        }
    }
}
