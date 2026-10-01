import SwiftUI
import SwiftData

/// 锻炼历史页：月份导航 + 月度汇总 + 按日只读卡片。
/// 当日数据来自健康快照（活动消耗/心率/睡眠）与 workoutsJSON 解析出的运动记录（类型中文名+时长+热量）。
/// 数据来自 HealthKit/Garmin 同步，不可编辑。
struct ExerciseHistoryView: View {
    @Query(sort: \DailyHealthSnapshot.date, order: .reverse) private var allSnapshots: [DailyHealthSnapshot]

    @State private var monthAnchor: Date = .now
    @State private var showDatePicker = false
    @State private var expandedDay: Date?

    private var calendar: Calendar { Calendar.current }

    private var range: (start: Date, end: Date) {
        HistoryGrouping.monthRange(for: monthAnchor, calendar: calendar)
    }

    private var monthSnapshots: [DailyHealthSnapshot] {
        allSnapshots.filter { $0.date >= range.start && $0.date < range.end }
    }

    private var dayGroups: [HistoryGrouping.DayExercise] {
        HistoryGrouping.groupWorkoutsByDay(snapshots: monthSnapshots, calendar: calendar)
    }

    private var summary: (activeDays: Int, totalMinutes: Int) {
        HistoryGrouping.monthlyExerciseSummary(snapshots: monthSnapshots)
    }

    private var canStepForward: Bool {
        StatsAggregation.canStepForward(from: monthAnchor, granularity: .month, calendar: calendar)
    }

    var body: some View {
        List {
            Section {
                navigationRow
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            if dayGroups.isEmpty {
                emptySection
            } else {
                summarySection
                daySections
            }
        }
        .navigationTitle("锻炼历史")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDatePicker) {
            datePickerSheet
        }
        .onAppear {
            if expandedDay == nil {
                expandedDay = dayGroups.first?.date
            }
        }
    }

    // MARK: - 月份导航（与统计页同款）

    private var navigationRow: some View {
        HStack {
            Button {
                monthAnchor = StatsAggregation.steppedDate(
                    monthAnchor, granularity: .month, delta: -1, calendar: calendar
                )
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("上一月")

            Spacer()

            Button {
                showDatePicker = true
            } label: {
                Text(StatsAggregation.rangeDisplayText(for: .month, anchor: monthAnchor, calendar: calendar))
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .accessibilityLabel("选择月份")

            Spacer()

            Button {
                monthAnchor = StatsAggregation.steppedDate(
                    monthAnchor, granularity: .month, delta: 1, calendar: calendar
                )
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!canStepForward)
            .accessibilityLabel("下一月")
        }
    }

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker(
                "选择月份",
                selection: $monthAnchor,
                in: ...Date.now,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("选择月份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showDatePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 月度汇总条

    private var summarySection: some View {
        Section {
            Text("本月 \(summary.activeDays) 天有运动 · 共 \(summary.totalMinutes) 分钟")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - 按日卡片（只读）

    private var daySections: some View {
        ForEach(dayGroups) { group in
            Section {
                dayHeader(group)
                if expandedDay == group.date {
                    dayDetail(group)
                    workoutRows(group)
                }
            }
        }
    }

    private func dayHeader(_ group: HistoryGrouping.DayExercise) -> some View {
        Button {
            expandedDay = expandedDay == group.date ? nil : group.date
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expandedDay == group.date ? "chevron.down" : "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(DietHistoryView.dayText(group.date))
                    .font(.headline)
                Spacer()
                Text("\(group.workouts.count) 条运动 · \(Int(group.totalMinutes.rounded())) 分钟")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(DietHistoryView.dayText(group.date))，\(group.workouts.count) 条运动，共 \(Int(group.totalMinutes.rounded())) 分钟")
    }

    /// 当日快照数据：活动消耗 / 平均心率 / 睡眠（含深睡占比），有则显示
    @ViewBuilder
    private func dayDetail(_ group: HistoryGrouping.DayExercise) -> some View {
        let snapshot = group.snapshot
        VStack(alignment: .leading, spacing: 4) {
            if snapshot.activeKcal > 0 || snapshot.avgHR > 0 {
                Text(snapshotMetricText(snapshot))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let sleepText = sleepText(snapshot) {
                Text(sleepText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func snapshotMetricText(_ snapshot: DailyHealthSnapshot) -> String {
        var parts: [String] = []
        if snapshot.activeKcal > 0 {
            parts.append("活动消耗 \(StatsAggregation.kcalText(snapshot.activeKcal)) 千卡")
        }
        if snapshot.avgHR > 0 {
            parts.append("平均心率 \(HealthCardFormat.heartText(bpm: snapshot.avgHR)) 次/分")
        }
        return parts.joined(separator: " · ")
    }

    /// 「睡眠 3 小时 34 分（深睡 46%）」；无睡眠数据返回 nil
    private func sleepText(_ snapshot: DailyHealthSnapshot) -> String? {
        guard snapshot.sleepMinutes > 0 else { return nil }
        var text = "睡眠 \(HealthCardFormat.sleepText(minutes: snapshot.sleepMinutes))"
        if let deepPct = HistoryGrouping.deepSleepPercent(snapshot) {
            text += "（深睡 \(deepPct)%）"
        }
        return text
    }

    /// 运动记录列表：类型中文名 + 时长 + 热量（与统计页运动列表同款样式）
    private func workoutRows(_ group: HistoryGrouping.DayExercise) -> some View {
        ForEach(group.workouts, id: \.uuid) { workout in
            HStack {
                Text(StatsAggregation.workoutDisplayName(workout.activityType))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(HealthCardFormat.sleepText(minutes: workout.durationMinutes))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(workout.energyKcal.map { "\(StatsAggregation.kcalText($0)) 千卡" } ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .frame(minWidth: 72, alignment: .trailing)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 空态

    private var emptySection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "figure.run")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("本月没有运动记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("可以 ‹ 翻到之前的月份看看")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .listRowBackground(Color.clear)
        }
    }
}
