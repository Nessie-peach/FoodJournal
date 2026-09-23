# M2 验证：doubao-seed-2.0-mini 识图关闭 thinking 提速效果

- 日期：2026-09-24
- 模型：`doubao-seed-2.0-mini`，端点 `https://ark.cn-beijing.volces.com/api/plan/v3/chat/completions`
- 图片：`test-images/IMG_7474.JPG`（两只卤鸡腿，M0 中识别质量最差的一张）
- 脚本：`m2_thinking_test.py`（共 4 次请求：A×2 默认 / B×2 关 thinking），原始数据 `m2_thinking_results.json`
- 图片压缩与 M0 一致：最长边 1024、JPEG q60（压缩后 60003 B）

## 1. thinking 参数官方写法

官方深度思考文档：**https://www.volcengine.com/docs/82379/1449737**（火山方舟《深度思考》）

Chat Completions 请求体加：

```json
"thinking": { "type": "disabled" }
```

取值：`enabled` 强制开启 / `disabled` 强制关闭（模型直接回答，不输出思维链）/ `auto` 模型自判。
模型列表文档（https://volcengine.com/docs/82379/1554678）明确：带"深度思考"标签的模型默认启用深度思考，可通过 `thinking.type=disabled` 关闭。

## 2. 延迟与 tokens 对比

| 请求 | thinking | 延迟 (ms) | completion_tokens | reasoning_tokens |
|------|----------|-----------|-------------------|------------------|
| A1 | 未传（默认开） | 6911 | 767 | 675 |
| A2 | 未传（默认开） | 6684 | 858 | 766 |
| B1 | disabled | 1973 | 107 | 0 |
| B2 | disabled | 1842 | 101 | 0 |

- 默认组平均 ~6798 ms，关闭组平均 ~1908 ms，**提速约 3.6 倍（省 ~4.9 s/次）**
- 提速来源明确：关闭后 reasoning_tokens 从 ~720 降到 0，completion_tokens 降约 85%

## 3. 关闭 thinking 的识别 JSON（原文）

B1（含一处格式瑕疵：末尾多一个 `}`，非严格合法 JSON，需容错解析）：

```json
{"mealName":"卤鸡腿双拼饭","items":[{"name":"白米饭","calories":210,"protein":4.2,"carbs":45.6,"fat":0.4},{"name":"卤鸡腿","calories":320,"protein":38,"carbs":0,"fat":18},{"name":"炒时蔬（娃娃菜、土豆丝）","calories":110,"protein":3,"carbs":20,"fat":2}]}}
```

B2：

```json
{"mealName":"红烧鸡腿套餐","items":[{"name":"红烧鸡腿","calories":350,"protein":36,"carbs":2,"fat":18},{"name":"白米饭","calories":220,"protein":4.5,"carbs":50,"fat":0.5},{"name":"炒时蔬（土豆娃娃菜）","calories":120,"protein":3,"carbs":20,"fat":3}]}
```

### 鸡腿识别对了吗（重点）

- **没对，两只卤鸡腿仍只识别出 1 份**——关闭 thinking 后 B1/B2 均只列出 1 条"鸡腿"条目，与默认组（A1/A2 也各只有 1 条卤鸡腿）一致：**M0 漏数一只的问题未改善也未恶化**，默认组在本次 2 次中同样漏数（M0 的漏数非 thinking 所致，疑似模型计数能力/图片视角问题）。
- 其他菜品无幻觉：白米饭、炒时蔬真实存在，无编造菜名；仅时蔬细项描述两次略有出入（娃娃菜/土豆丝），属正常估算粒度差异。
- 菜名存在随机性：B1"卤鸡腿双拼饭"、B2"红烧鸡腿套餐"，与默认组"卤鸡腿套餐饭"措辞不一，无实质影响。

## 4. 结论

**识图请求应默认关闭 thinking（`"thinking": {"type": "disabled"}`）**：

1. 提速 ~3.6 倍（6.8 s → 1.9 s），completion_tokens 省 ~85%，直接降低成本与用户等待时间；
2. 识别准确率本次实测与默认组持平，无劣化；
3. 注意两点：关闭后输出偶发尾括号冗余（B1），客户端需 JSON 容错解析；若后续发现复杂摆盘/多菜品计数错误率上升，可对该场景单独回退 `auto`。
