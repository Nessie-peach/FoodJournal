#!/bin/bash
# scan-secrets.sh —— 公开仓库提交前的敏感信息扫描
#
# 用法：
#   ./tools/scan-secrets.sh            扫当前跟踪的文件（快）
#   ./tools/scan-secrets.sh --history  连全部历史一起扫（慢，历史对公众同样可见）
#
# 退出码：0 = 无高危命中；1 = 有高危命中（应当阻断提交）
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO" || exit 1
MODE="${1:-}"

/usr/bin/python3 - "$MODE" <<'PY'
import os, re, subprocess, sys

mode = sys.argv[1] if len(sys.argv) > 1 else ""
user = os.environ.get("USER", "pigeon")

HIGH = {
    "GitHub 令牌": r"(ghp_|github_pat_|gho_|ghs_)[A-Za-z0-9_]{20,}",
    "云厂商 Key": r"(sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|LTAI[A-Za-z0-9]{12,})",
    "私钥块": r"-----BEGIN [A-Z ]*PRIVATE KEY",
    "JWT": r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.",
    "Bearer 长串": r"Bearer\s+[A-Za-z0-9._-]{24,}",
    "赋值式密钥": r"""(?i)(api[_-]?key|apikey|secret|password|passwd|access[_-]?token)\s*[:=]\s*["']([A-Za-z0-9_\-]{16,})["']""",
}
LOW = {
    "设备 UDID": r"[0-9A-F]{8}-[0-9A-F]{16}",
    "本机用户路径": r"/Users/" + re.escape(user) + r"/",
    "非示例邮箱": r"[A-Za-z0-9._%+-]+@(?!example\.com|example\.org|test\.com)[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
    "钥匙串服务名": r"dietapp-[a-z0-9-]+",
    "Apple 团队 ID": r"DEVELOPMENT_TEAM[^\n]*[A-Z0-9]{10}",
}


def mask(s: str) -> str:
    return s if len(s) <= 8 else s[:5] + "…" + s[-3:]


ALLOW = "scan-secrets:allow"          # 行内标记：该行跳过扫描
IGNORE_FILE = "scan-secrets:ignore-file"  # 文件头 20 行内出现则整个文件跳过


def check(name: str, text: str, sink: dict):
    lines = text.splitlines()
    if any(IGNORE_FILE in ln for ln in lines[:20]):
        return
    for label, pat in {**HIGH, **LOW}.items():
        for m in re.finditer(pat, text):
            ln = text.count("\n", 0, m.start())
            if ln < len(lines) and ALLOW in lines[ln]:
                continue
            sink.setdefault(label, []).append((f"{name}:{ln + 1}", mask(m.group(0))))


hits: dict = {}
if mode == "--history":
    commits = subprocess.run(["git", "rev-list", "--all"], capture_output=True, text=True).stdout.split()
    files = subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split("\n")
    for f in files:
        if not f or not os.path.isfile(f):
            continue
        try:
            check(f"[当前] {f}", open(f, encoding="utf-8", errors="ignore").read(), hits)
        except OSError:
            pass
    for label, pat in {**HIGH, **LOW}.items():
        out = subprocess.run(["git", "grep", "-I", "-l", "-E", pat, *commits, "--"],
                             capture_output=True, text=True).stdout.splitlines()
        for line in out[:40]:
            sha, _, path = line.partition(":")
            hits.setdefault(label, []).append((f"[历史 {sha[:7]}] {path}", "—"))
else:
    for f in subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split("\n"):
        if not f or not os.path.isfile(f):
            continue
        try:
            check(f, open(f, encoding="utf-8", errors="ignore").read(), hits)
        except OSError:
            pass

high_labels = set(HIGH)
bad = 0
for label, items in sorted(hits.items(), key=lambda kv: (kv[0] not in high_labels, kv[0])):
    sev = "高危" if label in high_labels else "提示"
    print(f"\n【{sev}】{label} —— {len(items)} 处")
    seen = set()
    for name, val in items:
        key = (name, val)
        if key in seen:
            continue
        seen.add(key)
        print(f"   {name}   {val}")
        if len(seen) >= 12:
            print("   …（更多命中已省略）")
            break
    if label in high_labels:
        bad += len(items)

print("\n" + ("❌ 发现高危命中，请勿提交" if bad else "✅ 无高危命中"))
sys.exit(1 if bad else 0)
PY
