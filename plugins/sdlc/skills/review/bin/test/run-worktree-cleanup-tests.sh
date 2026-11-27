#!/usr/bin/env bash
# Dependency-free test harness for the review-worktree cleanup classifier.
# Builds real throwaway git repos (a bare origin, a primary clone, and review worktrees under
# {parent}/.sdlc-worktrees/{repo}/) and drives worktree-cleanup.js through its CLI. Asserts the
# safety contract: only direct children of .sdlc-worktrees/{repo}/ are candidates, dirty / locked /
# open / PR-less worktrees are kept, squash- and rebase-landed work is safe, unlanded commits are
# listed, and every error fails closed to "keep".
# No npm packages — bash + node + git only. Ends "<n> checks, <m> failed"; exit 1 on any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$HERE/../worktree-cleanup.js"

for tool in node git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool not on PATH — cannot run worktree-cleanup tests" >&2
    exit 1
  fi
done
if [ ! -f "$CTL" ]; then
  echo "FAIL: classifier not found at $CTL" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Hermetic git: no user/system config, fixed identity, no signing, main as the default branch.
export HOME="$WORK/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/home/.gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global advice.detachedHead false

total=0
fails=0
OUT=""
CODE=0

# run <args...> — run the classifier; sets OUT (stdout) and CODE.
run() {
  OUT="$(node "$CTL" "$@" 2>/dev/null)"
  CODE=$?
}

