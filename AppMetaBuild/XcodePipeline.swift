import Foundation
import CryptoKit

final class XcodePipeline: @unchecked Sendable {
    private static let profileCacheLock = NSLock()
    private static var profileCache: [String: ProfileCacheEntry] = [:]

    let commands: CommandExecuting

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
        let container = try Self.resolveContainer(projectPath)
        var res = InspectResult(projectPath: container.path)
        res.containerKind = container.kind
        let listData = try runCapturing(["/usr/bin/xcodebuild", "-list", "-json", container.flag, container.path])
        let (name, schemes) = try Self.parseList(listData)
        res.projectName = name
        res.schemes = schemes
        res.suggestedScheme = scheme.isEmpty ? Self.suggestReleaseScheme(schemes) : scheme
        if res.suggestedScheme.isEmpty {
            throw BuildError.message(L10n.t("No scheme found; share a scheme in Xcode.", "没有 scheme；请在 Xcode 里 Share 一个 scheme。"))
        }
        res.configuration = Self.resolveConfiguration(project: container.path, scheme: res.suggestedScheme)
        var settingsArgs = [
            "/usr/bin/xcodebuild", "-showBuildSettings", "-json",
            container.flag, container.path, "-scheme", res.suggestedScheme,
            "-destination", "generic/platform=iOS",
        ]
        if !res.configuration.isEmpty {
            settingsArgs += ["-configuration", res.configuration]
        }
        var rawProducts: [SignedProduct] = []
        do {
            let settingsData = try runCapturing(settingsArgs)
            rawProducts = Self.signedProducts(from: settingsData)
            let settings = Self.pickSettings(settingsData)
            res.bundleId = settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? ""
            res.teamId = settings["DEVELOPMENT_TEAM"] ?? ""
            res.productName = settings["PRODUCT_NAME"] ?? ""
            res.marketingVersion = Self.resolvedSetting(settings["MARKETING_VERSION"])
            res.buildNumber = Self.resolvedSetting(settings["CURRENT_PROJECT_VERSION"])
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
        var identityLines: [String] = []
        do {
            let ident = try runCapturing(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
            let text = String(data: ident, encoding: .utf8) ?? ""
            identityLines = text.split(separator: "\n").map(String.init)
            res.identities = Self.parseIdentities(identityLines)
            res.distributionCerts = res.identities.filter { $0.kind == "distribution" }.map(\.line)
            res.developmentCerts = res.identities.filter { $0.kind == "development" }.map(\.line)
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
            specifier: res.profileSpecifier,
            configuration: res.configuration
        )
        if rawProducts.isEmpty, Self.isResolvedBundleID(res.bundleId) {
            rawProducts = [SignedProduct(
                target: res.productName,
                bundleId: res.bundleId,
                productType: "com.apple.product-type.application",
                profileSpecifier: res.profileSpecifier,
                isMain: true
            )]
        }
        res.products = Self.assignProfiles(
            rawProducts,
            installed: installed,
            teamId: res.teamId,
            configuration: res.configuration,
            identities: res.identities,
            mainBundleId: res.bundleId
        )
        if let main = res.products.first(where: \.isMain), !main.profileSpecifier.isEmpty {
            res.profileSpecifier = main.profileSpecifier
        }
        res.selectedProfile = Self.defaultProfile(
            in: res.profiles,
            specifier: res.profileSpecifier,
            configuration: res.configuration,
            identities: res.identities,
            bundleId: res.bundleId
        )
        let assessment = Self.assess(inspect: res, profileValue: res.selectedProfile?.value ?? "", currentPath: res.projectPath)
        res.warnings = assessment.warnings
        res.ready = assessment.ready
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
        signingIdentity: String,
        products: [SignedProduct],
        onLog: @escaping (String) -> Void,
        onStage: @escaping (String, String) -> Void
    ) throws -> ArchiveProduct {
        try checkCancelled()
        let container = try Self.resolveContainer(project)
        let config = configuration.isEmpty ? "Release" : configuration
        let outDir = try Self.makeOutputDirectory(for: container.path)
        let exportDir = outDir.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let logURL = outDir.appendingPathComponent("build.log")
        let archivePath = outDir.appendingPathComponent("\(scheme).xcarchive").path
        let plistPath = outDir.appendingPathComponent("ExportOptions.plist").path
        let profileMap = Self.profileMap(products: products, mainBundleId: bundleId, mainProfile: profile)
        if products.contains(where: { !$0.isMain && $0.profileName.isEmpty }) {
            throw BuildError.message(L10n.t(
                "A signed target has no matching provisioning profile.",
                "有一个需要签名的 Target 没有匹配的描述文件。"
            ))
        }
        try Self.exportOptionsPlist(
            teamId: teamId,
            profiles: profileMap,
            profileKind: profileKind,
            signingCertificate: signingIdentity
        ).write(toFile: plistPath, atomically: true, encoding: .utf8)

        let logger = LineLog(url: logURL)
        defer { logger?.close() }
        let emit: (String) -> Void = { line in
            logger?.write(line)
            onLog(line)
        }
        emit("Log: \(logURL.path)")
        emit("Team \(teamId)")
        emit("Identity \(signingIdentity)")
        emit("Profile \(profile)")
        onStage("archive", L10n.t("Archiving \(config). This can take several minutes.", "正在 Archive \(config)，可能需要几分钟。"))
        emit("xcodebuild archive \(container.flag) \(container.path) -scheme \(scheme) -configuration \(config)")
        let workDirectory = URL(fileURLWithPath: container.path).deletingLastPathComponent().path
        var archiveArguments = [
            "/usr/bin/xcodebuild", "archive",
            container.flag, container.path,
            "-scheme", scheme,
            "-configuration", config,
            "-destination", "generic/platform=iOS",
            "-archivePath", archivePath,
            "CODE_SIGN_STYLE=Manual",
        ]
        if !teamId.isEmpty { archiveArguments.append("DEVELOPMENT_TEAM=\(teamId)") }
        if products.count <= 1, !profile.isEmpty {
            archiveArguments.append("PROVISIONING_PROFILE_SPECIFIER=\(profile)")
        }
        if !signingIdentity.isEmpty { archiveArguments.append("CODE_SIGN_IDENTITY=\(signingIdentity)") }
        try runStreaming(onLog: emit, arguments: archiveArguments, directory: workDirectory)
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
        let versions = Self.readAppVersion(inArchive: archivePath)
        Self.preserveSymbols(fromArchive: archivePath, to: outDir)
        try? FileManager.default.removeItem(atPath: archivePath)
        let metadata = ExportMetadata(
            method: try Self.exportMethod(for: profileKind),
            bundleId: bundleId,
            version: versions.version,
            build: versions.build,
            profile: profile
        )
        let metadataURL = URL(fileURLWithPath: ipa).deletingPathExtension().appendingPathExtension("export-metadata.json")
        if let data = try? JSONEncoder.pretty.encode(metadata) {
            try? data.write(to: metadataURL)
        }
        emit("IPA: \(ipa)")
        if !versions.version.isEmpty || !versions.build.isEmpty {
            emit("Version \(versions.version) (\(versions.build))")
        }
        return ArchiveProduct(
            ipaPath: ipa,
            logPath: logURL.path,
            version: versions.version,
            build: versions.build,
            metadataPath: metadataURL.path
        )
    }

    func upload(ipa: String, credentials: Credentials, logFile: URL? = nil, onLog: @escaping (String) -> Void, onStage: @escaping (String, String) -> Void) throws {
        try checkCancelled()
        let method = try ipaDistributionMethod(ipa)
        guard method == "app-store-connect" else {
            throw BuildError.message(L10n.t(
                "Only an App Store IPA can be uploaded.",
                "只有 App Store IPA 可以上传。"
            ))
        }
        onStage("upload", L10n.t("Uploading IPA to App Store Connect.", "正在上传 IPA 到 App Store Connect。"))
        let transporterPath = try locateTransporter()
        try checkCancelled()
        let keyDir = try Self.prepareKeyDir(credentials)
        defer { try? FileManager.default.removeItem(at: keyDir) }
        try deliver(
            ipa: ipa,
            credentials: credentials,
            transporterPath: transporterPath,
            keyDirectory: keyDir,
            logFile: logFile,
            onLog: onLog
        )
        onStage("uploaded", L10n.t(
            "Delivery succeeded. Apple still needs to process the build before it appears in App Store Connect.",
            "投递成功。Apple 还要处理构建，之后才会出现在 App Store Connect。"
        ))
    }

    func locateTransporter() throws -> String {
        do {
            let transporter = try commands.run(
                arguments: ["/usr/bin/xcrun", "--find", "iTMSTransporter"],
                directory: "",
                extraEnvironment: [:],
                onLog: nil,
                logFile: nil
            )
            return String(decoding: transporter.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch BuildError.cancelled {
            throw BuildError.cancelled
        } catch {
            return ""
        }
    }

    func deliver(
        ipa: String,
        credentials: Credentials,
        transporterPath: String,
        keyDirectory: URL,
        logFile: URL?,
        onLog: @escaping (String) -> Void
    ) throws {
        let env = ["API_PRIVATE_KEYS_DIR": keyDirectory.path]
        let directory = (ipa as NSString).deletingLastPathComponent
        if transporterPath.isEmpty {
            onLog("iTMSTransporter was not found, trying altool")
            try runStreaming(onLog: onLog, arguments: [
                "/usr/bin/xcrun", "altool", "--upload-app",
                "-f", ipa, "-t", "ios",
                "--apiKey", credentials.keyId,
                "--apiIssuer", credentials.issuerId,
                "--show-progress",
            ], directory: directory, extraEnv: env, logFile: logFile)
        } else {
            onLog("xcrun iTMSTransporter -m upload")
            try runStreaming(onLog: onLog, arguments: [
                "/usr/bin/xcrun", "iTMSTransporter", "-m", "upload",
                "-assetFile", ipa,
                "-apiKey", credentials.keyId,
                "-apiIssuer", credentials.issuerId,
            ], directory: directory, extraEnv: env, logFile: logFile)
        }
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

    struct XcodeContainer: Equatable, Sendable {
        var path: String
        var kind: String
        var flag: String { kind == "workspace" ? "-workspace" : "-project" }
    }

    static func resolveContainer(_ path: String) throws -> XcodeContainer {
        var path = (path as NSString).expandingTildeInPath
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw BuildError.message(L10n.t("Project path not found.", "找不到工程路径。"))
        }
        let lower = path.lowercased()
        if lower.hasSuffix(".xcworkspace") { return XcodeContainer(path: path, kind: "workspace") }
        if lower.hasSuffix(".xcodeproj") { return XcodeContainer(path: path, kind: "project") }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let workspaces = names.filter { $0.lowercased().hasSuffix(".xcworkspace") }
        if workspaces.count > 1 {
            throw BuildError.message(L10n.t("Folder contains multiple .xcworkspace files; pick one.", "文件夹里有多个 .xcworkspace，请选其中一个。"))
        }
        if let workspace = workspaces.first {
            return XcodeContainer(path: (path as NSString).appendingPathComponent(workspace), kind: "workspace")
        }
        let projects = names.filter { $0.lowercased().hasSuffix(".xcodeproj") }
        if projects.count == 1 {
            return XcodeContainer(path: (path as NSString).appendingPathComponent(projects[0]), kind: "project")
        }
        if projects.count > 1 {
            throw BuildError.message(L10n.t("Folder contains multiple .xcodeproj files; pick one.", "文件夹里有多个 .xcodeproj，请选其中一个。"))
        }
        throw BuildError.message(L10n.t("No .xcodeproj or .xcworkspace found.", "没有找到 .xcodeproj 或 .xcworkspace。"))
    }

    static func resolvedSetting(_ value: String?) -> String {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("$") else { return "" }
        return text
    }

    static func suggestReleaseScheme(_ schemes: [String]) -> String {
        schemes.first { $0.lowercased().contains("release") } ?? schemes.first ?? ""
    }

    static func resolveConfiguration(project: String, scheme: String) -> String {
        guard let xml = schemeXML(project: project, scheme: scheme) else { return "Release" }
        let archive = actionBuildConfiguration(xml: xml, action: "ArchiveAction")
        return archive.isEmpty ? "Release" : archive
    }

    static func schemeXML(project: String, scheme: String) -> String? {
        var roots = [URL(fileURLWithPath: project)]
        if project.lowercased().hasSuffix(".xcworkspace") {
            let parent = URL(fileURLWithPath: project).deletingLastPathComponent()
            let children = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            roots.append(contentsOf: children.filter { $0.pathExtension == "xcodeproj" })
        }
        for root in roots {
            var candidates = [
                root.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme"),
            ]
            let userdata = root.appendingPathComponent("xcuserdata")
            if let users = try? FileManager.default.contentsOfDirectory(atPath: userdata.path) {
                for user in users {
                    candidates.append(userdata.appendingPathComponent("\(user)/xcschemes/\(scheme).xcscheme"))
                }
            }
            for url in candidates {
                if let xml = try? String(contentsOf: url, encoding: .utf8) { return xml }
            }
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

    static func isResolvedBundleID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$"), !trimmed.contains(" ") else { return false }
        let parts = trimmed.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
    }

    static func isResolvedTeamID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 10, !trimmed.contains("$") else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func sameProjectPath(_ lhs: String, _ rhs: String) -> Bool {
        func normalize(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return normalize(lhs) == normalize(rhs)
    }

    static func pickSettings(_ data: Data) -> [String: String] {
        guard let arr = jsonArray(from: data) else { return [:] }
        var resolved: [[String: String]] = []
        for entry in arr {
            let target = ((entry["target"] as? String) ?? "").lowercased()
            if target.contains("test") { continue }
            let settings = stringSettings(entry["buildSettings"] as? [String: Any] ?? [:])
            guard isResolvedBundleID(settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? "") else { continue }
            resolved.append(settings)
        }
        if let app = resolved.first(where: { $0["PRODUCT_TYPE"] == "com.apple.product-type.application" }) {
            return app
        }
        return resolved.first ?? [:]
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
        info.platforms = platformNames(obj["Platform"])
        info.platformKnown = !info.platforms.isEmpty
        info.path = path
        return info
    }

    static func platformNames(_ raw: Any?) -> [String] {
        if let values = raw as? [String] { return values }
        if let values = raw as? [Any] { return values.compactMap { $0 as? String } }
        if let value = raw as? String, !value.isEmpty { return [value] }
        return []
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
        specifier: String,
        configuration: String
    ) -> [ProfileInfo] {
        let preferred = Set(preferredProfileKinds(for: configuration))
        let matched: [ProfileInfo] = profiles.compactMap { raw in
            var profile = raw
            if profile.platformKnown && !profile.supportsIOS { return nil }
            if !teamId.isEmpty && !profile.teamId.isEmpty && profile.teamId != teamId { return nil }
            let specified = !specifier.isEmpty && (profile.name == specifier || profile.uuid == specifier)
            if specified {
                profile.match = "project"
                return profile
            }
            if !bundleMatches(profile.bundleId, bundleId) { return nil }
            profile.match = "installed"
            return profile
        }
        var list = matched
        if !specifier.isEmpty && !list.contains(where: { $0.name == specifier || $0.uuid == specifier }) {
            var missing = ProfileInfo()
            missing.name = specifier
            missing.match = "project"
            list.append(missing)
        }
        list.sort { lhs, rhs in
            if lhs.installed != rhs.installed { return lhs.installed }
            if lhs.expired != rhs.expired { return !lhs.expired }
            let leftPreferred = preferred.contains(lhs.kind)
            let rightPreferred = preferred.contains(rhs.kind)
            if leftPreferred != rightPreferred { return leftPreferred }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.name < rhs.name
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.uuid.isEmpty ? $0.value : $0.uuid).inserted }
    }

    static func defaultProfile(
        in profiles: [ProfileInfo],
        specifier: String,
        configuration: String,
        identities: [SigningIdentity],
        bundleId: String
    ) -> ProfileInfo? {
        let preferred = Set(preferredProfileKinds(for: configuration))
        func usable(_ profile: ProfileInfo) -> Bool {
            guard profile.installed, !profile.expired, profile.supportsIOS else { return false }
            guard bundleMatches(profile.bundleId, bundleId) else { return false }
            return matchingIdentity(profile: profile, identities: identities) != nil
        }
        if let named = profiles.first(where: { ($0.name == specifier || $0.uuid == specifier) && usable($0) }) {
            return named
        }
        if let preferredMatch = profiles.first(where: { preferred.contains($0.kind) && usable($0) }) {
            return preferredMatch
        }
        return profiles.first(where: usable)
    }

    static func expectedIdentityKind(for profileKind: String) -> String {
        profileKind == "development" ? "development" : "distribution"
    }

    static func matchingIdentity(profile: ProfileInfo, identities: [SigningIdentity]) -> SigningIdentity? {
        let expected = expectedIdentityKind(for: profile.kind)
        return identities.first {
            $0.kind == expected && profile.certFingerprints.contains($0.fingerprint)
        }
    }

    static func parseIdentities(_ lines: [String]) -> [SigningIdentity] {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9A-Fa-f]{40})\s+"([^"]+)""#) else { return [] }
        var identities: [SigningIdentity] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let hashRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line) else { continue }
            let name = String(line[nameRange])
            guard let kind = identityKind(name: name) else { continue }
            identities.append(SigningIdentity(
                fingerprint: String(line[hashRange]).uppercased(),
                name: name,
                kind: kind,
                line: line
            ))
        }
        return identities
    }

    static func identityKind(name: String) -> String? {
        let value = name.lowercased()
        if value.hasPrefix("iphone developer") || value.hasPrefix("apple development") || value.hasPrefix("ios development") {
            return "development"
        }
        if value.hasPrefix("iphone distribution") || value.hasPrefix("apple distribution") || value.hasPrefix("ios distribution") {
            return "distribution"
        }
        return nil
    }

    static func assess(inspect: InspectResult, profileValue: String, currentPath: String) -> SigningAssessment {
        var result = SigningAssessment()
        if !sameProjectPath(currentPath, inspect.projectPath) {
            result.warnings.append(L10n.t(
                "The project path changed. Inspect it again before archiving.",
                "工程路径已改变，请重新识别后再 Archive。"
            ))
            return result
        }
        if !isResolvedBundleID(inspect.bundleId) {
            result.warnings.append(inspect.bundleId.isEmpty
                ? L10n.t("No expanded Bundle ID was found for this scheme.", "这个 scheme 没有读到已展开的 Bundle ID。")
                : L10n.t("Bundle ID is not expanded: \(inspect.bundleId)", "Bundle ID 没有展开：\(inspect.bundleId)"))
        }
        if !isResolvedTeamID(inspect.teamId) {
            result.warnings.append(inspect.teamId.isEmpty
                ? L10n.t("No expanded Team ID was found for this scheme.", "这个 scheme 没有读到已展开的 Team ID。")
                : L10n.t("Team ID is not expanded: \(inspect.teamId)", "Team ID 没有展开：\(inspect.teamId)"))
        }
        guard let profile = inspect.profiles.first(where: { $0.value == profileValue }) else {
            result.warnings.append(L10n.t(
                "No matching provisioning profile is installed for this Bundle ID.",
                "本机没有和这个 Bundle ID 匹配的描述文件。"
            ))
            return result
        }
        result.expectsDevelopment = profile.kind == "development"
        if !profile.installed {
            result.warnings.append(L10n.t(
                "Provisioning profile \"\(profile.name)\" is named by the project but is not installed on this Mac.",
                "工程指定了描述文件 \"\(profile.name)\"，但本机没有安装。"
            ))
        } else if profile.expired {
            result.warnings.append(L10n.t(
                "Provisioning profile \"\(profile.name)\" has expired.",
                "描述文件 \"\(profile.name)\" 已过期。"
            ))
        } else if !profile.platformKnown {
            result.warnings.append(L10n.t(
                "Provisioning profile \"\(profile.name)\" does not say which platform it is for.",
                "描述文件 \"\(profile.name)\" 没有标明平台。"
            ))
        } else if !profile.supportsIOS {
            result.warnings.append(L10n.t(
                "Provisioning profile \"\(profile.name)\" is not an iOS profile.",
                "描述文件 \"\(profile.name)\" 不是 iOS 描述文件。"
            ))
        }
        if let identity = matchingIdentity(profile: profile, identities: inspect.identities) {
            result.identityName = identity.name
            result.certificateFound = true
        } else if profile.installed {
            let expected = result.expectsDevelopment
                ? L10n.t("Apple Development", "Apple Development")
                : L10n.t("Apple Distribution", "Apple Distribution")
            result.warnings.append(L10n.t(
                "Provisioning profile \"\(profile.name)\" does not include a \(expected) certificate from this keychain.",
                "描述文件 \"\(profile.name)\" 不包含本机钥匙串里的 \(expected) 证书。"
            ))
        }
        if let legacy = legacyIdentityWarning(projectIdentity: inspect.codeSignIdentity, expectsDevelopment: result.expectsDevelopment) {
            result.warnings.append(legacy)
        }
        if inspect.signingStyle.lowercased() == "automatic" {
            result.warnings.append(L10n.t(
                "The project uses Automatic signing. Archive will pass manual signing on the command line and will not edit the project.",
                "工程使用 Automatic 签名。Archive 会在命令行改用手动签名，不会修改工程文件。"
            ))
        }
        let bundleAligned = bundleMatches(profile.bundleId, inspect.bundleId)
        if profile.installed && isResolvedBundleID(inspect.bundleId) && !bundleAligned {
            result.warnings.append(L10n.t(
                "Provisioning profile \"\(profile.name)\" does not match Bundle ID \(inspect.bundleId).",
                "描述文件 \"\(profile.name)\" 和 Bundle ID \(inspect.bundleId) 不匹配。"
            ))
        }
        result.ready = isResolvedBundleID(inspect.bundleId)
            && isResolvedTeamID(inspect.teamId)
            && profile.installed
            && !profile.expired
            && profile.supportsIOS
            && bundleAligned
            && result.certificateFound
        return result
    }

    static func legacyIdentityWarning(projectIdentity: String, expectsDevelopment: Bool) -> String? {
        let identity = projectIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !identity.isEmpty else { return nil }
        let legacy = expectsDevelopment
            ? identity.hasPrefix("iphone developer")
            : identity.hasPrefix("iphone distribution")
        guard legacy else { return nil }
        return L10n.t(
            "The project still uses the legacy identity \"\(projectIdentity)\". This archive will use the matching certificate from the keychain instead.",
            "工程还在用旧的证书名 \"\(projectIdentity)\"。本次 Archive 会改用钥匙串里匹配到的证书。"
        )
    }

    static func profileGroups(in profiles: [ProfileInfo], configuration: String) -> [ProfileGroup] {
        var order = preferredProfileKinds(for: configuration)
        for kind in ["appstore", "adhoc", "enterprise", "development", ""] where !order.contains(kind) {
            order.append(kind)
        }
        return order.compactMap { kind in
            let items = profiles.filter { $0.kind == kind || (kind.isEmpty && !["appstore", "adhoc", "enterprise", "development"].contains($0.kind)) }
            guard !items.isEmpty else { return nil }
            let title: String
            switch kind {
            case "appstore": title = L10n.t("App Store", "App Store")
            case "development": title = L10n.t("Development", "开发")
            case "adhoc": title = L10n.t("Ad Hoc", "Ad Hoc")
            case "enterprise": title = L10n.t("Enterprise", "企业")
            default: title = L10n.t("Other", "其他")
            }
            return ProfileGroup(kind: kind, title: title, profiles: items)
        }
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

    static func exportMethod(for kind: String) throws -> String {
        switch kind {
        case "development": return "development"
        case "adhoc": return "ad-hoc"
        case "enterprise": return "enterprise"
        case "appstore": return "app-store-connect"
        default:
            throw BuildError.message(L10n.t(
                "Unknown provisioning profile type \"\(kind)\".",
                "未知的描述文件类型 \"\(kind)\"。"
            ))
        }
    }

    static func signingCertificate(for kind: String) -> String {
        kind == "development" ? "Apple Development" : "Apple Distribution"
    }

    static func exportOptionsPlist(
        teamId: String,
        profiles: [String: String],
        profileKind: String,
        signingCertificate: String
    ) throws -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let certificate = signingCertificate.isEmpty ? Self.signingCertificate(for: profileKind) : signingCertificate
        let method = try exportMethod(for: profileKind)
        let entries = profiles.keys.sorted().map { key in
            "\t\t<key>\(esc(key))</key>\n\t\t<string>\(esc(profiles[key] ?? ""))</string>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>method</key>
        	<string>\(esc(method))</string>
        	<key>destination</key>
        	<string>export</string>
        	<key>signingStyle</key>
        	<string>manual</string>
        	<key>teamID</key>
        	<string>\(esc(teamId))</string>
        	<key>signingCertificate</key>
        	<string>\(esc(certificate))</string>
        	<key>manageAppVersionAndBuildNumber</key>
        	<false/>
        	<key>stripSwiftSymbols</key>
        	<true/>
        	<key>provisioningProfiles</key>
        	<dict>
        \(entries)
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
        guard Credentials.isValidKeyID(cred.keyId), Credentials.isValidIssuerID(cred.issuerId) else {
            throw BuildError.message(L10n.t(
                "Key ID must be 10 letters or digits, and Issuer ID must be a UUID.",
                "Key ID 必须是 10 位字母或数字，Issuer ID 必须是 UUID。"
            ))
        }
        guard let pem = KeychainStore.load(keyId: cred.keyId) else {
            throw BuildError.message(L10n.t(
                "The private key is not in the login keychain.",
                "登录钥匙串里没有这把私钥。"
            ))
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appmeta-build-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let dest = dir.appendingPathComponent("AuthKey_\(cred.keyId).p8")
        try pem.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return dir
    }

    func ipaDistributionMethod(_ ipa: String) throws -> String {
        let metadataURL = URL(fileURLWithPath: ipa).deletingPathExtension().appendingPathExtension("export-metadata.json")
        if let data = try? Data(contentsOf: metadataURL),
           let meta = try? JSONDecoder().decode(ExportMetadata.self, from: data),
           !meta.method.isEmpty {
            return meta.method
        }
        guard let kind = try embeddedProfileKind(ipa) else {
            throw BuildError.message(L10n.t(
                "Could not read the provisioning profile inside the IPA.",
                "读不到 IPA 里的描述文件。"
            ))
        }
        return try Self.exportMethod(for: kind)
    }

    private func embeddedProfileKind(_ ipa: String) throws -> String? {
        let listing = try runCapturing(["/usr/bin/unzip", "-Z1", ipa])
        let lines = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
        guard let entry = lines.first(where: { $0.hasSuffix("embedded.mobileprovision") && $0.contains(".app/") }) else {
            return nil
        }
        let cms = try runCapturing(["/usr/bin/unzip", "-p", ipa, entry])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mobileprovision")
        try cms.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try decodeProfile(temp.path)?.kind
    }

    static func signedProducts(from data: Data) -> [SignedProduct] {
        guard let entries = jsonArray(from: data) else { return [] }
        var products: [SignedProduct] = []
        var seen = Set<String>()
        for entry in entries {
            let target = entry["target"] as? String ?? ""
            if target.lowercased().contains("test") { continue }
            let settings = stringSettings(entry["buildSettings"] as? [String: Any] ?? [:])
            let type = settings["PRODUCT_TYPE"] ?? ""
            guard type == "com.apple.product-type.application"
                    || type.contains("app-extension")
                    || type.contains("watch")
                    || type.contains("on-demand-install") else { continue }
            let bundleId = settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? ""
            guard isResolvedBundleID(bundleId), seen.insert(bundleId).inserted else { continue }
            products.append(SignedProduct(
                target: target,
                bundleId: bundleId,
                productType: type,
                profileSpecifier: settings["PROVISIONING_PROFILE_SPECIFIER"] ?? settings["PROVISIONING_PROFILE"] ?? ""
            ))
        }
        return products
    }

    static func assignProfiles(
        _ products: [SignedProduct],
        installed: [ProfileInfo],
        teamId: String,
        configuration: String,
        identities: [SigningIdentity],
        mainBundleId: String
    ) -> [SignedProduct] {
        products.map { raw in
            var product = raw
            let matches = matchProfiles(
                installed,
                bundleId: product.bundleId,
                teamId: teamId,
                specifier: product.profileSpecifier,
                configuration: configuration
            )
            let chosen = defaultProfile(
                in: matches,
                specifier: product.profileSpecifier,
                configuration: configuration,
                identities: identities,
                bundleId: product.bundleId
            )
            product.profileName = chosen?.value ?? ""
            product.profileKind = chosen?.kind ?? ""
            product.isMain = product.bundleId == mainBundleId
            return product
        }
    }

    static func profileMap(products: [SignedProduct], mainBundleId: String, mainProfile: String) -> [String: String] {
        var map: [String: String] = [:]
        if products.isEmpty, !mainBundleId.isEmpty, !mainProfile.isEmpty {
            map[mainBundleId] = mainProfile
            return map
        }
        for product in products {
            let name = product.bundleId == mainBundleId ? mainProfile : product.profileName
            if !name.isEmpty { map[product.bundleId] = name }
        }
        return map
    }

    static func makeOutputDirectory(for containerPath: String) throws -> URL {
        let name = URL(fileURLWithPath: containerPath).deletingPathExtension().lastPathComponent
        let safe = name.isEmpty ? "project" : name
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/AppMeta Build", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        cleanupCache(at: root, keepingLatest: 3, maxAgeDays: 7)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanupCache(at root: URL, keepingLatest: Int, maxAgeDays: Int) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let dated = urls.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }.sorted { $0.1 > $1.1 }
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 24 * 60 * 60)
        for (index, item) in dated.enumerated() where index >= keepingLatest || item.1 < cutoff {
            try? fm.removeItem(at: item.0)
        }
    }

    static func readAppVersion(inArchive archive: String) -> (version: String, build: String) {
        let apps = URL(fileURLWithPath: archive).appendingPathComponent("Products/Applications")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: apps.path),
              let app = names.first(where: { $0.hasSuffix(".app") }) else { return ("", "") }
        let plist = apps.appendingPathComponent(app).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return ("", "")
        }
        return (obj["CFBundleShortVersionString"] as? String ?? "", obj["CFBundleVersion"] as? String ?? "")
    }

    static func preserveSymbols(fromArchive archive: String, to outDir: URL) {
        let source = URL(fileURLWithPath: archive).appendingPathComponent("dSYMs")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { return }
        try? FileManager.default.copyItem(at: source, to: outDir.appendingPathComponent("dSYMs"))
    }

    static func incrementBuildNumber(containerPath: String, current: String) throws -> String {
        guard let number = Int(current) else {
            throw BuildError.message(L10n.t(
                "Build number \"\(current)\" is not an integer.",
                "Build 号 \"\(current)\" 不是整数。"
            ))
        }
        let next = String(number + 1)
        let pattern = #"CURRENT_PROJECT_VERSION = "?\#(NSRegularExpression.escapedPattern(for: current))"? *;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw BuildError.message(L10n.t("Could not update the build number.", "无法更新 Build 号。"))
        }
        var changed = 0
        for file in pbxprojFiles(containerPath) {
            guard var text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let count = regex.numberOfMatches(in: text, range: range)
            guard count > 0 else { continue }
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "CURRENT_PROJECT_VERSION = \(next);")
            try text.write(to: file, atomically: true, encoding: .utf8)
            changed += count
        }
        guard changed > 0 else {
            throw BuildError.message(L10n.t(
                "CURRENT_PROJECT_VERSION \(current) was not found in the project.",
                "工程里没有找到 CURRENT_PROJECT_VERSION \(current)。"
            ))
        }
        return next
    }

    static func pbxprojFiles(_ containerPath: String) -> [URL] {
        if containerPath.lowercased().hasSuffix(".xcodeproj") {
            return [URL(fileURLWithPath: containerPath).appendingPathComponent("project.pbxproj")]
        }
        let parent = URL(fileURLWithPath: containerPath).deletingLastPathComponent()
        let children = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        return children
            .filter { $0.pathExtension == "xcodeproj" && $0.lastPathComponent != "Pods.xcodeproj" }
            .map { $0.appendingPathComponent("project.pbxproj") }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
