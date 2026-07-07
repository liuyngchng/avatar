//
//  TextNormalizer.swift
//  SiriApp
//
//  Ported from Android: TextNormalizer.kt
//  Converts numbers/English to Chinese for TTS output.
//

import Foundation

enum TextNormalizer {

    // MARK: - Chinese Number Characters

    private static let chineseDigits: [Character] = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    private static let units: [Character] = ["\0", "十", "百", "千"]
    private static let wanUnits: [Character] = ["\0", "万", "亿"]

    // MARK: - English Letter Mapping

    private static func englishLetterToChinese(_ c: Character) -> String {
        switch c {
        case "a": return "诶"
        case "b": return "必"
        case "c": return "西"
        case "d": return "地"
        case "e": return "亿"
        case "f": return "艾夫"
        case "g": return "记"
        case "h": return "艾尺"
        case "i": return "爱"
        case "j": return "这"
        case "k": return "凯"
        case "l": return "艾欧"
        case "m": return "艾姆"
        case "n": return "恩"
        case "o": return "欧"
        case "p": return "批"
        case "q": return "克由"
        case "r": return "阿儿"
        case "s": return "艾斯"
        case "t": return "替"
        case "u": return "由"
        case "v": return "威"
        case "w": return "达不溜"
        case "x": return "艾克斯"
        case "y": return "歪"
        case "z": return "贼"
        default: return ""
        }
    }

    // MARK: - Substitution Dictionary

