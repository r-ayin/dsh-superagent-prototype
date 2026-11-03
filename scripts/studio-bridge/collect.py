#!/usr/bin/env python3
"""studio-bridge collect — 消费 pending/*.result.md，回写 autonomous_studio 的 status.json。

规则：
- result 首行 `STATUS: ok | partial | failed`
- ok  → completedStages 追加本阶段，currentStage 推进到下一阶段
- 其他 → 写 blockedReasons，currentStage 不动（等人工/重试）
- 已消费的 task+result 归档到 .planning/pending/done/
- completedStages 只增不减
"""
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone

STAGES = ["requirements", "prd", "tech-plan", "development",
          "verification", "review", "deployment", "done"]

ARTIFACT_KEY = {
    "requirements": "requirements",
    "prd": "prd",
    "tech-plan": "techPlan",
    "verification": "testCases",
}

STATUS_RE = re.compile(r"^\s*STATUS:\s*(ok|partial|failed)", re.IGNORECASE)


def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def next_stage(stage):
    try:
        i = STAGES.index(stage)
    except ValueError:
        return stage
    return STAGES[min(i + 1, len(STAGES) - 1)]


def parse_name(fn):
    """<project>__<stage>__<ts>.result.md -> (project, stage)"""
    core = fn[: -len(".result.md")]
    parts = core.split("__")
    if len(parts) < 3:
        return None, None
    return parts[0], parts[1]


def first_status(path):
    try:
        with open(path, encoding="utf-8") as f:
            for i, line in enumerate(f):
                if i > 10:
                    break
                m = STATUS_RE.match(line)
                if m:
                    return m.group(1).lower()
    except OSError:
        pass
    return None


def collect_one(repo, project, fn):
    pend = os.path.join(repo, ".planning", "pending")
    res_path = os.path.join(pend, fn)
    task_name = fn[: -len(".result.md")] + ".task.md"
    stage = parse_name(fn)[1]
    verdict = first_status(res_path)

    status_path = os.path.join(repo, ".planning", "status.json")
    if not os.path.isfile(status_path):
        return {"project": project, "file": fn, "action": "skip", "reason": "no-status"}
    with open(status_path, encoding="utf-8") as f:
        status = json.load(f)

    eng = status.setdefault("engine", {})
    cur = status.get("currentStage", "")

    if verdict == "ok":
        done = status.setdefault("completedStages", [])
        if stage not in done:
            done.append(stage)
        status["currentStage"] = next_stage(stage)
        arts = eng.setdefault("stageArtifacts", {})
        key = ARTIFACT_KEY.get(stage)
        if key and not arts.get(key):
            default = {
                "requirements": ".planning/requirements.md",
                "prd": ".planning/prd.md",
                "techPlan": ".planning/tech-plan.md",
                "testCases": ".planning/test-cases.md",
            }[key]
            if os.path.exists(os.path.join(repo, default)):
                arts[key] = default
        conf = eng.setdefault("stageConfidence", {})
        conf.setdefault(stage, 80)
        # 进入下一阶段即清空 draftPending
        if isinstance(eng.get("draftPending"), dict):
            eng["draftPending"] = {"stage": None, "artifact": None,
                                   "createdAt": None, "confirmed": False}
        eng["blockedReasons"] = []
        result = "collected %s -> advanced to %s" % (stage, status["currentStage"])
    elif verdict in ("partial", "failed"):
        reasons = eng.setdefault("blockedReasons", [])
        msg = "%s 阶段产出 %s" % (stage, verdict)
        if msg not in reasons:
            reasons.append(msg)
        result = msg
    else:
        result = "unparsed-status, left in queue"
        return {"project": project, "file": fn, "action": "skip", "reason": result}

    eng["lastEngineResult"] = result
    status["lastUpdated"] = now_iso()
    with open(status_path, "w", encoding="utf-8") as f:
        json.dump(status, f, ensure_ascii=False, indent=2)

    # 归档
    done_dir = os.path.join(pend, "done")
    os.makedirs(done_dir, exist_ok=True)
    for p in (task_name, fn):
        src = os.path.join(pend, p)
        if os.path.exists(src):
            shutil.move(src, os.path.join(done_dir, p))

    return {"project": project, "file": fn, "verdict": verdict,
            "action": "collect", "from": cur, "to": status["currentStage"]}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    reg_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "registry.json")
    if not os.path.isfile(reg_path):
        print(json.dumps({"error": "registry not found: %s" % reg_path}))
        return 2
    with open(reg_path, encoding="utf-8") as f:
        projects = json.load(f).get("projects", [])

    out = []
    for item in projects:
        repo = item.get("repo", "")
        pid = item.get("id") or os.path.basename(repo)
        pend = os.path.join(repo, ".planning", "pending")
        if not os.path.isdir(pend):
            continue
        for fn in sorted(os.listdir(pend)):
            if fn.endswith(".result.md"):
                out.append(collect_one(repo, pid, fn))

    print(json.dumps({"at": now_iso(), "results": out}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
