import SwiftUI
import SwiftData

/// 首页：今日饮食记录列表 + 汇总
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var todayMeals: [Meal]

    @State private var showCameraAlert = false

    init() {
        // 今日范围（含边界当天全天）
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        _todayMeals = Query(
            filter: #Predicate<Meal> { meal in
                meal.date >= start && meal.date < end
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SummaryBar(meals: todayMeals)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(todayMeals) { meal in
                        NavigationLink(value: meal.id) {
                            MealRow(meal: meal)
                        }
                    }
                    .onDelete(perform: deleteMeals)
                } header: {
                    Text("今日记录（\(todayMeals.count)）")
                } footer: {
                    if todayMeals.isEmpty {
                        Text("还没有记录，点右上角 + 记一餐吧")
                    }
                }
            }
            .navigationTitle("今天吃什么")
            .navigationDestination(for: UUID.self) { id in
                if let meal = todayMeals.first(where: { $0.id == id }) {
                    MealEditView(meal: meal)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCameraAlert = true
                    } label: {
                        Image(systemName: "camera.fill")
                    }
                    .accessibilityLabel("拍照识别")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        MealEditView()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增一餐")
                }
            }
            .alert("提示", isPresented: $showCameraAlert) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("拍照识别将在下一版本提供")
            }
        }
    }

    private func deleteMeals(at offsets: IndexSet) {
        let repository = MealRepository(context: modelContext)
        let mealsToDelete = offsets.map { todayMeals[$0] }
        for meal in mealsToDelete {
            try? repository.delete(meal)
        }
    }
}

// MARK: - 今日汇总

private struct SummaryBar: View {
    let meals: [Meal]

    private var totalCalories: Double { meals.reduce(0) { $0 + $1.totalCalories } }
    private var totalProtein: Double { meals.reduce(0) { $0 + $1.totalProtein } }
    private var totalCarbs: Double { meals.reduce(0) { $0 + $1.totalCarbs } }
    private var totalFat: Double { meals.reduce(0) { $0 + $1.totalFat } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日汇总")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                summaryItem(value: "\(Int(totalCalories))", unit: "千卡", label: "总热量")
                summaryItem(value: String(format: "%.1f", totalProtein), unit: "g", label: "蛋白")
                summaryItem(value: String(format: "%.1f", totalCarbs), unit: "g", label: "碳水")
                summaryItem(value: String(format: "%.1f", totalFat), unit: "g", label: "脂肪")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func summaryItem(value: String, unit: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 餐次行

private struct MealRow: View {
    let meal: Meal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(meal.name.isEmpty ? "未命名一餐" : meal.name)
                    .font(.body.weight(.medium))
                Spacer()
                Text("\(Int(meal.totalCalories)) 千卡")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if let type = meal.type {
                    Label(type.displayName, systemImage: type.systemImageName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(meal.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(meal.items.count) 个菜品")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    HomeView()
        .modelContainer(for: [Meal.self, FoodItem.self, WeightRecord.self, DailyJournal.self, DailyAdvice.self, DailyHealthSnapshot.self], inMemory: true)
}
