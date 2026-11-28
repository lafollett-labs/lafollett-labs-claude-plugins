#!/usr/bin/env bash
# Fixture tests for git-conventions.js — branch-name parse and build, Conventional Commits subject check,
# ticket-key extraction (issue #42 and story code LT-02), commit-description sanitizing, and PR base
# resolution (base: gh is the shared stub-gh.sh; git runs hermetically in throwaway repos).
# Each rejection must carry a specific reason. No npm packages — bash + node + git (+ python3 for parity).
# SDLC_TEST_TMP=<dir> keeps the base cases' repos there instead of a self-cleaning mktemp dir.
# Exit 0 = all checks pass, 1 = any fail.
# shellcheck disable=SC2016 # single-quoted JS checks and literal backticks are inputs, never shell expansions
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../git-conventions.js"
FIX="$HERE/fixtures/git-conventions"

command -v node >/dev/null 2>&1 || { echo "FAIL: node not on PATH — cannot run git-conventions tests" >&2; exit 1; }
[ -f "$CLI" ] || { echo "FAIL: git-conventions.js not found at $CLI" >&2; exit 1; }

total=0
fails=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); fails=$((fails + 1)); echo "FAIL: $1"; }

# run <args...> — sets $out and $code
run() { out="$(node "$CLI" "$@" 2>/dev/null)"; code=$?; }
run_stdin() { local file="$1"; shift; out="$(node "$CLI" "$@" < "$file" 2>/dev/null)"; code=$?; }
# field <json> <name> — one field of a JSON object, as text
field() { node -e 'process.stdout.write(String(JSON.parse(process.argv[1])[process.argv[2]]))' "$1" "$2"; }

# check <name> <expected-exit> <js-boolean-expression over `o`>
check() {
  local name="$1" want="$2" expr="$3"
  if [ "$code" -eq "$want" ] && node -e "const o = JSON.parse(process.argv[1]); process.exit(($expr) ? 0 : 1)" "$out" 2>/dev/null; then
    pass "$name"
  else
    fail "$name — exit $code, got: $out"
  fi
}

ISSUE42='o.ticket_key === "#42" && o.key_kind === "issue" && o.issue_number === 42 && o.key_slug === "42"'
STORY='o.ticket_key === "LT-02" && o.key_kind === "story" && o.issue_number === null && o.key_slug === "LT-02"'
NOKEY='o.ticket_key === null && o.key_kind === null && o.issue_number === null && o.key_slug === null'

# --- branch: accepted shapes -------------------------------------------------
for t in feat fix chore docs refactor test; do
  run branch --name "$t/42-some-slug"
  check "branch accepts $t/ with an issue number" 0 "o.ok && o.type === '$t' && $ISSUE42 && o.slug === 'some-slug' && o.on_feature"
  run branch --name "$t/LT-02-some-slug"
  check "branch accepts $t/ with a story code" 0 "o.ok && o.type === '$t' && $STORY && o.slug === 'some-slug' && o.on_feature"
done
run branch --name "fix/42"
check "branch accepts an issue key with no description" 0 "o.ok && $ISSUE42 && o.slug === null"
run branch --name "fix/LT-02"
check "branch accepts a story key with no description" 0 "o.ok && $STORY && o.slug === null"
run branch --name "feat/42-7-steps-to-v2"
check "branch splits an issue number from a digit-led description" 0 'o.ok && o.issue_number === 42 && o.slug === "7-steps-to-v2"'
run branch --name "feat/ABCDE-9-x"
check "branch accepts a five-letter story code" 0 'o.ok && o.ticket_key === "ABCDE-9" && o.key_kind === "story"'

