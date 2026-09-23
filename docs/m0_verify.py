#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M0 技术验证：火山引擎 Agent Plan 端点 LLM API 验证脚本（只测火山引擎一家）。

四步验证（总请求 5 次，无重试）：
1. GET  {base}/models
2. POST {base}/chat/completions  deepseek-v4-pro 纯文本
3. 对 3 张餐食照片分别调 doubao-seed-2.0-mini 识图（PIL 压缩 -> base64 data URI）

安全红线：API Key 仅从 macOS 钥匙串读取，不落盘、不打印；
所有输出（stdout / 结果 JSON）均经 sanitize 清洗，防止 Key 泄漏。
"""

import argparse
import base64
import io
import json
import subprocess
import sys
import time
from pathlib import Path

import requests
from PIL import Image

DOCS_DIR = Path(__file__).resolve().parent
IMG_DIR = DOCS_DIR / "test-images"
IMAGES = ["IMG_7429.JPG", "IMG_7474.JPG", "IMG_7470.JPG"]

DEFAULT_BASE = "https://ark.cn-beijing.volces.com/api/plan/v3"
TEXT_MODEL = "deepseek-v4-pro"
VISION_MODEL = "doubao-seed-2.0-mini"

VISION_SYSTEM = (
    '你是食物识别助手，只输出 JSON，格式 '
    '{"mealName":"...","items":[{"name":"...","calories":数字kcal,'
    '"protein":数字克,"carbs":数字克,"fat":数字克}]}，不要输出其他文字'
)
VISION_USER_TEXT = "请识别这张餐食照片中的所有菜品，并按系统要求的 JSON 格式输出营养估算。"

TEXT_SYSTEM = "你是助手"
TEXT_USER = "回复OK"


def get_api_key() -> str:
    proc = subprocess.run(
        ["security", "find-generic-password", "-a", "pigeon", "-s", "dietapp-m0-volc", "-w"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        print("FATAL: 无法从钥匙串获取 API Key", file=sys.stderr)
        sys.exit(1)
    return proc.stdout.strip()


def sanitize(obj, key: str):
    """递归清洗：任何字符串中出现 Key 即替换为 ***REDACTED***。"""
    if isinstance(obj, str):
        return obj.replace(key, "***REDACTED***")
    if isinstance(obj, dict):
        return {k: sanitize(v, key) for k, v in obj.items()}
    if isinstance(obj, list):
        return [sanitize(v, key) for v in obj]
    return obj


def compress_to_data_uri(path: Path) -> tuple[str, int]:
    """PIL 压缩：最长边 1024、JPEG quality 60，返回 (data URI, 压缩后字节大小)。"""
    img = Image.open(path)
    img = img.convert("RGB")
    img.thumbnail((1024, 1024), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=60)
    raw = buf.getvalue()
    b64 = base64.b64encode(raw).decode("ascii")
    return f"data:image/jpeg;base64,{b64}", len(raw)


def do_request(method: str, url: str, headers: dict, json_body=None) -> dict:
    t0 = time.perf_counter()
    try:
        resp = requests.request(method, url, headers=headers, json=json_body, timeout=(10, 180))
        latency = round((time.perf_counter() - t0) * 1000)
        try:
            body = resp.json()
        except Exception:
            body = {"raw_text": resp.text}
        return {
            "status_code": resp.status_code,
            "latency_ms": latency,
            "ok": resp.ok,
            "body": body,
        }
    except requests.RequestException as e:
        latency = round((time.perf_counter() - t0) * 1000)
        return {
            "status_code": None,
            "latency_ms": latency,
            "ok": False,
            "body": {"error_type": type(e).__name__, "error": str(e)},
        }


def describe_error(result: dict) -> str:
    """失败时的摘要：状态码 + 响应体前 500 字符（JSON 序列化）。"""
    body_str = json.dumps(result["body"], ensure_ascii=False)
    return f"HTTP {result['status_code']} | body[:500]: {body_str[:500]}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default=DEFAULT_BASE, help="API base URL")
    parser.add_argument("--out", default=str(DOCS_DIR / "m0_results.json"), help="结果 JSON 输出路径")
    parser.add_argument("--only", choices=["models", "text", "vision"], help="只跑其中一步（变体验证用）")
    args = parser.parse_args()

    key = get_api_key()
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    base = args.base.rstrip("/")

    results = {"base_url": base, "tests": []}

    # ---------- 1. GET /models ----------
    if args.only in (None, "models"):
        print(f"[1] GET {base}/models ...", flush=True)
        r = do_request("GET", f"{base}/models", headers)
        entry = {
            "name": "GET /models 端点可用性",
            "request": {"method": "GET", "url": f"{base}/models", "auth": "Bearer <key>"},
            "status_code": r["status_code"],
            "latency_ms": r["latency_ms"],
            "response": r["body"],
        }
        results["tests"].append(entry)
        if r["ok"]:
            print(f"    -> {r['status_code']} ({r['latency_ms']} ms) OK")
        else:
            print(f"    -> FAIL {describe_error(r)}")

    # ---------- 2. deepseek-v4-pro 纯文本 ----------
    if args.only in (None, "text"):
        body = {
            "model": TEXT_MODEL,
            "messages": [
                {"role": "system", "content": TEXT_SYSTEM},
                {"role": "user", "content": TEXT_USER},
            ],
        }
        print(f"[2] POST chat/completions model={TEXT_MODEL} ...", flush=True)
        r = do_request("POST", f"{base}/chat/completions", headers, body)
        entry = {
            "name": f"纯文本对话（{TEXT_MODEL}）",
            "request": {"method": "POST", "url": f"{base}/chat/completions", "body": body},
            "status_code": r["status_code"],
            "latency_ms": r["latency_ms"],
            "response": r["body"],
        }
        results["tests"].append(entry)
        if r["ok"]:
            content = r["body"].get("choices", [{}])[0].get("message", {}).get("content", "")
            usage = r["body"].get("usage", {})
            print(f"    -> {r['status_code']} ({r['latency_ms']} ms) reply={content!r} usage={usage}")
        else:
            print(f"    -> FAIL {describe_error(r)}")

    # ---------- 3. 三张照片识图 ----------
    if args.only in (None, "vision"):
        for img_name in IMAGES:
            img_path = IMG_DIR / img_name
            if not img_path.exists():
                print(f"[3] {img_name}: 文件不存在，跳过")
                results["tests"].append({
                    "name": f"识图（{img_name}）",
                    "request": {"image": img_name, "error": "文件不存在"},
                    "status_code": None, "latency_ms": None, "response": None,
                })
                continue
            data_uri, comp_bytes = compress_to_data_uri(img_path)
            body = {
                "model": VISION_MODEL,
                "messages": [
                    {"role": "system", "content": VISION_SYSTEM},
                    {"role": "user", "content": [
                        {"type": "image_url", "image_url": {"url": data_uri}},
                        {"type": "text", "text": VISION_USER_TEXT},
                    ]},
                ],
            }
            # 请求体里不含 Key；记录时省略 base64 图片数据
            req_log = {
                "method": "POST", "url": f"{base}/chat/completions", "model": VISION_MODEL,
                "image": img_name, "compressed_jpeg_bytes": comp_bytes,
                "system_prompt": VISION_SYSTEM, "user_text": VISION_USER_TEXT,
            }
            print(f"[3] 识图 {img_name}（压缩后 {comp_bytes} B）...", flush=True)
            r = do_request("POST", f"{base}/chat/completions", headers, body)
            entry = {
                "name": f"识图（{img_name}，{VISION_MODEL}）",
                "request": req_log,
                "status_code": r["status_code"],
                "latency_ms": r["latency_ms"],
                "response": r["body"],
            }
            results["tests"].append(entry)
            if r["ok"]:
                content = r["body"].get("choices", [{}])[0].get("message", {}).get("content", "")
                print(f"    -> {r['status_code']} ({r['latency_ms']} ms)")
                print(f"    reply: {content}")
            else:
                print(f"    -> FAIL {describe_error(r)}")

    # 输出结果 JSON（经 sanitize 清洗，不含 Key）
    sanitized = sanitize(results, key)
    out_path = Path(args.out)
    out_path.write_text(json.dumps(sanitized, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n结果已写入 {out_path}")


if __name__ == "__main__":
    main()
