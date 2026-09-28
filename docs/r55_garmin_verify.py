#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
R5-5 (E1) Garmin 中国区账号验证脚本 —— 只读操作
- 密码仅从 macOS 钥匙串读取（security find-generic-password），不落盘、不回显
- is_cn=True 走 sso.garmin.cn
- 拉取今天+昨天的 HRV / 身体电量 / 压力 / 睡眠分期 / 每日摘要（共 10 次数据请求）
- 结果写 r55_garmin_results.json（脱敏：字符串值只保留类型）
"""
import json
import subprocess
import sys
import traceback
from datetime import date, timedelta
from pathlib import Path

import garminconnect

OUT_JSON = Path(__file__).parent / "r55_garmin_results.json"
TOKEN_DIR = "~/.garth_session_cn"
EMAIL = "tonytao81@outlook.com"

# 结果里允许保留的类型：数值 / 布尔 / null
ALLOWED = (int, float, bool)


def get_password_from_keychain() -> str:
    r = subprocess.run(
        ["security", "find-generic-password", "-s", "dietapp-r5-garmin", "-w"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise RuntimeError(f"keychain read failed (rc={r.returncode})")
    pw = r.stdout.strip()
    if not pw:
        raise RuntimeError("keychain returned empty password")
    return pw


def sanitize(obj):
    """脱敏：数值/布尔保留，字符串只报类型（枚举类短词除外）。"""
    if isinstance(obj, ALLOWED) or obj is None:
        return obj
    if isinstance(obj, str):
        # 睡眠分期等枚举值（纯小写字母/下划线，无个人信息）保留
        if obj.replace("_", "").isalpha() and obj.islower() and len(obj) <= 30:
            return obj
        return f"<str len={len(obj)}>"
    if isinstance(obj, dict):
        return {k: sanitize(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [sanitize(v) for v in obj[:3]] + ([f"...({len(obj)} items)"] if len(obj) > 3 else [])
    return f"<{type(obj).__name__}>"


def try_fetch(client, label, fn, days):
    results = {}
    for d in days:
        key = d.isoformat()
        try:
            raw = fn(d)
            results[key] = {"ok": True, "data": sanitize(raw)}
        except Exception as e:
            results[key] = {"ok": False, "error": f"{type(e).__name__}: {e}"[:200]}
    return label, results


def main():
    days = [date.today(), date.today() - timedelta(days=1)]
    report = {"is_cn": True, "email": EMAIL, "endpoints": {}, "token_dir": TOKEN_DIR}
    client = garminconnect.Garmin(email=EMAIL, password=get_password_from_keychain(), is_cn=True)

    # ---- 登录（最多 2 次尝试，不重试轰炸）----
    login_ok, mfa = False, False
    for attempt in (1, 2):
        try:
            res = client.login()
            if isinstance(res, tuple) and res[0]:  # (needs_mfa, None)
                mfa = True
                report["login_error"] = "MFA required (needs_mfa returned)"
                break
            login_ok = True
            report["login_attempts"] = attempt
            break
        except Exception as e:
            msg = f"{type(e).__name__}: {e}"
            report["login_error"] = msg[:300]
            low = msg.lower()
            if any(k in low for k in ("mfa", "totp", "captcha", "verification", "401", "403")):
                report["login_error_type"] = "MFA/verification-class error, stop retrying"
                break
    report["login_success"] = login_ok
    report["mfa_required"] = mfa
    if not login_ok:
        OUT_JSON.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(json.dumps({"login_success": False, "error": report.get("login_error", "")[:120]}, ensure_ascii=False))
        sys.exit(1)

    # ---- token 持久化 ----
    try:
        client.client.dump(str(Path(TOKEN_DIR).expanduser()))
        report["token_saved"] = True
    except Exception as e:
        report["token_saved"] = False
        report["token_save_error"] = f"{type(e).__name__}: {e}"[:200]

    # ---- 数据接口（10 次请求）----
    fetches = [
        ("hrv", lambda d: client.get_hrv_data(d.isoformat())),
        ("body_battery", lambda d: client.get_body_battery(d.isoformat())),
        ("stress", lambda d: client.get_stress_data(d.isoformat())),
        ("sleep", lambda d: client.get_sleep_data(d.isoformat())),
        ("user_summary", lambda d: client.get_user_summary(d.isoformat())),
    ]
    for label, fn in fetches:
        name, res = try_fetch(client, label, fn, days)
        report["endpoints"][name] = res

    OUT_JSON.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    summary = {"login_success": True, "token_saved": report.get("token_saved")}
    for name, res in report["endpoints"].items():
        summary[name] = {d: ("ok" if v["ok"] else "fail") for d, v in res.items()}
    print(json.dumps(summary, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # 只输出异常类型，避免泄漏
        print(json.dumps({"fatal": traceback.format_exception_only(sys.exc_info()[0])[-1].strip()}))
        sys.exit(2)