# --- branch: rejected shapes, each with a specific reason ---------------------
run branch --name "main"
check "branch rejects main as a base branch" 1 "!o.ok && !o.on_feature && $NOKEY && /base branch/.test(o.error)"
run branch --name "master"
check "branch rejects master as a base branch" 1 '!o.ok && /base branch/.test(o.error)'
run branch --name "feature/42-x"
check "branch rejects an unknown type prefix" 1 '!o.ok && !o.on_feature && /type prefix/.test(o.error) && o.error.includes("<type>/<issue-number | STORY-CODE>-<description>")'
run branch --name "feat/#42-x"
check "branch rejects a # before the issue number" 1 '!o.ok && !o.on_feature && /drop the `#`/.test(o.error)'
run branch --name "feat/lt-02-x"
check "branch rejects a lowercase story code" 1 '!o.ok && !o.on_feature && /no ticket key/.test(o.error)'
run branch --name "feat/042-x"
check "branch rejects an issue number with a leading zero" 1 '!o.ok && !o.on_feature && /no ticket key/.test(o.error)'
run branch --name "feat/LONGER-2-x"
check "branch rejects a story code longer than five letters" 1 '!o.ok && !o.on_feature && /no ticket key/.test(o.error)'
run branch --name "feat/add-login"
check "branch rejects a description with no key" 1 '!o.ok && !o.on_feature && /no ticket key/.test(o.error)'
run branch --name "feat/2fa-login"
check "branch reads no key from a digit-led description" 1 "!o.ok && !o.on_feature && $NOKEY && /no ticket key/.test(o.error)"
run branch --name "feat/42abc"
check "branch reads no key when a letter follows the number" 1 "!o.ok && !o.on_feature && $NOKEY"
run branch --name "feat/LT-02x-y"
check "branch reads no key when a letter follows a story code" 1 "!o.ok && !o.on_feature && $NOKEY"
run branch --name "feat/42_Foo"
check "branch rejects a non-kebab description but is still on a feature branch" 1 "!o.ok && o.on_feature && $ISSUE42 && /description/.test(o.error)"
run branch --name "feat/LT-02-Upper"
check "branch rejects an uppercase description after a story code" 1 "!o.ok && o.on_feature && $STORY && /description/.test(o.error)"
run branch --name ""
check "branch rejects an empty name" 1 '!o.ok && /empty/.test(o.error)'

# --- commits ------------------------------------------------------------------
run_stdin "$FIX/commits-valid.txt" commits
check "commits accepts typed, scoped, breaking, revert and reapply subjects with no key" 0 'o.ok && o.count === 7 && o.offenders.length === 0'
run_stdin "$FIX/commits-mixed.txt" commits
check "commits reports the offender count" 1 '!o.ok && o.count === 10 && o.offenders.length === 9 && o.error === "9 commit(s) don'"'"'t match Conventional Commits format"'
check "commits names an unknown type" 1 'o.offenders.some(f => f.subject === "feature: add x" && /type `feature` is not one of/.test(f.error))'
check "commits names an uppercase type as unknown" 1 'o.offenders.some(f => f.subject === "Feat: add x" && /type `Feat`/.test(f.error))'
check "commits rejects a revert subject without the quoted original" 1 'o.offenders.some(f => f.subject === "Revert add x" && /missing `<type>: ` prefix/.test(f.error))'
check "commits names a missing prefix" 1 'o.offenders.some(f => f.subject === "add title search" && /missing `<type>: ` prefix/.test(f.error))'
check "commits names an empty scope" 1 'o.offenders.some(f => f.subject === "fix(): add x" && /scope `\(\)`/.test(f.error))'
check "commits names a scope with a space" 1 'o.offenders.some(f => f.subject === "fix(my api): add x" && /scope `\(my api\)`/.test(f.error))'
check "commits names a missing space after the colon" 1 'o.offenders.some(f => f.subject === "docs:add x" && /missing space/.test(f.error))'
check "commits names a missing description" 1 'o.offenders.some(f => f.subject === "chore: " && /missing description/.test(f.error))'
check "commits names extra space before the description" 1 'o.offenders.some(f => f.subject === "chore:  add x" && /one space/.test(f.error))'
out="$(printf '%s\n' 'ci: pin actions' 'build: bump node' 'perf: cache the read' 'style: wrap lines' 'revert: undo the cache' | node "$CLI" commits)"; code=$?
check "commits accepts the other Conventional Commits types" 0 'o.ok && o.count === 5'
run_stdin "$FIX/commits-crlf.txt" commits
check "commits tolerates CRLF line endings" 0 'o.ok && o.count === 2'
run_stdin /dev/null commits
check "commits with no subjects is a pass" 0 'o.ok && o.count === 0'

