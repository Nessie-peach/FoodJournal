import SwiftUI
import SwiftData

/// 饮食历史页：月份导航 + 月度汇总 + 按日折叠卡片（展开看各餐，再展开看菜品明细）。
/// 点击某餐 push 现有餐编辑页（编辑模式，可改可删）。按当月区间查询，不做全量加载。
struct DietHistoryView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var monthAnchor: Date = .now
    /// 当月经区间查询的餐记录（月份切换/返回页面时重取）
    @State private var monthMeals: [Meal] = []
    @State private var showDatePicker = false
    /// 展开的日（startOfDay）；默认展开最近一天
    @State private var expandedDay: Date?
    /// 展开菜品明细的餐
    @State private var expandedMealIDs: Set<UUID> = []

    private var calendar: Calendar { Calendar.current }

    private var range: (start: Date, end: Date) {
        HistoryGrouping.monthRange(for: monthAnchor, calendar: calendar)
    }

    private var dayGroups: [HistoryGrouping.DayMeals] {
        HistoryGrouping.groupMealsByDay(monthMeals, calendar: calendar)
    }

    private var summary: (recordedDays: Int, avgDailyKcal: Double) {
        HistoryGrouping.monthlyDietSummary(monthMeals, calendar: calendar)
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
        .navigationTitle("饮食历史")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDatePicker) {
            datePickerSheet
        }
        .onAppear { reload() }
        .onChange(of: monthAnchor) { _, _ in reload() }
    }

    // MARK: - 数据

    /// 按当月日期区间 fetch（复用仓库的 [start, end) 口径）
    private func reload() {
        let repository = MealRepository(context: modelContext)
        let lastMoment = range.end.addingTimeInterval(-1)
        monthMeals = (try? repository.fetch(from: range.start, to: lastMoment)) ?? []
        if expandedDay == nil, let latest = dayGroups.first?.date {
            expandedDay = latest
        }
    }

    // MARK: - 月份导航（与统计页同款：‹ 年/月 › + 日历 sheet，未来月份不可选）

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
            Text("本月 \(summary.recordedDays) 天有记录 · 日均 \(StatsAggregation.kcalText(summary.avgDailyKcal)) 千卡")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - 按日卡片

    private var daySections: some View {
        ForEach(dayGroups) { group in
            Section {
                dayHeader(group)
                if expandedDay == group.date {
                    mealRows(group)
                }
            }
        }
    }

    private func dayHeader(_ group: HistoryGrouping.DayMeals) -> some View {
        Button {
            expandedDay = expandedDay == group.date ? nil : group.date
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expandedDay == group.date ? "chevron.down" : "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(Self.dayText(group.date))
                    .font(.headline)
                Spacer()
                photoThumbnails(group)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(StatsAggregation.kcalText(group.totalCalories)) 千卡")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                    Text("\(group.mealCount) 餐")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Self.dayText(group.date))，共 \(group.mealCount) 餐，\(StatsAggregation.kcalText(group.totalCalories)) 千卡")
    }

    /// 头部照片缩略图（≤3，超出显示 +N）
    @ViewBuilder
    private func photoThumbnails(_ group: HistoryGrouping.DayMeals) -> some View {
        if !group.photoThumbnails.isEmpty {
            HStack(spacing: -6) {
                ForEach(group.photoThumbnails.indices, id: \.self) { index in
                    if let image = UIImage(data: group.photoThumbnails[index]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.background, lineWidth: 1)
                            )
                    }
                }
                if group.photoExtraCount > 0 {
                    Text("+\(group.photoExtraCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
        }
    }

    // MARK: - 各餐行 + 菜品明细

    private func mealRows(_ group: HistoryGrouping.DayMeals) -> some View {
        ForEach(group.meals) { meal in
            VStack(alignment: .leading, spacing: 0) {
                mealRow(meal)
                if expandedMealIDs.contains(meal.id) {
                    itemDetailRows(meal)
                }
            }
        }
    }

    /// 餐行：点行体 push 餐编辑页；尾部箭头展开/收起菜品明细
    private func mealRow(_ meal: Meal) -> some View {
        HStack(spacing: 8) {
            NavigationLink {
                MealEditView(meal: meal)
            } label: {
                HStack(spacing: 8) {
                    if let type = meal.type {
                        Label(type.displayName, systemImage: type.systemImageName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(meal.name.isEmpty ? "未命名一餐" : meal.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(StatsAggregation.kcalText(meal.totalCalories))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
            Button {
                if expandedMealIDs.contains(meal.id) {
                    expandedMealIDs.remove(meal.id)
                } else {
                    expandedMealIDs.insert(meal.id)
                }
            } label: {
                Image(systemName: expandedMealIDs.contains(meal.id) ? "chevron.down.circle" : "chevron.right.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(expandedMealIDs.contains(meal.id) ? "收起菜品明细" : "展开菜品明细")
        }
        .padding(.vertical, 6)
    }

    /// 菜品明细：名称/热量/蛋白/碳水/脂肪，source 为 official 时显示「官方」胶囊
    private func itemDetailRows(_ meal: Meal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(meal.items.sorted { $0.id.uuidString < $1.id.uuidString }) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("· \(item.name.isEmpty ? "未命名菜品" : item.name)")
                        .font(.caption)
                        .lineLimit(1)
                    if item.source == "official" {
                        Text("官方")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Text("\(StatsAggregation.kcalText(item.calories)) 千卡 P\(item.protein) C\(item.carbs) F\(item.fat)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if meal.items.isEmpty {
                Text("无菜品明细")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 24)
        .padding(.bottom, 8)
    }

    // MARK: - 空态

    private var emptySection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("本月没有饮食记录")
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

    // MARK: - 日期文案

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter
    }()

    static func dayText(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
