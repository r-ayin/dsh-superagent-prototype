#!/usr/bin/env bash
# studio-bridge 端到端自测：玩具项目，验证 投递→幂等→回收→推进→门禁
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=/tmp/studio-bridge-selftest
FAIL=0

ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

rm -rf "$W"; mkdir -p "$W/.planning"
cat > "$W/.planning/status.json" <<'J'
{
  "currentStage": "requirements",
  "completedStages": [],
  "lastUpdated": "2026-11-03T00:00:00+08:00",
  "taskType": "new-feature",
  "notes": "selftest toy project",
  "locked": true,
  "engine": { "autoAdvance": true, "stageArtifacts": {}, "blockedReasons": [] }
}
J
cat > "$W/reg.json" <<'J'
{"version":1,"projects":[{"id":"toy","repo":"/tmp/studio-bridge-selftest","enabled":true,"maxPerDay":6}]}
J

echo "== 1. 首次 dispatch 应投递 =="
OUT=$(python3 "$HERE/dispatch.py" "$W/reg.json")
echo "$OUT" | grep -q '"action": "dispatch"' && ok "dispatch 产出任务书" || bad "dispatch 未投递"
N=$(ls "$W/.planning/pending/"*.task.md 2>/dev/null | wc -l)
[ "$N" -eq 1 ] && ok "pending 有 1 个任务书" || bad "pending 任务书数=$N"
grep -q "requirements" "$W/.planning/pending/"*.task.md && ok "任务书含阶段名" || bad "任务书缺阶段"
grep -q "STATUS: ok | partial | failed" "$W/.planning/pending/"*.task.md && ok "任务书含 result 写法" || bad "任务书缺 result 说明"

echo "== 2. 重复 dispatch 应被幂等挡住 =="
OUT2=$(python3 "$HERE/dispatch.py" "$W/reg.json")
echo "$OUT2" | grep -q 'inflight' && ok "幂等生效（inflight）" || bad "幂等失效：$OUT2"
N2=$(ls "$W/.planning/pending/"*.task.md 2>/dev/null | wc -l)
[ "$N2" -eq 1 ] && ok "任务书未增加" || bad "任务书增至 $N2"

echo "== 3. 写 result 后 collect 应推进状态机 =="
TASK=$(ls "$W/.planning/pending/"*.task.md | head -1)
RES="${TASK%.task.md}.result.md"
printf 'STATUS: ok\n\n产出 .planning/requirements.md\n' > "$RES"
touch "$W/.planning/requirements.md"
python3 "$HERE/collect.py" "$W/reg.json" > /dev/null
python3 - "$W/.planning/status.json" <<'PY' && ok "currentStage 推进到 prd 且 completedStages 含 requirements" || bad "状态机未正确推进"
import json,sys
s=json.load(open(sys.argv[1]))
assert s["currentStage"]=="prd", s["currentStage"]
assert "requirements" in s["completedStages"], s["completedStages"]
assert s["engine"]["stageArtifacts"].get("requirements")==".planning/requirements.md", s["engine"]["stageArtifacts"]
PY
[ -f "$W/.planning/pending/done/$(basename "$TASK")" ] && ok "任务书已归档" || bad "任务书未归档"

echo "== 4. 门禁：autoAdvance=false 应全停 =="
python3 - "$W/.planning/status.json" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); s["engine"]["autoAdvance"]=False; json.dump(s,open(p,"w"))
PY
python3 "$HERE/dispatch.py" "$W/reg.json" | grep -q 'auto-advance-off' && ok "autoAdvance 门禁生效" || bad "autoAdvance 门禁失效"

echo "== 5. 门禁：draftPending 未确认应等待 =="
python3 - "$W/.planning/status.json" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p))
s["engine"]["autoAdvance"]=True
s["engine"]["draftPending"]={"stage":"prd","artifact":".planning/prd.md","createdAt":"2026-11-03T00:00:00+08:00","confirmed":False}
json.dump(s,open(p,"w"))
PY
python3 "$HERE/dispatch.py" "$W/reg.json" | grep -q 'awaiting-confirm' && ok "draftPending 门禁生效" || bad "draftPending 门禁失效"

echo "== 6. 门禁：routeHealth<5 应阻断 =="
python3 - "$W/.planning/status.json" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p))
s["engine"]["draftPending"]={"stage":None,"artifact":None,"createdAt":None,"confirmed":False}
s["engine"]["routeHealth"]={"score":3,"correctionPending":False}
json.dump(s,open(p,"w"))
PY
python3 "$HERE/dispatch.py" "$W/reg.json" | grep -q 'route-correction' && ok "routeHealth 门禁生效" || bad "routeHealth 门禁失效"

echo "== 7. 门禁：development 阶段非显式授权应转人工 =="
python3 - "$W/.planning/status.json" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p))
s["currentStage"]="development"; s["completedStages"]=["requirements","prd","tech-plan"]
s["engine"].pop("routeHealth",None)
json.dump(s,open(p,"w"))
PY
python3 "$HERE/dispatch.py" "$W/reg.json" | grep -q 'human-required:development' && ok "开发阶段默认转人工" || bad "开发阶段门禁失效"

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS (7/7)"; exit 0; else echo "FAILED: $FAIL"; exit 1; fi
