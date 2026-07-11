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
        "你好，有什么可以帮你的？",
        "嗨，我在呢。",
        "你好，请说。",
        "在的，有什么需要吗？",
        "你好，随时为你服务。",
        "嗨，有什么想问的吗？",
    ]

    /// Fallback when no keywords match
    private let fallbacks = [
        "这个问题我暂时不太了解。",
        "不好意思，这个我不太清楚。",
        "抱歉，我可能需要更多信息才能回答。",
        "让我想想...这个我不太确定。",
        "这个问题超出了我的知识范围。",
        "我不太确定，换个问题试试？",
        "抱歉，我无法回答这个问题。",
        "这个我还不太了解。",
    ]

    /// Keyword → neutral response
    private func keywordResponse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords: [String: [String]] = [
            "你好": ["你好！", "你好啊！", "嗨，你好！", "你好，有什么可以帮你的？"],
            "再见": ["再见！", "拜拜，回头见。", "下次见！"],
            "谢谢": ["不客气。", "不用谢。", "应该的。"],
            "名字": ["我叫小火。", "我是小火，你的语音助手。", "我叫小火，很高兴认识你。"],
            "天气": ["建议查看一下天气预报，我暂时无法获取实时天气数据。", "天气情况建议查询当地气象信息。"],
            "开心": ["开心就好！", "那挺好的。", "心情好就是最好的状态。"],
            "难过": ["别难过，会好起来的。", "需要聊聊吗？我在这儿呢。", "有时候倾诉一下会好受些。"],
            "无聊": ["可以找点感兴趣的事情做做。", "要不要听首歌或者看个视频？", "无聊的时候可以出去走走。"],
            "累": ["好好休息一下。", "注意身体，适当放松。", "累了就歇会儿。"],
            "可爱": ["谢谢！", "谢谢你。"],
            "厉害": ["谢谢夸奖。", "过奖了。"],
            "爱你": ["谢谢你的喜欢。", "感谢。"],
            "吃": ["按时吃饭很重要。", "注意饮食健康。"],
            "睡": ["早点休息，晚安。", "保证充足的睡眠很重要。"],
            "讲笑话": ["抱歉，我不太擅长讲笑话。", "这个我不太拿手。"],
            "故事": ["抱歉，我没什么故事可讲。", "这个不太擅长。"],
            "看": ["你想看什么？", "需要我帮你查什么吗？"],
            "外面": ["外面的世界很精彩。", "可以出去走走看看。"],
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
        .happy:     ["开心", "高兴", "哈哈", "好棒", "太好了", "喜欢", "耶"],
        .sad:       ["难过", "伤心", "哭", "不开心", "难受", "烦恼", "emo"],
        .surprised: ["哇", "天哪", "不会吧", "真的吗", "什么", "我去"],
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
            "有什么需要随时叫我。",
            "我在呢，有什么想问的吗？",
            "需要帮忙的话直接说就行。",
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
