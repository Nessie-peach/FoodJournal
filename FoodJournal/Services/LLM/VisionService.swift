import Foundation

/// 拍照识图结果：餐名 + 各菜品营养草稿（尚未落库，供 UI 二次确认/编辑）。
struct MealRecognitionResult: Equatable, Sendable {
    var mealName: String
    var items: [FoodItemDraft]
}

/// 单个菜品的营养草稿。
struct FoodItemDraft: Equatable, Sendable {
    var name: String
    /// kcal
    var calories: Double
    /// g
    var protein: Double
    /// g
    var carbs: Double
    /// g
    var fat: Double
    /// 营养数据来源：official 表示品牌官方/包装营养表，estimate 表示估算；模型可能漏输出，为 nil
    var source: String?
}

/// 识图流程错误（分类风格与 LLMClient.ConnectionError 一致；绝不包含 API Key）。
enum VisionError: LocalizedError, Equatable {
    case invalidURL
    case invalidKey        // 401 / 403
    case endpointNotFound  // 404
    case rateLimited       // 429
    case timeout           // 30 秒
    case http(Int)
    case network
    /// 模型回复无法解析为合法结果；附带原始回复前 200 字符供调试
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "BaseURL 不合法，请检查后重试"
        case .invalidKey: "API Key 无效"
        case .endpointNotFound: "端点或模型不存在"
        case .rateLimited: "请求被限流，请稍后重试"
        case .timeout: "识图超时（30 秒），请重试"
        case .http(let code): "服务端错误（HTTP \(code)）"
        case .network: "网络连接失败"
        case .parseFailed: "AI 返回内容无法识别，请重试"
        }
    }
}

/// 拍照识图服务：OpenAI 兼容 chat/completions 视觉请求 + 结果解析。
struct VisionService: Sendable {
    /// 识图 system prompt（定稿，勿改动：多张照片/营养表口径/备注优先采信 + 连锁品牌官方数据 + 多份同类食物分开记录 + source 字段 + 纯 JSON 输出约束）
    static let systemPrompt =
        "你是食物识别助手。用户提供的是同一餐食的一张或多张照片，可能包含食物的不同角度，也可能包含包装上的营养成分表，还可能附带文字备注（备注信息优先采信）。仔细清点每种食物的数量，多份同类食物要分开记录或在名称中标注数量。如果照片中包含营养成分表，优先按照营养表上的数值填写（注意区分\"每100克\"与\"每份\"的口径）。若识别为连锁品牌的具体商品（如茶百道、蜜雪冰城、瑞幸、麦当劳等），先辨别具体品类与规格（饮品需辨别糖度与杯型），并优先依据该品牌官方公布的营养数据作答。只输出 JSON，格式 {\"mealName\":\"...\",\"items\":[{\"name\":\"...\",\"calories\":数字kcal,\"protein\":数字克,\"carbs\":数字克,\"fat\":数字克,\"source\":\"official或estimate\"}]}，source 填 official 表示依据品牌官方或包装营养表数据，estimate 表示估算；不要输出任何其他文字。"

    static let defaultUserText = "请识别这些同一餐食照片中的所有菜品，并按系统要求的 JSON 格式输出营养估算。"

    /// user 消息文本：备注非空时拼接备注并要求优先采信；空白备注视为未填写
    static func userText(remark: String?) -> String {
        let trimmed = remark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return defaultUserText }
        return "用户备注：\(trimmed)（识别时请优先采信备注信息）。请识别照片中的所有菜品，并按系统要求的 JSON 格式输出营养估算。"
    }

    /// 请求超时（秒）
    static let timeoutInterval: TimeInterval = 30

    /// 识别餐食照片（支持同一餐食的多张照片：不同角度 / 包装营养成分表）。
    /// - Parameters:
    ///   - imageDatas: JPEG 图片数据数组（建议先用 `ImageCompression.compress` 压缩，每张各自压缩）
    ///   - remark: 用户拍后备注（可空，非空时优先采信）
    ///   - config: LLM 接入配置（BaseURL / 模型 ID）
    ///   - apiKey: API Key（仅用于 Authorization 头，绝不进入错误信息）
    func recognizeFood(
        imageDatas: [Data],
        remark: String? = nil,
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
            imageDatas: imageDatas,
            remark: remark
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
                rawReply = try Self.extractReplyContent(from: data)
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

    /// 组装 OpenAI 兼容多模态请求体：单条 user 消息的 content 数组中放多个 image_url（每张各自转 data URI）+ 文本指令。
    /// internal 以便单测直接验证请求体构造。
    static func makeRequestBody(
        config: LLMProviderConfig,
        imageDatas: [Data],
        remark: String? = nil
    ) -> [String: Any] {
        let imageEntries = imageDatas.map { data in
            [
                "type": "image_url",
                "image_url": ["url": ImageCompression.dataURI(from: data)],
            ]
        }
        return [
            "model": config.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": imageEntries + [["type": "text", "text": userText(remark: remark)]],
                ],
            ],
            // 关闭模型 thinking（实测提速 3.6 倍，见 docs/M2-thinking提速验证.md）。
            // 注意：该参数为火山引擎端点特有；其他厂商不识别时可能忽略或返回 400，
            // 届时用户可在设置页看到错误提示（当前默认厂商即火山，可接受）。
            "thinking": ["type": "disabled"],
            "stream": false,
        ]
    }

    /// 从 chat/completions 响应中取出 choices[0].message.content
    /// internal 以便 AIEditService 复用（同为 chat/completions 纯文本响应）
    static func extractReplyContent(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }
                let message: Message?
            }
            let choices: [Choice]?
        }

        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            if let content = decoded.choices?.first?.message?.content, !content.isEmpty {
                return content
            }
        } catch {
            // 落到下方统一按 parseFailed 处理
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw VisionError.parseFailed(String(raw.prefix(200)))
    }
}

