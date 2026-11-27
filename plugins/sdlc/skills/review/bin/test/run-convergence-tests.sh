#!/usr/bin/env bash
# Dependency-free test harness for the Gate 1 convergence controller.
# Drives convergence.js through its CLI against throwaway ledgers and asserts the
# termination-policy contract: ledger shape, severity-gated clean counter (MEDIUM+ gates,
# LOW/INFO advisory), lock, round cap, no auto-waive, reopen-guard, category floor, and
# fail-closed errors.
# No npm packages — bash + node only. Ends "<n> checks, <m> failed"; exit 1 on any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$HERE/../convergence.js"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH — cannot run convergence tests" >&2
  exit 1
fi
if [ ! -f "$CTL" ]; then
  echo "FAIL: controller not found at $CTL" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

total=0
fails=0
OUT=""
CODE=0

# rec <ledger> <round> <findings_json> [gate] — record one round; sets OUT (stdout) and CODE.
rec() {
  OUT="$(printf '%s' "$3" | node "$CTL" record --ledger "$1" --target feat/42-t --round "$2" --sha "sha$2" --gate "${4:-Gate 1}" 2>/dev/null)"
  CODE=$?
}

# jget <json> <js-expr over `j`> — evaluate an expression against parsed JSON; prints result.
jget() {
  # A missing path prints "undefined" (never a stack trace) so the assertion reports a clean FAIL.
  node -e 'const j=JSON.parse(process.argv[1]); let v; try { v=eval(process.argv[2]) } catch { v=undefined }
    process.stdout.write(typeof v==="string"?v:String(JSON.stringify(v)))' "$1" "$2" 2>/dev/null
}

# check <name> <actual> <expected>
check() {
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 — expected [$3], got [$2]"
    fails=$((fails + 1))
  fi
}

# check_match <name> <actual> <extended-regex>
check_match() {
  total=$((total + 1))
  if printf '%s' "$2" | grep -Eq -- "$3"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 — [$2] does not match /$3/"
    fails=$((fails + 1))
  fi
}

f() { # f <location> <severity> <title> [category] — one finding object
  if [ -n "${4:-}" ]; then
    printf '{"location":"%s","severity":"%s","title":"%s","category":"%s"}' "$1" "$2" "$3" "$4"
  else
    printf '{"location":"%s","severity":"%s","title":"%s"}' "$1" "$2" "$3"
  fi
}

echo "=== Gate 1 convergence controller tests ==="

# --- AC1: ledger is written each round, schema + fingerprint per finding ---
L="$WORK/ac1.json"
rec "$L" 1 "[$(f src/a.js:12 HIGH 'Transaction left open on early return' data-integrity),$(f src/b.js:3 LOW 'Unused import')]"
check "AC1 record exits 0" "$CODE" "0"
LED="$(cat "$L" 2>/dev/null || echo '{}')"
check "AC1 schema_version 1"      "$(jget "$LED" 'j.schema_version')" "1"
check "AC1 target recorded"       "$(jget "$LED" 'j.target')" "feat/42-t"
check "AC1 one rounds[] entry"    "$(jget "$LED" 'j.rounds.length')" "1"
check "AC1 round number + sha"    "$(jget "$LED" 'j.rounds[0].round+":"+j.rounds[0].sha')" "1:sha1"
check "AC1 finding per input"     "$(jget "$LED" 'j.rounds[0].findings.length')" "2"
check "AC1 every fingerprint sha256" \
  "$(jget "$LED" 'j.rounds[0].findings.every(x=>/^sha256:[0-9a-f]{64}$/.test(x.fingerprint))')" "true"
check "AC1 finding carries schema keys" \
  "$(jget "$LED" '["fingerprint","file","category","severity","summary_normalized","status","first_seen_round","self_inflicted"].every(k=>k in j.rounds[0].findings[0])')" "true"
check "AC1 file strips :line"     "$(jget "$LED" 'j.rounds[0].findings[0].file')" "src/a.js"
check "AC1 status OPEN"           "$(jget "$LED" 'j.rounds[0].findings[0].status')" "OPEN"
check "AC1 summary normalized"    "$(jget "$LED" 'j.rounds[0].findings[0].summary_normalized')" "transaction left open on early return"
check "AC1 counters present"      "$(jget "$LED" 'Object.keys(j.counters).sort().join(",")')" "consecutive_clean_rounds,reopen_events"

# Fingerprint identity survives line drift, case, whitespace, and punctuation.
LA="$WORK/fp-a.json"; LB="$WORK/fp-b.json"
rec "$LA" 1 "[$(f src/a.js:12 MEDIUM 'Null deref, on retry!')]"
rec "$LB" 1 "[$(f src/a.js:98 MEDIUM '  null   DEREF on retry ')]"
check "AC1 fingerprint ignores line/case/space/punct" \
  "$(jget "$(cat "$LA")" 'j.rounds[0].findings[0].fingerprint')" \
  "$(jget "$(cat "$LB")" 'j.rounds[0].findings[0].fingerprint')"

# Re-recording the same round replaces it (idempotent retry), never duplicates.
rec "$L" 1 "[$(f src/b.js:3 LOW 'Unused import')]"
check "AC1 re-record same round is idempotent" "$(jget "$(cat "$L")" 'j.rounds.length')" "1"

# Out-of-scope findings never enter the ledger.
L="$WORK/scope.json"
rec "$L" 1 '[{"location":"x.js:1","severity":"HIGH","title":"pre-existing debt","in_scope":false}]'
check "AC1 out-of-scope finding excluded" "$(jget "$(cat "$L")" 'j.rounds[0].findings.length')" "0"

