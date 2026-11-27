import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// "Open at login" for the app itself.
final class LoginItem: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var needsApproval = false
    @Published private(set) var problem: String?

    init() { refresh() }

    static var installedInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isOn = status == .enabled
        needsApproval = status == .requiresApproval
    }

    /// The user's own choice in Settings; on by default.
    static var wanted: Bool {
        get { UserDefaults.standard.object(forKey: "wantsLoginItem") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wantsLoginItem") }
    }

    /// At launch: puts the app back into the login items if macOS dropped it (a new signature can do
    /// that) while the user still wants it there.
    func ensure() {
        let status = SMAppService.mainApp.status
        let names: [SMAppService.Status: String] = [.enabled: "enabled", .requiresApproval: "requires approval", .notRegistered: "not registered", .notFound: "not found"]
        Log.note("login item: \(names[status] ?? "unknown")")
        guard Self.installedInApplications, Self.wanted, status == .notRegistered || status == .notFound else { return }
        do {
            try SMAppService.mainApp.register()
            Log.note("login item registered again")
        } catch {
            Log.error("login item register failed: \(error.localizedDescription)")
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        problem = nil
        Self.wanted = enabled
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            problem = enabled
                ? tr("macOS не дала добавить приложение в автозапуск. Добавь его вручную: Системные настройки → Основные → Объекты входа.", "macOS didn't let Dockling open at login. Add it by hand: System Settings → General → Login Items.")
                : tr("Не получилось убрать приложение из автозапуска. Убери его вручную: Системные настройки → Основные → Объекты входа.", "Couldn't stop Dockling from opening at login. Remove it by hand: System Settings → General → Login Items.")
            Log.error("login item change failed: \((error as NSError).code)")
        }
        refresh()
    }
}

