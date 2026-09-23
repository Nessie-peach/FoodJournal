import XCTest
@testable import FoodJournal

final class KeychainStoreTests: XCTestCase {
    /// 使用独立的测试服务名，避免影响真实的识图/建议 Key
    private let store = KeychainStore(service: "com.pigeon.foodjournal.llm.test")

    override func setUp() {
        super.setUp()
        store.delete()
    }

    override func tearDown() {
        store.delete()
        super.tearDown()
    }

    func testSharedStoreServiceNames() {
        XCTAssertEqual(KeychainStore.vision.service, "com.pigeon.foodjournal.llm.vision")
        XCTAssertEqual(KeychainStore.advice.service, "com.pigeon.foodjournal.llm.advice")
    }

    /// 增删改查 round-trip
    func testSaveLoadOverwriteDelete() throws {
        // 初始状态：无 Key
        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasStoredKey)

        // 新增
        try store.save("sk-test-key-001")
        XCTAssertEqual(store.load(), "sk-test-key-001")
        XCTAssertTrue(store.hasStoredKey)

        // 覆盖
        try store.save("sk-test-key-002")
        XCTAssertEqual(store.load(), "sk-test-key-002")

        // 删除
        store.delete()
        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasStoredKey)
    }

    /// 删除不存在的 Key 应静默成功
    func testDeleteMissingIsNoop() {
        store.delete()
        store.delete()
        XCTAssertNil(store.load())
    }

    /// 识图与建议两个服务名相互隔离
    func testVisionAndAdviceAreIsolated() throws {
        KeychainStore.vision.delete()
        KeychainStore.advice.delete()
        defer {
            KeychainStore.vision.delete()
            KeychainStore.advice.delete()
        }

        try KeychainStore.vision.save("sk-vision-only")
        XCTAssertNil(KeychainStore.advice.load())

        try KeychainStore.advice.save("sk-advice-only")
        XCTAssertEqual(KeychainStore.vision.load(), "sk-vision-only")
        XCTAssertEqual(KeychainStore.advice.load(), "sk-advice-only")
    }

    /// Key 不得写入 UserDefaults（服务对应的存储域检查）
    func testKeyNeverInUserDefaults() throws {
        try store.save("sk-should-not-leak")
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation() {
            if let string = value as? String {
                XCTAssertFalse(string.contains("sk-should-not-leak"),
                               "UserDefaults 键 \(key) 中疑似泄漏了 API Key")
            }
        }
    }
}
