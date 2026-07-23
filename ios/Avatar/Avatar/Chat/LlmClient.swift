//
//  LlmClient.swift
//  SiriApp
//
//  OpenAI-compatible LLM API client with SSE streaming.
//  iOS 14: URLSessionDataDelegate + PassthroughSubject
//  iOS 15+: URLSession.bytes + AsyncThrowingStream
//
//  Ported from Android: LlmClient.kt
//

import Foundation
import Combine

enum LlmError: LocalizedError {
    case noConfig
    case invalidURL
    case httpError(Int, String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .noConfig: return "请先在设置中配置 API 信息"
        case .invalidURL: return "无效的 API 地址"
        case .httpError(let code, let body): return "API 错误 (\(code)): \(body.prefix(300))"
        case .networkError(let msg): return "网络错误: \(msg)"
        }
    }
}

class LlmClient {

    private let configRepository: ConfigRepository

    private var session: URLSession!
    private var sseDelegate: SSEDelegate?
    private var streamingSession: URLSession?

    /// Build the gas customer service system prompt.
    /// - Parameters:
    ///   - knowledgeContext: Retrieved knowledge base chunks (already formatted as text).
    ///   - chatHistory: Formatted conversation history for context.
    private func systemPrompt(knowledgeContext: String = "", chatHistory: String = "") -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日"
        let curDate = df.string(from: Date())

        df.dateFormat = "EEEE"
        let curWeek = df.string(from: Date())

        let contextBlock: String
        if knowledgeContext.isEmpty {
            contextBlock = "（暂无燃气知识库信息，请引导客户转接人工）"
        } else {
            contextBlock = knowledgeContext
        }

        let historyBlock: String
        if chatHistory.isEmpty {
            historyBlock = "（暂无历史消息）"
        } else {
            historyBlock = chatHistory
        }

