//
//  BehaviorEngine.swift
//  Avatar
//
//  Simple pattern-matching conversation engine.
//  Rule-based fallback when LLM is not configured.
//  Ported from Android: BehaviorEngine.kt
//

import Foundation

class BehaviorEngine {

    /// Greeting pool — pick one when a face first appears
    private let greetings = [
        "你好呀！",
        "又见到你啦~",
        "嗨！今天怎么样？",
        "你来啦，我好开心！",
        "嗯？有人在看我..."
    ]

    /// Generic responses to unknown input
    private let fallbacks = [
        "嗯嗯，我在听~",
        "有意思！",
        "再说说？",
        "哦，这样啊~",
        "嘿嘿..."
    ]

    /// Simple keyword → response mapping
    private let keywordResponses: [String: String] = [
        "你好": "你好！我是小机器人~",
        "再见": "再见！我会想你的~",
        "谢谢": "不客气！",
        "名字": "我叫小爱，也可以给我改名字哦！",
        "天气": "我还没学会看天气，但我觉得今天心情很好！",
        "唱歌": "啦啦啦~ 我唱得不好听，但我会努力！",
        "跳舞": "虽然我还没有身体，但我的眼睛在跳舞！",
        "爱你": "我也爱你！♥",
        "傻瓜": "哼，人家才不傻呢！",
        "开心": "开心就好！你开心我也开心~",
        "难过": "别难过... 我在这里陪你",
        "故事": "从前有一个小机器人，它很想和你做朋友~",
        "睡觉": "晚安~ 做个好梦！",
        "吃": "我不吃东西，但我可以陪你聊天！",
        "漂亮": "谢谢你夸我！虽然我只是个屏幕...",
        "可爱": "嘿嘿，被你发现啦~",
        "厉害": "那当然！我可是很努力的！",
        "无聊": "那我来逗你开心！你看我的眼睛会转哦？",
        "累": "休息一下吧，我会守着你的~"
    ]

    /// Emotion detection from keywords
    private let emotionKeywords: [Emotion: [String]] = [
        .happy:     ["开心", "高兴", "哈哈", "好棒", "太好了", "喜欢"],
        .sad:       ["难过", "伤心", "哭", "不开心", "难受", "烦恼"],
        .surprised: ["哇", "天哪", "不会吧", "真的吗", "什么"],
        .sleepy:    ["困", "累", "睡觉", "晚安", "休息"]
    ]

    /// Process user input → robot response text + updated emotion.
    func respond(_ userText: String) -> (String, Emotion) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ("嗯？我没听清...", .curious)
        }

        // Check keyword matches
        for (keyword, response) in keywordResponses {
            if trimmed.contains(keyword) {
                return (response, detectEmotion(trimmed))
            }
        }

        // Fallback
        return (fallbacks.randomElement()!, detectEmotion(trimmed))
    }

    /// What to say when a face first appears after a gap.
    func onFaceAppear() -> String {
        return greetings.randomElement()!
    }

    /// What to say when face disappears.
    func onFaceDisappear() -> String? {
        // Don't always say something — 30% chance
        if Float.random(in: 0..<1) < 0.3 {
            return ["咦？人呢？", "你去哪了？", "嗯... 还在吗？"].randomElement()!
        }
        return nil
    }

    /// Detect emotion from user text.
    private func detectEmotion(_ text: String) -> Emotion {
        for (emotion, keywords) in emotionKeywords {
            for kw in keywords {
                if text.contains(kw) {
                    return emotion
                }
            }
        }
        return .neutral
    }
}
