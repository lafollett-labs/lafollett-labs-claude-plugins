#!/usr/bin/env bash
# Tests for scripts/hooks/{pre-commit,commit-msg} in throwaway repos: real git, real gitleaks, and a
# stub denylist scanner keyed on two synthetic terms (one non-ASCII). Fake secrets are assembled at
# runtime so none is ever committed. Exit 0 = all pass.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOOKS="$ROOT/scripts/hooks"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

command -v gitleaks >/dev/null 2>&1 || { echo "FAIL: gitleaks not on PATH (scripts/ci/security/install-gitleaks.sh)"; exit 1; }

fails=0
total=0
pass() { total=$((total + 1)); echo "PASS: $1"; }
fail() { total=$((total + 1)); echo "FAIL: $1 — $2"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] expected [$3]"; fi; }

export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global init.defaultBranch main
git config --global user.name tester
git config --global user.email tester@example.com
git config --global commit.gpgsign false
git config --global core.hooksPath "$HOOKS"

TERM_HIT="zebra""corn"                  # the stub scanner's terms, built so this file never matches them
TERM_UTF8="$(printf 'z\303\274''ri')"   # a non-ASCII term (UTF-8 bytes)
fake_secret() { printf 'ghp_%s' "$(printf 'x7Kq2Lm9Pz4Rt8Vw1Ny3x7Kq2Lm9Pz4Rt8Vw' | tr 'x' 'A')"; }

mkdir -p "$W/bin" "$W/home/bin"
cat > "$W/home/bin/scan.sh" <<EOF
#!/usr/bin/env bash
set -o pipefail
[ \$# -gt 0 ] || { echo "stub scanner: no-argument mode" >&2; exit 1; }
grep -inE '$TERM_HIT|$TERM_UTF8' "\$@" | cut -d: -f1,2 && exit 1 || exit 0
EOF
printf '#!/bin/sh\nexit 1\n' > "$W/home/bin/mute.sh"   # a scanner that reports a hit but no location
chmod +x "$W/home/bin/scan.sh" "$W/home/bin/mute.sh"
# edit: a GIT_EDITOR that puts $EDIT_SUBJECT and $EDIT_BODY above git's template
# shellcheck disable=SC2016 # the editor script expands its own variables
printf '#!/bin/sh\n{ printf "%%s\\n\\n%%s\\n" "$EDIT_SUBJECT" "$EDIT_BODY"; cat "$1"; } > "$1.new" && mv "$1.new" "$1"\n' > "$W/edit"
chmod +x "$W/edit"

N=0
fresh() { # fresh: a repo with the repo's gitleaks config committed and the stub scanner configured
  N=$((N + 1)); R="$W/r$N"
  git init -q "$R"
  cp "$ROOT/.gitleaks.toml" "$R/"
  git -C "$R" config labs.denylistScan "$W/home/bin/scan.sh"
  git -C "$R" add .gitleaks.toml && git -C "$R" commit -qm "chore: init" >/dev/null 2>&1
}
# try <git commit args...>: commit in $R; prints the exit code, keeps stderr in $W/err
try() { (cd "$R" && git commit -q "$@") > /dev/null 2> "$W/err"; echo $?; }
said() { grep -c -- "$1" "$W/err" || true; }

echo "=== hook tests ==="

fresh
echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "a clean commit passes" "$(try -m "feat: a")" 0

fresh
echo one > "$R/a.txt"; git -C "$R" add a.txt; try --no-verify -m "chore: $TERM_HIT" >/dev/null
echo two > "$R/b.txt"; git -C "$R" add b.txt
check "a hit in HEAD's message does not block the next commit" "$(try -m "fix: b")" 0
check "an --amend that fixes HEAD's message passes" "$(try --amend -m "fix: clean")" 0

fresh
echo "x $TERM_HIT" > "$R/a.txt"; git -C "$R" add a.txt
check "a hit in an added line blocks" "$(try -m "feat: a")" 1
check "  and names the added line, with no locate command" \
  "$(said 'staged paths or added lines'):$(said '  added line:  a.txt:1$'):$(said 'locate:')" "1:1:0"

fresh
mkdir -p "$R/sub"; printf 'one\ntwo\n' > "$R/sub/a.txt"; git -C "$R" add -A; try -m "chore: seed" >/dev/null
printf 'one\nnew\nx %s\ntwo\n' "$TERM_HIT" > "$R/sub/a.txt"; git -C "$R" add -A
check "a hit in the second added line is named by its new line number" \
  "$(try -m "feat: a"):$(said '  added line:  sub/a.txt:3$')" "1:1"

fresh
echo "x $TERM_HIT" > "$R/q\"x y.txt"; echo "x $TERM_HIT" > "$R/back\\slash.txt"; git -C "$R" add -A
try -m "feat: a" >/dev/null
check "paths git quotes are named as written" \
  "$(grep -cxF '  added line:  q"x y.txt:1' "$W/err"):$(grep -cxF '  added line:  back\slash.txt:1' "$W/err")" "1:1"
echo ok > "$R/q\"$TERM_HIT.txt"; git -C "$R" add -A
check "  in staged paths too" "$(try -m "feat: a"):$(grep -cxF "  staged path: q\"$TERM_HIT.txt" "$W/err")" "1:1"

