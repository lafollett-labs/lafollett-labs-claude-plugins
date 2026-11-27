#!/usr/bin/env bash
# Dependency-free test harness for the publish-body helper.
# `prepare` makes a Markdown file ready to publish (Test Plan written into the file, Test Plan and
# fence lint); `body` splits the file into the issue title and body; `verify` compares the body the
# file publishes with the body GitHub stored. Every `prepare` case runs on a throwaway copy, so
# fixtures are never rewritten. bash + node only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PB="$HERE/../publish-body.js"
FIXTURES="$HERE/fixtures"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH — cannot run publish-body tests"
  echo "1 checks, 1 failed"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

checks=0
fails=0
OUT=""
CODE=0

# crlf <src> <dst> — copy with every line ending rewritten to CRLF (POSIX awk; no sed \r)
crlf() { awk '{ printf "%s\r\n", $0 }' "$1" > "$2"; }

# run <subcommand> <args...> — sets OUT and CODE
run() {
  OUT="$(node "$PB" "$@" 2>/dev/null)"
  CODE=$?
}
prep() { run prepare --file "$1" --type "$2"; }
ver() { run verify --file "$1" --readback "$2"; }

# copy <fixture> — fresh writable copy under $WORK; prints its path
n=0
copy() {
  n=$((n + 1))
  local dst="$WORK/$n-$1"
  cp "$FIXTURES/$1" "$dst"
  printf '%s' "$dst"
}

# jget <json> <js-expr over `j`> — evaluate an expression against parsed JSON
jget() {
  node -e 'const j=JSON.parse(process.argv[1]); let v; try { v=eval(process.argv[2]) } catch { v=undefined }
    process.stdout.write(typeof v==="string"?v:String(JSON.stringify(v)))' "$1" "$2" 2>/dev/null
}

# check <name> <actual> <expected>
check() {
  checks=$((checks + 1))
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 — expected [$3], got [$2]"
    fails=$((fails + 1))
  fi
}

# same_bytes <name> <actual-file> <expected-file>
same_bytes() {
  checks=$((checks + 1))
  if cmp -s "$2" "$3"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 — bytes differ from $(basename "$3")"
    fails=$((fails + 1))
  fi
}

echo "=== publish-body tests ==="

# --- prepare: Test Plan write-back ---------------------------------------------------------

f="$(copy pb-story.md)"
prep "$f" Story
check "story: exit 0" "$CODE" 0
check "story: test plan added" "$(jget "$OUT" j.testPlan)" added
same_bytes "story: file gains the rendered Test Plan" "$f" "$FIXTURES/pb-story.expected"

prep "$f" Story
check "story re-run: test plan present" "$(jget "$OUT" j.testPlan)" present
same_bytes "story re-run: file unchanged" "$f" "$FIXTURES/pb-story.expected"

for t in Task Bug; do
  f="$(copy pb-story.md)"
  prep "$f" "$t"
  check "$t: test plan added" "$(jget "$OUT" j.testPlan)" added
done

f="$WORK/no-final-newline.md"
printf '%s' "$(cat "$FIXTURES/pb-story.md")" > "$f"
prep "$f" Story
same_bytes "no final newline: appended cleanly" "$f" "$FIXTURES/pb-story.expected"

f="$WORK/story-crlf.md"; crlf "$FIXTURES/pb-story.md" "$f"
crlf "$FIXTURES/pb-story.expected" "$WORK/story-crlf.expected"
prep "$f" Story
check "crlf: test plan added" "$(jget "$OUT" j.testPlan)" added
same_bytes "crlf: appended lines keep CRLF" "$f" "$WORK/story-crlf.expected"

f="$(copy pb-has-test-plan.md)"
prep "$f" Story
check "authored test plan: present" "$(jget "$OUT" j.testPlan)" present
same_bytes "authored test plan: file unchanged" "$f" "$FIXTURES/pb-has-test-plan.md"
check "authored test plan: exactly one heading" "$(grep -c '^## Test Plan' "$f")" 1

f="$(copy pb-test-plan-heading-variant.md)"
prep "$f" Story
check "heading variant: present" "$(jget "$OUT" j.testPlan)" present
same_bytes "heading variant: file unchanged" "$f" "$FIXTURES/pb-test-plan-heading-variant.md"

f="$(copy pb-fenced-test-plan.md)"
prep "$f" Story
check "fenced heading: not a Test Plan, so one is added" "$(jget "$OUT" j.testPlan)" added
check "fenced heading: no warnings" "$(jget "$OUT" j.warnings.length)" 0
same_bytes "fenced heading: real Test Plan appended" "$f" "$FIXTURES/pb-fenced-test-plan.expected"