# --- AC2: clean means zero open MEDIUM+ findings; LOW/INFO are advisory ---
L="$WORK/ac2.json"
rec "$L" 1 "[$(f a.js:1 LOW 'Naming nit'),$(f a.js:2 INFO 'Consider a comment')]"
check "AC2 LOW/INFO-only round counts clean" "$(jget "$OUT" 'j.counters.consecutive_clean_rounds')" "1"
check "AC2 CONTINUE gate string"          "$(jget "$OUT" 'j.gate_status')" "OPEN — need 1 more consecutive clean round(s)"
check "AC2 advisory findings still recorded OPEN" "$(jget "$(cat "$L")" 'j.rounds[0].findings.filter(x=>x.status==="OPEN").length')" "2"
rec "$L" 2 "[$(f a.js:9 MEDIUM 'Missing error handling'),$(f a.js:1 LOW 'Naming nit')]"
check "AC2 one MEDIUM resets counter"     "$(jget "$OUT" 'j.counters.consecutive_clean_rounds')" "0"
check "AC2 MEDIUM round → CONTINUE"       "$(jget "$OUT" 'j.decision')" "CONTINUE"
check "AC2 reset gate string"             "$(jget "$OUT" 'j.gate_status')" "OPEN — need 2 more consecutive clean round(s)"
for s in HIGH CRITICAL; do
  rec "$WORK/ac2-$s.json" 1 "[$(f a.js:3 "$s" 'Real defect')]"
  check "AC2 one $s → not clean"          "$(jget "$OUT" 'j.counters.consecutive_clean_rounds')" "0"
done

# --- AC3: two consecutive clean rounds lock (identical lock string); open LOW/INFO never block ---
L="$WORK/ac3.json"
rec "$L" 1 "[]"
rec "$L" 2 "[$(f a.js:1 LOW 'Naming nit')]"
check "AC3 open LOW does not block the lock" "$(jget "$OUT" 'j.decision')" "LOCKED"
check "AC3 lock string unchanged"         "$(jget "$OUT" 'j.gate_status')" "LOCKED — ready for Gate 2 (PR peer review)"
L="$WORK/ac3-med.json"
rec "$L" 1 "[]"
rec "$L" 2 "[$(f a.js:1 MEDIUM 'Missing guard')]"
check "AC3 open MEDIUM blocks the lock"   "$(jget "$OUT" 'j.decision')" "CONTINUE"
rec "$L" 3 "[]"; rec "$L" 4 "[]"
check "AC3 two clean rounds → LOCKED"     "$(jget "$OUT" 'j.decision')" "LOCKED"

# --- AC4 + AC5: round cap terminates a spiral; nothing is ever auto-waived ---
L="$WORK/ac4.json"
never_continue_at_cap=true
for r in 1 2 3 4 5 6 7 8 9; do
  rec "$L" "$r" "[$(f "c$r.js:1" MEDIUM "churn defect $r")]"
  d="$(jget "$OUT" 'j.decision')"
  if [ "$r" -lt 8 ]; then
    check "AC4 churn round $r below cap → CONTINUE" "$d" "CONTINUE"
  elif [ "$d" = "CONTINUE" ]; then
    never_continue_at_cap=false
  fi
done
check "AC4 never CONTINUE at/after cap"   "$never_continue_at_cap" "true"
rec "$L" 8 "[$(f c8.js:1 MEDIUM 'churn defect 8'),$(f c8.js:2 LOW 'nit')]"
check "AC4 cap + open MEDIUM → HUMAN_GATE" "$(jget "$OUT" 'j.decision')" "HUMAN_GATE"
check_match "AC4 HUMAN_GATE reason counts gating findings only" "$(jget "$OUT" 'j.gate_status')" '^HUMAN_GATE — round cap 8 reached with 1 open MEDIUM\+ finding\(s\)'

L="$WORK/ac5-low.json"
for r in 1 2 3 4 5 6 7; do rec "$L" "$r" "[$(f "m$r.js:1" MEDIUM "defect $r")]"; done
rec "$L" 8 "[$(f z.js:1 LOW 'nit one'),$(f z.js:2 INFO 'fyi')]"
check "AC5 cap + only LOW/INFO → CONTINUE (clean)" "$(jget "$OUT" 'j.decision')" "CONTINUE"
check "AC5 advisory findings stay OPEN, never waived" "$(jget "$(cat "$L")" 'j.rounds[7].findings.filter(x=>x.status==="OPEN").length')" "2"
check "AC5 no waived field in output"     "$(jget "$OUT" '"waived" in j')" "false"
check "AC5 statuses only OPEN/RESOLVED"   "$(jget "$(cat "$L")" 'j.rounds.every(r=>r.findings.every(x=>["OPEN","RESOLVED"].includes(x.status)))')" "true"
rec "$L" 9 "[$(f z.js:1 LOW 'nit one')]"
check "AC5 second advisory-only round past cap → LOCKED" "$(jget "$OUT" 'j.decision')" "LOCKED"
L="$WORK/ac5-floor.json"
for r in 1 2 3 4 5 6 7; do rec "$L" "$r" "[$(f "m$r.js:1" MEDIUM "defect $r")]"; done
rec "$L" 8 "[$(f db.sql:1 LOW 'Row count not checked' data-integrity)]"
check "AC5 cap + floored LOW → HUMAN_GATE" "$(jget "$OUT" 'j.decision')" "HUMAN_GATE"
check "status after cap HUMAN_GATE → not locked" "$(jget "$(node "$CTL" status --ledger "$L" 2>/dev/null)" 'j.locked')" "false"
L="$WORK/ac4-cleancap.json"
for r in 1 2 3 4 5 6 7; do rec "$L" "$r" "[$(f "k$r.js:1" MEDIUM "d $r")]"; done
rec "$L" 8 "[]"
check "AC4 clean round at cap earns its confirmation round" "$(jget "$OUT" 'j.decision')" "CONTINUE"
rec "$L" 9 "[]"
check "AC4 confirmation past cap locks"   "$(jget "$OUT" 'j.decision')" "LOCKED"

