#!/usr/bin/env bash
# Build MoShot.app with the system Swift toolchain (no Xcode project needed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/MoShot.app"
BIN="$APP/Contents/MacOS/MoShot"

echo "==> cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling"
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -framework Cocoa \
  -framework ScreenCaptureKit \
  -framework Vision \
  -framework CoreImage \
  -o "$BIN" \
  "$ROOT"/Sources/*.swift

echo "==> packaging"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 签名：本地自签证书（MoShot Local Signing）。
#
# 为什么不用 ad-hoc：ad-hoc 的 designated requirement 是 cdhash，屏幕录制授权绑在这个
# 哈希上，重新编译就变，系统日志报 "Failed to match existing code requirement"，
# 表现为「设置里勾了但一直提示要授权」。
#
# 为什么不用 Apple Development 证书：本机那张已被 Apple 吊销（CSSMERR_TP_CERT_REVOKED）。
#
# 自签证书的 requirement 是 "identifier + certificate root = H<...>"，与二进制内容无关，
# 重建不掉授权；本地构建无 quarantine 属性，Gatekeeper 也不会拦。
# 证书私钥在本机登录钥匙串（CN=MoShot Local Signing），换机器需重新生成。
echo "==> signing"
SIGN_ID="${MOSHOT_SIGN_ID:-MoShot Local Signing}"
# 注意：自签证书不出现在 find-identity -p codesigning 列表里（未标记信任根），
# 但 codesign 能用它的私钥签名，所以这里直接试签，失败才退回 ad-hoc。
if codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" >/dev/null 2>&1; then
  echo "    signed: $SIGN_ID"
else
  echo "    (证书签名失败，退回 ad-hoc；重建后要重新授权)"
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

echo "==> done: $APP"
