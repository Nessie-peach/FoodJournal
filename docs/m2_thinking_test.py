#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M2 验证：doubao-seed-2.0-mini 识图关闭 thinking（深度思考）后的提速效果。

同一图片（IMG_7474.JPG，M0 中漏数一只卤鸡腿的图）、同一识图 prompt，共 4 次请求：
- 请求 A×2：不加 thinking 参数（默认行为，M0 基线）
- 请求 B×2：加 "thinking": {"type": "disabled"}（官方写法，见
  https://www.volcengine.com/docs/82379/1449737 深度思考）

安全红线：API Key 仅从 macOS 钥匙串读取，不落盘、不打印；
所有输出（stdout / 结果 JSON）均经 sanitize 清洗，防止 Key 泄漏。
"""

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
IMG_PATH = DOCS_DIR / "test-images" / "IMG_7474.JPG"

BASE = "https://ark.cn-beijing.volces.com/api/plan/v3"
MODEL = "doubao-seed-2.0-mini"
ENDPOINT = f"{BASE}/chat/completions"

VISION_SYSTEM = (
    '你是食物识别助手，只输出 JSON，格式 '
    '{"mealName":"...","items":[{"name":"...","calories":数字kcal,'
    '"protein":数字克,"carbs":数字克,"fat":数字克}]}，不要输出其他文字'
)
VISION_USER_TEXT = "请识别这张餐食照片中的所有菜品，并按系统要求的 JSON 格式输出营养估算。"


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
    if isinstance(obj, str):
        return obj.replace(key, "***REDACTED***")
    if isinstance(obj, dict):
        return {k: sanitize(v, key) for k, v in obj.items()}
    if isinstance(obj, list):
        return [sanitize(v, key) for v in obj]
    return obj


def compress_to_data_uri(path: Path) -> tuple[str, int]:
    """与 M0 相同：最长边 1024、JPEG quality 60。"""
    img = Image.open(path).convert("RGB")
    img.thumbnail((1024, 1024), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=60)
    raw = buf.getvalue()
    return "data:image/jpeg;base64," + base64.b64encode(raw).decode("ascii"), len(raw)


def run_once(key: str, data_uri: str, label: str, disable_thinking: bool) -> dict:
    body = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": VISION_SYSTEM},
            {"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": data_uri}},
                {"type": "text", "text": VISION_USER_TEXT},
            ]},
        ],
    }
    if disable_thinking:
        body["thinking"] = {"type": "disabled"}

    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    t0 = time.perf_counter()
    try:
        resp = requests.post(ENDPOINT, headers=headers, json=body, timeout=(10, 180))
        latency = round((time.perf_counter() - t0) * 1000)
        try:
            rj = resp.json()
        except Exception:
            rj = {"raw_text": resp.text}
    except requests.RequestException as e:
        latency = round((time.perf_counter() - t0) * 1000)
        return {"label": label, "ok": False, "latency_ms": latency,
                "error": f"{type(e).__name__}: {e}"}

    if not resp.ok:
        return {"label": label, "ok": False, "latency_ms": latency,
                "status_code": resp.status_code, "error": json.dumps(rj, ensure_ascii=False)[:500]}

    msg = rj.get("choices", [{}])[0].get("message", {})
    usage = rj.get("usage", {})
    details = usage.get("completion_tokens_details") or {}
    return {
        "label": label,
        "ok": True,
        "latency_ms": latency,
        "status_code": resp.status_code,
        "completion_tokens": usage.get("completion_tokens"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "reasoning_tokens": details.get("reasoning_tokens"),
        "content": msg.get("content", ""),
        "has_reasoning_content": bool(msg.get("reasoning_content")),
    }


def main():
    key = get_api_key()
    data_uri, comp_bytes = compress_to_data_uri(IMG_PATH)
    print(f"图片: {IMG_PATH.name}（压缩后 {comp_bytes} B），模型 {MODEL}", flush=True)

    plan = [("A1-default", False), ("A2-default", False),
            ("B1-no-thinking", True), ("B2-no-thinking", True)]
    results = []
    for label, disable in plan:
        print(f"[{label}] thinking={'disabled' if disable else '默认(未传)'} ...", flush=True)
        r = run_once(key, data_uri, label, disable)
        if r["ok"]:
            print(f"    -> {r['latency_ms']} ms, completion_tokens={r['completion_tokens']}, "
                  f"reasoning_tokens={r['reasoning_tokens']}", flush=True)
            print(f"    content: {r['content']}", flush=True)
        else:
            print(f"    -> FAIL {r.get('error')}", flush=True)
        results.append(r)

    out = DOCS_DIR / "m2_thinking_results.json"
    out.write_text(json.dumps(sanitize(results, key), ensure_ascii=False, indent=2),
                   encoding="utf-8")
    print(f"\n结果已写入 {out}")


if __name__ == "__main__":
    main()
