#!/bin/zsh
# Run the TypingSession regression tests (Swift compiler required).
# 运行状态机回归测试（需要 Swift 编译器）。
set -euo pipefail
cd "${0:A:h}"
mkdir -p work
xcrun swiftc -O native/TypingSession.swift tests/main.swift -o work/session-tests -framework AppKit -framework ApplicationServices
./work/session-tests
