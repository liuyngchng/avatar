//
//  ConfigViewModel.swift
//  SiriApp
//
//  Settings ViewModel: save / test / clear config.
//  Ported from Android: ConfigViewModel.kt
//

import Foundation
import Combine

enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}

class ConfigViewModel: ObservableObject {
    @Published var config: LlmConfig?
    @Published var testResult: ConnectionTestState = .idle

    private let repository = ConfigRepository()

    init() {
        config = repository.getConfig()
    }

    func saveConfig(_ apiUrl: String, _ model: String, _ apiKey: String, _ embeddingModel: String = "") {
        let trimmedUrl = apiUrl.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        let trimmedEmbedding = embeddingModel.trimmingCharacters(in: .whitespaces)

        guard !trimmedUrl.isEmpty, !trimmedModel.isEmpty, !trimmedKey.isEmpty else {
            testResult = .failure("所有字段不能为空")
            return
        }

        guard trimmedUrl.hasPrefix("http://") || trimmedUrl.hasPrefix("https://") else {
            testResult = .failure("API 地址必须以 http:// 或 https:// 开头")
            return
        }

        let newConfig = LlmConfig(
            apiUrl: trimmedUrl,
            model: trimmedModel,
            apiKey: trimmedKey,
            embeddingModel: trimmedEmbedding.isEmpty ? nil : trimmedEmbedding
        )
        repository.saveConfig(newConfig)
        config = newConfig
        testResult = .success("配置已保存")
    }

    func testConnection(_ apiUrl: String, _ model: String, _ apiKey: String, _ embeddingModel: String = "") {
        let trimmedUrl = apiUrl.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        let trimmedEmbedding = embeddingModel.trimmingCharacters(in: .whitespaces)

        guard !trimmedUrl.isEmpty, !trimmedModel.isEmpty, !trimmedKey.isEmpty else {
            testResult = .failure("请先填写完整信息")
            return
        }

        testResult = .testing

        // Test LLM first
        testLLMConnection(baseUrl: trimmedUrl, model: trimmedModel, apiKey: trimmedKey) { [weak self] llmResult in
            guard let self = self else { return }

            switch llmResult {
            case .failure(let msg):
                self.testResult = .failure("LLM API ✗\n\(msg)")
            case .success:
                // LLM OK, now test Embedding
                let embModel = trimmedEmbedding.isEmpty ? "text-embedding-v3" : trimmedEmbedding
                self.testEmbeddingConnection(baseUrl: trimmedUrl, model: embModel, apiKey: trimmedKey) { embResult in
                    switch embResult {
                    case .success:
                        self.testResult = .success("LLM API ✓  Embedding API ✓")
                    case .failure(let msg):
                        self.testResult = .success("LLM API ✓  Embedding API ✗\n\(msg)")
                    }
                }
            }
        }
    }

    // MARK: - Private: Individual API tests

    private func testLLMConnection(
        baseUrl: String,
        model: String,
        apiKey: String,
        completion: @escaping (TestResult) -> Void
    ) {
        guard let url = URL(string: "\(baseUrl)/chat/completions") else {
            completion(.failure("无效的 API 地址"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "hi"]
            ],
            "max_tokens": 1,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    let nsError = error as NSError
                    let message: String
                    switch nsError.code {
                    case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                        message = "无法连接到服务器"
                    case NSURLErrorTimedOut:
                        message = "连接超时"
                    case NSURLErrorServerCertificateUntrusted:
                        message = "SSL 证书验证失败"
                    default:
                        message = error.localizedDescription
                    }
                    completion(.failure(message))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure("无效的服务器响应"))
                    return
                }

                if (200...299).contains(httpResponse.statusCode) {
                    completion(.success)
                } else {
                    let errorBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "未知错误"
                    completion(.failure("HTTP \(httpResponse.statusCode): \(String(errorBody.prefix(200)))"))
                }
            }
        }.resume()
    }

    private func testEmbeddingConnection(
        baseUrl: String,
        model: String,
        apiKey: String,
        completion: @escaping (TestResult) -> Void
    ) {
        guard let url = URL(string: "\(baseUrl)/embeddings") else {
            completion(.failure("无效的 Embedding API 地址"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": model,
            "input": "test",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    let nsError = error as NSError
                    let message: String
                    switch nsError.code {
                    case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                        message = "无法连接到 Embedding 服务"
                    case NSURLErrorTimedOut:
                        message = "Embedding 连接超时"
                    case NSURLErrorServerCertificateUntrusted:
                        message = "SSL 证书验证失败"
                    default:
                        message = error.localizedDescription
                    }
                    completion(.failure(message))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure("无效的服务器响应"))
                    return
                }

                if (200...299).contains(httpResponse.statusCode) {
                    completion(.success)
                } else {
                    completion(.failure("HTTP \(httpResponse.statusCode)"))
                }
            }
        }.resume()
    }

    private enum TestResult {
        case success
        case failure(String)
    }

    func clearConfig() {
        repository.clearConfig()
        config = nil
        testResult = .idle
    }

    func resetTestResult() {
        testResult = .idle
    }
}
