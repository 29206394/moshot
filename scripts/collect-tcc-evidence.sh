#!/usr/bin/env bash
# MoShot 屏幕录制授权取证（只读：不改 TCC、不改钥匙串、不改 App）
#
# 用法：./scripts/collect-tcc-evidence.sh [输出文件]
# 默认输出到 /tmp/moshot-tcc-<时间戳>.txt
set -uo pipefail

OUT="${1:-/tmp/moshot-tcc-$(date +%Y%m%d-%H%M%S).txt}"
APP="/Applications/MoShot.app"
BID="com.moxian.moshot"
CN="MoShot Local Signing"

exec > >(tee "$OUT") 2>&1

echo "== MoShot TCC evidence =="
echo "collected_at: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "host: $(hostname -s)  macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "sip: $(csrutil status 2>/dev/null | head -1)"

echo
echo "-- app --"
if [[ -d "$APP" ]]; then
  codesign -dvvv "$APP" 2>&1 | grep -E "Executable=|Identifier=|Authority=|CDHash=|TeamIdentifier=|Signed Time="
  codesign -d -r- "$APP" 2>&1 | tail -1
  codesign --verify --deep --strict "$APP" 2>&1 && echo "codesign_verify=ok" || echo "codesign_verify=FAILED"
  /usr/bin/xattr -p com.apple.quarantine "$APP" 2>/dev/null && echo "quarantine=present" || echo "quarantine=none"
else
  echo "app_not_found: $APP"
fi

echo
echo "-- signing identity in keychain --"
security find-identity -p codesigning 2>&1 | head -10
echo "--- cert presence (login keychain) ---"
security find-certificate -c "$CN" -Z "$HOME/Library/Keychains/login.keychain-db" 2>&1 | grep -E "SHA-1 hash|keychain" || echo "cert_not_in_login_keychain"
echo "--- trust settings (user) ---"
security dump-trust-settings 2>/dev/null | grep -A4 "$CN" || echo "no_user_trust_settings_for_$CN"

echo
echo "-- tccd (last 15 min, subject=$BID) --"
log show --last 15m --predicate "process == \"tccd\" AND eventMessage CONTAINS[c] \"$BID\"" --style compact 2>/dev/null \
  | grep -E "AUTHREQ_CTX|AUTHREQ_SUBJECT|AUTHREQ_RESULT|Failed to match" | tail -40 \
  || echo "no_tccd_entries"

echo
echo "-- permission log --"
if [[ -f /tmp/moshot-perm.log ]]; then
  tail -60 /tmp/moshot-perm.log
else
  echo "no /tmp/moshot-perm.log (1.1.1 之前没有这条日志)"
fi

echo
echo "== saved: $OUT =="
