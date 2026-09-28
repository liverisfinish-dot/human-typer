import AppKit
import ApplicationServices

let eventMarker: Int64 = 0x4155544F545950
func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }

struct Target {
    let pid: pid_t
    let window: AXUIElement
    let title: String
    let document: String
    let focusedRole: String
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// Chrome 窗口通常在 kAXDocument 上直接带页面 URL（最快、最准）；
/// 个别版本/状态下才需要下钻到 AXWebArea。实测 WebArea 在深度 8 左右，
/// 旧代码只搜深度 <7、80 节点所以永远找不到，只能靠 AXDocument。
/// 这里：优先 AXDocument，失败再放宽 BFS 兜底，且优先返回 docs.google.com 的地址。
func docID(from urlString: String) -> String {
    guard let url = URL(string: urlString), url.host == "docs.google.com" else { return "" }
    let parts = url.pathComponents
    // "/document/d/XXX/edit" -> ["/", "document", "d", "XXX", "edit"]
    guard parts.count > 3, parts.count > 2, parts[1] == "document", parts[2] == "d" else { return "" }
    return parts[3]
}

func pageURL(_ window: AXUIElement) -> String {
    if let document = attribute(window, kAXDocumentAttribute) as? String, !document.isEmpty { return document }
    if let documentURL = attribute(window, kAXDocumentAttribute) as? URL { return documentURL.absoluteString }
    if let direct = attribute(window, kAXURLAttribute) as? URL { return direct.absoluteString }
    if let direct = attribute(window, kAXURLAttribute) as? String, !direct.isEmpty { return direct }
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var index = 0
    var fallback = ""
    while index < queue.count && index < 600 {
        let (element, depth) = queue[index]; index += 1
        // 中间容器也可能带 AXDocument，先收下备用
        if fallback.isEmpty, let mid = attribute(element, kAXDocumentAttribute) as? String, mid.contains("docs.google.com/document/") {
            // docs 地址优先，直接返回，不等 BFS 跑完
            return mid
        }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if role == "AXWebArea" {
            var urlString = ""
            if let url = attribute(element, kAXURLAttribute) as? URL { urlString = url.absoluteString }
            else if let url = attribute(element, kAXURLAttribute) as? String { urlString = url }
            if urlString.contains("docs.google.com/document/") { return urlString }
            if fallback.isEmpty, !urlString.isEmpty { fallback = urlString }
            // WebArea 内部还可能嵌套真正的文档区，继续往下找，不 continue 跳过
        }
        if depth < 12, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children.prefix(50).map { ($0, depth + 1) })
        }
    }
    return fallback
}

final class KeyboardSender {
    private var clipboard: [[NSPasteboard.PasteboardType: Data]]?
    private var ownedChange: Int?
    private var lastPaste = 0.0
    private let board = NSPasteboard.general
    var canRestore: Bool { monotonic() - lastPaste >= 0.6 }

