import Foundation

/// The interface is in Russian or English. macOS chooses between the bundle's ru.lproj and en.lproj
/// from the user's preferred languages, including a per-app choice in System Settings → General →
/// Language & Region. Any other language gets English.
enum Language {
    static let isRussian: Bool = {
        let chosen = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        return chosen.hasPrefix("ru")
    }()

    /// For dates and times: Russian, or English with the Mac's region (so 15:00 or 3:00 PM, as the user is used to).
    static let locale: Locale = isRussian
        ? Locale(identifier: "ru_RU")
        : Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))
}

/// Returns the Russian or the English text, whichever the interface uses.
func tr(_ russian: String, _ english: String) -> String {
    Language.isRussian ? russian : english
}

/// A short time span for status lines and cards: "2 ч 13 мин" or "2 h 13 min".
func durationText(minutes: Int) -> String {
    let h = minutes / 60, m = minutes % 60
    if h > 0 { return tr("\(h) ч \(m) мин", "\(h) h \(m) min") }
    return tr("\(m) мин", "\(m) min")
}

/// Text in the interface language's quotation marks: «…» or “…”.
func quoted(_ text: String) -> String {
    tr("«\(text)»", "“\(text)”")
}
