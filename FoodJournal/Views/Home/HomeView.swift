import SwiftUI
import SwiftData
import PhotosUI

/// 今日页：管住嘴（饮食记录）/ 迈开腿（健康数据占位）
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var todayMeals: [Meal]
    @Query private var weightRecords: [WeightRecord]

    // MARK: - 今日页模式

    private enum TodayMode: Hashable {
        case diet
        case exercise
    }

    @State private var selectedMode: TodayMode = .diet

    // MARK: - 识图流程状态

    @AppStorage(LLMProviderConfig.visionStorageKey) private var visionConfigJSON: String = LLMProviderConfig.default.asJSON

    @State private var showSourceDialog = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?

    /// 已压缩、待识别/待保存的照片 JPEG Data
    @State private var pendingImageData: Data?
    @State private var isRecognizing = false
    @State private var recognitionTask: Task<Void, Never>?

    @State private var showConfigAlert = false
    @State private var showFailureAlert = false
    @State private var failureMessage = ""
    @State private var showImageLoadError = false

    @State private var showSettings = false
    @State private var editRoute: EditRoute?

    /// 跳转 MealEditView 的路由参数（Hashable 以配合 navigationDestination(item:)）
    struct EditRoute: Hashable {
        var prefill: MealEditView.Prefill
        var focusName: Bool
    }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

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
            VStack(spacing: 0) {
                Picker("今日模式", selection: $selectedMode) {
                    Text("管住嘴").tag(TodayMode.diet)
                    Text("迈开腿").tag(TodayMode.exercise)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch selectedMode {
                case .diet:
                    dietList
                case .exercise:
                    exercisePlaceholder
                }
            }
            .navigationTitle("今天吃什么")
            .navigationDestination(for: UUID.self) { id in
                if let meal = todayMeals.first(where: { $0.id == id }) {
                    MealEditView(meal: meal)
                }
            }
            .navigationDestination(item: $editRoute) { route in
                MealEditView(prefill: route.prefill, focusNameOnAppear: route.focusName)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSourceDialog = true
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
            .confirmationDialog("拍照识别", isPresented: $showSourceDialog, titleVisibility: .visible) {
                Button("拍照") { showCamera = true }
                    .disabled(!cameraAvailable)
                Button("从相册选择") { showPhotoPicker = true }
                Button("取消", role: .cancel) {}
            } message: {
                if !cameraAvailable {
                    Text("当前设备没有可用相机（模拟器），请从相册选择")
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    handlePickedImage(image)
                }
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
            .onChange(of: photoPickerItem) { _, newItem in
                loadPickedPhoto(newItem)
            }
            .overlay {
                if isRecognizing {
                    recognizingOverlay
                }
            }
            .alert("尚未完成配置", isPresented: $showConfigAlert) {
                Button("前往设置") { showSettings = true }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请先在设置页填写识图模型的 BaseURL、模型 ID 和 API Key")
            }
            .alert("识别失败", isPresented: $showFailureAlert) {
                Button("重试") { retryRecognition() }
                Button("手动记录") { routeToManualEdit() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(failureMessage)
            }
            .alert("无法读取图片", isPresented: $showImageLoadError) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("所选图片无法读取或处理，请换一张试试")
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    // MARK: - 管住嘴：今日饮食列表

    private var dietList: some View {
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

            Section {
                NavigationLink {
                    WeightView()
                } label: {
                    WeightCard(summary: WeightCardSummary(records: weightRecords))
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    // MARK: - 迈开腿：健康数据占位

    private var exercisePlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.run")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("健康数据（消耗/睡眠/心率/HRV）将在下一阶段接入佳明后展示")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 识别中遮罩

    private var recognizingOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("正在识别…")
                    .font(.headline)
                Button("取消") { cancelRecognition() }
                    .buttonStyle(.bordered)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 图片入口

    /// 相册选图：异步载入 Data → UIImage 后进入统一识别流程
    private func loadPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                handlePickedImage(image)
            } else {
                showImageLoadError = true
            }
        }
        photoPickerItem = nil
    }

    /// 拍照/相册共用入口：压缩 → 配置检查 → 发起识别
    private func handlePickedImage(_ image: UIImage) {
        guard let data = ImageCompression.compress(image) else {
            showImageLoadError = true
            return
        }
        pendingImageData = data

        let config = LLMProviderConfig(json: visionConfigJSON) ?? .default
        let apiKey = KeychainStore.vision.load()
        guard RecognitionFlowLogic.isConfigComplete(config: config, apiKey: apiKey) else {
            showConfigAlert = true
            return
        }
        startRecognition(config: config, apiKey: apiKey ?? "")
    }

    // MARK: - 识别流程

    private func startRecognition(config: LLMProviderConfig, apiKey: String) {
        guard let data = pendingImageData, !isRecognizing else { return }
        isRecognizing = true
        recognitionTask = Task {
            do {
                let result = try await VisionService().recognizeFood(
                    imageData: data, config: config, apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                // 识别成功：立即跳编辑页（识别模式），焦点落餐名
                editRoute = EditRoute(
                    prefill: MealEditView.Prefill(
                        name: result.mealName,
                        items: result.items.map { MealEditView.ItemDraft(draft: $0) },
                        photoData: data
                    ),
                    focusName: true
                )
            } catch is CancellationError {
                // 用户取消，静默
            } catch let error as URLError where error.code == .cancelled {
                // 用户取消，静默
            } catch {
                failureMessage = (error as? LocalizedError)?.errorDescription ?? "识别失败，请重试"
                showFailureAlert = true
            }
            isRecognizing = false
        }
    }

    private func cancelRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecognizing = false
    }

    private func retryRecognition() {
        let config = LLMProviderConfig(json: visionConfigJSON) ?? .default
        let apiKey = KeychainStore.vision.load() ?? ""
        startRecognition(config: config, apiKey: apiKey)
    }

    /// 识别失败后改手动记录：仅保留照片预填，其余手动填
    private func routeToManualEdit() {
        editRoute = EditRoute(
            prefill: MealEditView.Prefill(name: "", items: [], photoData: pendingImageData),
            focusName: true
        )
    }

    // MARK: - 记录删除

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
