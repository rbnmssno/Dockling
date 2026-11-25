import AppKit

/// `--showcase <folder>`: the pictures and the animation for the README, made from the real app.
///
/// The scene is a stage of our own: a compact Dock with a few of Apple's apps on a wallpaper-like
/// backdrop, on the sharpest screen, so every picture comes out at full resolution and the whole Dock
/// fits in the frame. Nothing of the real screen gets in. Claude Code hooks, the calendar, music, the
/// clipboard and the screenshot watcher stay off, and every text in the pictures is made up here.
/// Saved settings end as they were: the theme is put back, the scale is set on the stage only.
/// Run it with `--isolated` beside a running Dockling.
enum Showcase {
    /// The Dock he stands on during a showcase, in place of the real one (see `DockGeometry.current`).
    static let stage: DockInfo? = {
        guard DevTools.showcase != nil,
              let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else { return nil }
        let f = screen.frame
        let shelf = Shelf.frame(on: f)
        return DockInfo(screen: f, floorY: shelf.maxY - 5, minX: shelf.minX, maxX: shelf.maxX)
    }()

    /// The Dock shelf: a glass bar with a few apps, centred at the bottom of the screen.
    enum Shelf {
        static let apps = ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app", "/System/Applications/Messages.app",
                           "/System/Applications/Notes.app", "/System/Applications/Music.app", "/System/Applications/Utilities/Terminal.app"]
        static let tile: CGFloat = 54
        static let gap: CGFloat = 8
        static let inset: CGFloat = 10

