import Foundation

final class XcodePipeline {
    private let lock = NSLock()
    private var current: Process?

    func cancel() {
        lock.lock()
        let proc = current
        lock.unlock()
        proc?.terminate()
    }

    func inspect(projectPath: String, scheme: String) throws -> InspectResult {
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
        ]
        if !res.configuration.isEmpty {
            settingsArgs += ["-configuration", res.configuration]
        }
        if let settingsData = try? runCapturing(settingsArgs) {
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
        }
        if let ident = try? runCapturing(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]) {
            let text = String(data: ident, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n").map(String.init)
            res.distributionCerts = lines.filter {
                $0.contains("Apple Distribution") || $0.contains("iPhone Distribution")
            }
            res.developmentCerts = lines.filter {
                $0.contains("Apple Development") || $0.contains("iPhone Developer")
            }
        }
        let installed = Self.installedProfiles()
        res.profiles = Self.matchProfiles(
            installed,
            bundleId: res.bundleId,
            teamId: res.teamId,
            specifier: res.profileSpecifier,
            configuration: res.configuration
        )
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
    ) throws -> String {
        let proj = try Self.resolveXcodeproj(project)
        let config = configuration.isEmpty ? "Release" : configuration
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: Date())
        let outDir = URL(fileURLWithPath: proj).deletingLastPathComponent()
            .appendingPathComponent("build/appmeta-local/\(stamp)", isDirectory: true)
        let exportDir = outDir.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let archivePath = outDir.appendingPathComponent("\(scheme).xcarchive").path
        let plistPath = outDir.appendingPathComponent("ExportOptions.plist").path
        try Self.exportOptionsPlist(teamId: teamId, bundleId: bundleId, profile: profile, profileKind: profileKind)
            .write(toFile: plistPath, atomically: true, encoding: .utf8)

        onStage("archive", L10n.t("Archiving \(config). This can take several minutes.", "正在 Archive \(config)，可能需要几分钟。"))
        onLog("xcodebuild archive -project \(proj) -scheme \(scheme) -configuration \(config)")
        try runStreaming(onLog: onLog, arguments: [
            "/usr/bin/xcodebuild", "archive",
            "-project", proj,
            "-scheme", scheme,
            "-configuration", config,
            "-destination", "generic/platform=iOS",
            "-archivePath", archivePath,
        ], directory: URL(fileURLWithPath: proj).deletingLastPathComponent().path)

        onStage("export", L10n.t("Exporting a manually signed IPA.", "正在导出手动签名 IPA。"))
        onLog("xcodebuild -exportArchive")
        try runStreaming(onLog: onLog, arguments: [
            "/usr/bin/xcodebuild", "-exportArchive",
            "-archivePath", archivePath,
            "-exportPath", exportDir.path,
            "-exportOptionsPlist", plistPath,
        ], directory: URL(fileURLWithPath: proj).deletingLastPathComponent().path)

        guard let ipa = Self.firstIPA(in: exportDir.path) else {
            throw BuildError.message(L10n.t("Export finished but no IPA was produced.", "导出结束但没有生成 IPA。"))
        }
        onLog("IPA: \(ipa)")
        return ipa
    }

    func upload(ipa: String, credentials: Credentials, onLog: @escaping (String) -> Void, onStage: @escaping (String, String) -> Void) throws {
        onStage("upload", L10n.t("Uploading IPA to App Store Connect.", "正在上传 IPA 到 App Store Connect。"))
        let keyDir = try Self.prepareKeyDir(credentials)
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let env = ["API_PRIVATE_KEYS_DIR=\(keyDir.path)"]
        onLog("xcrun altool --upload-app -t ios --show-progress")
        do {
            try runStreaming(onLog: onLog, arguments: [
                "/usr/bin/xcrun", "altool", "--upload-app",
                "-f", ipa, "-t", "ios",
                "--apiKey", credentials.keyId,
                "--apiIssuer", credentials.issuerId,
                "--show-progress",
            ], directory: (ipa as NSString).deletingLastPathComponent, extraEnv: env)
        } catch {
            onLog("altool failed, trying iTMSTransporter: \(error.localizedDescription)")
            try runStreaming(onLog: onLog, arguments: [
                "/usr/bin/xcrun", "iTMSTransporter", "-m", "upload",
                "-assetFile", ipa,
                "-apiKey", credentials.keyId,
                "-apiIssuer", credentials.issuerId,
            ], directory: (ipa as NSString).deletingLastPathComponent, extraEnv: env)
        }
        onStage("uploaded", L10n.t(
            "Delivery succeeded. Apple still needs to process the build before it appears in App Store Connect.",
            "投递成功。Apple 还要处理构建，之后才会出现在 App Store Connect。"
        ))
    }

    private func runCapturing(_ arguments: [String]) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: arguments[0])
        proc.arguments = Array(arguments.dropFirst())
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(data: data, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw BuildError.message(msg)
        }
        return data
    }

    private func runStreaming(onLog: @escaping (String) -> Void, arguments: [String], directory: String, extraEnv: [String] = []) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: arguments[0])
        proc.arguments = Array(arguments.dropFirst())
        proc.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment
        for item in extraEnv {
            if let eq = item.firstIndex(of: "=") {
                env[String(item[..<eq])] = String(item[item.index(after: eq)...])
            }
        }
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        lock.lock(); current = proc; lock.unlock()
        try proc.run()
        let handle = out.fileHandleForReading
        var leftover = ""
        handle.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            leftover += chunk
            let parts = leftover.split(separator: "\n", omittingEmptySubsequences: false)
            leftover = String(parts.last ?? "")
            for line in parts.dropLast() {
                let text = String(line)
                if !text.isEmpty { onLog(text) }
            }
        }
        proc.waitUntilExit()
        handle.readabilityHandler = nil
        if let rest = String(data: handle.readDataToEndOfFile(), encoding: .utf8), !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onLog(rest)
        }
        lock.lock(); current = nil; lock.unlock()
        if proc.terminationStatus != 0 {
            throw BuildError.message("command failed (\(proc.terminationStatus)): \(arguments.joined(separator: " "))")
        }
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
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let project = obj["project"] as? [String: Any], let schemes = project["schemes"] as? [String], !schemes.isEmpty {
            return (project["name"] as? String ?? "", schemes)
        }
        if let workspace = obj["workspace"] as? [String: Any], let schemes = workspace["schemes"] as? [String], !schemes.isEmpty {
            return (workspace["name"] as? String ?? "", schemes)
        }
        throw BuildError.message(L10n.t("No shared schemes in this project.", "工程里没有 shared scheme。"))
    }

    static func pickSettings(_ data: Data) -> [String: String] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var fallback: [String: String]?
        for entry in arr {
            let target = ((entry["target"] as? String) ?? "").lowercased()
            if target.contains("test") { continue }
            let settings = (entry["buildSettings"] as? [String: String]) ?? [:]
            if fallback == nil { fallback = settings }
            let bid = settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? ""
            if !bid.isEmpty && !bid.contains("$") { return settings }
        }
        return fallback ?? [:]
    }

    static func installedProfiles() -> [ProfileInfo] {
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
                let lower = name.lowercased()
                guard lower.hasSuffix(".mobileprovision") || lower.hasSuffix(".provisionprofile") else { continue }
                let path = dir.appendingPathComponent(name).path
                guard let info = decodeProfile(path) else { continue }
                let key = info.uuid.isEmpty ? path : info.uuid
                if seen.insert(key).inserted {
                    result.append(info)
                }
            }
        }
        return result
    }

    static func decodeProfile(_ path: String) -> ProfileInfo? {
        let cms = Process()
        cms.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        cms.arguments = ["cms", "-D", "-i", path]
        let cmsOut = Pipe()
        cms.standardOutput = cmsOut
        cms.standardError = Pipe()
        try? cms.run()
        let xml = cmsOut.fileHandleForReading.readDataToEndOfFile()
        cms.waitUntilExit()
        guard cms.terminationStatus == 0 else { return nil }
        let pl = Process()
        pl.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        pl.arguments = ["-convert", "json", "-o", "-", "-"]
        let plIn = Pipe()
        let plOut = Pipe()
        pl.standardInput = plIn
        pl.standardOutput = plOut
        pl.standardError = Pipe()
        try? pl.run()
        plIn.fileHandleForWriting.write(xml)
        try? plIn.fileHandleForWriting.close()
        let json = plOut.fileHandleForReading.readDataToEndOfFile()
        pl.waitUntilExit()
        guard pl.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let entitlements = obj["Entitlements"] as? [String: Any] ?? [:]
        let appId = (entitlements["application-identifier"] as? String)
            ?? (entitlements["com.apple.application-identifier"] as? String)
            ?? ""
        let getTaskAllow = entitlements["get-task-allow"] as? Bool ?? false
        let devices = obj["ProvisionedDevices"] as? [Any] ?? []
        let allDevices = obj["ProvisionsAllDevices"] as? Bool ?? false
        let teams = obj["TeamIdentifier"] as? [String] ?? []
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
        if let exp = obj["ExpirationDate"] as? String {
            info.expired = (ISO8601DateFormatter().date(from: exp) ?? Date.distantFuture) < Date()
        }
        info.path = path
        return info
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
            var p = raw
            if p.expired { return nil }
            if !teamId.isEmpty && !p.teamId.isEmpty && p.teamId != teamId { return nil }
            if !bundleMatches(p.bundleId, bundleId) { return nil }
            p.match = (!specifier.isEmpty && (p.uuid == specifier || p.name == specifier)) ? "project" : "installed"
            return p
        }
        let narrowed = matched.filter { preferred.contains($0.kind) }
        let list = narrowed.isEmpty ? matched : narrowed
        return list.sorted {
            if $0.match != $1.match { return $0.match == "project" }
            let aPref = preferred.contains($0.kind)
            let bPref = preferred.contains($1.kind)
            if aPref != bPref { return aPref }
            return $0.name < $1.name
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
