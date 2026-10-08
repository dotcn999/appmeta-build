import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chinese
    var id: String { rawValue }
}

enum AppColorMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    var id: String { rawValue }
}

final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "app.language") }
    }
    @Published var colorMode: AppColorMode {
        didSet { UserDefaults.standard.set(colorMode.rawValue, forKey: "app.colorMode") }
    }

    var isChinese: Bool {
        Self.prefersSimplifiedChinese(selection: language, locale: .current)
    }

    /// Traditional Chinese stays in English until Traditional copy exists.
    static func prefersSimplifiedChinese(selection: AppLanguage, locale: Locale) -> Bool {
        switch selection {
        case .english:
            return false
        case .chinese:
            return true
        case .system:
            let language = locale.language
            guard language.languageCode?.identifier == "zh" else { return false }
            if language.script?.identifier == "Hant" { return false }
            if let region = language.region?.identifier, ["TW", "HK", "MO"].contains(region) { return false }
            return true
        }
    }

    var preferredScheme: ColorScheme? {
        switch colorMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private init() {
        let lang = UserDefaults.standard.string(forKey: "app.language") ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: lang) ?? .system
        let mode = UserDefaults.standard.string(forKey: "app.colorMode") ?? AppColorMode.system.rawValue
        colorMode = AppColorMode(rawValue: mode) ?? .system
    }

    func t(_ en: String, _ zhHans: String) -> String {
        isChinese ? zhHans : en
    }
}

enum L10n {
    static func t(_ en: String, _ zhHans: String) -> String {
        AppearanceStore.shared.t(en, zhHans)
    }
}
