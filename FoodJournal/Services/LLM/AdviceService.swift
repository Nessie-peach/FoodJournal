import Foundation
import SwiftData

/// 健康建议生成流程错误（分类风格与 VisionError 一致；绝不包含 API Key）。
enum AdviceError: LocalizedError, Equatable {
    case invalidURL
    case invalidKey        // 401 / 403
    case endpointNotFound  // 404
    case rateLimited       // 429
    case timeout           // 45 秒
    case http(Int)
    case network
    /// 模型回复为空或无法解析
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "BaseURL 不合法，请检查后重试"
        case .invalidKey: "API Key 无效"
        case .endpointNotFound: "端点或模型不存在"
        case .rateLimited: "请求被限流，请稍后重试"
        case .timeout: "生成超时（45 秒），请重试"
        case .http(let code): "服务端错误（HTTP \(code)）"
        case .network: "网络连接失败"
        case .parseFailed: "AI 返回内容无法识别，请重试"
        }
    }
}

/// AI 健康建议服务（R5-4）：数据驱动的私人化建议，无需小记文本。
/// 从 SwiftData 读当日健康快照 / 饮食 / 近 7 日体重打包为文本，走建议模型非流式生成。
struct AdviceService {
    /// 建议 system prompt（定稿，勿改动）
    static let systemPrompt =
        "你是用户的私人健康助手。根据提供的当日健康数据、饮食记录与体重趋势，输出中文健康建议，分四个部分：一、当日概况（两三句话总结饮食与运动平衡）；二、做得好的点（一两句，实事求是，没有亮点就说没有）；三、分维度建议（睡眠、运动、饮食各一条，具体可执行，结合数据）；四、心理关怀（若睡眠不足 6.5 小时或数据透露压力大/状态差，给一段简短温暖的宽慰；状态平稳则一两句正向鼓励即可，不煽情）。数据缺失的维度直接说明并跳过对应建议，不要编造数值。"

    /// 请求超时（秒）
    static let timeoutInterval: TimeInterval = 45

    /// 生成健康建议。
    /// - Parameters:
    ///   - date: 建议对应的日期（默认当天）
    ///   - context: SwiftData 上下文（读快照 / 饮食 / 体重）
    ///   - config: LLM 接入配置（建议模型那份；BaseURL / 模型 ID）
    ///   - apiKey: API Key（仅用于 Authorization 头，绝不进入错误信息）
    ///   - channel: 建议渠道（"exercise"=迈开腿 / "journal"=小记）
    ///   - journalText: 小记全文；仅 journal 渠道打包进数据段（无小记传 nil，标「无数据」）
    @MainActor
    func generateAdvice(
        date: Date = .now,
        context: ModelContext,
        config: LLMProviderConfig,
        apiKey: String,
        channel: String = DailyAdvice.Channel.exercise,
        journalText: String? = nil
    ) async throws -> String {
        let userText = Self.packContextText(
            snapshot: Self.fetchSnapshot(for: date, in: context),
            meals: Self.fetchMeals(for: date, in: context),
            weights: Self.fetchRecentWeights(before: date, days: 7, in: context),
            includesJournalSection: channel == DailyAdvice.Channel.journal,
            journalText: journalText
        )
        return try await request(userText: userText, config: config, apiKey: apiKey)
    }

    // MARK: - 数据打包