    private static let substitutions: [(String, String)] = {
        let pairs: [(String, String)] = [
            // Multi-word phrases (before single words)
            ("Due diligence", "尽职调查"),
            ("Term sheet", "投资条款"),
            ("Burn rate", "烧钱速度"),
            ("QR Code", "二维码"),
            ("Apple Watch", "苹果手表"),
            ("Nintendo Switch", "任天堂斯威奇"),

            // Cloud / DevOps
            ("Kubernetes", "酷博内提斯"),
            ("K8s", "酷八斯"),
            ("Docker", "道客"),
            ("DevOps", "德沃普斯"),
            ("Cloud-native", "云原生"),
            ("Serverless", "无服务"),
            ("Microservice", "微服务"),
            ("Container", "容器"),
            ("Orchestration", "编排"),
            ("Provisioning", "资源配置"),
            ("On-premise", "本地部署"),
            ("Deployment", "部署"),
            ("Rollback", "回滚"),
            ("Fallback", "回退"),
            ("Pipeline", "流水线"),
            ("Endpoint", "端点"),
            ("Payload", "数据载荷"),
            ("Middleware", "中间件"),
            ("Gateway", "网关"),
            ("Proxy", "代理"),
            ("Cache", "缓存"),
            ("Firewall", "防火墙"),
            ("Workflow", "工作流"),

            // SaaS models
            ("SaaS", "萨斯"),
            ("PaaS", "帕斯"),
            ("IaaS", "艾斯"),

            // Protocols
            ("RESTful", "瑞斯特佛"),
            ("GraphQL", "格拉夫口艾欧"),
            ("WebSocket", "韦伯索克特"),
            ("AJAX", "阿贾克斯"),
            ("OAuth", "欧奥斯"),
            ("SSL", "安全套接层"),
            ("TLS", "传输层安全"),
            ("SSH", "安全外壳"),
            ("DNS", "域名系统"),
            ("CDN", "内容分发"),
            ("FTP", "文件传输协议"),
            ("SMTP", "邮件传输协议"),
            ("TCP", "传输控制协议"),
            ("HTTP", "超文本传输协议"),
            ("HTTPS", "超文本传输安全协议"),

            // Version control
            ("GitHub", "吉特哈布"),
            ("GitLab", "吉特莱布"),
            ("Git", "吉特"),

            // Dev methodology
            ("Agile", "敏捷"),
            ("Scrum", "斯克拉姆"),
            ("Sprint", "斯普林特"),
            ("Backlog", "待办列表"),

            // Software engineering
            ("Singleton", "单例模式"),
            ("Factory", "工厂模式"),
            ("Observer", "观察者模式"),
            ("Framework", "框架"),
            ("Library", "库"),
            ("Plugin", "插件"),
            ("Patch", "补丁"),
            ("Hotfix", "热修复"),

            // Tech acronyms
            ("API", "接口"),
            ("SDK", "软件开发包"),
            ("IDE", "集成开发环境"),
            ("DOM", "文档对象模型"),
            ("AI", "人工智能"),
            ("GPT", "生成式预训练"),
            ("LLM", "大语言模型"),
            ("OCR", "文字识别"),
            ("NLP", "自然语言处理"),

            // Hardware
            ("CPU", "处理器"),
            ("GPU", "图形处理器"),
            ("RAM", "内存"),
            ("ROM", "存储"),
            ("SSD", "固态硬盘"),
            ("HDD", "机械硬盘"),
            ("Lightning", "苹果接口"),
            ("LCD", "液晶屏"),
            ("HDR", "高动态范围"),
            ("NFC", "近场通信"),
            ("Bluetooth", "蓝牙"),

            // Resolution
            ("4K", "四开"),
            ("8K", "八开"),
            ("1080p", "一零八零批"),
            ("720p", "七二零批"),

            // Brands
            ("iPhone", "苹果手机"),
            ("iPad", "苹果平板"),
            ("MacBook", "苹果笔记本"),
            ("AirPods", "苹果耳机"),
            ("Mac", "苹果电脑"),
            ("Android", "安卓"),
            ("Kindle", "肯斗"),
            ("PlayStation", "游戏站"),
            ("Xbox", "艾克斯博克斯"),
            ("Nintendo", "任天堂"),
            ("Switch", "任天堂游戏机"),

            // Gaming
            ("DLC", "追加内容"),
            ("MOD", "模组"),
            ("MOBA", "多人在线竞技"),
            ("RPG", "角色扮演"),
            ("RTS", "即时战略"),
            ("Noob", "新手"),
            ("GG", "认输"),
            ("GLHF", "祝好运"),
            ("AFK", "暂时离开"),
            ("Lag", "卡顿"),

            // Internet slang
            ("LOL", "大笑"),
            ("OMG", "天哪"),
            ("BTW", "顺便说"),
            ("ASAP", "尽快"),
            ("FYI", "供参考"),
            ("TBD", "待定"),
            ("ETA", "预计时间"),
            ("IRL", "现实中"),
            ("DIY", "自己动手"),

            // C-suite
            ("CEO", "首席执行官"),
            ("CFO", "首席财务官"),
            ("CTO", "首席技术官"),
            ("COO", "首席运营官"),

            // Business
            ("HR", "人力资源"),
            ("PR", "公关"),
            ("BD", "商务拓展"),
            ("KPI", "关键绩效指标"),
            ("OKR", "目标与关键成果"),
            ("ROI", "投资回报率"),
            ("IPO", "上市"),
            ("VC", "风投"),
            ("PE", "私募股权"),
            ("NDA", "保密协议"),
            ("SOP", "标准操作流程"),
            ("BP", "商业计划书"),
            ("KOL", "意见领袖"),
            ("KOC", "关键消费者"),
            ("MCN", "多频道网络"),
            ("USP", "独特卖点"),
            ("Pivot", "业务转型"),
            ("Deck", "演示文稿"),
            ("Pitch", "项目推介"),
            ("Benchmark", "基准"),
            ("Traction", "增长势头"),
            ("Runway", "资金存续期"),
            ("Valuation", "估值"),
            ("Exit", "退出"),

            // Business models
            ("B2B", "企业对企业"),
            ("B2C", "企业对消费者"),
            ("C2C", "消费者对消费者"),
            ("O2O", "线上线下融合"),
            ("SOHO", "家居办公"),

            // Finance
            ("P&L", "损益表"),
            ("M&A", "并购"),

            // Daily life
            ("WiFi", "无线网"),
            ("Wi-Fi", "无线网"),
            ("GPS", "导航"),
            ("ATM", "自动取款机"),
            ("VIP", "贵宾"),
            ("PIN", "密码"),
            ("PPT", "幻灯片"),
            ("PDF", "便携文档"),
            ("Excel", "表格"),
            ("Word", "文档"),
            ("T-shirt", "体恤"),
            ("Jeans", "牛仔裤"),
            ("Sneakers", "运动鞋"),
            ("VR", "虚拟现实"),
            ("AR", "增强现实"),
            ("MR", "混合现实"),
            ("Party", "派对"),
            ("Buffet", "自助餐"),
            ("BBQ", "烧烤"),
            ("Cafe", "咖啡馆"),
            ("Shampoo", "洗发水"),
            ("Conditioner", "护发素"),
            ("Lotion", "润肤露"),
            ("Sunscreen", "防晒霜"),
            ("SPF", "防晒指数"),
            ("Mask", "面膜"),

            // Music
            ("Hip-hop", "嘻哈"),
            ("Rap", "说唱"),
            ("Pop", "流行乐"),
            ("Rock", "摇滚乐"),
            ("Jazz", "爵士"),
            ("DJ", "打碟师"),
            ("MC", "主持人"),
            ("VS", "对阵"),

            // Food
            ("Coffee", "咖啡"),
            ("Chocolate", "巧克力"),
            ("Salad", "沙拉"),
            ("Sandwich", "三明治"),
            ("Bacon", "培根"),
            ("Cherry", "车厘子"),
            ("Kiwi", "奇异果"),
            ("Mango", "芒果"),
            ("Pizza", "披萨"),
            ("Burger", "汉堡"),
            ("Toast", "吐司"),
            ("Whisky", "威士忌"),
            ("Brandy", "白兰地"),
            ("Cigar", "雪茄"),
            ("Radar", "雷达"),
            ("Laser", "激光"),
            ("Motor", "马达"),
            ("Neon", "霓虹"),
            ("Guitar", "吉他"),
            ("Ballet", "芭蕾"),
            ("Soda", "苏打"),
            ("Cacao", "可可"),
            ("Lemon", "柠檬"),

            // Misc
            ("OK", "好的"),
            ("NBA", "美职篮"),
            ("NASA", "纳萨"),
            ("IBM", "国际商业机器"),
            ("USB", "优盘"),
            ("HDMI", "高清线"),
            ("FIFA", "国际足联"),
            ("ID", "身份标识"),
            ("PC", "个人电脑"),
            ("FPS", "帧率"),
            ("Brainstorming", "头脑风暴"),
            ("Dating", "约会交友"),
            ("Toilet", "洗手间"),
            ("WC", "洗手间"),
        ]
        // Sort by key length descending for longest match first
        return pairs.sorted { $0.0.count > $1.0.count }
    }()