# jget <json> <js-expr over `j`> — evaluate an expression against parsed JSON; prints result.
jget() {
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

# commit <dir> <file> <line> <message> — append a line to a file and commit it; prints nothing.
commit() {
  printf '%s\n' "$3" >>"$1/$2"
  git -C "$1" add "$2" && git -C "$1" commit -qm "$4"
}

sha() { git -C "$REPO" rev-parse "$1"; }
# commits <range> — the PR's commit SHAs, comma-joined (what the platform API reports).
commits() { git -C "$REPO" rev-list "$1" | paste -sd, -; }

# --- fixture: bare origin + primary clone at $PROJ/repo; review worktrees under $WTB ------------
PROJ="$WORK/proj"
ORIGIN="$WORK/origin.git"
REPO="$PROJ/repo"
WTB="$PROJ/.sdlc-worktrees/repo"
mkdir -p "$PROJ"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
# a shared file with distant lines, so a branch and the base can edit it without conflicting
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'line %s\n' "$i" >>"$REPO/shared.txt"; done
git -C "$REPO" add shared.txt && git -C "$REPO" commit -qm "base 0"
git -C "$REPO" push -q origin main

# wt <slug> <branch> <start> — create a review worktree on a new local branch.
wt() { git -C "$REPO" worktree add -q -b "$2" "$WTB/$1" "$3" 2>/dev/null; }

# =================================================================================================
# list — candidate enumeration
# =================================================================================================
wt f1 feat/f1 main
commit "$WTB/f1" f1.txt one "f1 one"
commit "$WTB/f1" f1.txt two "f1 two"
# decoys: same repo, wrong places
git -C "$REPO" worktree add -q -b decoy/elsewhere "$PROJ/elsewhere/x" main 2>/dev/null
git -C "$REPO" worktree add -q -b decoy/repo2 "$PROJ/.sdlc-worktrees/repo2/x" main 2>/dev/null
git -C "$REPO" worktree add -q -b decoy/nested "$WTB/a/b" main 2>/dev/null

run list --repo "$REPO"
check "list exits 0" "$CODE" "0"
check "list returns only direct children of .sdlc-worktrees/{repo}/" \
  "$(jget "$OUT" 'j.worktrees.map(w=>w.path.split("/").pop()).sort().join(",")')" "f1"
check "list reports the branch" "$(jget "$OUT" 'j.worktrees[0].branch')" "feat/f1"
check "list reports the head" "$(jget "$OUT" 'j.worktrees[0].head')" "$(sha feat/f1)"
check_match "list reports wt_base" "$(jget "$OUT" 'j.wt_base')" '/proj/\.sdlc-worktrees/repo$'

run list --repo "$WTB/f1"
check "list from inside a review worktree resolves the same base" \
  "$(jget "$OUT" 'j.worktrees.map(w=>w.path.split("/").pop()).join(",")')" "f1"

# a review worktree created from inside a linked (non-review) worktree lands under the PRIMARY's base
git -C "$PROJ/elsewhere/x" worktree add -q -b feat/from-linked "$WTB/from-linked" main 2>/dev/null
run list --repo "$PROJ/elsewhere/x"
check "worktree created from a linked worktree is listed under the primary's base" \
  "$(jget "$OUT" 'j.worktrees.map(w=>w.path.split("/").pop()).sort().join(",")')" "f1,from-linked"
git -C "$REPO" worktree remove "$WTB/from-linked"

# a hand-made worktree whose folder name would break a single-quoted shell command is flagged, so the
# procedure keeps it before any interpolation (command substitution must never run)
git -C "$REPO" worktree add -q -b feat/quote "$WTB/x'\$(touch PWNED)'" main 2>/dev/null
run list --repo "$REPO"
check "list flags a path containing a quote as not shell-safe" \
  "$(jget "$OUT" 'j.worktrees.find(w=>w.branch==="feat/quote").shell_safe')" "false"
check "list marks an ordinary path shell-safe" "$(jget "$OUT" 'j.worktrees.find(w=>w.branch==="feat/f1").shell_safe')" "true"
check "list reports whether wt_base is shell-safe" "$(jget "$OUT" 'j.wt_base_shell_safe')" "true"
git -C "$REPO" worktree remove "$WTB/x'\$(touch PWNED)'"
TAB="$(printf 'tab\tname')"
git -C "$REPO" worktree add -q -b feat/tab "$WTB/$TAB" main 2>/dev/null
run list --repo "$REPO"
check "list flags a path containing a control character as not shell-safe" \
  "$(jget "$OUT" 'j.worktrees.find(w=>w.branch==="feat/tab").shell_safe')" "false"
git -C "$REPO" worktree remove "$WTB/$TAB"

# the worktree the caller is running in is flagged, so cleanup never removes the session's own directory
run list --repo "$WTB/f1"
check "list from inside a review worktree marks it current" "$(jget "$OUT" 'j.worktrees.find(w=>w.branch==="feat/f1").current')" "true"
check "only that worktree is current" "$(jget "$OUT" 'j.worktrees.filter(w=>w.current).length')" "1"
run list --repo "$REPO"
check "list from the primary checkout marks no worktree current" "$(jget "$OUT" 'j.worktrees.filter(w=>w.current).length')" "0"

# =================================================================================================
# classify — merged PR, head is one of the PR's commits → safe (case 1)
# =================================================================================================
F1="$(sha feat/f1)"
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state merged --pr-ref '#15' \
  --pr-head "$F1" --pr-commits "$(commits main..feat/f1)"
check "head in PR commits → exit 0" "$CODE" "0"
check "head in PR commits → safe" "$(jget "$OUT" 'j.verdict+":"+j.class')" "safe:safe"
check_match "safe reason names the PR" "$(jget "$OUT" 'j.reason')" '#15'

run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state closed --pr-head "$F1" --pr-commits "$F1"
check "closed PR, head in commits → safe" "$(jget "$OUT" 'j.verdict')" "safe"

run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state MERGED --pr-head "$F1" --pr-commits "$F1"
check "gh-style upper-case state is normalised" "$(jget "$OUT" 'j.verdict')" "safe"

# =================================================================================================
# squash merge — none of the branch's commits are in main, all content landed → safe (case 2)
# =================================================================================================
wt f2 feat/f2 main
commit "$WTB/f2" f2.txt one "f2 one"
commit "$WTB/f2" f2.txt two "f2 two"
git -C "$REPO" merge -q --squash feat/f2 >/dev/null && git -C "$REPO" commit -qm "squash f2 (#16)"
git -C "$REPO" push -q origin main
if git -C "$REPO" merge-base --is-ancestor feat/f2 main; then
  check "squash fixture: branch head is NOT in main" "ancestor" "not-ancestor"
fi
F2="$(sha feat/f2)"
run classify --repo "$REPO" --worktree "$WTB/f2" --pr-state merged --pr-head "$F2" \
  --pr-commits "$(git -C "$REPO" rev-list "$F2" ^main~1 | paste -sd, -)"
check "squash-merged branch → safe" "$(jget "$OUT" 'j.verdict+":"+j.class')" "safe:safe"

# =================================================================================================
# rebase before merge — the worktree holds a pre-rebase copy (case 3)
# =================================================================================================
wt f3 feat/f3 main
commit "$WTB/f3" f3.txt one "f3 one"
sed 's/^line 1$/line 1 (f3)/' "$WTB/f3/shared.txt" >"$WTB/f3/shared.tmp" && mv "$WTB/f3/shared.tmp" "$WTB/f3/shared.txt"
git -C "$WTB/f3" commit -qam "f3 edits shared line 1"
OLD3="$(sha feat/f3)"
# the base moves on: a new file AND a non-conflicting hunk in the same file
commit "$REPO" base.txt b1 "base 1"
sed 's/^line 10$/line 10 (base)/' "$REPO/shared.txt" >"$REPO/shared.tmp" && mv "$REPO/shared.tmp" "$REPO/shared.txt"
git -C "$REPO" commit -qam "base edits shared line 10"
# the author rebases the PR onto the new base and pushes (the worktree never sees it)
git -C "$REPO" checkout -q -b feat/f3-final "$OLD3"
git -C "$REPO" rebase -q main
FINAL3="$(sha feat/f3-final)"
git -C "$REPO" checkout -q main
run classify --repo "$REPO" --worktree "$WTB/f3" --pr-state merged --pr-ref '#16' \
  --pr-head "$FINAL3" --pr-commits "$(commits main..feat/f3-final)"
check "pre-rebase copy → safe" "$(jget "$OUT" 'j.verdict+":"+j.class')" "safe:safe"
check_match "pre-rebase reason says content landed" "$(jget "$OUT" 'j.reason')" 'rebase'

# head behind the PR's final head (the author pushed more after this worktree synced) → safe
wt f3b feat/f3b "$FINAL3~1"
run classify --repo "$REPO" --worktree "$WTB/f3b" --pr-state merged --pr-head "$FINAL3" --pr-commits "$FINAL3"
check "head behind PR final head → safe" "$(jget "$OUT" 'j.verdict')" "safe"

# =================================================================================================
# not landed — a commit that is not in the PR's final head (case 4)
# =================================================================================================
wt f4 feat/f4 "$FINAL3"
commit "$WTB/f4" f4.txt x "unpushed fix"
X4="$(sha feat/f4)"
run classify --repo "$REPO" --worktree "$WTB/f4" --pr-state merged --pr-ref '#18' \
  --pr-head "$FINAL3" --pr-commits "$(commits main..feat/f3-final)"
check "extra commit → keep not-landed" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:not-landed"
check "not-landed lists exactly the extra commit" "$(jget "$OUT" 'j.unlanded.map(c=>c.sha).join(",")')" "$X4"
check "not-landed lists the commit subject" "$(jget "$OUT" 'j.unlanded[0].subject')" "unpushed fix"
check_match "not-landed reason counts commits" "$(jget "$OUT" 'j.reason')" '1 commit'

# pre-rebase copy PLUS an extra commit: the rebased duplicates are not listed, only the new one
wt f5 feat/f5 "$OLD3"
commit "$WTB/f5" f5.txt y "follow-up after review"
Y5="$(sha feat/f5)"
run classify --repo "$REPO" --worktree "$WTB/f5" --pr-state merged \
  --pr-head "$FINAL3" --pr-commits "$(commits main..feat/f3-final)"
check "pre-rebase copy + extra commit → not-landed" "$(jget "$OUT" 'j.class')" "not-landed"
check "patch-equivalent rebased commits are not listed" "$(jget "$OUT" 'j.unlanded.map(c=>c.sha).join(",")')" "$Y5"

# pre-rebase copy, then a later PR commit edits the SAME line, then rebase: the content check conflicts,
# but every worktree commit has a patch-equivalent in the final head → landed (safe), nothing listed
wt f7 feat/f7 main
sed 's/^line 5$/line 5 (A)/' "$WTB/f7/shared.txt" >"$WTB/f7/shared.tmp" && mv "$WTB/f7/shared.tmp" "$WTB/f7/shared.txt"
git -C "$WTB/f7" commit -qam "f7 edits line 5"
OLD7="$(sha feat/f7)"
git -C "$REPO" checkout -q -b feat/f7-final "$OLD7"
sed 's/^line 5 (A)$/line 5 (B)/' "$REPO/shared.txt" >"$REPO/shared.tmp" && mv "$REPO/shared.tmp" "$REPO/shared.txt"
git -C "$REPO" commit -qam "review fix: line 5 again"
git -C "$REPO" checkout -q main
commit "$REPO" base7.txt b "base moves for f7"
git -C "$REPO" checkout -q feat/f7-final
git -C "$REPO" rebase -q main
FINAL7="$(sha feat/f7-final)"
git -C "$REPO" checkout -q main
run classify --repo "$REPO" --worktree "$WTB/f7" --pr-state merged --pr-ref '#20' \
  --pr-head "$FINAL7" --pr-commits "$(commits main..feat/f7-final)"
check "pre-rebase copy superseded by a later same-line PR commit → safe" "$(jget "$OUT" 'j.verdict+":"+j.class')" "safe:safe"
check "…and no commit is reported unlanded" "$(jget "$OUT" 'j.unlanded.length')" "0"
check_match "…and the reason says the commits landed by patch" "$(jget "$OUT" 'j.reason')" 'patch'

# an "evil merge": every non-merge commit has a patch-equivalent in the final head, but the merge commit
# itself adds content — patch comparison cannot see it, so a merge in the range is never safe by patch
git -C "$REPO" checkout -q -b side7 "$OLD7~1"
git -C "$REPO" cherry-pick -x "$OLD7" >/dev/null
git -C "$REPO" checkout -q main
git -C "$WTB/f7" merge -q --no-ff --no-commit side7 2>/dev/null
printf 'only in the merge\n' >"$WTB/f7/evil.txt"
git -C "$WTB/f7" add evil.txt && git -C "$WTB/f7" commit -qm "merge side7 (adds evil.txt)"
run classify --repo "$REPO" --worktree "$WTB/f7" --pr-state merged --pr-head "$FINAL7" --pr-commits "$(commits main..feat/f7-final)"
check "evil merge (content only in the merge commit) → not-landed" "$(jget "$OUT" 'j.class')" "not-landed"

# a large base drift on the patch path must not flow through a buffered pipe: with buffered git output
# capped tiny, a superseded pre-rebase copy behind a big generated-file drift is still classified safe
wt f16 feat/f16 main
sed 's/^line 7$/line 7 (A)/' "$WTB/f16/shared.txt" >"$WTB/f16/shared.tmp" && mv "$WTB/f16/shared.tmp" "$WTB/f16/shared.txt"
git -C "$WTB/f16" commit -qam "f16 edits line 7"
OLD16="$(sha feat/f16)"
git -C "$REPO" checkout -q -b big16 main
awk 'BEGIN { for (i = 0; i < 20000; i++) printf "generated row %d\n", i }' >"$REPO/generated.txt"
git -C "$REPO" add generated.txt && git -C "$REPO" commit -qm "big generated drift"
git -C "$REPO" checkout -q -b feat/f16-final "$OLD16"
sed 's/^line 7 (A)$/line 7 (B)/' "$REPO/shared.txt" >"$REPO/shared.tmp" && mv "$REPO/shared.tmp" "$REPO/shared.txt"
git -C "$REPO" commit -qam "f16 review fix: line 7 again"
git -C "$REPO" rebase -q big16
F16="$(sha feat/f16-final)"
git -C "$REPO" checkout -q main
OUT="$(WORKTREE_CLEANUP_MAX_BUFFER=65536 node "$CTL" classify --repo "$REPO" --worktree "$WTB/f16" --pr-state merged --pr-head "$F16" --pr-commits "$(commits big16..feat/f16-final)" 2>/dev/null)"
check "large base drift on the patch path, tiny output buffer → still safe" "$(jget "$OUT" 'j.verdict+":"+j.class')" "safe:safe"
OUT="$(WORKTREE_CLEANUP_MAX_BUFFER=64 node "$CTL" list --repo "$REPO" 2>/dev/null)"
check_match "output over the buffer is reported as such, not as 'git unavailable'" "$(jget "$OUT" 'j.class+":"+j.reason')" '^error:.*exceeded the 64-byte buffer'

# an unpushed amend that only re-indents (YAML / Python meaning changes) is NOT the same patch as the merged
# commit — whitespace-insensitive patch-ids would call it landed and removal would delete the only copy
wt f8 feat/f8 main
printf 'c:\nd: 2\n' >"$WTB/f8/cfg.yaml"
git -C "$WTB/f8" add cfg.yaml && git -C "$WTB/f8" commit -qm "f8 adds cfg"
F8="$(sha feat/f8)"
printf 'c:\n  d: 2\n' >"$WTB/f8/cfg.yaml"
git -C "$WTB/f8" commit -q -a --amend -m "f8 adds cfg (indent fixed)"
run classify --repo "$REPO" --worktree "$WTB/f8" --pr-state merged --pr-head "$F8" --pr-commits "$F8"
check "unpushed whitespace-only amend of a merged commit → keep not-landed" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:not-landed"
check "…and the amend is listed" "$(jget "$OUT" 'j.unlanded.map(c=>c.subject).join(",")')" "f8 adds cfg (indent fixed)"

# an unpushed amend that changes only non-UTF-8 bytes (cp1252 é → è) — the patch comparison must see raw
# bytes; a UTF-8-decoded diff collapses both to U+FFFD and would call the amend landed
wt f9 feat/f9 main
printf 'caf\351\n' >"$WTB/f9/enc.txt"
git -C "$WTB/f9" add enc.txt && git -C "$WTB/f9" commit -qm "f9 adds enc"
F9="$(sha feat/f9)"
printf 'caf\350\n' >"$WTB/f9/enc.txt"
git -C "$WTB/f9" commit -q -a --amend -m "f9 adds enc (cp1252 fix)"
run classify --repo "$REPO" --worktree "$WTB/f9" --pr-state merged --pr-head "$F9" --pr-commits "$F9"
check "unpushed non-UTF-8 byte amend of a merged commit → keep not-landed" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:not-landed"

# a custom merge driver (Pro Git's merge=ours recipe) resolves a both-sides change to the final head's
# version, so merge-tree reproduces F's tree exactly — the content check must not vouch for such paths
git config --global merge.ours.driver true
wt f10 feat/f10 main
printf 'cfg.txt merge=ours\n' >"$WTB/f10/.gitattributes"
printf 'v: 1\n' >"$WTB/f10/cfg.txt"
git -C "$WTB/f10" add .gitattributes cfg.txt && git -C "$WTB/f10" commit -qm "f10 adds cfg"
F10="$(sha feat/f10)"
printf 'v: 2\n' >"$WTB/f10/cfg.txt"
git -C "$WTB/f10" commit -q -a --amend -m "f10 adds cfg (v2)"
run classify --repo "$REPO" --worktree "$WTB/f10" --pr-state merged --pr-head "$F10" --pr-commits "$F10"
check "unpushed amend to a merge=ours file → keep not-landed" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:not-landed"
git config --global --unset merge.ours.driver

# the final head renames a file INTO a driver-attributed path (a common union CHANGELOG recipe) while the
# worktree edits the same region under the old name — merge-tree merges at the new path with the driver
git -C "$REPO" checkout -q -b base13 main
printf 'docs/CHANGELOG.md merge=union\n' >"$REPO/.gitattributes"
printf 'x1\nx2\nx3\nx4\nx5\n' >"$REPO/CHANGELOG.md"
git -C "$REPO" add .gitattributes CHANGELOG.md && git -C "$REPO" commit -qm "base13 changelog"
git -C "$REPO" checkout -q -b feat/f13-final base13
mkdir -p "$REPO/docs" && git -C "$REPO" mv CHANGELOG.md docs/CHANGELOG.md
sed 's/^x3$/x3 (final)/' "$REPO/docs/CHANGELOG.md" >"$REPO/docs/CHANGELOG.tmp" && mv "$REPO/docs/CHANGELOG.tmp" "$REPO/docs/CHANGELOG.md"
git -C "$REPO" commit -qam "f13 moves changelog to docs/"
F13="$(sha feat/f13-final)"
git -C "$REPO" checkout -q main
wt f13 feat/f13 base13
sed '/^x3$/d' "$WTB/f13/CHANGELOG.md" >"$WTB/f13/CHANGELOG.tmp" && mv "$WTB/f13/CHANGELOG.tmp" "$WTB/f13/CHANGELOG.md"
git -C "$WTB/f13" commit -qam "f13 drops x3 (unpushed)"
run classify --repo "$REPO" --worktree "$WTB/f13" --pr-state merged --pr-head "$F13" --pr-commits "$F13"
check "final head renames into a merge=union path, worktree edits the old path → keep not-landed" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:not-landed"

# merge.default applies a driver to every path whose merge attribute is unspecified
git -C "$REPO" checkout -q -b base14 main
printf 'a\nb\nc\nd\ne\n' >"$REPO/u.txt"
git -C "$REPO" add u.txt && git -C "$REPO" commit -qm "base14 u"
git -C "$REPO" checkout -q -b feat/f14-final base14
sed 's/^c$/C/' "$REPO/u.txt" >"$REPO/u.tmp" && mv "$REPO/u.tmp" "$REPO/u.txt"
git -C "$REPO" commit -qam "f14 final edits c"
F14="$(sha feat/f14-final)"
git -C "$REPO" checkout -q main
wt f14 feat/f14 base14
sed '/^c$/d' "$WTB/f14/u.txt" >"$WTB/f14/u.tmp" && mv "$WTB/f14/u.tmp" "$WTB/f14/u.txt"
git -C "$WTB/f14" commit -qam "f14 drops c (unpushed)"
git config --global merge.default union
run classify --repo "$REPO" --worktree "$WTB/f14" --pr-state merged --pr-head "$F14" --pr-commits "$F14"
check "merge.default=union with a same-line change → keep not-landed" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:not-landed"
git config --global --unset merge.default

# a gitlink bump hidden by .gitmodules ignore=all must still count as a different patch
wt f11 feat/f11 main
printf '[submodule "sub"]\n\tpath = sub\n\turl = ./sub\n\tignore = all\n' >"$WTB/f11/.gitmodules"
git -C "$WTB/f11" add .gitmodules
git -C "$WTB/f11" update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,sub"
git -C "$WTB/f11" commit -qm "f11 adds sub"
F11="$(sha feat/f11)"
git -C "$WTB/f11" update-index --cacheinfo "160000,2222222222222222222222222222222222222222,sub"
git -C "$WTB/f11" commit -q --amend -m "f11 adds sub (bumped)"
run classify --repo "$REPO" --worktree "$WTB/f11" --pr-state merged --pr-head "$F11" --pr-commits "$F11"
check "unpushed gitlink bump hidden by ignore=all → keep not-landed" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:not-landed"

# signed commits + log.showSignature must not leak signature lines into the commit parsing
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/signkey"
  printf 't@example.com %s\n' "$(cat "$WORK/signkey.pub")" >"$WORK/allowed_signers"
  git config --global gpg.format ssh
  git config --global user.signingkey "$WORK/signkey.pub"
  git config --global gpg.ssh.allowedSignersFile "$WORK/allowed_signers"
  git config --global commit.gpgsign true
  git config --global log.showSignature true
  wt f12 feat/f12 main
  printf 'c:\nd: 2\n' >"$WTB/f12/sig.yaml"
  git -C "$WTB/f12" add sig.yaml && git -C "$WTB/f12" commit -qm "f12 adds sig"
  F12="$(sha feat/f12)"
  printf 'c:\n  d: 2\n' >"$WTB/f12/sig.yaml"
  git -C "$WTB/f12" commit -q -a --amend -m "f12 adds sig (indent fixed)"
  run classify --repo "$REPO" --worktree "$WTB/f12" --pr-state merged --pr-head "$F12" --pr-commits "$F12"
  check "signed commits with log.showSignature → still classified (not-landed)" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:not-landed"
  check "…and the amend is listed by subject" "$(jget "$OUT" 'j.unlanded.map(c=>c.subject).join(",")')" "f12 adds sig (indent fixed)"
  for k in gpg.format user.signingkey gpg.ssh.allowedSignersFile commit.gpgsign log.showSignature; do
    git config --global --unset "$k"
  done
elif [ "${REQUIRE_SSH_KEYGEN:-0}" = "1" ]; then
  # CI sets this so an image without ssh-keygen can never green a run that skipped the case.
  check "signed-commit case — ssh-keygen required (REQUIRE_SSH_KEYGEN=1) but not on PATH" "missing" "present"
else
  echo "SKIP: signed-commit case (ssh-keygen not on PATH)"
fi

# =================================================================================================
# dirty / locked / prunable worktrees are kept whatever the PR says (case 5)
# =================================================================================================
SAFE_ARGS=(--pr-state merged --pr-head "$F1" --pr-commits "$F1")
printf 'edit\n' >>"$WTB/f1/f1.txt"
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "modified tracked file → keep dirty" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:dirty"
git -C "$WTB/f1" checkout -q -- f1.txt
printf 'new\n' >"$WTB/f1/scratch.txt"
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "untracked file → keep dirty" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:dirty"
rm -f "$WTB/f1/scratch.txt"
git -C "$WTB/f1" rev-parse HEAD >"$(git -C "$WTB/f1" rev-parse --path-format=absolute --git-path MERGE_HEAD)"
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "merge in progress → keep dirty" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:dirty"
rm -f "$(git -C "$WTB/f1" rev-parse --path-format=absolute --git-path MERGE_HEAD)"
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "clean again → safe" "$(jget "$OUT" 'j.verdict')" "safe"

# edits hidden from `git status` by index flags are still uncommitted work — git worktree remove deletes them
git -C "$WTB/f1" update-index --skip-worktree f1.txt
printf 'hidden local edit\n' >>"$WTB/f1/f1.txt"
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "edit hidden by --skip-worktree → keep dirty" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:dirty"
check_match "…and the reason names the hidden path" "$(jget "$OUT" 'j.reason')" 'hidden from git status'
git -C "$WTB/f1" update-index --no-skip-worktree f1.txt && git -C "$WTB/f1" checkout -q -- f1.txt
git -C "$WTB/f1" update-index --assume-unchanged f1.txt
printf 'hidden local edit\n' >>"$WTB/f1/f1.txt"
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "edit hidden by --assume-unchanged → keep dirty" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:dirty"
git -C "$WTB/f1" update-index --no-assume-unchanged f1.txt && git -C "$WTB/f1" checkout -q -- f1.txt
git -C "$WTB/f1" update-index --assume-unchanged f1.txt
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "flagged but unedited file → still safe" "$(jget "$OUT" 'j.verdict')" "safe"
git -C "$WTB/f1" update-index --no-assume-unchanged f1.txt
# a sparse-checkout style skip-worktree entry with no file on disk holds no local edit → not dirty
git -C "$WTB/f1" update-index --skip-worktree f1.txt && rm -f "$WTB/f1/f1.txt"
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "skip-worktree entry absent from disk (sparse) → still safe" "$(jget "$OUT" 'j.verdict')" "safe"
git -C "$WTB/f1" update-index --no-skip-worktree f1.txt && git -C "$WTB/f1" checkout -q -- f1.txt
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "flags cleared → safe again" "$(jget "$OUT" 'j.verdict')" "safe"
check "no ignored files → ignored count 0" "$(jget "$OUT" 'j.ignored')" "0"
# ignored files do not block removal, but git worktree remove deletes them — the verdict must say so
printf 'notes.md\nscratch/\n' >>"$(git -C "$WTB/f1" rev-parse --path-format=absolute --git-path info/exclude)"
printf 'local\n' >"$WTB/f1/notes.md"
mkdir -p "$WTB/f1/scratch" && printf 'a\n' >"$WTB/f1/scratch/a" && printf 'b\n' >"$WTB/f1/scratch/b"
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "ignored files alone → still safe" "$(jget "$OUT" 'j.verdict')" "safe"
check "ignored paths are counted (a directory counts once)" "$(jget "$OUT" 'j.ignored')" "2"
check_match "safe reason discloses the ignored paths removal deletes" "$(jget "$OUT" 'j.reason')" '2 ignored path\(s\) will also be deleted'
rm -rf "$WTB/f1/notes.md" "$WTB/f1/scratch"

git -C "$REPO" worktree lock --reason "on a USB disk" "$WTB/f1"
run list --repo "$REPO"
check "list reports locked" "$(jget "$OUT" 'j.worktrees.find(w=>w.branch==="feat/f1").locked')" "true"
run classify --repo "$REPO" --worktree "$WTB/f1" "${SAFE_ARGS[@]}"
check "locked worktree → keep locked" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:locked"
check_match "locked reason carries the lock reason" "$(jget "$OUT" 'j.reason')" 'USB disk'
git -C "$REPO" worktree unlock "$WTB/f1"

wt gone feat/gone main
rm -rf "$WTB/gone"
run list --repo "$REPO"
check "list reports a missing directory as prunable" "$(jget "$OUT" 'j.worktrees.find(w=>w.branch==="feat/gone").prunable')" "true"
run classify --repo "$REPO" --worktree "$WTB/gone" --pr-state merged --pr-head "$(sha feat/gone)" --pr-commits "$(sha feat/gone)"
check "missing directory → keep prunable" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:prunable"
git -C "$REPO" worktree prune

# =================================================================================================
# PR open / no PR / local-only pre-check / head unavailable
# =================================================================================================
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state open --pr-head "$F1" --pr-commits "$F1"
check "PR open → keep pr-open" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:pr-open"
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state OPEN
check "gh's upper-case OPEN counts as open" "$(jget "$OUT" 'j.class')" "pr-open"
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state none
check "no PR → keep no-pr" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:no-pr"
run classify --repo "$REPO" --worktree "$WTB/f1"
check "no PR facts yet, clean → pending" "$(jget "$OUT" 'j.verdict+":"+j.class')" "pending:pending"
printf 'new\n' >"$WTB/f1/scratch.txt"
run classify --repo "$REPO" --worktree "$WTB/f1"
check "no PR facts yet, dirty → keep dirty (no API call needed)" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:dirty"
rm -f "$WTB/f1/scratch.txt"
run classify --repo "$REPO" --worktree "$WTB/f4" --pr-state merged --pr-head 0123456789abcdef0123456789abcdef01234567
check "PR final head not available locally → keep head-unavailable" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:head-unavailable"

# =================================================================================================
# source branch deleted on the remote — final head reached through the PR ref only
# =================================================================================================
OTHER="$WORK/other"
git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
git -C "$OTHER" checkout -q -b feat/f6 origin/main~1
commit "$OTHER" f6.txt one "f6 one"
git -C "$OTHER" push -q origin feat/f6
git -C "$REPO" fetch -q origin feat/f6
wt f6 feat/f6 origin/feat/f6
git -C "$OTHER" rebase -q origin/main
FINAL6="$(git -C "$OTHER" rev-parse HEAD)"
git -C "$OTHER" push -q origin "HEAD:refs/pull/7/head"
git -C "$OTHER" push -q origin --delete feat/f6
git -C "$REPO" fetch -q --prune origin
git -C "$REPO" fetch -q origin "refs/pull/7/head"
run classify --repo "$REPO" --worktree "$WTB/f6" --pr-state merged --pr-ref '#7' --pr-head "$FINAL6" --pr-commits "$FINAL6"
check "remote branch deleted, PR head fetched by ref → safe" "$(jget "$OUT" 'j.verdict')" "safe"

# =================================================================================================
# fail closed — every controller error exits 2 with verdict keep
# =================================================================================================
expect_error() {
  check "$1 → exit 2" "$CODE" "2"
  check "$1 → verdict keep" "$(jget "$OUT" 'j.verdict+":"+j.class')" "keep:error"
}
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-stat merged
expect_error "unknown option"
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state merged --pr-state none
expect_error "duplicate option"
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state merged --pr-head 'HEAD;rm'
expect_error "malformed SHA"
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state merged --pr-head "$F1" --pr-commits "$F1,nope"
expect_error "malformed commit list"
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state abandoned
expect_error "unknown PR state"
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state merged --pr-ref 15 --pr-head "$F1" --pr-commits "$F1"
expect_error "a PR ref without #"
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state constructor --pr-head "$F1" --pr-commits "$F1"
expect_error "inherited object key as PR state (constructor)"
run classify --repo "$REPO" --worktree "$WTB/f1" --pr-state __proto__ --pr-head "$F1" --pr-commits "$F1"
expect_error "inherited object key as PR state (__proto__)"
run classify --repo "$REPO" --worktree "$REPO" --pr-state merged --pr-head "$F1"
expect_error "primary checkout is never a candidate"
run classify --repo "$REPO" --worktree "$PROJ/elsewhere/x" --pr-state merged --pr-head "$F1"
expect_error "worktree outside .sdlc-worktrees/{repo}/"
run classify --repo "$REPO" --worktree "$WTB/a/b" --pr-state merged --pr-head "$F1"
expect_error "nested path under the base"
run classify --repo "$REPO" --pr-state merged
expect_error "missing --worktree"
run list --repo "$WORK/not-a-repo"
expect_error "list outside a git repo"
run sweep
expect_error "unknown command"

echo "=================================="
echo "$total checks, $fails failed"
[ "$total" -gt 0 ] && [ "$fails" -eq 0 ]
