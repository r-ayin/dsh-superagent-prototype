#!/usr/bin/env python3
"""studio-bridge status — 一次看清所有受管项目：当前阶段、卡在哪、下次动作。"""
import json
import os
import sys
from datetime import datetime, timezone

STAGES = ["requirements", "prd", "tech-plan", "development",
          "verification", "review", "deployment", "done"]
AUTO = {"requirements", "prd", "tech-plan"}


def load_registry(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f).get("projects", [])


def pending_count(repo):
    d = os.path.join(repo, ".planning", "pending")
    if not os.path.isdir(d):
        return 0
    return sum(1 for f in os.listdir(d) if f.endswith(".task.md"))


def verdict_of(repo, item_id):
    """最近一条 result 的 verdict（若有）"""
    d = os.path.join(repo, ".planning", "pending")
    if not os.path.isdir(d):
        return "-"
    best, stamp = "-", ""
    for fn in os.listdir(d):
        if fn.endswith(".result.md") and fn.startswith(item_id + "__"):
            try:
                ts = int(fn.rsplit("__", 1)[1].split(".")[0])
            except (IndexError, ValueError):
                continue
            if ts >= 0 and fn > stamp:
                stamp = fn
                try:
                    with open(os.path.join(d, fn), encoding="utf-8") as f:
                        for line in f:
                            if line.strip().upper().startswith("STATUS:"):
                                best = line.split(":", 1)[1].strip()
                                break
                except OSError:
                    pass
    return best


def judge(item, status):
    """返回 (能否自动推进, 原因)"""
    if not item.get("enabled", True):
        return False, "disabled"
    if status is None:
        return False, "无 status.json"
    eng = status.get("engine") or {}
    cur = status.get("currentStage", "?")
    if cur == "done":
        return False, "已完成"
    if eng.get("autoAdvance") is False:
        return False, "autoAdvance=off"
    if cur not in AUTO and not item.get("allowAutoDevelopment"):
        return False, "阶段需人工（%s）" % cur
    dp = eng.get("draftPending") or {}
    if dp.get("stage") and dp.get("confirmed") is False:
        return False, "等确认 %s" % dp.get("stage")
    reasons = eng.get("blockedReasons") or []
    if reasons:
        return False, "blocked: " + str(reasons[0])[:40]
    rh = eng.get("routeHealth") or {}
    if isinstance(rh.get("score"), (int, float)) and rh["score"] < 5:
        return False, "路线修正中 %s 分" % rh["score"]
    return True, "可推进"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    reg = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "registry.json")
    if not os.path.isfile(reg):
        print("registry not found: %s" % reg)
        return 2
    rows = []
    for item in load_registry(reg):
        repo = item.get("repo", "")
        pid = item.get("id") or os.path.basename(repo)
        sp = os.path.join(repo, ".planning", "status.json")
        status = None
        if os.path.isfile(sp):
            try:
                with open(sp, encoding="utf-8") as f:
                    status = json.load(f)
            except (json.JSONDecodeError, OSError):
                status = None
        can, why = judge(item, status)
        cur = (status or {}).get("currentStage", "-")
        done = ",".join((status or {}).get("completedStages") or []) or "-"
        act = ((status or {}).get("engine") or {}).get("lastEngineAction") or "-"
        rows.append((pid, cur, done, pending_count(repo), verdict_of(repo, pid),
                     "YES" if can else "no", why, act[:19]))

    hdr = ("项目", "阶段", "已完成", "待办", "末次result", "可自动", "原因", "末次心跳")
    widths = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(len(hdr))]
    def fmt(r):
        return "  ".join(str(c).ljust(widths[i]) for i, c in enumerate(r))
    print(fmt(hdr))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print(fmt(r))
    ready = sum(1 for r in rows if r[5] == "YES")
    print("\n%d/%d 个项目可自动推进" % (ready, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
