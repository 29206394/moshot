#!/usr/bin/env bash
# Build MoShot.app with the system Swift toolchain (no Xcode project needed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/MoShot.app"
BIN="$APP/Contents/MacOS/MoShot"

# 签名身份与证书根（跨版本必须不变；变了 TCC 里的屏幕录制授权全部失效）
SIGN_ID="${MOSHOT_SIGN_ID:-MoShot Local Signing}"
EXPECTED_ROOT="366ac5692982edc6f7ca6f547069ed428d312a2d"
CERT="$ROOT/Resources/MoShotSigning.cer"

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
# 证书随包分发：目标机器跑 scripts/trust-cert.sh 导入并标信任
cp "$CERT" "$APP/Contents/Resources/MoShotSigning.cer"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 签名：本地自签证书（MoShot Local Signing）。
#
# 为什么不用 ad-hoc：ad-hoc 的 designated requirement 是 cdhash，屏幕录制授权绑在
# 这个哈希上，重新编译就变，系统日志报 "Failed to match existing code requirement"，
# 表现为「设置里勾了但一直提示要授权」。
#
# 为什么不用 Apple Development 证书：本机那张已被 Apple 吊销（CSSMERR_TP_CERT_REVOKED）。
#
# 自签证书的 requirement 是 "identifier + certificate root = H<...>"，与二进制内容无关，
# 重建不掉授权；本地构建无 quarantine 属性，Gatekeeper 也不会拦。
# 证书私钥在本机登录钥匙串（CN=MoShot Local Signing），换机器需重新生成。
#
# 签名失败一律硬失败：静默退回 ad-hoc 会让下一次重建悄悄丢掉授权，问题更难查。
echo "==> signing"
if ! codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"; then
  echo "ERROR: 签名失败，身份 '$SIGN_ID' 不可用。" >&2
  echo "       私钥必须在登录钥匙串；目标机器先跑 ./scripts/trust-cert.sh" >&2
  echo "       不退回 ad-hoc：ad-hoc 的 DR 是 cdhash，重建即掉屏幕录制授权。" >&2
  # 删掉半成品，避免有人把 linker-signed 的 ad-hoc 包误发出去
  rm -rf "$APP"
  exit 1
fi

echo "==> verifying"
codesign --verify --deep --strict "$APP"

DR="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
IDENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
ROOT_ACTUAL="$(printf '%s' "$DR" | sed -n 's/.*certificate root = H"\([0-9a-fA-F]*\)".*/\1/p' | tr 'A-Z' 'a-z')"

if [[ "$ROOT_ACTUAL" != "$EXPECTED_ROOT" ]]; then
  echo "ERROR: designated requirement 的证书根不符。" >&2
  echo "       期望: $EXPECTED_ROOT" >&2
  echo "       实际: ${ROOT_ACTUAL:-无法解析}" >&2
  echo "       DR: $IDENT" >&2
  exit 1
fi
if [[ "$DR" != *"identifier \"com.moxian.moshot\""* ]]; then
  echo "ERROR: designated requirement 的 identifier 不是 com.moxian.moshot：$DR" >&2
  exit 1
fi

CDHASH="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
echo "    signed:   $SIGN_ID"
echo "    cdhash:   $CDHASH"
echo "    DR:       $DR"
echo "==> done: $APP"
