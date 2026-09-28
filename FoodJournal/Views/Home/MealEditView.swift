import SwiftUI
import SwiftData
import UIKit

/// 手动记录/编辑一餐。新增模式：餐段按当前时间推断、时间为当前时间。
/// 编辑模式：载入已有 Meal，保存时更新。
/// 识别模式：拍照识图结果预填（餐名/菜品/照片），可自动聚焦餐名输入框。
struct MealEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// 编辑模式的已有 Meal（nil 表示新增）
    private let editingMeal: Meal?

    /// 进入页面后是否自动聚焦餐名输入框（识别模式使用，避开导航动画 0.3s 后激活）
    private let focusNameOnAppear: Bool

    /// 待保存的照片数据（编辑模式下仅在非 nil 时覆盖）
    @State private var photoData: Data?
    /// 其余照片（首图之后），保存时写入 Meal.additionalPhotos
    @State private var additionalPhotos: [Data] = []
    @FocusState private var nameFieldFocused: Bool

    @State private var name: String = ""
    @State private var mealType: MealType = .lunch
    @State private var date: Date = .now
    @State private var itemDrafts: [ItemDraft] = []
    @State private var showAISheet = false

    /// 菜品行草稿：文本输入便于实时编辑，保存时解析
    struct ItemDraft: Identifiable, Hashable {
        let id: UUID
        var name: String
        var caloriesText: String
        var proteinText: String
        var carbsText: String
        var fatText: String
        /// 识别来源：official 时行内显示「官方」标记；手动新增为 nil
        var source: String?
        /// 用户是否手动改过营养数值（改过则不再显示「官方」标记）
        var nutrientsEdited: Bool

        init(
            name: String = "",
            calories: Double = 0,
            protein: Double = 0,
            carbs: Double = 0,
            fat: Double = 0,
            source: String? = nil
        ) {
            self.id = UUID()
            self.name = name
            self.caloriesText = NumberFormatting.inputText(calories)
            self.proteinText = NumberFormatting.inputText(protein)
            self.carbsText = NumberFormatting.inputText(carbs)
            self.fatText = NumberFormatting.inputText(fat)
            self.source = source
            self.nutrientsEdited = false
        }

        /// 由识图结果草稿构造（营养数值转输入框文本）
        init(draft: FoodItemDraft) {
            self.init(name: draft.name, calories: draft.calories, protein: draft.protein, carbs: draft.carbs, fat: draft.fat, source: draft.source)
        }
    }

    /// 识别模式预填数据
    struct Prefill: Hashable {
        var name: String = ""
        var items: [ItemDraft] = []
        var photoData: Data?
        var additionalPhotos: [Data] = []
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
        focusNameOnAppear = false
        let now = Date.now
        _mealType = State(initialValue: MealType.from(date: now))
        _date = State(initialValue: now)
        _itemDrafts = State(initialValue: [ItemDraft()])
    }

    init(meal: Meal) {
        editingMeal = meal
        focusNameOnAppear = false
        _name = State(initialValue: meal.name)
        _mealType = State(initialValue: meal.type ?? .lunch)
        _date = State(initialValue: meal.date)
        _photoData = State(initialValue: meal.photoData)
        _additionalPhotos = State(initialValue: meal.additionalPhotos)
        _itemDrafts = State(initialValue: meal.items
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { ItemDraft(name: $0.name, calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat, source: $0.source) })
        if itemDrafts.isEmpty { _itemDrafts = State(initialValue: [ItemDraft()]) }
    }

    /// 识别模式：识图结果预填，餐段/时间按当前时间推断
    init(prefill: Prefill, focusNameOnAppear: Bool) {
        editingMeal = nil
        self.focusNameOnAppear = focusNameOnAppear
        let now = Date.now
        _mealType = State(initialValue: MealType.from(date: now))
        _date = State(initialValue: now)
        _name = State(initialValue: prefill.name)
        _photoData = State(initialValue: prefill.photoData)
        _additionalPhotos = State(initialValue: prefill.additionalPhotos)
        _itemDrafts = State(initialValue: prefill.items.isEmpty ? [ItemDraft()] : prefill.items)
    }

    // MARK: - Body

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("餐名（如：麦当劳巨无霸套餐）", text: $name)
                    .focused($nameFieldFocused)

                Picker("餐段", selection: $mealType) {
                    ForEach(MealType.allCases) { type in
                        Label(type.displayName, systemImage: type.systemImageName)
                            .tag(type)
                    }
                }
                .pickerStyle(.menu)

                DatePicker("时间", selection: $date)
            }

            if photoData != nil || !additionalPhotos.isEmpty {
                Section("照片（\(allPhotos.count)）") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(allPhotos.indices, id: \.self) { index in
                                if let image = UIImage(data: allPhotos[index]) {
                                    VStack(spacing: 4) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 120, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(index == 0 ? "封面" : "第 \(index + 1) 张")
                                            .font(.caption2)
                                            .foregroundStyle(index == 0 ? .orange : .secondary)
                                    }
                                    .accessibilityLabel(index == 0 ? "餐食封面照片" : "餐食照片\(index + 1)")
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
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
        .sheet(isPresented: $showAISheet) {
            MealAISheet(
                currentName: name,
                currentItemDrafts: itemDrafts,
                onApply: { result in applyAIResult(result) }
            )
        }
        .task {
            // 识别模式：延迟 0.3s 激活焦点，避免与 push 导航动画抢焦点
            if focusNameOnAppear {
                try? await Task.sleep(for: .seconds(0.3))
                nameFieldFocused = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showAISheet = true
                } label: {
                    Label("AI 修改", systemImage: "wand.and.stars")
                }
                .accessibilityLabel("用 AI 指令修改本餐记录")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
            }
        }
    }

    /// 把 AI 修改结果写回编辑页字段（餐名 + 菜品明细整体替换），不自动保存
    private func applyAIResult(_ result: MealRecognitionResult) {
        if !result.mealName.trimmingCharacters(in: .whitespaces).isEmpty {
            name = result.mealName
        }
        var drafts = result.items.map { ItemDraft(draft: $0) }
        if drafts.isEmpty { drafts = [ItemDraft()] }
        itemDrafts = drafts
    }

    // MARK: - 照片

    /// 全部照片（首图在前）
    private var allPhotos: [Data] {
        (photoData.map { [$0] } ?? []) + additionalPhotos
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
                fat: NumberParsing.parseOrZero(draft.fatText),
                source: draft.source
            )
        }

        if let meal = editingMeal {
            meal.name = trimmedName
            meal.mealType = mealType.rawValue
            meal.date = date
            if let data = photoData { meal.photoData = data }
            meal.additionalPhotos = additionalPhotos
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
                photoData: photoData,
                additionalPhotos: additionalPhotos,
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

    /// 识别来源为官方且用户未手动改过数值时显示「官方」标记
    private var showOfficialBadge: Bool {
        draft.source == "official" && !draft.nutrientsEdited
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("菜品名称", text: $draft.name)
                    .font(.body.weight(.medium))
                if showOfficialBadge {
                    Text("官方")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.12)))
                        .accessibilityLabel("数据来源为品牌官方或包装营养表")
                }
            }

            HStack(spacing: 8) {
                nutrientField("热量", text: $draft.caloriesText, unit: "千卡", width: 74)
                nutrientField("蛋白", text: $draft.proteinText, unit: "g", width: 52)
                nutrientField("碳水", text: $draft.carbsText, unit: "g", width: 52)
                nutrientField("脂肪", text: $draft.fatText, unit: "g", width: 52)
            }
        }
        .padding(.vertical, 2)
        // 手动改过任一营养数值即视为估算，不再显示「官方」标记
        .onChange(of: draft.caloriesText) { _, _ in draft.nutrientsEdited = true }
        .onChange(of: draft.proteinText) { _, _ in draft.nutrientsEdited = true }
        .onChange(of: draft.carbsText) { _, _ in draft.nutrientsEdited = true }
        .onChange(of: draft.fatText) { _, _ in draft.nutrientsEdited = true }
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

