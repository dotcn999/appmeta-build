import Foundation

struct ProfileInfo: Hashable, Identifiable {
    var id: String { uuid.isEmpty ? name : uuid }
    var uuid = ""
    var name = ""
    var teamId = ""
    var teamName = ""
    var bundleId = ""
    var appId = ""
    var isAppStore = false
    var expired = false
    var match = ""
    var path = ""
    var displayName: String { match == "project" ? "\(name) ★" : name }
    var value: String { name.isEmpty ? uuid : name }
}

struct InspectResult {
    var projectPath = ""
    var projectName = ""
    var schemes: [String] = []
    var suggestedScheme = ""
    var bundleId = ""
    var teamId = ""
    var productName = ""
    var signingStyle = ""
    var codeSignIdentity = ""
    var profileSpecifier = ""
    var distributionCerts: [String] = []
    var profiles: [ProfileInfo] = []
    var selectedProfile: ProfileInfo?
    var warnings: [String] = []
    var ready = false
}

struct Credentials: Codable, Equatable {
    var keyId = ""
    var issuerId = ""
    var privateKeyPath = ""
    var isComplete: Bool {
        !keyId.trimmingCharacters(in: .whitespaces).isEmpty
            && !issuerId.trimmingCharacters(in: .whitespaces).isEmpty
            && FileManager.default.isReadableFile(atPath: privateKeyPath)
    }
}

enum BuildError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        }
    }
}
