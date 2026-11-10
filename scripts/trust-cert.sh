#!/usr/bin/env bash
# 导入并信任 MoShot 的本地签名证书（每个终端只需跑一次，可重入）。
#
# 为什么需要：MoShot 用自签证书签名，代码要求是
#   identifier "com.moxian.moshot" and certificate root = H"366ac569..."
# 证书只在钥匙串里存在、并且被标为信任根时，身份才完整可用；否则 TCC 匹配
# 屏幕录制授权记录时会报「Failed to match existing code requirement」，
# 表现为设置里勾了却一直要授权。
#
# 只做两件事：
#   1) 把 Resources/MoShotSigning.cer 导入登录钥匙串，并授权 codesign 使用
#   2) 只对 codeSign 策略标信任根（不动 SSL / 邮件等其它策略）
#
# 用法：
#   ./scripts/trust-cert.sh                # 默认用包内证书
#   ./scripts/trust-cert.sh /path/x.cer    # 指定证书文件
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT="${1:-$ROOT/Resources/MoShotSigning.cer}"
CN="MoShot Local Signing"
EXPECTED_SHA1="366ac5692982edc6f7ca6f547069ed428d312a2d"
KC="$HOME/Library/Keychains/login.keychain-db"

if [[ ! -f "$CERT" ]]; then
  echo "ERROR: 证书文件不存在：$CERT" >&2
  exit 1
fi

GOT_SHA1="$(openssl x509 -inform der -in "$CERT" -noout -fingerprint -sha1 2>/dev/null \
  | sed 's/^.*=//; s/://g' | tr 'A-Z' 'a-z')"
if [[ -z "$GOT_SHA1" ]]; then
  GOT_SHA1="$(openssl x509 -in "$CERT" -noout -fingerprint -sha1 2>/dev/null \
    | sed 's/^.*=//; s/://g' | tr 'A-Z' 'a-z')"
fi
if [[ "$GOT_SHA1" != "$EXPECTED_SHA1" ]]; then
  echo "ERROR: 证书指纹不符，期望 $EXPECTED_SHA1，实际 ${GOT_SHA1:-无法解析}" >&2
  exit 1
fi

echo "==> certificate: $CERT (sha1=$GOT_SHA1)"

if security find-certificate -c "$CN" -Z "$KC" 2>/dev/null | grep -qi "$EXPECTED_SHA1"; then
  echo "==> cert already in login keychain"
else
  echo "==> importing cert into login keychain"
  # -T 允许 codesign 与 security 直接使用该证书，避免每次签名弹授权
  security import "$CERT" -k "$KC" -T /usr/bin/codesign -T /usr/bin/security
fi

if security dump-trust-settings 2>/dev/null | grep -q "$CN"; then
  echo "==> trust settings already present (codeSign)"
else
  echo "==> marking cert as trusted root for code signing (may ask for your password)"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$CERT"
fi

echo "==> verifying"
if security find-identity -p codesigning -v | grep -qi "$EXPECTED_SHA1"; then
  echo "OK: 签名身份可用（valid identity）"
else
  echo "ERROR: 身份仍不可用。请在钥匙串访问里确认「$CN」已导入且信任设置为「代码签名：始终信任」。" >&2
  exit 1
fi