// MARK: - AI 修改弹层（R5-2）

/// 「AI 修改」弹层：当前餐摘要 + 自然语言指令输入 + 逐轮变更摘要，支持多轮，应用时整体写回。
private struct MealAISheet: View {
    let currentName: String
    let currentItemDrafts: [MealEditView.ItemDraft]
    /// 应用：把最新结果写回编辑页（不自动保存）
    let onApply: (MealRecognitionResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(LLMProviderConfig.adviceStorageKey) private var adviceConfigJSON: String = ""

    /// 一轮 AI 修改记录
    struct Round: Identifiable {
        let id = UUID()
        let instruction: String
        let changes: [MealItemChange]
        let mealNameChanged: Bool
        let result: MealRecognitionResult
        let resultJSON: String
    }

    @State private var rounds: [Round] = []
    @State private var inputText = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool
    @State private var generateTask: Task<Void, Never>?

    private var adviceConfig: LLMProviderConfig {
        LLMProviderConfig(json: adviceConfigJSON) ?? .default
    }

    /// 建议模型是否可用（端点 + 模型 + Key 均已配置）
    private var isConfigured: Bool {
        adviceConfig.isEndpointConfigured
            && adviceConfig.isModelConfigured
            && KeychainStore.advice.hasStoredKey
    }

    /// 编辑页当前状态快照（首轮的修改基准）
    private var snapshot: MealRecognitionResult {
        MealRecognitionResult(
            mealName: currentName,
            items: currentItemDrafts.map { draft in
                FoodItemDraft(
                    name: draft.name,
                    calories: NumberParsing.parseOrZero(draft.caloriesText),
                    protein: NumberParsing.parseOrZero(draft.proteinText),
                    carbs: NumberParsing.parseOrZero(draft.carbsText),
                    fat: NumberParsing.parseOrZero(draft.fatText),
                    source: draft.source
                )
            }
        )
    }

    /// 最新结果（未生成过时为编辑页快照）
    private var latestResult: MealRecognitionResult {
        rounds.last?.result ?? snapshot
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isConfigured {
                    unconfiguredView
                } else {
                    content
                }
            }
            .navigationTitle("AI 修改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onDisappear {
            generateTask?.cancel()
        }
    }