# A line starting with a one-line ```span``` is inline code, not a fence: the Test Plan below it is real.
f="$(copy pb-inline-span.md)"
prep "$f" Story; prep "$f" Story
check "inline span: Test Plan stays present on re-run" "$(jget "$OUT" j.testPlan)" present
same_bytes "inline span: file unchanged after two runs" "$f" "$FIXTURES/pb-inline-span.md"

# Never append inside a fence that never closes: warn instead, on every run.
f="$(copy pb-unclosed-fence.md)"
prep "$f" Story; prep "$f" Story
check "unclosed fence: nothing appended" "$(jget "$OUT" j.testPlan)" none
check "unclosed fence: warned at the opening fence" \
  "$(jget "$OUT" 'j.warnings.map(w=>w.rule+":"+w.line+":"+w.section).join("|")')" "unclosed-fence:9:Notes"
same_bytes "unclosed fence: file unchanged after two runs" "$f" "$FIXTURES/pb-unclosed-fence.md"

# A fence line with an info string never closes a block, so the bare fence after it does: no false unclosed fence.
f="$(copy tp-fence-info-line.md)"
prep "$f" Story
check "info-string fence line: test plan added" "$(jget "$OUT" j.testPlan)" added
check "info-string fence line: no warnings" "$(jget "$OUT" j.warnings.length)" 0

f="$WORK/has-tp-crlf.md"; crlf "$FIXTURES/pb-has-test-plan.md" "$f"; cp "$f" "$WORK/has-tp-crlf.orig"
prep "$f" Story
check "crlf authored test plan: present" "$(jget "$OUT" j.testPlan)" present
same_bytes "crlf authored test plan: file unchanged" "$f" "$WORK/has-tp-crlf.orig"

f="$WORK/cp1252.md"
printf '# Story: Quote\n\n## Acceptance Criteria\n\n- [ ] Show \223smart\224 quotes\n' > "$f"
cp "$f" "$WORK/cp1252.orig"
prep "$f" Story
check "not utf-8: exit 1" "$CODE" 1
same_bytes "not utf-8: file untouched" "$f" "$WORK/cp1252.orig"

f="$(copy tp-no-acs.md)"
prep "$f" Story
check "no ACs: none" "$(jget "$OUT" j.testPlan)" none
same_bytes "no ACs: file unchanged" "$f" "$FIXTURES/tp-no-acs.md"

# --- prepare: other types get no Test Plan; checklists with inline code are fine on GitHub ----

for t in Epic Subtask Spike; do
  f="$(copy pb-ac-inline-code.md)"
  prep "$f" "$t"
  check "$t: exit 0" "$CODE" 0
  check "$t: test plan n/a" "$(jget "$OUT" j.testPlan)" n/a
  check "$t: inline code in a checklist is not warned" "$(jget "$OUT" j.warnings.length)" 0
  same_bytes "$t: file unchanged" "$f" "$FIXTURES/pb-ac-inline-code.md"
done

f="$(copy pb-unclosed-fence.md)"
prep "$f" Epic
check "epic unclosed fence: warned at the opening fence" \
  "$(jget "$OUT" 'j.warnings.map(w=>w.rule+":"+w.line).join("|")')" "unclosed-fence:9"
same_bytes "epic unclosed fence: file unchanged" "$f" "$FIXTURES/pb-unclosed-fence.md"

f="$WORK/cp1252-epic.md"
printf '# Epic: Quote\n\n## Description\n\nShow \223smart\224 quotes\n' > "$f"
cp "$f" "$WORK/cp1252-epic.orig"
prep "$f" Epic
check "epic not utf-8: exit 1" "$CODE" 1
same_bytes "epic not utf-8: file untouched" "$f" "$WORK/cp1252-epic.orig"

f="$(copy pb-duplicate-test-plan.md)"
prep "$f" Story
check "duplicate: present" "$(jget "$OUT" j.testPlan)" present
check "duplicate: warned at the second heading" \
  "$(jget "$OUT" 'j.warnings.map(w=>w.rule+":"+w.line).join("|")')" "duplicate-test-plan:11"
same_bytes "duplicate: file unchanged" "$f" "$FIXTURES/pb-duplicate-test-plan.md"

# --- prepare: usage / IO errors exit 1 and write nothing ------------------------------------

