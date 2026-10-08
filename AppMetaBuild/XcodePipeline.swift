import Foundation
import CryptoKit

final class XcodePipeline: @unchecked Sendable {
    private let commands: CommandExecuting
    private static let profileCacheLock = NSLock()
    private static var profileCache: [String: ProfileCacheEntry] = [:]

    init(commands: CommandExecuting = CommandSession()) {
        self.commands = commands
    }

    func prepareForNewOperation() {
        commands.prepareForNewOperation()
    }

    func cancel() {
        commands.cancel()
    }

    private func checkCancelled() throws {
        if commands.isCancelled { throw BuildError.cancelled }
    }

    func inspect(projectPath: String, scheme: String) throws -> InspectResult {
        try checkCancelled()
        let project = try Self.resolveXcodeproj(projectPath)
        var res = InspectResult(projectPath: project)
        let listData = try runCapturing(["/usr/bin/xcodebuild", "-list", "-json", "-project", project])
        let (name, schemes) = try Self.parseList(listData)
        res.projectName = name
        res.schemes = schemes
        res.suggestedScheme = scheme.isEmpty ? Self.suggestReleaseScheme(schemes) : scheme
        if res.suggestedScheme.isEmpty {
            throw BuildError.message(L10n.t("No scheme found; share a scheme in Xcode.", "没有 scheme；请在 Xcode 里 Share 一个 scheme。"))
        }
        res.configuration = Self.resolveConfiguration(project: project, scheme: res.suggestedScheme)
        var settingsArgs = [
            "/usr/bin/xcodebuild", "-showBuildSettings", "-json",
            "-project", project, "-scheme", res.suggestedScheme,
            "-destination", "generic/platform=iOS",
        ]
        if !res.configuration.isEmpty {
            settingsArgs += ["-configuration", res.configuration]
        }
        do {
            let settingsData = try runCapturing(settingsArgs)
            let settings = Self.pickSettings(settingsData)
            res.bundleId = settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? ""
            res.teamId = settings["DEVELOPMENT_TEAM"] ?? ""
            res.productName = settings["PRODUCT_NAME"] ?? ""
            res.signingStyle = settings["CODE_SIGN_STYLE"] ?? ""
            res.codeSignIdentity = settings["CODE_SIGN_IDENTITY"] ?? ""
            res.profileSpecifier = settings["PROVISIONING_PROFILE_SPECIFIER"] ?? settings["PROVISIONING_PROFILE"] ?? ""
            if res.configuration.isEmpty {
                res.configuration = settings["CONFIGURATION"] ?? ""
            }
        } catch BuildError.cancelled {
            throw BuildError.cancelled
        } catch {
            // Build settings are best-effort; the warnings below explain what is missing.
        }
        var specifiers = Self.pbxprojProfileSpecifiers(project)
        if !res.profileSpecifier.isEmpty { specifiers.insert(res.profileSpecifier, at: 0) }
        specifiers = Self.uniqueKeepOrder(specifiers)
        if res.profileSpecifier.isEmpty { res.profileSpecifier = specifiers.first ?? "" }
        var identityLines: [String] = []
        do {
            let ident = try runCapturing(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
            let text = String(data: ident, encoding: .utf8) ?? ""
            identityLines = text.split(separator: "\n").map(String.init)
            res.distributionCerts = identityLines.filter {
                $0.contains("Apple Distribution") || $0.contains("iPhone Distribution")
            }
            res.developmentCerts = identityLines.filter {
                $0.contains("Apple Development") || $0.contains("iPhone Developer")
            }
        } catch BuildError.cancelled {
            throw BuildError.cancelled
        } catch {
            // A missing identity list is reported as "certificate not found".
        }
        let installed = try installedProfiles()
        res.profiles = Self.matchProfiles(
            installed,
            bundleId: res.bundleId,
            teamId: res.teamId,
            specifiers: specifiers,
            configuration: res.configuration
        )
        for spec in specifiers {
            if res.profiles.contains(where: { $0.name == spec || $0.uuid == spec }) { continue }
            var missing = ProfileInfo()
            missing.name = spec
            missing.match = "project"
            missing.kind = res.usesDevelopmentSigning ? "development" : "appstore"
            res.profiles.insert(missing, at: 0)
            res.warnings.append(L10n.t(
                "Project specifies provisioning profile \"\(spec)\", but it is not installed on this Mac.",
                "工程指定了描述文件 \"\(spec)\"，但本机没有安装这份文件。"
            ))
        }
        res.selectedProfile = res.profiles.first
        if res.signingStyle.lowercased() == "automatic" {
            res.warnings.append(L10n.t(
                "Signing style is Automatic. This app exports with manual signing; set the scheme to Manual in Xcode.",
                "签名方式是 Automatic。本应用按手动签名导出；请在 Xcode 把该 scheme 设为 Manual。"
            ))
        }
        if res.usesDevelopmentSigning {
            if res.developmentCerts.isEmpty {
                res.warnings.append(L10n.t(
                    "No Apple Development certificate in the keychain. Import it in Xcode or Keychain Access.",
                    "钥匙串里没有 Apple Development 证书。请在 Xcode 或钥匙串中导入。"
                ))
            }
        } else if res.distributionCerts.isEmpty {
            res.warnings.append(L10n.t(
                "No Apple Distribution certificate in the keychain. Import it in Xcode or Keychain Access.",
                "钥匙串里没有 Apple Distribution 证书。请在 Xcode 或钥匙串中导入。"
            ))
        }
        if res.selectedProfile == nil {
            if res.usesDevelopmentSigning {
                res.warnings.append(L10n.t(
                    "No matching Development provisioning profile. Double-click the .mobileprovision or assign it on this scheme in Xcode.",
                    "没有匹配的开发描述文件。请双击 .mobileprovision，或在 Xcode 的该 scheme 上指定。"
                ))
            } else {
                res.warnings.append(L10n.t(
                    "No matching App Store provisioning profile. Double-click the .mobileprovision or assign it on this scheme in Xcode.",
                    "没有匹配的 App Store 描述文件。请双击 .mobileprovision，或在 Xcode 的该 scheme 上指定。"
                ))
            }
        }
        let identity = res.codeSignIdentity.lowercased()
        if (identity.contains("iphone developer") || identity == "iphone distribution")
            && (res.developmentCerts.contains(where: { $0.contains("Apple Development") })
                || res.distributionCerts.contains(where: { $0.contains("Apple Distribution") })) {
            res.warnings.append(L10n.t(
                "The project still uses the legacy identity \"\(res.codeSignIdentity)\". Keychain has Apple Development / Distribution; set Signing Certificate in Xcode to match, or the profile will show as not including the cert.",
                "工程还在用旧的证书名 \"\(res.codeSignIdentity)\"。钥匙串里是 Apple Development / Distribution；请在 Xcode 把 Signing Certificate 改成对应证书，否则会提示描述文件不包含该证书。"
            ))
        }
        if let selected = res.selectedProfile, selected.expired {
            res.warnings.append(L10n.t(
                "Provisioning profile \"\(selected.name)\" has expired.",
                "描述文件 \"\(selected.name)\" 已过期。"
            ))
        }
        if let selected = res.selectedProfile, !selected.certFingerprints.isEmpty {
            let keychain = Set(Self.identityFingerprints(identityLines))
            let overlap = selected.certFingerprints.contains { keychain.contains($0) }
            if !overlap && !keychain.isEmpty {
                res.warnings.append(L10n.t(
                    "Provisioning profile \"\(selected.name)\" does not include the signing certificate currently in the keychain. Recreate the profile with this certificate, or pick a certificate that is already in the profile.",
                    "描述文件 \"\(selected.name)\" 不包含当前钥匙串里的签名证书。请用这张证书重新生成描述文件，或改选描述文件里已有的证书。"
                ))
            }
        }
        let hasCert = res.usesDevelopmentSigning ? !res.developmentCerts.isEmpty : !res.distributionCerts.isEmpty
        res.ready = !res.bundleId.isEmpty && !res.teamId.isEmpty && res.selectedProfile != nil && hasCert
        return res
    }

    func archiveAndExport(
        project: String,
        scheme: String,
        configuration: String,
        teamId: String,
        bundleId: String,
        profile: String,
        profileKind: String,
        onLog: @escaping (String) -> Void,
        onStage: @escaping (String, String) -> Void
    ) throws -> ArchiveProduct {
        try checkCancelled()
        let proj = try Self.resolveXcodeproj(project)
        let config = configuration.isEmpty ? "Release" : configuration
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: Date())
        let outDir = URL(fileURLWithPath: proj).deletingLastPathComponent()
            .appendingPathComponent("build/appmeta-local/\(stamp)", isDirectory: true)
        let exportDir = outDir.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let logURL = outDir.appendingPathComponent("build.log")
        let archivePath = outDir.appendingPathComponent("\(scheme).xcarchive").path
        let plistPath = outDir.appendingPathComponent("ExportOptions.plist").path
        try Self.exportOptionsPlist(teamId: teamId, bundleId: bundleId, profile: profile, profileKind: profileKind)
            .write(toFile: plistPath, atomically: true, encoding: .utf8)

        let logger = LineLog(url: logURL)
        defer { logger?.close() }
        let emit: (String) -> Void = { line in
            logger?.write(line)
            onLog(line)
        }
        emit("Log: \(logURL.path)")
        onStage("archive", L10n.t("Archiving \(config). This can take several minutes.", "正在 Archive \(config)，可能需要几分钟。"))
        emit("xcodebuild archive -project \(proj) -scheme \(scheme) -configuration \(config)")
        let workDirectory = URL(fileURLWithPath: proj).deletingLastPathComponent().path
        try runStreaming(onLog: emit, arguments: [
            "/usr/bin/xcodebuild", "archive",
            "-project", proj,
            "-scheme", scheme,
            "-configuration", config,
            "-destination", "generic/platform=iOS",
            "-archivePath", archivePath,
        ], directory: workDirectory)
        try checkCancelled()

        onStage("export", L10n.t("Exporting a manually signed IPA.", "正在导出手动签名 IPA。"))
        emit("xcodebuild -exportArchive")
        try runStreaming(onLog: emit, arguments: [
            "/usr/bin/xcodebuild", "-exportArchive",
            "-archivePath", archivePath,
            "-exportPath", exportDir.path,
            "-exportOptionsPlist", plistPath,
        ], directory: workDirectory)

        guard let ipa = Self.firstIPA(in: exportDir.path) else {
            throw BuildError.message(L10n.t("Export finished but no IPA was produced.", "导出结束但没有生成 IPA。"))
        }
        onLog("IPA: \(ipa)")
        return ArchiveProduct(ipaPath: ipa, logPath: logURL.path)
    }

