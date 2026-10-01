import SwiftUI
import SwiftData
import UserNotifications

/// 小记页：当日小记编辑器（自动保存）+ AI 建议（channel = journal）+ 历史建议 + 23:30 提醒
struct JournalView: View {
    @Environment(\.modelContext) private var modelContext
    /// 空态「去设置」跳转「我的」tab（复用 selectedTab 机制）
    @Binding var selectedTab: AppTab

    /// 建议模型配置（@AppStorage JSON，与「我的-建议模型」共享）
    @AppStorage(LLMProviderConfig.adviceStorageKey) private var adviceConfigJSON = "{}"

    // MARK: 小记编辑
    @State private var journalText = ""
    /// 最近一次落库的文本（避免加载时与空文本触发无意义保存）
    @State private var lastSavedText = ""
    @State private var savedAt: Date?
    @State private var autosaveTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool

    // MARK: AI 建议
    @State private var cachedAdvice: DailyAdvice?
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?
    @State private var errorMessage: String?

    // MARK: 历史建议
    @State private var historyAdvice: [DailyAdvice] = []
    @State private var expandedAdviceIDs: Set<UUID> = []

    // MARK: 通知
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    /// 通知路由（点击 23:30 提醒自动生成建议 / 次日补生成横幅）
    @State private var router = NotificationRouter.shared