        static func frame(on screen: CGRect) -> CGRect {
            let n = CGFloat(apps.count)
            let width = n * tile + (n - 1) * gap + 2 * inset
            let height = tile + 2 * inset
            return CGRect(x: (screen.midX - width / 2).rounded(), y: screen.minY + 8, width: width.rounded(), height: height)
        }
    }

    static func run(_ app: AppDelegate, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let brain = app.brain!
        let stage = app.stage!
        guard let window = stage.window, let screen = window.screen, let dock = Self.stage else { return }
        let at: (Double, @escaping () -> Void) -> Void = { t, f in DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        let speed = max(20, app.prefs.walkSpeed)

        stage.setScale(x: 1, y: 1)
        let sprite = stage.spriteSize
        let middle = (dock.minX + dock.maxX) / 2
        let reach = (dock.maxX - dock.minX) / 2 - sprite.width / 2 - 6
        let startX = middle + reach * 0.8, endX = middle - reach * 0.45
        stage.place(x: startX - window.frame.minX)

        let back = Backdrop(screen: screen.frame, dock: dock)
        back.order(.below, relativeTo: window.windowNumber)

        app.chat.model.limits = PlanLimits(session: 23, week: 41,
                                           sessionReset: Date().addingTimeInterval(2 * 3600 + 14 * 60),
                                           weekReset: Date().addingTimeInterval(3 * 86400 + 5 * 3600))
        let conversation = Language.isRussian ? [
            ChatMessage(role: .me, text: "Как по-английски «руки не доходят»?"),
            ChatMessage(role: .bot, text: "I haven't gotten around to it. Например: I still haven't gotten around to the README."),
            ChatMessage(role: .me, text: "Сколько секунд в неделе?"),
            ChatMessage(role: .bot, text: "604 800."),
        ] : [
            ChatMessage(role: .me, text: "Name for a function that retries with backoff?"),
            ChatMessage(role: .bot, text: "retryWithBackoff. If it gives up after a few tries, withRetry(maxAttempts:) reads well too."),
            ChatMessage(role: .me, text: "How many seconds are in a week?"),
            ChatMessage(role: .bot, text: "604,800."),
        ]

        // Every picture is centred on the Dock and as wide as it plus a margin, so the whole Dock shows.
        let chatW: CGFloat = 348, chatH: CGFloat = 352
        let floor = dock.floorY
        let frameW = max(chatW, dock.maxX - dock.minX) + 64
        let column = { (top: CGFloat) in CGRect(x: middle - frameW / 2, y: screen.frame.minY, width: frameW, height: top - screen.frame.minY) }
        let movie = column(floor + sprite.height + 10 + chatH + 26)
        Log.debug("showcase: movie region \(movie)")
        let walkTime = Double(abs(startX - endX) / speed)

        // The animation: a wave, a walk to the left end, Claude Code at work and done, then he is carried
        // to the middle and dropped, and the chat opens over him.
        var t = 1.5
        let movieSeconds = (17.5 + walkTime).rounded(.up)
        let movieEnd = t + movieSeconds
        at(t) { record(movie, seconds: movieSeconds, to: dir.appendingPathComponent("tour.mov")) }
        t += 0.8; at(t) { brain.react("wave", duration: 1.5) }
        t += 1.8; at(t) { brain.walk(to: endX - window.frame.minX) }
        t += walkTime + 0.5; at(t) { brain.claude = .work }
        t += 3.2; at(t) {
            brain.claude = .none
            brain.notify(Card(icon: .done, color: Card.green, text: tr("Тесты прошли: 42 из 42", "Tests passed: 42 of 42"), meta: tr("Monobrow · 3 мин", "Monobrow · 3 min"),
                              actions: [CardAction(title: tr("Открыть", "Open"), primary: true) {}], duration: 3.2))
        }
        t += 3.6; at(t) { brain.stagePressed(); brain.stageDragBegan() }
        let steps = 10
        let dx = (middle - endX) / CGFloat(steps)
        for i in 1...steps {
            at(t + 0.06 * Double(i)) {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                stage.sprite.position.x += dx
                stage.sprite.position.y += i <= 7 ? 15 : 0
                CATransaction.commit()
                brain.stageCarried()
            }
        }
        t += 0.06 * Double(steps) + 0.35; at(t) { brain.stageDropped() }
        // The theme is set for this run and put back at the end (an `--isolated` run has settings of its own).
        let savedTheme = app.prefs.theme
        t += 1.9; at(t) {
            app.prefs.theme = .dark
            app.chat.model.messages = conversation
            app.chat.open()
        }
        // While a recording runs macOS dims the screen around it, so the stills wait for it to end.
        t = max(t + 3.4, movieEnd + 1.2)

        // Still pictures: the chat in both themes, then the cards, then the settings window.
        let chatRegion = { () -> CGRect in column((app.chat.panelFrame?.maxY ?? movie.maxY) + 26) }
        at(t) { shoot(chatRegion(), to: dir.appendingPathComponent("chat-dark.png")) }
        // The chat takes its text colours when it opens, so it is reopened in the light theme.
        t += 0.4; at(t) { app.chat.close(); app.prefs.theme = .light }
        t += 0.4; at(t) { app.chat.model.messages = conversation; app.chat.open() }
        t += 1.2; at(t) { shoot(chatRegion(), to: dir.appendingPathComponent("chat-light.png")) }
        t += 0.4; at(t) { app.chat.close(); app.prefs.theme = savedTheme }

        let cardRegion = column(floor + sprite.height + 84)
        t += 1.0; at(t) {
            brain.claude = .wait
            brain.cards.setStanding(Card(icon: .lock, color: Card.amber, text: "npm test", meta: "Bash · Monobrow", mono: true,
                                         actions: [CardAction(title: tr("Разрешить", "Allow"), primary: true) {}, CardAction(title: tr("Отклонить", "Deny")) {}],
                                         sticky: true, hold: true, tag: "cc-question"))
        }
        t += 1.6; at(t) { shoot(cardRegion, to: dir.appendingPathComponent("card-permission.png")) }
        t += 0.4; at(t) {
            brain.cards.setStanding(nil)
            brain.claude = .none
            brain.notify(Card(icon: .done, color: Card.green, text: tr("Собрал окно чата и подключил лимиты", "Built the chat window and hooked up the limits"),
                              meta: tr("Dockling · 4 мин", "Dockling · 4 min"),
                              actions: [CardAction(title: tr("Открыть", "Open"), primary: true) {}], duration: 6))
        }
        t += 1.6; at(t) { shoot(cardRegion, to: dir.appendingPathComponent("card-done.png")) }
        t += 0.4; at(t) {
            brain.notify(Card(icon: .calendar, color: Card.blue, text: tr("Созвон через 10 минут", "Weekly planning"), meta: tr("Планирование, 15:00", "3:00 PM, in 10 min"),
                              actions: [CardAction(title: tr("Открыть", "Open"), primary: true) {}, CardAction(title: tr("Позже", "Later")) {}], duration: 6))
        }
        t += 1.6; at(t) { shoot(cardRegion, to: dir.appendingPathComponent("card-meeting.png")) }
        t += 0.4; at(t) { brain.cards.hide(); app.openSettings() }
        t += 0.3; at(t) {
            // On the same sharp screen, above the backdrop.
            for w in NSApp.windows where w.isVisible && w.title == "Dockling" {
                let area = screen.visibleFrame
                w.setFrameOrigin(CGPoint(x: area.midX - w.frame.width / 2, y: area.maxY - w.frame.height - 40))
            }
        }
        t += 1.7; at(t) {
            for w in NSApp.windows where w.isVisible && w.title == "Dockling" {
                capture(["-l", String(w.windowNumber)], to: dir.appendingPathComponent("settings.png"))
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

    /// A wallpaper and the Dock shelf, over the bottom of the screen, just under the pet's window.
    final class Backdrop: NSWindow {
        init(screen: CGRect, dock: DockInfo) {
            let frame = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: min(screen.height, dock.floorY - screen.minY + 620))
            super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
            isOpaque = true
            contentView = Scene(screen: screen, origin: frame.origin)
            orderFrontRegardless()
        }
    }

    final class Scene: NSView {
        private let shelf: CGRect
        private let icons: [NSImage]

        init(screen: CGRect, origin: CGPoint) {
            shelf = Shelf.frame(on: screen).offsetBy(dx: -origin.x, dy: -origin.y)
            icons = Shelf.apps.filter { FileManager.default.fileExists(atPath: $0) }
                .map { NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

        private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
        }

        private var wallpaper: NSImage?

        /// A lilac wallpaper with soft colour fields, blurred once like an aurora, so the glass has
        /// something to show through and bend at its edges.
        private func makeWallpaper() -> NSImage? {
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return nil }
            let sharp = NSImage(size: size, flipped: false) { r in
                NSGradient(colors: [self.rgb(0xC3B2FF), self.rgb(0x8E78EE), self.rgb(0x3F2E9A)], atLocations: [0, 0.4, 1], colorSpace: .sRGB)?
                    .draw(in: r, angle: 90)
                let c = CGPoint(x: self.shelf.midX, y: self.shelf.minY)
                let s = max(r.height, 700)
                let fields: [(UInt32, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                    (0xFF8FD0, 0.42, 0.50, 0.46, 0.30, 0.85), (0x5FC6FF, -0.50, 0.36, 0.40, 0.26, 0.75),
                    (0xFFC59E, 0.00, 0.02, 0.60, 0.16, 0.80), (0x2A1C80, -0.10, 0.92, 0.80, 0.30, 0.90),
                    (0xB28CFF, 0.10, 0.62, 0.35, 0.12, 0.70),
                ]
                for (hex, dx, dy, w, h, a) in fields {
                    let rect = CGRect(x: c.x + dx * s - w * s / 2, y: c.y + dy * s - h * s / 2, width: w * s, height: h * s)
                    let t = NSAffineTransform(); t.translateX(by: rect.midX, yBy: rect.midY); t.rotate(byDegrees: dx * 18); t.translateX(by: -rect.midX, yBy: -rect.midY)
                    let oval = NSBezierPath(ovalIn: rect); oval.transform(using: t as AffineTransform)
                    self.rgb(hex, a).setFill(); oval.fill()
                }
                return true
            }
            guard let tiff = sharp.tiffRepresentation, let input = CIImage(data: tiff) else { return sharp }
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 70).cropped(to: input.extent)
            let rep = NSCIImageRep(ciImage: blurred)
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            return image
        }

        override func draw(_ dirty: NSRect) {
            if wallpaper == nil { wallpaper = makeWallpaper() }
            wallpaper?.draw(in: bounds)

            // The shelf: clear glass with a bright rim, as the Dock on macOS 26.
            let path = NSBezierPath(roundedRect: shelf, xRadius: 24, yRadius: 24)
            NSShadow().then { $0.shadowColor = NSColor(white: 0, alpha: 0.18); $0.shadowBlurRadius = 18; $0.shadowOffset = NSSize(width: 0, height: -4) }.set()
            NSColor(white: 1, alpha: 0.22).setFill()
            path.fill()
            NSShadow().set()
            NSGradient(colors: [NSColor(white: 1, alpha: 0.20), NSColor(white: 1, alpha: 0)])?.draw(in: path, angle: -90)
            NSColor(white: 1, alpha: 0.55).setStroke()
            path.lineWidth = 1
            path.stroke()

            for (i, icon) in icons.enumerated() {
                let x = shelf.minX + Shelf.inset + CGFloat(i) * (Shelf.tile + Shelf.gap)
                icon.draw(in: CGRect(x: x, y: shelf.minY + Shelf.inset, width: Shelf.tile, height: Shelf.tile))
            }
        }
    }
}

private extension NSShadow {
    func then(_ set: (NSShadow) -> Void) -> NSShadow { set(self); return self }
}