    // Pre-compiled structures
    private static let specialRegexes: [(NSRegularExpression, String)] = {
        var regexes: [(NSRegularExpression, String)] = []
        var words: [(String, String)] = []

        for (en, zh) in substitutions {
            if en.allSatisfy({ $0.isLetter }) {
                words.append((en.lowercased(), zh))
            } else {
                if let regex = try? NSRegularExpression(
                    pattern: "\\b\(NSRegularExpression.escapedPattern(for: en))\\b",
                    options: .caseInsensitive
                ) {
                    regexes.append((regex, zh))
                }
            }
        }

        // Sort words by length descending
        words.sort { $0.0.count > $1.0.count }

        // Build combined word regex
        if !words.isEmpty {
            let pattern = words.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")
            if let regex = try? NSRegularExpression(pattern: "\\b(\(pattern))\\b", options: .caseInsensitive) {
                // Store word map for replacement lookup
                let wordMap = Dictionary(uniqueKeysWithValues: words)
                regexes.append((regex, "__WORD_MAP__"))
                _pureWordMap = wordMap
            }
        }

        return regexes
    }()

    private static var _pureWordMap: [String: String] = [:]

    // MARK: - Number Conversion

    private static func digitsToChinese(_ s: String) -> String {
        s.map { c in
            if c.isNumber, let idx = c.wholeNumberValue {
                return String(chineseDigits[idx])
            }
            return String(c)
        }.joined()
    }

    private static func numberToChinese(_ numStr: String) -> String {
        guard let n = Int64(numStr) else { return digitsToChinese(numStr) }
        if n == 0 { return "零" }
        if n < 10 { return String(chineseDigits[Int(n)]) }

        let digits = Array(numStr)
        let len = digits.count
        var sb = ""

        for groupStart in stride(from: 0, to: len, by: 4) {
            let groupLen = min(4, len - groupStart)
            let groupEnd = groupStart + groupLen
            var groupSb = ""

            for i in groupStart..<groupEnd {
                let d = digits[i].wholeNumberValue!
                if d == 0 {
                    let allZeroAfter = ((i + 1)..<groupEnd).allSatisfy { digits[$0] == "0" }
                    if !allZeroAfter && !groupSb.isEmpty && groupSb.last != "零" {
                        groupSb.append("零")
                    }
                    continue
                }
                groupSb.append(chineseDigits[d])
                let unitIdx = groupEnd - i - 1
                if unitIdx > 0 { groupSb.append(units[unitIdx]) }
            }

            // Trim trailing 零
            while groupSb.last == "零" {
                groupSb.removeLast()
            }

            if !groupSb.isEmpty {
                sb += groupSb
                let wanIdx = (len - groupEnd) / 4
                if wanIdx > 0 { sb.append(wanUnits[wanIdx]) }
            }
        }

        // 一十 → 十
        if sb.hasPrefix("一十") {
            sb.removeFirst()
        }

        return sb
    }

