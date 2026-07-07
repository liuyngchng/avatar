//
//  LlmConfig.swift
//  SiriApp
//
//  Ported from Android: LlmConfig.kt
//

import Foundation

struct LlmConfig: Codable, Equatable {
    let apiUrl: String
    let model: String
    let apiKey: String
    var enableSearch: Bool

    var baseUrl: String {
        apiUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var chatCompletionsUrl: URL? {
        URL(string: "\(baseUrl)/chat/completions")
    }

    var isValid: Bool {
        !apiUrl.isEmpty && !model.isEmpty && !apiKey.isEmpty
            && (apiUrl.hasPrefix("http://") || apiUrl.hasPrefix("https://"))
    }

    /// Whether this provider supports the `enable_search` parameter.
    var supportsWebSearch: Bool {
        apiUrl.contains("dashscope.aliyuncs.com")
    }

    init(apiUrl: String, model: String, apiKey: String, enableSearch: Bool = true) {
        self.apiUrl = apiUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.model = model.trimmingCharacters(in: .whitespaces)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
        // Bailian always supports web search
        let isBailian = self.apiUrl.contains("dashscope.aliyuncs.com")
        self.enableSearch = enableSearch || isBailian
    }
}