# --- key: free-text search ------------------------------------------------------
run key --text "fix: handle a null config (#42)"
check "key extracts an issue number from a PR title" 0 "o.ok && $ISSUE42"
run key --text "feat: LT-02 add the tuner"
check "key extracts a story code from free text" 0 "o.ok && $STORY"
run key --text "LT-02 then #42"
check "key prefers an issue number over an earlier story code" 0 "o.ok && $ISSUE42"
run key --text "Closes #42, refs #7"
check "key returns the first issue of several" 0 "o.ok && $ISSUE42"
run key --text "no key here"
check "key reports a missing key" 1 "!o.ok && $NOKEY && /no ticket key/.test(o.error)"
run key --text "see page#42 and AB-12x"
check "key needs a boundary around #N and a story code" 1 '!o.ok'
run key --text "fix lt-02 thing"
check "key search ignores a lowercase story code" 1 '!o.ok'
run key --text "bump 42 deps"
check "key search ignores a bare number" 1 '!o.ok'
run key --text "issue #0"
check "key search ignores #0" 1 '!o.ok'
run key --text "store SHA-256 digests as UTF-8 with ISO-8601 dates per RFC-3339"
check "key search ignores standard terms" 1 "!o.ok && $NOKEY"
run key --text "UTF-8 output for LT-02"
check "key search skips a standard term to the story code after it" 0 "o.ok && $STORY"

# --- key: --anchored ----------------------------------------------------------
run key --anchored --text "#42"
check "key --anchored accepts #N" 0 "o.ok && $ISSUE42"
run key --anchored --text "42"
check "key --anchored accepts a bare issue number" 0 "o.ok && $ISSUE42"
run key --anchored --text "LT-02"
check "key --anchored accepts a story code" 0 "o.ok && $STORY"
run key --anchored --text "  #42 "
check "key --anchored trims surrounding whitespace" 0 "o.ok && $ISSUE42"
run key --anchored --text "lt-02"
check "key --anchored normalizes a lowercase story code" 0 "o.ok && $STORY"
run key --anchored --text "Lt-02"
check "key --anchored normalizes a mixed-case story code" 0 "o.ok && $STORY"
run key --anchored --text "take #42"
check "key --anchored rejects surrounding text" 1 "!o.ok && $NOKEY && /is not a ticket key/.test(o.error)"
run key --anchored --text "#042"
check "key --anchored rejects a leading zero" 1 '!o.ok'
run key --anchored --text "#LT-02"
check "key --anchored rejects a # before a story code" 1 '!o.ok'
run key --anchored --text "LONGER-2"
check "key --anchored rejects a story code longer than five letters" 1 '!o.ok'
run key --anchored --text "hello"
check "key --anchored rejects a non-key" 1 "!o.ok && $NOKEY && /is not a ticket key/.test(o.error)"
# Case folding is ASCII-only: these uppercase to LIT-/ST- but are not ASCII keys
run key --anchored --text "lıt-2"
check "key --anchored rejects a dotless-i lookalike" 1 '!o.ok'
run key --anchored --text "ſt-2"
check "key --anchored rejects a long-s lookalike" 1 '!o.ok'

