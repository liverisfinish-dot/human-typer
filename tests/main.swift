import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name); checks += 1
}
let mixed = "Hello 你好，世界！\nEnglish 中文 👨‍👩‍👧‍👦 e\u{301} 🇨🇳\tEND"
let s = TypingSession()
s.restAtWordBoundary = false // 旧精确用例：关闭词边界顺延，保持原断言
s.nextChunk = { 10 }; s.delay = { _ in 0.25 }
s.prepare(mixed, now: 0)
expect(String(s.characters) == mixed, "Unicode grapheme preservation")
expect(s.characters.contains("👨‍👩‍👧‍👦"), "ZWJ emoji stays whole")
expect(!s.ready(now: 4.999), "no output during countdown")
s.finishCountdown(now: 4.999)
expect(s.state == .countdown, "countdown cannot finish early")
s.finishCountdown(now: 5)
var now = 5.0
var output = ""
var rests = 0
while !s.isFinished {
    expect(s.ready(now: now), "ready at deadline")
    output.append(s.pendingCharacter!)
    s.didSend(now: now)
    if s.state == .resting {
        rests += 1
        expect(s.deadline == now + 5, "rest is exactly five seconds")
        expect(!s.ready(now: now + 4.999), "rest cannot finish early")
    }
    now = s.deadline
}
expect(output == mixed, "complete output is identical")
expect(s.index == mixed.count, "progress matches graphemes")
expect(rests == (mixed.count - 1) / 10, "no rest after final character")
expect(s.state == .completed, "completion")

// Pause during a rest, keep both position and remaining delay across countdown.
s.prepare(String(repeating: "中A", count: 30), now: 0); s.finishCountdown(now: 5)
now = 5
for _ in 0..<10 { expect(s.ready(now: now), "ready"); s.didSend(now: now); now = s.deadline }
let restEnd = s.deadline
s.pause(now: restEnd - 3)
expect(s.index == 10 && s.state == .paused, "pause preserves position")
expect(!s.ready(now: 1000), "paused session never emits")
s.resume(now: 1000); s.finishCountdown(now: 1005)
expect(s.state == .resting && s.deadline == 1008, "remaining rest survives resume")
expect(!s.ready(now: 1007.999), "resumed rest enforced")
expect(s.ready(now: 1008), "resume after remaining rest")
s.didSend(now: 1008)
expect(s.index == 11, "resume advances to next character once")
s.pause(now: 1008.1); s.resume(now: 2000); s.pause(now: 2001); s.resume(now: 3000)
s.finishCountdown(now: 3005)
expect(s.index == 11, "cancelled countdown cannot lose progress")
s.reset(); expect(s.index == 0 && s.state == .idle, "reset cancels all work")
s.didSend(now: 9999); expect(s.index == 0, "no stale callback after reset")
s.prepare("", now: 0); expect(s.state == .completed, "empty input")
s.prepare("a\r\nb\rc", now: 0); expect(String(s.characters) == "a\nb\nc", "line endings")

// Long run, real random group sizes, no recursion and no duplicates.
let long = TypingSession(); long.restAtWordBoundary = false
long.prepare(String(repeating: "中a👋🏽\n", count: 2500), now: 0)
long.finishCountdown(now: 5); now = 5; var previous = 0; var sizes: Set<Int> = []
while !long.isFinished {
    expect(long.ready(now: now), "long run scheduling")
    long.didSend(now: now)
    if long.state == .resting {
        let size = long.index - previous
        expect((10...20).contains(size), "group size bound")
        expect(long.deadline == now + 5, "random group rest exact")
        previous = long.index; sizes.insert(size)
    }
    now = long.deadline
}
expect(sizes.count > 1, "group sizes vary")
expect(long.index == 10000, "ten thousand characters complete")

// Language modes: Chinese rests every 10-20 chars, English every 60-80.
expect(TypingSession.LanguageMode.chinese.chunkRange == 10...20, "chinese chunk 10-20")
expect(TypingSession.LanguageMode.english.chunkRange == 60...80, "english chunk 60-80")
expect(TypingSession().typoFrequency == .off, "typo off by default")

