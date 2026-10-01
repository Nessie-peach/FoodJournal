import SwiftUI
import SwiftData
import Charts

/// 统计页：日/周/月三粒度联动，模块①摄入 vs 消耗 ②睡眠 ③运动
struct StatsView: View {
    @State private var granularity: StatsGranularity = .day
    @State private var anchorDate: Date = .now
    @State private var showDatePicker = false

    @Query(sort: \Meal.date) private var meals: [Meal]
    @Query(sort: \DailyHealthSnapshot.date) private var snapshots: [DailyHealthSnapshot]

    private var calendar: Calendar { Calendar.current }

    private var range: StatsAggregation.DayRange {
        StatsAggregation.dateRange(for: granularity, anchor: anchorDate, calendar: calendar)
    }

    /// 区间内餐记录：按业务日归属（凌晨 04:00 前算前一业务日）
    private var rangeMeals: [Meal] {
        let dayAnchors = Set(range.days)
        return meals.filter {
            dayAnchors.contains(LogicalDay.businessDay(of: $0.date, calendar: calendar))
        }
    }

    /// 区间内健康快照：快照按自然日聚合，按自然日锚点匹配
    private var rangeSnapshots: [DailyHealthSnapshot] {
        let dayAnchors = Set(range.days)
        return snapshots.filter { dayAnchors.contains(calendar.startOfDay(for: $0.date)) }
    }

    private var points: [StatsAggregation.DailyPoint] {
        StatsAggregation.dailyPoints(
            meals: rangeMeals, snapshots: rangeSnapshots, days: range.days, calendar: calendar
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    granularityPicker
                    navigationRow
                    IntakeBurnSection(granularity: granularity, points: points)
                    SleepSection(granularity: granularity, points: points)
                    WorkoutSection(granularity: granularity, range: range, snapshots: rangeSnapshots)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("统计")
            .sheet(isPresented: $showDatePicker) {
                datePickerSheet
            }
        }
    }

    // MARK: - 顶部控制区

    private var granularityPicker: some View {
        // 切换粒度只换区间口径，锚点日期保持不变
        Picker("时间粒度", selection: $granularity) {
            ForEach(StatsGranularity.allCases) { gran in
                Text(gran.rawValue).tag(gran)
            }
        }
        .pickerStyle(.segmented)
    }

    private var navigationRow: some View {
        HStack {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("上一\(granularity.rawValue)")

            Spacer()

            Button {
                showDatePicker = true
            } label: {
                Text(StatsAggregation.rangeDisplayText(for: granularity, anchor: anchorDate, calendar: calendar))
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .accessibilityLabel("选择日期")

            Spacer()

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!StatsAggregation.canStepForward(
                from: anchorDate, granularity: granularity, calendar: calendar
            ))
            .accessibilityLabel("下一\(granularity.rawValue)")
        }
        .padding(.vertical, 4)
    }