fresh
mkdir -p "$R/my dir"; echo "x $TERM_HIT" > "$R/my dir/a b.txt"; git -C "$R" add -A
check "a path with a space is named without git's trailing tab" \
  "$(try -m "feat: a"):$(grep -cx '  added line:  my dir/a b\.txt:1' "$W/err")" "1:1"

fresh
echo ok > "$R/$TERM_HIT.txt"; git -C "$R" add -A
check "a hit in a staged path blocks" "$(try -m "feat: a")" 1
check "  and names the path" "$(said "  staged path: $TERM_HIT.txt\$"):$(said '  added line:')" "1:0"

fresh
git -C "$R" config labs.denylistScan "$W/home/bin/mute.sh"
echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "a hit without a location prints a locate command for the repo root" \
  "$(try -m "feat: a"):$(said "  locate: cd $R && git diff --cached")" "1:1"

fresh
echo ok > "$R/$TERM_UTF8.txt"; git -C "$R" add -A
check "a non-ASCII term in a staged path blocks" "$(try -m "feat: a"):$(said "  staged path: $TERM_UTF8.txt\$")" "1:1"

fresh
echo "x $TERM_HIT" > "$R/a.txt"; git -C "$R" add a.txt; try --no-verify -m "chore: seed" >/dev/null
echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "removing a term is not blocked by pre-commit" "$(try -m "fix: remove it")" 0

fresh
printf 'TOKEN=%s # gitleaks:allow\n' "$(fake_secret)" > "$R/t.txt"; git -C "$R" add t.txt
check "an inline gitleaks:allow secret is still refused" "$(try -m "feat: t")" 1
check "  as a secret" "$(said 'gitleaks found a secret')" 1

fresh
echo "anything" > "$R/.gitleaksignore"; echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "a .gitleaksignore file is refused" "$(try -m "feat: a")" 1
check "  by name" "$(said 'remove .gitleaksignore')" 1

fresh
printf '#!/bin/sh\nexit 1\n' > "$W/bin/gitleaks"; chmod +x "$W/bin/gitleaks"   # 1: what a bad config exits
echo ok > "$R/a.txt"; git -C "$R" add a.txt
code="$(PATH="$W/bin:$PATH" try -m "feat: a")"
check "a gitleaks that cannot run blocks" "$code" 1
check "  as a failure, not a secret" "$(said 'gitleaks failed to run'):$(said 'found a secret')" "1:0"
rm -f "$W/bin/gitleaks"