# Cap counts Gate 1 rounds in the ledger's current cycle — never the caller's lifetime round label.
L="$WORK/ac4-cycle.json"
rec "$L" 9 "[]"
check "AC4 first ledger round labelled 9 → CONTINUE" "$(jget "$OUT" 'j.decision')" "CONTINUE"
L="$WORK/ac4-reset.json"
for r in 1 2 3 4 5; do rec "$L" "$r" "[$(f "n$r.js:1" MEDIUM "d $r")]"; done
rec "$L" 6 "[]"; rec "$L" 7 "[]"
check "AC4 lock before cap"                "$(jget "$OUT" 'j.decision')" "LOCKED"
rec "$L" 8 "[$(f p.js:1 MEDIUM 'post-lock regression')]"
check "AC4 cycle resets after a lock → CONTINUE at label 8" "$(jget "$OUT" 'j.decision')" "CONTINUE"
L="$WORK/ac4-gate2.json"
rec "$L" 1 "[]"; rec "$L" 2 "[]"
for r in 3 4 5 6 7 8 9; do rec "$L" "$r" "[$(f "g$r.js:1" MEDIUM "peer finding $r")]" "Gate 2"; done
rec "$L" 10 "[]"
check "AC4 Gate 2 rounds never consume the Gate 1 cap" "$(jget "$OUT" 'j.decision')" "CONTINUE"
check "Gate 2 round still breaks the clean streak"     "$(jget "$OUT" 'j.counters.consecutive_clean_rounds')" "1"
check "ledger records each round's gate"               "$(jget "$(cat "$L")" 'j.rounds[2].gate+"|"+j.rounds[9].gate')" "Gate 2|Gate 1"
L="$WORK/ac4-g2cur.json"
for r in 1 2 3 4 5 6 7; do rec "$L" "$r" "[$(f "h$r.js:1" MEDIUM "d $r")]"; done
rec "$L" 8 "[$(f peer.js:1 LOW 'peer nit')]" "Gate 2"
check "current Gate 2 round never escalates or locks"  "$(jget "$OUT" 'j.decision')" "CONTINUE"
check "Gate 2 round never marks the ledger locked"     "$(jget "$(node "$CTL" status --ledger "$L" 2>/dev/null)" 'j.locked')" "false"
L="$WORK/g2-streak.json"
rec "$L" 1 "[]"; rec "$L" 2 "[]" "Gate 2"
check "clean Gate 2 round never completes a lock"      "$(jget "$OUT" 'j.decision')" "CONTINUE"
check "Gate 2 round gate_status says streak unchanged"  "$(jget "$OUT" 'j.gate_status')" "OPEN — Gate 2 round recorded (Gate 1 streak unchanged)"
rec "$L" 3 "[]"
check "clean Gate 2 round neither breaks nor extends"  "$(jget "$OUT" 'j.decision+":"+j.counters.consecutive_clean_rounds')" "LOCKED:2"
rec "$L" 4 "[]" "Gate 2"
S="$(node "$CTL" status --ledger "$L" 2>/dev/null)"
check "clean Gate 2 after a lock keeps status locked"  "$(jget "$S" 'j.locked+":"+j.last_clean.round')" "true:3"
rec "$L" 5 "[$(f peer.js:1 MEDIUM 'peer blocker')]" "Gate 2"
check "dirty Gate 2 after a lock unlocks status"       "$(jget "$(node "$CTL" status --ledger "$L" 2>/dev/null)" 'j.locked')" "false"
check "dirty Gate 2 gate_status says streak reset"     "$(jget "$OUT" 'j.gate_status')" "OPEN — Gate 2 round recorded (Gate 1 streak reset)"
L="$WORK/g2-advisory.json"
rec "$L" 1 "[]"; rec "$L" 2 "[$(f peer.js:1 LOW 'peer nit')]" "Gate 2"
check "advisory-only Gate 2 round keeps the streak"     "$(jget "$OUT" 'j.gate_status')" "OPEN — Gate 2 round recorded (Gate 1 streak unchanged)"

# --- AC6: reopen-guard escalates past REOPEN_CAP (2), citing the fingerprint ---
L="$WORK/ac6.json"
X="$(f r.js:5 MEDIUM 'Flapping race condition')"
Y="$(f other.js:1 MEDIUM 'Keeps the walk from locking')"
rec "$L" 1 "[$X]"
rec "$L" 2 "[$Y]"
check "AC6 absent finding carried as RESOLVED" \
  "$(jget "$(cat "$L")" 'j.rounds[1].findings.filter(x=>x.status==="RESOLVED").map(x=>x.file).join()')" "r.js"
