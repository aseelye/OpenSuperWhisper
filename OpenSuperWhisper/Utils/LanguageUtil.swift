import Foundation

/// Locale discovery and migration helpers shared by onboarding, Settings, and
/// both transcription providers.
///
/// Apple owns the list of locales supported by SpeechTranscriber. This small
/// fallback list is used synchronously until the asset manager loads Apple's
/// current list.
enum LanguageUtil {
    private static let fallbackLocaleIdentifiers = [
        "ar-SA", "ca-ES", "cs-CZ", "da-DK", "de-DE", "el-GR", "en-AU", "en-CA",
        "en-GB", "en-IN", "en-US", "es-ES", "es-MX", "fi-FI", "fr-CA", "fr-FR",
        "he-IL", "hi-IN", "hr-HR", "hu-HU", "id-ID", "it-IT", "ja-JP", "ko-KR",
        "ms-MY", "nb-NO", "nl-NL", "pl-PL", "pt-BR", "pt-PT", "ro-RO", "ru-RU",
        "sk-SK", "sv-SE", "th-TH", "tr-TR", "uk-UA", "vi-VN", "zh-CN", "zh-TW"
    ]

    /// Canonical BCP-47 identifiers available synchronously during startup.
    /// Settings and onboarding replace this fallback with Apple's current
    /// dynamic list as soon as the asset manager refreshes.
    static var availableLocaleIdentifiers: [String] {
        localeIdentifiers(for: availableLocales)
    }

    /// Locale values available synchronously during startup/migration.
    static var availableLocales: [Locale] {
        fallbackLocaleIdentifiers.map(Locale.init(identifier:))
    }

    static func localeIdentifiers(for locales: [Locale]) -> [String] {
        var seen = Set<String>()
        return locales
            .map(localeIdentifier(for:))
            .filter { seen.insert($0).inserted }
    }

    /// The locale selected for a new installation: the first preferred system
    /// language with an Apple-supported equivalent, then en-US, then Apple's
    /// first advertised locale as a final defensive fallback.
    static var defaultLocaleIdentifier: String {
        let supported = availableLocaleIdentifiers

        for preferred in Locale.preferredLanguages {
            if let equivalent = equivalentLocaleIdentifier(for: preferred, in: supported) {
                return equivalent
            }
        }

        if let english = equivalentLocaleIdentifier(for: "en-US", in: supported) {
            return english
        }

        return supported.first ?? "en-US"
    }

    static func displayName(for identifier: String) -> String {
        let canonical = canonicalIdentifier(identifier)
        let display = Locale.current.localizedString(forIdentifier: canonical)
            ?? Locale(identifier: canonical).localizedString(forIdentifier: canonical)
        return display?.localizedCapitalized ?? canonical
    }

    static func localeIdentifier(for locale: Locale) -> String {
        canonicalIdentifier(locale.identifier)
    }

    static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        canonicalIdentifier(identifier)
    }

    static func locale(for identifier: String) -> Locale {
        Locale(identifier: canonicalIdentifier(identifier))
    }

    /// Converts a legacy Whisper language (`en`, `zh`, `auto`, …) to one
    /// Apple-supported regional locale. Unknown values follow the normal
    /// system/en-US fallback rules.
    static func localeIdentifier(forLegacyWhisperLanguage value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultLocaleIdentifier
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.caseInsensitiveCompare("auto") != .orderedSame else {
            return defaultLocaleIdentifier
        }

        let candidate = equivalentLocaleIdentifier(for: normalized, in: availableLocaleIdentifiers)
        return candidate ?? defaultLocaleIdentifier
    }

    private static func equivalentLocaleIdentifier(for identifier: String, in supported: [String]) -> String? {
        guard !supported.isEmpty else { return nil }

        let requested = Locale(identifier: canonicalIdentifier(identifier))
        let requestedLanguage = requested.language.languageCode?.identifier.lowercased()
        let requestedScript = requested.language.script?.identifier.lowercased()
        let requestedRegion = requested.region?.identifier.uppercased()

        let ranked = supported.enumerated().compactMap { index, value -> (Int, Int, String)? in
            let candidate = Locale(identifier: value)
            guard let language = candidate.language.languageCode?.identifier.lowercased(), language == requestedLanguage else {
                return nil
            }

            let script = candidate.language.script?.identifier.lowercased()
            let region = candidate.region?.identifier.uppercased()
            let score: Int
            switch (requestedScript, requestedRegion) {
            case let (requestedScript?, requestedRegion?) where script == requestedScript && region == requestedRegion:
                score = 0
            case let (_, requestedRegion?) where region == requestedRegion:
                score = 1
            case let (requestedScript?, _) where script == requestedScript:
                score = 2
            default:
                // A bare English preference is most predictably represented
                // by en-US instead of whichever regional locale sorts first.
                score = requestedLanguage == "en" && region == "US" ? 2 : 3
            }
            return (score, index, value)
        }

        return ranked.sorted {
            if $0.0 == $1.0 { return $0.1 < $1.1 }
            return $0.0 < $1.0
        }.first?.2
    }

    private static func canonicalIdentifier(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "en-US" }

        // Locale accepts both underscore and BCP-47 separators. Preserve
        // extension/private-use subtags by only normalizing the separator and
        // the conventional language/script/region casing.
        let locale = Locale(identifier: trimmed.replacingOccurrences(of: "_", with: "-"))
        let raw = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let parts = raw.split(separator: "-").map(String.init)
        guard let language = parts.first, !language.isEmpty else { return "en-US" }

        var normalized = [language.lowercased()]
        var index = 1
        if index < parts.count, parts[index].count == 4 {
            normalized.append(parts[index].lowercased().localizedCapitalized)
            index += 1
        }
        if index < parts.count, parts[index].count == 2 || (index < parts.count && parts[index].count == 3 && parts[index].allSatisfy(\.isNumber)) {
            normalized.append(parts[index].uppercased())
            index += 1
        }
        if index < parts.count {
            normalized.append(contentsOf: parts[index...].map { $0.lowercased() })
        }
        return normalized.joined(separator: "-")
    }
}
