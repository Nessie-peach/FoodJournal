import Foundation
import SwiftData

// MARK: - 备份错误

enum BackupError: LocalizedError {
    case fileUnreadable
    case corrupted
    case incompatibleVersion(schemaVersion: Int)

    var errorDescription: String? {
        switch self {
        case .fileUnreadable:
            return "无法读取备份文件，请确认文件存在且可访问"
        case .corrupted:
            return "备份文件已损坏或格式不正确，无法导入"
        case .incompatibleVersion(let version):
            return "备份文件版本不兼容（schema v\(version)），当前 App 支持 v\(BackupService.schemaVersion)"
        }
    }
}

// MARK: - 导入报告

/// 导入结果报告：各表新增/跳过条数（同 id 已存在则跳过）
struct ImportReport: Equatable {
    var mealsAdded = 0
    var mealsSkipped = 0
    var weightsAdded = 0
    var weightsSkipped = 0
    var journalsAdded = 0
    var journalsSkipped = 0
    var advicesAdded = 0
    var advicesSkipped = 0

    /// 各表总跳过数
    var totalSkipped: Int {
        mealsSkipped + weightsSkipped + journalsSkipped + advicesSkipped
    }

    /// 供 alert 展示的中文摘要
    var summary: String {
        var lines: [String] = []
        if mealsAdded + mealsSkipped > 0 {
            lines.append("餐食：新增 \(mealsAdded) 条，跳过重复 \(mealsSkipped) 条")
        }
        if weightsAdded + weightsSkipped > 0 {
            lines.append("体重：新增 \(weightsAdded) 条，跳过重复 \(weightsSkipped) 条")
        }
        if journalsAdded + journalsSkipped > 0 {
            lines.append("小记：新增 \(journalsAdded) 条，跳过重复 \(journalsSkipped) 条")
        }
        if advicesAdded + advicesSkipped > 0 {
            lines.append("建议：新增 \(advicesAdded) 条，跳过重复 \(advicesSkipped) 条")
        }
        return lines.isEmpty ? "备份为空，没有可导入的数据" : lines.joined(separator: "\n")
    }
}

// MARK: - 备份载荷（不含 LLM 配置与 API Key；健康快照可从健康 App 重新同步，不导出）

/// 单个菜品
struct FoodItemBackup: Codable, Equatable {
    var id: UUID
    var name: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
}

/// 一餐（照片以 base64 存储）
struct MealBackup: Codable, Equatable {
    var id: UUID
    var date: Date
    /// 餐次（MealType rawValue）
    var mealType: String
    var name: String
    var photoData: String?
    var additionalPhotos: [String]
    var items: [FoodItemBackup]
}

struct WeightBackup: Codable, Equatable {
    var id: UUID
    var date: Date
    var weightKg: Double
}

struct JournalBackup: Codable, Equatable {
    var id: UUID
    var date: Date
    var text: String
}

struct AdviceBackup: Codable, Equatable {
    var id: UUID
    var date: Date
    var content: String
    var generatedAt: Date
    var modelTag: String
}

struct BackupPayload: Codable, Equatable {
    var schemaVersion: Int = BackupService.schemaVersion
    var exportedAt: Date
    var meals: [MealBackup]
    var weights: [WeightBackup]
    var journals: [JournalBackup]
    var advices: [AdviceBackup]
}

// MARK: - 备份服务

/// 数据导出/导入：侧载 App 每 7 天需重装，这是数据保命功能。
/// 导出为 JSON 写入临时目录后经系统分享面板保存；导入按 id 去重合并（不覆盖已有记录）。
@MainActor
struct BackupService {
    nonisolated static let schemaVersion = 1
    /// @AppStorage 键：最近一次成功导出的时间戳（timeIntervalSince1970，0 表示从未导出）
    nonisolated static let lastExportStorageKey = "backup.lastExportTimestamp"

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: 导出

    /// 导出全部记录为 JSON 文件，返回文件 URL（临时目录，导出后用 ShareLink 分享保存）
    func export() throws -> URL {
        let payload = try buildPayload()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(payload)
        let url = Self.temporaryFileURL()
        try data.write(to: url, options: .atomic)
        return url
    }

    private func buildPayload() throws -> BackupPayload {
        let meals = try modelContext.fetch(FetchDescriptor<Meal>())
        let weights = try modelContext.fetch(FetchDescriptor<WeightRecord>())
        let journals = try modelContext.fetch(FetchDescriptor<DailyJournal>())
        let advices = try modelContext.fetch(FetchDescriptor<DailyAdvice>())

        return BackupPayload(
            exportedAt: .now,
            meals: meals.map(Self.makeBackup(from:)),
            weights: weights.map { WeightBackup(id: $0.id, date: $0.date, weightKg: $0.weightKg) },
            journals: journals.map { JournalBackup(id: $0.id, date: $0.date, text: $0.text) },
            advices: advices.map {
                AdviceBackup(
                    id: $0.id, date: $0.date, content: $0.content,
                    generatedAt: $0.generatedAt, modelTag: $0.modelTag
                )
            }
        )
    }