    // MARK: - Sentence Splitting

    static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""

        for ch in text {
            current.append(ch)
            if ch == "。" || ch == "！" || ch == "？" || ch == "!" || ch == "?" || ch == "\n" {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if sentence.isNotBlank {
                    result.append(sentence)
                }
                current = ""
            }
        }

        let remaining = current.trimmingCharacters(in: .whitespaces)
        if remaining.isNotBlank {
            result.append(remaining)
        }

        if result.isEmpty {
            result.append(text)
        }

        return result
    }

    // MARK: - Pre-compiled Regexes (created once, reused on every normalize call)

    private static let celsiusRangeRegex = try? NSRegularExpression(
        pattern: "(\\d+(?:\\.\\d+)?)\\s*[~～\\-—]\\s*(\\d+(?:\\.\\d+)?)\\s*℃"
    )
    private static let degreeRangeRegex = try? NSRegularExpression(
        pattern: "(\\d+(?:\\.\\d+)?)\\s*[~～\\-—]\\s*(\\d+(?:\\.\\d+)?)\\s*度"
    )
    private static let celsiusRegex = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*℃")
    private static let percentRegex = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*%")
    private static let simpleRangeRegex = try? NSRegularExpression(
        pattern: "(\\d+(?:\\.\\d+)?)\\s*[~～\\-—−]\\s*(\\d+(?:\\.\\d+)?)"
    )
    private static let yearRegex = try? NSRegularExpression(pattern: "(\\d{4})\\s*年")
    private static let monthRegex = try? NSRegularExpression(pattern: "(\\d{1,2})\\s*月")
    private static let dayRegex = try? NSRegularExpression(pattern: "(\\d{1,2})\\s*日")
    private static let hourRegex = try? NSRegularExpression(pattern: "(\\d{1,2})\\s*点")
    private static let timeRegex = try? NSRegularExpression(pattern: "(\\d{1,2}):(\\d{2})(?!\\d)")
    private static let decimalRegex = try? NSRegularExpression(pattern: "(\\d+)\\.(\\d+)")
    private static let integerRegex = try? NSRegularExpression(pattern: "\\d+")
    private static let englishWordRegex = try? NSRegularExpression(pattern: "[a-zA-Z]+")
    private static let dashOrTildeRegex = try? NSRegularExpression(pattern: "[~～\\-—−]")
    private static let whitespaceRegex = try? NSRegularExpression(pattern: "\\s+")

    // MARK: - Normalize

    static func normalize(_ text: String) -> String {
        var result = text

        // Step 1: Special character regexes (multi-word phrases, symbols)
        for (regex, replacement) in specialRegexes {
            if replacement == "__WORD_MAP__" {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
                // Handle word map replacements separately
                let nsRange = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: nsRange,
                    withTemplate: "")  // This is a placeholder; actual replacement done below
                // Re-do with proper handling
            } else {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }

        // Re-apply word-based substitutions using the pure word regex
        if let wordRegex = specialRegexes.first(where: { $0.1 == "__WORD_MAP__" })?.0 {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = wordRegex.matches(in: result, range: nsRange)
            // Process in reverse to preserve indices
            for match in matches.reversed() {
                if let range = Range(match.range, in: result) {
                    let word = result[range].lowercased()
                    if let zh = _pureWordMap[word] {
                        result.replaceSubrange(range, with: zh)
                    }
                }
            }
        }

        // Step 2: Range with ℃: 28℃～35℃ → 二十八至三十五摄氏度
        if let regex = celsiusRangeRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let g1 = nsString.substring(with: match.range(at: 1))
                let g2 = nsString.substring(with: match.range(at: 2))
                result = nsString.replacingCharacters(in: match.range, with: numberToChinese(g1) + "至" + numberToChinese(g2) + "摄氏度")
            }
        }

        // Step 3: Range with 度
        if let regex = degreeRangeRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let g1 = nsString.substring(with: match.range(at: 1))
                let g2 = nsString.substring(with: match.range(at: 2))
                result = nsString.replacingCharacters(in: match.range, with: numberToChinese(g1) + "至" + numberToChinese(g2) + "度")
            }
        }

        // Step 4: Celsius: 35℃
        if let regex = celsiusRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let g1 = nsString.substring(with: match.range(at: 1))
                result = nsString.replacingCharacters(in: match.range, with: numberToChinese(g1) + "摄氏度")
            }
        }

        // Step 5: Percentage: 50% → 百分之五十
        if let regex = percentRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let g1 = nsString.substring(with: match.range(at: 1))
                result = nsString.replacingCharacters(in: match.range, with: "百分之" + numberToChinese(g1))
            }
        }

        // Step 6: Simple range: 28~35
        if let regex = simpleRangeRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let g1 = nsString.substring(with: match.range(at: 1))
                let g2 = nsString.substring(with: match.range(at: 2))
                result = nsString.replacingCharacters(in: match.range, with: numberToChinese(g1) + "至" + numberToChinese(g2))
            }
        }

        // Step 7: Year: 2026年 → 二零二六年
        if let regex = yearRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let g1 = nsString.substring(with: match.range(at: 1))
                result = nsString.replacingCharacters(in: match.range, with: digitsToChinese(g1) + "年")
            }
        }

        // Step 8: Month: 7月
        if let regex = monthRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let g1 = nsString.substring(with: match.range(at: 1))
                result = nsString.replacingCharacters(in: match.range, with: numberToChinese(g1) + "月")
            }
        }

        // Step 9: Day: 2日
        if let regex = dayRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let g1 = nsString.substring(with: match.range(at: 1))
                result = nsString.replacingCharacters(in: match.range, with: numberToChinese(g1) + "日")
            }
        }

        // Step 10: Hour: 14点
        if let regex = hourRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let g1 = nsString.substring(with: match.range(at: 1))
                result = nsString.replacingCharacters(in: match.range, with: numberToChinese(g1) + "点")
            }
        }

        // Step 11: Time HH:MM: 8:00 → 八点, 19:35 → 十九点三十五分, 08:05 → 八点零五分
        if let regex = timeRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let hourStr = nsString.substring(with: match.range(at: 1))
                let minuteStr = nsString.substring(with: match.range(at: 2))
                let minute = Int(minuteStr) ?? 0
                let chHour = numberToChinese(hourStr)
                let replacement: String
                if minute == 0 {
                    replacement = chHour + "点"
                } else if minute < 10 {
                    replacement = chHour + "点零" + numberToChinese(String(minute)) + "分"
                } else {
                    replacement = chHour + "点" + numberToChinese(String(minute)) + "分"
                }
                result = nsString.replacingCharacters(in: match.range, with: replacement)
            }
        }

        // Step 12: Decimal: 3.14 → 三点一四
        if let regex = decimalRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let intPart = numberToChinese(nsString.substring(with: match.range(at: 1)))
                let fracStr = nsString.substring(with: match.range(at: 2))
                let fracPart = fracStr.compactMap { $0.wholeNumberValue }
                    .map { String(chineseDigits[$0]) }
                    .joined()
                result = nsString.replacingCharacters(in: match.range, with: intPart + " 点 " + fracPart)
            }
        }

        // Step 13: Remaining standalone integers
        if let regex = integerRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let num = nsString.substring(with: match.range(at: 0))
                result = nsString.replacingCharacters(in: match.range, with: numberToChinese(num))
            }
        }

        // Step 14: Remaining English letters
        if let regex = englishWordRegex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let word = nsString.substring(with: match.range(at: 0)).lowercased()
                result = nsString.replacingCharacters(in: match.range, with: word.map { englishLetterToChinese($0) }.joined())
            }
        }

        // Step 15: Replace tildes, dashes
        if let regex = dashOrTildeRegex {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "，"
            )
        }

        // Step 16: Collapse whitespace
        if let regex = whitespaceRegex {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        return result
    }
}