# --- parity: accept/reject matches the contract's patterns, written independently in Python -------------
if command -v python3 >/dev/null 2>&1; then
  parity() {  # parity <name> <python-pattern> <match|search> <script-args-prefix...> -- <inputs...>
    local name="$1" pat="$2" mode="$3"; shift 3
    local pre=() inp mismatch=0
    while [ "$1" != "--" ]; do pre+=("$1"); shift; done; shift
    for inp in "$@"; do
      local want got
      want=$(python3 -c 'import re,sys; print(1 if getattr(re, sys.argv[2])(sys.argv[1], sys.argv[3]) else 0)' "$pat" "$mode" "$inp")
      node "$CLI" "${pre[@]}" "$inp" >/dev/null 2>&1 && got=1 || got=0
      [ "$want" = "$got" ] || { mismatch=1; echo "  parity mismatch: '$inp' want=$want got=$got"; }
    done
    if [ "$mismatch" -eq 0 ]; then pass "$name"; else fail "$name"; fi
  }
  parity "branch parity with the contract pattern" \
    '^(feat|fix|chore|docs|refactor|test)/([1-9][0-9]*|[A-Z]{2,5}-[0-9]+)(-[a-z0-9-]+)?$' match branch --name -- \
    "feat/1-a" "fix/22" "chore/1-" "docs/1--x" "test/1-a_b" "refactor/LT-0-9z" "feat/LT-02" "feat/L-1" \
    "feat/1x" "feat/LT-" "feat/-1" "Feat/1" "feat/1/sub" "main" "feat/1-ab-cd-ef" "feat/0-x" "feat/ABCDEF-1"
  parity "anchored key parity, ASCII case-insensitive story codes" '(?a)^(#?[1-9][0-9]*|(?i:[A-Z]{2,5}-[0-9]+))$' match key --anchored --text -- \
    "#1" "1" "#01" "#" "LT-02" "LT-1" "L-1" "LT1" "LT-1a" "lt-1" "LT-" "-1" "Lt-1" "lıt-1" "ſt-1" "#LT-1"
  parity "free key parity" '(?<![\w#&])#[1-9][0-9]*\b|\b(?!(AES|CRC|CVE|CWE|ECMA|HTTP|IEC|ISO|PEP|RFC|RSA|SHA|TLS|UCS|UTF)-)[A-Z]{2,5}-[0-9]+\b' search key --text -- \
    "fix: LT-1 x" "xLT-1" "LT-1x" "(LT-1)" "LT-1_" "a LT-22." "none" "(#4)" "a#4" "#4x" "&#4;" "##4" "#0" \
    "UTF-8" "SHA-256 LT-3" "ISO-8601" "XISO-1" "CVE-2024-1234"
  slug_mismatch=0
  for title in "Add Title Search!" "  ---  " "Café façade" "İstanbul ǅemal" "Fix: null ptr in Parser.cs" "a_b__c" "$(printf 'ab-%.0s' $(seq 1 30))"; do
    want=$(python3 -c '
import re,sys
s=re.sub(r"-+","-",re.sub(r"[^a-z0-9]+","-",sys.argv[1].lower())).strip("-")[:60].strip("-")
print(s or "untitled")' "$title")
    got=$(printf '%s' "$title" | node "$CLI" new --type feat --key '#1' | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).slug)')
    [ "$want" = "$got" ] || { slug_mismatch=1; echo "  parity mismatch: '$title' want=$want got=$got"; }
  done
  if [ "$slug_mismatch" -eq 0 ]; then pass "slug parity with the documented slug pipeline"; else fail "slug parity with the documented slug pipeline"; fi
else
  fail "python3 not on PATH — parity checks cannot run"
fi

# --- stdin input: callers pass untrusted text through a quoted heredoc, never a shell argument ---
run key --anchored <<'TXT'
#42
TXT
check "key reads the text from stdin" 0 "o.ok && $ISSUE42"
run key --anchored <<'TXT'
lt-02
TXT
check "key normalizes a lowercase stdin story code (the deliver argument)" 0 "o.ok && $STORY"
run key --anchored <<'TXT'
#42' ; touch /tmp/pwned-git-conventions ; echo '
TXT
check "key treats a quote-bearing stdin value as data" 1 '!o.ok && o.error.includes("touch /tmp/pwned-git-conventions")'
if [ ! -e /tmp/pwned-git-conventions ]; then pass "a quote-bearing value runs nothing"; else fail "a quote-bearing value ran a command"; fi
run branch <<'TXT'
feat/12-it's
TXT
check "branch reads the name from stdin and rejects a quote" 1 '!o.ok && o.on_feature && o.ticket_key === "#12"'
out="$(printf 'feat/LT-02-x' | node "$CLI" branch)"; code=$?
check "branch stdin without a trailing newline" 0 'o.ok && o.slug === "x"'