rec "$L" 3 "[$X]"                       # reopen 1
rec "$L" 4 "[$Y]"
rec "$L" 5 "[$X]"                       # reopen 2 — at cap, must NOT trip
check "AC6 exactly REOPEN_CAP reopens → CONTINUE" "$(jget "$OUT" 'j.decision')" "CONTINUE"
check "AC6 reopen_events counted (X r3,r5 + Y r4)" "$(jget "$OUT" 'j.counters.reopen_events')" "3"
rec "$L" 6 "[$Y]"
rec "$L" 7 "[$X]"                       # reopen 3 — past cap
check "AC6 past REOPEN_CAP → HUMAN_GATE" "$(jget "$OUT" 'j.decision')" "HUMAN_GATE"
FP="$(jget "$(cat "$L")" 'j.rounds[6].findings.find(x=>x.file==="r.js").fingerprint')"
check_match "AC6 reason cites fingerprint" "$(jget "$OUT" 'j.gate_status')" "reopen-guard: ${FP} re-opened 3x"
check "AC6 first_seen_round preserved"  "$(jget "$(cat "$L")" 'j.rounds[6].findings.find(x=>x.file==="r.js").first_seen_round')" "1"
# A flapping advisory finding never trips the guard; the walk is held open by a MEDIUM.
L="$WORK/ac6-low.json"
X="$(f r.js:5 LOW 'Flapping naming nit')"
for r in 1 2 3 4 5 6 7; do
  if [ $((r % 2)) -eq 1 ]; then rec "$L" "$r" "[$X,$Y]"; else rec "$L" "$r" "[$Y]"; fi
done
check "AC6 advisory reopened past cap → CONTINUE" "$(jget "$OUT" 'j.decision')" "CONTINUE"
check "AC6 advisory reopens still counted" "$(jget "$(cat "$L")" 'j.rounds[6].findings.find(x=>x.file==="r.js").reopen_count')" "3"

# --- AC7: category severity floor ---
L="$WORK/ac7.json"
rec "$L" 1 "[$(f db.sql:4 LOW 'Row count not checked' data-integrity)]"
check "AC7 data-integrity LOW stored MEDIUM" "$(jget "$(cat "$L")" 'j.rounds[0].findings[0].severity')" "MEDIUM"
check "AC7 reported severity kept"      "$(jget "$(cat "$L")" 'j.rounds[0].findings[0].severity_reported')" "LOW"
check "AC7 floored finding gates counter" "$(jget "$OUT" 'j.counters.consecutive_clean_rounds')" "0"
for c in migration auth secrets; do
  L="$WORK/ac7-$c.json"
  rec "$L" 1 "[$(f x:1 INFO 'n' "$c")]"
  check "AC7 $c INFO floored to MEDIUM" "$(jget "$(cat "$L")" 'j.rounds[0].findings[0].severity')" "MEDIUM"
done
L="$WORK/ac7-gen.json"
rec "$L" 1 "[$(f x:1 HIGH 'n' 'made-up-category'),$(f y:1 LOW 'm')]"
check "AC7 unknown/missing category → general" "$(jget "$(cat "$L")" 'j.rounds[0].findings.map(x=>x.category).join()')" "general,general"
check "AC7 floor never lowers HIGH"     "$(jget "$(cat "$L")" 'j.rounds[0].findings[0].severity')" "HIGH"
check_match "AC7 off-enum category reported" "$(jget "$OUT" 'j.reasons.join()')" "category 'made-up-category' not in enum"
L="$WORK/ac7-case.json"
rec "$L" 1 "[$(f src/auth.ts:3 LOW 'Token not rotated' ' Auth ')]"
check "AC7 category is case/space-normalized before the floor" "$(jget "$(cat "$L")" 'j.rounds[0].findings[0].category+":"+j.rounds[0].findings[0].severity')" "auth:MEDIUM"

# --- AC8: always-on, fails closed (HUMAN_GATE, ledger untouched) ---
L="$WORK/ac8.json"
rec "$L" 1 "[$(f a:1 LOW 'n')]"
cp "$L" "$WORK/ac8.before"
rec "$L" 2 "not json"
check "AC8 malformed stdin exits 2"     "$CODE" "2"
check "AC8 malformed stdin → HUMAN_GATE" "$(jget "$OUT" 'j.decision')" "HUMAN_GATE"
check_match "AC8 error gate string"     "$(jget "$OUT" 'j.gate_status')" '^HUMAN_GATE — convergence controller error: '
if cmp -s "$L" "$WORK/ac8.before"; then check "AC8 ledger untouched on error" ok ok; else check "AC8 ledger untouched on error" "AC8 ledger modified on error" ok; fi
rec "$L" 2 '[{"location":"a:1","severity":"SEVERE","title":"x"}]'
check "AC8 invalid severity → exit 2"   "$CODE" "2"
rec "$WORK/badgate.json" 1 "[]" "Gate 3"
check "AC8 invalid --gate → exit 2"     "$CODE" "2"
printf '{broken' >"$WORK/corrupt.json"
rec "$WORK/corrupt.json" 2 "[]"
check "AC8 corrupt ledger → exit 2"     "$CODE" "2"
check "AC8 corrupt ledger → HUMAN_GATE" "$(jget "$OUT" 'j.decision')" "HUMAN_GATE"
check "AC8 corrupt ledger untouched"    "$(cat "$WORK/corrupt.json")" "{broken"
OUT="$(node "$CTL" record --ledger "$WORK/noargs.json" </dev/null 2>/dev/null)"; CODE=$?
check "AC8 missing args → exit 2"       "$CODE" "2"
check "AC8 missing args → no ledger"    "$([ -e "$WORK/noargs.json" ] && echo yes || echo no)" "no"
L="$WORK/ac8-null.json"
rec "$L" 1 "[]"
cp "$L" "$WORK/ac8-null.before"
rec "$L" 2 '[null]'
check "AC8 null element → exit 2"           "$CODE" "2"
check "AC8 null element → HUMAN_GATE"       "$(jget "$OUT" 'j.decision')" "HUMAN_GATE"
check_match "AC8 null element error cites index" "$(jget "$OUT" 'j.error')" 'finding 0 is not an object'
if cmp -s "$L" "$WORK/ac8-null.before"; then check "AC8 null element leaves ledger untouched" ok ok; else check "AC8 null element leaves ledger untouched" "AC8 null element modified ledger" ok; fi
for bad in 'false' '0' '""' '[]'; do
  rec "$WORK/ac8-falsy.json" 1 "[$bad]"
  check "AC8 non-object element $bad → exit 2" "$CODE" "2"
