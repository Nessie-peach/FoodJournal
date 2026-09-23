import Foundation

/// 数字输入解析工具：容错处理用户手动输入的数值文本
enum NumberParsing {
    /// 把用户输入的数字文本解析为 Double。
    /// - 支持小数点「.」与中文键盘常见的逗号「,」小数分隔（如 "12,5" → 12.5）
    /// - 自动去除首尾空白与千分位逗号以外的空白
    /// - 空串或非法内容返回 nil（调用方可按 0 处理）
    static func parse(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 归一化逗号：若同时含 "." 与 ","，视逗号为千分位；否则视逗号为小数点
        if trimmed.contains(","), trimmed.contains(".") {
            trimmed = trimmed.replacingOccurrences(of: ",", with: "")
        } else {
            trimmed = trimmed.replacingOccurrences(of: ",", with: ".")
        }

        return Double(trimmed)
    }

    /// 解析并容错：空值 / 非法输入按 fallback（默认 0）处理
    static func parseOrZero(_ text: String, fallback: Double = 0) -> Double {
        parse(text) ?? fallback
    }
}

/// 数值显示格式化：用于把 Double 回填到输入框，去掉多余的 0
enum NumberFormatting {
    /// 0 → "0"；12.5 → "12.5"；12.0 → "12"
    static func inputText(_ value: Double) -> String {
        guard value != 0 else { return "0" }
        if value == value.rounded() && abs(value) < 1_000_000 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
