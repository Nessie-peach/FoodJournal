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
        // 今日范围（含边界当天全天），与 HomeView 今日口径一致
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        _todaySnapshots = Query(
            filter: #Predicate<DailyHealthSnapshot> { snapshot in
                snapshot.date >= start && snapshot.date < end
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
        // 昨日范围（身体电量较昨日趋势对比用）
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        _yesterdaySnapshots = Query(
            filter: #Predicate<DailyHealthSnapshot> { snapshot in
                snapshot.date >= yesterdayStart && snapshot.date < start
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Group {
                    if let snapshot = todaySnapshot {
                        cards(for: snapshot)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity)

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

    // MARK: - 卡片区

    private func cards(for snapshot: DailyHealthSnapshot) -> some View {
        VStack(spacing: 16) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                spacing: 12
            ) {
                HealthMetricCard(
                    icon: "flame.fill", title: "活动消耗", tint: .orange,
                    value: "\(Int(snapshot.activeKcal.rounded()))", unit: "千卡"
                )
                HealthMetricCard(
                    icon: "bed.double.fill", title: "睡眠", tint: .indigo,
                    value: HealthCardFormat.sleepText(minutes: snapshot.sleepMinutes),
                    unit: nil,
                    footnote: sleepFootnote(snapshot)
                )
                HealthMetricCard(
                    icon: "heart.fill", title: "平均心率", tint: .pink,
                    value: HealthCardFormat.heartText(bpm: snapshot.avgHR),
                    unit: snapshot.avgHR > 0 ? "次/分" : nil
                )
                HealthMetricCard(
                    icon: "waveform.path.ecg", title: "HRV", tint: .green,
                    value: hrvCard.value,
                    unit: hrvCard.unit,
                    footnote: hrvCard.footnote
                )
                HealthMetricCard(
                    icon: "battery.75percent", title: "身体电量", tint: .cyan,
                    value: batteryCard.value,
                    unit: batteryCard.unit,
                    footnote: batteryCard.footnote
                )
                HealthMetricCard(
                    icon: "brain.head.profile", title: "压力", tint: .mint,
                    value: stressCard.value,
                    unit: stressCard.unit,
                    footnote: stressCard.footnote
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
        cachedAdvice = try? AdviceRepository(context: modelContext)
            .advice(for: .now, channel: DailyAdvice.Channel.exercise)
    }

    private func generateAdvice() {
        guard todaySnapshot != nil, !isGenerating else { return }
        let config = LLMProviderConfig(json: adviceConfigJSON) ?? .default
        guard config.isEndpointConfigured, config.isModelConfigured,
              let apiKey = KeychainStore.advice.load() else { return }

        errorMessage = nil
        isGenerating = true
        let context = modelContext
        generationTask = Task {
            do {
                let content = try await AdviceService()
                    .generateAdvice(date: .now, context: context, config: config, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                let saved = try AdviceRepository(context: context).upsert(
                    date: .now,
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

    /// 进入页面先取一次授权状态（供空态区分），再触发一次后台同步
    ///（未请求授权时 syncRecent 内部直接跳过，不弹授权）
    private func triggerSync() {
        Task {
            authState = await HealthKitService().authorizationState()
            await syncNow()
        }
    }

    /// HealthKit 同步 + 已登录 Garmin 时追加 Garmin 后台同步（数据落快照，卡片经 @Query 自动刷新）
    private func syncNow() async {
        await HealthKitService().syncRecent(days: 7, context: modelContext)
        if GarminTokenStore.shared.loadTokens() != nil {
            await GarminSyncService().syncRecent(days: 7, context: modelContext)
        }
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
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
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
