import Foundation

/// Names and codes for the Subtitles panel's two pickers: the language
/// spoken in the takes, and the one to translate into.
enum SubtitleLanguages {
    /// "English" for en-US, "Español" shown as "Spanish" — always in the
    /// user's own language so the list reads naturally.
    static func name(of locale: Locale) -> String {
        guard let code = locale.language.languageCode?.identifier else { return locale.identifier }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// "English (US)" — the locale spelled out, for the picker's subtitle.
    static func fullName(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// "US" for en-US; the short chip VEED shows beside the language.
    static func regionChip(of locale: Locale) -> String {
        if let region = locale.region?.identifier { return region }
        if let script = locale.language.script?.identifier { return String(script.prefix(2)).uppercased() }
        return String((locale.language.languageCode?.identifier ?? "??").prefix(2)).uppercased()
    }

    /// Languages Apple's on-device translator handles well. Codes are BCP 47
    /// as `Locale.Language` wants them.
    static let translationTargets: [String] = [
        "en", "es", "fr", "de", "it", "pt-BR", "nl", "pl", "uk", "ru", "tr",
        "ar", "hi", "th", "vi", "id", "ja", "ko", "zh-Hans", "zh-Hant",
    ]

    static func name(ofLanguage code: String) -> String {
        let language = Locale.Language(identifier: code)
        var name = Locale.current.localizedString(forLanguageCode: language.languageCode?.identifier ?? code) ?? code
        if let script = language.script?.identifier, let scriptName = Locale.current.localizedString(forScriptCode: script) {
            name += " (\(scriptName))"
        } else if let region = language.region?.identifier {
            name += " (\(region))"
        }
        return name
    }

    /// The first translation target that isn't what's being spoken —
    /// English if the takes aren't in English, Spanish if they are.
    static func defaultTranslationTarget(for spoken: String) -> String {
        let spokenCode = Locale(identifier: spoken).language.languageCode?.identifier
        return spokenCode == "en" ? "es" : "en"
    }
}