    // MARK: 未配置建议模型

    private var unconfiguredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("尚未配置建议模型")
                .font(.headline)
            Text("请先在「我的」页配置建议模型的 BaseURL、模型 ID 与 API Key")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("前往「我的」配置") {
                showSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: 主内容

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summarySection
                    ForEach(rounds) { round in
                        roundSection(round)
                    }
                    if isGenerating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("AI 正在修改…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("取消") {
                                generateTask?.cancel()
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    }
                    if let errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                            Button("重试") { send() }
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
            }

            Divider()
            inputBar
        }
        .safeAreaInset(edge: .bottom) {
            if !rounds.isEmpty && !isGenerating {
                applyBar
            }
        }
    }

    /// 当前餐摘要：餐名 + 菜品名列表
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前餐")
                .font(.caption)
                .foregroundStyle(.secondary)
            let result = latestResult
            Text(result.mealName.isEmpty ? "未命名一餐" : result.mealName)
                .font(.headline)
            if result.items.isEmpty {
                Text("（无菜品）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(result.items.map(\.name).joined(separator: "、"))
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .combine)
    }

    /// 单轮结果：指令 + 变更摘要
    private func roundSection(_ round: Round) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(round.instruction, systemImage: "text.bubble")
                .font(.subheadline.weight(.medium))
            if round.changes.isEmpty && !round.mealNameChanged {
                Text("AI 认为无需修改")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                if round.mealNameChanged {
                    Text("餐名：\(currentName) → \(round.result.mealName)")
                        .font(.subheadline)
                }
                ForEach(Array(round.changes.enumerated()), id: \.offset) { _, change in
                    Text(change.summaryText)
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemBackground)))
    }

    /// 输入框 + 发送
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("如：这一整杯都是我喝的 / 米饭只吃了一半", text: $inputText, axis: .vertical)
                .lineLimit(1...3)
                .focused($inputFocused)
                .onSubmit { send() }
                .submitLabel(.send)
                .disabled(isGenerating)
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(isGenerating || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    /// 底部应用/取消栏
    private var applyBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                onApply(latestResult)
                dismiss()
            } label: {
                Text("应用")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: 发起修改

    private func send() {
        let instruction = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isGenerating else { return }

        let currentJSON = AIEditService.encodeJSON(latestResult)
        let history = rounds.map { (instruction: $0.instruction, resultJSON: $0.resultJSON) }
        let config = adviceConfig
        let apiKey = KeychainStore.advice.load() ?? ""
        let previousResult = latestResult

        inputText = ""
        errorMessage = nil
        isGenerating = true

        generateTask = Task {
            do {
                let result = try await AIEditService().reviseMeal(
                    currentJSON: currentJSON,
                    instruction: instruction,
                    history: history,
                    config: config,
                    apiKey: apiKey
                )
                let resultJSON = AIEditService.encodeJSON(result)
                let changes = MealDraftDiff.diffMealDrafts(old: previousResult.items, new: result.items)
                let mealNameChanged = previousResult.mealName != result.mealName
                guard !Task.isCancelled else { return }
                rounds.append(Round(
                    instruction: instruction,
                    changes: changes,
                    mealNameChanged: mealNameChanged,
                    result: result,
                    resultJSON: resultJSON
                ))
            } catch is CancellationError {
                // 用户取消，静默恢复输入
                inputText = instruction
            } catch {
                inputText = instruction
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }
}

#Preview {
    NavigationStack { MealEditView() }
        .modelContainer(for: [Meal.self, FoodItem.self, WeightRecord.self, DailyJournal.self, DailyAdvice.self, DailyHealthSnapshot.self], inMemory: true)
}
