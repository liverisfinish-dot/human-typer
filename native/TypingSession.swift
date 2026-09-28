import Foundation

/// 粘贴文本里常混进看不见的控制字符（Word 软换行 U+000B、分页符 U+000C、NEL 等），
/// 编辑框里看着一切正常，但发给文档会乱套。以前是整段拒收，现在自动清理：
/// 软换行/分页/NEL 转成普通换行，其余 C0/C1 控制字符和 BOM 直接去掉，返回清理后的文本
/// 和 (码点, 个数) 明细。制表符、换行、零宽连接符、emoji 等原样保留。
func sanitizeInput(_ text: String) -> (cleaned: String, removed: [(UInt32, Int)]) {
    var counts: [UInt32: Int] = [:]
    var out = ""
    out.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        let v = scalar.value
        switch v {
        case 9, 10, 13:
            out.unicodeScalars.append(scalar) // 制表/换行/回车保留（回车在 prepare 里统一转成换行）
        case 0x0B, 0x0C, 0x85:
            out.append("\n"); counts[v, default: 0] += 1 // 软换行/分页/NEL → 换行
        case 0x00...0x1F, 0x7F...0x9F, 0xFEFF:
            counts[v, default: 0] += 1 // 其余控制字符和 BOM 丢弃
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return (out, counts.sorted { $0.key < $1.key })
}

/// No UI or keyboard dependencies. Time is monotonic and injectable in tests.
final class TypingSession {
    enum State: Equatable { case idle, countdown, typing, resting, paused, completed }

    /// 中文 10–20 字停 5 秒；英文 60–80 字停 5 秒。由界面手动切换。
    enum LanguageMode: Int {
        case chinese = 0, english = 1
        var chunkRange: ClosedRange<Int> {
            switch self {
            case .chinese: return 10...20
            case .english: return 60...80
            }
        }
    }

    enum TypoFrequency: Int {
        case frequent = 0, occasional = 1, off = 2
    }

    /// 打错纠错动作。错字和退格不推进原文进度，只有正确字符推进。
    enum Action: Equatable {
        case type(Character, isWrong: Bool)
        case backspace
    }

    private(set) var state: State = .idle
    private(set) var characters: [Character] = []
    private(set) var index = 0
    private(set) var deadline: TimeInterval = 0
    private var remainingDelay: TimeInterval = 0
    private var resumeState: State = .typing
    private var inChunk = 0
    private var chunkSize = 10
    var languageMode: LanguageMode = .chinese
    var typoFrequency: TypoFrequency = .off
    /// 停顿前把当前词打完：分块计数满后若停在词中间，顺延到词边界再休息。
    /// 超长词最多顺延 12 字，避免等太久。
    var restAtWordBoundary = true
    private let maxRestExtension = 12
    /// 优先消费的纠错队列：错词在前、等量退格在后。为空时才输出正确字符。
    private(set) var typoQueue: [Action] = []
    var inTypo: Bool { !typoQueue.isEmpty }

    var nextChunk: () -> Int = { Int.random(in: 10...20) }
    var delay: (Character) -> Double = { character in
        let punctuation = "，。！？；：,.!?;:、"
        return Double.random(in: 0.22...0.40) + (punctuation.contains(character) ? 0.35 : 0)
    }
    /// 每个词开头掷一次骰子：频繁约 22%，偶尔约 6%。测试可注入固定值。
    var typoRoll: () -> Double = { Double.random(in: 0..<1) }
    /// 为即将输入的词生成一个相近的错词（等长）。返回 nil 表示该词不打错。
    var makeWrongWord: ([Character]) -> [Character]? = { DefaultWrongChars.wrongWord(for: $0) }
    /// 发现打错后的停顿（装作注意到），以及退格/重打前的衔接延时。
    var noticeDelay: () -> Double = { Double.random(in: 0.4...0.9) }
    var backspaceDelay: () -> Double = { Double.random(in: 0.06...0.12) }
    var retypeDelay: () -> Double = { Double.random(in: 0.15...0.30) }

    var active: Bool { state == .countdown || state == .typing || state == .resting }
    /// 纠错优先：队列非空时返回错字/退格，否则返回原文当前字符。
    var pendingAction: Action? {
        if let first = typoQueue.first { return first }
        guard index < characters.count else { return nil }
        return .type(characters[index], isWrong: false)
    }
    /// 兼容旧调用：纠错中返回错字，否则返回原文当前字符；退格前返回 nil。
    var pendingCharacter: Character? {
        if let first = typoQueue.first {
            if case .type(let ch, _) = first { return ch }
            return nil
        }
        return index < characters.count ? characters[index] : nil
    }
    var isFinished: Bool { index == characters.count }

    func prepare(_ text: String, now: Double) {
        characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        index = 0; inChunk = 0; chunkSize = nextChunk()
        remainingDelay = 0; resumeState = .typing
        typoQueue = []
        state = characters.isEmpty ? .completed : .countdown
        deadline = now + 5
    }
    func resume(now: Double) {
        guard state == .paused, !isFinished else { return }
        state = .countdown; deadline = now + 5
    }
    func finishCountdown(now: Double) {
        guard state == .countdown, now >= deadline else { return }
        state = resumeState; deadline = now + remainingDelay
        remainingDelay = 0
    }
    func pause(now: Double) {
        guard active else { return }
        if state != .countdown {
            remainingDelay = max(0, deadline - now)
            resumeState = state
        }
        state = .paused
    }
    func ready(now: Double) -> Bool {
        guard state == .typing || state == .resting, now >= deadline else { return false }
        state = .typing
        return !isFinished || !typoQueue.isEmpty
    }
    /// 新版统一入口：调用方按 pendingAction 执行（打字/退格）后调用。
    func didPerform(_ action: Action, now: Double) {
        guard state == .typing else { return }
        switch action {
        case .backspace:
            guard !typoQueue.isEmpty, typoQueue.first == .backspace else { return }
            typoQueue.removeFirst()
            deadline = typoQueue.isEmpty ? now + retypeDelay() : now + backspaceDelay()
        case .type(let ch, let isWrong):
            if isWrong {
                guard !typoQueue.isEmpty, typoQueue.first == .type(ch, isWrong: true) else { return }
                typoQueue.removeFirst()
                // 错字打完、轮到退格：先装作发现错误停一下。
                if let first = typoQueue.first, first == .backspace {
                    deadline = now + noticeDelay()
                } else {
                    deadline = now + delay(ch)
                }
            } else {
                guard typoQueue.isEmpty, index < characters.count, characters[index] == ch else { return }
                index += 1; inChunk += 1
                if isFinished { state = .completed; return }
                if shouldRest() {
                    inChunk = 0; chunkSize = nextChunk()
                    state = .resting; deadline = now + 5
                    return
                }
                deadline = now + delay(ch)
                maybeTriggerWordTypo()
            }
        }
    }
    /// 旧版入口：仅推进正确字符。纠错队列非空时拒绝，避免进度错乱。
    func didSend(now: Double) {
        guard state == .typing, typoQueue.isEmpty, let character = pendingCharacter else { return }
        index += 1; inChunk += 1
        if isFinished { state = .completed; return }
        if shouldRest() {
            inChunk = 0; chunkSize = nextChunk()
            state = .resting; deadline = now + 5
        } else { deadline = now + delay(character) }
    }
    /// 分块计数满后，若正停在词中间就顺延到词边界（超长词最多顺延 12 字）。
    private func shouldRest() -> Bool {
        guard inChunk >= chunkSize else { return false }
        guard restAtWordBoundary else { return true }
        return !isMidWord() || inChunk >= chunkSize + maxRestExtension
    }
    /// 是否正停在词中间：下一个字和刚打的字都属于同一个词。
    /// 中文按双字词切分，双字边界可休息。
    private func isMidWord() -> Bool {
        guard index < characters.count, index > 0 else { return false }
        let next = characters[index], prev = characters[index - 1]
        guard Self.isWordChar(next) && Self.isWordChar(prev) else { return false }
        if Self.isCJK(next) && Self.isCJK(prev) {
            var n = 0; var j = index - 1
            while j >= 0 && Self.isCJK(characters[j]) { n += 1; j -= 1 }
            return n % 2 != 0
        }
        return true
    }
    static func isWordChar(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        let v = s.value
        return (0x61...0x7A).contains(v) || (0x41...0x5A).contains(v)
            || (0x30...0x39).contains(v) || (0x4E00...0x9FFF).contains(v)
    }
    static func isCJK(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (0x4E00...0x9FFF).contains(s.value)
    }
    /// 词首（空格/标点后的第一个词字符；中文双字词按双字切分）才掷骰子。
    /// 中选则把整个词打成相近错词，随后删整个词、重打。
    private func isWordStart(at i: Int) -> Bool {
        guard i < characters.count, Self.isWordChar(characters[i]) else { return false }
        if i == 0 { return true }
        let prev = characters[i - 1]
        if !Self.isWordChar(prev) { return true }
        if Self.isCJK(characters[i]) && Self.isCJK(prev) {
            var n = 0; var j = i - 1
            while j >= 0 && Self.isCJK(characters[j]) { n += 1; j -= 1 }
            return n % 2 == 0
        }
        return false
    }
    /// 从词首取整个词：英文按字母数字 run，中文取双字；超长词最多取 10 字。
    private func wordRun(from i: Int) -> [Character] {
        var out: [Character] = []
        guard i < characters.count else { return out }
        let cjk = Self.isCJK(characters[i])
        var j = i
        while j < characters.count && out.count < 10 && Self.isWordChar(characters[j]) {
            if cjk != Self.isCJK(characters[j]) { break }
            out.append(characters[j]); j += 1
            if cjk && out.count == 2 { break }
        }
        return out
    }
    private func maybeTriggerWordTypo() {
        guard typoFrequency != .off, typoQueue.isEmpty, index < characters.count else { return }
        guard isWordStart(at: index) else { return }
        let threshold = typoFrequency == .frequent ? 0.22 : 0.06
        guard typoRoll() < threshold else { return }
        let word = wordRun(from: index)
        guard let wrong = makeWrongWord(word) else { return }
        typoQueue = wrong.map { .type($0, isWrong: true) } + Array(repeating: .backspace, count: wrong.count)
    }
    /// 开始新任务时若切换了语言/分块闭包，补抽一次（prepare 用的是旧闭包）。
    func rechunkForNewTask() {
        inChunk = 0; chunkSize = nextChunk()
    }
    /// 打错频率等界面选项在 prepare 之后才设置，清空可能残留的纠错队列。
    func clearTypoState() {
        typoQueue = []
    }
    func reset() {
        state = .idle; characters = []; index = 0
        inChunk = 0; remainingDelay = 0; resumeState = .typing
        typoQueue = []
    }
}

/// 默认错字生成：英文按 QWERTY 邻键，数字按相邻数字，中文按常见字随手错一个，
/// 空格标点换行制表不打错。返回数组长度即错字个数（1–2）。
enum DefaultWrongChars {
    static let neighbors: [Character: [Character]] = [
        "a": ["s", "q", "z"], "b": ["v", "g", "h", "n"], "c": ["x", "d", "f", "v"],
        "d": ["s", "e", "r", "f", "c", "x"], "e": ["w", "r", "d", "s"], "f": ["d", "r", "t", "g", "v", "c"],
        "g": ["f", "t", "y", "h", "b", "v"], "h": ["g", "y", "u", "j", "n", "b"],
        "i": ["u", "o", "k", "j"], "j": ["h", "u", "i", "k", "n", "m"], "k": ["j", "i", "o", "l", "m"],
        "l": ["k", "o", "p"], "m": ["n", "j", "k"], "n": ["b", "h", "j", "m"],
        "o": ["i", "p", "l", "k"], "p": ["o", "l"], "q": ["w", "a"], "r": ["e", "t", "f", "d"],
        "s": ["a", "w", "e", "d", "x", "z"], "t": ["r", "y", "g", "f"], "u": ["y", "i", "h", "j"],
        "v": ["c", "f", "g", "b"], "w": ["q", "e", "s", "a"], "x": ["z", "s", "d", "c"],
        "y": ["t", "u", "h", "g"], "z": ["x", "s", "a"],
    ]
    /// 高频常用汉字池：用于中文错字和“常见字打得快”的判断。
    static let commonHanzi = "的了我是在有和人这中大为上个国以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接竞"
    static let commonHanziChars = Array(commonHanzi)

    /// 单字映射：英文按 QWERTY 邻键，数字按相邻数字，中文按常见字随手错一个。
    /// 空格标点换行等返回 nil（该词整体跳过，不打错）。
    static func wrongChar(for ch: Character) -> Character? {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return nil }
        if ("a"..."z").contains(scalar) {
            return (neighbors[ch] ?? ["e", "t", "a"]).randomElement()!
        }
        if ("A"..."Z").contains(scalar) {
            let lower = Character(ch.lowercased())
            let pool = neighbors[lower] ?? ["e", "t", "a"]
            return Character(pool.randomElement()!.uppercased())
        }
        if ("0"..."9").contains(scalar) {
            let d = scalar.value - Unicode.Scalar("0").value
            return Character(String([ (d + 1) % 10, (d + 9) % 10 ].randomElement()!))
        }
        if (0x4E00...0x9FFF).contains(scalar.value) {
            return commonHanziChars.randomElement()!
        }
        return nil
    }

    /// 整词错成相近词（等长，保证删整个词时退格数对得上）：
    /// 英文 35% 相邻字母换位，其余 1–2 处邻键替换；中文双字换 1–2 字。
    /// 词过长（>10）或含不可映射字符返回 nil。
    static func wrongWord(for word: [Character]) -> [Character]? {
        guard !word.isEmpty && word.count <= 10 else { return nil }
        for ch in word { guard wrongChar(for: ch) != nil else { return nil } }
        let isLatin = word.allSatisfy {
            guard let s = $0.unicodeScalars.first, $0.unicodeScalars.count == 1 else { return false }
            return (0x61...0x7A).contains(s.value) || (0x41...0x5A).contains(s.value)
        }
        if isLatin && word.count >= 2 && Double.random(in: 0..<1) < 0.35 {
            // 换位：thier、tpying 这类经典手误。
            for _ in 0..<8 {
                let i = Int.random(in: 0..<(word.count - 1))
                if word[i] != word[i + 1] {
                    var out = word
                    out.swapAt(i, i + 1)
                    return out
                }
            }
        }
        let edits = word.count <= 2 ? 1 : 2
        var out = word
        for _ in 0..<8 {
            out = word
            for pos in Array(0..<word.count).shuffled().prefix(edits) {
                out[pos] = wrongChar(for: word[pos])!
            }
            if out != word { return out }
        }
        return nil
    }
}
