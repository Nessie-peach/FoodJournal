import Foundation

/// AI 修改服务：用建议模型按自然语言指令修正识别结果（R5-2）。
/// 请求走 OpenAI 兼容 chat/completions（纯文本），解析复用 VisionResponseParser 容错。
struct AIEditService: Sendable {
    /// 修改 system prompt（定稿，勿改动：严格按指令改、未提及的不动、只输出与输入同构的 JSON）
    static let systemPrompt =
        "你是饮食记录修改助手。用户会给你一份当前的餐食记录 JSON 和一句自然语言修改指令。严格按照指令修改数据（如\"这一整杯都是我喝的\"意味着把按半杯估算的菜品数值调整为整杯；\"米饭只吃了一半\"意味着减半），未提及的菜品保持不变。可以微调菜品名称使其更准确。只输出修改后的完整 JSON，格式与输入完全一致：{\"mealName\":\"...\",\"items\":[{\"name\":\"...\",\"calories\":数字,\"protein\":数字,\"carbs\":数字,\"fat\":数字,\"source\":\"official或estimate\"}]}，不要输出任何其他文字。"

    /// 请求超时（秒）
    static let timeoutInterval: TimeInterval = 30

    /// 按指令修改当前餐食记录。
    /// - Parameters:
    ///   - currentJSON: 当前餐食记录 JSON（首轮为编辑页快照，多轮时为上一轮结果 JSON）
    ///   - instruction: 本轮自然语言修改指令
    ///   - history: 历轮（指令, 该轮结果 JSON），按时间先后排列
    ///   - config: LLM 接入配置（建议模型那份；BaseURL / 模型 ID）
    ///   - apiKey: API Key（仅用于 Authorization 头，绝不进入错误信息）
    func reviseMeal(
        currentJSON: String,
        instruction: String,
        history: [(instruction: String, resultJSON: String)],
        config: LLMProviderConfig,
        apiKey: String
    ) async throws -> MealRecognitionResult {
        let base = config.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !base.isEmpty,
              let url = URL(string: base + "/chat/completions"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw VisionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.makeRequestBody(
            config: config,
            currentJSON: currentJSON,
            instruction: instruction,
            history: history
        ))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = Self.timeoutInterval
        sessionConfiguration.timeoutIntervalForResource = Self.timeoutInterval
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }

        let rawReply: String
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw VisionError.network
            }
            switch http.statusCode {
            case 200...299:
                rawReply = try VisionService.extractReplyContent(from: data)
            case 401, 403:
                throw VisionError.invalidKey
            case 404:
                throw VisionError.endpointNotFound
            case 429:
                throw VisionError.rateLimited
            default:
                throw VisionError.http(http.statusCode)
            }
        } catch let error as VisionError {
            throw error
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw VisionError.timeout
        } catch {
            throw VisionError.network
        }

        return try VisionResponseParser.parse(rawReply)
    }

    /// 组装请求体：system prompt + 历轮（user 指令 / assistant 结果交替）+ 当前餐 JSON + 本轮指令。
    /// internal 以便单测直接验证消息构造。
    static func makeRequestBody(
        config: LLMProviderConfig,
        currentJSON: String,
        instruction: String,
        history: [(instruction: String, resultJSON: String)]
    ) -> [String: Any] {
        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        for round in history {
            messages.append(["role": "user", "content": Self.userContent(currentJSON: round.resultJSON, instruction: round.instruction)])
            messages.append(["role": "assistant", "content": round.resultJSON])
        }
        messages.append(["role": "user", "content": Self.userContent(currentJSON: currentJSON, instruction: instruction)])
        return [
            "model": config.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": messages,
            // 与识图一致：关闭模型 thinking（火山引擎端点特有参数，其他厂商可能忽略）
            "thinking": ["type": "disabled"],
            "stream": false,
        ]
    }

    /// user 消息文本：当前餐 JSON + 本轮指令
    private static func userContent(currentJSON: String, instruction: String) -> String {
        "当前的餐食记录 JSON：\n\(currentJSON)\n\n修改指令：\(instruction)"
    }

    /// 把结果编码回与 prompt 约定同构的 JSON（多轮 history 与下一轮 currentJSON 用）。
    static func encodeJSON(_ result: MealRecognitionResult) -> String {
        struct EncodableItem: Encodable {
            let name: String
            let calories: Double
            let protein: Double
            let carbs: Double
            let fat: Double
            let source: String?
        }
        struct EncodableResult: Encodable {
            let mealName: String
            let items: [EncodableItem]
        }
        let payload = EncodableResult(
            mealName: result.mealName,
            items: result.items.map {
                EncodableItem(name: $0.name, calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat, source: $0.source)
            }
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"mealName\":\"\",\"items\":[]}"
        }
        return json
    }
}

// MARK: - 变更摘要（纯函数，独立可测）

