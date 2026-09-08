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

        // Align groups from the right: the most-significant group may be
        // shorter than 4 (e.g. 12345 → [1][2345]). Mirrors the desktop Go
        // implementation (firstLen := l % 4). Fixes 5-7/9-11 digit readings.
        var groupStart = 0
        var firstLen = len % 4
        if firstLen == 0 { firstLen = 4 }
        while groupStart < len {
            let groupLen = (groupStart == 0) ? firstLen : 4
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
            groupStart = groupEnd
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

        // Step 1: Range with ℃: 28℃～35℃ → 二十八至三十五摄氏度
        if let regex = celsiusRangeRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let g1 = nsCurrent.substring(with: match.range(at: 1))
                let g2 = nsCurrent.substring(with: match.range(at: 2))
                result = nsCurrent.replacingCharacters(in: match.range, with: numberToChinese(g1) + "至" + numberToChinese(g2) + "摄氏度")
            }
        }

        // Step 3: Range with 度
        if let regex = degreeRangeRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let g1 = nsCurrent.substring(with: match.range(at: 1))
                let g2 = nsCurrent.substring(with: match.range(at: 2))
                result = nsCurrent.replacingCharacters(in: match.range, with: numberToChinese(g1) + "至" + numberToChinese(g2) + "度")
            }
        }

        // Step 4: Celsius: 35℃
        if let regex = celsiusRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let g1 = nsCurrent.substring(with: match.range(at: 1))
                result = nsCurrent.replacingCharacters(in: match.range, with: numberToChinese(g1) + "摄氏度")
            }
        }

        // Step 5: Percentage: 50% → 百分之五十
        if let regex = percentRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let g1 = nsCurrent.substring(with: match.range(at: 1))
                result = nsCurrent.replacingCharacters(in: match.range, with: "百分之" + numberToChinese(g1))
            }
        }

        // Step 6: Simple range: 28~35
        if let regex = simpleRangeRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let g1 = nsCurrent.substring(with: match.range(at: 1))
                let g2 = nsCurrent.substring(with: match.range(at: 2))
                result = nsCurrent.replacingCharacters(in: match.range, with: numberToChinese(g1) + "至" + numberToChinese(g2))
            }
        }

        // Step 7: Year: 2026年 → 二零二六年
        if let regex = yearRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let g1 = nsCurrent.substring(with: match.range(at: 1))
                result = nsCurrent.replacingCharacters(in: match.range, with: digitsToChinese(g1) + "年")
            }
        }

        // Step 8: Month: 7月
        if let regex = monthRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let g1 = nsCurrent.substring(with: match.range(at: 1))
                result = nsCurrent.replacingCharacters(in: match.range, with: numberToChinese(g1) + "月")
            }
        }

        // Step 9: Day: 2日
        if let regex = dayRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let g1 = nsCurrent.substring(with: match.range(at: 1))
                result = nsCurrent.replacingCharacters(in: match.range, with: numberToChinese(g1) + "日")
            }
        }

        // Step 10: Hour: 14点
        if let regex = hourRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let g1 = nsCurrent.substring(with: match.range(at: 1))
                result = nsCurrent.replacingCharacters(in: match.range, with: numberToChinese(g1) + "点")
            }
        }

        // Step 11: Time HH:MM: 8:00 → 八点, 19:35 → 十九点三十五分, 08:05 → 八点零五分
        if let regex = timeRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let hourStr = nsCurrent.substring(with: match.range(at: 1))
                let minuteStr = nsCurrent.substring(with: match.range(at: 2))
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
                result = nsCurrent.replacingCharacters(in: match.range, with: replacement)
            }
        }

        // Step 12: Decimal: 3.14 → 三点一四
        if let regex = decimalRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let intPart = numberToChinese(nsCurrent.substring(with: match.range(at: 1)))
                let fracStr = nsCurrent.substring(with: match.range(at: 2))
                let fracPart = fracStr.compactMap { $0.wholeNumberValue }
                    .map { String(chineseDigits[$0]) }
                    .joined()
                result = nsCurrent.replacingCharacters(in: match.range, with: intPart + " 点 " + fracPart)
            }
        }

        // Step 13: Remaining standalone integers
        if let regex = integerRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let num = nsCurrent.substring(with: match.range(at: 0))
                result = nsCurrent.replacingCharacters(in: match.range, with: numberToChinese(num))
            }
        }

        // Step 14: Remaining English letters
        if let regex = englishWordRegex {
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
            for match in matches.reversed() {
                let nsCurrent = result as NSString
                let word = nsCurrent.substring(with: match.range(at: 0)).lowercased()
                result = nsCurrent.replacingCharacters(in: match.range, with: word.map { englishLetterToChinese($0) }.joined())
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
