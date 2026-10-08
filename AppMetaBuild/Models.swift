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
    var platforms: [String] = []
    var platformKnown = false
    var installed: Bool { !path.isEmpty }
    var supportsIOS: Bool {
        platforms.contains { name in
            let value = name.lowercased()
            return value == "ios" || value == "iphoneos" || value == "iphone" || value.contains("iphoneos")
        }
    }
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
        var text = kindLabel.isEmpty ? star + name : "\(star)\(name) · \(kindLabel)"
        if path.isEmpty {
            text += " · " + L10n.t("Not installed", "未安装")
        } else if expired {
            text += " · " + L10n.t("Expired", "已过期")
        } else if !platformKnown {
            text += " · " + L10n.t("Unknown platform", "平台未知")
        }
        return text
    }
    var value: String { name.isEmpty ? uuid : name }
    var selectable: Bool { installed && !expired && (supportsIOS || !platformKnown) }
}

struct SigningIdentity: Hashable, Sendable {
    var fingerprint = ""
    var name = ""
    var kind = ""
    var line = ""
}

enum Notice: Hashable {
    case pathChanged
    case bundleMissing
    case bundleUnexpanded(String)
    case teamMissing
    case teamUnexpanded(String)
    case noProfile
    case profileMissing(String)
    case profileExpired(String)
    case profilePlatformUnknown(String)
    case profileNotIOS(String)
    case certificateMissing(name: String, development: Bool)
    case legacyIdentity(String)
    case automaticSigning
    case bundleMismatch(profile: String, bundle: String)

    var text: String {
        switch self {
        case .pathChanged:
            return L10n.t(
                "The project path changed. Inspect it again before archiving.",
                "工程路径已改变，请重新识别后再 Archive。"
            )
        case .bundleMissing:
            return L10n.t("No expanded Bundle ID was found for this scheme.", "这个 scheme 没有读到已展开的 Bundle ID。")
        case .bundleUnexpanded(let value):
            return L10n.t("Bundle ID is not expanded: \(value)", "Bundle ID 没有展开：\(value)")
        case .teamMissing:
            return L10n.t("No expanded Team ID was found for this scheme.", "这个 scheme 没有读到已展开的 Team ID。")
        case .teamUnexpanded(let value):
            return L10n.t("Team ID is not expanded: \(value)", "Team ID 没有展开：\(value)")
        case .noProfile:
            return L10n.t(
                "No matching provisioning profile is installed for this Bundle ID.",
                "本机没有和这个 Bundle ID 匹配的描述文件。"
            )
        case .profileMissing(let name):
            return L10n.t(
                "Provisioning profile \"\(name)\" is named by the project but is not installed on this Mac.",
                "工程指定了描述文件 \"\(name)\"，但本机没有安装。"
            )
        case .profileExpired(let name):
            return L10n.t("Provisioning profile \"\(name)\" has expired.", "描述文件 \"\(name)\" 已过期。")
        case .profilePlatformUnknown(let name):
            return L10n.t(
                "Provisioning profile \"\(name)\" does not say which platform it is for.",
                "描述文件 \"\(name)\" 没有标明平台。"
            )
        case .profileNotIOS(let name):
            return L10n.t("Provisioning profile \"\(name)\" is not an iOS profile.", "描述文件 \"\(name)\" 不是 iOS 描述文件。")
        case .certificateMissing(let name, let development):
            let expected = development ? "Apple Development" : "Apple Distribution"
            return L10n.t(
                "Provisioning profile \"\(name)\" does not include a \(expected) certificate from this keychain.",
                "描述文件 \"\(name)\" 不包含本机钥匙串里的 \(expected) 证书。"
            )
        case .legacyIdentity(let name):
            return L10n.t(
                "The project still uses the legacy identity \"\(name)\". This archive will use the matching certificate from the keychain instead.",
                "工程还在用旧的证书名 \"\(name)\"。本次 Archive 会改用钥匙串里匹配到的证书。"
            )
        case .automaticSigning:
            return L10n.t(
                "The project uses Automatic signing. Archive will pass manual signing on the command line and will not edit the project.",
                "工程使用 Automatic 签名。Archive 会在命令行改用手动签名，不会修改工程文件。"
            )
        case .bundleMismatch(let profile, let bundle):
            return L10n.t(
                "Provisioning profile \"\(profile)\" does not match Bundle ID \(bundle).",
                "描述文件 \"\(profile)\" 和 Bundle ID \(bundle) 不匹配。"
            )
        }
    }
}

struct SigningAssessment: Equatable {
    var ready = false
    var warnings: [Notice] = []
    var identityName = ""
    var expectsDevelopment = false
    var certificateFound = false
}

struct ProfileGroup: Identifiable {
    var id: String { kind.isEmpty ? "other" : kind }
    var kind = ""
    var title = ""
    var profiles: [ProfileInfo] = []
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
    var marketingVersion = ""
    var buildNumber = ""
    var containerKind = "project"
    var products: [SignedProduct] = []
    var signingStyle = ""
    var codeSignIdentity = ""
    var profileSpecifier = ""
    var distributionCerts: [String] = []
    var developmentCerts: [String] = []
    var identities: [SigningIdentity] = []
    var profiles: [ProfileInfo] = []
    var selectedProfile: ProfileInfo?
    var warnings: [Notice] = []
    var ready = false
    var usesDevelopmentSigning: Bool {
        configuration.lowercased().contains("debug")
    }
}

struct Credentials: Codable, Equatable, Sendable {
    var keyId = ""
    var issuerId = ""
    var storedKeyId = ""
    var hasPrivateKey = false
    /// Read from older config files so the key can be moved into the keychain. Never written back.
    var legacyPrivateKeyPath = ""

    var isComplete: Bool {
        Self.isValidKeyID(keyId)
            && keyId == storedKeyId
            && Self.isValidIssuerID(issuerId)
            && hasPrivateKey
    }

    static func isValidKeyID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 10 && trimmed.allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func isValidIssuerID(_ value: String) -> Bool {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private enum CodingKeys: String, CodingKey {
        case keyId, issuerId, storedKeyId, hasPrivateKey, privateKeyPath
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyId = try container.decodeIfPresent(String.self, forKey: .keyId) ?? ""
        issuerId = try container.decodeIfPresent(String.self, forKey: .issuerId) ?? ""
        storedKeyId = try container.decodeIfPresent(String.self, forKey: .storedKeyId) ?? ""
        hasPrivateKey = try container.decodeIfPresent(Bool.self, forKey: .hasPrivateKey) ?? false
        legacyPrivateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyId, forKey: .keyId)
        try container.encode(issuerId, forKey: .issuerId)
        try container.encode(storedKeyId, forKey: .storedKeyId)
        try container.encode(hasPrivateKey, forKey: .hasPrivateKey)
    }
}

struct ArchiveProduct: Equatable, Sendable {
    var ipaPath: String
    var logPath: String
    var version = ""
    var build = ""
    var metadataPath = ""
}

struct SignedProduct: Hashable, Identifiable, Codable, Sendable {
    var id: String { bundleId }
    var target = ""
    var bundleId = ""
    var productType = ""
    var profileSpecifier = ""
    var profileName = ""
    var profileKind = ""
    var isMain = false
}

struct ExportMetadata: Codable, Equatable, Sendable {
    var method = ""
    var bundleId = ""
    var version = ""
    var build = ""
    var profile = ""
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
