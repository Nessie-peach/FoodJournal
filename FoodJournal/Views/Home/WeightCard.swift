import SwiftUI
import SwiftData

/// 体重卡数据组装（纯逻辑，独立可测）。
/// records 须按日期倒序传入（最新在前）。
struct WeightCardSummary: Equatable {
    let latestKg: Double
    /// 较前一次记录的变化量（正为增重，负为减重）；仅有一条记录时为 nil
    let change: Double?

    init?(records: [WeightRecord]) {
        guard let latest = records.first else { return nil }
        self.latestKg = latest.weightKg
        self.change = records.count >= 2 ? latest.weightKg - records[1].weightKg : nil
    }
}

/// 今日页【管住嘴】底部的体重卡：点击 push 到体重详情页
struct WeightCard: View {
    let summary: WeightCardSummary?

    var body: some View {
        Group {
            if let summary {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("最近体重")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f", summary.latestKg) + " kg")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    if let change = summary.change, abs(change) >= 0.05 {
                        changeBadge(change)
                    }
                }
            } else {
                Label("还没有体重记录，点我记录", systemImage: "scalemass")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 中文习惯：增重红色警示，减重绿色鼓励（与体重详情页列表一致）
    private func changeBadge(_ change: Double) -> some View {
        let gained = change > 0
        return Label {
            Text(String(format: "%+.1f", change))
                .monospacedDigit()
        } icon: {
            Image(systemName: gained ? "arrow.up" : "arrow.down")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(gained ? Color.red : Color.green)
    }
}