    func upload(ipa: String, credentials: Credentials, logFile: URL? = nil, onLog: @escaping (String) -> Void, onStage: @escaping (String, String) -> Void) throws {
        try checkCancelled()
        onStage("upload", L10n.t("Uploading IPA to App Store Connect.", "正在上传 IPA 到 App Store Connect。"))
        let keyDir = try Self.prepareKeyDir(credentials)
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let env = ["API_PRIVATE_KEYS_DIR": keyDir.path]
        let directory = (ipa as NSString).deletingLastPathComponent
        onLog("xcrun altool --upload-app -t ios --show-progress")
        do {
            try runStreaming(onLog: onLog, arguments: [
                "/usr/bin/xcrun", "altool", "--upload-app",
                "-f", ipa, "-t", "ios",
                "--apiKey", credentials.keyId,
                "--apiIssuer", credentials.issuerId,
                "--show-progress",
            ], directory: directory, extraEnv: env, logFile: logFile)
        } catch BuildError.cancelled {
            throw BuildError.cancelled
        } catch {
            try checkCancelled()
            onLog("altool failed, trying iTMSTransporter: \(error.localizedDescription)")
            try runStreaming(onLog: onLog, arguments: [
                "/usr/bin/xcrun", "iTMSTransporter", "-m", "upload",
                "-assetFile", ipa,
                "-apiKey", credentials.keyId,
                "-apiIssuer", credentials.issuerId,
            ], directory: directory, extraEnv: env, logFile: logFile)
        }
        onStage("uploaded", L10n.t(
            "Delivery succeeded. Apple still needs to process the build before it appears in App Store Connect.",
            "投递成功。Apple 还要处理构建，之后才会出现在 App Store Connect。"
        ))
    }