/// 模型回复文本 → MealRecognitionResult 的解析器（独立可测）。
enum VisionResponseParser {
    /// 提取 JSON 并解码；失败抛 `VisionError.parseFailed`（带原始回复前 200 字符）。
    static func parse(_ reply: String) throws -> MealRecognitionResult {
        guard let jsonText = extractJSON(from: reply),
              let jsonData = jsonText.data(using: .utf8) else {
            throw VisionError.parseFailed(String(reply.prefix(200)))
        }
        if let result = try? JSONDecoder().decode(TolerantRecognitionResult.self, from: jsonData) {
            return result.toResult()
        }
        // 容错：模型偶发在合法 JSON 之后尾随多余 `}`（M2-0 实测）。
        // 「第一个 { 到最后一个 }」的截取策略会把尾括号包含进来导致解码失败，
        // 这里逐次去掉末尾的 `}` 再试。
        var trimmed = jsonText
        while trimmed.hasSuffix("}") {
            trimmed = String(trimmed.dropLast())
            if let data = trimmed.data(using: .utf8),
               let result = try? JSONDecoder().decode(TolerantRecognitionResult.self, from: data) {
                return result.toResult()
            }
        }
        throw VisionError.parseFailed(String(reply.prefix(200)))
    }

    /// 从模型回复文本中提取 JSON：
    /// 1. 剥离 ```json ... ``` 代码围栏；
    /// 2. 截取第一个 `{` 到最后一个 `}` 之间的内容（去掉围栏外的前后废话）。
    static func extractJSON(from reply: String) -> String? {
        var text = reply
        // 剥离代码围栏（```json ... ``` 或 ``` ... ```）
        if let fenceRange = text.range(of: "```") {
            let afterFence = text[fenceRange.upperBound...]
            if let closeRange = afterFence.range(of: "```") {
                text = String(afterFence[..<closeRange.lowerBound])
            } else {
                text = String(afterFence)
            }
            // 去掉可能紧跟 ``` 的语言标记（如 "json\n{...}"）
            if let newline = text.firstIndex(where: { $0.isNewline }) {
                let before = text[..<newline]
                if before.trimmingCharacters(in: .whitespaces) == "json" {
                    text = String(text[text.index(after: newline)...])
                }
            }
        }

        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }
}

// MARK: - 容错解码（模型可能输出字符串数字或带单位数字）

/// 可容错解码的 Double：支持 JSON 数字、字符串数字（"360"）、带单位数字（"360kcal"）。
/// 缺失或无法解析时按 0 处理。
@propertyWrapper
struct FlexibleDouble: Decodable, Equatable, Sendable {
    var wrappedValue: Double

    init(wrappedValue: Double = 0) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            wrappedValue = value
        } else if let text = try? container.decode(String.self) {
            wrappedValue = Self.extractNumber(from: text) ?? 0
        } else {
            wrappedValue = 0
        }
    }

    /// 从文本中提取第一段数字（含小数与负号）；无数字返回 nil。
    static func extractNumber(from text: String) -> Double? {
        guard let match = text.firstMatch(of: /-?[0-9]+(?:\.[0-9]+)?/) else { return nil }
        return Double(match.0)
    }
}

/// 内部容错解码模型：mealName / items 缺失时给默认值，营养数值走 FlexibleDouble。
private struct TolerantRecognitionResult: Decodable {
    struct TolerantItem: Decodable {
        var name: String
        @FlexibleDouble var calories: Double = 0
        @FlexibleDouble var protein: Double = 0
        @FlexibleDouble var carbs: Double = 0
        @FlexibleDouble var fat: Double = 0
        var source: String?

        private enum CodingKeys: String, CodingKey {
            case name, calories, protein, carbs, fat, source
        }

        init() {
            name = ""
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? container.decode(String.self, forKey: .name)) ?? ""
            calories = (try? container.decodeIfPresent(FlexibleDouble.self, forKey: .calories))?.wrappedValue ?? 0
            protein = (try? container.decodeIfPresent(FlexibleDouble.self, forKey: .protein))?.wrappedValue ?? 0
            carbs = (try? container.decodeIfPresent(FlexibleDouble.self, forKey: .carbs))?.wrappedValue ?? 0
            fat = (try? container.decodeIfPresent(FlexibleDouble.self, forKey: .fat))?.wrappedValue ?? 0
            // source 可选（模型可能漏输出）；未知值原样保留，UI 只对 official 显示标记
            source = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? nil
        }
    }

    var mealName: String
    var items: [TolerantItem]

    private enum CodingKeys: String, CodingKey {
        case mealName, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mealName = (try? container.decode(String.self, forKey: .mealName)) ?? ""
        items = (try? container.decodeIfPresent([TolerantItem].self, forKey: .items)) ?? []
    }

    func toResult() -> MealRecognitionResult {
        MealRecognitionResult(
            mealName: mealName,
            items: items.map {
                FoodItemDraft(
                    name: $0.name,
                    calories: $0.calories,
                    protein: $0.protein,
                    carbs: $0.carbs,
                    fat: $0.fat,
                    source: $0.source
                )
            }
        )
    }
}