# --- new: branch name from a ticket title (title on stdin) ---------------------
out="$(printf 'Add Title Search!' | node "$CLI" new --type feat --key '#42')"; code=$?
check "new builds <type>/<N>-<slug> from #N" 0 "o.ok && o.branch === 'feat/42-add-title-search' && o.slug === 'add-title-search' && o.type === 'feat' && o.spike === false && $ISSUE42"
out="$(printf 'Add Title Search!' | node "$CLI" new --type feat --key 42)"; code=$?
check "new accepts a bare issue number" 0 "o.ok && o.branch === 'feat/42-add-title-search' && $ISSUE42"
out="$(printf 'Live tuner' | node "$CLI" new --type feat --key LT-02)"; code=$?
check "new builds <type>/<CODE>-<slug> from a story code" 0 "o.ok && o.branch === 'feat/LT-02-live-tuner' && $STORY"
out="$(printf '  ---  ' | node "$CLI" new --type fix --key '#1')"; code=$?
check "new falls back to untitled when the title has no slug characters" 0 'o.ok && o.branch === "fix/1-untitled"'
out="$(printf 'add a settings page with keyboard shortcuts and a dark theme toggle for admins' | node "$CLI" new --type feat --key '#7')"; code=$?
check "new caps the slug at 60 characters" 0 'o.ok && o.slug === "add-a-settings-page-with-keyboard-shortcuts-and-a-dark-theme" && o.slug.length === 60'
out="$(printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbb' | node "$CLI" new --type feat --key '#1')"; code=$?
check "new drops a dash left at the 60-character cut" 0 'o.ok && o.slug === "a".repeat(59)'
out="$(printf 'Café façade' | node "$CLI" new --type docs --key '#1')"; code=$?
check "new turns non-ASCII runs into dashes" 0 'o.ok && o.slug === "caf-fa-ade"'
run new --type chore --key '#1' <<'TXT'
$(touch /tmp/pwned-git-conventions-new) `id` "x" 'y'
TXT
check "new treats a shell-shaped title as data" 0 'o.ok && /^[a-z0-9][a-z0-9-]{0,59}$/.test(o.slug) && o.slug === "touch-tmp-pwned-git-conventions-new-id-x-y"'
if [ ! -e /tmp/pwned-git-conventions-new ]; then pass "a shell-shaped title runs nothing"; else fail "a shell-shaped title ran a command"; fi
out="$(printf 'Investigate X' | node "$CLI" new --type spike --key '#9')"; code=$?
check "new maps a spike to a chore/ branch and flags it" 0 'o.ok && o.branch === "chore/9-investigate-x" && o.type === "chore" && o.spike === true'
out="$(printf 'x' | node "$CLI" new --type feature --key '#1')"; code=$?
check "new rejects an unknown type" 1 "!o.ok && /type \`feature\`/.test(o.error) && $NOKEY"
out="$(printf 'x' | node "$CLI" new --type feat --key lt-02)"; code=$?
check "new rejects a lowercase story code (callers normalize with key --anchored)" 1 "!o.ok && /ticket key/.test(o.error) && $NOKEY"
out="$(printf 'x' | node "$CLI" new --type feat --key '#0')"; code=$?
check "new rejects issue #0" 1 '!o.ok && /ticket key/.test(o.error)'
rt_mismatch=0
for key in '#7' 'AB-7'; do
  for title in "Add Title Search!" "x" "!!!" "Fix: null ptr in Parser.cs" "$(printf 'a%.0s' $(seq 1 80))"; do
    b="$(printf '%s' "$title" | node "$CLI" new --type refactor --key "$key" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).branch)')"
    node "$CLI" branch --name "$b" >/dev/null 2>&1 || { rt_mismatch=1; echo "  round-trip failed: '$key' '$title' → '$b'"; }
  done
