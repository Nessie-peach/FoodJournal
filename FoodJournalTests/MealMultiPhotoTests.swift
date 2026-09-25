import XCTest
import SwiftData
@testable import FoodJournal

/// Meal 多照片存储 round-trip 单测（in-memory 容器，验证 [Data] 字段稳定可用）
@MainActor
final class MealMultiPhotoTests: XCTestCase {
    private func fetch(byID id: UUID, context: ModelContext) throws -> Meal? {
        var descriptor = FetchDescriptor<Meal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - 存 3 张照片读出顺序与内容一致

    func testAdditionalPhotosRoundTrip() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)

        let cover = Data("cover-jpeg".utf8)
        let photo2 = Data("second-jpeg".utf8)
        let photo3 = Data("third-jpeg".utf8)
        let meal = Meal(
            mealType: .lunch,
            name: "多照片一餐",
            photoData: cover,
            additionalPhotos: [photo2, photo3]
        )
        context.insert(meal)
        try context.save()

        let fetched = try XCTUnwrap(try fetch(byID: meal.id, context: context))
        XCTAssertEqual(fetched.photoData, cover, "首图 photoData 应原样读出")
        XCTAssertEqual(fetched.additionalPhotos, [photo2, photo3], "additionalPhotos 读出顺序与内容应一致")
        XCTAssertEqual(fetched.allPhotos, [cover, photo2, photo3], "allPhotos 首图在前")
    }

    // MARK: - 空照片默认值与更新 round-trip

    func testAdditionalPhotosDefaultEmptyThenUpdateRoundTrip() throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)

        let meal = Meal(mealType: .dinner, name: "先无照片")
        context.insert(meal)
        try context.save()

        let fetched1 = try XCTUnwrap(try fetch(byID: meal.id, context: context))
        XCTAssertTrue(fetched1.additionalPhotos.isEmpty, "未传照片时 additionalPhotos 应为空数组")

        let newPhotos = [Data("a".utf8), Data("b".utf8), Data("c".utf8)]
        fetched1.photoData = newPhotos[0]
        fetched1.additionalPhotos = Array(newPhotos.dropFirst())
        try context.save()

        let fetched2 = try XCTUnwrap(try fetch(byID: meal.id, context: context))
        XCTAssertEqual(fetched2.photoData, Data("a".utf8))
        XCTAssertEqual(fetched2.additionalPhotos, [Data("b".utf8), Data("c".utf8)])
    }

    // MARK: - 无封面只有附照时 allPhotos 兜底

    func testAllPhotosWithoutCoverFallsBackToAdditional() throws {
        let meal = Meal(
            mealType: .breakfast,
            name: "无封面",
            photoData: nil,
            additionalPhotos: [Data("x".utf8)]
        )
        XCTAssertEqual(meal.allPhotos, [Data("x".utf8)], "photoData 为 nil 时 allPhotos 由 additionalPhotos 顶上")
    }
}