    /// 打包建议用上下文文本；缺失维度明确标注「无数据」，不编造。
    /// includesJournalSection 为 true 时（journal 渠道）追加【今日小记】段：
    /// 有小记打全文，无小记（journalText 为 nil 或空白）标「无数据」。
    /// internal 以便单测覆盖有/无快照、无饮食、无体重、有/无小记各分支。
    nonisolated static func packContextText(
        snapshot: DailyHealthSnapshot?,
        meals: [Meal],
        weights: [WeightRecord],
        includesJournalSection: Bool = false,
        journalText: String? = nil
    ) -> String {
        var lines: [String] = []

        if let snapshot {
            lines.append("【当日健康数据】")
            lines.append("活动消耗：\(Int(snapshot.activeKcal.rounded())) 千卡；静息消耗：\(Int(snapshot.restingKcal.rounded())) 千卡")
            if snapshot.sleepMinutes > 0 {
                var sleep = "睡眠：\(HealthCardFormat.sleepText(minutes: snapshot.sleepMinutes))"
                if let start = snapshot.sleepStart, let end = snapshot.sleepEnd {
                    sleep += "（\(HealthCardFormat.clockText(start)) 入睡，\(HealthCardFormat.clockText(end)) 起床）"
                }
                lines.append(sleep)
            } else {
                lines.append("睡眠：无数据")
            }
            lines.append(snapshot.avgHR > 0 ? "平均心率：\(Int(snapshot.avgHR.rounded())) 次/分" : "平均心率：无数据")
            if let lastNight = snapshot.hrvLastNightAvg {
                var hrv = "HRV：昨晚平均 \(Int(lastNight.rounded())) ms（佳明）"
                if let low = snapshot.hrvBaselineLow, let high = snapshot.hrvBaselineHigh {
                    let vs = lastNight < low ? "低于" : lastNight > high ? "高于" : "处于"
                    hrv += "，基线 \(Int(low))-\(Int(high)) ms（\(vs)基线）"
                }
                lines.append(hrv)
            } else if let hrv = snapshot.hrvMS {
                lines.append("HRV：\(Int(hrv.rounded())) ms")
            } else {
                lines.append("HRV：无数据")
            }
            // Garmin 专有：身体电量 / 压力 / 睡眠分期
            if let battery = snapshot.bodyBatteryCurrent {
                lines.append("身体电量：\(battery)/100")
            } else {
                lines.append("身体电量：无数据")
            }
            if let stress = snapshot.stressAvg {
                lines.append("压力：均值 \(stress)/100")
            } else {
                lines.append("压力：无数据")
            }
            if let deep = snapshot.deepSleepMin, let rem = snapshot.remSleepMin {
                var stages = "睡眠分期："
                if snapshot.sleepMinutes > 0 {
                    stages += "深睡 \(Int((deep / snapshot.sleepMinutes * 100).rounded()))%，REM \(Int((rem / snapshot.sleepMinutes * 100).rounded()))%"
                } else {
                    stages += "深睡 \(Int(deep.rounded())) 分钟，REM \(Int(rem.rounded())) 分钟"
                }
                if let score = snapshot.sleepScore {
                    stages += "，睡眠分 \(score)"
                }
                lines.append(stages)
            } else {
                lines.append("睡眠分期：无数据")
            }
            let workouts = Self.parseWorkouts(from: snapshot.workoutsJSON)
            if workouts.isEmpty {
                lines.append("运动记录：无数据")
            } else {
                lines.append("运动记录：")
                for workout in workouts {
                    var entry = "- \(Self.workoutName(workout.activityType)) \(Int(workout.durationMinutes.rounded())) 分钟"
                    if let energy = workout.energyKcal {
                        entry += "，消耗 \(Int(energy.rounded())) 千卡"
                    }
                    lines.append(entry)
                }
            }
        } else {
            lines.append("【当日健康数据】无数据（未授权或尚未同步）")
        }

        lines.append("")
        if meals.isEmpty {
            lines.append("【今日饮食】无饮食记录")
        } else {
            lines.append("【今日饮食】")
            let names = meals.map { meal in
                "\(meal.type?.displayName ?? "加餐")「\(meal.name)」"
            }
            lines.append("已记录 \(meals.count) 餐：" + names.joined(separator: "、"))
            let totalCalories = meals.reduce(0.0) { $0 + $1.totalCalories }
            let totalProtein = meals.reduce(0.0) { $0 + $1.totalProtein }
            let totalCarbs = meals.reduce(0.0) { $0 + $1.totalCarbs }
            let totalFat = meals.reduce(0.0) { $0 + $1.totalFat }
            lines.append("营养合计：热量 \(Int(totalCalories.rounded())) 千卡，蛋白质 \(Int(totalProtein.rounded())) 克，碳水 \(Int(totalCarbs.rounded())) 克，脂肪 \(Int(totalFat.rounded())) 克")
        }

        lines.append("")
        let sortedWeights = weights.sorted { $0.date < $1.date }
        if sortedWeights.isEmpty {
            lines.append("【近 7 日体重】无体重数据")
        } else {
            lines.append("【近 7 日体重】")
            for record in sortedWeights {
                lines.append("\(Self.dayText(record.date)) \(Self.numberText(record.weightKg)) 千克")
            }
            if sortedWeights.count >= 2,
               let first = sortedWeights.first,
               let last = sortedWeights.last {
                let delta = last.weightKg - first.weightKg
                let direction = delta > 0 ? "上升" : delta < 0 ? "下降" : "持平"
                lines.append("趋势：近期体重\(direction)约 \(Self.numberText(abs(delta))) 千克")
            }
        }

        if includesJournalSection {
            lines.append("")
            let trimmed = (journalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                lines.append("【今日小记】无数据")
            } else {
                lines.append("【今日小记】")
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 请求

    /// 组装 OpenAI 兼容请求体。internal 以便单测直接验证消息构造。
    nonisolated static func makeRequestBody(config: LLMProviderConfig, userText: String) -> [String: Any] {
        [
            "model": config.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
            // 与识图/AI 修改一致：关闭模型 thinking（火山引擎端点特有参数，其他厂商可能忽略）
            "thinking": ["type": "disabled"],
            "stream": false,
        ]
    }

    private func request(userText: String, config: LLMProviderConfig, apiKey: String) async throws -> String {
        let base = config.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !base.isEmpty,
              let url = URL(string: base + "/chat/completions"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AdviceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.makeRequestBody(config: config, userText: userText))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = Self.timeoutInterval
        sessionConfiguration.timeoutIntervalForResource = Self.timeoutInterval
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AdviceError.network
            }
            switch http.statusCode {
            case 200...299:
                let content = try VisionService.extractReplyContent(from: data)
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AdviceError.parseFailed
                }
                return content
            case 401, 403:
                throw AdviceError.invalidKey
            case 404:
                throw AdviceError.endpointNotFound
            case 429:
                throw AdviceError.rateLimited
            default:
                throw AdviceError.http(http.statusCode)
            }
        } catch let error as AdviceError {
            throw error
        } catch let error as VisionError {
            if case .parseFailed = error { throw AdviceError.parseFailed }
            throw AdviceError.network
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw AdviceError.timeout
        } catch {
            throw AdviceError.network
        }
    }

