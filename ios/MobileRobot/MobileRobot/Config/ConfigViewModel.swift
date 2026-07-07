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

    func saveConfig(_ apiUrl: String, _ model: String, _ apiKey: String) {
        let trimmedUrl = apiUrl.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)

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
            apiKey: trimmedKey
        )
        repository.saveConfig(newConfig)
        config = newConfig
        testResult = .success("配置已保存")
    }

    func testConnection(_ apiUrl: String, _ model: String, _ apiKey: String) {
        let trimmedUrl = apiUrl.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)

        guard !trimmedUrl.isEmpty, !trimmedModel.isEmpty, !trimmedKey.isEmpty else {
            testResult = .failure("请先填写完整信息")
            return
        }

        testResult = .testing

        guard let url = URL(string: "\(trimmedUrl)/chat/completions") else {
            testResult = .failure("无效的 API 地址")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": trimmedModel,
            "messages": [
                ["role": "user", "content": "hi"]
            ],
            "max_tokens": 1,
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    let message: String
                    let nsError = error as NSError
                    switch nsError.code {
                    case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                        message = "无法连接到服务器，请检查 API 地址"
                    case NSURLErrorTimedOut:
                        message = "连接超时，请检查网络"
                    case NSURLErrorServerCertificateUntrusted:
                        message = "SSL 证书验证失败"
                    default:
                        message = "连接失败: \(error.localizedDescription)"
                    }
                    self?.testResult = .failure(message)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.testResult = .failure("无效的服务器响应")
                    return
                }

                if (200...299).contains(httpResponse.statusCode) {
                    self?.testResult = .success("连接成功！API 响应正常")
                } else {
                    let errorBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "未知错误"
                    self?.testResult = .failure(
                        "服务器返回错误 (\(httpResponse.statusCode)): \(String(errorBody.prefix(200)))"
                    )
                }
            }
        }.resume()
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
