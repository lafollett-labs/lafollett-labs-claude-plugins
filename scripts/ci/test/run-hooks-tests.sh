#!/usr/bin/env bash
# Tests for scripts/hooks/{pre-commit,commit-msg} in throwaway repos: real git, real gitleaks, and a
# stub denylist scanner keyed on one synthetic term. Fake secrets are assembled at runtime so none is
# ever committed. Exit 0 = all pass.
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
chmod +x "$W/home/bin/scan.sh"

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
check "  and says where to look" "$(said 'staged paths or added lines'):$(said 'locate: git diff --cached')" "1:1"

fresh
echo ok > "$R/$TERM_HIT.txt"; git -C "$R" add -A
check "a hit in a staged path blocks" "$(try -m "feat: a")" 1

fresh
echo ok > "$R/$TERM_UTF8.txt"; git -C "$R" add -A
check "a non-ASCII term in a staged path blocks" "$(try -m "feat: a")" 1

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
check "a ~ scanner path resolves" "$(HOME="$W/home" try -m "feat: a"):$(said 'not executable')" "1:0"
git -C "$R" config labs.denylistScan "$W/home/bin/missing.sh"
check "a missing scanner is named as missing" "$(try -m "feat: a"):$(said 'missing or not executable')" "1:1"
# shellcheck disable=SC2088 # the literal ~user is the input under test
git -C "$R" config labs.denylistScan "~nosuchuser-zz9/bin/scan.sh"
check "a ~user path that does not expand blocks" "$(try -m "feat: a"):$(said 'cannot read labs.denylistScan')" "1:1"

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

echo "=============================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] || { echo "FAIL: no checks ran"; exit 1; }
[ "$fails" -eq 0 ] || exit 1
echo "ALL PASS"
