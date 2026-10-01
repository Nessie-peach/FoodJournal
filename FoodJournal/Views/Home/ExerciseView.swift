import SwiftUI
import SwiftData

/// 迈开腿页：当日健康快照卡片（活动消耗 / 睡眠 / 心率 / HRV）。
/// 数据来自 SwiftData（DailyHealthSnapshot），进入页面或下拉刷新时后台触发 HealthKit 同步，不阻塞 UI。
struct ExerciseView: View {
    @Environment(\.modelContext) private var modelContext
    /// 空态「去设置」跳转「我的」tab（复用备份横幅的 selectedTab 机制）
    @Binding var selectedTab: AppTab

    @Query private var todaySnapshots: [DailyHealthSnapshot]

    /// 建议模型配置（@AppStorage JSON，与「我的-建议模型」共享）
    @AppStorage(LLMProviderConfig.adviceStorageKey) private var adviceConfigJSON = "{}"

    /// 授权状态（异步取一次）：用于区分空态是「未授权」还是「健康里没数据」
    @State private var authState: HealthAuthorizationState = .notDetermined

    /// 当日 AI 建议缓存（channel = exercise）
    @State private var cachedAdvice: DailyAdvice?
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?
    @State private var errorMessage: String?

    /// 全局同步状态（@Observable，body 内读取自动追踪）
    private let syncStatus = SyncStatusStore.shared

    /// 卡片数值处是否显示同步转圈：仅当同步中且本轮含 Garmin 来源
    private var isGarminSyncing: Bool {
        syncStatus.isSyncing && syncStatus.currentSources.contains(.garmin)
    }

    private var todaySnapshot: DailyHealthSnapshot? {
        todaySnapshots.first
    }

    /// 建议模型是否可用（端点 + 模型 + Key 均已配置）
    private var isAdviceConfigured: Bool {
        let config = LLMProviderConfig(json: adviceConfigJSON) ?? .default
        return config.isEndpointConfigured && config.isModelConfigured && KeychainStore.advice.hasStoredKey
    }

