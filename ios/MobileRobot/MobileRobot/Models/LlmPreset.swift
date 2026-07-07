//
//  LlmPreset.swift
//  SiriApp
//
//  Ported from Android: SettingsScreen.kt (LLM_PRESETS)
//

import Foundation

struct LlmPreset: Identifiable {
    let id = UUID()
    let name: String
    let apiUrl: String
    let model: String

    static let all: [LlmPreset] = [
        LlmPreset(
            name: "阿里百炼(Qwen)",
            apiUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen-plus"
        ),
        LlmPreset(
            name: "DeepSeek",
            apiUrl: "https://api.deepseek.com/v1",
            model: "deepseek-v4-flash"
        ),
        LlmPreset(
            name: "硅基流动",
            apiUrl: "https://api.siliconflow.cn/v1",
            model: "deepseek-ai/DeepSeek-V3"
        ),
    ]
}
