# studio-bridge

把 `autonomous_studio` 的 planning 产物接成 super agent 的本地自动推进项。

## 为什么是外挂脚本而不是改核心

super agent 是编译型 TS 项目，且本机跑着的就是它本人。bridge 只依赖文件系统与
`.planning/` 契约，做成独立 Python 脚本（纯标准库）可以对生产零影响，也不受构建链约束。

## 数据流

```
<repo>/.planning/status.json      ← Engine 维护的状态机
        │  dispatch.py 读
        ▼
<repo>/.planning/pending/<proj>__<stage>__<ts>.task.md   任务书
        │  worker（super agent automation / 人）执行
        ▼
<repo>/.planning/pending/<proj>__<stage>__<ts>.result.md 首行 STATUS: ok|partial|failed
        │  collect.py 读
        ▼
status.json 的 completedStages / currentStage / stageArtifacts / blockedReasons
```

## 用法

```bash
python3 dispatch.py registry.json    # 心跳：产出任务书
python3 collect.py  registry.json    # 回收：回写状态机
bash selftest.sh                     # 端到端自测（玩具项目，不碰真实仓库）
```

建议心跳频率：dispatch 每 10–15 分钟，collect 紧随其后（或同一个 cron 里串行跑）。

## 门禁（继承 autonomous-engine GATES）

| 条件 | 行为 |
|---|---|
| `currentStage == done` | 不再投递 |
| `engine.autoAdvance == false` | 全停（用户一句话即可关闭） |
| 阶段不在 `requirements/prd/tech-plan` | 转人工（除非项目显式 `allowAutoDevelopment`） |
| `draftPending.confirmed == false` | 等人确认，不投递 |
| `routeHealth.score < 5` 或 `correctionPending` | 路线修正中，不投递 |
| 同 project+stage 已有未消费任务书 | 不重复投（幂等） |
| 当日已投递 ≥ `maxPerDay` | 熔断转人工 |
| `engine.blockedReasons` 非空 | 全停，不再重投（partial/failed/待决问题都要人处置） |
| result 里 `OPEN_QUESTIONS: n` 且 n>0 | 停在当前阶段，标 `awaiting-decision`，不推进 |

硬红线（不因本脚本而放松）：**不自动 git push、不自动执行部署阶段**。

## 任务书里有什么

项目、仓库、阶段、任务类型、当前状态、本阶段要产出的路径与验收口径、
上游已有产物清单、硬约束、以及 result 的写法。worker 照着做即可。

## 与 super agent automation 的接法

建**一个** interval automation（例如每 15 分钟），prompt 大意：

> 读 `<repo>/.planning/pending/` 下最新的 `*.task.md`，按它的验收口径完成，
> 把结果写成同名 `.result.md`（首行 STATUS: ok|partial|failed），然后运行
> `python3 scripts/studio-bridge/collect.py`。

这样任务书数量增长不会带来 automation 数量增长。

## 文件一览

| 文件 | 作用 |
|---|---|
| `dispatch.py` | 心跳：读状态 → 过门禁 → 渲染任务书 → 幂等投递 |
| `collect.py` | 回收：读 result → 回写状态机 → 归档 |
| `run_once.sh` | 一次完整 tick：collect → dispatch → status_report（挂 cron 的入口） |
| `status_report.py` | 看板：所有项目的阶段 / 卡点 / 下一步 |
| `automation_prompt.md` | 可直接粘进 super agent automation 的 prompt 模板 |
| `selftest.sh` | 端到端自测，10 组用例 |
| `registry.json` | 受管项目列表 |

## 最小接入

```bash
cp registry.json registry.mine.json
# 编辑 registry.mine.json：把 repo 指向你自己的 autonomous_studio 项目
bash run_once.sh registry.mine.json      # 手动 tick 一次看效果
python3 status_report.py registry.mine.json

# 挂 cron（每 15 分钟）
*/15 * * * * /abs/path/scripts/studio-bridge/run_once.sh /abs/path/registry.mine.json
```

worker 侧见 `automation_prompt.md`。

## 卡住之后怎么恢复

`blockedReasons` 非空会让 dispatch 完全停手——这是故意的：**同一阶段的任务书被
无限重投**比停机更糟。人工处置后清空即可续跑：

```bash
python3 - <<'J'
import json
p = "<repo>/.planning/status.json"
s = json.load(open(p))
s["engine"]["blockedReasons"] = []
s["engine"].pop("openQuestions", None)
json.dump(s, open(p, "w"), ensure_ascii=False, indent=2)
J
```

## 为什么要有 OPEN_QUESTIONS

`STATUS: ok` 只说明「该产的东西产出完了」，不说明「没有遗留问题」。需求阶段最常见的
是产出完整但带若干等产品拍板的问题；照常推进到 prd，下游就建在未定的前提上。
result 首部声明 `OPEN_QUESTIONS: 5` 就会停在原地，等答案再走。