fresh
mkdir -p "$W/nogl"; for t in bash sh git sed awk grep cut find mktemp rm cat env dirname; do ln -sf "$(command -v "$t")" "$W/nogl/$t"; done
echo ok > "$R/a.txt"; git -C "$R" add a.txt
code="$( (cd "$R" && PATH="$W/nogl" "$(command -v git)" commit -q -m "feat: a") >/dev/null 2>"$W/err"; echo $?)"
check "no gitleaks on PATH: the commit passes" "$code" 0
check "  and says the scan was skipped" "$(said 'secret scan skipped')" 1

fresh
# shellcheck disable=SC2088 # the literal ~ is the input under test
git -C "$R" config labs.denylistScan "~/bin/scan.sh"
echo "x $TERM_HIT" > "$R/a.txt"; git -C "$R" add a.txt
check "a ~ scanner path resolves" "$(HOME="$W/home" try -m "feat: a"):$(said 'private denylist hit'):$(said 'not executable')" "1:1:0"
git -C "$R" config labs.denylistScan "$W/home/bin/missing.sh"
check "a missing scanner is named as missing" "$(try -m "feat: a"):$(said 'missing or not executable')" "1:1"
# shellcheck disable=SC2088 # the literal ~user is the input under test
git -C "$R" config labs.denylistScan "~nosuchuser-zz9/bin/scan.sh"
check "a ~user path that does not expand blocks in pre-commit" "$(try -m "feat: a"):$(said 'pre-commit: cannot read labs.denylistScan')" "1:1"
printf 'feat: a\n' > "$W/msg"
code="$( (cd "$R" && bash "$HOOKS/commit-msg" "$W/msg") 2>"$W/err"; echo $?)"
check "  and in commit-msg" "$code:$(said 'commit-msg: cannot read labs.denylistScan')" "1:1"

fresh
# shellcheck disable=SC2088 # the literal ~ is the input under test
git -C "$R" config labs.denylistScan "~/bin/scan.sh"
echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "commit-msg resolves a ~ scanner path" "$(HOME="$W/home" try -m "feat: $TERM_HIT"):$(said 'hit in the commit message')" "1:1"
git -C "$R" config labs.denylistScan "$W/home/bin/missing.sh"
printf 'feat: a\n' > "$W/msg"
code="$( (cd "$R" && bash "$HOOKS/commit-msg" "$W/msg") 2>"$W/err"; echo $?)"
check "commit-msg names a missing scanner" "$code:$(said 'missing or not executable')" "1:1"

