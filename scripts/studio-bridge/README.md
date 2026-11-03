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
