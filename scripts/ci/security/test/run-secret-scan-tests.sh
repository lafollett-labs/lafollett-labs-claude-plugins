#!/usr/bin/env bash
# Tests for scripts/ci/security/secret-scan.sh and the repo's .gitleaks.toml.
#   range      SCAN_BASE..SCAN_HEAD is scanned; no usable base scans the whole tree
#   gate       a secret in range fails; the script never passes without scanning
#   allow-list an entry clears one exact value at one exact path; any other config shape is refused
#   tree       the current tree passes with the repo's config
# Range contracts use a stub gitleaks; the rest need the real gitleaks on PATH. Fake secrets are
# assembled at runtime so none is ever committed. Exit 0 = all pass.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
SCAN="$ROOT/scripts/ci/security/secret-scan.sh"
CONFIG="$ROOT/.gitleaks.toml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
total=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); echo "FAIL: $1 — $2"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$3], got [$2]"; fi; }

ZERO=0000000000000000000000000000000000000000
# A GitHub-PAT-shaped value gitleaks' default rules flag; built here, never stored.
fake_secret() { printf 'ghp_%s' "$(printf 'x7Kq2Lm9Pz4Rt8Vw1Ny3x7Kq2Lm9Pz4Rt8Vw' | tr 'x' 'A')"; }

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global init.defaultBranch main