prep "$WORK/does-not-exist.md" Story
check "missing file: exit 1" "$CODE" 1
prep "$WORK" Story
check "directory as --file: exit 1" "$CODE" 1
f="$(copy pb-story.md)"
prep "$f" ""
check "empty --type: exit 1" "$CODE" 1
same_bytes "empty --type: file unchanged" "$f" "$FIXTURES/pb-story.md"
run prepare --file "$f"
check "missing --type: exit 1" "$CODE" 1
run
check "missing subcommand: exit 1" "$CODE" 1
check "no temp files left behind" "$(find "$WORK" -name '*.tmp' | wc -l | tr -d ' ')" 0

# --- body: title from the H1, body after it ---------------------------------------------------

run body --file "$FIXTURES/pb-story.md"
check "body: exit 0" "$CODE" 0
check "body: title drops the type label" "$(jget "$OUT" j.title)" "Book Filtering"
check "body: starts after the H1 and its blank line" "$(jget "$OUT" 'j.body.split("\n")[0]')" "## Description"
check "body: no H1 left in the body" "$(jget "$OUT" '/^# /m.test(j.body)')" false

f="$WORK/01-Story-Sign-In-With-Email.md"
printf '## Acceptance Criteria\n\n- [ ] Signed in\n' > "$f"
run body --file "$f"
check "no H1: title from the file name" "$(jget "$OUT" j.title)" "Sign In With Email"
check "no H1: the whole file is the body" "$(jget "$OUT" 'j.body.split("\n")[0]')" "## Acceptance Criteria"

f="$WORK/c-sharp.md"
printf '# Task: Support C#\n\nBody\n' > "$f"
run body --file "$f"
check "title keeps a trailing # that is not a closing sequence" "$(jget "$OUT" j.title)" "Support C#"

f="$WORK/closing.md"
printf '\n\n# Epic: Search ##\n\n\nBody\n' > "$f"
run body --file "$f"
check "closing hashes and leading blank lines dropped" "$(jget "$OUT" 'j.title+"|"+JSON.stringify(j.body)')" 'Search|"Body\n"'

# --- verify: stored body equality ------------------------------------------------------------

ver "$FIXTURES/pb-sent.md" "$FIXTURES/pb-rb-ok.md"
check "stored body equal: exit 0" "$CODE" 0
check "stored body equal" "$(jget "$OUT" j.equal)" true
check "stored body equal: no line" "$(jget "$OUT" j.line)" null

crlf "$FIXTURES/pb-rb-ok.md" "$WORK/rb-crlf.md"
ver "$FIXTURES/pb-sent.md" "$WORK/rb-crlf.md"
check "CRLF readback: equal" "$(jget "$OUT" j.equal)" true

crlf "$FIXTURES/pb-sent.md" "$WORK/sent-crlf.md"
ver "$WORK/sent-crlf.md" "$FIXTURES/pb-rb-ok.md"
check "CRLF file vs LF readback: equal" "$(jget "$OUT" j.equal)" true

{ cat "$FIXTURES/pb-rb-ok.md"; printf '\n\n  \n'; } > "$WORK/rb-trailing.md"
ver "$FIXTURES/pb-sent.md" "$WORK/rb-trailing.md"
check "trailing blank lines: equal" "$(jget "$OUT" j.equal)" true

ver "$FIXTURES/pb-sent.md" "$FIXTURES/pb-rb-edited.md"
check "edited on GitHub: not equal" "$(jget "$OUT" j.equal)" false
check "edited on GitHub: first differing line and both sides" \
  "$(jget "$OUT" 'j.line+"|"+j.sent+"|"+j.stored')" "8|- [ ] Tests pass|- [x] Tests pass"

ver "$FIXTURES/pb-sent.md" "$FIXTURES/pb-rb-no-test-plan.md"
check "Test Plan missing from the stored body: reported where it starts" \
  "$(jget "$OUT" 'j.equal+"|"+j.line+"|"+j.stored')" "false|22|null"

ver "$FIXTURES/pb-sent.md" "$FIXTURES/pb-rb-with-title.md"
check "stored body holds the H1: differs at line 1" "$(jget "$OUT" 'j.equal+"|"+j.line')" "false|1"

ver "$WORK/does-not-exist.md" "$FIXTURES/pb-rb-ok.md"
check "verify missing file: exit 1" "$CODE" 1
run verify --file "$FIXTURES/pb-sent.md"
check "verify missing --readback: exit 1" "$CODE" 1

echo "=========================================="
echo "$checks checks, $fails failed"
[ "$fails" -eq 0 ]
