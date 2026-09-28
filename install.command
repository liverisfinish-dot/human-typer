#!/bin/zsh
# Install the built app to ~/Desktop (double-click to run).
# 将构建好的 App 安装到桌面（双击运行）。
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/packaging/人类打字机.app"
if [[ ! -x "$APP/Contents/MacOS/AutoTyper" ]]; then
  echo "请先运行 ./build.command 先构建 (build first)."
  exit 1
fi
if pgrep -f "人类打字机.app/Contents/MacOS/AutoTyper" >/dev/null; then
  echo "人类打字机正在运行，请先退出再安装 (quit the app first)."
  exit 1
fi
rm -rf "$HOME/Desktop/人类打字机.app"
cp -R "$APP" "$HOME/Desktop/人类打字机.app"
echo "已安装到桌面 Installed: $HOME/Desktop/人类打字机.app"
