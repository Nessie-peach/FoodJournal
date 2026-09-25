import SwiftUI
import SwiftData

/// 迈开腿页：当日健康快照卡片（活动消耗 / 睡眠 / 心率 / HRV）。
/// 数据来自 SwiftData（DailyHealthSnapshot），进入页面或下拉刷新时后台触发 HealthKit 同步，不阻塞 UI。
struct ExerciseView: View {
    @Environment(\.modelContext) private var modelContext
    /// 空态「去设置」跳转「我的」tab（复用备份横幅的 selectedTab 机制）
    @Binding var selectedTab: AppTab

    @Query private var todaySnapshots: [DailyHealthSnapshot]

    private var todaySnapshot: DailyHealthSnapshot? {
        todaySnapshots.first
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
    }

    var body: some View {
        ScrollView {
            Group {
                if let snapshot = todaySnapshot {
                    cards(for: snapshot)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: triggerSync)
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
                    footnote: sleepTimeText(snapshot)
                )
                HealthMetricCard(
                    icon: "heart.fill", title: "平均心率", tint: .pink,
                    value: HealthCardFormat.heartText(bpm: snapshot.avgHR),
                    unit: snapshot.avgHR > 0 ? "次/分" : nil
                )
                HealthMetricCard(
                    icon: "waveform.path.ecg", title: "HRV", tint: .green,
                    value: HealthCardFormat.hrvText(ms: snapshot.hrvMS) ?? "—",
                    unit: snapshot.hrvMS != nil ? "ms" : nil,
                    footnote: snapshot.hrvMS != nil ? nil : "佳明未同步 HRV"
                )
            }

            Text("更新于 \(HealthCardFormat.clockText(snapshot.syncedAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
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
            Text("请先在「我的-健康数据」完成授权，并确认佳明 Connect 已开启同步到苹果健康")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                selectedTab = .settings
            } label: {
                Label("去设置", systemImage: "person.crop.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 80)
        .padding(.bottom, 32)
    }

    // MARK: - 同步

    /// 进入页面触发一次后台同步（未授权时 syncRecent 内部直接跳过，不弹授权）
    private func triggerSync() {
        Task { await syncNow() }
    }

    private func syncNow() async {
        await HealthKitService().syncRecent(days: 7, context: modelContext)
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
