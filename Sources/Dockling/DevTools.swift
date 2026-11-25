import AppKit
import AVFoundation
import Speech

/// Development switches:
///   --log                 print what happens
///   --isolated            a test copy beside the user's own Dockling: its own settings (app.dockling.Dockling.test)
///                         and its own data folder in the temporary directory, so the running pet is left alone
///   --skin <folder>       use sheet.png and sheet.json from a folder, without touching the settings
///   --demo <name>         run a scenario: walk, chat, cards, sleep, drop, follow, limits
///   --dock-display main|external   his Dock is on that display, whatever the real Dock does
///   --quit-after <sec>    leave after a while
///   --render <folder>     write offscreen pictures of the cards and the chat
///   --showcase <folder>   the README pictures and animation, over a backdrop of our own (see Showcase)
enum DevTools {
    /// A scripted run: no strolls of his own and no clipboard offers, so only the script shows.
    static var scripted = false
    static let isolated = CommandLine.arguments.contains("--isolated")
    static var showcase: String? { value(after: "--showcase") }

    static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(_ app: AppDelegate) {
        if let dir = showcase {
            scripted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Showcase.run(app, to: URL(fileURLWithPath: dir)) }
        }
        if let s = value(after: "--quit-after"), let t = Double(s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }
        if let s = value(after: "--sleep-after"), let t = Double(s) {
            PetBrain.sleepAfter = t
            app.brain.restartSleepCheck()
        }
        guard let demo = value(after: "--demo") else { return }
        let brain = app.brain!
        let after: (Double, @escaping () -> Void) -> Void = { t, f in DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        Log.debug("demo \(demo)")
        switch demo {
        case "walk":
            after(1) { brain.walk(to: app.stage.centerX - 200) }
        case "chat":
            after(1) { app.chat.open() }
            after(2) { app.chat.send(value(after: "--say") ?? tr("Ответь одним коротким предложением: ты на связи?", "Answer in one short sentence: are you there?")) }
        case "limits":
            // The chat opens with no message sent; the limits come by themselves.
            after(1) { app.chat.open() }
        case "follow":
            // The way he follows the Dock to another display: down below the edge, up again further on.
            after(1.5) {
                let to = max(80, app.stage.centerX - 260)
                app.stage.dive { app.stage.surface(at: to); app.brain.settle() }
            }
        case "remind":
            // Asked in the chat, then the chat closes; the reminder comes as a card.
            after(1) { app.chat.open() }
            after(1.5) { app.chat.send(value(after: "--say") ?? tr("напомни через 4 сек проверка напоминания", "remind me in 4 seconds to check the reminder")) }
            after(2.5) { Log.debug("chat says: \(app.chat.model.messages.last?.text ?? "-")"); app.chat.close() }
        case "cards":
            after(1) { brain.notify(Card(icon: .done, color: Card.green, text: tr("Собрал окно чата и подключил лимиты", "Built the chat window and hooked up the limits"), meta: tr("Dockling · 4 мин", "Dockling · 4 min"), actions: [CardAction(title: tr("Открыть", "Open"), primary: true) {}], duration: 4)) }
            after(5.5) {
                brain.cards.setStanding(Card(icon: .lock, color: Card.amber, text: "npm test", meta: "Bash · Monobrow", mono: true,
                                             actions: [CardAction(title: tr("Разрешить", "Allow"), primary: true) {}, CardAction(title: tr("Отклонить", "Deny")) {}], sticky: true, hold: true, tag: "cc-question"))
            }
            after(7) { brain.notify(Card(icon: .battery, color: Card.red, text: tr("Осталось 5% заряда", "5% battery left"), duration: 2)) }
            after(10) { brain.cards.setStanding(nil) }
        case "sleep":
            after(1) { brain.setAsleep(true) }
            after(5) { brain.setAsleep(false) }
        case "settings":
            after(1) { app.openSettings() }
        case "walkclick":
            // A click on him in the middle of a walk, then the chat closes again.
            after(1) { brain.walk(to: app.stage.centerX - 400) }
            after(2.2) { Log.debug("press mid-walk"); brain.stagePressed(); brain.stageClicked() }
            after(4) { app.chat.close() }
            after(5) { Log.debug("state: \(brain.base ?? "-"), moving \(app.stage.isMoving)") }
        case "walkcharge":
            // Charger events while he runs, then while he is held in the air.
            after(3) { brain.walk(to: app.stage.centerX - 500) }
            after(4) { Log.debug("charger on mid-walk, moving \(app.stage.isMoving)"); brain.react("charge_on") }
            after(4.3) { Log.debug("greeting during it"); brain.react("wave", duration: 1.5) }
            after(7) { Log.debug("picked up"); brain.stagePressed(); brain.stageDragBegan(); app.stage.sprite.position.y += 150; brain.stageCarried() }
            after(7.5) { Log.debug("charger off while held"); brain.react("charge_off") }
            after(8.5) { Log.debug("dropped"); brain.stageDropped() }
            after(11.5) { Log.debug("state: \(brain.base ?? "-")") }
        case "carrychat":
            // The chat is open while he is carried across the screen and dropped.
            let report = { (label: String) in
                guard let f = app.chat.panelFrame, let w = app.stage.window else { return }
                let head = w.frame.minX + app.stage.centerX
                Log.debug("\(label): chat centre \(Int(f.midX)) vs his \(Int(head)), chat bottom \(Int(f.minY)) vs head \(Int(w.frame.minY + app.stage.headTop))")
            }
            after(1) { app.chat.open() }
            after(1.8) { report("open") }
            after(2.2) { brain.stagePressed(); brain.stageDragBegan() }
            for i in 1...10 {
                after(2.2 + Double(i) * 0.05) {
                    app.stage.sprite.position = CGPoint(x: app.stage.sprite.position.x - 40, y: app.stage.sprite.position.y + 18)
                    brain.stageCarried()
                }
            }
            after(2.9) { report("carried") }
            after(3.0) { brain.stageDropped() }
            after(3.05) { report("falling") }
            after(3.8) { report("landed") }
            after(4.2) { app.chat.close() }
        case "walkhover":
            // The cursor finds him on the run.
            after(1) { brain.walk(to: app.stage.centerX - 400) }
            after(2.5) { Log.debug("hover mid-walk"); brain.stageHovered() }
            after(3.5) { Log.debug("state: \(brain.base ?? "-"), moving \(app.stage.isMoving)") }
        case "walklag":
            // The app is busy right when he arrives; the compositor must still stop his running on time.
            let distance = CGFloat(Double(value(after: "--distance") ?? "200") ?? 200)
            after(1) { brain.walk(to: app.stage.centerX - distance) }
            let arrival = 1 + Double(distance) / app.prefs.walkSpeed
            after(arrival - 0.3) { Log.debug("main thread busy"); Thread.sleep(forTimeInterval: 2.5) }
        case "perms":
            Log.debug("microphone: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0 not asked, 2 denied, 3 allowed)")
            Log.debug("speech: \(SFSpeechRecognizer.authorizationStatus().rawValue) (0 not asked, 2 denied, 3 allowed)")
            Log.debug("russian on-device speech: \(SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))?.supportsOnDeviceRecognition == true)")
        case "away":
            // Nobody at the Mac for the first 12 seconds, then the real counter (the user is back).
            let start = Date()
            PetBrain.idleOverride = { Date().timeIntervalSince(start) < 12 ? 1000 : nil }
            app.brain.restartSleepCheck()
        case "idle":
            for i in 0..<6 { after(Double(i)) { Log.debug("idle \(String(format: "%.1f", PetBrain.idleTime)) s") } }
        case "glass":
            // The chat over an opaque test pattern of our own, shot at several transparency values.
            // Only the pattern's area is captured, so nothing else on the screen is recorded.
            let dir = URL(fileURLWithPath: value(after: "--out") ?? NSTemporaryDirectory())
            let values = (value(after: "--values") ?? "0,25,40,49,51,60,75,85,100").split(separator: ",").compactMap { Double($0) }
            let darkPattern = value(after: "--pattern") == "dark"
            let darkGlass = value(after: "--theme").map { $0 == "dark" } ?? app.prefs.isDark
            var back: NSWindow?
            after(1) {
                app.chat.model.messages += [ChatMessage(role: .me, text: tr("Как сделать стекло читаемым?", "How do I make glass readable?")),
                                            ChatMessage(role: .bot, text: tr("Плотнее подложка под текстом и плавное размытие фона.", "A denser backing under the text and a soft blur behind it."))]
                app.chat.open()
            }
            after(1.6) {
                guard let chat = app.chat.panelFrame else { return }
                let frame = chat.insetBy(dx: -50, dy: -40)
                let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
                w.contentView = TestPattern(dark: darkPattern)
                w.orderFrontRegardless()
                back = w
                app.chat.bringToFront()
            }
            for (i, v) in values.enumerated() {
                let t = 2.2 + Double(i) * 0.9
                after(t) { app.chat.previewGlass(dark: darkGlass, transparency: v) }
                after(t + 0.6) {
                    guard let back, let screen = back.screen else { return }
                    let f = back.frame
                    let top = screen.frame.maxY - f.maxY + (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - screen.frame.maxY
                    let name = "glass-\(darkGlass ? "dark" : "light")-on-\(darkPattern ? "dark" : "light")-\(String(format: "%03d", Int(v))).png"
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-R\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))", dir.appendingPathComponent(name).path]
                    try? p.run()
                    p.waitUntilExit()
                    Log.debug("glass shot \(name)")
                }
            }
            after(2.2 + Double(values.count) * 0.9 + 0.3) { back?.orderOut(nil); NSApp.terminate(nil) }
        case "work":
            after(1) { brain.claude = .work }
            after(5) { brain.claude = .none }
        case "autoclick":
            // Presses the first button of whatever card is up, as a person would.
            let at = Double(value(after: "--click-at") ?? "4") ?? 4
            after(at) {
                Log.debug("autoclick on: \(brain.cards.current?.text ?? "no card")")
                brain.cards.current?.actions.first?.run()
                brain.cards.hide()
            }
        default:
            break
        }
        if let dir = value(after: "--render") {
            after(Double(value(after: "--render-at") ?? "3") ?? 3) { render(app, to: URL(fileURLWithPath: dir)) }
        }
        if let dir = value(after: "--shot") {
            let times = (value(after: "--shot-at") ?? "3").split(separator: ",").compactMap { Double($0) }
            for (i, t) in times.enumerated() {
                after(t) { shoot(to: URL(fileURLWithPath: dir), suffix: "\(i + 1)") }
            }
        }
    }

    /// Real on-screen pictures of this app's own windows only (glass included), one file per window.
    static func shoot(to dir: URL, suffix: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible && window.contentView != nil && window.frame.width > 40 {
            let name = String(describing: type(of: window)) + "-" + suffix + ".png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(window.windowNumber), dir.appendingPathComponent(name).path]
            try? p.run()
            p.waitUntilExit()
            Log.debug("shot \(name) \(Int(window.frame.width))x\(Int(window.frame.height)) key=\(window.isKeyWindow)")
        }
    }

    /// Text and colour stripes to look at through the glass: light like a page, or dark like an editor.
    final class TestPattern: NSView {
        let dark: Bool
        init(dark: Bool) { self.dark = dark; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

        override func draw(_ r: NSRect) {
            (dark ? NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1) : NSColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1)).setFill()
            bounds.fill()
            let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemPink]
            for i in 0..<Int(bounds.width / 22) + 1 {
                colors[i % colors.count].setFill()
                NSRect(x: CGFloat(i) * 22, y: 0, width: 11, height: bounds.height * 0.18).fill()
            }
            let text = "Съешь же ещё этих мягких французских булок, да выпей чаю. The quick brown fox jumps over the lazy dog 0123456789"
            var y = bounds.height * 0.2
            var size: CGFloat = 10
            let ink = dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.08, alpha: 1)
            while y < bounds.height - 10 {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: size > 16 ? .bold : .regular), .foregroundColor: ink]
                (text + " " + text).draw(at: NSPoint(x: 6, y: y), withAttributes: attrs)
                y += size + 7
                size = size >= 22 ? 10 : size + 2
            }
            (dark ? NSColor.white : NSColor.black).setFill()
            for i in 0..<4 { NSRect(x: CGFloat(i) * 140 + 20, y: bounds.height * 0.62, width: 70, height: 22).fill() }
        }
    }

    /// Pictures of the app's own windows, drawn offscreen (the system glass itself is not captured).
    static func render(_ app: AppDelegate, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = String(describing: type(of: window))
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            Log.debug("rendered \(name) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        }
    }
}