    private static func makeBackup(from meal: Meal) -> MealBackup {
        MealBackup(
            id: meal.id,
            date: meal.date,
            mealType: meal.mealType,
            name: meal.name,
            photoData: meal.photoData?.base64EncodedString(),
            additionalPhotos: meal.additionalPhotos.map { $0.base64EncodedString() },
            items: meal.items.map {
                FoodItemBackup(
                    id: $0.id, name: $0.name,
                    calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat
                )
            }
        )
    }

    private static func temporaryFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: .now)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("今天吃什么-备份-\(stamp).json")
    }

    // MARK: 导入

    /// 从备份文件导入：校验 schemaVersion 后按 id 去重合并（同 id 已存在则跳过，不覆盖）
    func importBackup(from url: URL) throws -> ImportReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.fileUnreadable
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupError.fileUnreadable
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: BackupPayload
        do {
            payload = try decoder.decode(BackupPayload.self, from: data)
        } catch DecodingError.keyNotFound(let key, _) where key.stringValue == "schemaVersion" {
            throw BackupError.corrupted
        } catch {
            throw BackupError.corrupted
        }

        guard payload.schemaVersion == Self.schemaVersion else {
            throw BackupError.incompatibleVersion(schemaVersion: payload.schemaVersion)
        }

        var report = ImportReport()
        try importMeals(payload.meals, into: &report)
        try importWeights(payload.weights, into: &report)
        try importJournals(payload.journals, into: &report)
        try importAdvices(payload.advices, into: &report)
        return report
    }

    private func importMeals(_ backups: [MealBackup], into report: inout ImportReport) throws {
        let existingIDs = Set(try modelContext.fetch(FetchDescriptor<Meal>()).map(\.id))
        for backup in backups {
            if existingIDs.contains(backup.id) {
                report.mealsSkipped += 1
                continue
            }
            let meal = Meal(
                id: backup.id,
                date: backup.date,
                mealType: MealType.allCases.first ?? .breakfast,
                name: backup.name,
                photoData: backup.photoData.flatMap { Data(base64Encoded: $0) },
                additionalPhotos: backup.additionalPhotos.compactMap { Data(base64Encoded: $0) }
            )
            // mealType 以 rawValue 字符串保真还原（避免枚举 init 失败丢信息）
            meal.mealType = backup.mealType
            meal.items = backup.items.map {
                FoodItem(
                    id: $0.id, name: $0.name,
                    calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat,
                    meal: meal
                )
            }
            modelContext.insert(meal)
            report.mealsAdded += 1
        }
        try modelContext.save()
    }

    private func importWeights(_ backups: [WeightBackup], into report: inout ImportReport) throws {
        let existingIDs = Set(try modelContext.fetch(FetchDescriptor<WeightRecord>()).map(\.id))
        for backup in backups {
            if existingIDs.contains(backup.id) {
                report.weightsSkipped += 1
                continue
            }
            modelContext.insert(
                WeightRecord(id: backup.id, date: backup.date, weightKg: backup.weightKg)
            )
            report.weightsAdded += 1
        }
        try modelContext.save()
    }

    private func importJournals(_ backups: [JournalBackup], into report: inout ImportReport) throws {
        let existingIDs = Set(try modelContext.fetch(FetchDescriptor<DailyJournal>()).map(\.id))
        for backup in backups {
            if existingIDs.contains(backup.id) {
                report.journalsSkipped += 1
                continue
            }
            modelContext.insert(DailyJournal(id: backup.id, date: backup.date, text: backup.text))
            report.journalsAdded += 1
        }
        try modelContext.save()
    }

    private func importAdvices(_ backups: [AdviceBackup], into report: inout ImportReport) throws {
        let existingIDs = Set(try modelContext.fetch(FetchDescriptor<DailyAdvice>()).map(\.id))
        for backup in backups {
            if existingIDs.contains(backup.id) {
                report.advicesSkipped += 1
                continue
            }
            modelContext.insert(
                DailyAdvice(
                    id: backup.id, date: backup.date, content: backup.content,
                    generatedAt: backup.generatedAt, modelTag: backup.modelTag
                )
            )
            report.advicesAdded += 1
        }
        try modelContext.save()
    }
}