/// The settings window. It is built when shown and released when closed.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private unowned let app: AppDelegate
    private var window: NSWindow?

    init(app: AppDelegate) {
        self.app = app
    }

    func show() {
        if window == nil {
            let view = SettingsView(prefs: app.prefs, login: app.loginItem, hooks: app.hookInstaller)
            let host = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: host)
            w.title = "Dockling"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 560, height: 760))
            w.center()
            window = w
        }
        app.loginItem.refresh()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window?.contentViewController = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var login: LoginItem
    @ObservedObject var hooks: HookInstaller
    /// The built-in character, for the preview at the top.
    private let skin = Skin.load()
    @State private var claudeFound = ClaudeChat.locate(custom: "")?.path
    @State private var codexFound: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                section(tr("Персонаж", "Character")) {
                    slider(tr("Ширина", "Width"), value: $prefs.scaleX, range: Preferences.scaleRange, label: "\(Int(prefs.scaleX * 100))%")
                    slider(tr("Высота", "Height"), value: $prefs.scaleY, range: Preferences.scaleRange, label: "\(Int(prefs.scaleY * 100))%")
                    slider(tr("Скорость бега", "Running speed"), value: $prefs.walkSpeed, range: Preferences.speedRange, label: tr("\(Int(prefs.walkSpeed)) пт/с", "\(Int(prefs.walkSpeed)) pt/s"))
                    Toggle(tr("Гуляет по Dock сам", "Walks along the Dock on his own"), isOn: $prefs.strolls)
                }
                section(tr("Вид", "Appearance")) {
                    Picker(tr("Тема", "Theme"), selection: $prefs.theme) {
                        Text(tr("Авто", "Auto")).tag(ThemeChoice.auto)
                        Text(tr("Светлая", "Light")).tag(ThemeChoice.light)
                        Text(tr("Тёмная", "Dark")).tag(ThemeChoice.dark)
                    }
                    .pickerStyle(.segmented)
                    slider(tr("Прозрачность стекла", "Glass transparency"), value: $prefs.transparency, range: 0...100, label: "\(Int(prefs.transparency))%")
                    Toggle(tr("Значок в строке меню", "Menu bar icon"), isOn: $prefs.showMenuBarIcon)
                    if !prefs.showMenuBarIcon {
                        Text(tr("Без значка настройки открываются правым кликом по персонажу или повторным запуском Dockling.", "Without the icon, open Settings by right-clicking the character or by opening Dockling again."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                section("Claude") {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: claudeFound == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(claudeFound == nil ? .orange : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(claudeFound == nil ? tr("Claude Code не найден", "Claude Code not found") : tr("Чат работает через твой Claude Code, по подписке", "The chat runs on your Claude Code subscription"))
                            Text(claudeFound.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? tr("Установи Claude Code или укажи путь к нему.", "Install Claude Code or choose where it is.")).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(tr("Указать…", "Choose…"), action: pickClaude)
                    }
                    Toggle(tr("Отвечать вслух на голосовые вопросы", "Read answers to voice questions aloud"), isOn: $prefs.speakVoiceReplies)
                    Toggle(tr("Следить за лимитами, пока работает Claude Code", "Keep an eye on the limits while Claude Code works"), isOn: $prefs.watchLimits)
                    Text(tr("Лимиты приходят только вместе с ответом, поэтому раз в несколько минут через Claude Code уходит самый маленький запрос: около тысячи токенов самой дешёвой модели. Без этого лимиты узнаются, когда открываешь чат.", "The limits only come with an answer, so every few minutes the smallest request goes through Claude Code: about a thousand tokens of the cheapest model. Without this, the limits are asked for when you open the chat."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                section("Codex") {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: codexFound == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(codexFound == nil ? .orange : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(codexFound == nil ? tr("Codex не найден", "Codex not found") : tr("Вкладка Codex работает через твой Codex CLI, по входу ChatGPT", "The Codex tab runs on your Codex CLI with your ChatGPT login"))
                            Text(codexFound.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? tr("Установи Codex CLI и войди через ChatGPT, или укажи путь к нему.", "Install the Codex CLI and sign in with ChatGPT, or choose where it is.")).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if !prefs.codexPath.isEmpty {
                            Button(tr("Сам", "Auto")) { prefs.codexPath = ""; codexFound = CodexChat.locate(custom: "")?.path }
                        }
                        Button(tr("Указать…", "Choose…"), action: pickCodex)
                    }
                    Toggle(tr("Садиться за ноутбук, пока Codex работает в BB", "Sit at the laptop while Codex works in BB"), isOn: $prefs.bbActivity)
                    Text(tr("Dockling видит только число активных задач на этом Mac. Лимит Codex на эту проверку не расходуется.", "Dockling reads only the number of active tasks on this Mac. Checking doesn't use your Codex allowance."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(tr("Codex только разговаривает: разговор не сохраняется в его истории, плагины, MCP, хуки и команды из твоего профиля Codex выключены, нет доступа к файлам пользователя и проектов. Лимиты читаются без запроса к модели. Платный доступ по API-ключу не используется.", "Codex only talks: the conversation isn't kept in its history, the plugins, MCP servers, hooks and commands from your Codex profile are off, and it has no access to your or your projects' files. The limits are read without asking the model. Paid API-key access is never used."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                section("Claude Code") {
                    Toggle(tr("Показывать, что делает Claude Code", "Show what Claude Code is doing"), isOn: Binding(get: { hooks.installed }, set: { hooks.setInstalled($0) }))
                    Text(tr("Добавляет хуки в ~/.claude/settings.json: статус работы, вопросы о разрешениях с кнопками, итог задачи. Чужие хуки не трогаются, копия файла сохраняется рядом.", "Adds hooks to ~/.claude/settings.json: work status, permission requests with buttons, a summary when a task ends. Other hooks are left alone, and a backup of the file is saved next to it."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem = hooks.problem { Text(problem).foregroundStyle(.red).font(.callout) }
                }
                section(tr("Уведомления", "Notifications")) {
                    Toggle(tr("Встречи из календаря за 10 минут", "Calendar meetings 10 minutes ahead"), isOn: $prefs.calendarReminders)
                    Toggle(tr("Предлагать спросить про скриншот", "Offer to ask about screenshots"), isOn: $prefs.screenshotOffers)
                }
                section(tr("Система", "System")) {
                    Toggle(tr("Запускать вместе с системой", "Open at login"), isOn: Binding(get: { login.isOn }, set: { login.setEnabled($0) }))
                    if login.needsApproval {
                        Text(tr("Автозапуск выключен в Системных настройках → Основные → Объекты входа.", "Opening at login is turned off in System Settings → General → Login Items.")).font(.caption).foregroundStyle(.orange)
                    }
                    if let p = login.problem { Text(p).font(.caption).foregroundStyle(.red) }
                    if !LoginItem.installedInApplications {
                        Text(tr("Для автозапуска перенеси приложение в «Программы».", "To open at login, move the app to Applications.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(tr("Пиксельный шрифт: Ghost Pixel, изменённая версия Pixelify Sans © The Pixelify Sans Project Authors, SIL Open Font License 1.1.", "Pixel font: Ghost Pixel, a modified version of Pixelify Sans © The Pixelify Sans Project Authors, SIL Open Font License 1.1."))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(24)
            .padding(.top, 14)
        }
        .frame(minWidth: 520, minHeight: 600)
        .onAppear { codexFound = CodexChat.locate(custom: prefs.codexPath)?.path }
    }

    // MARK: - Pieces

    @Environment(\.colorScheme) private var scheme

    /// A lilac card in the icon's colours with a little Dock, where he runs at the chosen size and speed.
    private var hero: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let colors = scheme == .dark
            ? [Color(red: 0.27, green: 0.23, blue: 0.47), Color(red: 0.14, green: 0.12, blue: 0.27)]
            : [Color(red: 0.66, green: 0.61, blue: 0.95), Color(red: 0.45, green: 0.38, blue: 0.84)]
        return ZStack(alignment: .topLeading) {
            shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            DockPreview(skin: skin, scaleX: prefs.scaleX, scaleY: prefs.scaleY, speed: prefs.walkSpeed)
            VStack(alignment: .leading, spacing: 6) {
                Text("GHOST").font(.pixel(30)).foregroundStyle(.white)
                Text(tr("Живёт на Dock, отвечает как Claude или Codex,\nследит за Claude Code и календарём.", "Lives on the Dock, answers as Claude or Codex,\nkeeps an eye on Claude Code and your calendar."))
                    .font(.callout).foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(height: 270)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.12 : 0.3), lineWidth: 1))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.pixel(12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Slider(value: value, in: range)
            Text(label).font(.pixel(12)).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }


    private func pickClaude() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = tr("Выбери программу claude", "Choose the claude program")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.claudePath = url.path
        claudeFound = ClaudeChat.locate(custom: url.path)?.path
    }

    private func pickCodex() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = tr("Выбери программу codex", "Choose the codex program")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.codexPath = url.path
        codexFound = CodexChat.locate(custom: url.path)?.path
    }
}

/// A little glass Dock with the character running along it at his real on-screen size (two screen
/// points per sheet pixel, times the width and height sliders) and the chosen speed, resting a moment
/// at each end. It only animates while the settings window is open.
private struct DockPreview: View {
    let scaleX: Double
    let scaleY: Double
    let speed: Double
    private let frames: [String: [CGImage]]
    private let fps: [String: Double]
    private let size: CGSize
    private let foot: CGFloat

    private static let pause: Double = 1.2

    init(skin: Skin?, scaleX: Double, scaleY: Double, speed: Double) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.speed = max(speed, 1)
        var frames: [String: [CGImage]] = [:]
        var fps: [String: Double] = [:]
        if let skin {
            for name in ["idle", "walk_right", "walk_left"] {
                guard let a = skin[name] else { continue }
                frames[name] = (0..<max(1, a.frames)).compactMap { skin.frameImage(name, column: $0) }
                fps[name] = max(a.fps, 1)
            }
        }
        self.frames = frames
        self.fps = fps
        size = skin.map { CGSize(width: $0.frameSize.width * 2 * scaleX, height: $0.frameSize.height * 2 * scaleY) } ?? .zero
        foot = CGFloat(skin?.footPadding ?? 0) * 2 * scaleY
    }

    var body: some View {
        GeometryReader { geo in
            let dockTop = geo.size.height - 40
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.2))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .frame(width: geo.size.width - 32, height: 24)
                    .offset(x: 16, y: dockTop)
                if !frames.isEmpty {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                        let (x, image) = pose(at: ctx.date.timeIntervalSinceReferenceDate, width: geo.size.width)
                        if let image {
                            Image(decorative: image, scale: 1).interpolation(.none).resizable()
                                .frame(width: size.width, height: size.height)
                                .offset(x: x, y: dockTop - size.height + foot)
                        }
                    }
                }
            }
        }
    }

    /// Where he is and which frame shows: right, rest, left, rest, over and over.
    private func pose(at time: Double, width: CGFloat) -> (CGFloat, CGImage?) {
        let from: CGFloat = 28, to = max(from, width - 28 - size.width)
        let run = Double(to - from) / speed
        let lap = 2 * (run + Self.pause)
        let t = time.truncatingRemainder(dividingBy: max(lap, 0.01))
        let (name, x): (String, CGFloat)
        if t < run {
            (name, x) = ("walk_right", from + CGFloat(t * speed))
        } else if t < run + Self.pause {
            (name, x) = ("idle", to)
        } else if t < 2 * run + Self.pause {
            (name, x) = ("walk_left", to - CGFloat((t - run - Self.pause) * speed))
        } else {
            (name, x) = ("idle", from)
        }
        let row = frames[name] ?? frames["idle"] ?? frames.values.first ?? []
        guard !row.isEmpty else { return (x, nil) }
        let i = Int(time * (fps[name] ?? 8)) % row.count
        return (x, row[i])
    }
}
