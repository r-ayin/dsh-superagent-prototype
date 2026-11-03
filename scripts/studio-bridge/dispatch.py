#!/usr/bin/env python3
"""studio-bridge dispatch — 把 autonomous_studio 的 planning 状态转成 super-agent 任务书。

只读 status.json，只往 <repo>/.planning/pending/ 写任务书，不改任何项目源码。
幂等：同一 project+stage 已有未消费 pending 时不重复投递。
退出码：0=有投递或无项目可投；2=registry 不可读。
"""
import json
import os
import sys
import time
from datetime import datetime, timezone

STAGES = ["requirements", "prd", "tech-plan", "development",
          "verification", "review", "deployment", "done"]

# 仅这些阶段允许自动推进；development 及之后默认转人工（方案建议 #1）
AUTO_STAGES = {"requirements", "prd", "tech-plan"}

STAGE_OUTPUT = {
    "requirements": ".planning/requirements.md",
    "prd": ".planning/prd.md 与 .planning/test-cases.md",
    "tech-plan": ".planning/tech-plan.md",
}

STAGE_ACCEPT = {
    "requirements": "需求边界清晰、可被拆成可验证条目，且不含实现方案",
    "prd": "PRD 的异常与边界章节每一条都转成 test-cases.md 里对应用例",
    "tech-plan": "含代码库分析、分步任务与每步的验证命令；标注为 DRAFT 待确认",
}

BRIEF_HEADER = """# {project} · {stage} 任务书

- 任务 ID：`{task_id}`
- 项目：{project}
- 仓库：`{repo}`
- 阶段：{stage}
- 任务类型：{task_type}
- 生成时间：{now}

## 当前状态

- currentStage：{current_stage}
- completedStages：{completed}
- 说明：{notes}

## 本阶段要产出

{output}

## 上游已有产物

{artifacts}

## 验收口径

{accept}

## 硬约束（继承 autonomous-engine GATES）

- 不执行 git push、不执行部署阶段动作
- 产出只写入上表路径，不改无关文件
- 完成后把结果写入同目录的 `{task_id}.result.md`，首行写 `STATUS: ok | partial | failed`
- 结论附证据（文件路径:行号 或 命令输出），不要只给散文

## 产出后

dispatch 下次心跳会读取 result 并回写 status.json 的 completedStages / stageArtifacts。
"""


def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def load_registry(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return data.get("projects", [])


def read_status(repo):
    p = os.path.join(repo, ".planning", "status.json")
    if not os.path.isfile(p):
        return None
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def pending_dir(repo):
    d = os.path.join(repo, ".planning", "pending")
    os.makedirs(d, exist_ok=True)
    return d


def inflight(repo, project, stage):
    """已有同 project+stage 的未消费任务书？"""
    d = pending_dir(repo)
    prefix = "%s__%s__" % (project, stage)
    for fn in os.listdir(d):
        if fn.startswith(prefix) and fn.endswith(".task.md"):
            if not os.path.exists(os.path.join(d, fn[: -len(".task.md")] + ".result.md")):
                return fn
    return None


def today_count(repo, project):
    d = pending_dir(repo)
    today = datetime.now().strftime("%Y%m%d")
    n = 0
    for fn in os.listdir(d):
        if fn.startswith(project + "__") and fn.endswith(".task.md"):
            try:
                ts = int(fn.rsplit("__", 1)[1].split(".")[0])
                if datetime.fromtimestamp(ts).strftime("%Y%m%d") == today:
                    n += 1
            except (IndexError, ValueError):
                continue
    return n


def gate(project, status, repo, max_per_day, allow_auto_dev):
    """返回 (blocked_reason|None)。None 表示可以投递。"""
    eng = status.get("engine") or {}
    stage = status.get("currentStage", "")

    if status.get("currentStage") == "done":
        return "already-done"
    if eng.get("autoAdvance") is False:
        return "auto-advance-off"
    if stage not in AUTO_STAGES and not allow_auto_dev:
        return "human-required:%s" % stage

    dp = eng.get("draftPending") or {}
    if dp.get("stage") and dp.get("confirmed") is False:
        return "awaiting-confirm:%s" % dp.get("stage")

    rh = eng.get("routeHealth") or {}
    if isinstance(rh.get("score"), (int, float)) and rh["score"] < 5:
        return "route-correction:score=%s" % rh["score"]
    reasons = eng.get("blockedReasons") or []
    if reasons:
        # 上一轮结果留下的阻塞（partial/failed 或 awaiting-decision）必须先由人处置，
        # 否则同一阶段的任务书会被无限重投。
        return "blocked:" + str(reasons[0])

    if rh.get("correctionPending") is True:
        return "correction-pending"

    ap = inflight(repo, project, stage)
    if ap:
        return "inflight:%s" % ap
    if today_count(repo, project) >= max_per_day:
        return "daily-cap:%d" % max_per_day
    return None


def render(project, repo, status):
    stage = status["currentStage"]
    eng = status.get("engine") or {}
    arts = eng.get("stageArtifacts") or {}
    existing = []
    for k, v in arts.items():
        if v and os.path.exists(os.path.join(repo, v)):
            existing.append("- %s：`%s`" % (k, v))
    if not existing:
        existing = ["（无）"]
    task_id = "%s__%s__%d" % (project, stage, int(time.time()))
    return task_id, BRIEF_HEADER.format(
        project=project,
        stage=stage,
        task_id=task_id,
        repo=repo,
        task_type=status.get("taskType", "unknown"),
        now=now_iso(),
        current_stage=stage,
        completed=", ".join(status.get("completedStages") or []) or "（无）",
        notes=status.get("notes") or "（无）",
        output=STAGE_OUTPUT.get(stage, "（未知阶段）"),
        artifacts="\n".join(existing),
        accept=STAGE_ACCEPT.get(stage, "（未知阶段）"),
    )


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    reg_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "registry.json")
    if not os.path.isfile(reg_path):
        print(json.dumps({"error": "registry not found: %s" % reg_path}))
        return 2

    registry = load_registry(reg_path)
    results = []
    for item in registry:
        if not item.get("enabled", True):
            results.append({"project": item.get("id"), "action": "skip", "reason": "disabled"})
            continue
        pid = item.get("id") or os.path.basename(item.get("repo", ""))
        repo = item.get("repo", "")
        if not repo or not os.path.isdir(repo):
            results.append({"project": pid, "action": "skip", "reason": "repo-missing"})
            continue

        status = read_status(repo)
        if status is None:
            results.append({"project": pid, "action": "skip", "reason": "no-status"})
            continue

        reason = gate(pid, status, repo,
                      int(item.get("maxPerDay", 6)),
                      bool(item.get("allowAutoDevelopment", False)))
        if reason:
            results.append({"project": pid, "action": "skip", "reason": reason})
            continue

        task_id, brief = render(pid, repo, status)
        out = os.path.join(pending_dir(repo), task_id + ".task.md")
        with open(out, "w", encoding="utf-8") as f:
            f.write(brief)

        # 回写 lastEngineAction（只动 engine 的两个时间字段）
        eng = status.setdefault("engine", {})
        eng["lastEngineAction"] = now_iso()
        eng["lastEngineResult"] = "dispatched %s" % task_id
        sp = os.path.join(repo, ".planning", "status.json")
        with open(sp, "w", encoding="utf-8") as f:
            json.dump(status, f, ensure_ascii=False, indent=2)

        results.append({"project": pid, "action": "dispatch",
                        "stage": status["currentStage"], "task": out})

    print(json.dumps({"at": now_iso(), "results": results},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