    init(selectedTab: Binding<AppTab>) {
        _selectedTab = selectedTab
        let calendar = Calendar.current
        // 今日快照：快照按自然日 key 存取，凌晨窗口（00:00–04:00）取前一自然日（方案 A），
        // 与 HomeView 缺口卡消耗口径一致
        let burnDayStart = LogicalDay.burnSnapshotDay(for: .now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 1, to: burnDayStart) ?? burnDayStart
        _todaySnapshots = Query(
            filter: #Predicate<DailyHealthSnapshot> { snapshot in
                snapshot.date >= burnDayStart && snapshot.date < end
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
        // 昨日范围（身体电量较昨日趋势对比用）：今日快照日的前一自然日
        let yesterdayStart = LogicalDay.previousCalendarDay(of: burnDayStart, calendar: calendar)
        let yesterdayEnd = burnDayStart
        _yesterdaySnapshots = Query(
            filter: #Predicate<DailyHealthSnapshot> { snapshot in
                snapshot.date >= yesterdayStart && snapshot.date < yesterdayEnd
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                syncStatusBar
                    .padding(.horizontal, 16)

                Group {
                    if let snapshot = todaySnapshot {
                        cards(for: snapshot)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity)

                historyEntry

                adviceCard
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            loadCachedAdvice()
            triggerSync()
        }
        .refreshable { await syncNow() }
    }

    // MARK: - 同步状态条

    /// 同步中：转圈 + 来源文案；空闲：「上次同步 HH:mm」/「尚未同步」；失败：⚠️ + 重试
    @ViewBuilder
    private var syncStatusBar: some View {
        HStack(spacing: 6) {
            if syncStatus.isSyncing {
                ProgressView()
                    .controlSize(.small)
                Text(syncStatus.currentSources.contains(.garmin) ? "正在同步佳明数据…" : "正在同步健康数据…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = syncStatus.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("重试") {
                    Task { await syncNow() }
                }
                .font(.caption)
            } else if let last = syncStatus.lastSyncAt {
                Text("上次同步 \(HealthCardFormat.clockText(last))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("尚未同步")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    // MARK: - 卡片区

    private func cards(for snapshot: DailyHealthSnapshot) -> some View {
        VStack(spacing: 16) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                spacing: 12
            ) {
                HealthMetricCard(
                    icon: "flame.fill", title: "活动消耗", tint: .orange,
                    value: "\(Int(snapshot.activeKcal.rounded()))", unit: "千卡",
                    showsSpinner: isGarminSyncing
                )
                HealthMetricCard(
                    icon: "bed.double.fill", title: "睡眠", tint: .indigo,
                    value: HealthCardFormat.sleepText(minutes: snapshot.sleepMinutes),
                    unit: nil,
                    footnote: sleepFootnote(snapshot),
                    showsSpinner: isGarminSyncing
                )
                HealthMetricCard(
                    icon: "heart.fill", title: "平均心率", tint: .pink,
                    value: HealthCardFormat.heartText(bpm: snapshot.avgHR),
                    unit: snapshot.avgHR > 0 ? "次/分" : nil,
                    showsSpinner: isGarminSyncing
                )
                HealthMetricCard(
                    icon: "waveform.path.ecg", title: "HRV", tint: .green,
                    value: hrvCard.value,
                    unit: hrvCard.unit,
                    footnote: hrvCard.footnote,
                    showsSpinner: isGarminSyncing
                )
                HealthMetricCard(
                    icon: "battery.75percent", title: "身体电量", tint: .cyan,
                    value: batteryCard.value,
                    unit: batteryCard.unit,
                    footnote: batteryCard.footnote,
                    showsSpinner: isGarminSyncing
                )
                HealthMetricCard(
                    icon: "brain.head.profile", title: "压力", tint: .mint,
                    value: stressCard.value,
                    unit: stressCard.unit,
                    footnote: stressCard.footnote,
                    showsSpinner: isGarminSyncing
                )
            }

            Text("更新于 \(HealthCardFormat.clockText(snapshot.syncedAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    /// HRV 卡：有 Garmin 数据优先（标「佳明」），否则回落 HealthKit，都没有显示「未同步」
    private var hrvCard: ExerciseCardLogic.HRVCard {
        ExerciseCardLogic.hrvCard(from: todaySnapshot)
    }

    /// 身体电量卡：当前值 + 较昨日充/放趋势
    private var batteryCard: ExerciseCardLogic.BatteryCard {
        ExerciseCardLogic.batteryCard(current: todaySnapshot?.bodyBatteryCurrent, yesterday: yesterdaySnapshot?.bodyBatteryCurrent)
    }

    /// 压力卡：均值 + 等级文案
    private var stressCard: ExerciseCardLogic.StressCard {
        ExerciseCardLogic.stressCard(avg: todaySnapshot?.stressAvg)
    }

    /// 昨日快照（身体电量趋势对比用）
    @Query private var yesterdaySnapshots: [DailyHealthSnapshot]

    private var yesterdaySnapshot: DailyHealthSnapshot? {
        yesterdaySnapshots.first
    }

    /// 睡眠卡脚注：起止时间 + 分期摘要（深睡/REM/睡眠分，有 Garmin 分期数据时）
    private func sleepFootnote(_ snapshot: DailyHealthSnapshot) -> String? {
        var parts: [String] = []
        if let timeText = sleepTimeText(snapshot) {
            parts.append(timeText)
        }
        if let stagesText = ExerciseCardLogic.sleepStagesText(snapshot) {
            parts.append(stagesText)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 「23:40 入睡 · 07:00 起床」，起止任一缺失则不显示
    private func sleepTimeText(_ snapshot: DailyHealthSnapshot) -> String? {
        guard let start = snapshot.sleepStart, let end = snapshot.sleepEnd else { return nil }
        return "\(HealthCardFormat.clockText(start)) 入睡 · \(HealthCardFormat.clockText(end)) 起床"
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.run")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("暂无健康数据")
                .font(.title3.weight(.semibold))
            Text(emptyStateHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                selectedTab = .settings
            } label: {
                Label(emptyStateButtonTitle, systemImage: "person.crop.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 80)
        .padding(.bottom, 32)
    }

    /// 空态文案：未请求授权 → 引导去授权；已请求但无数据 → 指向健康数据源
    private var emptyStateHint: String {
        switch authState {
        case .notDetermined:
            return "请先到「我的 → 健康数据」完成授权"
        case .requested:
            return "健康里可能还没有数据，请确认佳明 Connect 已开启同步到苹果健康"
        }
    }

    private var emptyStateButtonTitle: String {
        authState == .notDetermined ? "去授权" : "去设置"
    }

    // MARK: - 历史入口

    /// 四卡片之后 → 锻炼历史页（只读）
    private var historyEntry: some View {
        NavigationLink {
            ExerciseHistoryView()
        } label: {
            HStack {
                Spacer()
                Text("查看锻炼历史")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - AI 健康建议卡

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
                    Text("正在结合今日数据生成建议…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", role: .cancel) {
                        generationTask?.cancel()
                        isGenerating = false
                    }
                    .font(.subheadline)
                }
            } else if todaySnapshot == nil {
                Text("先完成健康数据授权，才能生成建议")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    selectedTab = .settings
                } label: {
                    Label("生成今日建议", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
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
                adviceContent(advice)
            } else {
                Text("结合今天的睡眠、运动与饮食数据，生成私人化建议")
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
        .padding(.bottom, 24)
    }

    /// 建议全文：四个小标题加粗分段 + 生成时间 + 重新生成
    private func adviceContent(_ advice: DailyAdvice) -> some View {
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

    private func loadCachedAdvice() {
        // 建议归属业务日（凌晨 04:00 前算前一业务日）
        cachedAdvice = try? AdviceRepository(context: modelContext)
            .advice(for: LogicalDay.businessDay(of: .now), channel: DailyAdvice.Channel.exercise)
    }

    private func generateAdvice() {
        guard todaySnapshot != nil, !isGenerating else { return }
        let config = LLMProviderConfig(json: adviceConfigJSON) ?? .default
        guard config.isEndpointConfigured, config.isModelConfigured,
              let apiKey = KeychainStore.advice.load() else { return }

        errorMessage = nil
        isGenerating = true
        let context = modelContext
        let adviceDay = LogicalDay.businessDay(of: .now)
        generationTask = Task {
            do {
                let content = try await AdviceService()
                    .generateAdvice(date: adviceDay, context: context, config: config, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                let saved = try AdviceRepository(context: context).upsert(
                    date: adviceDay,
                    channel: DailyAdvice.Channel.exercise,
                    content: content,
                    modelTag: config.modelID
                )
                cachedAdvice = saved
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            isGenerating = false
        }
    }

    // MARK: - 同步

    /// 进入页面先取一次授权状态（供空态区分），再触发一次前台同步（15 分钟防抖，
    /// 未请求授权时协调器内部 HealthKit 分支先请求授权）
    private func triggerSync() {
        Task {
            authState = await HealthKitService().authorizationState()
            await SyncCoordinator.shared.sync(trigger: .foreground)
        }
    }

    /// 下拉刷新 / 失败重试：手动同步，忽略防抖并重置熔断计数
    private func syncNow() async {
        await SyncCoordinator.shared.sync(trigger: .manual)
    }
}

// MARK: - 卡片数据逻辑（纯函数，可单测）

/// 迈开腿卡片数据源选择与文案构造：本地快照驱动，无副作用
enum ExerciseCardLogic {
    struct HRVCard: Equatable {
        let value: String
        let unit: String?
        let footnote: String?
    }

    /// HRV 卡数据源选择：Garmin lastNightAvg 优先（标「佳明」+ 基线状态）→ HealthKit hrvMS 回落 → 未同步
    static func hrvCard(from snapshot: DailyHealthSnapshot?) -> HRVCard {
        guard let snapshot else { return HRVCard(value: "—", unit: nil, footnote: "未同步") }
        if let garmin = snapshot.hrvLastNightAvg {
            var footnote = "佳明"
            if let low = snapshot.hrvBaselineLow, let high = snapshot.hrvBaselineHigh {
                let status = garmin < low ? "，偏低" : garmin > high ? "，偏高" : "，平衡"
                footnote = "\(Int(garmin.rounded())) ms · 基线 \(Int(low))-\(Int(high))\(status) · 佳明"
            }
            return HRVCard(value: String(Int(garmin.rounded())), unit: "ms", footnote: footnote)
        }
        if let hk = snapshot.hrvMS {
            return HRVCard(value: String(Int(hk.rounded())), unit: "ms", footnote: nil)
        }
        return HRVCard(value: "—", unit: nil, footnote: "未同步")
    }

    struct BatteryCard: Equatable {
        let value: String
        let unit: String?
        let footnote: String?
    }

    /// 身体电量卡：当前值 + 较昨日充/放趋势
    static func batteryCard(current: Int?, yesterday: Int?) -> BatteryCard {
        guard let current else { return BatteryCard(value: "—", unit: nil, footnote: "未同步") }
        let footnote: String?
        if let yesterday {
            let delta = current - yesterday
            footnote = delta > 0 ? "较昨日充电 +\(delta)" : delta < 0 ? "较昨日放电 −\(abs(delta))" : "与昨日持平"
        } else {
            footnote = nil
        }
        return BatteryCard(value: String(current), unit: nil, footnote: footnote)
    }

    struct StressCard: Equatable {
        let value: String
        let unit: String?
        let footnote: String?
    }

    /// 压力卡：均值 + 等级文案（Garmin 分级：0-25 低 / 26-50 中 / 51-75 高 / 76-100 极高）
    static func stressCard(avg: Int?) -> StressCard {
        guard let avg else { return StressCard(value: "—", unit: nil, footnote: "未同步") }
        let level: String
        switch avg {
        case ..<26: level = "低压力"
        case ..<51: level = "中等压力"
        case ..<76: level = "高压力"
        default: level = "极高压力"
        }
        return StressCard(value: String(avg), unit: nil, footnote: level)
    }

    /// 睡眠分期摘要：「深睡 x% · REM y% · 睡眠分 z」。
    /// 百分比基准为快照睡眠时长（HealthKit 口径）；无时长时按分钟展示。
    /// 任一必需数据缺失返回 nil（脚注退回仅起止时间）。
    static func sleepStagesText(_ snapshot: DailyHealthSnapshot) -> String? {
        guard let deep = snapshot.deepSleepMin, let rem = snapshot.remSleepMin else { return nil }
        var deepPart: String
        var remPart: String
        if snapshot.sleepMinutes > 0 {
            let deepPct = Int((deep / snapshot.sleepMinutes * 100).rounded())
            let remPct = Int((rem / snapshot.sleepMinutes * 100).rounded())
            deepPart = "深睡 \(deepPct)%"
            remPart = "REM \(remPct)%"
        } else {
            deepPart = "深睡 \(Int(deep.rounded())) 分"
            remPart = "REM \(Int(rem.rounded())) 分"
        }
        var text = "\(deepPart) · \(remPart)"
        if let score = snapshot.sleepScore {
            text += " · 睡眠分 \(score)"
        }
        return text
    }
}

// MARK: - 单个指标卡片

/// 健康指标卡片：图标 + 标题 + 大字数值 + 可选单位/脚注，风格与管住嘴页汇总条统一
private struct HealthMetricCard: View {
    let icon: String
    let title: String
    let tint: Color
    let value: String
    let unit: String?
    var footnote: String? = nil
    /// 同步中在数值位置显示小转圈（隐藏原数值占位，避免布局跳动）
    var showsSpinner: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                ZStack(alignment: .leading) {
                    Text(value)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .opacity(showsSpinner ? 0 : 1)
                    if showsSpinner {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ExerciseView(selectedTab: .constant(.home))
        .modelContainer(for: [Meal.self, FoodItem.self, WeightRecord.self, DailyJournal.self, DailyAdvice.self, DailyHealthSnapshot.self], inMemory: true)
}
