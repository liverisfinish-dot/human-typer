# 人类打字机 HumanTyper · macOS 原生版

> English quick start at the bottom. [English](#english-quick-start)

一个 macOS 原生小工具：把准备好的文本，用**人类打字节奏**一个字一个字敲进 Google Docs（或任何浏览器文档页）。
不依赖 Python、不联网下载组件、不碰剪贴板（默认模式），退出即焕然一新。

- 三档速度：极速 0.08–0.18 秒/字，正常 0.22–0.40，慢速 0.40–0.70；三档都带"简单快、困难慢"（空格/高频字母/短单词快，大写/数字/生僻字/长单词慢，标点额外加时）
- 中英文两种停顿：中文每随机 10–20 字、英文每随机 60–80 字固定停顿 5 秒，**停顿前一定打完整个词**
- 逼真打错：整词打成相近词（英文邻键/换位，中文换字）→ 停顿 → 退格删掉整个词 → 重打；频率可调（频繁/偶尔/关闭）
- 目标保护：锁定窗口 + 文档地址，切换窗口/手动按键/休眠自动暂停，暂停保留进度
- 随时启停：`Control + Option + S` 开始/继续，`Control + Option + E` 暂停；黏贴文本里的隐形控制字符自动清理

## 环境要求

- macOS 13+，Apple 芯片（ARM64）
- Apple Command Line Tools（提供 Swift 编译器）：`xcode-select --install`
- Chrome / Edge / Safari / Firefox / Brave（写 Google Docs 用 Chrome 最稳）
- 不需要 Python，不需要 `pip install` 任何东西

## 三步跑起来

```sh
git clone <你的仓库地址> human-typer && cd human-typer
./build.command    # 双击也行：编译出 packaging/人类打字机.app
./install.command  # 双击也行：安装到桌面
```

然后双击桌面的"人类打字机"：

1. 粘贴文本（可选填 Google Docs 链接 + "打开文档"定位已打开的文档）
2. 系统设置 → 隐私与安全性 → 辅助功能，允许"人类打字机"（首次一次，以后不用管）
3. 点"开始 / 继续"，5 秒内切到 Docs 正文点出光标 → 自动开打

从 Word/网页粘贴带进来的隐形字符（软换行等）会自动清理并告诉你清理了几个。

## 项目结构

```
human-typer/
  native/TypingSession.swift  # 可注入时钟的输入状态机（分块停顿/整词打错/词边界）
  native/main.swift           # AppKit 界面、权限、键盘发送、前台目标保护
  tests/main.swift            # 状态机回归测试（Unicode/停顿/暂停续打/纠错）
  resources/Info.plist        # App 元信息（含 bundle id）
  assets/                     # 图标（AppIcon.icns + 生成脚本）
  build.command               # 编译
  test.command                # 回归测试（双击运行）
  install.command             # 安装到桌面
  run.command                 # 打开构建好的 App
```

`./test.command` 跑 11000+ 断言：Unicode、倒计时、精确 5 秒停顿、暂停续打、一万字长跑、整词纠错序列。

## 自己改

- 换包名：改 `build.command` 里的 `BUNDLE_ID`（改完要在系统设置里重新允许辅助功能）
- 调手感：`native/main.swift` 的 `smartDelay`（变速）、`native/TypingSession.swift` 的打错概率（`0.22`/`0.06`）、分块（`chunkRange`）
- 图标：`assets/make_icon.py`（需 Pillow），生成后用 `iconutil` 转 icns 也行

## 许可与免责

本项目 dedication 到公有领域（见 `UNLICENSE`，即 The Unlicense）：随便用、随便改、随便商用。

请负责任地使用：它只是帮你把**你自己的文字**敲进**你自己的文档**；别拿去刷屏、作弊或违反目标网站的使用条款。重要文本打完请核对一遍。

---

## English Quick Start

HumanTyper types your prepared text into Google Docs with a human rhythm on macOS (ARM64, macOS 13+).
No Python, no downloads at runtime — just Swift + Apple Command Line Tools.

```sh
git clone <repo-url> human-typer && cd human-typer
./build.command    # compiles packaging/人类打字机.app (or double-click it)
./install.command  # installs to ~/Desktop (or double-click it)
```

1. Paste your text (optionally add a Google Docs link + "Open" to locate the doc).
2. Grant Accessibility permission once: System Settings → Privacy & Security → Accessibility.
3. Hit Start, click into the Docs body within 5 seconds — it types, rests 5s every 10–20 (Chinese) / 60–80 (English) chars, makes human-like whole-word typos and corrects them.

 `./test.command` runs 11,000+ regression assertions. Public domain — see `UNLICENSE`. Use responsibly: your own words, your own docs.
