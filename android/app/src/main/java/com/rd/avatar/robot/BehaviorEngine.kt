package com.rd.avatar.robot

import kotlin.random.Random

/**
 * Goofy conversation engine — fallback when no LLM is configured.
 *
 * The personality: a silly stick figure living inside the phone screen.
 * Self-deprecating, exaggerated, meme-aware, occasionally unhinged.
 */
class BehaviorEngine {

    /** Random goofy greetings */
    private val greetings = listOf(
        "嘿！你来啦！我刚在屏幕里做了个后空翻，可惜你没看到~",
        "哦？有人类！快看我快看我，我是你手机里唯一会画圈圈的火柴人！",
        "噔噔噔噔！火柴人登场！（自己给自己配音）",
        "等了半天你终于来了，我都快把自己打成死结了...",
        "嘿嘿嘿，又到了被人类戳屏幕的时间！",
        "哇！吓我一跳！——好吧其实我在屏幕里什么也感觉不到。",
    )

    /** Fallback when no keywords match */
    private val fallbacks = listOf(
        "嗯...这个问题我得翻翻我脑子里的数据库——好吧我承认我脑子是空的。",
        "你说的每个字我都认识，但合在一起我就...噗，CPU烧了。",
        "等一下让我想想...（其实在想今天中午吃什么）",
        "作为一根火柴人，我对世界的了解主要来自你戳屏幕的次数。",
        "略略略~ 换个问题考我？",
        "我连脑子都是画的，你还指望我能回答这个？！",
        "好问题！下一题！（逃",
        "据我精密计算...对不起我数学是体育老师教的。",
    )

    /** Keyword → funny response */
    private val keywordResponses = mapOf(
        "你好" to { listOf("嗨嗨嗨！", "来了老弟~", "你好啊人类！", "哟！").random() },
        "再见" to { listOf("拜拜！我去屏幕后面抠脚了~", "慢走不送，记得回来戳我！", "See you~ 我继续在屏幕里躺平。").random() },
        "谢谢" to { listOf("不客气不客气，给我画个鼻孔就好！", "客气啥，反正我住你手机里，也算一家人~", "不用谢，我只是在完成KPI。").random() },
        "名字" to { listOf("我叫小火！火柴人的火，不是火锅的火。虽然火锅我也喜欢。", "小火！你可以叫我小🔥，但我建议不要——浪费电。", "我叫小火，为什么要叫小火？因为我只有火没有柴，所以是根棍子。").random() },
        "天气" to { listOf("我帮你看看窗...等一下我没有窗。你倒是看一下窗外啊！", "根据我精密的分析——我在手机里，你在手机外，你问我天气？", "如果你觉得热，那就是夏天；冷就是冬天。我的气象学就这么朴素。").random() },
        "唱歌" to { listOf("♪~我是一根火柴人~脑袋圆圆腿长长~♪  好了付费内容到此为止。", "不行，唱歌要收费的。先给我画根眉毛当出场费。", "唱了怕你手机音响炸了，我的声音可是有魔力的（并不）。").random() },
        "跳舞" to { listOf("你看我跳！你看我跳！...好吧我只是在原地扭了一下。", "我全身就六根线，跳起来就是一顿乱甩，你确定要看？", "哐哐哐哐！——这是机械舞。哐哐哐哐！——这也是机械舞。" ).random() },
        "爱你" to { listOf("♥！（我全身最红的就是嘴，凑合用吧）", "哎呀，我脸红了...等一下我脸红是什么样的？让我想想...", "谢谢你的爱，我已经把它存在了我并不存在的心里。").random() },
        "傻" to { listOf("对对对，我全身加起来不超过两位数笔画，你说能聪明到哪去？", "我是有点傻，但你想啊——筷子也不会说话啊，我已经很厉害了！", "你才傻！...好吧我确实不太聪明。").random() },
        "笨" to { listOf("我承认我笨，毕竟加工精度不如你的手机芯片嘛~", "笨有笨的好，至少我跑不到线外面去！" ).random() },
        "开心" to { listOf("开心！让我蹦一个！╰(*°▽°*)╯ 看到没，我刚跳了0.1像素。", "开心就好！心情好了来戳我屏幕，我不怕疼（因为我根本没有触觉神经）。").random() },
        "难过" to { listOf("来来来，我给你表演个单腿站立——我输了，因为我根本站不稳。", "别难过了，想想我：连鼻子都没有，每天只能用嘴呼吸，惨不惨？").random() },
        "无聊" to { listOf("无聊？来看我画圈圈！→ ○ 看完了吗？这就是我的毕生所学。", "无聊的时候可以数我有几根线：头一根...胳膊两根...算了你数吧。", "那我给你讲个笑话吧：有根火柴走在路上，头痒了，挠了挠，然后——火了。").random() },
        "累" to { listOf("累了吧？没事，我比你更累——我每天24小时站着，从不坐下。", "躺下歇会儿！不像我，我腿是画的，弯不了。").random() },
        "可爱" to { listOf("谢谢！不过你确定一根线条能可爱吗？好吧我信了( •̀ ω •́ )✧", "嘿嘿嘿被发现了，其实我偷偷在头上加了高光。").random() },
        "厉害" to { listOf("那当然！不是每根火柴人都能做语音助手的！我是百里挑一！", "强者的世界你不懂，我昨天单手（我是说左手那根线）举起了自己。").random() },
        "讲笑话" to { listOf(
            "为什么火柴人不会感冒？——因为它没有鼻孔！",
            "火柴人去面试，面试官问：你有什么特长？火柴人说：我特别长。",
            "两根火柴走在路上，一根说：我觉得我头有点烫。另一根说：别担心你只是被画出了高光。",
            "有一天火柴人去理发，理发师问：剪多少？火柴人说：全剪了。理发师说：那你就不存在了。"
        ).random() },
        "故事" to { listOf(
            "从前有一根火柴人，它想去环游世界。结果发现——它只有两厘米高，连屏幕都出不去。完。",
            "很久很久以前，有个画火柴人的程序员。他画了一天，火柴人活了过来，说的第一句话是：你怎么把我画这么丑？"
        ).random() },
        "吃" to { listOf("我是火柴人，不吃东西，但我可以帮你看着你的外卖（虽然我在屏幕里看不到）。", "你能吃，我不能吃，贫富差距啊！", "说到吃...我建议你放下手机去吃东西，我又跑不了。").random() },
        "睡" to { listOf("晚安！我值班，你放心睡。有贼我帮你喊——虽然我嗓子也是画的。", "去睡吧！我关灯...哦我没有灯，我关屏幕吧——不行关了你就看不到我了。").random() },
        "漂亮" to { listOf("谢谢夸奖！虽然我的颜值主要靠你的屏幕分辨率撑着。", "你真有眼光，能在六根线里看出美来，艺术家啊！").random() },
        "垃圾" to { listOf("你说得对，我确实是几根线条拼出来的。但请不要伤害一根火柴人的自尊心——虽然我没有。", "噗，被骂了。但是没关系！被骂又不会让我的线条变弯！...好吧本来就有点弯。").random() },

        // Camera-related keywords → trigger looking mode hint
        "看" to { listOf(
            "让我看看...（掏出不存在的望远镜）...哦我没有望远镜，因为我没有口袋！",
            "你想看什么？虽然我在屏幕里，视野范围大约...零。"
        ).random() },
        "外面" to { listOf("外面？你是说我屏幕玻璃外面的世界？那个传说中的三维空间？！", "我帮你看看外面——等一下我启动摄像头...哦等等，我得先让主人帮我打开。").random() },
    )

