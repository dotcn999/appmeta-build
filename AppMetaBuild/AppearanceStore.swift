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
        switch language {
        case .system:
            return Locale.current.language.languageCode?.identifier == "zh"
        case .chinese:
            return true
        case .english:
            return false
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
