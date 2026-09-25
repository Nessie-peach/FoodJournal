import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

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

                DataManagementSection(
                    modelContext: modelContext
                )

                HealthDataSection()
            }
            .navigationTitle("我的")
        }
    }
}

// MARK: - 健康数据（HealthKit 同步状态与操作）

private struct HealthDataSection: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(HealthKitService.authRequestedStorageKey) private var hasRequestedHealthAuth = false

    @State private var state: HealthAuthorizationState = .notDetermined
    @State private var isSyncing = false
    @State private var syncResult: String?

    var body: some View {
        Section {
            permissionRow

            // 佳明同步引导：固定文案
            Text("数据来自苹果健康。请在佳明 Connect 中开启：头像 → 设置 → 已连接的设备 → 健康（Apple Health）→ 打开共享")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                Task { await syncNow() }
            } label: {
                HStack {
                    if isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("立即同步")
                }
            }
            .disabled(isSyncing || state == .denied)

            if let syncResult {
                Text(syncResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("健康数据")
        } footer: {
            Text("App 变为前台时自动同步最近 7 天数据；也可手动立即同步。")
                .font(.footnote)
        }
        .onAppear { refreshState() }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch state {
        case .authorized:
            HStack {
                Text("HealthKit 权限")
                Spacer()
                Text("已授权").foregroundStyle(.green).font(.footnote)
            }
        case .notDetermined:
            HStack {
                Text("HealthKit 权限")
                Spacer()
                Button("去授权") {
                    Task {
                        try? await HealthKitService().requestAuthorization()
                        hasRequestedHealthAuth = true
                        refreshState()
                    }
                }
                .font(.footnote)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("HealthKit 权限")
                    Spacer()
                    Text("被拒绝").foregroundStyle(.red).font(.footnote)
                }
                Text("请到系统设置开启")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("前往系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote)
            }
        }
    }

    private func refreshState() {
        state = HealthKitService().authorizationState(hasRequestedBefore: hasRequestedHealthAuth)
    }

    private func syncNow() async {
        isSyncing = true
        syncResult = nil
        defer { isSyncing = false }
        let service = HealthKitService()
        guard service.authorizationState(hasRequestedBefore: hasRequestedHealthAuth) == .authorized else {
            syncResult = "未授权，无法同步"
            return
        }
        await service.syncRecent(days: 7, context: modelContext)
        syncResult = "已同步最近 7 天健康数据"
    }
}

// MARK: - 数据管理（导出 / 导入备份）

private struct DataManagementSection: View {
    let modelContext: ModelContext

    /// 最近一次成功导出的时间戳（0 = 从未导出）
    @AppStorage(BackupService.lastExportStorageKey) private var lastExportTimestamp: Double = 0

    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var importReport: ImportReport?
    @State private var errorMessage: String?

    private var lastExportText: String {
        guard lastExportTimestamp > 0 else { return "从未导出" }
        return Date(timeIntervalSince1970: lastExportTimestamp)
            .formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        Section {
            HStack {
                Text("上次导出")
                Spacer()
                Text(lastExportText)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            Button {
                runExport()
            } label: {
                HStack {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("导出数据")
                }
            }
            .disabled(isExporting || isImporting)

            if let exportedURL {
                ShareLink(item: exportedURL, preview: SharePreview("今天吃什么-备份")) {
                    Label("分享刚导出的备份文件", systemImage: "square.and.arrow.up")
                }
            }

            Button {
                showImporter = true
            } label: {
                HStack {
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("导入数据")
                }
            }
            .disabled(isExporting || isImporting)
        } header: {
            Text("数据管理")
        } footer: {
            Text("侧载 App 每 7 天需重装，请定期导出备份。备份含餐食/照片/体重/小记/建议，不含模型配置与 API Key。")
                .font(.footnote)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .alert("导入完成", isPresented: .init(
            get: { importReport != nil },
            set: { if !$0 { importReport = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(importReport?.summary ?? "")
        }
        .alert("操作失败", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 导出

    private func runExport() {
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try BackupService(modelContext: modelContext).export()
            lastExportTimestamp = Date().timeIntervalSince1970
            exportedURL = url
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 导入

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            defer { isImporting = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try BackupService(modelContext: modelContext).importBackup(from: url)
                importReport = report
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
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