done
if [ "$rt_mismatch" -eq 0 ]; then pass "every new branch name passes branch"; else fail "every new branch name passes branch"; fi
out="$(node "$CLI" new --type feat < /dev/null 2>/dev/null)"; code=$?
check "new without --key is a usage error" 2 '/--key/.test(o.error)'

# --- retype: rename a branch to another work type, keeping key and slug ---------
run retype --name "chore/9-investigate-x" --type feat
check "retype swaps the type prefix on an issue branch" 0 'o.ok && o.from === "chore/9-investigate-x" && o.to === "feat/9-investigate-x" && o.type === "feat"'
run retype --name "chore/LT-02" --type fix
check "retype keeps a key-only story branch" 0 'o.ok && o.to === "fix/LT-02"'
run retype --name "chore/9-x" --type spike
check "retype rejects spike as a target type" 1 '!o.ok && /type `spike`/.test(o.error)'
run retype --name "main" --type feat
check "retype rejects a branch that is not <type>/<key>" 1 '!o.ok && /base branch/.test(o.error)'
run retype --name "chore/9-x" --type chore
check "retype rejects a no-op rename" 1 '!o.ok && /already/.test(o.error)'
out="$(node "$CLI" retype --type feat < /dev/null 2>/dev/null)"; code=$?
check "retype without a name is a usage error" 2 '/--name/.test(o.error)'

# --- sanitize: one-line commit description from untrusted text (stdin) ---------
run sanitize <<'TXT'
Use `rm` $HOME "quoted" back\slash
second line
TXT
check "sanitize replaces shell meta and newlines with single spaces" 0 'o.ok && o.description === "Use rm HOME quoted back slash second line"'
out="$(printf 'a\r\nb\t\tc' | node "$CLI" sanitize)"; code=$?
check "sanitize collapses CRLF and tabs" 0 'o.description === "a b c"'
out="$(printf '%s' "$(printf 'word %.0s' $(seq 1 20))" | node "$CLI" sanitize)"; code=$?
check "sanitize caps at 60 and trims the cut" 0 'o.description.length <= 60 && !/\s$/.test(o.description) && o.description.startsWith("word word")'
out="$(printf '%s' "$(printf 'x%.0s' $(seq 1 30))" | node "$CLI" sanitize --max 10)"; code=$?
check "sanitize honours --max" 0 'o.description === "xxxxxxxxxx"'
out="$(printf ' `$` ' | node "$CLI" sanitize)"; code=$?
check "sanitize falls back to investigation when nothing is left" 0 'o.ok && o.description === "investigation"'
out="$(node "$CLI" sanitize --fallback research < /dev/null)"; code=$?
check "sanitize honours --fallback on empty input" 0 'o.ok && o.description === "research"'
out="$(printf 'Résumé — naïve' | node "$CLI" sanitize)"; code=$?
check "sanitize keeps printable unicode" 0 'o.description === "Résumé — naïve"'
out="$(printf 'xxxxxxxxx\360\237\230\200yz' | node "$CLI" sanitize --max 10)"; code=$?
check "sanitize caps by code point, never splitting an emoji" 0 'o.description === "xxxxxxxxx\u{1F600}" && !/[\uD800-\uDFFF]/u.test(o.description)'
d="$(printf 'Investigate `X` "now"\n' | node "$CLI" sanitize)"
d="$(field "$d" description)"
if printf 'chore: %s\n' "$d" | node "$CLI" commits >/dev/null 2>&1; then pass "a sanitized description makes a valid commit subject"; else fail "a sanitized description makes a valid commit subject — '$d'"; fi
out="$(printf 'x' | node "$CLI" sanitize --max 0 2>/dev/null)"; code=$?
check "sanitize rejects a non-positive --max" 2 '/--max/.test(o.error)'

