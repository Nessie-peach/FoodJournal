import SwiftUI
import SwiftData

/// 体重记录：录入 + 历史列表（含与上一次的变化量）
struct WeightView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var records: [WeightRecord]

    @State private var weightText: String = ""
    @State private var entryDate: Date = .now
    @State private var inputError: String?

    init() {
        _records = Query(
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    var body: some View {
        List {
            Section("录入体重") {
                HStack(spacing: 12) {
                    TextField("体重(kg)", text: $weightText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .monospacedDigit()

                    DatePicker("日期", selection: $entryDate, displayedComponents: .date)
                        .labelsHidden()

                    Spacer()

                    Button("记录") { saveRecord() }
                        .buttonStyle(.borderedProminent)
                        .disabled(weightText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let inputError {
                    Text(inputError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if records.isEmpty {
                    Text("还没有体重记录，先记录一条吧")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        WeightRow(record: record, previous: previousRecord(for: index))
                    }
                    .onDelete(perform: deleteRecords)
                }
            } header: {
                Text("历史记录（\(records.count)）")
            }
        }
        .navigationTitle("体重")
    }

    // MARK: - 数据

    /// 列表按日期倒序，index+1 即时间上更早的上一次记录
    private func previousRecord(for index: Int) -> WeightRecord? {
        guard index + 1 < records.count else { return nil }
        return records[index + 1]
    }

    // MARK: - Actions

    private func saveRecord() {
        guard let weight = NumberParsing.parse(weightText), weight > 0, weight < 500 else {
            inputError = "请输入有效的体重数值（0–500 kg）"
            return
        }
        inputError = nil
        let repository = WeightRepository(context: modelContext)
        try? repository.insert(WeightRecord(date: entryDate, weightKg: weight))
        weightText = ""
    }

    private func deleteRecords(at offsets: IndexSet) {
        let repository = WeightRepository(context: modelContext)
        for index in offsets {
            try? repository.delete(records[index])
        }
    }
}

// MARK: - 记录行

private struct WeightRow: View {
    let record: WeightRecord
    /// 时间上更早的一条记录，用于计算变化量
    let previous: WeightRecord?

    private var change: Double? {
        guard let previous else { return nil }
        return record.weightKg - previous.weightKg
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                Text(record.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.1f", record.weightKg) + " kg")
                .font(.body.weight(.semibold))
                .monospacedDigit()
            if let change, abs(change) >= 0.05 {
                changeBadge(change)
            }
        }
        .padding(.vertical, 2)
    }

    /// 中文习惯：增重红色警示，减重绿色鼓励
    private func changeBadge(_ change: Double) -> some View {
        let gained = change > 0
        return Label {
            Text(String(format: "%+.1f", change))
                .monospacedDigit()
        } icon: {
            Image(systemName: gained ? "arrow.up" : "arrow.down")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(gained ? Color.red : Color.green)
    }
}

#Preview {
    NavigationStack { WeightView() }
        .modelContainer(for: [Meal.self, FoodItem.self, WeightRecord.self, DailyJournal.self, DailyAdvice.self, DailyHealthSnapshot.self], inMemory: true)
}