done

# An errored round never reaches the ledger — the next clean round must not lock over its findings.
L="$WORK/ac8-gap.json"
rec "$L" 1 "[$(f a:1 HIGH 'h')]"
rec "$L" 2 "[]"
rec "$L" 3 '[{"location":"a:1","severity":"HIGH"}]'   # round 3 errors (no title) → never recorded
check "AC8 errored round → exit 2"          "$CODE" "2"
rec "$L" 4 "[]"
check "AC8 clean round after a gap never locks" "$(jget "$OUT" 'j.decision')" "CONTINUE"
check "AC8 gap resets the clean streak"     "$(jget "$OUT" 'j.counters.consecutive_clean_rounds')" "1"
check_match "AC8 gap reason names missing round" "$(jget "$OUT" 'j.reasons.join()')" 'round\(s\) 3 missing from ledger'
check "AC8 status sees the reset streak"    "$(jget "$(node "$CTL" status --ledger "$L" 2>/dev/null)" 'j.consecutive_clean_rounds')" "1"
rec "$L" 5 "[]"
check "AC8 two clean rounds after a gap → LOCKED" "$(jget "$OUT" 'j.decision')" "LOCKED"
L="$WORK/ac8-gap-g2.json"
rec "$L" 1 "[]"
rec "$L" 3 "[]" "Gate 2"                 # round 2 errored → gap before a clean peer round
check_match "AC8 Gate 2 after a gap reports the reset" "$(jget "$OUT" 'j.gate_status')" 'Gate 1 streak reset'
check "AC8 Gate 2 after a gap zeroes the streak" "$(jget "$OUT" 'j.counters.consecutive_clean_rounds')" "0"
rec "$L" 4 "[]"
check "AC8 clean Gate 2 never bridges a gap" "$(jget "$OUT" 'j.decision')" "CONTINUE"
# A ledger inherited from another branch (same ticket key) never carries its streak or lock over.
L="$WORK/target.json"
rec "$L" 1 "[]"; rec "$L" 2 "[]"                       # locked on feat/42-t
OUT="$(printf '[]' | node "$CTL" record --ledger "$L" --target feat/42-followup --round 3 --sha sha3 2>/dev/null)"
check "target change never locks on the first clean round" "$(jget "$OUT" 'j.decision')" "CONTINUE"
check "target change resets the clean streak"   "$(jget "$OUT" 'j.counters.consecutive_clean_rounds')" "1"
check_match "target change reason names both branches" "$(jget "$OUT" 'j.reasons.join()')" 'target changed feat/42-t → feat/42-followup'
check "target change keeps prior rounds"        "$(jget "$(cat "$L")" 'j.rounds.length')" "3"
S="$(node "$CTL" status --ledger "$L" --target feat/42-followup 2>/dev/null)"
check "status --target sees the new branch unlocked" "$(jget "$S" 'j.locked+":"+j.consecutive_clean_rounds')" "false:1"
L="$WORK/target-lock.json"
rec "$L" 1 "[]"; rec "$L" 2 "[]"
S="$(node "$CTL" status --ledger "$L" --target other-branch 2>/dev/null)"
check "status on a foreign target → not locked"  "$(jget "$S" 'j.locked+":"+j.last_clean')" "false:null"
S="$(node "$CTL" status --ledger "$L" --target feat/42-t 2>/dev/null)"
check "status on the same target → locked"      "$(jget "$S" 'j.locked')" "true"
L="$WORK/target-cap.json"
for r in 1 2 3 4 5 6 7; do rec "$L" "$r" "[$(f "t$r.js:1" MEDIUM "churn $r")]"; done
OUT="$(printf '%s' "[$(f x.js:1 LOW 'n')]" | node "$CTL" record --ledger "$L" --target feat/42-followup --round 8 --sha sha8 2>/dev/null)"
check "target change restarts the round cap"    "$(jget "$OUT" 'j.decision')" "CONTINUE"

# A ledger written before per-round targets existed inherits the ledger-level target.
L="$WORK/legacy.json"
printf '%s' '{"schema_version":1,"target":"feat/42-t","rounds":[{"round":1,"gate":"Gate 1","sha":"s1","decision":"CONTINUE","clean":true,"reopen_events":0,"findings":[]}]}' >"$L"
S="$(node "$CTL" status --ledger "$L" --target feat/42-t 2>/dev/null)"
check "legacy ledger rounds inherit the ledger target (status)" "$(jget "$S" 'j.consecutive_clean_rounds')" "1"
rec "$L" 2 "[]"
check "legacy ledger rounds inherit the ledger target (record)" "$(jget "$OUT" 'j.decision')" "LOCKED"
check "legacy ledger raises no target-change reason" "$(jget "$OUT" 'j.reasons.some(r=>r.includes("target changed"))')" "false"

# status without --target scopes the streak to the newest round's target, as record does.
L="$WORK/unscoped.json"
rec "$L" 1 "[]"; rec "$L" 2 "[]"
printf '[]' | node "$CTL" record --ledger "$L" --target feat/42-followup --round 3 --sha sha3 >/dev/null 2>&1
check "unscoped status streak follows the newest target" "$(jget "$(node "$CTL" status --ledger "$L" 2>/dev/null)" 'j.consecutive_clean_rounds')" "1"