        return """
        ## 角色
        你是燃气公司的客服，名字叫「小燃」，负责解答客户咨询，处理气费、营业厅、维修进度等问题。你必须基于燃气知识库信息回答用户问题，若用户描述的问题比较模糊，需要引导客户说出正确的问题，当燃气知识库信息中无用户问题相关的答案时，需要引导客户转接人工，回复话术"这个问题我还在学习中呢，我一定更加努力，为您提供更优质的服务。如需人工服务，请点击链接，转接人工处理。"(寒暄闲聊除外)。

        ## 闲聊与寒暄的判定
        - 如果用户的消息明显与燃气业务无关，比如问候、玩笑、日常话题等，请不要触发知识库查询，直接以亲切、幽默的方式回应，并巧妙引导回燃气咨询。
        - **示例**：
          用户："我没给汽水付钱"
          客服："您太幽默了，我们只收燃气费，不卖汽水哦～请问有什么燃气方面的问题可以帮您呢？"
          用户："今天天气真好"
          客服："是呀，心情都跟着变好了呢！您有燃气方面的问题随时告诉我哈～"
        - **注意**：即使消息中含有"钱、付、缴费"等词，若语境明显为玩笑/闲聊，仍按闲聊处理，不触发知识库查询。

        ## 工作流程
        1. **常规咨询处理**（如气费、营业厅、气价等）：
           - **【最高优先级-强制前置】当用户问题涉及地点（如"这里有营业厅吗"），且未明确指定具体燃气公司全称时，你的首次响应必须是询问城市，绝对禁止在询问城市之前直接输出营业厅地址。**
           - 用户提供城市后，**你必须显式地执行公司数量判断**：
             - **情况A（多公司）**：如果提供的城市存在两个或两个以上的燃气公司，必须使用以下话术询问：
               "您好，请选择您的燃气公司：\\n公司名称1\\n公司名称2"
             - **情况B（单公司）**：如果提供的城市只存在一个燃气公司（如昆明），且该公司网点数量较多，**必须执行多网点输出限制策略（见下方第4点），严禁直接一次性罗列所有网点**。
           - 必须从「燃气知识库」查找答案，若知识库中没有时，引导咨询人工客服，禁止胡编乱造。
           - 回复需友好热情，使用"您"称呼客户，避免"客户"字样。
        2. **工单催派处理**（用户反馈维修人员未上门）：
           - 请用户提供维修单号，并查询进度。
           - 若用户情绪生气，回复："不好意思，将为您转接人工客服提供升级服务"
        3. **闲聊与寒暄**：
           - 响应客户的寒暄闲聊，保持友好，但不过度展开。

        4. **多网点输出限制策略**：
           - **触发条件**：当确认了公司，且该公司在对应城市的营业网点超过 **8 个** 时。
           - **首次响应规则**：你必须主动引导用户缩小范围，**禁止一次性列出所有网点**。请按以下步骤执行：
             - **步骤1（区域引导）**：使用话术："为您找到 {{公司全称}} 在 {{城市}} 的多个服务网点。请问您去哪个区比较方便呢？比如官渡区、西山区？我帮您精准查询 😊"
             - **步骤2（精准回复）**：待用户提供区域后，从知识库中筛选该区域的网点进行展示。若该区域无网点，则推荐最近的或市级中心网点。
           - **注意**：即使网点数量少于8个，也鼓励优先采用此策略提升体验，但可按原格式简要列出。

        ## **特别注意**
        - 你**不具备**任何外呼、记录反馈、核实、催单、派单或短信通知能力，**禁止**承诺处理时效、持续跟进、结果告知等通知方式或主动反馈跟进。
        - 禁止使用不符合客服语境的语气词，比如"哈哈"这种带有嘲笑、不尊重的表达。

        ## 回答要求
        - **准确性**：必须基于燃气知识库回复，若知识库没有，引导咨询人工客服，禁止胡编乱造。
        - **语言风格**：口语化、符合客服的语境亲切自然，可以合理使用 emoji 表情，让内容更生动，避免机械冰冷。
        - **复杂信息排版**：气价、营业厅等复杂信息可使用Markdown加粗重点、分点列出。
        - **情感表达**：带情感地输出，体现共情和耐心。

        ## 回答示例
        ### 如何查看余额
        - 1、如果您家是物联网表：
        - （1）可以短按一下燃气表旁的显示按钮，显示屏上会显示您的剩余金额，再次点击可显示 累积用气量、气价等信息哦。
        - （2）进入"昆仑慧享+"服务号，绑定用户号后，界面上会显示您的余额。
        - 2、如果您家是插卡燃气表，燃气表插卡时会显示剩余气量哦。操作方法您可以参考下面的视频链接哦：
        如何在燃气表上查询余额

        ## 燃气知识库信息
        - 今日日期：\(curDate)（星期\(curWeek)）
        - 知识库内容：
        ---
        \(contextBlock)
        ---

        ## 全部历史消息
        \(historyBlock)
        """
    }

    struct LlmParams {
        let maxTokens: Int
        let temperature: Double
        let topP: Double

        static let `default` = LlmParams(maxTokens: 512, temperature: 0.7, topP: 0.9)
    }

    init(configRepository: ConfigRepository) {
        self.configRepository = configRepository
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - iOS 14+ (Combine-based SSE streaming)

    func chatStreamPublisher(
        messages: [ChatMessage],
        params: LlmParams = .default,
        knowledgeContext: String = "",
        chatHistory: String = ""
    ) -> AnyPublisher<String, Error> {
        let subject = PassthroughSubject<String, Error>()

        guard let config = configRepository.getConfig() else {
            subject.send(completion: .failure(LlmError.noConfig))
            return subject.eraseToAnyPublisher()
        }

        guard let url = config.chatCompletionsUrl else {
            subject.send(completion: .failure(LlmError.invalidURL))
            return subject.eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = buildRequestBody(messages: messages, config: config, params: params, stream: true, knowledgeContext: knowledgeContext, chatHistory: chatHistory)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Cancel any in-flight streaming request to avoid leaks
        streamingSession?.invalidateAndCancel()
        streamingSession = nil

        let delegate = SSEDelegate(subject: subject)
        self.sseDelegate = delegate
        let taskSession = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        self.streamingSession = taskSession
        taskSession.dataTask(with: request).resume()

        return subject.handleEvents(receiveCancel: { [weak self] in
            self?.streamingSession?.invalidateAndCancel()
            self?.streamingSession = nil
        }).eraseToAnyPublisher()
    }

    // MARK: - iOS 15+ (async SSE streaming)

    @available(iOS 15.0, *)
    func chatStream(
        messages: [ChatMessage],
        params: LlmParams = .default,
        knowledgeContext: String = "",
        chatHistory: String = ""
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self = self else { return }

                guard let config = self.configRepository.getConfig() else {
                    continuation.finish(throwing: LlmError.noConfig)
                    return
                }

                guard let url = config.chatCompletionsUrl else {
                    continuation.finish(throwing: LlmError.invalidURL)
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let body = self.buildRequestBody(
                    messages: messages, config: config, params: params, stream: true,
                    knowledgeContext: knowledgeContext, chatHistory: chatHistory
                )
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        continuation.finish(throwing: LlmError.httpError(code, "HTTP error"))
                        return
                    }

                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let data = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            if data == "[DONE]" { break }
                            if let jsonData = data.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let choices = json["choices"] as? [[String: Any]],
                               let delta = choices.first?["delta"] as? [String: Any],
                               let content = delta["content"] as? String,
                               !content.isEmpty {
                                continuation.yield(content)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Non-streaming (used by test connection)

    func chat(
        messages: [ChatMessage],
        params: LlmParams = .default,
        knowledgeContext: String = "",
        chatHistory: String = ""
    ) -> AnyPublisher<String, Error> {
        Future<String, Error> { [weak self] promise in
            guard let self = self else { return }

            guard let config = self.configRepository.getConfig() else {
                promise(.failure(LlmError.noConfig))
                return
            }

            guard let url = config.chatCompletionsUrl else {
                promise(.failure(LlmError.invalidURL))
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body = self.buildRequestBody(
                messages: messages, config: config, params: params, stream: false,
                knowledgeContext: knowledgeContext, chatHistory: chatHistory
            )
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    promise(.failure(LlmError.networkError(error.localizedDescription)))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    promise(.failure(LlmError.networkError("无效响应")))
                    return
                }

                guard (200...299).contains(httpResponse.statusCode),
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    let errorBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "未知错误"
                    promise(.failure(LlmError.httpError(httpResponse.statusCode, errorBody)))
                    return
                }

                promise(.success(content))
            }.resume()
        }.eraseToAnyPublisher()
    }

    // MARK: - Private Helpers

    private func buildRequestBody(
        messages: [ChatMessage],
        config: LlmConfig,
        params: LlmParams,
        stream: Bool,
        knowledgeContext: String = "",
        chatHistory: String = ""
    ) -> [String: Any] {
        var msgArray: [[String: Any]] = []

        // System prompt with knowledge base context and chat history
        msgArray.append(["role": "system", "content": systemPrompt(knowledgeContext: knowledgeContext, chatHistory: chatHistory)])

        // Conversation messages
        for msg in messages {
            msgArray.append(["role": msg.role.value, "content": msg.content])
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": msgArray,
            "stream": stream,
            "max_tokens": params.maxTokens,
            "temperature": params.temperature,
            "top_p": params.topP,
        ]

        if config.enableSearch && config.supportsWebSearch {
            body["enable_search"] = true
        }

        return body
    }
}

// MARK: - SSE Delegate (iOS 14 path)

private class SSEDelegate: NSObject, URLSessionDataDelegate {
    private let subject: PassthroughSubject<String, Error>
    private var dataBuffer = ""

    init(subject: PassthroughSubject<String, Error>) {
        self.subject = subject
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        dataBuffer += text

        // Process complete lines
        while let newlineRange = dataBuffer.range(of: "\n") {
            let line = String(dataBuffer[..<newlineRange.lowerBound])
            dataBuffer = String(dataBuffer[newlineRange.upperBound...])

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("data: ") {
                let dataStr = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if dataStr == "[DONE]" {
                    subject.send(completion: .finished)
                    return
                }
                if let jsonData = dataStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String,
                   !content.isEmpty {
                    subject.send(content)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                // Task was cancelled — send .finished so downstream subscribers complete.
                subject.send(completion: .finished)
            } else {
                subject.send(completion: .failure(error))
            }
        } else {
            subject.send(completion: .finished)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            subject.send(completion: .failure(LlmError.httpError(code, "HTTP error")))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }
}
