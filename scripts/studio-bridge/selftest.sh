#!/usr/bin/env bash
# studio-bridge 端到端自测：玩具项目，验证 投递→幂等→回收→推进→门禁
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=/tmp/studio-bridge-selftest
FAIL=0
PASS=0

ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
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

echo "== 8. 门禁：maxPerDay=0 应熔断 =="
W2=/tmp/studio-bridge-selftest2
rm -rf "$W2"; mkdir -p "$W2/.planning"
cat > "$W2/.planning/status.json" <<'J'
{"currentStage":"requirements","completedStages":[],"lastUpdated":"2026-11-03T00:00:00+08:00",
 "taskType":"new-feature","locked":true,"engine":{"autoAdvance":true,"stageArtifacts":{}}}
J
cat > "$W2/reg.json" <<'J'
{"version":1,"projects":[{"id":"toy2","repo":"/tmp/studio-bridge-selftest2","enabled":true,"maxPerDay":0}]}
J
python3 "$HERE/dispatch.py" "$W2/reg.json" | grep -q 'daily-cap' && ok "日上限熔断生效" || bad "日上限熔断失效"

echo "== 9. partial 结果不推进阶段、只记阻塞 =="
python3 "$HERE/dispatch.py" "$W2/reg.json" > /dev/null 2>&1   # 先放开上限再造一条
python3 - "$W2/reg.json" <<'J'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["projects"][0]["maxPerDay"]=6; json.dump(d,open(p,"w"))
J
python3 "$HERE/dispatch.py" "$W2/reg.json" > /dev/null
T2=$(ls "$W2/.planning/pending/"*.task.md 2>/dev/null | head -1)
printf 'STATUS: partial\n\n做了一半，缺上游 requirements.md\n' > "${T2%.task.md}.result.md"
python3 "$HERE/collect.py" "$W2/reg.json" > /dev/null
python3 - "$W2/.planning/status.json" <<'J' && ok "partial 不推进且记 blockedReasons" || bad "partial 处理错误"
import json,sys
s=json.load(open(sys.argv[1]))
assert s["currentStage"]=="requirements", s["currentStage"]
assert s["engine"].get("blockedReasons"), "blockedReasons 为空"
J

echo "== 10. 多项目互不影响 =="
cat > /tmp/studio-bridge-multi.json <<'J'
{"version":1,"projects":[
 {"id":"toy","repo":"/tmp/studio-bridge-selftest","enabled":true,"maxPerDay":6},
 {"id":"toy2","repo":"/tmp/studio-bridge-selftest2","enabled":true,"maxPerDay":6},
 {"id":"ghost","repo":"/tmp/does-not-exist","enabled":true}
]}
J
OUT3=$(python3 "$HERE/dispatch.py" /tmp/studio-bridge-multi.json)
echo "$OUT3" | grep -q '"project": "ghost"' && echo "$OUT3" | grep -q 'repo-missing' && ok "缺失仓库被跳过不报错" || bad "缺失仓库处理异常"
python3 - "$HERE/registry.json" <<'J' > /tmp/reg-check.txt 2>&1 && ok "status_report 可跑" || bad "status_report 失败"
import subprocess,sys
r=subprocess.run([sys.executable, sys.argv[1].replace("registry.json","status_report.py"), "/tmp/studio-bridge-multi.json"],capture_output=True,text=True)
print(r.stdout)
assert r.returncode==0
assert "可自动推进" in r.stdout
J

echo "== 11. 门禁：OPEN_QUESTIONS>0 不推进、转 awaiting-decision =="
W3=/tmp/studio-bridge-selftest3
rm -rf "$W3"; mkdir -p "$W3/.planning"
cat > "$W3/.planning/status.json" <<'J'
{"currentStage":"requirements","completedStages":[],"lastUpdated":"2026-11-03T00:00:00+08:00",
 "taskType":"enhancement","locked":false,"engine":{"autoAdvance":true,"stageArtifacts":{}}}
J
cat > "$W3/reg.json" <<'J'
{"version":1,"projects":[{"id":"toy3","repo":"/tmp/studio-bridge-selftest3","enabled":true,"maxPerDay":6}]}
J
python3 "$HERE/dispatch.py" "$W3/reg.json" > /dev/null
T3=$(ls "$W3/.planning/pending/"*.task.md 2>/dev/null | head -1)
printf 'STATUS: ok\nOPEN_QUESTIONS: 3\n\n产出已写，但有 3 个问题要人拍板\n' > "${T3%.task.md}.result.md"
python3 "$HERE/collect.py" "$W3/reg.json" > /dev/null
python3 - "$W3/.planning/status.json" <<'J' && ok "OPEN_QUESTIONS>0 时停在原阶段并记 awaiting-decision" || bad "OPEN_QUESTIONS 门禁失效"
import json,sys
s=json.load(open(sys.argv[1]))
assert s["currentStage"]=="requirements", s["currentStage"]
assert s["engine"]["openQuestions"]==3, s["engine"].get("openQuestions")
assert any("awaiting-decision" in r for r in s["engine"]["blockedReasons"]), s["engine"]["blockedReasons"]
J

echo "== 12. 门禁：有阻塞时 dispatch 不重投 =="
OUT4=$(python3 "$HERE/dispatch.py" "$W3/reg.json")
echo "$OUT4" | grep -q 'blocked:' && ok "阻塞态下不再重投任务书" || bad "阻塞态仍在重投"
echo "$OUT4" | grep -q '"action": "dispatch"' && bad "仍产生了新任务书" || ok "未产生新任务书"

echo "== 13. 清空阻塞后可恢复推进 =="
python3 - "$W3/.planning/status.json" <<'J'
import json,sys
p=sys.argv[1]; s=json.load(open(p))
s["engine"]["blockedReasons"]=[]
s["engine"].pop("openQuestions",None)
json.dump(s,open(p,"w"),ensure_ascii=False,indent=2)
J
OUT5=$(python3 "$HERE/dispatch.py" "$W3/reg.json")
echo "$OUT5" | grep -q '"action": "dispatch"' && ok "人工清空阻塞后恢复投递" || bad "清空后仍不投递"

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS ($PASS checks, 0 failed)"; exit 0; else echo "FAILED: $FAIL of $((PASS+FAIL))"; exit 1; fi