/// 单个菜品的变更项（AI 修改前后对比）。
struct MealItemChange: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// 菜品仍在，名称/数值有变化
        case modified
        /// 新增菜品
        case added
        /// 菜品被移除
        case removed
    }

    let kind: Kind
    /// 变更前菜品（added 时为 nil）
    let oldItem: FoodItemDraft?
    /// 变更后菜品（removed 时为 nil）
    let newItem: FoodItemDraft?

    /// 面向用户的摘要文本（只列有变化的部分）
    var summaryText: String {
        switch kind {
        case .added:
            let item = newItem
            return "新增：\(item?.name ?? "")（热量 \(formatNumber(item?.calories ?? 0)) 千卡）"
        case .removed:
            return "删除：\(oldItem?.name ?? "")"
        case .modified:
            let old = oldItem, new = newItem
            var lines: [String] = []
            if old?.name != new?.name {
                lines.append("名称：\(old?.name ?? "") → \(new?.name ?? "")")
            }
            func field(_ label: String, _ oldValue: Double, _ newValue: Double) {
                if oldValue != newValue {
                    lines.append("\(label)：\(formatNumber(oldValue)) → \(formatNumber(newValue))")
                }
            }
            field("热量", old?.calories ?? 0, new?.calories ?? 0)
            field("蛋白", old?.protein ?? 0, new?.protein ?? 0)
            field("碳水", old?.carbs ?? 0, new?.carbs ?? 0)
            field("脂肪", old?.fat ?? 0, new?.fat ?? 0)
            let name = new?.name ?? old?.name ?? ""
            return "\(name)：" + lines.joined(separator: "，")
        }
    }

    private func formatNumber(_ value: Double) -> String {
        NumberFormatting.inputText(value)
    }
}

enum MealDraftDiff {
    /// 逐菜品对比新旧草稿列表，生成变更摘要。无变化时返回空数组。
    /// 对齐策略：以菜品名称做 LCS 对齐（同名项配对比较营养数值）；
    /// 间隙中两侧都非空时，营养签名相同而名称不同的视为重命名配对，其余按删除/新增。
    static func diffMealDrafts(old: [FoodItemDraft], new: [FoodItemDraft]) -> [MealItemChange] {
        let oldNames = old.map(\.name)
        let newNames = new.map(\.name)
        let m = oldNames.count, n = newNames.count

        // LCS 长度表（名称相同视为可对齐）
        var lcs = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                lcs[i][j] = oldNames[i] == newNames[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        // 回溯出配对的 (oldIndex, newIndex)
        var pairs: [(oldIndex: Int, newIndex: Int)] = []
        var i = 0, j = 0
        while i < m && j < n {
            if oldNames[i] == newNames[j] {
                pairs.append((i, j))
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        var changes: [MealItemChange] = []
        var oi = 0, ni = 0
        for pair in pairs {
            emitGap(old: old[oi..<pair.oldIndex], new: new[ni..<pair.newIndex], into: &changes)
            if old[pair.oldIndex] != new[pair.newIndex] {
                changes.append(MealItemChange(kind: .modified, oldItem: old[pair.oldIndex], newItem: new[pair.newIndex]))
            }
            oi = pair.oldIndex + 1
            ni = pair.newIndex + 1
        }
        emitGap(old: old[oi..<m], new: new[ni..<n], into: &changes)
        return changes
    }

    /// 处理对齐间隙：一侧为空直接新增/删除；两侧都非空时优先按「重命名」配对（营养签名相同、名称不同），其余删除/新增
    private static func emitGap(old: ArraySlice<FoodItemDraft>, new: ArraySlice<FoodItemDraft>, into changes: inout [MealItemChange]) {
        let oldItems = Array(old)
        let newItems = Array(new)

        if oldItems.isEmpty {
            newItems.forEach { changes.append(MealItemChange(kind: .added, oldItem: nil, newItem: $0)) }
            return
        }
        if newItems.isEmpty {
            oldItems.forEach { changes.append(MealItemChange(kind: .removed, oldItem: $0, newItem: nil)) }
            return
        }

        var matchedNew = Set<Int>()
        for oldItem in oldItems {
            if let k = newItems.indices.first(where: {
                !matchedNew.contains($0)
                    && newItems[$0].name != oldItem.name
                    && hasSameNutrition(newItems[$0], oldItem)
            }) {
                matchedNew.insert(k)
                changes.append(MealItemChange(kind: .modified, oldItem: oldItem, newItem: newItems[k]))
            } else {
                changes.append(MealItemChange(kind: .removed, oldItem: oldItem, newItem: nil))
            }
        }
        for (k, newItem) in newItems.enumerated() where !matchedNew.contains(k) {
            changes.append(MealItemChange(kind: .added, oldItem: nil, newItem: newItem))
        }
    }

    /// 营养签名是否完全一致（用于识别「只改了名」的重命名）
    private static func hasSameNutrition(_ a: FoodItemDraft, _ b: FoodItemDraft) -> Bool {
        a.calories == b.calories && a.protein == b.protein && a.carbs == b.carbs && a.fat == b.fat
    }
}