# --- usage errors -------------------------------------------------------------
run bogus
check "an unknown subcommand is a usage error" 2 '/usage/.test(o.error)'
out="$(node "$CLI" branch < /dev/null 2>/dev/null)"; code=$?
check "branch with no --name and empty stdin is a usage error" 2 '/--name/.test(o.error)'
out="$(node "$CLI" key < /dev/null 2>/dev/null)"; code=$?
check "key with no --text and empty stdin is a usage error" 2 '/--text/.test(o.error)'

# --- base: the branch a PR from this work targets ----------------------------------
# gh is the shared stub; git runs hermetically (no user or system config) in throwaway repos.
if [ -n "${SDLC_TEST_TMP:-}" ]; then
  W="$(mktemp -d "$SDLC_TEST_TMP/git-conventions.XXXX")"
else
  W="$(mktemp -d)"
  trap 'rm -rf "$W"' EXIT
fi
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$W/gitconfig"
mkdir -p "$HOME"
git config --global user.name tester
git config --global user.email tester@example.com
git config --global commit.gpgsign false

# repo <dir> <branch> — a one-commit repo on <branch>
repo() { git init -q -b "$2" "$1" && git -C "$1" commit -q --allow-empty -m init; }
# gh_routes <exit> <body | -> — a fresh stub dir answering `gh pr view 7 --json baseRefName`
GN=0
gh_routes() {
  GN=$((GN + 1)); GHD="$W/gh$GN"; mkdir -p "$GHD"
  if [ "$2" = - ]; then printf 'GraphQL: Could not resolve to a PullRequest with the number of 7.\n' > "$GHD/r.stderr"; resp=r.stderr
  else printf '%s\n' "$2" > "$GHD/r.json"; resp=r.json; fi
  printf '%s\t%s\t%s\n' '^pr view 7 --json baseRefName$' "$1" "$resp" > "$GHD/routes"
}
# base_in <dir> [args...] — sets $out and $code for `base` run inside <dir>
base_in() {
  local dir="$1"; shift
  out="$(cd "$dir" && SDLC_GH="${GH_OVERRIDE:-$HERE/stub-gh.sh}" STUB_GH_DIR="${GHD:-$W}" SDLC_GH_TIMEOUT_MS="${TIMEOUT_MS:-5000}" \
    node "$CLI" base "$@" 2>/dev/null)"
  code=$?
}

R="$W/plain"; repo "$R" feat/42-add-login
base_in "$R"
check "base defaults to main with no PR, config or origin/HEAD" 0 'o.base === "main" && o.source === "default" && Object.keys(o).join() === "base,source"'
mkdir -p "$W/not-a-repo"; base_in "$W/not-a-repo"
check "base outside a git repo is the default" 0 'o.base === "main" && o.source === "default"'

R="$W/origin-head"; repo "$R" feat/42-add-login
git -C "$R" update-ref refs/remotes/origin/trunk HEAD
git -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
base_in "$R"
check "base reads origin/HEAD minus origin/" 0 'o.base === "trunk" && o.source === "origin-head"'

git -C "$R" config branch.feat/42-add-login.sdlc-base release/2.0
base_in "$R"
check "base prefers the branch's sdlc-base config over origin/HEAD" 0 'o.base === "release/2.0" && o.source === "config"'
git -C "$R" config branch.fix/LT-02-x.sdlc-base develop
base_in "$R" --branch fix/LT-02-x
check "base --branch reads that branch's config" 0 'o.base === "develop" && o.source === "config"'
base_in "$R" --branch docs/7-other
check "base --branch with no config falls through to origin/HEAD" 0 'o.base === "trunk" && o.source === "origin-head"'
git -C "$R" update-ref --no-deref HEAD "$(git -C "$R" rev-parse HEAD)"
base_in "$R"
check "base on a detached HEAD skips the branch config" 0 'o.base === "trunk" && o.source === "origin-head"'