// Word-boundary rest: English never rests mid-word ("ab ab ..." chunks of 7).
let w = TypingSession(); w.nextChunk = { 7 }; w.delay = { _ in 0.1 }
w.prepare(String(repeating: "ab ", count: 100), now: 0); w.finishCountdown(now: 5)
now = 5
var wRests: [Int] = []
while !w.isFinished {
    expect(w.ready(now: now), "word-boundary scheduling")
    w.didSend(now: now)
    if w.state == .resting { wRests.append(w.index) }
    now = w.deadline
}
expect(!wRests.isEmpty, "word-boundary rests occur")
var wPrev = 0
for r in wRests {
    let size = r - wPrev
    expect((7...19).contains(size), "chunk plus at most 12 extension")
    let atBoundary = r == w.characters.count
        || !TypingSession.isWordChar(w.characters[r]) || !TypingSession.isWordChar(w.characters[r - 1])
    expect(atBoundary, "rest lands on word boundary")
    wPrev = r
}

// Chinese rests on bigram boundaries: "你好世界和平" chunks of 4 rest at 4, then finish.
let c = TypingSession(); c.nextChunk = { 4 }; c.delay = { _ in 0.1 }
c.prepare("你好世界和平", now: 0); c.finishCountdown(now: 5)
now = 5
var cRests: [Int] = []
while !c.isFinished {
    expect(c.ready(now: now), "bigram scheduling")
    c.didSend(now: now)
    if c.state == .resting { cRests.append(c.index) }
    now = c.deadline
}
expect(cRests == [4], "chinese rests on bigram boundary")

// Very long word: extension capped, 50 a's with chunk 10 rest at 22 and 44.
let lw = TypingSession(); lw.nextChunk = { 10 }; lw.delay = { _ in 0.1 }
lw.prepare(String(repeating: "a", count: 50), now: 0); lw.finishCountdown(now: 5)
now = 5
var lwRests: [Int] = []
while !lw.isFinished {
    expect(lw.ready(now: now), "long-word scheduling")
    lw.didSend(now: now)
    if lw.state == .resting { lwRests.append(lw.index) }
    now = lw.deadline
}
expect(lwRests == [22, 44], "long-word extension capped at 12")

// Word typo: whole similar word, then delete whole word, then correct word.
let t = TypingSession()
t.nextChunk = { 1000 }; t.delay = { _ in 0.2 }
t.typoFrequency = .frequent
t.typoRoll = { 0.0 } // always trigger at word start
t.makeWrongWord = { word in word.map { _ in "X" } }
t.noticeDelay = { 0.5 }; t.backspaceDelay = { 0.1 }; t.retypeDelay = { 0.2 }
t.prepare("hi be", now: 0); t.finishCountdown(now: 5)
now = 5
var seen: [String] = []
while t.state != .completed {
    expect(t.ready(now: now), "word-typo scheduling")
    guard let act = t.pendingAction else { preconditionFailure("no action") }
    switch act {
    case .type(let ch, let wrong):
        seen.append(wrong ? "W(\(ch))" : "C(\(ch))")
        if wrong { expect(t.inTypo, "inTypo during wrong word") }
    case .backspace:
        seen.append("BS")
    }
    let before = now
    t.didPerform(act, now: now)
    if seen.suffix(2) == ["C( )", "W(X)"] { expect(t.deadline == before + 0.2, "typing pace inside wrong word") }
    if seen.suffix(2) == ["W(X)", "W(X)"] { expect(t.deadline == before + 0.5, "notice pause before deleting word") }
    if seen.last == "BS" && t.inTypo { expect(t.deadline == before + 0.1, "backspacing whole word") }
    if seen.suffix(2) == ["BS", "BS"] { expect(t.deadline == before + 0.2, "retype pause after word deleted") }
    now = t.deadline
}
expect(seen == ["C(h)", "C(i)", "C( )", "W(X)", "W(X)", "BS", "BS", "C(b)", "C(e)"],
       "wrong word->delete word->correct word")
expect(t.index == 5, "word-typo run completes all correct chars")
expect(!t.inTypo, "no leftover typo queue")

// Single word never corrupts mid-word: "abc" with always-roll stays clean.
let m = TypingSession(); m.nextChunk = { 1000 }; m.delay = { _ in 0.1 }
m.typoFrequency = .frequent; m.typoRoll = { 0.0 }
m.makeWrongWord = { word in word.map { _ in "X" } }
m.prepare("abc", now: 0); m.finishCountdown(now: 5)
now = 5
var mSeen: [String] = []
while m.state != .completed {
    expect(m.ready(now: now), "mid-word scheduling")
    let act = m.pendingAction!
    if case .type(let ch, let wrong) = act { mSeen.append(wrong ? "W" : "C\(ch)") } else { mSeen.append("BS") }
    m.didPerform(act, now: now); now = m.deadline
}
expect(mSeen == ["Ca", "Cb", "Cc"], "no mid-word corruption")
expect(!m.inTypo, "no typo triggered mid-word")

