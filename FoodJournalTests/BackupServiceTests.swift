import XCTest
import SwiftData
@testable import FoodJournal

/// 备份导出/导入测试
@MainActor
final class BackupServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var createdFiles: [URL] = []

    override func setUp() async throws {
        container = try TestSupport.makeContainer()
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        createdFiles = []
        container = nil
        context = nil
    }

    // MARK: - 构造样例数据

    private func insertSampleData(into context: ModelContext) throws {
        let photo = Data("封面照片二进制".utf8)
        let extraPhoto = Data("第二张照片二进制".utf8)
        let meal = Meal(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            date: TestSupport.date(y: 9, d: 20, hour: 12, minute: 30),
            mealType: .lunch,
            name: "麦当劳巨无霸套餐",
            photoData: photo,
            additionalPhotos: [extraPhoto],
            items: [
                FoodItem(
                    id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000AA")!,
                    name: "巨无霸", calories: 550, protein: 25, carbs: 45, fat: 30, meal: nil
                ),
                FoodItem(
                    id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000AB")!,
                    name: "中薯条", calories: 340, protein: 4, carbs: 44, fat: 17, meal: nil
                ),
            ]
        )
        context.insert(meal)
        context.insert(WeightRecord(
            id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!,
            date: TestSupport.date(y: 9, d: 20, hour: 7, minute: 0),
            weightKg: 72.5
        ))
        context.insert(DailyJournal(
            id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!,
            date: TestSupport.date(y: 9, d: 20, hour: 22, minute: 0),
            text: "今天中午吃了汉堡，晚上控制住了"
        ))
        context.insert(DailyAdvice(
            id: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!,
            date: TestSupport.date(y: 9, d: 20, hour: 8, minute: 0),
            content: "晚餐建议清淡少油",
            generatedAt: TestSupport.date(y: 9, d: 20, hour: 8, minute: 5),
            modelTag: "glm-4.7"
        ))
        try context.save()
    }

    private func makeBackupFile(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-test-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        createdFiles.append(url)
        return url
    }

    private func encodePayload(_ payload: BackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    // MARK: - 1. 导出 → 清空 → 导入：逐字段一致

    func testExportThenImportRoundTripPreservesAllFields() throws {
        try insertSampleData(into: context)

        let service = BackupService(modelContext: context)
        let url = try service.export()
        createdFiles.append(url)

        // 清空 in-memory 容器
        try context.delete(model: Meal.self)
        try context.delete(model: FoodItem.self)
        try context.delete(model: WeightRecord.self)
        try context.delete(model: DailyJournal.self)
        try context.delete(model: DailyAdvice.self)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<Meal>()).isEmpty)

        // 导入到同一个已清空容器
        let report = try service.importBackup(from: url)
        XCTAssertEqual(report.mealsAdded, 1)
        XCTAssertEqual(report.weightsAdded, 1)
        XCTAssertEqual(report.journalsAdded, 1)
        XCTAssertEqual(report.advicesAdded, 1)

        // 逐字段校验：餐食 + 菜品 + 照片 + 时间
        let meals = try context.fetch(FetchDescriptor<Meal>())
        XCTAssertEqual(meals.count, 1)
        let meal = try XCTUnwrap(meals.first)
        XCTAssertEqual(meal.id, UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001"))
        XCTAssertEqual(meal.date, TestSupport.date(y: 9, d: 20, hour: 12, minute: 30))
        XCTAssertEqual(meal.mealType, MealType.lunch.rawValue)
        XCTAssertEqual(meal.name, "麦当劳巨无霸套餐")
        XCTAssertEqual(meal.photoData, Data("封面照片二进制".utf8))
        XCTAssertEqual(meal.additionalPhotos, [Data("第二张照片二进制".utf8)])
        XCTAssertEqual(meal.items.count, 2)
        let burger = try XCTUnwrap(meal.items.first { $0.name == "巨无霸" })
        XCTAssertEqual(burger.id, UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000AA"))
        XCTAssertEqual(burger.calories, 550)
        XCTAssertEqual(burger.protein, 25)
        XCTAssertEqual(burger.carbs, 45)
        XCTAssertEqual(burger.fat, 30)
        XCTAssertTrue(meal.items.allSatisfy { $0.meal === meal })

        // 其余表
        let weight = try XCTUnwrap(try context.fetch(FetchDescriptor<WeightRecord>()).first)
        XCTAssertEqual(weight.weightKg, 72.5)
        XCTAssertEqual(weight.date, TestSupport.date(y: 9, d: 20, hour: 7, minute: 0))
        let journal = try XCTUnwrap(try context.fetch(FetchDescriptor<DailyJournal>()).first)
        XCTAssertEqual(journal.text, "今天中午吃了汉堡，晚上控制住了")
        let advice = try XCTUnwrap(try context.fetch(FetchDescriptor<DailyAdvice>()).first)
        XCTAssertEqual(advice.content, "晚餐建议清淡少油")
        XCTAssertEqual(advice.modelTag, "glm-4.7")
    }

    // MARK: - 2. 同一文件导入两次：第二次全部跳过

    func testImportingSameFileTwiceSkipsAllDuplicates() throws {
        try insertSampleData(into: context)

        let service = BackupService(modelContext: context)
        let url = try service.export()
        createdFiles.append(url)

        // 清空后第一次导入：全部新增
        try context.delete(model: Meal.self)
        try context.delete(model: WeightRecord.self)
        try context.delete(model: DailyJournal.self)
        try context.delete(model: DailyAdvice.self)
        try context.save()

        let first = try service.importBackup(from: url)
        XCTAssertEqual(first.mealsAdded, 1)
        XCTAssertEqual(first.weightsAdded, 1)
        XCTAssertEqual(first.journalsAdded, 1)
        XCTAssertEqual(first.advicesAdded, 1)

        // 第二次导入同一文件：全部跳过，不产生重复
        let second = try service.importBackup(from: url)
        XCTAssertEqual(second.mealsAdded, 0)
        XCTAssertEqual(second.mealsSkipped, 1)
        XCTAssertEqual(second.weightsAdded, 0)
        XCTAssertEqual(second.weightsSkipped, 1)
        XCTAssertEqual(second.journalsAdded, 0)
        XCTAssertEqual(second.journalsSkipped, 1)
        XCTAssertEqual(second.advicesAdded, 0)
        XCTAssertEqual(second.advicesSkipped, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Meal>()).count, 1)
    }

    // MARK: - 3. 损坏 JSON 抛错不 crash

    func testCorruptedJSONThrowsInsteadOfCrashing() throws {
        let service = BackupService(modelContext: context)
        let url = try makeBackupFile(data: Data("这不是一段 JSON{{".utf8))
        XCTAssertThrowsError(try service.importBackup(from: url)) { error in
            XCTAssertTrue(error is BackupError)
        }
        // 半截 JSON 同样抛错
        let partialURL = try makeBackupFile(data: Data(#"{"schemaVersion":1,"meals":[{"id":"#.utf8))
        XCTAssertThrowsError(try service.importBackup(from: partialURL))
    }

    // MARK: - 4. 错误 schemaVersion 抛版本不兼容

    func testIncompatibleSchemaVersionThrows() throws {
        var payload = BackupPayload(exportedAt: .now, meals: [], weights: [], journals: [], advices: [])
        payload.schemaVersion = 999
        let url = try makeBackupFile(data: try encodePayload(payload))

        let service = BackupService(modelContext: context)
        XCTAssertThrowsError(try service.importBackup(from: url)) { error in
            guard case BackupError.incompatibleVersion(let version) = error else {
                return XCTFail("期望 incompatibleVersion，实际 \(error)")
            }
            XCTAssertEqual(version, 999)
        }
    }

    // MARK: - 5. ImportReport 计数正确（部分重复 → 新增/跳过各一半）

    func testImportReportCountsPartialDuplicates() throws {
        try insertSampleData(into: context)
        let service = BackupService(modelContext: context)
        let url = try service.export()
        createdFiles.append(url)

        // 清空后只放回一条同 id 的旧餐食
        try context.delete(model: Meal.self)
        try context.delete(model: WeightRecord.self)
        try context.delete(model: DailyJournal.self)
        try context.delete(model: DailyAdvice.self)
        let kept = Meal(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            date: TestSupport.date(y: 1, d: 1, hour: 8),
            mealType: .snack,
            name: "旧记录（不应被覆盖）"
        )
        context.insert(kept)
        try context.save()

        let report = try service.importBackup(from: url)
        XCTAssertEqual(report.mealsAdded, 0)
        XCTAssertEqual(report.mealsSkipped, 1)
        XCTAssertEqual(report.weightsAdded, 1)
        XCTAssertEqual(report.weightsSkipped, 0)
        XCTAssertEqual(report.journalsAdded, 1)
        XCTAssertEqual(report.advicesAdded, 1)
        XCTAssertEqual(report.totalSkipped, 1)

        // 同 id 旧记录未被覆盖
        let meal = try XCTUnwrap(try context.fetch(FetchDescriptor<Meal>()).first)
        XCTAssertEqual(meal.name, "旧记录（不应被覆盖）")
        XCTAssertEqual(meal.mealType, MealType.snack.rawValue)

        // 中文摘要包含计数
        XCTAssertTrue(report.summary.contains("新增 1"))
        XCTAssertTrue(report.summary.contains("跳过重复 1"))
    }
}
