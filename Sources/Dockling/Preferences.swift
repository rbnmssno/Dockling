import AppKit
import Combine

enum ThemeChoice: String, CaseIterable {
    case auto, light, dark
}

/// User settings, stored in UserDefaults.
final class Preferences: ObservableObject {
    private let store: UserDefaults

    @Published var theme: ThemeChoice { didSet { store.set(theme.rawValue, forKey: Key.theme) } }
    /// 0 = solid panel, 100 = clear glass like the Dock.
    @Published var transparency: Double { didSet { store.set(transparency, forKey: Key.transparency) } }
    /// Size of the character along each axis, relative to the standard size (2 screen points per sprite pixel).
    @Published var scaleX: Double { didSet { store.set(scaleX, forKey: Key.scaleX) } }
    @Published var scaleY: Double { didSet { store.set(scaleY, forKey: Key.scaleY) } }
    /// Running speed in points per second.
    @Published var walkSpeed: Double { didSet { store.set(walkSpeed, forKey: Key.walkSpeed) } }
    @Published var strolls: Bool { didSet { store.set(strolls, forKey: Key.strolls) } }
    @Published var speakVoiceReplies: Bool { didSet { store.set(speakVoiceReplies, forKey: Key.speakVoiceReplies) } }
    @Published var screenshotOffers: Bool { didSet { store.set(screenshotOffers, forKey: Key.screenshotOffers) } }
    @Published var calendarReminders: Bool { didSet { store.set(calendarReminders, forKey: Key.calendarReminders) } }
    @Published var showMenuBarIcon: Bool { didSet { store.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }
    /// Empty: find Claude Code on its own.
    @Published var claudePath: String { didSet { store.set(claudePath, forKey: Key.claudePath) } }

    var didSetUpLoginItem: Bool {
        get { store.bool(forKey: Key.didSetUpLoginItem) }
        set { store.set(newValue, forKey: Key.didSetUpLoginItem) }
    }

    private enum Key {
        static let theme = "theme"
        static let transparency = "glassTransparency"
        static let scaleX = "scaleX"
        static let scaleY = "scaleY"
        static let walkSpeed = "walkSpeed"
        static let strolls = "strolls"
        static let speakVoiceReplies = "speakVoiceReplies"
        static let screenshotOffers = "screenshotOffers"
        static let calendarReminders = "calendarReminders"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let claudePath = "claudePath"
        static let didSetUpLoginItem = "didSetUpLoginItem"
    }

    static let speedRange: ClosedRange<Double> = 20...140
    static let scaleRange: ClosedRange<Double> = 0.5...2.0

    init(store: UserDefaults = .standard) {
        self.store = store
        store.register(defaults: [
            Key.theme: ThemeChoice.auto.rawValue,
            Key.transparency: 85.0,
            Key.scaleX: 1.0,
            Key.scaleY: 1.0,
            Key.walkSpeed: 56.0,
            Key.strolls: true,
            Key.speakVoiceReplies: true,
            Key.screenshotOffers: true,
            Key.calendarReminders: true,
            Key.showMenuBarIcon: false,
        ])
        theme = ThemeChoice(rawValue: store.string(forKey: Key.theme) ?? "") ?? .auto
        transparency = store.double(forKey: Key.transparency).clamped(0, 100)
        scaleX = store.double(forKey: Key.scaleX).clamped(Self.scaleRange.lowerBound, Self.scaleRange.upperBound)
        scaleY = store.double(forKey: Key.scaleY).clamped(Self.scaleRange.lowerBound, Self.scaleRange.upperBound)
        walkSpeed = store.double(forKey: Key.walkSpeed).clamped(Self.speedRange.lowerBound, Self.speedRange.upperBound)
        strolls = store.bool(forKey: Key.strolls)
        speakVoiceReplies = store.bool(forKey: Key.speakVoiceReplies)
        screenshotOffers = store.bool(forKey: Key.screenshotOffers)
        calendarReminders = store.bool(forKey: Key.calendarReminders)
        showMenuBarIcon = store.bool(forKey: Key.showMenuBarIcon)
        claudePath = store.string(forKey: Key.claudePath) ?? ""
    }

    /// Light or dark for the widget's own glass, whatever the theme choice.
    var isDark: Bool {
        switch theme {
        case .light: return false
        case .dark: return true
        case .auto: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
}
