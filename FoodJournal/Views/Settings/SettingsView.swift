import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("LLM 模型设置") {
                    Text("识图功能需选择支持视觉（图片输入）的模型；API Key 与所有配置仅存储在本机，不会上传到任何服务器。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                LLMProviderSection(
                    title: "识图模型",
                    storageKey: LLMProviderConfig.visionStorageKey,
                    keychain: .vision
                )

                LLMProviderSection(
                    title: "建议模型",
                    storageKey: LLMProviderConfig.adviceStorageKey,
                    keychain: .advice
                )

                Section {
                    Text("导出 / 导入功能将在后续版本提供")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("数据管理（导出/导入，后续版本提供）")
                }
            }
            .navigationTitle("我的")
        }
    }
}

// MARK: - 单个模型配置 Section（识图 / 建议复用）

private struct LLMProviderSection: View {
    let title: String
    let keychain: KeychainStore

    @AppStorage private var configJSON: String
    @State private var manualModelInput = false
    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var isTesting = false
    @State private var testResult: String?

    init(title: String, storageKey: String, keychain: KeychainStore) {
        self.title = title
        self.keychain = keychain
        _configJSON = AppStorage(wrappedValue: LLMProviderConfig.default.asJSON, storageKey)
    }

    /// 桥接 @AppStorage 的 JSON 字符串与 LLMProviderConfig
    private var config: LLMProviderConfig {
        get { LLMProviderConfig(json: configJSON) ?? .default }
        nonmutating set { configJSON = newValue.asJSON }
    }

    // 计算属性不能直接用作 Binding，以下为显式 Binding（set 整体回写保证持久化）
    private var presetBinding: Binding<LLMPreset> {
        Binding(
            get: { config.preset },
            set: { var c = config; c.applyPreset($0); config = c }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { config.baseURL },
            set: { var c = config; c.baseURL = $0; config = c }
        )
    }

    private var modelIDBinding: Binding<String> {
        Binding(
            get: { config.modelID },
            set: { var c = config; c.modelID = $0; config = c }
        )
    }

    /// 快捷选项列表；当前模型 ID 不在预设中时置顶展示，避免 Picker 显示为空
    private var modelOptions: [String] {
        var options = config.preset.quickModels
        let current = config.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty && !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options
    }

    private var canTest: Bool {
        config.isEndpointConfigured
            && config.isModelConfigured
            && (hasStoredKey || !apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        Section(title) {
            Picker("厂商预设", selection: presetBinding) {
                ForEach(LLMPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .onChange(of: config.preset) { _, newPreset in
                config.applyPreset(newPreset)
            }

            TextField("BaseURL（https://…）", text: baseURLBinding)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            modelInputRows

            SecureField("API Key", text: $apiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: apiKeyInput) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    if (try? keychain.save(trimmed)) != nil {
                        hasStoredKey = true
                    }
                }

            keyStatusRow

            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("测试连通")
                }
            }
            .disabled(!canTest || isTesting)

            if let testResult {
                Text(testResult)
                    .font(.footnote)
                    .foregroundStyle(testResult.hasPrefix("✅") ? Color.green : Color.red)
            }
        }
        .onAppear {
            hasStoredKey = keychain.hasStoredKey
        }
    }

    /// 模型 ID：预设快捷选项 Picker + 手动输入开关；custom 全手填
    @ViewBuilder
    private var modelInputRows: some View {
        if config.preset != .custom && !config.preset.quickModels.isEmpty {
            Toggle("手动输入模型 ID", isOn: $manualModelInput)
        }

        if config.preset == .custom || manualModelInput {
            TextField("模型 ID（手填）", text: modelIDBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            Picker("模型 ID", selection: modelIDBinding) {
                ForEach(modelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
        }
    }

    @ViewBuilder
    private var keyStatusRow: some View {
        HStack {
            Text(hasStoredKey ? "API Key 已存储" : "API Key 未存储")
                .font(.footnote)
                .foregroundStyle(hasStoredKey ? Color.green : Color.secondary)
            Spacer()
            if hasStoredKey {
                Button("清除", role: .destructive) {
                    keychain.delete()
                    hasStoredKey = false
                    apiKeyInput = ""
                }
                .font(.footnote)
            }
        }
    }

    private func runTest() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespaces)
        let stored = key.isEmpty ? (keychain.load() ?? "") : key

        isTesting = true
        testResult = nil
        defer { isTesting = false }

        guard !stored.isEmpty, config.isEndpointConfigured, config.isModelConfigured else {
            testResult = "❌ 请先填写 BaseURL、模型 ID 和 API Key"
            return
        }

        do {
            let elapsed = try await LLMClient().testConnection(config: config, apiKey: stored)
            testResult = "✅ 连接成功，耗时 \(String(format: "%.1f", elapsed)) 秒"
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView()
}
