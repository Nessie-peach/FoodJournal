#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 m0_results.json 与 m0_results_models_variant.json 生成 M0-实测记录-原始.md。
输入文件均已经过 sanitize（不含 API Key），生成过程不再引入任何敏感信息。"""

import json
from pathlib import Path

DOCS = Path(__file__).resolve().parent
main = json.loads((DOCS / "m0_results.json").read_text(encoding="utf-8"))
variant = json.loads((DOCS / "m0_results_models_variant.json").read_text(encoding="utf-8"))

lines = []
w = lines.append

w("# M0 技术验证实测记录（原始）")
w("")
w("- **日期**：2026-09-23")
w("- **目标**：「今天吃什么」M0 技术验证 —— 火山引擎 LLM API（识图 + 文本）")
w("- **Base URL**：`https://ark.cn-beijing.volces.com/api/plan/v3`（火山 Agent Plan 订阅端点，OpenAI 兼容）")
w("- **模型**：识图 `doubao-seed-2.0-mini`，文本 `deepseek-v4-pro`")
w("- **认证**：Bearer Token，API Key 存于 macOS 钥匙串（`security find-generic-password -a pigeon -s dietapp-m0-volc -w` 读取），未出现在脚本源码 / 文件 / stdout / stderr 中")
w("- **图片预处理**：PIL 压缩（最长边 1024、JPEG quality 60）→ base64 data URI → OpenAI `image_url` 格式")
w("- **总请求数**：6（主流程 5 次 + `/models` 变体探测 1 次），无重试轰炸")
w("- **执行环境**：python 3.13.12（venv `/Users/pigeon/.workbuddy/binaries/python/envs/m0`，requests + pillow）")
w("")
w("## 结果总览")
w("")
w("| # | 测试 | 状态码 | 延迟 | 结果 |")
w("|---|------|--------|------|------|")
for i, t in enumerate(main["tests"], 1):
    if t["status_code"] == 200:
        res = "成功"
    elif t["name"] == "GET /models 端点可用性":
        res = "失败（Plan 端点不提供 /models）"
    else:
        res = "失败"
    w(f"| {i} | {t['name']} | {t['status_code']} | {t['latency_ms']} ms | {res} |")
w(f"| 6 | GET /models 变体（标准端点，去掉 `/plan`） | {variant['tests'][0]['status_code']} | {variant['tests'][0]['latency_ms']} ms | 失败（Key 仅限 Plan 端点） |")
w("")
w("**核心结论**：Agent Plan 端点 `chat/completions` 全部可用（文本 + 3 张识图均 200）；Plan 端点不提供 `GET /models`（404 空响应），且该订阅 Key 在标准端点 `/api/v3` 上无效（401），属预期行为而非故障。")
w("")

def req_desc(t):
    r = t["request"]
    if r.get("method") == "GET":
        return f"`GET {r['url']}`（Bearer 认证）"
    parts = [f"`POST {r['url']}`"]
    if "model" in r:
        parts.append(f"模型 `{r['model']}`")
    if "image" in r:
        parts.append(f"照片 `{r['image']}`（压缩后 {r['compressed_jpeg_bytes']} B JPEG）")
    return "，".join(parts)

def block(t, num, extra_variant=None):
    w(f"## {num}. {t['name']}")
    w("")
    w(f"- **请求**：{req_desc(t)}")
    w(f"- **状态码**：{t['status_code']}")
    w(f"- **延迟**：{t['latency_ms']} ms")
    w("")
    if t.get("response") is not None:
        w("**响应 JSON**：")
        w("")
        w("```json")
        w(json.dumps(t["response"], ensure_ascii=False, indent=2))
        w("```")
    if extra_variant:
        w("")
        w(extra_variant)
    w("")

variant_note = (
    "**变体探测（去掉 `/plan`，标准端点）**：`GET https://ark.cn-beijing.volces.com/api/v3/models` → "
    f"**401**（{variant['tests'][0]['latency_ms']} ms），响应："
)
block(main["tests"][0], 1, extra_variant=variant_note + "```json\n" + json.dumps(variant["tests"][0]["response"], ensure_ascii=False, indent=2) + "\n```")

for i, t in enumerate(main["tests"][1:], 2):
    if "image" in t["request"]:
        r = t["request"]
        w(f"## {i}. 识图：{r['image']}（{r['model']}）")
        w("")
        w(f"- **请求**：`POST {r['url']}`，模型 `{r['model']}`，图片 `{r['image']}`（压缩后 {r['compressed_jpeg_bytes']} B JPEG，base64 data URI 放入 `image_url`）")
        w(f"- **System Prompt**：{r['system_prompt']}")
        w(f"- **User 文本**：{r['user_text']}")
        w(f"- **状态码**：{t['status_code']}")
        w(f"- **延迟**：{t['latency_ms']} ms")
        w("")
        w("**响应 JSON**：")
        w("")
        w("```json")
        w(json.dumps(t["response"], ensure_ascii=False, indent=2))
        w("```")
        w("")
    else:
        block(t, i)

w("## 观察与备注")
w("")
w("1. **识图延迟范围**：7314–9209 ms（含大量 reasoning tokens，`doubao-seed-2-0-mini-260428` 为推理模型，实测 reasoning_tokens 551–790）。")
w("2. **文本延迟**：1262 ms（`deepseek-v4-pro-ga-260813`，含 25 reasoning tokens）。")
w('3. 三次识图的 `prompt_tokens` 均为 1410，图片 token 计费一致；输出 `content` 均为可解析 JSON，符合 system prompt 约定的 `{"mealName": ..., "items": [...]}` 结构。')
w("4. `GET /models` 在 Plan 端点 404（空响应体），在标准端点 401（AuthenticationError）——订阅 Key 仅绑定 Plan 端点，模型列表不可查询，只能按文档直接使用模型 ID。")
w("5. API Key 全程仅从钥匙串读取并置于 Authorization 头，未写入任何文件或日志。")
w("")

out = DOCS / "M0-实测记录-原始.md"
out.write_text("\n".join(lines), encoding="utf-8")
print(f"written: {out}")
