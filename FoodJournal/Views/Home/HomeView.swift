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
    @Query private var todaySnapshots: [DailyHealthSnapshot]
    /// 近三天（含今天）餐与快照：趋势表卡用
    @Query private var recentMeals: [Meal]
    @Query private var recentSnapshots: [DailyHealthSnapshot]
    /// 近 8 个自然日快照：营养目标的「近 7 个业务日均消耗」用
    @Query private var weekSnapshots: [DailyHealthSnapshot]

    /// 跳转饮食历史页
    @State private var showDietHistory = false

    /// 每日热量缺口目标（千卡），我的-目标 中设置
    @AppStorage(CalorieGap.goalStorageKey) private var gapGoalKcal: Double = CalorieGap.defaultGoalKcal

    /// 蛋白系数（g/kg）与脂肪供能比，我的-目标 中设置
    @AppStorage(NutritionTargetSettings.proteinFactorKey) private var proteinFactor: Double = NutritionTargetSettings.defaultProteinFactor
    @AppStorage(NutritionTargetSettings.fatRatioKey) private var fatRatio: Double = NutritionTargetSettings.defaultFatRatio

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
    fileprivate static let maxPhotoCount = 5

    /// 已压缩、待识别/待保存的照片 JPEG Data（首图在前）
    @State private var pendingImages: [Data] = []

    /// 拍后备注（照片确认页输入，随识别流程传给模型；空白视为未填写）
    @State private var photoRemark = ""

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

    /// 历史页补记录的预设日期（nil = 今日页发起的正常流程）；
    /// 识别/手动记录进入编辑页时写入该日期，用后即清
    @State private var historyPresetDate: Date?

    /// 跳转 MealEditView 的路由参数（Hashable 以配合 navigationDestination(item:)）
    struct EditRoute: Hashable {
        var prefill: MealEditView.Prefill
        var focusName: Bool
        /// 历史页补记录的预设日期（nil = 用当前时间）
        var presetDate: Date?
    }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    init(selectedTab: Binding<AppTab>) {
        _selectedTab = selectedTab
        let calendar = Calendar.current
        // 今日业务日区间（04:00 分界：当天 04:00 → 次日 04:00）
        let businessRange = LogicalDay.businessDayRange(of: .now, calendar: calendar)
        let start = businessRange.start
        let end = businessRange.end
        _todayMeals = Query(
            filter: #Predicate<Meal> { meal in
                meal.date >= start && meal.date < end
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
        // 今日消耗快照：快照按自然日 key 存取，凌晨窗口（00:00–04:00）取前一自然日（方案 A）
        let burnDayStart = LogicalDay.burnSnapshotDay(for: .now, calendar: calendar)
        let burnDayEnd = calendar.date(byAdding: .day, value: 1, to: burnDayStart) ?? burnDayStart
        _todaySnapshots = Query(
            filter: #Predicate<DailyHealthSnapshot> { snapshot in
                snapshot.date >= burnDayStart && snapshot.date < burnDayEnd
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
        // 近三个业务日（趋势表卡）：最早业务日锚点前推 2 个日历日；
        // 查询起点用自然日 0 点（略宽于业务日 04:00，归属由 TrendPreview 按业务日判定）
        let todayAnchor = LogicalDay.businessDay(of: .now, calendar: calendar)
        let threeDayAnchor = calendar.date(byAdding: .day, value: -2, to: todayAnchor) ?? todayAnchor
        let threeDayStart = calendar.startOfDay(for: threeDayAnchor)
        _recentMeals = Query(
            filter: #Predicate<Meal> { meal in
                meal.date >= threeDayStart && meal.date < end
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
        _recentSnapshots = Query(
            filter: #Predicate<DailyHealthSnapshot> { snapshot in
                snapshot.date >= threeDayStart && snapshot.date < end
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
        // 近 8 个自然日快照（覆盖营养目标的近 7 个业务日，含凌晨窗口余量）
        let weekAnchor = calendar.date(byAdding: .day, value: -7, to: todayAnchor) ?? todayAnchor
        let weekStart = calendar.startOfDay(for: weekAnchor)
        _weekSnapshots = Query(
            filter: #Predicate<DailyHealthSnapshot> { snapshot in
                snapshot.date >= weekStart && snapshot.date < end
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    var body: some View {
        // 识别遮罩与告警挂在 NavigationStack 外层：从历史页发起补记录识别时，
        // 覆盖层仍能盖住已 push 的历史页（挂在栈内根视图上会被 push 内容遮挡）
        recognitionAlerts(content:
            NavigationStack {
                captureFlowPresentations(content: mainPage)
                    .sheet(isPresented: $showSettings) {
                        SettingsView()
                    }
            }
        )
    }

    // MARK: - 主页面（内容 + 弹窗）

    private var mainPage: some View {
        todayContent
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
        .navigationDestination(isPresented: $showDietHistory) {
            DietHistoryView(
                onCapture: { presetDate in
                    historyPresetDate = presetDate
                    showCamera = true
                },
                onPickPhotos: { presetDate in
                    historyPresetDate = presetDate
                    showPhotoPicker = true
                }
            )
        }
        .toolbar { toolbarItems }
    }

    // MARK: - 顶栏

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("拍照") {
                    historyPresetDate = nil
                    showCamera = true
                }
                .disabled(!cameraAvailable)
                Button("从相册选择") {
                    historyPresetDate = nil
                    showPhotoPicker = true
                }
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
            // 传 Binding 而非值拷贝：确认页实时读取 pendingImages，
            // 首拍追加后立即可见（值拷贝会停在呈现时的旧快照上）
            images: $pendingImages,
            remark: $photoRemark,
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
                SummaryBar(
                    meals: todayMeals,
                    targets: nutritionTargets,
                    basisWeightKg: latestWeightKg,
                    basisAvgBurnKcal: avgBurn7d,
                    deficitGoalKcal: gapGoalKcal
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                CalorieGapCard(
                    totalBurnedKcal: todaySnapshots.first.map { $0.activeKcal + $0.restingKcal },
                    consumedKcal: todayMeals.reduce(0) { $0 + $1.totalCalories },
                    goalKcal: gapGoalKcal,
                    isGarminSyncing: SyncStatusStore.shared.isSyncing
                        && SyncStatusStore.shared.currentSources.contains(.garmin),
                    showsBurnCutoffNote: LogicalDay.isInLateNightWindow(now: .now)
                )
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
                ThreeDayTrendCard(
                    rows: TrendPreview.recentThreeDayTrend(
                        meals: recentMeals, snapshots: recentSnapshots, now: .now
                    ),
                    onOpenHistory: { showDietHistory = true }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
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

    // MARK: - 每日营养素目标

    /// 最新一次体重记录（kg）
    private var latestWeightKg: Double? {
        weightRecords.max { $0.date < $1.date }?.weightKg
    }

    /// 近 7 个业务日均总消耗（activeKcal + restingKcal）
    private var avgBurn7d: Double? {
        averageBurn(
            snapshots: weekSnapshots,
            anchorDay: LogicalDay.businessDay(of: .now)
        )
    }

    /// 今日汇总卡的每日营养素目标（各项缺失独立处理）
    private var nutritionTargets: NutritionTargets {
        makeTargets(
            latestWeightKg: latestWeightKg,
            avgBurn7d: avgBurn7d,
            deficitTarget: gapGoalKcal,
            proteinFactor: proteinFactor,
            fatRatio: fatRatio
        )
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
        pendingImages = CaptureFlowLogic.appendedPhotos(
            current: pendingImages, new: datas, limit: Self.maxPhotoCount
        )
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
        startRecognition(config: config, apiKey: apiKey ?? "", remark: photoRemark)
    }

    // MARK: - 识别流程

    private func startRecognition(config: LLMProviderConfig, apiKey: String, remark: String) {
        guard !pendingImages.isEmpty, !isRecognizing else { return }
        let images = pendingImages
        isRecognizing = true
        recognitionTask = Task {
            do {
                let result = try await VisionService().recognizeFood(
                    imageDatas: images, remark: remark, config: config, apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                // 识别成功：立即跳编辑页（识别模式），首图作封面、焦点落餐名；
                // 历史页补记录时预设日期为该历史业务日
                editRoute = EditRoute(
                    prefill: MealEditView.Prefill(
                        name: result.mealName,
                        items: result.items.map { MealEditView.ItemDraft(draft: $0) },
                        photoData: images.first,
                        additionalPhotos: Array(images.dropFirst())
                    ),
                    focusName: true,
                    presetDate: historyPresetDate
                )
                historyPresetDate = nil
                pendingImages = []
                photoRemark = ""
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
        startRecognition(config: config, apiKey: apiKey, remark: photoRemark)
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
            focusName: true,
            presetDate: historyPresetDate
        )
        historyPresetDate = nil
        pendingImages = []
        photoRemark = ""
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
    /// 每日营养素目标（nil = 依据缺失，显示「—」）
    let targets: NutritionTargets
    /// 目标依据：最新体重 / 近 7 业务日均消耗 / 缺口目标
    let basisWeightKg: Double?
    let basisAvgBurnKcal: Double?
    let deficitGoalKcal: Double

    private var totalCalories: Double { meals.reduce(0) { $0 + $1.totalCalories } }
    private var totalProtein: Double { meals.reduce(0) { $0 + $1.totalProtein } }
    private var totalCarbs: Double { meals.reduce(0) { $0 + $1.totalCarbs } }
    private var totalFat: Double { meals.reduce(0) { $0 + $1.totalFat } }

    /// 是否有任一目标依据（体重或快照），决定底部显示依据行还是缺失提示
    private var hasAnyBasis: Bool { basisWeightKg != nil || basisAvgBurnKcal != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日汇总")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                summaryItem(
                    value: "\(Int(totalCalories))", unit: "千卡", label: "总热量",
                    target: targets.calories, isOver: isOverTarget(today: totalCalories, target: targets.calories),
                    comma: true
                )
                summaryItem(
                    value: String(format: "%.1f", totalProtein), unit: "g", label: "蛋白",
                    target: targets.proteinG, isOver: isOverTarget(today: totalProtein, target: targets.proteinG)
                )
                summaryItem(
                    value: String(format: "%.1f", totalCarbs), unit: "g", label: "碳水",
                    target: targets.carbsG, isOver: isOverTarget(today: totalCarbs, target: targets.carbsG)
                )
                summaryItem(
                    value: String(format: "%.1f", totalFat), unit: "g", label: "脂肪",
                    target: targets.fatG, isOver: isOverTarget(today: totalFat, target: targets.fatG)
                )
            }
            footerLine
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 底部：有依据 → 依据行；体重与快照都缺 → 缺失提示
    @ViewBuilder
    private var footerLine: some View {
        if hasAnyBasis {
            Text(basisText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            Text("记录体重并同步健康数据后可显示每日目标")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 「目标依据：体重 104 kg · 近7日均消耗 2,400 千卡 · 缺口 300」（缺失项略去）
    private var basisText: String {
        var parts: [String] = []
        if let weight = basisWeightKg {
            parts.append("体重 \(String(format: "%g", weight)) kg")
        }
        if let burn = basisAvgBurnKcal {
            parts.append("近7日均消耗 \(StatsAggregation.kcalText(burn)) 千卡")
        }
        parts.append("缺口 \(Int(deficitGoalKcal))")
        return "目标依据：" + parts.joined(separator: " · ")
    }

    /// 三行式列：今日值+单位 → /目标（缺失「—」）→ 营养素名；超额今日值标红
    private func summaryItem(
        value: String, unit: String, label: String, target: Double?, isOver: Bool, comma: Bool = false
    ) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isOver ? Color.red : Color.primary)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(targetText(target, comma: comma))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 第二行目标文字：千卡带千分位，其余整数
    private func targetText(_ target: Double?, comma: Bool) -> String {
        guard let target else { return "—" }
        let number = comma ? StatsAggregation.kcalText(target) : "\(Int(target.rounded()))"
        return "/\(number)"
    }
}

// MARK: - 热量缺口卡

/// 今日热量缺口：总消耗（活动+静息）/ 已摄入 / 当前缺口 / 距目标 / 当量提示。
/// 无当日快照时走「待同步」空态（其余行弱化）；@Query 快照与今日餐变化自动重算。
/// 凌晨窗口（00:00–04:00）消耗取前一自然日（方案 A），显示「消耗截至 24:00」小字。
private struct CalorieGapCard: View {
    /// 当日总消耗（活动+静息，kcal）；nil = 未同步/无数据
    let totalBurnedKcal: Double?
    let consumedKcal: Double
    let goalKcal: Double
    /// 同步中且含 Garmin 来源：消耗行显示小转圈（未登录 Garmin 时不转，维持「待同步」）
    var isGarminSyncing: Bool = false
    /// 凌晨窗口小字：消耗数据截至前一自然日 24:00
    var showsBurnCutoffNote: Bool = false

    private var result: CalorieGap.Result? {
        CalorieGap.evaluate(
            totalBurnedKcal: totalBurnedKcal, consumedKcal: consumedKcal, goalKcal: goalKcal
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("热量缺口")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let result {
                normalRows(result)
            } else {
                pendingRows
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 正常态

    private func normalRows(_ result: CalorieGap.Result) -> some View {
        let burned = Int((totalBurnedKcal ?? 0).rounded())
        let consumed = Int(consumedKcal.rounded())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                metric(value: burned, label: "今日总消耗", showsSpinner: isGarminSyncing)
                metric(value: consumed, label: "已摄入")
                metric(value: burned - consumed, label: "当前缺口")
            }
            if showsBurnCutoffNote {
                Text("消耗截至 24:00")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            goalLine(result.goalStatus)
            hintLine(result.hint)
        }
    }

    private func metric(value: Int, label: String, showsSpinner: Bool = false) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                ZStack(alignment: .leading) {
                    Text("\(value)")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .opacity(showsSpinner ? 0 : 1)
                        .foregroundStyle(showsSpinner ? Color.secondary : Color.primary)
                    if showsSpinner {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text("千卡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func goalLine(_ status: CalorieGap.GoalStatus) -> some View {
        switch status {
        case .belowGoal(let remaining):
            Text("距目标：还差 \(Int(remaining.rounded())) 千卡达标")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .aboveGoal(let excess):
            Text("距目标：已超出目标 \(Int(excess.rounded())) 千卡")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func hintLine(_ hint: CalorieGap.EquivalentHint) -> some View {
        switch hint {
        case .surplus(let name):
            Text("已多留出约\(name)的缺口")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .goalReached:
            Text("已达今日缺口目标，再吃将增加盈余")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .hidden:
            EmptyView()
        }
    }

    // MARK: 待同步空态（弱化）

    private var pendingRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                pendingItem(value: "待同步", label: "今日总消耗", showsSpinner: isGarminSyncing)
                pendingItem(value: "\(Int(consumedKcal.rounded()))", label: "已摄入")
                pendingItem(value: "—", label: "当前缺口")
            }
            Text(isGarminSyncing ? "正在同步健康数据…" : "健康数据待同步，同步后显示缺口进度")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func pendingItem(value: String, label: String, showsSpinner: Bool = false) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .center) {
                Text(value)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .opacity(showsSpinner ? 0 : 1)
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 近三天趋势表卡

/// 近三天摄入/消耗/差值一览：点标题行箭头进入完整饮食历史
private struct ThreeDayTrendCard: View {
    let rows: [TrendPreview.TrendRow]
    let onOpenHistory: () -> Void

    /// 数值列宽（摄入/消耗/差值右对齐）
    private let valueWidth: CGFloat = 62

    private var showsPendingNotice: Bool { TrendPreview.showsBurnPendingNotice(rows) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerButton
            columnHeaders
            ForEach(rows) { row in
                rowView(row)
            }
            if showsPendingNotice {
                Text("消耗数据待同步")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 标题行（44pt 点击区，整行可点）

    private var headerButton: some View {
        Button(action: onOpenHistory) {
            HStack {
                Text("近三天")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: Circle())
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("近三天趋势，查看饮食历史")
    }

    // MARK: 表头与数据行

    private var columnHeaders: some View {
        HStack {
            Text("日期")
            Spacer()
            Text("摄入").frame(width: valueWidth, alignment: .trailing)
            Text("消耗").frame(width: valueWidth, alignment: .trailing)
            Text("差值").frame(width: valueWidth, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func rowView(_ row: TrendPreview.TrendRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.label)
                    .font(.subheadline.weight(row.isToday ? .semibold : .regular))
                    .foregroundStyle(row.isToday ? .primary : .secondary)
                Text(shortDate(row.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            valueCell(row.isToday, text: countText(row.intake), color: valueColor(row.isToday))
            valueCell(row.isToday, text: burnText(row), color: valueColor(row.isToday))
            valueCell(row.isToday, text: diffText(row), color: diffColor(row))
        }
    }

    private func valueCell(_ isToday: Bool, text: String, color: Color) -> some View {
        Text(text)
            .font(.subheadline.weight(isToday ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(color)
            .frame(width: valueWidth, alignment: .trailing)
    }

    // MARK: 数值格式

    private func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return "\(month)/\(day)"
    }

    private func countText(_ kcal: Double) -> String {
        "\(Int(kcal.rounded()))"
    }

    private func burnText(_ row: TrendPreview.TrendRow) -> String {
        row.burn.map { countText($0) } ?? "—"
    }

    /// 缺口（负）显示 −N、盈余（正）显示 +N；无消耗数据显示 —
    private func diffText(_ row: TrendPreview.TrendRow) -> String {
        guard let diff = row.diff else { return "—" }
        let value = Int(diff.rounded())
        return value < 0 ? "−\(abs(value))" : "+\(value)"
    }

    private func valueColor(_ isToday: Bool) -> Color {
        isToday ? .primary : .secondary
    }

    private func diffColor(_ row: TrendPreview.TrendRow) -> Color {
        guard let diff = row.diff, Int(diff.rounded()) != 0 else {
            return row.isToday ? .primary : .secondary
        }
        return diff < 0 ? .green : .red
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
    /// 实时绑定宿主 pendingImages：追加/删除即时反映到确认页
    @Binding var images: [Data]
    /// 未达上限时展示「再拍一张」
    private var canAddMore: Bool { images.count < HomeView.maxPhotoCount }
    /// 拍后备注（随「完成拍摄」传入识别流程）
    @Binding var remark: String
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
                    remarkField
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
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

    /// 备注输入框：语音靠系统键盘听写，不做单独语音按钮
    private var remarkField: some View {
        TextField(
            "补充信息帮助识别：如品牌、糖度、份量（可选）",
            text: $remark,
            axis: .vertical
        )
        .lineLimit(1...3)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("拍后备注")
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
