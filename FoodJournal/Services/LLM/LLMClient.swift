import Foundation

/// OpenAI 兼容 Chat Completions 客户端（无状态、无共享可变状态）。
/// 目前仅实现「测试连通」所需的最小请求。
struct LLMClient {
    /// 连通性测试失败错误（按 HTTP 状态码 / 网络错误分类）
    struct ConnectionError: LocalizedError, Equatable {
        enum Kind: Equatable {
            /// 401 / 403
            case invalidKey
            /// 404
            case endpointNotFound
            /// 429
            case rateLimited
            /// 请求超时（15 秒）
            case timeout
            /// 其他 HTTP 错误
            case http(Int)
            /// 网络不可达 / DNS / TLS 等
            case network
            /// BaseURL 不合法或未填写
            case invalidURL
        }

        let kind: Kind

        var errorDescription: String? {
            switch kind {
            case .invalidKey: "API Key 无效"
            case .endpointNotFound: "端点或模型不存在"
            case .rateLimited: "请求被限流，请稍后重试"
            case .timeout: "连接超时（15 秒）"
            case .http(let code): "服务端错误（HTTP \(code)）"
            case .network: "网络连接失败"
            case .invalidURL: "BaseURL 不合法，请检查后重试"
            }
        }
    }

    /// 向 `{baseURL}/chat/completions` 发送一次最小请求，验证配置与 Key 可用。
    /// 成功返回耗时（秒）。
    ///
    /// - 重要：错误信息中绝不包含 API Key。
    func testConnection(config: LLMProviderConfig, apiKey: String) async throws -> TimeInterval {
        let base = config.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !base.isEmpty,
              let url = URL(string: base + "/chat/completions"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ConnectionError(kind: .invalidURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": "你是助手"],
                ["role": "user", "content": "回复OK"],
            ],
            "max_tokens": 16,
            "stream": false,
        ])

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 15
        sessionConfiguration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }

        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(start)

            guard let http = response as? HTTPURLResponse else {
                throw ConnectionError(kind: .network)
            }
            switch http.statusCode {
            case 200...299:
                return elapsed
            case 401, 403:
                throw ConnectionError(kind: .invalidKey)
            case 404:
                throw ConnectionError(kind: .endpointNotFound)
            case 429:
                throw ConnectionError(kind: .rateLimited)
            default:
                throw ConnectionError(kind: .http(http.statusCode))
            }
        } catch let error as ConnectionError {
            throw error
        } catch let urlError as URLError {
            if urlError.code == .timedOut {
                throw ConnectionError(kind: .timeout)
            }
            throw ConnectionError(kind: .network)
        } catch {
            throw ConnectionError(kind: .network)
        }
    }
}