    private func runCapturing(_ arguments: [String]) throws -> Data {
        try checkCancelled()
        let output = try commands.run(
            arguments: arguments,
            directory: "",
            extraEnvironment: [:],
            onLog: nil,
            logFile: nil
        )
        return output.stdout
    }

    private func runStreaming(
        onLog: @escaping (String) -> Void,
        arguments: [String],
        directory: String,
        extraEnv: [String: String] = [:],
        logFile: URL? = nil
    ) throws {
        try checkCancelled()
        _ = try commands.run(
            arguments: arguments,
            directory: directory,
            extraEnvironment: extraEnv,
            onLog: onLog,
            logFile: logFile
        )
    }

    static func resolveXcodeproj(_ path: String) throws -> String {
        var path = (path as NSString).expandingTildeInPath
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw BuildError.message(L10n.t("Project path not found.", "找不到工程路径。"))
        }
        if path.lowercased().hasSuffix(".xcodeproj") { return path }
        if path.lowercased().hasSuffix(".xcworkspace") {
            throw BuildError.message(L10n.t("This app currently supports .xcodeproj only.", "当前只支持 .xcodeproj。"))
        }
        let matches = (try? FileManager.default.contentsOfDirectory(atPath: path))?.filter { $0.lowercased().hasSuffix(".xcodeproj") } ?? []
        if matches.count == 1 { return (path as NSString).appendingPathComponent(matches[0]) }
        if matches.count > 1 {
            throw BuildError.message(L10n.t("Folder contains multiple .xcodeproj files; pick one.", "文件夹里有多个 .xcodeproj，请选其中一个。"))
        }
        throw BuildError.message(L10n.t("No .xcodeproj found.", "没有找到 .xcodeproj。"))
    }

    static func suggestReleaseScheme(_ schemes: [String]) -> String {
        schemes.first { $0.lowercased().contains("release") } ?? schemes.first ?? ""
    }

    static func inferredConfigurationName(_ scheme: String) -> String {
        let n = scheme.lowercased()
        if n.contains("debug") || n.contains("develop") || n.hasSuffix("-dev") || n.hasSuffix("_dev") || n.contains(".dev") {
            return "Debug"
        }
        if n.contains("release") || n.contains("appstore") || n.contains("app-store") || n.contains("distribution") || n.contains("prod") {
            return "Release"
        }
        return ""
    }

    static func resolveConfiguration(project: String, scheme: String) -> String {
        let inferred = inferredConfigurationName(scheme)
        guard let xml = schemeXML(project: project, scheme: scheme) else {
            return inferred.isEmpty ? "Release" : inferred
        }
        let launch = actionBuildConfiguration(xml: xml, action: "LaunchAction")
        let archive = actionBuildConfiguration(xml: xml, action: "ArchiveAction")
        if inferred == "Debug" {
            return launch.isEmpty ? "Debug" : launch
        }
        if inferred == "Release" {
            return archive.isEmpty ? "Release" : archive
        }
        if !archive.isEmpty { return archive }
        if !launch.isEmpty { return launch }
        return "Release"
    }

    static func schemeXML(project: String, scheme: String) -> String? {
        let proj = URL(fileURLWithPath: project)
        var candidates = [
            proj.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme"),
        ]
        let userdata = proj.appendingPathComponent("xcuserdata")
        if let users = try? FileManager.default.contentsOfDirectory(atPath: userdata.path) {
            for user in users {
                candidates.append(userdata.appendingPathComponent("\(user)/xcschemes/\(scheme).xcscheme"))
            }
        }
        for url in candidates {
            if let xml = try? String(contentsOf: url, encoding: .utf8) { return xml }
        }
        return nil
    }

    static func actionBuildConfiguration(xml: String, action: String) -> String {
        guard let start = xml.range(of: "<\(action)", options: .caseInsensitive) else { return "" }
        let fromAction = xml[start.lowerBound...]
        guard let tagEnd = fromAction.range(of: ">") else { return "" }
        let openTag = String(fromAction[..<tagEnd.upperBound])
        guard let regex = try? NSRegularExpression(pattern: #"buildConfiguration\s*=\s*"([^"]+)""#) else { return "" }
        let range = NSRange(openTag.startIndex..., in: openTag)
        guard let match = regex.firstMatch(in: openTag, range: range),
              let capture = Range(match.range(at: 1), in: openTag) else { return "" }
        return String(openTag[capture])
    }

    static func parseList(_ data: Data) throws -> (String, [String]) {
        let obj = try JSONPayload.object(from: data)
        if let project = obj["project"] as? [String: Any], let schemes = project["schemes"] as? [String], !schemes.isEmpty {
            return (project["name"] as? String ?? "", schemes)
        }
        if let workspace = obj["workspace"] as? [String: Any], let schemes = workspace["schemes"] as? [String], !schemes.isEmpty {
            return (workspace["name"] as? String ?? "", schemes)
        }
        throw BuildError.message(L10n.t("No shared schemes in this project.", "工程里没有 shared scheme。"))
    }

    static func jsonArray(from data: Data) -> [[String: Any]]? {
        JSONPayload.array(from: data)
    }

    static func stringSettings(_ raw: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in raw {
            if let s = value as? String {
                out[key] = s
            } else if let arr = value as? [String] {
                out[key] = arr.joined(separator: " ")
            } else if let n = value as? NSNumber {
                out[key] = n.stringValue
            }
        }
        return out
    }

    static func pickSettings(_ data: Data) -> [String: String] {
        guard let arr = jsonArray(from: data) else { return [:] }
        var fallback: [String: String]?
        for entry in arr {
            let target = ((entry["target"] as? String) ?? "").lowercased()
            if target.contains("test") { continue }
            let settings = stringSettings(entry["buildSettings"] as? [String: Any] ?? [:])
            if fallback == nil { fallback = settings }
            let bid = settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? ""
            if !bid.isEmpty && !bid.contains("$") { return settings }
        }
        return fallback ?? [:]
    }

    static func uniqueKeepOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items where !item.isEmpty && seen.insert(item).inserted {
            out.append(item)
        }
        return out
    }

    static func pbxprojProfileSpecifiers(_ project: String) -> [String] {
        let url = URL(fileURLWithPath: project).appendingPathComponent("project.pbxproj")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let regex = try? NSRegularExpression(
                pattern: #"PROVISIONING_PROFILE(?:_SPECIFIER)?(?:\[[^\]]+\])?\s*=\s*(?:"([^"]*)"|([^;]*));"#
              ) else { return [] }
        let ns = text as NSString
        var specs: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let quoted = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : ""
            let bare = match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let value = quoted.isEmpty ? bare : quoted
            if !value.isEmpty { specs.append(value) }
        }
        return uniqueKeepOrder(specs)
    }

    static func identityFingerprints(_ lines: [String]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9A-Fa-f]{40})\s+""#) else { return [] }
        var hashes: [String] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let capture = Range(match.range(at: 1), in: line) else { continue }
            hashes.append(String(line[capture]).uppercased())
        }
        return hashes
    }

    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    func installedProfiles() throws -> [ProfileInfo] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [
            home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles"),
            home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
        ]
        var seen = Set<String>()
        var result: [ProfileInfo] = []
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in files {
                try checkCancelled()
                let lower = name.lowercased()
                guard lower.hasSuffix(".mobileprovision") || lower.hasSuffix(".provisionprofile") else { continue }
                let path = dir.appendingPathComponent(name).path
                guard let info = try decodeProfile(path) else { continue }
                let key = info.uuid.isEmpty ? path : info.uuid
                if seen.insert(key).inserted {
                    result.append(info)
                }
            }
        }
        return result
    }

    func decodeProfile(_ path: String) throws -> ProfileInfo? {
        if let cached = Self.cachedProfile(at: path) { return cached }
        let xml: Data
        do {
            xml = try runCapturing(["/usr/bin/security", "cms", "-D", "-i", path])
        } catch BuildError.cancelled {
            throw BuildError.cancelled
        } catch {
            return nil
        }
        guard let info = Self.profileInfo(from: xml, path: path) else { return nil }
        Self.storeProfile(info, at: path)
        return info
    }

    private struct ProfileCacheEntry {
        var modified: Date
        var size: UInt64
        var info: ProfileInfo
    }

    private static func fileStamp(_ path: String) -> (Date, UInt64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return (modified, size)
    }

    private static func cachedProfile(at path: String) -> ProfileInfo? {
        guard let (modified, size) = fileStamp(path) else { return nil }
        profileCacheLock.lock()
        defer { profileCacheLock.unlock() }
        guard let entry = profileCache[path], entry.modified == modified, entry.size == size else { return nil }
        return entry.info
    }

    private static func storeProfile(_ info: ProfileInfo, at path: String) {
        guard let (modified, size) = fileStamp(path) else { return }
        profileCacheLock.lock()
        profileCache[path] = ProfileCacheEntry(modified: modified, size: size, info: info)
        profileCacheLock.unlock()
    }

    static func profileInfo(from xml: Data, path: String) -> ProfileInfo? {
        guard let obj = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any]
        else { return nil }
        let entitlements = obj["Entitlements"] as? [String: Any] ?? [:]
        let appId = (entitlements["application-identifier"] as? String)
            ?? (entitlements["com.apple.application-identifier"] as? String)
            ?? ""
        let getTaskAllow = boolValue(entitlements["get-task-allow"])
        let devices = obj["ProvisionedDevices"] as? [Any] ?? []
        let allDevices = boolValue(obj["ProvisionsAllDevices"])
        let teams = (obj["TeamIdentifier"] as? [String]) ?? []
        var info = ProfileInfo()
        info.uuid = obj["UUID"] as? String ?? ""
        info.name = obj["Name"] as? String ?? ""
        info.teamId = teams.first ?? ""
        info.teamName = obj["TeamName"] as? String ?? ""
        info.appId = appId
        if let dot = appId.firstIndex(of: ".") {
            info.bundleId = String(appId[appId.index(after: dot)...])
        } else {
            info.bundleId = appId
        }
        if allDevices {
            info.kind = "enterprise"
        } else if getTaskAllow {
            info.kind = "development"
        } else if !devices.isEmpty {
            info.kind = "adhoc"
        } else {
            info.kind = "appstore"
        }
        info.isAppStore = info.kind == "appstore"
        if let exp = obj["ExpirationDate"] as? Date {
            info.expired = exp < Date()
        } else if let exp = obj["ExpirationDate"] as? String {
            info.expired = (ISO8601DateFormatter().date(from: exp) ?? Date.distantFuture) < Date()
        }
        if let certs = obj["DeveloperCertificates"] as? [Data] {
            info.certFingerprints = certs.map(sha1Hex)
        }
        info.path = path
        return info
    }

    static func boolValue(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String { return ["true", "YES", "1"].contains(s) }
        return false
    }

    static func preferredProfileKinds(for configuration: String) -> [String] {
        let c = configuration.lowercased()
        if c.contains("debug") { return ["development"] }
        if c.contains("adhoc") || c.contains("ad-hoc") || c.contains("ad_hoc") { return ["adhoc"] }
        if c.contains("enterprise") { return ["enterprise"] }
        return ["appstore"]
    }

    static func matchProfiles(
        _ profiles: [ProfileInfo],
        bundleId: String,
        teamId: String,
        specifiers: [String],
        configuration: String
    ) -> [ProfileInfo] {
        let preferred = Set(preferredProfileKinds(for: configuration))
        let specSet = Set(specifiers)
        func isSpecified(_ p: ProfileInfo) -> Bool {
            specSet.contains(p.name) || specSet.contains(p.uuid)
        }
        let matched: [ProfileInfo] = profiles.compactMap { raw in
            var p = raw
            let specified = isSpecified(p)
            if specified {
                p.match = "project"
                return p
            }
            if p.expired { return nil }
            if !teamId.isEmpty && !p.teamId.isEmpty && p.teamId != teamId { return nil }
            if !bundleMatches(p.bundleId, bundleId) { return nil }
            p.match = "installed"
            return p
        }
        // Project-specified profiles always stay. Kind filter only hides extras.
        let specified = matched.filter { $0.match == "project" }
        let rest = matched.filter { $0.match != "project" }
        let narrowedRest = rest.filter { preferred.contains($0.kind) }
        let list = (specified + (narrowedRest.isEmpty ? rest : narrowedRest)).sorted {
            if $0.match != $1.match { return $0.match == "project" }
            if $0.expired != $1.expired { return !$0.expired }
            let aPref = preferred.contains($0.kind)
            let bPref = preferred.contains($1.kind)
            if aPref != bPref { return aPref }
            return $0.name < $1.name
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.value).inserted }
    }

    static func bundleMatches(_ profileBundle: String, _ appBundle: String) -> Bool {
        if profileBundle.isEmpty || appBundle.isEmpty { return false }
        if profileBundle == "*" { return true }
        if profileBundle.hasSuffix(".*") {
            let prefix = String(profileBundle.dropLast(2))
            return appBundle == prefix || appBundle.hasPrefix(prefix + ".")
        }
        return profileBundle == appBundle
    }

    static func exportMethod(for kind: String) -> String {
        switch kind {
        case "development": return "development"
        case "adhoc": return "ad-hoc"
        case "enterprise": return "enterprise"
        default: return "app-store-connect"
        }
    }

    static func signingCertificate(for kind: String) -> String {
        kind == "development" ? "Apple Development" : "Apple Distribution"
    }

    static func exportOptionsPlist(teamId: String, bundleId: String, profile: String, profileKind: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>method</key>
        	<string>\(esc(exportMethod(for: profileKind)))</string>
        	<key>destination</key>
        	<string>export</string>
        	<key>signingStyle</key>
        	<string>manual</string>
        	<key>teamID</key>
        	<string>\(esc(teamId))</string>
        	<key>signingCertificate</key>
        	<string>\(esc(signingCertificate(for: profileKind)))</string>
        	<key>stripSwiftSymbols</key>
        	<true/>
        	<key>provisioningProfiles</key>
        	<dict>
        		<key>\(esc(bundleId))</key>
        		<string>\(esc(profile))</string>
        	</dict>
        </dict>
        </plist>
        """
    }

    static func firstIPA(in dir: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir) else { return nil }
        while let item = enumerator.nextObject() as? String {
            if item.lowercased().hasSuffix(".ipa") {
                return (dir as NSString).appendingPathComponent(item)
            }
        }
        return nil
    }

    static func prepareKeyDir(_ cred: Credentials) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appmeta-build-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("AuthKey_\(cred.keyId).p8")
        try FileManager.default.copyItem(atPath: cred.privateKeyPath, toPath: dest.path)
        return dir
    }
}