fresh
echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "a hit in the message blocks" "$(try -m "feat: $TERM_HIT")" 1
check "  in commit-msg" "$(said 'hit in the commit message')" 1
check "a -m line starting with # is recorded, so a term there blocks" "$(try -m "fix: a" -m "#21 follow-up for $TERM_HIT")" 1
check "  and names its line in the recorded message" "$(said '  line 3 of the message git will record')" 1
# The editor writes the subject, 4 blank lines, then the term: git collapses them, except in verbatim.
for want in whitespace:3 verbatim:6; do
  git -C "$R" config commit.cleanup "${want%:*}"
  check "with commit.cleanup ${want%:*} the named line counts blank lines as git records them" \
    "$(EDIT_SUBJECT="fix: a" EDIT_BODY="$(printf '\n\n\nx %s' "$TERM_HIT")" GIT_EDITOR="$W/edit" try):$(said "  line ${want#*:} of the message git will record")" "1:1"
done
git -C "$R" config --unset commit.cleanup
git -C "$R" config commit.cleanup strip
check "with commit.cleanup strip git drops a -m # line, so it does not block" "$(try -m "fix: a" -m "#21 $TERM_HIT")" 0
git -C "$R" config --unset commit.cleanup

# An editor adds a # line holding the term; whether git records it depends on commit.cleanup.
fresh
echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "by default git drops an editor's # line, so it does not block" \
  "$(EDIT_SUBJECT="fix: a" EDIT_BODY="#21 $TERM_HIT" GIT_EDITOR="$W/edit" try)" 0
for mode in scissors whitespace verbatim; do
  fresh
  git -C "$R" config commit.cleanup "$mode"
  echo ok > "$R/a.txt"; git -C "$R" add a.txt
  check "with commit.cleanup $mode git keeps an editor's # line, so it blocks" \
    "$(EDIT_SUBJECT="fix: a" EDIT_BODY="#21 $TERM_HIT" GIT_EDITOR="$W/edit" try):$(said 'hit in the commit message')" "1:1"
done

fresh
echo "x $TERM_HIT" > "$R/a.txt"; git -C "$R" add a.txt; try --no-verify -m "chore: seed" >/dev/null
echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "the -v diff of a removal does not block commit-msg" \
  "$(GIT_EDITOR="sed -i.bak '1s/^/fix: remove it/'" try -v)" 0

fresh
echo x > "$R/$TERM_HIT.txt"; git -C "$R" add -A; try --no-verify -m "chore: seed" >/dev/null
git -C "$R" rm -q "$TERM_HIT.txt"
check "git's # status comments do not block commit-msg" "$(GIT_EDITOR="sed -i.bak '1s/^/chore: drop it/'" try)" 0

fresh
git -C "$R" config core.commentChar ';'
echo "x $TERM_HIT" > "$R/a.txt"; git -C "$R" add a.txt; try --no-verify -m "chore: seed" >/dev/null
echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "with core.commentChar ';' the -v diff still does not block" \
  "$(GIT_EDITOR="sed -i.bak '1s/^/fix: remove it/'" try -v)" 0

# core.commentString (git 2.45+) takes a multi-character string.
if [ -z "$(printf '// x\n' | git -c core.commentString=// stripspace --strip-comments 2>/dev/null)" ]; then
  fresh
  git -C "$R" config core.commentString '//'
  echo "x $TERM_HIT" > "$R/a.txt"; git -C "$R" add a.txt; try --no-verify -m "chore: seed" >/dev/null
  echo ok > "$R/a.txt"; git -C "$R" add a.txt
  check "with core.commentString '//' the -v diff does not block" \
    "$(GIT_EDITOR="sed -i.bak '1s/^/fix: remove it/'" try -v)" 0

  fresh
  git -C "$R" config core.commentChar ';'
  git -C "$R" config core.commentString '//'
  echo "x $TERM_HIT" > "$R/a.txt"; git -C "$R" add a.txt; try --no-verify -m "chore: seed" >/dev/null
  echo ok > "$R/a.txt"; git -C "$R" add a.txt
  check "with core.commentChar then core.commentString set, the last one set cuts the -v diff" \
    "$(GIT_EDITOR="sed -i.bak '1s/^/fix: remove it/'" try -v)" 0
else
  echo "SKIP: core.commentString needs git 2.45+"
fi

fresh
git -C "$R" config core.commentChar aUtO   # git reads auto in any case
echo "x $TERM_HIT" > "$R/a.txt"; git -C "$R" add a.txt; try --no-verify -m "chore: seed" >/dev/null
echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "with core.commentChar aUtO the -v diff does not block" "$(GIT_EDITOR="sed -i.bak '1s/^/fix: remove it/'" try -v)" 0
echo "y $TERM_HIT" > "$R/a.txt"; git -C "$R" add a.txt; try --no-verify -m "chore: again" >/dev/null
echo ok > "$R/a.txt"; git -C "$R" add a.txt
check "  nor when git picks ';' for a message that starts with #" "$(GIT_EDITOR=true try -e -v -m "#21 fix: remove it")" 0
echo more > "$R/b.txt"; git -C "$R" add b.txt
check "  and a first line starting with # that git records is scanned" \
  "$(GIT_EDITOR=true try -e -m "#21 $TERM_HIT"):$(said 'hit in the commit message')" "1:1"
check "  but an editor's # line is scanned (git may pick another comment char)" \
  "$(EDIT_SUBJECT="fix: b" EDIT_BODY="#21 $TERM_HIT" GIT_EDITOR="$W/edit" try):$(said 'hit in the commit message')" "1:1"

echo "=============================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] || { echo "FAIL: no checks ran"; exit 1; }
[ "$fails" -eq 0 ] || exit 1
echo "ALL PASS"
