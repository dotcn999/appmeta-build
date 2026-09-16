import SwiftUI

struct ContentView: View {
    @StateObject private var engine = BuildEngine()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox(L10n.t("App Store Connect API Key", "App Store Connect API Key")) {
                HStack(spacing: 8) {
                    TextField("Key ID", text: $engine.credentials.keyId)
                        .textFieldStyle(.roundedBorder)
                    TextField("Issuer ID", text: $engine.credentials.issuerId)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.t("Choose .p8", "选择 .p8")) { engine.choosePrivateKey() }
                    Button(L10n.t("Save", "保存")) { engine.saveCredentials() }
                }
                Text(engine.credentials.privateKeyPath.isEmpty
                     ? L10n.t("No private key selected.", "尚未选择私钥。")
                     : engine.credentials.privateKeyPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                TextField(L10n.t("Project path", "工程路径"), text: $engine.projectPath)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.t("Choose…", "选择…")) { engine.chooseProject() }
                Button(L10n.t("Inspect", "识别工程")) { engine.runInspect() }
                    .disabled(engine.projectPath.isEmpty || engine.busy)
            }

            if let ins = engine.inspect {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("Scheme", "Scheme"))
                        Picker("", selection: $engine.scheme) {
                            ForEach(ins.schemes, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("Provisioning profile", "描述文件"))
                        Picker("", selection: $engine.profile) {
                            ForEach(ins.profiles) { p in
                                Text(p.displayName).tag(p.value)
                            }
                        }
                        .labelsHidden()
                    }
                }
                Text(engine.facts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !ins.warnings.isEmpty {
                    Text(ins.warnings.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                Button(L10n.t("Archive, export & upload", "Archive、导出并上传")) {
                    engine.runExport(upload: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!engine.ready || !engine.canUpload || engine.busy)
                Button(L10n.t("Archive & export IPA", "Archive 并导出 IPA")) {
                    engine.runExport(upload: false)
                }
                .disabled(!engine.ready || engine.busy)
                Button(L10n.t("Upload IPA", "上传 IPA")) { engine.runUpload() }
                    .disabled(engine.artifact.isEmpty || !engine.canUpload || engine.busy)
                Spacer()
                Button(L10n.t("Cancel", "取消")) { engine.cancel() }
                    .disabled(!engine.busy)
                Button(L10n.t("Show IPA in Finder", "在 Finder 中显示 IPA")) { engine.revealArtifact() }
                    .disabled(engine.artifact.isEmpty)
            }

            HStack {
                Text(engine.stage.isEmpty ? L10n.t("Idle.", "空闲。") : engine.stage)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if engine.busy { ProgressView().controlSize(.small) }
            }
            if !engine.lastError.isEmpty {
                Text(engine.lastError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(3)
            }

            ScrollView {
                Text(engine.log.isEmpty ? L10n.t("Build log appears here.", "构建日志会显示在这里。") : engine.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("AppMeta Build")
        .onChange(of: engine.credentials) { _ in engine.saveCredentials() }
    }
}
