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
            throw BuildError.message(L10n.t("No scheme found; share a Release scheme in Xcode.", "没有 scheme；请在 Xcode 里 Share 一个 Release scheme。"))
        }
        if let settingsData = try? runCapturing([
            "/usr/bin/xcodebuild", "-showBuildSettings", "-json",
            "-project", project, "-scheme", res.suggestedScheme, "-configuration", "Release",
        ]) {
            let settings = Self.pickSettings(settingsData)
            res.bundleId = settings["PRODUCT_BUNDLE_IDENTIFIER"] ?? ""
            res.teamId = settings["DEVELOPMENT_TEAM"] ?? ""
            res.productName = settings["PRODUCT_NAME"] ?? ""
            res.signingStyle = settings["CODE_SIGN_STYLE"] ?? ""
            res.codeSignIdentity = settings["CODE_SIGN_IDENTITY"] ?? ""
            res.profileSpecifier = settings["PROVISIONING_PROFILE_SPECIFIER"] ?? settings["PROVISIONING_PROFILE"] ?? ""
        }
        if let ident = try? runCapturing(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]) {
            let text = String(data: ident, encoding: .utf8) ?? ""
            res.distributionCerts = text.split(separator: "\n").map(String.init).filter {
                $0.contains("Apple Distribution") || $0.contains("iPhone Distribution")
            }
        }
        let installed = Self.installedProfiles()
        res.profiles = Self.matchProfiles(installed, bundleId: res.bundleId, teamId: res.teamId, specifier: res.profileSpecifier)
        res.selectedProfile = res.profiles.first
        if res.signingStyle.lowercased() == "automatic" {
            res.warnings.append(L10n.t(
                "Release signing style is Automatic. This app exports with manual signing; set the Release scheme to Manual in Xcode.",
                "Release 签名是 Automatic。本应用按手动签名导出；请在 Xcode 把 Release scheme 设为 Manual。"
            ))
        }
        if res.distributionCerts.isEmpty {
            res.warnings.append(L10n.t(
                "No Apple Distribution certificate in the keychain. Import it in Xcode or Keychain Access.",
                "钥匙串里没有 Apple Distribution 证书。请在 Xcode 或钥匙串中导入。"
            ))
        }
        if res.selectedProfile == nil {
            res.warnings.append(L10n.t(
                "No matching App Store provisioning profile. Double-click the .mobileprovision or assign it on the Release scheme in Xcode.",
                "没有匹配的 App Store 描述文件。请双击 .mobileprovision，或在 Xcode 的 Release scheme 上指定。"
            ))
        }
        res.ready = !res.bundleId.isEmpty && !res.teamId.isEmpty && res.selectedProfile != nil && !res.distributionCerts.isEmpty
        return res
    }

    func archiveAndExport(
        project: String,
        scheme: String,
        teamId: String,
        bundleId: String,
        profile: String,
        onLog: @escaping (String) -> Void,
        onStage: @escaping (String, String) -> Void
    ) throws -> String {
        let proj = try Self.resolveXcodeproj(project)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: Date())
        let outDir = URL(fileURLWithPath: proj).deletingLastPathComponent()
            .appendingPathComponent("build/appmeta-local/\(stamp)", isDirectory: true)
        let exportDir = outDir.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let archivePath = outDir.appendingPathComponent("\(scheme).xcarchive").path
        let plistPath = outDir.appendingPathComponent("ExportOptions.plist").path
        try Self.exportOptionsPlist(teamId: teamId, bundleId: bundleId, profile: profile)
            .write(toFile: plistPath, atomically: true, encoding: .utf8)

        onStage("archive", L10n.t("Archiving Release. This can take several minutes.", "正在 Archive Release，可能需要几分钟。"))
        onLog("xcodebuild archive -project \(proj) -scheme \(scheme)")
        try runStreaming(onLog: onLog, arguments: [
            "/usr/bin/xcodebuild", "archive",
            "-project", proj,
            "-scheme", scheme,
            "-configuration", "Release",
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
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/MobileDevice/Provisioning Profiles")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.compactMap { name -> ProfileInfo? in
            let lower = name.lowercased()
            guard lower.hasSuffix(".mobileprovision") || lower.hasSuffix(".provisionprofile") else { return nil }
            return decodeProfile(dir.appendingPathComponent(name).path)
        }
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
        info.isAppStore = !getTaskAllow && devices.isEmpty && !allDevices
        if let exp = obj["ExpirationDate"] as? String {
            info.expired = (ISO8601DateFormatter().date(from: exp) ?? Date.distantFuture) < Date()
        }
        info.path = path
        return info
    }

    static func matchProfiles(_ profiles: [ProfileInfo], bundleId: String, teamId: String, specifier: String) -> [ProfileInfo] {
        profiles.compactMap { raw -> ProfileInfo? in
            var p = raw
            if !p.isAppStore || p.expired { return nil }
            if !teamId.isEmpty && !p.teamId.isEmpty && p.teamId != teamId { return nil }
            if !bundleMatches(p.bundleId, bundleId) { return nil }
            p.match = (!specifier.isEmpty && (p.uuid == specifier || p.name == specifier)) ? "project" : "installed"
            return p
        }
        .sorted {
            if $0.match != $1.match { return $0.match == "project" }
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

    static func exportOptionsPlist(teamId: String, bundleId: String, profile: String) -> String {
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
        	<string>app-store-connect</string>
        	<key>destination</key>
        	<string>export</string>
        	<key>signingStyle</key>
        	<string>manual</string>
        	<key>teamID</key>
        	<string>\(esc(teamId))</string>
        	<key>signingCertificate</key>
        	<string>Apple Distribution</string>
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