    // MARK: - 建议正文分段（UI 排版用）

    /// 把模型输出按「一、二、三、四、」小标题拆分为 (标题, 正文) 段落；
    /// 无法识别结构时返回单段（标题空，全文为正文）。
    nonisolated static func parseSections(from content: String) -> [(title: String, body: String)] {
        let pattern = /^[一二三四五六七八九十]+、/
        var sections: [(title: String, body: String)] = []
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.firstMatch(of: pattern) != nil {
                // 标题行可能形如「一、当日概况：xxx」，冒号后内容并入正文
                let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == "：" || $0 == ":" })
                let title = parts[0].trimmingCharacters(in: .whitespaces)
                let remainder = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                sections.append((title: title, body: remainder))
            } else if !sections.isEmpty {
                sections[sections.count - 1].body += (sections[sections.count - 1].body.isEmpty ? "" : "\n") + trimmed
            } else {
                sections.append((title: "", body: trimmed))
            }
        }
        return sections
    }

    // MARK: - 私有辅助

    private static func fetchSnapshot(for date: Date, in context: ModelContext) -> DailyHealthSnapshot? {
        let calendar = Calendar.current
        // 快照按自然日 key 存取：date 应传业务日锚点（00:00），取其自然日快照
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let predicate = #Predicate<DailyHealthSnapshot> { snapshot in
            snapshot.date >= start && snapshot.date < end
        }
        let descriptor = FetchDescriptor<DailyHealthSnapshot>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try? context.fetch(descriptor).first
    }

    private static func fetchMeals(for date: Date, in context: ModelContext) -> [Meal] {
        let calendar = Calendar.current
        // 餐按业务日归属：04:00 → 次日 04:00
        let range = LogicalDay.businessDayRange(of: date, calendar: calendar)
        let start = range.start
        let end = range.end
        let predicate = #Predicate<Meal> { meal in
            meal.date >= start && meal.date < end
        }
        let descriptor = FetchDescriptor<Meal>(predicate: predicate, sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchRecentWeights(before date: Date, days: Int, in context: ModelContext) -> [WeightRecord] {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else { return [] }
        let predicate = #Predicate<WeightRecord> { record in
            record.date >= start && record.date < end
        }
        let descriptor = FetchDescriptor<WeightRecord>(predicate: predicate, sortBy: [SortDescriptor(\.date)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func parseWorkouts(from json: String?) -> [WorkoutRecord] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WorkoutRecord].self, from: data)) ?? []
    }

    /// HKWorkoutActivityType 名称 → 中文运动名（未知类型原样展示）
    static func workoutName(_ activityType: String) -> String {
        switch activityType {
        case "running": "跑步"
        case "walking": "健走"
        case "cycling": "骑行"
        case "swimming": "游泳"
        case "functionalStrengthTraining", "traditionalStrengthTraining": "力量训练"
        case "yoga": "瑜伽"
        case "hiking": "徒步"
        case "elliptical": "椭圆机"
        case "rowing": "划船"
        case "jumpRope": "跳绳"
        case "basketball": "篮球"
        case "soccer": "足球"
        case "badminton": "羽毛球"
        case "tennis": "网球"
        case "pingPong": "乒乓球"
        case "dance": "舞蹈"
        case "climbing": "攀岩"
        default: activityType
        }
    }

    /// 日期 →「MM-dd」（固定 locale，结果稳定）
    private static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    /// 数值 → 最多一位小数的稳定文本（70.5 → "70.5"，70 → "70"）
    private static func numberText(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
