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

    private func systemPrompt(enableSearch: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 EEEE"
        let now = df.string(from: Date())
        let base = "你是一个语音助手，名字叫「小火」。用简短口语化的中文回复，控制在1-3句话（80字以内）。" +
            "只回应用户说的话，不要主动提供额外信息（如日期、天气等），除非用户明确问了。" +
            "回复自然友好、直接明了，保持中性的语气。" +
            "当前日期是\(now)（仅当你需要判断时间时参考，不要主动报日期）。" +
            "这是一段持续的多轮对话。下面 messages 中 role=user 是人类对你说的，role=assistant 是你自己说过的。" +
            "你要记住之前聊过的话题，可以自然地引用前面说过的话。" +
            "始终保持一致的助手风格。"
        if enableSearch {
            return base +
                "你已启用联网搜索，获取到的实时信息会直接提供给你。" +
                "对于需要最新数据的问题，务必基于搜索结果回答。" +
                "严禁说你无法搜索或不支持联网——搜索是系统自动完成的。"
        } else {
            return base +
                "如果用户问到你不了解的事，直接说不知道即可。"
        }
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
        params: LlmParams = .default
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

        let body = buildRequestBody(messages: messages, config: config, params: params, stream: true)
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
        params: LlmParams = .default
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
                    messages: messages, config: config, params: params, stream: true
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
        params: LlmParams = .default
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
                messages: messages, config: config, params: params, stream: false
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
        stream: Bool
    ) -> [String: Any] {
        var msgArray: [[String: Any]] = []

        // System prompt
        msgArray.append(["role": "system", "content": systemPrompt(enableSearch: config.enableSearch)])

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
