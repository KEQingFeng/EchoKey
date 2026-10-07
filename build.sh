#!/bin/bash
# 构建 EchoKey.app（原生 Swift，无需 Xcode / Homebrew）
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/dist/EchoKey.app"
BIN="$APP/Contents/MacOS/EchoKey"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "✗ 找不到 xcrun，请先安装命令行工具：xcode-select --install"
  exit 1
fi
SDK="$(xcrun --show-sdk-path)"

echo "==> 编译 main.swift"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -sdk "$SDK" -o "$BIN" "$DIR/Sources/main.swift" \
  -framework Cocoa -framework CoreGraphics -framework ApplicationServices -framework IOKit

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>EchoKey</string>
  <key>CFBundleDisplayName</key><string>EchoKey</string>
  <key>CFBundleIdentifier</key><string>com.echokey.app</string>
  <key>CFBundleExecutable</key><string>EchoKey</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "==> 签名（优先用稳定证书，TCC 权限才不会被每次重建重置）"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
if [ -n "$IDENTITY" ]; then
  echo "    使用证书：$IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP" || \
    codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (跳过签名)"
else
  echo "    未找到可用证书，回退 ad-hoc（注意：每次重建都会丢失系统权限）"
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (跳过签名)"
fi

echo "✅ 构建完成：$APP"