    private func step(_ delta: Int) {
        anchorDate = StatsAggregation.steppedDate(
            anchorDate, granularity: granularity, delta: delta, calendar: calendar
        )
    }

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker(
                "选择日期",
                selection: $anchorDate,
                in: ...Date.now,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("选择日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showDatePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 模块① 摄入 vs 消耗

private struct IntakeBurnSection: View {
    let granularity: StatsGranularity
    let points: [StatsAggregation.DailyPoint]

    private var intakeTotal: Double { StatsAggregation.totalIntake(points) }
    private var burnTotal: Double? { StatsAggregation.totalBurn(points) }
    private var burnMean: Double? { StatsAggregation.mean(of: points.map(\.burnKcal)) }
    private var balance: StatsAggregation.CalorieBalance? {
        .evaluate(intake: intakeTotal, burn: burnTotal)
    }

    var body: some View {
        statCard(title: "摄入 vs 消耗") {
            switch granularity {
            case .day:
                dayChart
            case .week, .month:
                seriesChart
            }
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let balance {
            HStack(spacing: 6) {
                Text(balanceLabel(balance))
                    .foregroundStyle(.secondary)
                Text(StatsAggregation.balanceText(balance))
                    .foregroundStyle(balanceColor(balance))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .font(.subheadline)
        } else {
            Text("消耗数据待同步")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func balanceLabel(_ balance: StatsAggregation.CalorieBalance) -> String {
        switch balance {
        case .deficit: return "缺口"
        case .surplus: return "盈余"
        case .even: return "收支"
        }
    }

    private func balanceColor(_ balance: StatsAggregation.CalorieBalance) -> Color {
        switch balance {
        case .deficit: return .green
        case .surplus: return .red
        case .even: return .secondary
        }
    }

    // MARK: 日视图：双柱

    private var dayChart: some View {
        Chart {
            BarMark(x: .value("类别", "摄入"), y: .value("千卡", intakeTotal))
                .foregroundStyle(intakeTotal > 0 ? Color.orange : Color.gray.opacity(0.35))
                .annotation(position: .top) {
                    if intakeTotal == 0 {
                        Text("无记录")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            if let burnTotal {
                BarMark(x: .value("类别", "消耗"), y: .value("千卡", burnTotal))
                    .foregroundStyle(Color.blue)
            }
        }
        .chartXAxis(.hidden)
        .frame(height: 180)
    }

    // MARK: 周/月视图：逐日双柱 + 消耗均值线

    private var seriesChart: some View {
        Chart {
            ForEach(points, id: \.day) { point in
                BarMark(x: .value("日期", point.day, unit: .day), y: .value("千卡", point.intakeKcal))
                    .foregroundStyle(by: .value("系列", "摄入"))
            }
            ForEach(points.compactMap { point in point.burnKcal.map { (point.day, $0) } }, id: \.0) { day, burn in
                BarMark(x: .value("日期", day, unit: .day), y: .value("千卡", burn))
                    .foregroundStyle(by: .value("系列", "消耗"))
            }
            if let burnMean {
                RuleMark(y: .value("消耗均值", burnMean))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("均值 \(StatsAggregation.kcalText(burnMean))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(["摄入": Color.orange, "消耗": Color.blue])
        .frame(height: 180)
    }
}

// MARK: - 模块② 睡眠

private struct SleepSection: View {
    let granularity: StatsGranularity
    let points: [StatsAggregation.DailyPoint]

    private var daySnapshotPoint: StatsAggregation.DailyPoint? {
        points.first
    }

    private var hasData: Bool {
        points.contains { ($0.sleepMinutes ?? 0) > 0 }
    }

    private var sleepMean: Double? {
        StatsAggregation.mean(of: points.map { point in
            (point.sleepMinutes ?? 0) > 0 ? point.sleepMinutes : nil
        })
    }

    var body: some View {
        statCard(title: "睡眠") {
            if !hasData {
                emptyText
            } else {
                switch granularity {
                case .day:
                    dayDetail
                case .week, .month:
                    seriesChart
                }
            }
        }
    }

    private var emptyText: some View {
        Text("暂无睡眠数据（需佳明同步或健康 App 数据）")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    // MARK: 日视图：时长 + 起止

    @ViewBuilder
    private var dayDetail: some View {
        if let point = daySnapshotPoint, let minutes = point.sleepMinutes {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(HealthCardFormat.sleepText(minutes: minutes))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    if let stages = StatsAggregation.sleepStageSummary(
                        deep: point.deepSleepMin, rem: point.remSleepMin, totalMinutes: minutes
                    ) {
                        Text(stages)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let start = point.sleepStart, let end = point.sleepEnd {
                    Text("\(HealthCardFormat.clockText(start)) 入睡 · \(HealthCardFormat.clockText(end)) 起床")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 周/月视图：逐日柱 + 均值线（无数据日空柱，x 轴连续）

    private var seriesChart: some View {
        Chart {
            ForEach(points, id: \.day) { point in
                BarMark(x: .value("日期", point.day, unit: .day), y: .value("分钟", point.sleepMinutes ?? 0))
                    .foregroundStyle(Color.indigo.opacity(0.85))
            }
            if let sleepMean {
                RuleMark(y: .value("平均时长", sleepMean))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("均值 \(HealthCardFormat.sleepText(minutes: sleepMean))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(height: 180)
    }
}

// MARK: - 模块③ 运动

private struct WorkoutSection: View {
    let granularity: StatsGranularity
    let range: StatsAggregation.DayRange
    let snapshots: [DailyHealthSnapshot]

    var body: some View {
        statCard(title: "运动") {
            switch granularity {
            case .day:
                dayList
            case .week, .month:
                aggregatedList
            }
        }
    }

    // MARK: 日视图：记录列表

    private var dayWorkouts: [WorkoutRecord] {
        StatsAggregation.workouts(in: snapshots, days: range.days)
    }

    @ViewBuilder
    private var dayList: some View {
        let workouts = dayWorkouts
        if workouts.isEmpty {
            Text("当天没有运动记录")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 8) {
                ForEach(workouts, id: \.uuid) { workout in
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
                }
            }
        }
    }

    // MARK: 周/月视图：按类型聚合

    @ViewBuilder
    private var aggregatedList: some View {
        let summaries = StatsAggregation.aggregateWorkouts(snapshots: snapshots, days: range.days)
        if summaries.isEmpty {
            Text("没有运动记录")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 8) {
                ForEach(summaries) { summary in
                    HStack {
                        Text(summary.displayName)
                            .font(.subheadline.weight(.medium))
                        Text("\(summary.count) 次")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(HealthCardFormat.sleepText(minutes: summary.totalMinutes))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text("\(StatsAggregation.kcalText(summary.totalKcal)) 千卡")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - 通用卡片容器

/// 统计页模块卡片：标题 + 内容，风格与首页卡片统一
private func statCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
}

#Preview {
    StatsView()
        .modelContainer(for: [Meal.self, FoodItem.self, WeightRecord.self, DailyJournal.self, DailyAdvice.self, DailyHealthSnapshot.self], inMemory: true)
}