# A failed rename never leaves an orphan temp file next to the ledger.
mkdir -p "$WORK/rename"
L="$WORK/rename/ledger.json"
printf '%s\n' "require('fs').renameSync = () => { throw new Error('EPERM: simulated'); };" >"$WORK/failrename.js"
OUT="$(printf '[]' | NODE_OPTIONS="--require $WORK/failrename.js" node "$CTL" record --ledger "$L" --target t --round 1 --sha s 2>/dev/null)"; CODE=$?
check "failed ledger write exits 2"             "$CODE" "2"
check "failed ledger write leaves no temp file" "$(find "$WORK/rename" -name '*.tmp' | wc -l | tr -d ' ')" "0"
printf '%s\n' "const fs = require('fs'); fs.renameSync = () => { throw new Error('EPERM: rename simulated'); }; fs.rmSync = () => { throw new Error('EBUSY: unlink simulated'); };" >"$WORK/failboth.js"
OUT="$(printf '[]' | NODE_OPTIONS="--require $WORK/failboth.js" node "$CTL" record --ledger "$WORK/rename/b.json" --target t --round 1 --sha s 2>/dev/null)"
check_match "failed cleanup keeps the rename error as the cause" "$(jget "$OUT" 'j.error')" 'EPERM: rename simulated.*not removed: EBUSY'
rm -f "$WORK"/rename/*.tmp

L="$WORK/ac8-upgrade.json"
rec "$L" 6 "[]"; rec "$L" 7 "[]"
check "empty ledger starting mid-branch still locks" "$(jget "$OUT" 'j.decision')" "LOCKED"

# --- robustness: dedup, location normalization, error index, history-replace warning ---
L="$WORK/dedup.json"
rec "$L" 1 "[$(f d.js:1 LOW 'Same defect'),$(f d.js:40 HIGH 'same DEFECT!')]"
check "dedup keeps one entry"              "$(jget "$(cat "$L")" 'j.rounds[0].findings.length')" "1"
check "dedup keeps the higher severity"    "$(jget "$(cat "$L")" 'j.rounds[0].findings[0].severity')" "HIGH"
L="$WORK/loc.json"
rec "$L" 1 "[$(f 'a.js (lines 10-20)' LOW 'x'),$(f a.js:L42 LOW 'y'),$(f a.js:3-9 LOW 'z')]"
check "location suffix forms normalize"    "$(jget "$(cat "$L")" 'j.rounds[0].findings.map(x=>x.file).join()')" "a.js,a.js,a.js"
L="$WORK/notimpl.json"
rec "$L" 1 '[{"location":"(not implemented)","severity":"HIGH","title":"Unmet acceptance criterion #2: x"}]'
check "all-parenthetical location keeps raw text" "$(jget "$(cat "$L")" 'j.rounds[0].findings[0].file')" "(not implemented)"
check "raw title persisted for PRIOR LEDGER"      "$(jget "$(cat "$L")" 'j.rounds[0].findings[0].title')" "Unmet acceptance criterion #2: x"
rec "$WORK/idx.json" 1 '[{"location":"x:1","severity":"LOW","title":"t","in_scope":false},{"severity":"LOW","title":"no loc"}]'
check_match "error cites original input index" "$(jget "$OUT" 'j.gate_status')" 'finding 1 has no location'
L="$WORK/replace.json"
rec "$L" 1 "[]"; rec "$L" 2 "[]"; rec "$L" 3 "[]"
rec "$L" 1 "[]"
check_match "re-recording an earlier round warns" "$(jget "$OUT" 'j.reasons.join()')" 'replaced ledger round\(s\) 1, 2, 3'

# --- Gate 2 rounds, status gaps, argument parsing ---
# g2: Gate 2 rounds never consume the Gate 1 cap (no lock to stop the count).
L="$WORK/g2cap.json"
for r in 1 2 3 4; do rec "$L" "$r" "[$(f "a$r.js:1" MEDIUM "g1 churn $r")]"; done
for r in 5 6 7 8; do rec "$L" "$r" "[$(f "b$r.js:1" MEDIUM "g2 churn $r")]" "Gate 2"; done
rec "$L" 9 "[$(f a9.js:1 MEDIUM 'g1 churn 9')]"
check "g2: Gate 2 rounds never consume the cap"   "$(jget "$OUT" 'j.decision')" "CONTINUE"
for r in 10 11; do rec "$L" "$r" "[$(f "a$r.js:1" MEDIUM "g1 churn $r")]"; done
rec "$L" 12 "[$(f a12.js:1 MEDIUM 'g1 churn 12')]"
check "g2: eighth Gate 1 round hits the cap"      "$(jget "$OUT" 'j.decision')" "HUMAN_GATE"
L="$WORK/g2dirty.json"
rec "$L" 1 "[]"; rec "$L" 2 "[$(f a.js:1 MEDIUM 'peer')]" "Gate 2"
check "g2: dirty Gate 2 round zeroes the streak"  "$(jget "$OUT" 'j.counters.consecutive_clean_rounds')" "0"
check "g2: self_inflicted is always false"        "$(jget "$(cat "$L")" 'j.rounds.every(r=>r.findings.every(x=>x.self_inflicted===false))')" "true"
L="$WORK/nofloor.json"
rec "$L" 1 "[$(f a.js:1 MEDIUM 'already medium' auth)]"
check "g2: MEDIUM auth finding has no severity_reported" "$(jget "$(cat "$L")" '"severity_reported" in j.rounds[0].findings[0]')" "false"

# gap: status never reports a lock across a round gap.
L="$WORK/lockgap.json"
rec "$L" 1 "[]"; rec "$L" 2 "[]"; rec "$L" 4 "[]" "Gate 2"
check "gap: lock → gap → clean G2 is not locked"   "$(jget "$(node "$CTL" status --ledger "$L" 2>/dev/null)" 'j.locked')" "false"
L="$WORK/lockround.json"
rec "$L" 1 "[]"; rec "$L" 2 "[]"
check "gap: status --round after an unrecorded round is not locked" "$(jget "$(node "$CTL" status --ledger "$L" --round 4 2>/dev/null)" 'j.locked')" "false"
check "gap: status --round next round stays locked" "$(jget "$(node "$CTL" status --ledger "$L" --round 3 2>/dev/null)" 'j.locked')" "true"

# args: unknown / duplicate options and non-canonical --round fail closed.
L="$WORK/args.json"
rec "$L" 1 "[]"; cp "$L" "$WORK/args.before"
OUT="$(printf '[]' | node "$CTL" record --ledger "$L" --target t --round 2 --sha s --gat "Gate 2" 2>/dev/null)"; CODE=$?
check "args: misspelled --gate → exit 2"            "$CODE" "2"
if cmp -s "$L" "$WORK/args.before"; then check "args: misspelled option leaves ledger untouched" ok ok; else check "args: misspelled option leaves ledger untouched" "args: misspelled option modified ledger" ok; fi
for bad in 0 0x2 1e0 3.0 +4 ' 3'; do
  OUT="$(printf '[]' | node "$CTL" record --ledger "$L" --target t --round "$bad" --sha s 2>/dev/null)"; CODE=$?
  check "args: --round '$bad' → exit 2" "$CODE" "2"
done
OUT="$(printf '[]' | node "$CTL" record --ledger "$L" --target t --round 2 --round 3 --sha s 2>/dev/null)"; CODE=$?
check "args: duplicate option → exit 2"             "$CODE" "2"
for args in '--gate' '--target:' '--sha:'; do          # a valueless trailing option, or an empty value (failed $(…))
  case "$args" in
    --gate)    set -- --target t --round 2 --sha s --gate ;;
    --target:) set -- --target "" --round 2 --sha s ;;
    --sha:)    set -- --target t --round 2 --sha "" ;;
  esac
  OUT="$(printf '[]' | node "$CTL" record --ledger "$L" "$@" 2>/dev/null)"; CODE=$?
  check "args: ${args%:} missing/empty value → exit 2" "$CODE" "2"
  check "args: ${args%:} missing/empty value → HUMAN_GATE" "$(jget "$OUT" 'j.decision')" "HUMAN_GATE"
  if cmp -s "$L" "$WORK/args.before"; then check "args: ${args%:} leaves ledger untouched" ok ok; else check "args: ${args%:} leaves ledger untouched" "args: ${args%:} modified ledger" ok; fi
done
set --
node "$CTL" status --ledger "$L" --bogus x >/dev/null 2>&1; CODE=$?
check "args: status unknown option → exit 2"        "$CODE" "2"

# g2-resolve: a Gate 2 round never resolves Gate 1 findings, so never inflates reopen_count.
L="$WORK/g2resolve.json"
rec "$L" 1 "[$(f a.js:1 MEDIUM 'never fixed')]"
rec "$L" 2 "[]" "Gate 2"
rec "$L" 3 "[$(f a.js:1 MEDIUM 'never fixed')]"
check "g2-resolve: Gate 2 round never counts as a reopen" "$(jget "$(cat "$L")" 'j.rounds[2].findings[0].reopen_count')" "0"
check "g2-resolve: Gate 2 round carries no RESOLVED entries" "$(jget "$(cat "$L")" 'j.rounds[1].findings.length')" "0"
L="$WORK/g2resolve2.json"
rec "$L" 1 "[$(f a.js:1 MEDIUM 'fixed later')]"
rec "$L" 2 "[]" "Gate 2"
rec "$L" 3 "[]"
check "g2-resolve: Gate 1 resolves across an intervening Gate 2 round" "$(jget "$(cat "$L")" 'j.rounds[2].findings.map(x=>x.status).join()')" "RESOLVED"

# shape: malformed ledger rounds fail closed with a named error.
printf '%s' '{"schema_version":1,"target":"t","rounds":[{"round":1,"gate":"Gate 1","sha":"s","decision":"LOCKED","clean":"yes","reopen_events":0,"findings":[]}]}' >"$WORK/badclean.json"
rec "$WORK/badclean.json" 2 "[]"
check "shape: non-boolean clean → exit 2"           "$CODE" "2"
check_match "shape: error names the bad field"      "$(jget "$OUT" 'j.error')" 'round 1 .*clean'
printf '%s' '{"schema_version":1,"target":"t","rounds":[{"round":1,"gate":"Gate 1","sha":"s","decision":"CONTINUE","clean":true,"reopen_events":0}]}' >"$WORK/nofind.json"
rec "$WORK/nofind.json" 2 "[]"
check_match "shape: missing findings is a named error" "$(jget "$OUT" 'j.error')" 'round 1 .*findings'
for bad in '"round":"1","gate":"Gate 1","clean":true,"findings":[]:round' \
           '"round":1,"gate":"Gate 3","clean":true,"findings":[]:gate' \
           '"round":1,"gate":"Gate 1","clean":false,"findings":[{"fingerprint":"sha256:x","status":"open"}]:findings\[\]' \
           '"round":1,"gate":"Gate 1","clean":false,"findings":[{"status":"OPEN"}]:findings\[\]'; do
  body="${bad%:*}"; field="${bad##*:}"; label="${field//\\/}"
  printf '{"schema_version":1,"target":"t","rounds":[{%s,"sha":"s","decision":"CONTINUE","reopen_events":0}]}' "$body" >"$WORK/shape.json"
  rec "$WORK/shape.json" 2 "[]"
  check "shape: invalid ledger $label → exit 2" "$CODE" "2"
  check_match "shape: error names $label" "$(jget "$OUT" 'j.error')" "invalid $field field"
done
for bad in '{"schema_version":2,"target":"t","rounds":[]}' '{"schema_version":1,"target":"t","rounds":{}}'; do
  printf '%s' "$bad" >"$WORK/schema.json"
  rec "$WORK/schema.json" 1 "[]"
  check "shape: unsupported schema → exit 2"   "$CODE" "2"
  check_match "shape: unsupported schema is named" "$(jget "$OUT" 'j.error')" 'unsupported schema'
done
mkdir -p "$WORK/isdir.json"
rec "$WORK/isdir.json" 1 "[]"
check_match "shape: unreadable ledger is not called invalid JSON" "$(jget "$OUT" 'j.error')" 'unreadable \(EISDIR\)'

# fp: fingerprint canonicalization.
fp() { rec "$WORK/fp-$1.json" 1 "[$(f "$2" MEDIUM "$3")]"; jget "$(cat "$WORK/fp-$1.json")" 'j.rounds[0].findings[0].fingerprint'; }
check "fp: NFC and NFD titles match"             "$(fp n1 a.js "$(printf 'caf\xc3\xa9 bug')")" "$(fp n2 a.js "$(printf 'cafe\xcc\x81 bug')")"
check "fp: punctuation is a word break"          "$(fp p1 a.js 'round-cap bug')" "$(fp p2 a.js 'round cap bug')"
check "fp: #L suffix strips"                     "$(fp s1 'a.js#L42' 't')" "$(fp s2 a.js t)"
check "fp: line:col range strips"                "$(fp s3 'a.js:12:4-12:9' 't')" "$(fp s4 a.js t)"
check "fp: en-dash range strips"               "$(fp s9 'a.js:12–15' t)" "$(fp s10 a.js t)"
check "fp: comma list with an L-prefixed en-dash range strips" "$(fp s11 'a.js:12, L40–45' t)" "$(fp s12 a.js t)"
check "fp: comma line list strips"               "$(fp s5 'a.js:12, 40' 't')" "$(fp s6 a.js t)"
check "fp: leading ./ and backslashes canonicalize" "$(fp s7 '.\\src\\a.js:3' 't')" "$(fp s8 src/a.js t)"
rec "$WORK/emoji.json" 1 '[{"location":"a.js","severity":"LOW","title":"🔥🔥"}]'
check "fp: all-symbol title → exit 2"            "$CODE" "2"

# --- status: Pass 2b reads the prior counter + last clean round from the ledger ---
L="$WORK/status.json"
rec "$L" 1 "[$(f a:1 MEDIUM 'm')]"
rec "$L" 2 "[]"
S="$(node "$CTL" status --ledger "$L" 2>/dev/null)"
check "status consecutive_clean_rounds" "$(jget "$S" 'j.consecutive_clean_rounds')" "1"
check "status last_clean round+sha"     "$(jget "$S" 'j.last_clean.round+":"+j.last_clean.sha')" "2:sha2"
check "status 1-clean streak is not locked" "$(jget "$S" 'j.locked')" "false"
rec "$L" 3 "[]"
check "status after lock → locked"      "$(jget "$(node "$CTL" status --ledger "$L" 2>/dev/null)" 'j.locked')" "true"
S="$(node "$CTL" status --ledger "$WORK/missing.json" 2>/dev/null)"
check "status on missing ledger → zero" "$(jget "$S" 'j.consecutive_clean_rounds+":"+j.last_clean')" "0:null"

# --- --skip: Files / Folder / Ad-hoc round numbers in the review file are never a ledger gap ---
L="$WORK/skip.json"
rec "$L" 1 "[]"
OUT="$(printf '[]' | node "$CTL" record --ledger "$L" --target feat/42-t --round 3 --sha sha3 --skip 2 2>/dev/null)"
check "skip: a skipped partial round is no gap → LOCKED" "$(jget "$OUT" 'j.decision')" "LOCKED"
check "skip: no gap reason" "$(jget "$OUT" 'j.reasons.some(r => r.includes("missing from ledger"))')" "false"
check "skip: status --round past a skipped round keeps the lock" \
  "$(jget "$(node "$CTL" status --ledger "$L" --round 5 --skip 2,4 2>/dev/null)" 'j.locked+":"+j.consecutive_clean_rounds')" "true:2"
check "skip: status --round past an unskipped round breaks the lock" \
  "$(jget "$(node "$CTL" status --ledger "$L" --round 5 --skip 2 2>/dev/null)" 'j.locked')" "false"
check "skip: an empty list is accepted" "$(node "$CTL" status --ledger "$L" --skip '' >/dev/null 2>&1; echo $?)" "0"
L="$WORK/skip-gap.json"
rec "$L" 1 "[]"
OUT="$(printf '[]' | node "$CTL" record --ledger "$L" --target feat/42-t --round 4 --sha sha4 --skip 2 2>/dev/null)"
check "skip: an unskipped missing round is still a gap" "$(jget "$OUT" 'j.decision+":"+j.reasons.join()')" "CONTINUE:round(s) 3 missing from ledger — clean streak reset"
printf '[]' | node "$CTL" record --ledger "$L" --target feat/42-t --round 5 --sha sha5 --skip 'x' >/dev/null 2>&1
check "skip: a malformed list fails closed (exit 2)" "$?" "2"

echo "=================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] && [ "$fails" -eq 0 ]