// Pause in the middle of a word correction keeps the queue across resume.
let p = TypingSession()
p.nextChunk = { 1000 }; p.delay = { _ in 0.2 }
p.typoFrequency = .frequent; p.typoRoll = { 0.0 }
p.makeWrongWord = { word in word.map { _ in "Y" } }
p.prepare("hi be", now: 0); p.finishCountdown(now: 5)
now = 5
for _ in 0..<3 {
    expect(p.ready(now: now), "ready correct char")
    p.didPerform(p.pendingAction!, now: now); now = p.deadline
}
expect(p.pendingAction == .type("Y", isWrong: true), "wrong word queued")
p.pause(now: now)
expect(p.state == .paused && p.inTypo, "pause keeps word-typo queue")
p.resume(now: now + 10); p.finishCountdown(now: now + 15)
now = now + 15
var tail: [String] = []
while p.state != .completed {
    expect(p.ready(now: now), "post-resume scheduling")
    let act = p.pendingAction!
    if act == .backspace { tail.append("BS") } else if case .type(let ch, let wflag) = act { tail.append(wflag ? "W" : "C\(ch)") }
    p.didPerform(act, now: now); now = p.deadline
}
expect(tail == ["W", "W", "BS", "BS", "Cb", "Ce"], "word correction resumes after pause")
expect(p.index == 5, "pause-resume word-typo run complete")

// Wrong-word generator: similar words, same length, skips spaces.
expect(DefaultWrongChars.wrongChar(for: " ") == nil, "no typo on space")
expect(DefaultWrongChars.wrongChar(for: "，") == nil, "no typo on punctuation")
expect("gjyuibnm".contains(DefaultWrongChars.wrongChar(for: "h")!), "neighbor-key typo")
expect("GJYUIBNM".contains(DefaultWrongChars.wrongChar(for: "H")!), "uppercase neighbor typo")
let d5 = DefaultWrongChars.wrongChar(for: "5")!
expect(d5 == "4" || d5 == "6", "adjacent-digit typo")
expect(DefaultWrongChars.wrongChar(for: "中") != nil, "hanzi typo exists")
let helloWrong = DefaultWrongChars.wrongWord(for: Array("hello"))!
expect(helloWrong.count == 5 && helloWrong != Array("hello"), "similar word, same length")
expect(helloWrong.allSatisfy { ("a"..."z").contains($0.unicodeScalars.first!) }, "latin stays latin")
expect(DefaultWrongChars.wrongWord(for: Array("hi there")) == nil, "space aborts word typo")
let guoWrong = DefaultWrongChars.wrongWord(for: ["中", "国"])!
expect(guoWrong.count == 2 && guoWrong != ["中", "国"], "hanzi word typo")
expect(DefaultWrongChars.wrongWord(for: Array(repeating: "a", count: 11)) == nil, "long word skipped")
// sanitizeInput: soft line breaks become newlines, stray controls dropped, rest kept.
let s1 = sanitizeInput("a\u{0B}b\u{0C}c\u{85}d")
expect(s1.cleaned == "a\nb\nc\nd", "soft breaks become newlines")
expect(s1.removed.map { $0.0 } == [0x0B, 0x0C, 0x85], "removed code points reported")
let s2 = sanitizeInput("a\u{00}b\u{07}c\u{7F}d\u{80}e\tf\ng\rh")
expect(s2.cleaned == "abcde\tf\ng\rh", "stray controls dropped, tab/newline/CR kept")
expect(s2.removed.reduce(0) { $0 + $1.1 } == 4, "four controls counted")
let s3 = sanitizeInput("Hello 你好👨‍👩‍👧‍👦\u{FEFF}")
expect(s3.cleaned == "Hello 你好👨‍👩‍👧‍👦", "BOM dropped, emoji/ZWJ kept")
expect(s3.removed.map { $0.0 } == [0xFEFF], "BOM reported")
let s4 = sanitizeInput("一切正常，没有控制字符。")
expect(s4.cleaned == "一切正常，没有控制字符。" && s4.removed.isEmpty, "clean text untouched")
print("PASS: \(checks) assertions; Unicode, countdown, exact rests, pause/resume, reset, 10,000-character run")
