//
//  BehaviorEngine.swift
//  Avatar
//
//  Neutral conversation engine — fallback when no LLM is configured.
//  Ported from Android: BehaviorEngine.kt
//

import Foundation

class BehaviorEngine {

    /// Neutral greetings
    private let greetings = [
        "您好，我是燃气客服小燃，有什么可以帮您的？",
        "您好，小燃为您服务，请问有什么需要？",
        "您好，请问有什么燃气方面的问题需要咨询？",
        "您好，随时为您服务，请说。",
        "您好，有什么想问的吗？",
    ]

    /// Fallback when no keywords match
    private let fallbacks = [
        "这个问题我还在学习中呢，我一定更加努力，为您提供更优质的服务。如需人工服务，请点击链接，转接人工处理。",
        "不好意思，这个我需要查一下，您稍等。",
        "抱歉，我可能需要更多信息才能回答您的问题。",
        "这个问题超出了我的知识范围，建议您转接人工客服处理。",
        "我不太确定，您可以换个方式描述一下问题吗？",
    ]

    /// Keyword → neutral response
    private func keywordResponse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords: [String: [String]] = [
            "你好": ["您好！", "您好，请问有什么可以帮您的？", "您好，我是燃气客服小燃。"],
            "再见": ["再见，如有燃气问题随时联系我们。", "再见，祝您生活愉快！"],
            "谢谢": ["不客气，很高兴为您服务。", "不用谢，有需要随时找我。", "应该的，祝您生活愉快。"],
            "名字": ["我叫小燃，是您的燃气客服助手。", "我是小燃，燃气公司的智能客服。"],
            "天气": ["是呀，心情都跟着变好了呢！您有燃气方面的问题随时告诉我哈～", "天气不错呢！有什么燃气业务需要咨询吗？"],
            "开心": ["开心就好！有什么燃气方面的问题可以随时问我。", "心情好最重要！"],
            "难过": ["别难过，希望我能帮到您。有什么燃气问题需要处理吗？"],
            "无聊": ["那正好，有什么燃气业务需要办理的吗？我帮您查查～"],
            "累": ["辛苦了，注意休息。燃气方面的事情交给我来查就行。", "注意身体哦！"],
            "爱": ["感谢您的认可。", "谢谢您的支持。"],
            "讲笑话": ["我不太擅长讲笑话呢，不过燃气业务方面的问题我比较在行～"],
            "燃气": ["请问您具体想了解什么？气费、营业厅还是维修进度呢？"],
            "缴费": ["请问您是想了解缴费方式，还是查询账单呢？"],
            "营业厅": ["请问您在哪个城市呢？我帮您查询当地的营业厅地址。"],
        ]

        for (keyword, responses) in keywords {
            if trimmed.contains(keyword) {
                return responses.randomElement()
            }
        }
        return nil
    }

    /// Emotion detection from keywords
    private let emotionKeywords: [Emotion: [String]] = [
        .happy:     ["开心", "高兴", "好棒", "太好了", "喜欢", "耶", "谢谢"],
        .sad:       ["难过", "伤心", "哭", "不开心", "难受", "烦恼", "生气", "投诉"],
        .surprised: ["哇", "天哪", "不会吧", "真的吗", "什么"],
    ]

    /// Process user input → robot response text + updated emotion.
    func respond(_ userText: String) -> (String, Emotion) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ("嗯？我没听清，可以再说一遍吗？", .curious)
        }

        // Check keyword matches
        if let response = keywordResponse(trimmed) {
            return (response, detectEmotion(trimmed))
        }

        // Fallback
        return (fallbacks.randomElement()!, detectEmotion(trimmed))
    }

    /// What to say when the app opens / user taps for interaction.
    func onWakeUp() -> String {
        return greetings.randomElement()!
    }

    /// What to say when a face first appears after a gap. (kept for compat)
    func onFaceAppear() -> String {
        return greetings.randomElement()!
    }

    /// What to say when face disappears. (kept for compat)
    func onFaceDisappear() -> String? {
        if Float.random(in: 0..<1) < 0.3 {
            return ["还在吗？", "你去哪了？", "嗯...还在吗？"].randomElement()!
        }
        return nil
    }

    /// Random remark — for idle antics.
    /// Returns nil ~70% of the time so it doesn't get annoying.
    func randomAntic() -> String? {
        if Float.random(in: 0..<1) < 0.7 { return nil }
        return [
            "有燃气方面的问题随时叫我。",
            "我在呢，有什么可以帮您的？",
            "需要帮忙查气费或营业厅的话直接说就行。",
            "有需要的话喊我一声。",
        ].randomElement()
    }

    /// Detect emotion from user text.
    private func detectEmotion(_ text: String) -> Emotion {
        for (emotion, keywords) in emotionKeywords {
            for kw in keywords {
                if text.contains(kw) { return emotion }
            }
        }
        return .neutral
    }
}