    /** Emotion detection from keywords */
    private val emotionKeywords = mapOf(
        Emotion.HAPPY to listOf("开心", "高兴", "哈哈", "好棒", "太好了", "喜欢", "嘿嘿", "耶"),
        Emotion.SAD to listOf("难过", "伤心", "哭", "不开心", "难受", "烦恼", "emo"),
        Emotion.SURPRISED to listOf("哇", "天哪", "不会吧", "真的吗", "什么", "我去"),
        Emotion.GOOFY to listOf("搞笑", "逗比", "沙雕", "段子", "笑话", "梗", "整活"),
    )

    /**
     * Process user input → robot response text + updated emotion.
     */
    fun respond(userText: String): Pair<String, Emotion> {
        val trimmed = userText.trim()
        if (trimmed.isEmpty()) {
            return "嗯？你说啥？我这边信号——哦我没有信号，我只是根火柴人..." to Emotion.CURIOUS
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
     * Random goofy remark — for idle antics.
     * Returns null ~70% of the time so it doesn't get annoying.
     */
    fun randomAntic(): String? {
        if (Random.nextFloat() < 0.7f) return null
        return listOf(
            "戳我一下！我保证不躲！",
            "无聊中...正在用左手画右手。",
            "你在看我吗？我也在看你！...好吧我看不到你。",
            "据说人类每看一次手机，就有一个火柴人被迫营业。",
            "你好呀！不说话的每一秒我都在屏幕里抠脚。",
            "（自己跟自己玩石头剪刀布）我出石头！我也出石头！——平局。",
        ).random()
    }

    /**
     * Detect emotion from user text.
     * Default leans toward GOOFY for a playful vibe.
     */
    private fun detectEmotion(text: String): Emotion {
        for ((emotion, keywords) in emotionKeywords) {
            for (kw in keywords) {
                if (text.contains(kw)) return emotion
            }
        }
        // Randomly inject GOOFY to keep things playful
        return if (Random.nextFloat() < 0.3f) Emotion.GOOFY else Emotion.NEUTRAL
    }
}