    private var isAdviceConfigured: Bool {
        let config = LLMProviderConfig(json: adviceConfigJSON) ?? .default
        return config.isEndpointConfigured && config.isModelConfigured && KeychainStore.advice.hasStoredKey
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let message = router.catchupMessage {
                        catchupBanner(message)
                    }
                    editorCard
                    adviceCard
                    historySection
                    notificationSection
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .navigationTitle("小记")
            .onAppear {
                loadToday()
                loadCachedAdvice()
                loadHistory()
                refreshNotificationStatus()
                consumePendingGeneration()
            }
            .onDisappear {
                // 失焦/离开页面兜底保存
                autosaveTask?.cancel()
                saveJournal()
            }
            .onChange(of: router.pendingJournalGeneration) { _, pending in
                guard pending else { return }
                consumePendingGeneration()
            }
        }
    }

    // MARK: - 待生成标记（通知直达）

    private func consumePendingGeneration() {
        guard router.pendingJournalGeneration else { return }
        router.pendingJournalGeneration = false
        generateAdvice()
    }

    // MARK: - 补生成横幅

    private func catchupBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text(message)
                .font(.subheadline)
            Spacer()
            Button {
                router.catchupMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    // MARK: - 小记编辑器

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日小记")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let savedAt {
                    Text("已保存 \(HealthCardFormat.clockText(savedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    saveJournal()
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(journalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && lastSavedText.isEmpty)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $journalText)
                    .focused($editorFocused)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                if journalText.isEmpty {
                    Text("记录今天的运动、工作、心情…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: journalText) { _, newValue in
                guard newValue != lastSavedText else { return }
                scheduleAutosave()
            }
            .onChange(of: editorFocused) { _, focused in
                // 失焦即保存（含取消未触发的延迟任务）
                if !focused { saveJournal() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    /// 输入停止 1 秒后自动保存
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveJournal()
        }
    }

    /// upsert 当日小记（一个业务日一篇）；无内容且无既有记录时跳过。
    /// 当日 = 当前业务日（凌晨 04:00 前写的小记归属前一业务日）
    private func saveJournal() {
        autosaveTask?.cancel()
        let text = journalText
        guard text != lastSavedText else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lastSavedText.isEmpty { return }
        do {
            _ = try JournalRepository(context: modelContext)
                .save(text: text, for: LogicalDay.businessDay(of: .now))
            lastSavedText = text
            savedAt = .now
        } catch {
            // 保存失败不打断输入，状态条不更新即提示未保存
        }
    }

    private func loadToday() {
        if let journal = try? JournalRepository(context: modelContext)
            .journal(for: LogicalDay.businessDay(of: .now)) {
            journalText = journal.text
            lastSavedText = journal.text
        } else {
            journalText = ""
            lastSavedText = ""
        }
    }

    // MARK: - AI 建议卡

    private var adviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("AI 健康建议")
                    .font(.subheadline.weight(.semibold))
            }

            if isGenerating {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在结合今日小记与数据生成建议…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", role: .cancel) {
                        generationTask?.cancel()
                        isGenerating = false
                    }
                    .font(.subheadline)
                }
            } else if !isAdviceConfigured {
                Text("建议模型未配置，请先到「我的」填写模型与 API Key")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    selectedTab = .settings
                } label: {
                    Label("去配置", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
            } else if let advice = cachedAdvice {
                adviceContent(advice, showRegenerate: true)
            } else {
                Text("结合今日小记与饮食、健康数据，生成专属于今天的建议")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    generateAdvice()
                } label: {
                    Label("生成今日建议", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
            }

            if let errorMessage, !isGenerating {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    /// 建议全文：四个小标题加粗分段 + 生成时间 + 可选重新生成
    private func adviceContent(_ advice: DailyAdvice, showRegenerate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let sections = AdviceService.parseSections(from: advice.content)
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                VStack(alignment: .leading, spacing: 4) {
                    if !section.title.isEmpty {
                        Text(section.title)
                            .font(.subheadline.weight(.bold))
                    }
                    Text(section.body)
                        .font(.subheadline)
                        .foregroundStyle(section.title.isEmpty ? .primary : .secondary)
                }
            }

            HStack {
                Text("生成于 \(HealthCardFormat.clockText(advice.generatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if showRegenerate {
                    Button {
                        generateAdvice()
                    } label: {
                        Label("重新生成", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func loadCachedAdvice() {
        // 建议归属业务日（凌晨 04:00 前算前一业务日）
        cachedAdvice = try? AdviceRepository(context: modelContext)
            .advice(for: LogicalDay.businessDay(of: .now), channel: DailyAdvice.Channel.journal)
    }

    private func generateAdvice() {
        guard !isGenerating else { return }
        let config = LLMProviderConfig(json: adviceConfigJSON) ?? .default
        guard config.isEndpointConfigured, config.isModelConfigured,
              let apiKey = KeychainStore.advice.load() else { return }

        errorMessage = nil
        isGenerating = true
        let context = modelContext
        let text = journalText
        let adviceDay = LogicalDay.businessDay(of: .now)
        generationTask = Task {
            do {
                let content = try await AdviceService().generateAdvice(
                    date: adviceDay,
                    context: context,
                    config: config,
                    apiKey: apiKey,
                    channel: DailyAdvice.Channel.journal,
                    journalText: text
                )
                guard !Task.isCancelled else { return }
                let saved = try AdviceRepository(context: context).upsert(
                    date: adviceDay,
                    channel: DailyAdvice.Channel.journal,
                    content: content,
                    modelTag: config.modelID
                )
                cachedAdvice = saved
                loadHistory()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            isGenerating = false
        }
    }

    // MARK: - 历史建议

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("历史建议")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            if historyAdvice.isEmpty {
                Text("近 30 天暂无历史建议")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(historyAdvice) { advice in
                    historyRow(advice)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func historyRow(_ advice: DailyAdvice) -> some View {
        let isExpanded = expandedAdviceIDs.contains(advice.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isExpanded {
                    expandedAdviceIDs.remove(advice.id)
                } else {
                    expandedAdviceIDs.insert(advice.id)
                }
            } label: {
                HStack {
                    Text(Self.dayTitle(advice.date))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                adviceContent(advice, showRegenerate: false)
            } else {
                Text(String(advice.content.prefix(60)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 近 30 天 journal 渠道建议按业务日去重（每个业务日取最新一条），倒序；
    /// 当前业务日已在顶部展示，不重复
    private func loadHistory() {
        let calendar = Calendar.current
        guard let from = calendar.date(byAdding: .day, value: -30, to: .now) else { return }
        let all = (try? AdviceRepository(context: modelContext).fetch(from: from, to: .now)) ?? []
        let todayBusinessDay = LogicalDay.businessDay(of: .now)
        var seenDays: Set<Date> = []
        var latestPerDay: [DailyAdvice] = []
        for advice in all.sorted(by: { $0.generatedAt > $1.generatedAt })
        where advice.channel == DailyAdvice.Channel.journal {
            let day = LogicalDay.businessDay(of: advice.date)
            if seenDays.insert(day).inserted {
                latestPerDay.append(advice)
            }
        }
        historyAdvice = latestPerDay.filter { LogicalDay.businessDay(of: $0.date) != todayBusinessDay }
    }

    /// 日期 →「MM月dd日」（固定 locale，结果稳定）
    private static func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM月dd日"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    // MARK: - 通知权限区

    private var notificationSection: some View {
        Group {
            switch notifStatus {
            case .notDetermined:
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(.orange)
                    Text("开启提醒，每天 23:30 记录小记并生成建议")
                        .font(.subheadline)
                    Spacer()
                    Button("开启") {
                        enableReminder()
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.subheadline)
                }
                .frameCardStyle()
            case .denied:
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.secondary)
                    Text("通知已关闭，去系统设置开启后可每天 23:30 提醒")
                        .font(.subheadline)
                    Spacer()
                    Button("去设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
                }
                .frameCardStyle()
            default:
                EmptyView()
            }
        }
    }

    private func enableReminder() {
        Task {
            let granted = await NotificationService.requestAuthorizationIfNeeded()
            if granted {
                await NotificationService.scheduleDailyReminder()
            }
            await MainActor.run { refreshNotificationStatus() }
        }
    }

    private func refreshNotificationStatus() {
        Task { @MainActor in
            notifStatus = await NotificationService.authorizationStatus()
        }
    }
}

// MARK: - 小工具

private extension View {
    /// 提示条统一样式
    func frameCardStyle() -> some View {
        self
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
    }
}

#Preview {
    JournalView(selectedTab: .constant(.home))
        .modelContainer(for: [Meal.self, FoodItem.self, WeightRecord.self, DailyJournal.self, DailyAdvice.self, DailyHealthSnapshot.self], inMemory: true)
}
