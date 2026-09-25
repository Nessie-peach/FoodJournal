#!/bin/bash
# ios-devmode.sh —— 用命令行查看 / 等待 iPhone 的「开发者模式」状态
#
# 背景（重要）：iOS 16 起，"开发者模式"是设备侧的安全开关，
# 苹果没有提供任何 Mac 端命令可以代你按下它 —— Xcode 图形界面也不行。
# Mac 端命令行能做的三件事：
#   1. 配对设备（让开关出现在手机设置里）
#   2. 读取当前状态（developerModeStatus / DDI 是否可用）
#   3. 轮询等待你手动打开后自动确认
#
# 手机上要做的（必须在手机上）：
#   设置 → 隐私与安全性 → 开发者模式 → 打开 → 按提示重启
#   重启后解锁屏幕 → 弹窗「打开开发者模式？」→ 点「打开」→ 输入锁屏密码
#
# 用法：
#   ./ios-devmode.sh status        查看设备与开发者模式状态
#   ./ios-devmode.sh pair          与新设备配对（手机需解锁并点「信任」）
#   ./ios-devmode.sh wait [分钟]   轮询等待直到开发者模式开启（默认 30 分钟）
#   ./ios-devmode.sh ready         就绪检查 + 打印可用的 xcodebuild destination
#
# 环境变量：
#   DEVICE_UDID   手动指定设备（默认自动挑选唯一插线的 iOS 真机）
#   DEVELOPER_DIR 默认 /Applications/Xcode.app/Contents/Developer
set -u

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PY="${PY:-/usr/bin/python3}"
UDID="${DEVICE_UDID:-}"

die() { printf '错误：%s\n' "$1" >&2; exit 1; }

find_udid() {
  xcrun devicectl list devices --timeout 60 --json-output - 2>/dev/null | "$PY" -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
out = []
for dev in d.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {}) or {}
    if hw.get("platform") == "iOS" and hw.get("reality") == "physical":
        out.append(hw.get("udid") or dev.get("identifier"))
print("\n".join(out))
'
}

resolve_udid() {
  if [ -n "$UDID" ]; then echo "$UDID"; return; fi
  local list
  list="$(find_udid)"
  if [ -z "$list" ]; then
    die "没有检测到插线并已配对的 iOS 真机。请用数据线连接 iPhone，解锁并点「信任此电脑」。"
    return
  fi
  local n
  n="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
  if [ "$n" -gt 1 ]; then
    die "检测到多台真机，请用 DEVICE_UDID=<UDID> 指定：
$list"
    return
  fi
  echo "$list"
}

details() {
  xcrun devicectl device info details --device "$1" --timeout 60 --json-output - 2>/dev/null
}

show() {
  local json
  json="$(details "$1")" || true
  [ -z "$json" ] && die "读取设备信息失败（设备未连接或未配对？）"
  printf '%s' "$json" | "$PY" -c '
import json,sys
d = json.load(sys.stdin)
r = d.get("result", {})
dp = r.get("deviceProperties", {}) or {}
cp = r.get("connectionProperties", {}) or {}
hw = r.get("hardwareProperties", {}) or {}
mode = dp.get("developerModeStatus", "unknown")
ddi = dp.get("ddiServicesAvailable")
print("设备      : %s (%s)" % (dp.get("name"), hw.get("marketingName")))
print("UDID      : %s" % (hw.get("udid") or r.get("identifier")))
print("系统      : iOS %s (%s) %s" % (dp.get("osVersionNumber"), dp.get("osBuildUpdate"), dp.get("releaseType", "")))
print("连接      : %s / %s / tunnel=%s" % (cp.get("transportType"), cp.get("pairingState"), cp.get("tunnelState")))
print("开发者模式: %s" % mode)
print("DDI 服务  : %s" % ("可用" if ddi else "不可用"))
print("READY=%s" % ("1" if mode == "enabled" and ddi else "0"))
'
}

require_udid() {
  local u; u="$(resolve_udid)"
  [ -n "$u" ] || exit 1
  echo "$u"
}

cmd_status() {
  local u; u="$(require_udid)"
  local out; out="$(show "$u")"
  printf '%s\n' "$out" | grep -v '^READY='
  local ready
  ready="$(printf '%s' "$out" | awk -F= '/^READY=/{print $2}')"
  if [ "$ready" = "1" ]; then
    echo
    echo "设备已就绪，可以直接真机调试。destination 写法："
    printf "  -destination 'platform=iOS,id=%s'\n" "$u"
  else
    echo
    echo "尚未就绪 —— 请在 iPhone 上操作："
    echo "  设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启 → 解锁后确认「打开」"
    echo "完成后运行：$0 wait    （或直接 $0 status 复查）"
  fi
}

cmd_pair() {
  local u; u="$(require_udid)"
  echo "正在与 $u 配对（手机需解锁，出现弹窗时点「信任」）..."
  xcrun devicectl manage pair --device "$u" || die "配对失败"
  echo "配对完成。"
}

cmd_wait() {
  local minutes="${1:-30}"
  local deadline=$(( $(date +%s) + minutes * 60 ))
  local u; u="$(require_udid)"
  echo "等待 $u 打开开发者模式（最多 $minutes 分钟）..."
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local out ready mode
    out="$(show "$u")"
    mode="$(printf '%s' "$out" | awk -F': ' '/^开发者模式/{print $2}')"
    ready="$(printf '%s' "$out" | awk -F= '/^READY=/{print $2}')"
    printf '[%s] 开发者模式=%s\n' "$(date '+%H:%M:%S')" "$mode"
    if [ "$ready" = "1" ]; then
      echo
      echo "已开启，设备就绪。"
      printf "  -destination 'platform=iOS,id=%s'\n" "$u"
      return 0
    fi
    sleep 10
  done
  die "超时：$minutes 分钟内仍未开启。请确认已在手机上打开开关并完成重启确认。"
}

cmd_ready() {
  local u; u="$(require_udid)"
  local out ready
  out="$(show "$u")"; printf '%s\n' "$out"
  ready="$(printf '%s' "$out" | awk -F= '/^READY=/{print $2}')"
  [ "$ready" = "1" ] || die "设备尚未就绪，先完成开发者模式开启（见 $0 status 的提示）。"
  echo
  echo "连通性自检："
  xcrun devicectl device info lockState --device "$u" --timeout 30 2>&1 | tail -5
  echo
  printf "xcodebuild destination： -destination 'platform=iOS,id=%s'\n" "$u"
}

case "${1:-status}" in
  status) cmd_status ;;
  pair)   cmd_pair ;;
  wait)   cmd_wait "${2:-30}" ;;
  ready)  cmd_ready ;;
  *)      sed -n '2,25p' "$0"; exit 1 ;;
esac
