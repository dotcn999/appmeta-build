import XCTest
@testable import AppMetaBuild

final class ScriptedCommands: CommandExecuting, @unchecked Sendable {
    var cancelled = false
    var invocations: [[String]] = []
    var handler: ([String]) throws -> CommandOutput = { _ in
        CommandOutput(stdout: Data(), stderr: Data())
    }

    func prepareForNewOperation() {
        cancelled = false
    }

    func cancel() {
        cancelled = true
    }

    var isCancelled: Bool { cancelled }

    func run(
        arguments: [String],
        directory: String,
        extraEnvironment: [String: String],
        onLog: ((String) -> Void)?,
        logFile: URL?
    ) throws -> CommandOutput {
        if cancelled { throw BuildError.cancelled }
        invocations.append(arguments)
        return try handler(arguments)
    }
}

final class PipelineTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("appmeta-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testArchiveActionOverridesSchemeName() throws {
        let project = temp.appendingPathComponent("Demo.xcodeproj")
        let scheme = project.appendingPathComponent("xcshareddata/xcschemes/Debug.xcscheme")
        try FileManager.default.createDirectory(at: scheme.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
          <LaunchAction buildConfiguration="Debug"></LaunchAction>
          <ArchiveAction buildConfiguration="Release"></ArchiveAction>
        </Scheme>
        """.write(to: scheme, atomically: true, encoding: .utf8)
        XCTAssertEqual(XcodePipeline.resolveConfiguration(project: project.path, scheme: "Debug"), "Release")
    }

    func testMissingArchiveActionUsesRelease() {
        XCTAssertEqual(XcodePipeline.resolveConfiguration(project: temp.path, scheme: "Missing"), "Release")
    }

    func testReleaseKeepsAdHocAndDoesNotDefaultExpired() {
        var adhoc = ProfileInfo()
        adhoc.uuid = "adhoc"
        adhoc.name = "Ad Hoc"
        adhoc.kind = "adhoc"
        adhoc.bundleId = "com.example.app"
        adhoc.teamId = "TEAMTEAM10"
        adhoc.path = "/tmp/adhoc.mobileprovision"
        adhoc.platforms = ["iOS"]
        adhoc.platformKnown = true

        var expired = adhoc
        expired.uuid = "store"
        expired.name = "App Store"
        expired.kind = "appstore"
        expired.expired = true

        let list = XcodePipeline.matchProfiles(
            [expired, adhoc],
            bundleId: "com.example.app",
            teamId: "TEAMTEAM10",
            specifier: "",
            configuration: "Release"
        )
        XCTAssertEqual(Set(list.map(\.kind)), ["adhoc", "appstore"])
        XCTAssertEqual(list.first?.kind, "adhoc")
    }

    func testUnknownProfileKindThrows() {
        XCTAssertThrowsError(try XcodePipeline.exportMethod(for: "mystery"))
        XCTAssertThrowsError(try XcodePipeline.exportOptionsPlist(
            teamId: "TEAMTEAM10",
            profiles: ["com.example.app": "Missing"],
            profileKind: "mystery",
            signingCertificate: ""
        ))
    }

    func testExportPlistUsesCertificateAndDoesNotManageBuildNumber() throws {
        let xml = try XcodePipeline.exportOptionsPlist(
            teamId: "TEAMTEAM10",
            profiles: ["com.example.app": "App Store", "com.example.widget": "Widget"],
            profileKind: "appstore",
            signingCertificate: "Apple Distribution: Example (TEAMTEAM10)"
        )
        XCTAssertTrue(xml.contains("<string>app-store-connect</string>"))
        XCTAssertTrue(xml.contains("<string>Apple Distribution: Example (TEAMTEAM10)</string>"))
        XCTAssertTrue(xml.contains("<key>manageAppVersionAndBuildNumber</key>\n\t<false/>"))
        XCTAssertTrue(xml.contains("<key>com.example.widget</key>"))
    }

    func testJSONPrefixDoesNotHideSchemes() throws {
        let data = Data("2026 warning: noisy\n{\"project\":{\"name\":\"Demo\",\"schemes\":[\"App\"]}}".utf8)
        let parsed = try XcodePipeline.parseList(data)
        XCTAssertEqual(parsed.0, "Demo")
        XCTAssertEqual(parsed.1, ["App"])
    }

    func testUnresolvedBundleIDIsRejectedAndApplicationIsPreferred() {
        XCTAssertFalse(XcodePipeline.isResolvedBundleID("$(PRODUCT_BUNDLE_IDENTIFIER)"))
        XCTAssertFalse(XcodePipeline.isResolvedTeamID("$TEAM"))
        let json = """
        [
          {"target":"App","buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"$(PRODUCT_BUNDLE_IDENTIFIER)","PRODUCT_TYPE":"com.apple.product-type.application"}},
          {"target":"AppTests","buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"com.example.tests","PRODUCT_TYPE":"com.apple.product-type.bundle.unit-test"}},
          {"target":"Widget","buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"com.example.widget","PRODUCT_TYPE":"com.apple.product-type.app-extension"}},
          {"target":"Main","buildSettings":{"PRODUCT_BUNDLE_IDENTIFIER":"com.example.app","PRODUCT_TYPE":"com.apple.product-type.application"}}
        ]
        """
        let settings = XcodePipeline.pickSettings(Data(json.utf8))
        XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "com.example.app")
    }

    func testWildcardBundleMatch() {
        XCTAssertTrue(XcodePipeline.bundleMatches("com.example.*", "com.example.app"))
        XCTAssertFalse(XcodePipeline.bundleMatches("com.example.*", "com.other.app"))
        XCTAssertTrue(XcodePipeline.bundleMatches("*", "com.example.app"))
    }

    func testLineSplitterKeepsPartialUTF8Line() {
        var splitter = UTF8LineSplitter()
        XCTAssertTrue(splitter.append(Data("hel".utf8)).isEmpty)
        XCTAssertEqual(splitter.append(Data("lo\n中".utf8)), ["hello"])
        XCTAssertEqual(splitter.flush(), "中")
    }

    func testVersionConflictAndFailureSummary() {
        XCTAssertNotNil(LogDiagnostics.versionConflictMessage(in: "CFBundleVersion must be higher than the previous upload"))
        XCTAssertNil(LogDiagnostics.versionConflictMessage(in: "the value must be higher"))
        let summary = LogDiagnostics.summarizeFailure(in: "noise\nerror: No signing certificate \"Apple Distribution\" found")
        XCTAssertEqual(summary, "error: No signing certificate \"Apple Distribution\" found")
    }

    func testIncrementBuildNumberSkipsPods() throws {
        let project = temp.appendingPathComponent("Demo.xcodeproj")
        let pods = temp.appendingPathComponent("Pods.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pods, withIntermediateDirectories: true)
        try "CURRENT_PROJECT_VERSION = 3;\n".write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        try "CURRENT_PROJECT_VERSION = 3;\n".write(to: pods.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let workspace = temp.appendingPathComponent("Demo.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let next = try XcodePipeline.incrementBuildNumber(containerPath: workspace.path, current: "3")
        XCTAssertEqual(next, "4")
        let updated = try String(contentsOf: project.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        let podsText = try String(contentsOf: pods.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        XCTAssertTrue(updated.contains("CURRENT_PROJECT_VERSION = 4;"))
        XCTAssertTrue(podsText.contains("CURRENT_PROJECT_VERSION = 3;"))
    }

    func testMetadataSelectsUploadMethod() throws {
        let ipa = temp.appendingPathComponent("App.ipa")
        try Data("ipa".utf8).write(to: ipa)
        let meta = ExportMetadata(method: "ad-hoc", bundleId: "com.example.app", version: "1.0", build: "3", profile: "Ad Hoc")
        let data = try JSONEncoder().encode(meta)
        try data.write(to: temp.appendingPathComponent("App.export-metadata.json"))
        let pipeline = XcodePipeline(commands: ScriptedCommands())
        XCTAssertEqual(try pipeline.ipaDistributionMethod(ipa.path), "ad-hoc")
        XCTAssertThrowsError(try pipeline.upload(ipa: ipa.path, credentials: Credentials(), onLog: { _ in }, onStage: { _, _ in }))
        XCTAssertTrue((pipeline.commands as! ScriptedCommands).invocations.isEmpty)
    }

    func testCancelBeforeUploadDoesNotCallAltool() throws {
        let ipa = try storeMetadata(method: "app-store-connect")
        let commands = ScriptedCommands()
        commands.handler = { _ in throw BuildError.cancelled }
        let pipeline = XcodePipeline(commands: commands)
        XCTAssertThrowsError(try pipeline.upload(ipa: ipa, credentials: Credentials(), onLog: { _ in }, onStage: { _, _ in })) { error in
            XCTAssertEqual(error as? BuildError, .cancelled)
        }
        XCTAssertEqual(commands.invocations.count, 1)
        XCTAssertTrue(commands.invocations[0].contains("--find"))
        XCTAssertFalse(commands.invocations.contains { $0.contains("altool") })
    }

    func testTransporterFailureDoesNotFallBack() throws {
        let commands = ScriptedCommands()
        commands.handler = { arguments in
            if arguments.contains("iTMSTransporter") {
                throw BuildError.message("ERROR: authentication failed")
            }
            return CommandOutput(stdout: Data(), stderr: Data())
        }
        let pipeline = XcodePipeline(commands: commands)
        XCTAssertThrowsError(try pipeline.deliver(
            ipa: temp.appendingPathComponent("App.ipa").path,
            credentials: sampleCredentials(),
            transporterPath: "/usr/bin/iTMSTransporter",
            keyDirectory: temp,
            logFile: nil,
            onLog: { _ in }
        ))
        XCTAssertEqual(commands.invocations.count, 1)
        XCTAssertFalse(commands.invocations[0].contains("altool"))
    }

    func testMissingTransporterUsesAltoolOnce() throws {
        let commands = ScriptedCommands()
        let pipeline = XcodePipeline(commands: commands)
        try pipeline.deliver(
            ipa: temp.appendingPathComponent("App.ipa").path,
            credentials: sampleCredentials(),
            transporterPath: "",
            keyDirectory: temp,
            logFile: nil,
            onLog: { _ in }
        )
        XCTAssertEqual(commands.invocations.filter { $0.contains("altool") }.count, 1)
    }

    func testCommandSessionReadsStderr() throws {
        let output = try CommandSession().run(
            arguments: ["/bin/sh", "-c", "echo hello; echo trouble >&2"],
            directory: "",
            extraEnvironment: [:],
            onLog: nil,
            logFile: nil
        )
        XCTAssertTrue(String(decoding: output.stdout, as: UTF8.self).contains("hello"))
        XCTAssertTrue(String(decoding: output.stderr, as: UTF8.self).contains("trouble"))
    }

    func testTraditionalChineseStaysEnglish() {
        XCTAssertFalse(AppearanceStore.prefersSimplifiedChinese(selection: .system, locale: Locale(identifier: "zh-Hant")))
        XCTAssertFalse(AppearanceStore.prefersSimplifiedChinese(selection: .system, locale: Locale(identifier: "zh-TW")))
        XCTAssertFalse(AppearanceStore.prefersSimplifiedChinese(selection: .system, locale: Locale(identifier: "zh-HK")))
        XCTAssertTrue(AppearanceStore.prefersSimplifiedChinese(selection: .system, locale: Locale(identifier: "zh-Hans")))
        XCTAssertTrue(AppearanceStore.prefersSimplifiedChinese(selection: .system, locale: Locale(identifier: "zh-CN")))
        XCTAssertFalse(AppearanceStore.prefersSimplifiedChinese(selection: .english, locale: Locale(identifier: "zh-Hans")))
        XCTAssertTrue(AppearanceStore.prefersSimplifiedChinese(selection: .chinese, locale: Locale(identifier: "en")))
    }

    func testWarningTextFollowsLanguage() {
        let previous = AppearanceStore.shared.language
        defer { AppearanceStore.shared.language = previous }
        AppearanceStore.shared.language = .english
        XCTAssertTrue(Notice.profileExpired("Demo").text.contains("expired"))
        AppearanceStore.shared.language = .chinese
        XCTAssertTrue(Notice.profileExpired("Demo").text.contains("过期"))
    }

    @MainActor
    func testSecondBuildIsRejected() {
        let gate = BuildGate()
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(gate.begin(first))
        XCTAssertFalse(gate.begin(second))
        XCTAssertTrue(gate.isBusy)
        gate.end(first)
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.begin(second))
    }

    func testKeyIDRejectsPathCharacters() {
        XCTAssertFalse(Credentials.isValidKeyID("../secret"))
        XCTAssertFalse(Credentials.isValidKeyID("short"))
        XCTAssertTrue(Credentials.isValidKeyID("ABCD123456"))
        XCTAssertFalse(Credentials.isValidIssuerID("not-a-uuid"))
    }

    private func sampleCredentials() -> Credentials {
        var credentials = Credentials()
        credentials.keyId = "ABCD123456"
        credentials.issuerId = "00000000-0000-0000-0000-000000000000"
        return credentials
    }

    private func storeMetadata(method: String) throws -> String {
        let ipa = temp.appendingPathComponent("App.ipa")
        try Data("ipa".utf8).write(to: ipa)
        let meta = ExportMetadata(method: method, bundleId: "com.example.app", version: "1.0", build: "3", profile: "App Store")
        try JSONEncoder().encode(meta).write(to: temp.appendingPathComponent("App.export-metadata.json"))
        return ipa.path
    }
}
