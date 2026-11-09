#!/bin/bash
# MacPaste 打包：swiftc 直接编译（绕开 SwiftPM 的 sandbox/manifest 机制）→ 组装 .app → ad-hoc 签名
# 固定 SDK：CLT 缺 libSwiftUIMacros.dylib 插件，27.0 SDK 的 SwiftUI @State 已改为宏无法编译，26.5 SDK 正常
set -e
cd "$(dirname "$0")/.."

if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
elif [ -z "$SDKROOT" ]; then
  export SDKROOT="$(xcrun --show-sdk-path 2>/dev/null || true)"
fi

echo "==> swiftc release 编译"
mkdir -p build/bin
swiftc -O -target arm64-apple-macos13.0 -lsqlite3 \
  $(find Sources/MacPaste -name '*.swift' | sort) \
  -o build/bin/MacPaste

echo "==> 组装 .app"
APP=build/MacPaste.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp build/bin/MacPaste "$APP/Contents/MacOS/MacPaste"
strip -x "$APP/Contents/MacOS/MacPaste"
cp App/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 稳定身份签名：自签名证书（MacPaste Developer）保证 TCC 辅助功能授权跨重打包持久有效
if security find-identity -v -p codesigning | grep -q "MacPaste Developer"; then
  codesign --force --deep -s "MacPaste Developer" "$APP"
  echo "==> 已用稳定身份 MacPaste Developer 签名"
else
  codesign --force --deep -s - "$APP"
  echo "==> 未找到稳定身份，回退 ad-hoc 签名（辅助功能授权将随重打包失效）"
fi

echo "✅ 打包完成: $(pwd)/$APP"