    func send(_ character: Character, paste: Bool) throws {
        guard AXIsProcessTrusted() else { throw Failure.message("辅助功能权限未开启，已暂停。") }
        if paste || character == "\t" {
            if clipboard == nil {
                clipboard = (board.pasteboardItems ?? []).map { item in
                    var values: [NSPasteboard.PasteboardType: Data] = [:]
                    for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
                    return values
                }
            } else if let ownedChange, board.changeCount != ownedChange {
                throw Failure.message("检测到剪贴板被其他程序更改，已暂停；请确认文档后继续。")
            }
            board.clearContents()
            guard board.setString(String(character), forType: .string) else {
                throw Failure.message("无法写入剪贴板。")
            }
            ownedChange = board.changeCount
            try key(9, flags: .maskCommand)
            lastPaste = monotonic()
        } else if character == "\n" {
            try key(36)
        } else {
            try key(0, unicode: String(character))
        }
    }
    func backspace() throws {
        guard AXIsProcessTrusted() else { throw Failure.message("辅助功能权限未开启，已暂停。") }
        try key(51)
    }
    private func key(_ code: CGKeyCode, flags: CGEventFlags = [], unicode: String? = nil) throws {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw Failure.message("macOS 无法创建键盘事件。")
        }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            if let unicode {
                let units = Array(unicode.utf16)
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            }
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    func restoreIfReady(force: Bool = false) {
        guard let saved = clipboard, force || monotonic() - lastPaste >= 0.6 else { return }
        if board.changeCount == ownedChange {
            board.clearContents()
            let items = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        clipboard = nil; ownedChange = nil
    }
}

enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var editor = NSTextView()
    var status = NSTextField(labelWithString: "就绪")
    var count = NSTextField(labelWithString: "0 字")
    var targetLabel = NSTextField(labelWithString: "目标：开始倒计时后，点击 Google Docs 正文中的插入位置。")
    var permissionLabel = NSTextField(labelWithString: "")
    var urlField = NSTextField()
    var startButton: NSButton!
    var pauseButton: NSButton!
    var resetButton: NSButton!
    var mode = NSPopUpButton()
    var speed = NSPopUpButton()
    var lang = NSPopUpButton()
    var typo = NSPopUpButton()
    var progress = NSProgressIndicator()
    let session = TypingSession()
    let sender = KeyboardSender()
    var target: Target?
    var timer: Timer?
    var globalMonitor: Any?
    var localMonitor: Any?
    var lastTick = monotonic()
    var testWindow: NSWindow?
    var lastSave = ""
    var lastTrust = false
    var pasteMode = false
    var activationRequested = false
    var targetDiagnostic = ""
    var startNotice = ""
    var accessibleBrowsers: Set<pid_t> = []
    let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch should reveal the existing app rather than create two typists.
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.humantyper.HumanTyper").first(where: { $0.processIdentifier != getpid() }) {
            other.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        buildMenu(); buildWindow(); installMonitors()
        timer = Timer(timeInterval: 0.04, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出人类打字机", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = "编辑"; menu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
    }
    func label(_ text: String, size: CGFloat = 13) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        return field
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }
    func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10
        return stack
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 770), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "人类打字机"; window.center(); window.minSize = NSSize(width: 720, height: 720); window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -22)])
        root.addArrangedSubview(label("人类打字机", size: 25))
        root.addArrangedSubview(label("粘贴文本 → 开始 → 在 5 秒内点击文档正文。中文每随机 10–20 字、英文每随机 60–80 字固定停顿 5 秒，停顿前打完整个词。"))
        urlField.placeholderString = "Google Docs 链接（可选，用于打开并定位已打开的文档）"
        urlField.stringValue = defaults.string(forKey: "documentURL") ?? ""
        let urlRow = row([urlField, button("打开文档", #selector(openDocument))]); root.addArrangedSubview(urlRow)
        urlRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        editor.isRichText = false; editor.font = .systemFont(ofSize: 16); editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.minSize = NSSize(width: 0, height: 240); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor; editor.delegate = self
        editor.string = defaults.string(forKey: "draft") ?? ""; lastSave = editor.string
        root.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        root.addArrangedSubview(count)
        mode.addItems(withTitles: ["直接输入（不占用剪贴板）", "逐字粘贴（兼容模式）"])
        mode.selectItem(at: defaults.integer(forKey: "mode"))
        speed.addItems(withTitles: ["极速 · 0.08–0.18 秒/字", "正常 · 0.22–0.40 秒/字", "慢速 · 0.40–0.70 秒/字"])
        // 老版本只有两档（0=正常，1=慢速），新顺序是极速/正常/慢速，老存档整体后移一档。
        if !defaults.bool(forKey: "speedMigratedV2") {
            speed.selectItem(at: min(defaults.integer(forKey: "speed") + 1, 2))
            defaults.set(true, forKey: "speedMigratedV2")
        } else {
            speed.selectItem(at: min(max(defaults.integer(forKey: "speed"), 0), 2))
        }
        lang.addItems(withTitles: ["中文模式 · 10–20字停5秒", "英文模式 · 60–80字停5秒"])
        lang.selectItem(at: min(max(defaults.integer(forKey: "langMode"), 0), 1))
        typo.addItems(withTitles: ["打错：频繁", "打错：偶尔", "打错：关闭"])
        typo.selectItem(at: min(max(defaults.integer(forKey: "typoMode"), 0), 2))
        root.addArrangedSubview(row([mode, speed]))
        root.addArrangedSubview(row([lang, typo]))
        permissionLabel.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(row([permissionLabel, button("权限设置", #selector(permissions)), button("打开测试区", #selector(openTest))]))
        targetLabel = label(targetLabel.stringValue, size: 12); root.addArrangedSubview(targetLabel)
        targetLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        root.addArrangedSubview(progress); progress.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        status = label("就绪", size: 14); root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        startButton = button("开始 / 继续  ⌃⌥S", #selector(start))
        pauseButton = button("暂停  ⌃⌥E", #selector(pauseAction))
        resetButton = button("结束本次", #selector(reset))
        root.addArrangedSubview(row([startButton, pauseButton, resetButton]))
        root.addArrangedSubview(label("手动按键、点击鼠标或切换窗口会暂停。继续前请把光标放回原文档末尾。\n暂停保留进度；“结束本次”清除进度。原文自动保存在这台 Mac。", size: 12))
        updateUI()
    }
    func textDidChange(_ notification: Notification) { save(); updateUI() }
    func save() {
        if editor.string != lastSave { defaults.set(editor.string, forKey: "draft"); lastSave = editor.string }
        defaults.set(urlField.stringValue, forKey: "documentURL")
        defaults.set(mode.indexOfSelectedItem, forKey: "mode"); defaults.set(speed.indexOfSelectedItem, forKey: "speed")
        defaults.set(lang.indexOfSelectedItem, forKey: "langMode"); defaults.set(typo.indexOfSelectedItem, forKey: "typoMode")
    }
    @objc func openDocument() {
        let text = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https", url.host == "docs.google.com", url.path.hasPrefix("/document/d/") else {
            status.stringValue = "请输入 https://docs.google.com/document/d/… 格式的文档链接。"; return
        }
        pause("打开文档，已暂停。"); save(); NSWorkspace.shared.open(url)
    }
    @objc func permissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func openTest() {
        pause("已暂停。测试区可用于验证中英文输入。")
        if testWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 640, height: 350), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "人类打字机 — 本地输入测试"; w.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: w.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds); text.isRichText = false; text.font = .systemFont(ofSize: 18)
            text.autoresizingMask = [.width]; text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticSpellingCorrectionEnabled = false; text.isAutomaticTextReplacementEnabled = false
            scroll.documentView = text; w.contentView!.addSubview(scroll); testWindow = w
        }
        testWindow!.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    /// 简单快、难词慢：空格与高频字母快，大写/数字/生僻字母慢；
    /// 中文常见字快、生僻字慢；短英文单词爆发快、长单词稍慢；标点额外加时。
    func smartDelay(_ character: Character, base: ClosedRange<Double>) -> Double {
        if character == " " { return Double.random(in: 0.05...0.10) }
        if character == "\n" || character == "\t" { return Double.random(in: base) }
        var factor = 1.0
        if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 {
            let v = scalar.value
            if (0x61...0x7A).contains(v) { // a-z
                factor = "etaoinshrdlu".contains(character) ? 0.8 : ("qxzjkv".contains(character) ? 1.6 : 1.0)
            } else if (0x41...0x5A).contains(v) { // A-Z
                let lower = Character(character.lowercased())
                factor = "qxzjkv".contains(lower) ? 1.8 : 1.5
            } else if (0x30...0x39).contains(v) { // 0-9
                factor = 1.5
            } else if (0x4E00...0x9FFF).contains(v) { // CJK
                factor = DefaultWrongChars.commonHanzi.contains(character) ? 0.9 : 1.3
            } else {
                factor = 1.4
            }
            // 英文单词长度：当前光标所在的字母 run 越短越快。
            if (0x61...0x7A).contains(v) || (0x41...0x5A).contains(v) {
                var start = session.index, end = session.index
                let chars = session.characters
                while start > 0, let s = chars[start - 1].unicodeScalars.first, chars[start - 1].unicodeScalars.count == 1,
                      (0x61...0x7A).contains(s.value) || (0x41...0x5A).contains(s.value) || s.value == 0x27 { start -= 1 }
                while end + 1 < chars.count, let s = chars[end + 1].unicodeScalars.first, chars[end + 1].unicodeScalars.count == 1,
                      (0x61...0x7A).contains(s.value) || (0x41...0x5A).contains(s.value) || s.value == 0x27 { end += 1 }
                let length = end - start + 1
                if length <= 3 { factor *= 0.85 }
                else if length >= 8 { factor *= 1.15 }
            }
        }
        var result = Double.random(in: base) * factor
        if "，。！？；：,.!?;:、".contains(character) { result += 0.35 }
        return min(max(result, 0.05), 1.2)
    }
    @objc func start() {
        guard !session.active else { return }
        guard AXIsProcessTrusted() else { status.stringValue = "请先在辅助功能中允许“人类打字机”，然后再开始。"; return }
        guard sender.canRestore else { status.stringValue = "正在完成上一次粘贴，请稍等一秒再开始。"; return }
        activationRequested = false
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.google.Chrome" || app.bundleIdentifier == "com.microsoft.edgemac" || app.bundleIdentifier == "com.brave.Browser" {
            if accessibleBrowsers.insert(app.processIdentifier).inserted {
                let ax = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(ax, 0.5)
                AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }
        sender.restoreIfReady()
        if session.state == .paused {
            session.resume(now: monotonic())
        } else {
            guard !editor.string.isEmpty else { status.stringValue = "请先粘贴要输入的文本。"; return }
            // 粘贴文本常带看不见的控制字符（Word 软换行等），直接清理后继续，不再整段拒收。
            let (cleaned, removed) = sanitizeInput(editor.string)
            guard !cleaned.isEmpty else { status.stringValue = "清理后没有可输入的内容。"; return }
            if !removed.isEmpty {
                editor.string = cleaned // save() 会随后把它存进本机偏好
                let total = removed.reduce(0) { $0 + $1.1 }
                let detail = removed.prefix(3).map { String(format: "U+%04X×%d", $0.0, $0.1) }.joined(separator: "、")
                startNotice = "（已自动清理 \(total) 个不可见字符：\(detail)）"
            } else {
                startNotice = ""
            }
            session.prepare(cleaned, now: monotonic()); target = nil
            pasteMode = mode.indexOfSelectedItem == 1
            let langMode = TypingSession.LanguageMode(rawValue: lang.indexOfSelectedItem) ?? .chinese
            session.languageMode = langMode
            session.nextChunk = { Int.random(in: langMode.chunkRange) }
            // 新任务的分块按当前语言模式重抽（prepare 里用的是旧闭包）。
            // 注意：prepare 已抽过一次 chunkSize，这里按新语言重抽并重置计数。
            session.rechunkForNewTask()
            let base: ClosedRange<Double>
            switch speed.indexOfSelectedItem {
            case 0: base = 0.08...0.18
            case 2: base = 0.40...0.70
            default: base = 0.22...0.40
            }
            session.delay = { [weak self] character in
                self?.smartDelay(character, base: base) ?? Double.random(in: base)
            }
            switch typo.indexOfSelectedItem {
            case 2:
                session.typoFrequency = .off
            case 1:
                session.typoFrequency = .occasional
            default:
                session.typoFrequency = .frequent
            }
            session.clearTypoState()
        }
        save(); updateUI()
    }
    func pause(_ reason: String) {
        guard session.active else { return }
        session.pause(now: monotonic()); status.stringValue = reason; updateUI()
    }
    @objc func pauseAction() { pause("已暂停，保留进度。点击“开始 / 继续”从下一字接着输入。") }
    @objc func systemSleep() { pause("Mac 即将休眠，已暂停。唤醒后请手动继续。") }
    @objc func reset() {
        pause("已结束。"); session.reset(); target = nil; startNotice = ""
        status.stringValue = "本次已结束。再次开始将从原文第一字输入。"; updateUI()
    }
    func currentTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        targetDiagnostic = "当前前台：\(app.localizedName ?? "未知")"
        // Querying our own AX server synchronously from its main thread can time out.
        if app.processIdentifier == getpid(), let localWindow = NSApp.keyWindow {
            return Target(pid: getpid(), window: AXUIElementCreateApplication(getpid()), title: localWindow.title,
                          document: "", focusedRole: localWindow.firstResponder is NSTextView ? "AXTextArea" : "AXUnknown")
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        guard let value = attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { targetDiagnostic += "，无法读取前台窗口"; return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.5)
        let title = attribute(window, kAXTitleAttribute) as? String ?? ""
        let document = pageURL(window)
        var focusedRole = ""
        if let focused = attribute(element, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            focusedRole = attribute(unsafeBitCast(focused, to: AXUIElement.self), kAXRoleAttribute) as? String ?? ""
        }
        let docShort = document.isEmpty ? "（空）" : String(document.prefix(80))
        targetDiagnostic += " · \(title) · \(focusedRole) · 文档地址=\(docShort)"
        return Target(pid: app.processIdentifier, window: window, title: title, document: document, focusedRole: focusedRole)
    }
    @discardableResult
    func activateLinkedDocument() -> Bool {
        let link = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link), url.host == "docs.google.com", url.path.hasPrefix("/document/d/") else { return false }
        let parts = url.pathComponents
        guard parts.count > 3 else { return false }
        let needle = "/document/d/" + parts[3]
        for app in NSWorkspace.shared.runningApplications {
            guard ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser"].contains(app.bundleIdentifier ?? "") else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.5)
                let document = pageURL(window)
                guard document.contains(needle) else { continue }
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                return true
            }
        }
        return false
    }
    /// nil = 允许输入；非 nil = 拒绝原因（直接展示给用户）。
    /// 把“真的没找到正文”和“找到了正文但是文档 ID 对不上”区分开，
    /// 后者是本次用户遇到的真因：链接里是旧文档 ID，前台是新建的 Untitled 文档。
    func denyReason(_ candidate: Target) -> String? {
        // Browser address bars, document titles, and menus must never receive text.
        if ["AXTextField", "AXComboBox", "AXSearchField", "AXMenuItem", "AXButton"].contains(candidate.focusedRole) {
            return "焦点在\(candidate.focusedRole)（可能是地址栏/工具栏），请用鼠标点一下文档正文、看到光标闪烁后再继续"
        }
        if candidate.pid == getpid() {
            return candidate.title == "人类打字机 — 本地输入测试" ? nil : "请先把 Google Docs 文档切到系统前台"
        }
        let link = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !link.isEmpty {
            guard let url = URL(string: link), url.host == "docs.google.com", url.pathComponents.count > 3 else {
                return "链接格式不对。请粘贴 https://docs.google.com/document/d/… 格式，或清空链接改按标题识别当前窗口"
            }
            let want = url.pathComponents[3]
            if candidate.document.isEmpty {
                return "浏览器没有提供文档地址（读到空），无法确认是不是链接中的文档。请点一次“打开文档”让浏览器暴露地址，或清空链接改按标题识别"
            }
            if !candidate.document.contains("/document/d/" + want) {
                let got = docID(from: candidate.document)
                let wantShort = String(want.prefix(8)) + "…"
                let gotShort = got.isEmpty ? "非文档页" : String(got.prefix(8)) + "…"
                return "当前文档与链接不一致：链接要写 \(wantShort)，当前是 \(gotShort)。请点“打开文档”切到正确文档，或清空链接直接用当前窗口"
            }
        }
        let bundle = NSRunningApplication(processIdentifier: candidate.pid)?.bundleIdentifier ?? ""
        let isBrowser = ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser"].contains(bundle)
        let isDocs = candidate.title.contains("Google Docs") || candidate.title.contains("Google 文档") || candidate.document.contains("docs.google.com/document/")
        if !(isBrowser && isDocs) {
            return "当前不是 Google Docs 文档页。请把 Docs 正文切到前台并点出光标"
        }
        return nil
    }
    func isAllowed(_ candidate: Target) -> Bool {
        denyReason(candidate) == nil
    }
    func matches(_ current: Target, _ saved: Target) -> Bool {
        current.pid == saved.pid && CFEqual(current.window, saved.window) && current.title == saved.title && current.document == saved.document
    }
    @objc func tick() {
        let now = monotonic()
        defer { lastTick = now }
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrust || permissionLabel.stringValue.isEmpty {
            permissionLabel.stringValue = trusted ? "辅助功能：已允许" : "辅助功能：未允许"
            lastTrust = trusted
            if trusted { installMonitors() }
        }
        if !session.active { sender.restoreIfReady(); return }
        if !trusted { pause("权限已失效，已暂停。请在系统设置重新允许本应用。"); return }
        if now - lastTick > 2 { pause("系统停顿或休眠，已暂停。请确认文档后继续。"); return }
        if session.state == .countdown {
            status.stringValue = "倒计时 \(max(0, Int(ceil(session.deadline - now)))) 秒：请点击目标文档正文。\(startNotice)"
            guard now >= session.deadline else { return }
            if !activationRequested && !urlField.stringValue.isEmpty {
                activationRequested = true
                if !activateLinkedDocument() {
                    status.stringValue = "链接中的文档没有在浏览器里找到，已停在当前前台页。请先用“打开文档”开一次，或清空链接。"
                }
                return
            }
            guard let current = currentTarget() else {
                pause("未找到前台窗口。\(targetDiagnostic)。请把 Google Docs 正文切到前台并点出光标。"); return
            }
            if let reason = denyReason(current) {
                pause("\(reason)。\(targetDiagnostic)。"); return
            }
            if let target, !matches(current, target) {
                pause("当前窗口或文档与原目标不一致。请回到原文档继续。"); return
            }
            target = current; targetLabel.stringValue = "目标：\(current.title)"
            session.finishCountdown(now: now)
        }
        guard let target, let current = currentTarget() else {
            pause("窗口或文档已切换，自动暂停。请回到原文档后继续。\(targetDiagnostic)。"); return
        }
        if let reason = denyReason(current) {
            pause("\(reason)。\(targetDiagnostic)。"); return
        }
        guard matches(current, target) else {
            pause("窗口或文档已切换，自动暂停。请回到原文档后继续。\(targetDiagnostic)。"); return
        }
        // Never combine injected typing with a physically held modifier key.
        let modifiers = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if !modifiers.isEmpty { pause("检测到修饰键按下，已暂停。松开后可继续。"); return }
        if session.state == .resting, now < session.deadline {
            status.stringValue = "已发送 \(session.index)/\(session.characters.count) 字 · 停顿 \(String(format: "%.1f", session.deadline - now)) 秒"
            return
        }
        guard session.ready(now: now), let action = session.pendingAction else { return }
        do {
            switch action {
            case .type(let ch, _):
                try sender.send(ch, paste: pasteMode)
            case .backspace:
                try sender.backspace()
            }
            session.didPerform(action, now: monotonic())
            if session.state == .completed {
                status.stringValue = "发送完成，共 \(session.index) 字。请在文档中核对结果。"
            } else if session.inTypo {
                status.stringValue = "输入中 · 已发送 \(session.index)/\(session.characters.count) 字 · 纠错中"
            } else {
                status.stringValue = "输入中 · 已发送 \(session.index)/\(session.characters.count) 字"
            }
            updateUI()
        } catch { pause(error.localizedDescription) }
    }
    func handle(_ event: NSEvent) -> Bool {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == eventMarker { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown && flags == [.control, .option] {
            if event.keyCode == 1 { if !event.isARepeat { start() }; return true }
            if event.keyCode == 14 { pauseAction(); return true }
        }
        if session.state == .typing || session.state == .resting {
            pause("检测到手动操作，已暂停。确认插入位置后可继续。")
        }
        return false
    }
    func installMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in _ = self?.handle(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event) == true ? nil : event }
    }
    func updateUI() {
        let langName = lang.indexOfSelectedItem == 1 ? "英文模式" : "中文模式"
        count.stringValue = "原文 \(editor.string.count) 字（空格、标点、换行各计 1 字；组合 emoji 计 1 字）· \(langName)"
        let locked = session.active || session.state == .paused
        editor.isEditable = !locked; mode.isEnabled = !locked; speed.isEnabled = !locked; urlField.isEnabled = !locked
        lang.isEnabled = !locked; typo.isEnabled = !locked
        startButton?.isEnabled = !session.active
        pauseButton?.isEnabled = session.active
        resetButton?.isEnabled = session.state != .idle
        progress.doubleValue = session.characters.isEmpty ? 0 : Double(session.index) / Double(session.characters.count)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        pause("已停止。"); save()
        // Let the target consume a pending paste before restoring the pasteboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            self.sender.restoreIfReady(force: true); sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
