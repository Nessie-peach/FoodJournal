import SwiftUI
import SwiftData
import PhotosUI

/// 今日页：管住嘴（饮食记录）/ 迈开腿（当日健康快照卡片）
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext

    /// 上层 TabView 的选中态：备份横幅点击时跳转「我的」
    @Binding var selectedTab: AppTab

    @Query private var todayMeals: [Meal]
    @Query private var weightRecords: [WeightRecord]

    // MARK: - 备份提醒

    @AppStorage(BackupService.lastExportStorageKey) private var lastExportTimestamp: Double = 0

    /// 从未导出，或距上次导出超过 5 天 → 显示备份提醒横幅
    private var showBackupBanner: Bool {
        lastExportTimestamp <= 0
            || Date().timeIntervalSince1970 - lastExportTimestamp > 5 * 24 * 3600
    }

    private var backupBannerText: String {
        guard lastExportTimestamp > 0 else {
            return "你还没有备份过数据，侧载重装会丢数据，去我的-数据管理导出"
        }
        let days = max(1, Int((Date().timeIntervalSince1970 - lastExportTimestamp) / (24 * 3600)))
        return "已 \(days) 天未备份，侧载重装会丢数据，去我的-数据管理导出"
    }

    // MARK: - 今日页模式

    private enum TodayMode: Hashable {
        case diet
        case exercise
    }

    @State private var selectedMode: TodayMode = .diet

    // MARK: - 识图流程状态

    @AppStorage(LLMProviderConfig.visionStorageKey) private var visionConfigJSON: String = LLMProviderConfig.default.asJSON

    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []

    /// 单次拍摄/多选的照片上限
    private static let maxPhotoCount = 5

    /// 已压缩、待识别/待保存的照片 JPEG Data（首图在前）
    @State private var pendingImages: [Data] = []

    /// 照片确认页（拍摄/多选后进入，可补拍、删图、发起识别）
    @State private var showConfirmSheet = false
    /// 确认页内补拍的相机（以确认页 sheet 为宿主呈现，取消/成功都回落到确认页）
    @State private var showRetakeCamera = false
    /// 入口相机本次是否拍到照片（用于 dismiss 后按状态机决定落点）
    @State private var entryCameraDidCapture = false

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

    init(selectedTab: Binding<AppTab>) {
        _selectedTab = selectedTab
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
            captureFlowPresentations(content: mainPage)
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
        }
    }

    // MARK: - 主页面（内容 + 弹窗）

    private var mainPage: some View {
        recognitionAlerts(content: todayContent)
    }

    private var todayContent: some View {
        VStack(spacing: 0) {
            switch selectedMode {
            case .diet:
                dietList
            case .exercise:
                ExerciseView(selectedTab: $selectedTab)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: UUID.self) { id in
            if let meal = todayMeals.first(where: { $0.id == id }) {
                MealEditView(meal: meal)
            }
        }
        .navigationDestination(item: $editRoute) { route in
            MealEditView(prefill: route.prefill, focusNameOnAppear: route.focusName)
        }
        .toolbar { toolbarItems }
    }

    // MARK: - 顶栏

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("拍照") { showCamera = true }
                    .disabled(!cameraAvailable)
                Button("从相册选择") { showPhotoPicker = true }
            } label: {
                Image(systemName: "camera.fill")
            }
            .accessibilityLabel("拍照识别")
        }
        ToolbarItem(placement: .principal) {
            Picker("今日模式", selection: $selectedMode) {
                Text("管住嘴").tag(TodayMode.diet)
                Text("迈开腿").tag(TodayMode.exercise)
            }
            .pickerStyle(.segmented)
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

    // MARK: - 拍摄流程呈现链

    /// 入口相机（fullScreenCover）→ 相册多选 → 照片确认页（sheet，内含补拍相机）
    private func captureFlowPresentations(content: some View) -> some View {
        content
            .fullScreenCover(isPresented: $showCamera, onDismiss: {
                // 入口相机 dismiss 后按状态机落点：拍到照片 → 确认页；取消 → 主界面
                if CaptureFlowLogic.destinationAfterCameraDismiss(
                    entryPoint: .entry, didCaptureImage: entryCameraDidCapture
                ) == .confirmSheet {
                    showConfirmSheet = true
                }
                entryCameraDidCapture = false
            }) {
                CameraPicker { image in
                    handlePickedImage(image, from: .entry)
                }
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoPickerItems,
                maxSelectionCount: Self.maxPhotoCount,
                matching: .images
            )
            .onChange(of: photoPickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                loadPickedPhotos(newItems)
            }
            .sheet(isPresented: $showConfirmSheet) {
                photoConfirmSheet
            }
    }

    /// 照片确认页 + 叠在其上的补拍相机：
    /// sheet 保持呈现，相机取消（X）只收起相机，已拍照片全部保留
    private var photoConfirmSheet: some View {
        PhotoConfirmView(
            images: pendingImages,
            canAddMore: pendingImages.count < Self.maxPhotoCount,
            onRetake: { showRetakeCamera = true },
            onComplete: { completeCapture() },
            onCancel: { showConfirmSheet = false },
            onDelete: { index in
                pendingImages.remove(at: index)
            }
        )
        .fullScreenCover(isPresented: $showRetakeCamera) {
            CameraPicker { image in
                handlePickedImage(image, from: .retake)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - 识别相关弹窗

    @ViewBuilder
    private func recognitionAlerts(content: some View) -> some View {
        content
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
    }

    // MARK: - 管住嘴：今日饮食列表

    private var dietList: some View {
        List {
            if showBackupBanner {
                Section {
                    BackupBanner(text: backupBannerText) {
                        selectedTab = .settings
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

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

    /// 相册多选：异步载入每张 → 压缩 → 追加后进入照片确认页
    private func loadPickedPhotos(_ items: [PhotosPickerItem]) {
        photoPickerItems = []
        Task {
            var loaded: [Data] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let compressed = ImageCompression.compress(image) {
                    loaded.append(compressed)
                }
            }
            guard !loaded.isEmpty else {
                showImageLoadError = true
                return
            }
            appendPendingImages(loaded)
            showConfirmSheet = true
        }
    }

    /// 拍照入口：压缩 → 追加；入口相机 dismiss 后按状态机进入确认页
    private func handlePickedImage(_ image: UIImage, from entryPoint: CaptureFlowLogic.CameraEntryPoint) {
        guard let data = ImageCompression.compress(image) else {
            showImageLoadError = true
            return
        }
        appendPendingImages([data])
        if entryPoint == .entry {
            entryCameraDidCapture = true
        }
    }

    /// 追加待处理照片（超过上限截断）
    private func appendPendingImages(_ datas: [Data]) {
        let space = Self.maxPhotoCount - pendingImages.count
        guard space > 0 else { return }
        pendingImages.append(contentsOf: datas.prefix(space))
    }

    /// 确认页「完成拍摄」：配置检查 → 发起识别（全部照片一次识别）
    private func completeCapture() {
        showConfirmSheet = false
        guard !pendingImages.isEmpty else { return }

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
        guard !pendingImages.isEmpty, !isRecognizing else { return }
        let images = pendingImages
        isRecognizing = true
        recognitionTask = Task {
            do {
                let result = try await VisionService().recognizeFood(
                    imageDatas: images, config: config, apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                // 识别成功：立即跳编辑页（识别模式），首图作封面、焦点落餐名
                editRoute = EditRoute(
                    prefill: MealEditView.Prefill(
                        name: result.mealName,
                        items: result.items.map { MealEditView.ItemDraft(draft: $0) },
                        photoData: images.first,
                        additionalPhotos: Array(images.dropFirst())
                    ),
                    focusName: true
                )
                pendingImages = []
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
        // 中途取消不丢已拍照片：回到照片确认页
        if !pendingImages.isEmpty {
            showConfirmSheet = true
        }
    }

    private func retryRecognition() {
        let config = LLMProviderConfig(json: visionConfigJSON) ?? .default
        let apiKey = KeychainStore.vision.load() ?? ""
        startRecognition(config: config, apiKey: apiKey)
    }

    /// 识别失败后改手动记录：保留全部照片预填，其余手动填
    private func routeToManualEdit() {
        editRoute = EditRoute(
            prefill: MealEditView.Prefill(
                name: "",
                items: [],
                photoData: pendingImages.first,
                additionalPhotos: Array(pendingImages.dropFirst())
            ),
            focusName: true
        )
        pendingImages = []
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

// MARK: - 备份提醒横幅

/// 数据备份提醒：点击跳转「我的」tab 的数据管理区
private struct BackupBanner: View {
    let text: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text + "，点按前往数据管理")
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

// MARK: - 照片确认页

/// 拍摄/多选后的照片确认页：横向缩略图列表（可左滑查看、单张删除）+ 补拍/完成。
/// 中途取消（含识别中取消）不丢已拍照片。
private struct PhotoConfirmView: View {
    let images: [Data]
    /// 未达上限时展示「再拍一张」
    let canAddMore: Bool
    let onRetake: () -> Void
    let onComplete: () -> Void
    let onCancel: () -> Void
    let onDelete: (Int) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if images.isEmpty {
                    emptyState
                } else {
                    thumbnailStrip
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("已选 \(images.count)/5 张")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成拍摄（\(images.count) 张）") { onComplete() }
                        .disabled(images.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if canAddMore && !images.isEmpty {
                    Button {
                        onRetake()
                    } label: {
                        Label("再拍一张", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Text("还没有照片")
        } description: {
            Text("照片已全部删除，可取消后重新拍摄或从相册选择")
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(images.indices, id: \.self) { index in
                    thumbnail(at: index)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private func thumbnail(at index: Int) -> some View {
        VStack(spacing: 6) {
            if let image = UIImage(data: images[index]) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 150, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button {
                        onDelete(index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .offset(x: 6, y: -6)
                    .accessibilityLabel("删除第 \(index + 1) 张照片")
                }
                Text(index == 0 ? "封面" : "第 \(index + 1) 张")
                    .font(.caption2)
                    .foregroundStyle(index == 0 ? .orange : .secondary)
            }
        }
    }
}

#Preview {
    HomeView(selectedTab: .constant(.home))
        .modelContainer(for: [Meal.self, FoodItem.self, WeightRecord.self, DailyJournal.self, DailyAdvice.self, DailyHealthSnapshot.self], inMemory: true)
}