new_repo() {
  git init -q "$1"
  git -C "$1" config user.name test
  git -C "$1" config user.email test@example.com
  git -C "$1" config commit.gpgsign false
}
commit_file() { mkdir -p "$(dirname "$1/$2")" && printf '%s\n' "$3" > "$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -qm "$2"; }

# scan_in <repo> [VAR=value ...]: run the scan in <repo> with only the given inputs.
scan_in() {
  local repo="$1"; shift
  (cd "$repo" && env -u SCAN_BASE -u SCAN_HEAD GITLEAKS_CONFIG="$CONFIG" "$@" bash "$SCAN") >"$WORK/out" 2>&1
  echo $?
}

# --- range contracts (stub gitleaks records its arguments) ---------------------------------------
STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/gitleaks" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" > "$STUB_LOG"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$STUB/gitleaks"
R="$WORK/range"
new_repo "$R"
commit_file "$R" a.txt one
BASE="$(git -C "$R" rev-parse HEAD)"
commit_file "$R" b.txt two
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"
stubbed() { scan_in "$R" STUB_LOG="$WORK/args" PATH="$STUB:$PATH" "$@"; }

code="$(stubbed SCAN_BASE="$BASE" SCAN_HEAD="$HEAD_SHA")"
check "range: exits with gitleaks' status" "$code" 0
check "range: scans base..head" "$(grep -c -- "--log-opts=-m $BASE..$HEAD_SHA" "$WORK/args")" 1

code="$(stubbed SCAN_BASE="$ZERO" SCAN_HEAD="$HEAD_SHA")"
check "range: an all-zero base scans the whole tree" "$(grep -c '^dir ' "$WORK/args")" 1

code="$(stubbed SCAN_HEAD="$HEAD_SHA")"
check "range: no base scans the whole tree" "$(grep -c '^dir ' "$WORK/args")" 1

code="$(stubbed SCAN_BASE=1234567890123456789012345678901234567890 SCAN_HEAD="$HEAD_SHA")"
check "range: a base absent from the clone scans the whole tree" "$(grep -c '^dir ' "$WORK/args")" 1

rm -f "$WORK/args"
code="$(stubbed SCAN_BASE="$BASE")"
check "refuses to pass without a head" "$code:$(test -f "$WORK/args" && echo ran || echo not-run)" "2:not-run"
rm -f "$WORK/args"
code="$(stubbed SCAN_BASE='HEAD~1' SCAN_HEAD="$HEAD_SHA")"
check "refuses a ref that is not a SHA" "$code:$(test -f "$WORK/args" && echo ran || echo not-run)" "2:not-run"
rm -f "$WORK/args"
code="$(stubbed SCAN_BASE="$BASE" SCAN_HEAD="$HEAD_SHA --no-git")"
check "refuses an injected flag" "$code:$(test -f "$WORK/args" && echo ran || echo not-run)" "2:not-run"

code="$(stubbed SCAN_BASE="$BASE" SCAN_HEAD="$HEAD_SHA" STUB_EXIT=1)"
check "a finding from gitleaks fails the scan" "$code" 1
check "uses the repo's config and redacts" "$(grep -c -- "--config $CONFIG .*--redact" "$WORK/args")" 1

# --- real gitleaks -------------------------------------------------------------------------------
if ! command -v gitleaks >/dev/null 2>&1; then
  fail "gitleaks available" "gitleaks is not on PATH; the remaining tests need it"
else
  S="$WORK/secret"
  new_repo "$S"
  commit_file "$S" README.md clean
  OLD="$(git -C "$S" rev-parse HEAD)"
  commit_file "$S" config.env "TOKEN=$(fake_secret)"
  NEW="$(git -C "$S" rev-parse HEAD)"
  code="$(scan_in "$S" SCAN_BASE="$OLD" SCAN_HEAD="$NEW")"
  check "a secret in range fails the scan" "$code:$(grep -c 'leaks found: 1' "$WORK/out")" "1:1"
  check "the finding is redacted in the log" "$(grep -c "$(fake_secret)" "$WORK/out")" 0

  commit_file "$S" notes.md "clean change"
  LATEST="$(git -C "$S" rev-parse HEAD)"
  code="$(scan_in "$S" SCAN_BASE="$NEW" SCAN_HEAD="$LATEST")"
  check "a secret committed before the range does not fail a clean range" "$code" 0

  A="$WORK/allow"
  new_repo "$A"
  commit_file "$A" README.md clean
  A_BASE="$(git -C "$A" rev-parse HEAD)"
  commit_file "$A" fixtures/token.txt "TOKEN=$(fake_secret)"
  cat > "$WORK/allow.toml" <<EOF
[extend]
useDefault = true

[[allowlists]]
description = "test: fake token in a fixture"
condition = "AND"
paths = ['''^fixtures/token\.txt$''']
regexTarget = "line"
regexes = ['''^TOKEN=$(fake_secret)$''']
EOF
  code="$(scan_in "$A" GITLEAKS_CONFIG="$WORK/allow.toml" SCAN_BASE="$A_BASE" SCAN_HEAD="$(git -C "$A" rev-parse HEAD)")"
  check "an allow-listed value at its listed path passes" "$code" 0
  A_MID="$(git -C "$A" rev-parse HEAD)"
  commit_file "$A" other.txt "TOKEN=$(fake_secret)"
  code="$(scan_in "$A" GITLEAKS_CONFIG="$WORK/allow.toml" SCAN_BASE="$A_MID" SCAN_HEAD="$(git -C "$A" rev-parse HEAD)")"
  check "the same value at another path still fails" "$code" 1

  I="$WORK/inline"
  new_repo "$I"
  commit_file "$I" README.md clean
  I_BASE="$(git -C "$I" rev-parse HEAD)"
  commit_file "$I" config.env "TOKEN=$(fake_secret) # gitleaks:allow"
  code="$(scan_in "$I" SCAN_BASE="$I_BASE" SCAN_HEAD="$(git -C "$I" rev-parse HEAD)")"
  check "an inline gitleaks:allow comment does not hide a secret" "$code" 1

  G="$WORK/ignorefile"
  new_repo "$G"
  commit_file "$G" README.md clean
  G_BASE="$(git -C "$G" rev-parse HEAD)"
  commit_file "$G" .gitleaksignore "anything"
  code="$(scan_in "$G" SCAN_BASE="$G_BASE" SCAN_HEAD="$(git -C "$G" rev-parse HEAD)")"
  check "a .gitleaksignore file fails the scan" "$code:$(grep -c 'gitleaksignore' "$WORK/out")" "2:1"

  M="$WORK/merge"
  new_repo "$M"
  commit_file "$M" README.md clean
  M_BASE="$(git -C "$M" rev-parse HEAD)"
  git -C "$M" checkout -q -b side
  commit_file "$M" side.txt side
  git -C "$M" checkout -q -
  commit_file "$M" main.txt main
  git -C "$M" merge -q --no-commit side >/dev/null 2>&1
  printf 'TOKEN=%s\n' "$(fake_secret)" > "$M/merged.env" && git -C "$M" add merged.env
  git -C "$M" commit -qm merge
  git -C "$M" rm -q merged.env && git -C "$M" commit -qm "remove it"
  code="$(scan_in "$M" SCAN_BASE="$M_BASE" SCAN_HEAD="$(git -C "$M" rev-parse HEAD)")"
  check "a secret introduced in a merge commit fails the scan" "$code" 1

  code="$(scan_in "$ROOT" SCAN_BASE="$ZERO" SCAN_HEAD="$(git -C "$ROOT" rev-parse HEAD)")"
  check "the current tree passes with the repo's config" "$code" 0
fi

# --- allow-list shape ----------------------------------------------------------------------------
# check-allowlist.py reads the parsed TOML, so each refused shape is also tried in other TOML spellings.
T3="'''"
good_entry="[[allowlists]]
description = \"fake token in a fixture\"
condition = \"AND\"
paths = [${T3}^fixtures/token\\.txt\$${T3}]
regexTarget = \"line\"
regexes = [${T3}^TOKEN=ghp_FAKE0000\$${T3}]"
config_case() { # config_case <label> <want> <whole config>
  printf '%s\n' "$3" > "$WORK/shape.toml"
  rm -f "$WORK/args"
  code="$(stubbed GITLEAKS_CONFIG="$WORK/shape.toml" SCAN_BASE="$BASE" SCAN_HEAD="$HEAD_SHA")"
  check "allow-list shape: $1" "$code:$(test -f "$WORK/args" && echo ran || echo not-run)" "$2"
}
shape_case() { config_case "$1" "$2" "$(printf '[extend]\nuseDefault = true\n\n%s' "$3")"; } # [extend] + <body>
with() { printf '%s\n' "$good_entry" | sed "$1"; }                                         # good_entry, edited
regex() { with "s|^regexes = .*|regexes = [${T3}$1${T3}]|"; }
path() { with "s|^paths = .*|paths = [${T3}$1${T3}]|"; }

shape_case "a reasoned exact-value, exact-file entry is accepted" "0:ran" "$good_entry"
shape_case "two such entries are accepted" "0:ran" "$(printf '%s\n\n%s' "$good_entry" "$(path '^b\\.txt$')")"
shape_case "regexTarget secret is accepted" "0:ran" "$(with 's/^regexTarget = .*/regexTarget = "secret"/')"
shape_case "an escaped dot in the value is accepted" "0:ran" "$(regex '^TOKEN\\.ghp_FAKE$')"
shape_case "an entry without a description is refused" "2:not-run" "$(with '/^description/d')"
shape_case "an empty description is refused" "2:not-run" "$(with 's/^description = .*/description = " "/')"
shape_case "an entry without condition AND is refused" "2:not-run" "$(with '/^condition/d')"
shape_case "condition OR is refused" "2:not-run" "$(with 's/"AND"/"OR"/')"
shape_case "an entry without an exact value is refused" "2:not-run" "$(with '/^regexes/d')"
shape_case "an entry without a path is refused" "2:not-run" "$(with '/^paths/d')"
shape_case "an unanchored path is refused" "2:not-run" "$(path 'fixtures/token\\.txt$')"
shape_case "a path without \$ is refused" "2:not-run" "$(path '^fixtures/token\\.txt')"
shape_case "a directory regex path is refused" "2:not-run" "$(path '^fixtures/.*$')"
shape_case "a bare dot in a path is refused" "2:not-run" "$(path '^fixtures/token.txt$')"
shape_case "a wildcard-class path is refused" "2:not-run" "$(path '^\\S\\S\\S\\S\\S\\S\\S\\S$')"
shape_case "two paths in one entry are refused" "2:not-run" "$(path "^a\\\\.txt\$${T3}, ${T3}^b\\\\.txt\$")"
shape_case "a multi-line paths array with two paths is refused" "2:not-run" \
  "$(with "s|^paths = .*|paths = [\\
  ${T3}^a\\\\.txt\$${T3},\\
  ${T3}^b\\\\.txt\$${T3},\\
]|")"
shape_case "a match-anything regex is refused" "2:not-run" "$(regex '.*')"
shape_case "an anchored match-anything regex is refused" "2:not-run" "$(regex '^.+$')"
shape_case "a \\S* regex is refused" "2:not-run" "$(regex '^\\S*$')"
shape_case "a [\\s\\S]* regex is refused" "2:not-run" "$(regex '^[\\s\\S]*$')"
shape_case "a (?:.)* regex is refused" "2:not-run" "$(regex '^(?:.)*$')"
shape_case "an unanchored regex is refused" "2:not-run" "$(regex 'TOKEN=ghp_FAKE0000$')"
shape_case "a regex without \$ (a prefix) is refused" "2:not-run" "$(regex '^TOKEN=ghp_FAKE0000')"
shape_case "an escaped final \$ is not an anchor" "2:not-run" "$(regex '^TOKEN=ghp_FAKE0000\\$')"
# shellcheck disable=SC1003 # a literal trailing backslash is the input under test
shape_case "a trailing lone backslash is refused" "2:not-run" "$(regex '^TOKEN=ghp_FAKE0000\\')"
shape_case "a short literal value is refused" "2:not-run" "$(regex '^ghp_$')"
shape_case "two regexes in one entry are refused" "2:not-run" "$(regex "^TOKEN=ghp_FAKE0000\$${T3}, ${T3}^TOKEN=ghp_FAKE1111\$")"
shape_case "a stopword beside a valid regex is refused" "2:not-run" "$(printf '%s\nstopwords = ["ghp_"]' "$good_entry")"
shape_case "regexTarget match is refused" "2:not-run" "$(with 's/^regexTarget = .*/regexTarget = "match"/')"
shape_case "a per-entry targetRules key is refused" "2:not-run" "$(printf '%s\ntargetRules = ["github-pat"]' "$good_entry")"
shape_case "a legacy [allowlist] table is refused" "2:not-run" "$(printf '[allowlist]\npaths = [%sfixtures%s]' "$T3" "$T3")"
config_case "a top-level dotted allowlist key is refused" "2:not-run" \
  "$(printf 'allowlist.paths = [%s.*%s]\n\n[extend]\nuseDefault = true' "$T3" "$T3")"
shape_case "a differently cased [[AllowLists]] table is refused" "2:not-run" "$(with 's/^\[\[allowlists\]\]/[[AllowLists]]/')"
inline() { # inline <path>: a top-level inline allowlists array of one entry for <path>, then [extend]
  printf 'allowlists = [{ description = "x", condition = "AND", paths = [%s%s%s], regexes = [%s^TOKEN=ghp_FAKE0000$%s] }]\n\n[extend]\nuseDefault = true' \
    "$T3" "$1" "$T3" "$T3" "$T3"
}
config_case "an inline allowlists array that meets the rules is accepted" "0:ran" "$(inline '^a\.txt$')"
config_case "an inline allowlists array is checked like the table form" "2:not-run" "$(inline '.*')"
shape_case "a per-rule allow-list is refused" "2:not-run" \
  "$(printf '[[rules]]\nid = "x"\nregex = %sx%s\n[[rules.allowlists]]\npaths = [%sfixtures%s]' "$T3" "$T3" "$T3" "$T3")"
shape_case "a rule reusing a default id with a never-matching regex is refused" "2:not-run" \
  "$(printf '[[rules]]\nid = "github-pat"\nregex = %s^NEVERMATCHES$%s' "$T3" "$T3")"
shape_case "a rule reusing a default id with an unreachable entropy is refused" "2:not-run" \
  "$(printf '[[rules]]\nid = "github-pat"\nentropy = 99.0')"
config_case "a top-level disabledRules is refused" "2:not-run" "$(printf 'disabledRules = ["github-pat"]\n\n[extend]\nuseDefault = true')"
shape_case "an [extend] path to a second config is refused" "2:not-run" 'path = "inner.toml"'
shape_case "[extend] disabledRules is refused" "2:not-run" 'disabledRules = ["github-pat"]'
shape_case "a differently cased [Extend] table is refused" "2:not-run" "$(printf '[Extend]\npath = "inner.toml"')"
config_case "a config without [extend] is refused" "2:not-run" "$good_entry"
config_case "useDefault = false is refused" "2:not-run" "$(printf '[extend]\nuseDefault = false')"
config_case "an inline extend table with a path is refused" "2:not-run" 'extend = { path = "inner.toml" }'
config_case "an inline extend table with disabledRules is refused" "2:not-run" \
  'extend = { useDefault = true, disabledRules = ["github-pat"] }'
config_case "a spaced [ extend ] header with a path is refused" "2:not-run" "$(printf '[ extend ]\npath = "inner.toml"')"
config_case "a quoted [\"extend\"] header with a path is refused" "2:not-run" "$(printf '["extend"]\npath = "inner.toml"')"
config_case "a literal-quoted dotted extend key is refused" "2:not-run" "'extend'.path = \"inner.toml\""
config_case "a config that is not TOML is refused" "2:not-run" "$(printf '[extend\nuseDefault = true')"
config_case "a duplicate [extend] table is refused" "2:not-run" "$(printf '[extend]\nuseDefault = true\n[extend]\npath = "inner.toml"')"
config_case "the repo's own config is accepted" "0:ran" "$(cat "$ROOT/.gitleaks.toml")"

# --- workflow wiring -----------------------------------------------------------------------------
# A cancelled run on main would leave that push's commits unscanned: the next push scans only its own.
CI_YML="$ROOT/.github/workflows/ci.yml"
check "ci.yml cancels in-progress runs only for pull requests" \
  "$(grep -cF "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$CI_YML")" 1
# The required check (job `check`) gates the merge only if it waits on every other job, this scan included.
jobs="$(awk '/^jobs:/{j=1; next} j && /^  [A-Za-z0-9_-]+:[[:space:]]*$/{sub(/:.*/, ""); sub(/^  /, ""); print}' "$CI_YML" \
  | grep -vx check | sort | tr '\n' ' ')"
needs="$(awk '/^  check:/{c=1; next} c && /^  [^ ]/{c=0} c && /^    needs:/{print}' "$CI_YML" \
  | sed 's/.*\[//; s/\].*//' | tr ',' '\n' | tr -d ' ' | sort | tr '\n' ' ')"
check "ci.yml's required check needs every other job" "$needs" "$jobs"
# shellcheck disable=SC2016 # a literal GitHub expression, not a shell one
check "ci.yml's required check runs when a need fails" "$(grep -cF 'if: ${{ !cancelled() }}' "$CI_YML")" 1
# ...and only if its last step is the gate, fed every need. gate-needs.sh has its own suite.
check_job="$(awk '/^  check:/{c=1; next} c && /^  [^ ]/{c=0} c' "$CI_YML")"
check "ci.yml's required check ends with the gate step" \
  "$(printf '%s\n' "$check_job" | grep -E '^[[:space:]]+run:' | tail -n 1 | sed 's/^[[:space:]]*//')" "run: bash scripts/ci/gate-needs.sh"
# shellcheck disable=SC2016 # a literal GitHub expression, not a shell one
check "ci.yml's gate reads toJSON(needs)" "$(printf '%s\n' "$check_job" | grep -cF 'NEEDS: ${{ toJSON(needs) }}')" 1
check "ci.yml's gate expects as many jobs as it needs" \
  "$(printf '%s\n' "$check_job" | sed -n 's/^[[:space:]]*EXPECT: \([0-9]*\)$/\1/p')" "$(printf '%s' "$needs" | wc -w | tr -d ' ')"

echo "=============================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] || { echo "FAIL: no checks ran"; exit 1; }
[ "$fails" -eq 0 ] || exit 1
echo "ALL PASS"