gh_routes 0 '{"baseRefName":"release/3.1"}'
base_in "$R" --pr 7 --branch fix/LT-02-x
check "base --pr takes the PR's baseRefName over any config" 0 'o.base === "release/3.1" && o.source === "pr"'
if [ "$(cat "$GHD/calls")" = 'pr view 7 --json baseRefName' ]; then pass "base --pr makes one gh pr view call"; else fail "base --pr calls were: $(cat "$GHD/calls")"; fi
gh_routes 1 -
base_in "$R" --pr 7
check "base --pr with a failing gh is an error carrying gh's reason" 2 '/^gh pr view 7 failed: GraphQL: Could not resolve/.test(o.error)'
gh_routes 0 'not json'
base_in "$R" --pr 7
check "base --pr with non-JSON is an error" 2 'o.error === "gh pr view 7 returned non-JSON"'
gh_routes 0 '{"number":7}'
base_in "$R" --pr 7
check "base --pr with no baseRefName is an error" 2 '/no baseRefName/.test(o.error)'
gh_routes 0 '{"baseRefName":"main..evil"}'
base_in "$R" --pr 7
check "base --pr rejects an unsafe ref name" 2 '/unsafe base ref "main\.\.evil" from pr/.test(o.error)'
GH_OVERRIDE="$FIX/../pr-checks/sleep-gh.sh" TIMEOUT_MS=300 base_in "$R" --pr 7
check "base --pr kills a hung gh and reports it" 2 'o.error === "gh pr view 7 timed out"'

R="$W/bad-config"; repo "$R" feat/9-x
git -C "$R" config branch.feat/9-x.sdlc-base '../main'
base_in "$R"
check "base rejects an unsafe configured ref" 2 '/unsafe base ref "\.\.\/main" from config/.test(o.error)'
base_in "$R" --pr x
check "base --pr must be a positive integer" 2 '/--pr must be a positive integer/.test(o.error)'
base_in "$R" --branch '../main'
check "base --branch must be a plain branch name" 2 '/is not a plain branch name/.test(o.error)'
base_in "$R" --branch -x
check "base --branch may not start with a dash" 2 '/"-x" is not a plain branch name/.test(o.error)'
base_in "$R" --branch feat/1-x.lock
check "base --branch may not end in .lock" 2 '/"feat\/1-x\.lock" is not a plain branch name/.test(o.error)'
base_in "$R" --branch 'feat/x;id'
check "base --branch allows only letters, digits and . _ / -" 2 '/"feat\/x;id" is not a plain branch name/.test(o.error)'
base_in "$R" --branch 'a//b'
check "base --branch may not hold //" 2 '/"a\/\/b" is not a plain branch name/.test(o.error)'
base_in "$R" --branch 'feat/.x'
check "base --branch may not start a component with ." 2 '/"feat\/\.x" is not a plain branch name/.test(o.error)'
base_in "$R" --branch 'feat/x.'
check "base --branch may not end in ." 2 '/"feat\/x\." is not a plain branch name/.test(o.error)'
base_in "$R" --branch 'feat/x/'
check "base --branch may not end in /" 2 '/"feat\/x\/" is not a plain branch name/.test(o.error)'
A255="$(printf '%255s' '' | tr ' ' a)"
base_in "$W/origin-head" --branch "$A255"
check "base --branch takes a 255-char name" 0 'o.base === "trunk" && o.source === "origin-head"'
base_in "$R" --branch "${A255}a"
check "base --branch refuses a 256-char name" 2 '/^base --branch "a{256}" is not a plain branch name$/.test(o.error)'
gh_routes 0 '{"baseRefName":"main$(id)"}'
base_in "$R" --pr 7
check "base --pr rejects a ref name with shell characters" 2 'o.error === "unsafe base ref \"main$(id)\" from pr"'
base_in "$R" --pr
check "base flag with no value is a usage error" 2 '/need a value/.test(o.error)'

echo
echo "$total checks, $fails failed"
[ "$fails" -eq 0 ] || exit 1
