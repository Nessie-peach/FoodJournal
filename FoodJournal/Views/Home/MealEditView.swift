import SwiftUI
import SwiftData

/// 手动记录/编辑一餐。新增模式：餐段按当前时间推断、时间为当前时间。
/// 编辑模式：载入已有 Meal，保存时更新。
struct MealEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// 编辑模式的已有 Meal（nil 表示新增）
    private let editingMeal: Meal?

    @State private var name: String = ""
    @State private var mealType: MealType = .lunch
    @State private var date: Date = .now
    @State private var itemDrafts: [ItemDraft] = []

    /// 菜品行草稿：文本输入便于实时编辑，保存时解析
    struct ItemDraft: Identifiable {
        let id: UUID
        var name: String
        var caloriesText: String
        var proteinText: String
        var carbsText: String
        var fatText: String

        init(name: String = "", calories: Double = 0, protein: Double = 0, carbs: Double = 0, fat: Double = 0) {
            self.id = UUID()
            self.name = name
            self.caloriesText = NumberFormatting.inputText(calories)
            self.proteinText = NumberFormatting.inputText(protein)
            self.carbsText = NumberFormatting.inputText(carbs)
            self.fatText = NumberFormatting.inputText(fat)
        }
    }

    // MARK: - 实时合计

    private var totalCalories: Double {
        itemDrafts.reduce(0) { $0 + NumberParsing.parseOrZero($1.caloriesText) }
    }
    private var totalProtein: Double {
        itemDrafts.reduce(0) { $0 + NumberParsing.parseOrZero($1.proteinText) }
    }
    private var totalCarbs: Double {
        itemDrafts.reduce(0) { $0 + NumberParsing.parseOrZero($1.carbsText) }
    }
    private var totalFat: Double {
        itemDrafts.reduce(0) { $0 + NumberParsing.parseOrZero($1.fatText) }
    }

    private var hasValidItem: Bool {
        itemDrafts.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Init

    init() {
        editingMeal = nil
        let now = Date.now
        _mealType = State(initialValue: MealType.from(date: now))
        _date = State(initialValue: now)
        _itemDrafts = State(initialValue: [ItemDraft()])
    }

    init(meal: Meal) {
        editingMeal = meal
        _name = State(initialValue: meal.name)
        _mealType = State(initialValue: meal.type ?? .lunch)
        _date = State(initialValue: meal.date)
        _itemDrafts = State(initialValue: meal.items
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { ItemDraft(name: $0.name, calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat) })
        if itemDrafts.isEmpty { _itemDrafts = State(initialValue: [ItemDraft()]) }
    }

    // MARK: - Body

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("餐名（如：麦当劳巨无霸套餐）", text: $name)

                Picker("餐段", selection: $mealType) {
                    ForEach(MealType.allCases) { type in
                        Label(type.displayName, systemImage: type.systemImageName)
                            .tag(type)
                    }
                }
                .pickerStyle(.menu)

                DatePicker("时间", selection: $date)
            }

            Section {
                ForEach($itemDrafts) { $draft in
                    ItemRow(draft: $draft)
                }
                .onDelete(perform: deleteItems)

                Button {
                    itemDrafts.append(ItemDraft())
                } label: {
                    Label("添加菜品", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("菜品明细")
            } footer: {
                if !hasValidItem {
                    Text("至少填写一行菜品名称，否则将不会保存菜品")
                }
            }

            Section {
                TotalsRow(
                    calories: totalCalories, protein: totalProtein,
                    carbs: totalCarbs, fat: totalFat
                )
            }
        }
        .navigationTitle(editingMeal == nil ? "记一餐" : "编辑一餐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
            }
        }
    }

    // MARK: - Actions

    private func deleteItems(at offsets: IndexSet) {
        itemDrafts.remove(atOffsets: offsets)
        if itemDrafts.isEmpty {
            itemDrafts.append(ItemDraft())
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let repository = MealRepository(context: modelContext)

        // 剔除名称为空的行
        let validItems = itemDrafts.compactMap { draft -> FoodItem? in
            let itemName = draft.name.trimmingCharacters(in: .whitespaces)
            guard !itemName.isEmpty else { return nil }
            return FoodItem(
                name: itemName,
                calories: NumberParsing.parseOrZero(draft.caloriesText),
                protein: NumberParsing.parseOrZero(draft.proteinText),
                carbs: NumberParsing.parseOrZero(draft.carbsText),
                fat: NumberParsing.parseOrZero(draft.fatText)
            )
        }

        if let meal = editingMeal {
            meal.name = trimmedName
            meal.mealType = mealType.rawValue
            meal.date = date
            // 简单起见：全量替换菜品
            for old in meal.items { modelContext.delete(old) }
            for item in validItems { item.meal = meal }
            meal.items = validItems
            try? repository.update(meal)
        } else {
            let meal = Meal(
                date: date,
                mealType: mealType,
                name: trimmedName.isEmpty ? "未命名一餐" : trimmedName,
                items: validItems
            )
            try? repository.insert(meal)
        }

        dismiss()
    }
}

// MARK: - 菜品行

private struct ItemRow: View {
    @Binding var draft: MealEditView.ItemDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("菜品名称", text: $draft.name)
                .font(.body.weight(.medium))

            HStack(spacing: 8) {
                nutrientField("热量", text: $draft.caloriesText, unit: "千卡", width: 74)
                nutrientField("蛋白", text: $draft.proteinText, unit: "g", width: 52)
                nutrientField("碳水", text: $draft.carbsText, unit: "g", width: 52)
                nutrientField("脂肪", text: $draft.fatText, unit: "g", width: 52)
            }
        }
        .padding(.vertical, 2)
    }

    private func nutrientField(_ label: String, text: Binding<String>, unit: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label)(\(unit))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.leading)
                .frame(width: width)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
        }
    }
}

// MARK: - 合计栏

private struct TotalsRow: View {
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double

    var body: some View {
        HStack {
            Text("合计")
                .font(.subheadline.weight(.semibold))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(calories))")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                    Text("千卡")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("蛋白 \(String(format: "%.1f", protein))g · 碳水 \(String(format: "%.1f", carbs))g · 脂肪 \(String(format: "%.1f", fat))g")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

#Preview {
    NavigationStack { MealEditView() }
        .modelContainer(for: [Meal.self, FoodItem.self, WeightRecord.self, DailyJournal.self, DailyAdvice.self, DailyHealthSnapshot.self], inMemory: true)
}
