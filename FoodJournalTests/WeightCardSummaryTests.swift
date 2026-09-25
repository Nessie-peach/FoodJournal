import Testing
import Foundation
@testable import FoodJournal

@Suite struct WeightCardSummaryTests {

    @Test("无记录时不生成卡片数据")
    func emptyRecords() {
        #expect(WeightCardSummary(records: []) == nil)
    }

    @Test("仅一条记录时无变化量")
    func singleRecord() {
        let records = [WeightRecord(date: .now, weightKg: 65.0)]
        let summary = WeightCardSummary(records: records)
        #expect(summary?.latestKg == 65.0)
        #expect(summary?.change == nil)
    }

    @Test("多条记录时计算与上一次的变化量")
    func changeBetweenRecords() {
        let old = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let records = [
            WeightRecord(date: .now, weightKg: 64.2),
            WeightRecord(date: old, weightKg: 65.5),
        ]
        let summary = WeightCardSummary(records: records)
        #expect(summary?.latestKg == 64.2)
        #expect(abs((summary?.change ?? 0) - (-1.3)) < 0.001)
    }
}
