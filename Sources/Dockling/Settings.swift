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
                ? "macOS не дала добавить приложение в автозапуск. Добавь его вручную: Системные настройки → Основные → Объекты входа."
                : "Не получилось убрать приложение из автозапуска. Убери его вручную: Системные настройки → Основные → Объекты входа."
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                section("Персонаж") {
                    slider("Ширина", value: $prefs.scaleX, range: Preferences.scaleRange, label: "\(Int(prefs.scaleX * 100))%")
                    slider("Высота", value: $prefs.scaleY, range: Preferences.scaleRange, label: "\(Int(prefs.scaleY * 100))%")
                    slider("Скорость бега", value: $prefs.walkSpeed, range: Preferences.speedRange, label: "\(Int(prefs.walkSpeed)) пт/с")
                    Toggle("Гуляет по Dock сам", isOn: $prefs.strolls)
                }
                section("Вид") {
                    Picker("Тема", selection: $prefs.theme) {
                        Text("Авто").tag(ThemeChoice.auto)
                        Text("Светлая").tag(ThemeChoice.light)
                        Text("Тёмная").tag(ThemeChoice.dark)
                    }
                    .pickerStyle(.segmented)
                    slider("Прозрачность стекла", value: $prefs.transparency, range: 0...100, label: "\(Int(prefs.transparency))%")
                    Toggle("Значок в строке меню", isOn: $prefs.showMenuBarIcon)
                    if !prefs.showMenuBarIcon {
                        Text("Без значка настройки открываются правым кликом по персонажу или повторным запуском Dockling.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                section("Claude") {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: claudeFound == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(claudeFound == nil ? .orange : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(claudeFound == nil ? "Claude Code не найден" : "Чат работает через твой Claude Code, по подписке")
                            Text(claudeFound.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Установи Claude Code или укажи путь к нему.").font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Указать…", action: pickClaude)
                    }
                    Toggle("Отвечать вслух на голосовые вопросы", isOn: $prefs.speakVoiceReplies)
                }
                section("Claude Code") {
                    Toggle("Показывать, что делает Claude Code", isOn: Binding(get: { hooks.installed }, set: { hooks.setInstalled($0) }))
                    Text("Добавляет хуки в ~/.claude/settings.json: статус работы, вопросы о разрешениях с кнопками, итог задачи. Чужие хуки не трогаются, копия файла сохраняется рядом.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem = hooks.problem { Text(problem).foregroundStyle(.red).font(.callout) }
                }
                section("Уведомления") {
                    Toggle("Встречи из календаря за 10 минут", isOn: $prefs.calendarReminders)
                    Toggle("Предлагать спросить про скриншот", isOn: $prefs.screenshotOffers)
                }
                section("Система") {
                    Toggle("Запускать вместе с системой", isOn: Binding(get: { login.isOn }, set: { login.setEnabled($0) }))
                    if login.needsApproval {
                        Text("Автозапуск выключен в Системных настройках → Основные → Объекты входа.").font(.caption).foregroundStyle(.orange)
                    }
                    if let p = login.problem { Text(p).font(.caption).foregroundStyle(.red) }
                    if !LoginItem.installedInApplications {
                        Text("Для автозапуска перенеси приложение в «Программы».").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Пиксельный шрифт: Ghost Pixel, изменённая версия Pixelify Sans © The Pixelify Sans Project Authors, SIL Open Font License 1.1.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(24)
            .padding(.top, 14)
        }
        .frame(minWidth: 520, minHeight: 600)
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
                Text("Живёт на Dock, отвечает как Claude,\nследит за Claude Code и календарём.")
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
        panel.message = "Выбери программу claude"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.claudePath = url.path
        claudeFound = ClaudeChat.locate(custom: url.path)?.path
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
