package com.rd.avatar.robot

import kotlin.random.Random

/**
 * Neutral conversation engine — fallback when no LLM is configured.
 */
class BehaviorEngine {

    /** Neutral greetings */
    private val greetings = listOf(
        "你好，有什么可以帮你的？",
        "嗨，我在呢。",
        "你好，请说。",
        "在的，有什么需要吗？",
        "你好，随时为你服务。",
        "嗨，有什么想问的吗？",
    )

    /** Fallback when no keywords match */
    private val fallbacks = listOf(
        "这个问题我暂时不太了解。",
        "不好意思，这个我不太清楚。",
        "抱歉，我可能需要更多信息才能回答。",
        "让我想想...这个我不太确定。",
        "这个问题超出了我的知识范围。",
        "我不太确定，换个问题试试？",
        "抱歉，我无法回答这个问题。",
        "这个我还不太了解。",
    )

    /** Keyword → neutral response */
    private val keywordResponses = mapOf(
        "你好" to { listOf("你好！", "你好啊！", "嗨，你好！", "你好，有什么可以帮你的？").random() },
        "再见" to { listOf("再见！", "拜拜，回头见。", "下次见！").random() },
        "谢谢" to { listOf("不客气。", "不用谢。", "应该的。").random() },
        "名字" to { listOf("我叫小火。", "我是小火，你的语音助手。", "我叫小火，很高兴认识你。").random() },
        "天气" to { listOf("建议查看一下天气预报，我暂时无法获取实时天气数据。", "天气情况建议查询当地气象信息。").random() },
        "开心" to { listOf("开心就好！", "那挺好的。", "心情好就是最好的状态。").random() },
        "难过" to { listOf("别难过，会好起来的。", "需要聊聊吗？我在这儿呢。", "有时候倾诉一下会好受些。").random() },
        "无聊" to { listOf("可以找点感兴趣的事情做做。", "要不要听首歌或者看个视频？", "无聊的时候可以出去走走。").random() },
        "累" to { listOf("好好休息一下。", "注意身体，适当放松。", "累了就歇会儿。").random() },
        "可爱" to { listOf("谢谢！", "谢谢你。").random() },
        "厉害" to { listOf("谢谢夸奖。", "过奖了。").random() },
        "爱你" to { listOf("谢谢你的喜欢。", "感谢。").random() },
        "吃" to { listOf("按时吃饭很重要。", "注意饮食健康。").random() },
        "睡" to { listOf("早点休息，晚安。", "保证充足的睡眠很重要。").random() },
        "讲笑话" to { listOf("抱歉，我不太擅长讲笑话。", "这个我不太拿手。").random() },
        "故事" to { listOf("抱歉，我没什么故事可讲。", "这个不太擅长。").random() },

        // Camera-related keywords → trigger looking mode hint
        "看" to { listOf("你想看什么？", "需要我帮你查什么吗？").random() },
        "外面" to { listOf("外面的世界很精彩。", "可以出去走走看看。").random() },
    )

    /** Emotion detection from keywords */
    private val emotionKeywords = mapOf(
        Emotion.HAPPY to listOf("开心", "高兴", "哈哈", "好棒", "太好了", "喜欢", "耶"),
        Emotion.SAD to listOf("难过", "伤心", "哭", "不开心", "难受", "烦恼", "emo"),
        Emotion.SURPRISED to listOf("哇", "天哪", "不会吧", "真的吗", "什么", "我去"),
    )

    /**
     * Process user input → robot response text + updated emotion.
     */
    fun respond(userText: String): Pair<String, Emotion> {
        val trimmed = userText.trim()
        if (trimmed.isEmpty()) {
            return "嗯？我没听清，可以再说一遍吗？" to Emotion.CURIOUS
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
     * What to say when the app opens / user taps for interaction.
     */
    fun onWakeUp(): String {
        return greetings.random()
    }

    /**
     * Random remark — for idle antics.
     * Returns null ~70% of the time so it doesn't get annoying.
     */
    fun randomAntic(): String? {
        if (Random.nextFloat() < 0.7f) return null
        return listOf(
            "有什么需要随时叫我。",
            "我在呢，有什么想问的吗？",
            "需要帮忙的话直接说就行。",
            "有需要的话喊我一声。",
        ).random()
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
