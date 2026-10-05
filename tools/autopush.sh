#!/bin/bash
# autopush.sh —— 定时把本仓库「已提交但未推送」的内容推到 GitHub
#
# 用法：
#   ./autopush.sh run        执行一次（launchd 每 10 分钟调它）
#   ./autopush.sh install    安装并加载 launchd 定时任务
#   ./autopush.sh uninstall  卸载
#   ./autopush.sh status     查看状态与最近日志
#   ./autopush.sh test       立即触发一次（不用等 10 分钟）
#
# 开关（写入 launchd 环境变量才生效，见 install 生成的文件）：
#   AUTO_COMMIT=1  工作区有改动、且最近 QUIET_MIN 分钟内没有文件被写入时，自动提交后再推
#                  默认 0（只推已提交内容，避免把其他会话的半成品自动提交）
#   QUIET_MIN=15   静默判定分钟数
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"   # pwd -P：解析软链接，保证 launchd 用的是物理真实路径
BRANCH=main
REMOTE=origin
LOG="$HOME/Library/Logs/foodjournal-autopush.log"
PLIST="$HOME/Library/LaunchAgents/com.pigeon.foodjournal-autopush.plist"
LABEL="com.pigeon.foodjournal-autopush"
AUTO_COMMIT="${AUTO_COMMIT:-0}"
QUIET_MIN="${QUIET_MIN:-15}"

export GIT_TERMINAL_PROMPT=0
export REPO

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

do_push() {
  cd "$REPO" || { log "仓库目录不存在"; return 1; }
  git rev-parse --git-dir >/dev/null 2>&1 || { log "不是 git 仓库"; return 1; }

  if [ "$AUTO_COMMIT" = "1" ] && [ -n "$(git status --porcelain)" ]; then
    quiet="$(git status --porcelain | /usr/bin/python3 -c '
import os, sys, time
q = int(sys.argv[1]); now = time.time(); newest = 0.0
repo = os.environ.get("REPO", ".")
for line in sys.stdin:
    p = line[3:].strip().strip("\"")
    fp = os.path.join(repo, p)
    if os.path.isfile(fp):
        newest = max(newest, os.path.getmtime(fp))
print(1 if newest and (now - newest) > q * 60 else 0)
' "$QUIET_MIN")"
    if [ "$quiet" = "1" ]; then
      if git add -A && git commit -q -m "chore(auto): 定时快照 $(date '+%F %H:%M')"; then
        log "自动提交：$(git log -1 --format=%s)"
      fi
    fi
  fi

  ahead="$(git rev-list --count "$REMOTE/$BRANCH..$BRANCH" 2>/dev/null || echo 0)"
  if [ "${ahead:-0}" -gt 0 ]; then
    if git push "$REMOTE" "$BRANCH" >>"$LOG" 2>&1; then
      log "已推送 $ahead 个提交"
    else
      log "推送失败（$ahead 个提交待推），下一轮重试"
      return 1
    fi
  fi
  return 0
}

install_agent() {
  mkdir -p "$(dirname "$PLIST")"
  cat >"$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO}/tools/autopush.sh</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AUTO_COMMIT</key><string>${AUTO_COMMIT}</string>
    <key>QUIET_MIN</key><string>${QUIET_MIN}</string>
  </dict>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/foodjournal-autopush.out.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/foodjournal-autopush.err.log</string>
</dict>
</plist>
PLISTEOF
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null
  if out="$(launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>&1)"; then
    echo "已安装并加载：${PLIST}（每 10 分钟一次，AUTO_COMMIT=${AUTO_COMMIT}）"
    log "安装 launchd 任务，AUTO_COMMIT=$AUTO_COMMIT"
  else
    echo "加载失败：$out"
    echo "→ 受沙箱限制无法访问 launchd，请在**你自己的终端**执行："
    echo "   launchctl bootstrap gui/\$(id -u) \"$PLIST\""
    log "launchd 加载失败：$out"
    return 1
  fi
}

uninstall_agent() {
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null
  rm -f "$PLIST"
  echo "已卸载（日志保留在 ${LOG}）"
}

status_agent() {
  echo "仓库      : $REPO"
  echo "分支      : $BRANCH → $REMOTE"
  echo "launchd   : $([ -f "$PLIST" ] && echo "已安装 $PLIST" || echo "未安装")"
  launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|last exit code|runs" | head -4
  echo "待推送提交: $(cd "$REPO" && git rev-list --count "$REMOTE/$BRANCH..$BRANCH" 2>/dev/null || echo '?')"
  echo "--- 最近 5 条日志 ---"
  tail -5 "$LOG" 2>/dev/null || echo "(暂无日志)"
}

case "${1:-run}" in
  run)       do_push ;;
  install)   install_agent ;;
  uninstall) uninstall_agent ;;
  status)    status_agent ;;
  test)      launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null && echo "已触发一次，3 秒后看 status" || { echo "任务未安装，直接执行 run："; do_push; } ;;
  *)         sed -n '2,20p' "$0" ;;
esac
