#!/bin/zsh
# Build the native macOS app (Apple Command Line Tools required, no network, no deps).
set -euo pipefail
cd "${0:A:h}"
BUNDLE_ID="com.humantyper.HumanTyper"
VERSION="2.1"
APP="$PWD/packaging/人类打字机.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" work
xcrun swiftc -O -target arm64-apple-macosx13.0 native/TypingSession.swift native/main.swift -o work/AutoTyper -framework AppKit -framework ApplicationServices
cp work/AutoTyper "$APP/Contents/MacOS/AutoTyper"
cp resources/Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
# A stable designated requirement keeps this local app's identity across rebuilds.
codesign --force --sign - --identifier "$BUNDLE_ID" --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --deep --strict "$APP"
echo "构建完成 Build done: $APP"
echo "安装到桌面 Install to Desktop: ./install.command"
