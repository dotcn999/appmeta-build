import Foundation

struct ProfileInfo: Hashable, Identifiable {
    var id: String { uuid.isEmpty ? name : uuid }
    var uuid = ""
    var name = ""
    var teamId = ""
    var teamName = ""
    var bundleId = ""
    var appId = ""
    /// appstore | development | adhoc | enterprise
    var kind = ""
    var isAppStore = false
    var expired = false
    var match = ""
    var path = ""
    var certFingerprints: [String] = []
    var displayName: String {
        let star = match == "project" ? "★ " : ""
        let kindLabel: String
        switch kind {
        case "appstore": kindLabel = L10n.t("App Store", "App Store")
        case "development": kindLabel = L10n.t("Development", "开发")
        case "adhoc": kindLabel = L10n.t("Ad Hoc", "Ad Hoc")
        case "enterprise": kindLabel = L10n.t("Enterprise", "企业")
        default: kindLabel = ""
        }
        if kindLabel.isEmpty { return star + name }
        return "\(star)\(name) · \(kindLabel)"
    }
    var value: String { name.isEmpty ? uuid : name }
}

struct InspectResult {
    var projectPath = ""
    var projectName = ""
    var schemes: [String] = []
    var suggestedScheme = ""
    var configuration = ""
    var bundleId = ""
    var teamId = ""
    var productName = ""
    var signingStyle = ""
    var codeSignIdentity = ""
    var profileSpecifier = ""
    var distributionCerts: [String] = []
    var developmentCerts: [String] = []
    var profiles: [ProfileInfo] = []
    var selectedProfile: ProfileInfo?
    var warnings: [String] = []
    var ready = false
    var usesDevelopmentSigning: Bool {
        configuration.lowercased().contains("debug")
    }
}

struct Credentials: Codable, Equatable, Sendable {
    var keyId = ""
    var issuerId = ""
    var privateKeyPath = ""
    var isComplete: Bool {
        !keyId.trimmingCharacters(in: .whitespaces).isEmpty
            && !issuerId.trimmingCharacters(in: .whitespaces).isEmpty
            && FileManager.default.isReadableFile(atPath: privateKeyPath)
    }
}

struct ArchiveProduct: Equatable, Sendable {
    var ipaPath: String
    var logPath: String
}

enum BuildError: LocalizedError, Equatable {
    case message(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .cancelled: return L10n.t("Cancelled.", "已取消。")
        }
    }
}
