package com.mobilerobot.app.robot

import com.mobilerobot.app.camera.FaceDetectionResult
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlin.random.Random

/**
 * Simple pattern-matching conversation engine.
 *
 * In a future iteration, replace with an LLM backend (GPT / Claude API,
 * or on-device Gemma / Llama). For now, this is a rule-based responder
 * that makes the robot feel alive.
 */
class BehaviorEngine {

    /** Greeting pool — pick one when a face first appears */
    private val greetings = listOf(
        "你好呀！",
        "又见到你啦~",
        "嗨！今天怎么样？",
        "你来啦，我好开心！",
        "嗯？有人在看我..."
    )

    /** Generic responses to unknown input */
    private val fallbacks = listOf(
        "嗯嗯，我在听~",
        "有意思！",
        "再说说？",
        "哦，这样啊~",
        "嘿嘿..."
    )

    /** Simple keyword → response mapping */
    private val keywordResponses = mapOf(
        "你好" to { "你好！我是小机器人~" },
        "再见" to { "再见！我会想你的~" },
        "谢谢" to { "不客气！" },
        "名字" to { "我叫小爱，也可以给我改名字哦！" },
        "天气" to { "我还没学会看天气，但我觉得今天心情很好！" },
        "唱歌" to { "啦啦啦~ 我唱得不好听，但我会努力！" },
        "跳舞" to { "虽然我还没有身体，但我的眼睛在跳舞！" },
        "爱你" to { "我也爱你！♥" },
        "傻瓜" to { "哼，人家才不傻呢！" },
        "开心" to { "开心就好！你开心我也开心~" },
        "难过" to { "别难过... 我在这里陪你" },
        "故事" to { "从前有一个小机器人，它很想和你做朋友~" },
        "睡觉" to { "晚安~ 做个好梦！" },
        "吃" to { "我不吃东西，但我可以陪你聊天！" },
        "漂亮" to { "谢谢你夸我！虽然我只是个屏幕..." },
        "可爱" to { "嘿嘿，被你发现啦~" },
        "厉害" to { "那当然！我可是很努力的！" },
        "无聊" to { "那我来逗你开心！你看我的眼睛会转哦？" },
        "累" to { "休息一下吧，我会守着你的~" }
    )

    /** Emotion detection from keywords */
    private val emotionKeywords = mapOf(
        Emotion.HAPPY to listOf("开心", "高兴", "哈哈", "好棒", "太好了", "喜欢"),
        Emotion.SAD to listOf("难过", "伤心", "哭", "不开心", "难受", "烦恼"),
        Emotion.SURPRISED to listOf("哇", "天哪", "不会吧", "真的吗", "什么"),
        Emotion.SLEEPY to listOf("困", "累", "睡觉", "晚安", "休息"),
    )

    /**
     * Process user input → robot response text + updated emotion.
     */
    fun respond(userText: String): Pair<String, Emotion> {
        val trimmed = userText.trim()
        if (trimmed.isEmpty()) {
            return "嗯？我没听清..." to Emotion.CURIOUS
        }

        // Check keyword matches
        for ((keyword, responseFn) in keywordResponses) {
            if (trimmed.contains(keyword)) {
                return responseFn() to detectEmotion(trimmed)
            }
        }

        // Fallback
        return fallbacks.random() to detectEmotion(trimmed)
    }

    /**
     * What to say when a face first appears after a gap.
     */
    fun onFaceAppear(): String {
        return greetings.random()
    }

    /**
     * What to say when face disappears.
     */
    fun onFaceDisappear(): String? {
        // Don't always say something — maybe 30% chance
        return if (Random.nextFloat() < 0.3f) {
            listOf("咦？人呢？", "你去哪了？", "嗯... 还在吗？").random()
        } else null
    }

    /**
     * Detect emotion from user text.
     */
    private fun detectEmotion(text: String): Emotion {
        for ((emotion, keywords) in emotionKeywords) {
            for (kw in keywords) {
                if (text.contains(kw)) return emotion
            }
        }
        return Emotion.NEUTRAL
    }
}
