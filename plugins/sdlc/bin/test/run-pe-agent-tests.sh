#!/usr/bin/env bash
# Contract tests for the PE-agent reporting bar, the search boundary, and pe-governance + lens 5
# enforcing the skill-authoring standard in both directions.
# Asserts the PE agents and sdlc:review agree on what gates: one senior-reviewer
# REPORTING BAR, every calibration valve routes to verification_receipts[] (never a
# severity downgrade or a silent drop), MEDIUM+ gates while LOW/INFO are advisory (one
# severity definition, owned by sdlc:review), receipts are producer-classified via `claim:`,
# absence claims need command + output. The protocol lives once, in pe-protocol.md, which
# sdlc:review inlines into every dispatch; agents carry only stack heuristics and never restate it.
# Below DEEP, PEs stay inside SEARCH_ROOTS under a defined budget, and an out-of-bounds document
# claim is an indeterminate receipt, never promoted. Every agent is named for its file and hands
# off only to PEs that exist.
# Mutation cases prove the guards actually fail.
# No dependencies — bash + POSIX grep/awk. Exit 0 = every check passes, 1 = any fails.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/../.." && pwd)"
BAR='REPORTING BAR: "Is this a real defect a senior reviewer would want fixed or flagged on this PR?"'

checks=0
fails=0
pass() { checks=$((checks + 1)); echo "PASS: $1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL: $1"; }

# Placeholder keys examples may use: #42/#57/#123/#1234, ABC-123/ABC-1234, and story codes LT-NN (LT-02).
PLACEHOLDERS=':(#(42|57|123|1234)|[A-Z][A-Z0-9]+-(123|1234)|LT-[0-9]{2})$'


# section <file> <heading-regex> — lines under a "## " heading, up to the next "## " heading.
section() { awk -v h="$2" '$0 ~ h {on=1; next} on && /^## /{exit} on{print}' "$1"; }

# block <file> <heading-regex> — lines under a "### " heading, up to the next "##" heading.
block() { awk -v h="$2" '$0 ~ h {on=1; next} on && /^##/{exit} on{print}' "$1"; }

# docs_section / docs_block <heading-regex> <file>... — as section / block, searched across several files
# (SKILL.md plus its references); a match never runs past the end of the file it starts in.
docs_section() { local h="$1"; shift; awk -v h="$h" 'FNR==1{if(on)exit} $0 ~ h {on=1; next} on && /^## /{exit} on{print}' "$@"; }
docs_block() { local h="$1"; shift; awk -v h="$h" 'FNR==1{if(on)exit} $0 ~ h {on=1; next} on && /^##/{exit} on{print}' "$@"; }

# unproven_branch <file>... — the proof check's branch for a receipt still unproven after its one re-dispatch.
unproven_branch() {
  docs_block '^#+ Negative-receipt proof check' "$@" | awk '/no reply == unproven/{on=1} on && /^[[:space:]]*else:/{exit} on{print}'
}

# issue_refs <file>... — "<line>:#<n>" ("<file>:<line>:#<n>" for several files, as grep -n prints) for each
# issue number of two or more digits; a # glued to a word or #, an entity (&#8212;) or a hex colour with a
# letter (#5319e7) is not one. Same rule as run-skill-structure-tests.sh.
issue_refs() {
  awk -v many="$(( $# > 1 ))" '{
    rest = $0; prev = ""
    while (match(rest, /#[0-9][0-9]+/)) {
      before = RSTART > 1 ? substr(rest, RSTART - 1, 1) : prev
      after = substr(rest, RSTART + RLENGTH, 1)
      if (before !~ /[[:alnum:]&#]/ && after !~ /[[:alnum:]]/)
        print (many ? FILENAME ":" : "") FNR ":" substr(rest, RSTART, RLENGTH)
      prev = substr(rest, RSTART + RLENGTH - 1, 1); rest = substr(rest, RSTART + RLENGTH)
    }
  }' "$@"
}

# narration <file>... — ticket keys / story numbers, ignoring finding and receipt ids (MEDIUM-001, RECEIPT-002)
# and the PLACEHOLDERS example keys
narration() {
  { grep -noE '[A-Z][A-Z0-9]+-[0-9]+|[Ss]tor(y|ies) [0-9]+|(^|[^A-Za-z])AC[0-9]+|# 0[0-9]( |$)' "$@"; issue_refs "$@"; } \
    | grep -vE ':(CRITICAL|HIGH|MEDIUM|LOW|INFO|RECEIPT)-[0-9]+$' | grep -vE "$PLACEHOLDERS"
}

# ticket_refs <file> — the narrower ticket regex the agent and protocol checks use, same exemptions
ticket_refs() {
  { grep -noE '[A-Z][A-Z0-9]+-[0-9]+|[Ss]tory [0-9]+' "$1"; issue_refs "$1"; } \
    | grep -vE ':(CRITICAL|HIGH|MEDIUM|LOW|INFO|RECEIPT)-[0-9]+$' | grep -vE "$PLACEHOLDERS"
}

# anchor <file> — the shared Calibration Anchor block (heading through the lenses lead-in).
anchor() { awk '/^### Calibration Anchor/{on=1} on{print} /^The lenses below describe/{exit}' "$1"; }

# check_tree <plugin-root> — run every contract check; prints one line per failed check,
# prints nothing when the tree satisfies the contract.
check_tree() {
  local root="$1" f pe ref p5 fmt schema want ub pf
  local skill="$root/skills/review/SKILL.md" proto="$root/skills/review/references/pe-protocol.md"
  local docs=("$skill" "$root"/skills/review/references/*.md)   # the review skill's instructions: SKILL.md + references
  [ -f "$proto" ] || { echo "protocol: pe-protocol.md missing"; return; }
  ref="$(anchor "$proto")"
  [ -n "$ref" ] || echo "protocol: Calibration Anchor block not found"
  printf '%s' "$ref" | grep -qF -- "$BAR" || echo "anchor: REPORTING BAR missing from the shared Calibration Anchor"
  printf '%s' "$ref" | grep -qF -- 'gates at ANY severity' && echo "anchor: claims every severity gates"
  grep -rliE -- 'block (this|the) PR' "$root/agents" "${docs[@]}" "$root/README.md" | sed 's|^|blocking-only REPORTING BAR (contradicts advisory LOW/INFO): |'
  # the protocol reaches every PE: sdlc:review reads it and inlines it into the dispatch prompt
  # shellcheck disable=SC2016 # the literal ${CLAUDE_PLUGIN_ROOT} is the text under test
  grep -qF 'PE_PROTOCOL        = read ${CLAUDE_PLUGIN_ROOT}/skills/review/references/pe-protocol.md' "$skill" \
    || echo "review: SKILL.md does not read the PE protocol"
  docs_section '^#+ Dispatch input contract' "${docs[@]}" | grep -qF '{PE_PROTOCOL}' \
    || echo "review: dispatch prompt does not inline the PE protocol"
  grep -qF 'if PE_PROTOCOL is empty or lacks "## Output Format":' "$skill" \
    || echo "review: dispatch does not stop on an empty or unreadable PE protocol"
  # the review moves reach every PE the same way, and the protocol asks for their coverage
  # shellcheck disable=SC2016 # the literal ${CLAUDE_PLUGIN_ROOT} is the text under test
  grep -qF 'REVIEW_MOVES       = read ${CLAUDE_PLUGIN_ROOT}/skills/review/references/review-moves.md' "$skill" \
    || echo "review: SKILL.md does not read the review moves"
  docs_section '^#+ Dispatch input contract' "${docs[@]}" | grep -qF '{REVIEW_MOVES}' \
    || echo "review: dispatch prompt does not inline the review moves"
  grep -qF 'if REVIEW_MOVES is empty or lacks "moves_coverage":' "$skill" \
    || echo "review: dispatch does not stop on an empty or unreadable review moves file"
  section "$proto" '^## Output Format' | grep -qF 'moves_coverage:' || echo "protocol: Output Format missing moves_coverage:"
  # lineage: the dispatch carries the fix diff + ripple receipts, validate gets the prior ids, the moves define the keys
  docs_section '^#+ Dispatch input contract' "${docs[@]}" | grep -qF 'FIX DIFF:' || echo "review: dispatch prompt does not carry FIX DIFF"
  docs_section '^#+ Dispatch input contract' "${docs[@]}" | grep -qF 'RIPPLE RECEIPTS:' || echo "review: dispatch prompt does not carry RIPPLE RECEIPTS"
  grep -qF 'prior_ids: session.prior_ids}' "$skill" || echo "review: validate does not get the prior round's ids"
  grep -qF 'if v.gating: print review-moves.md § Remediation Pre-flight' "$skill" || echo "review: a round with gating findings does not print the remediation pre-flight"
  section "$proto" '^## Output Format' | grep -qF 'introduced_by:' || echo "protocol: Output Format missing introduced_by:"
  for want in '## Round 2+' '## Finding Keys' '## Remediation Pre-flight'; do
    grep -qxF -- "$want" "$root/skills/review/references/review-moves.md" 2>/dev/null || echo "moves: $want missing"
  done
  for want in 'M1 Ripple' 'M2 Lifecycle' 'M3 Inputs' 'M4 Attack the guard' 'M5 Failure path' 'M6 Falsify the test' 'M7 Fact check'; do
    grep -qF -- "| $want |" "$root/skills/review/references/review-moves.md" 2>/dev/null || echo "moves: $want missing from the move table"
  done

  # AC1 — no valve relies on a severity downgrade (any casing / stem) or a silent drop.
  for f in "$proto" "$root"/agents/pe-*.md; do
    pe="$(basename "$f" .md)"; [ "$f" = "$proto" ] && pe=protocol
    grep -niE '(downgrad(e|ed|es|ing)|demot(e|ed|es|ing)) (a |the )?([a-z ]*finding )?to (LOW|INFO)|INFO at best|pre-demote' "$f" \
      | sed "s|^|$pe: severity-downgrade valve: |"
    grep -nF 'cannot verify → remove' "$f" | sed "s|^|$pe: unverifiable valve drops instead of routing: |"
  done
  # AC1/AC3/AC4 — Pass 5 carries the bar and both proof checks.
  p5="$(section "$proto" '^## Pass 5')"
  for want in "$BAR" 'provenance_check:' 'negative_receipt_proof:' \
              'construct the input MOST likely to break the claim and run it' \
              'never a claim about the whole input class'; do
    printf '%s' "$p5" | grep -qF -- "$want" || echo "protocol: Pass 5 missing: $want"
  done
  printf '%s' "$p5" | grep -qi -- 'downgrade' && echo "protocol: Pass 5 severity_honesty says downgrade"
  printf '%s' "$p5" | grep -qF -- 'rate it from Severity Definitions' || echo "protocol: Pass 5 severity_honesty missing: rate it from Severity Definitions"
  printf '%s' "$p5" | grep -qF -- 'one level lower' && echo "protocol: Pass 5 severity_honesty says one level lower"
  # AC2 — the Output Format teaches the non-gating channel and its fields.
  fmt="$(section "$proto" '^## Output Format')"
  for want in 'verification_receipt:' 'verification_receipts:' 'claim:' 'evidence:' 'is_pattern:'; do
    printf '%s' "$fmt" | grep -qF -- "$want" || echo "protocol: Output Format missing $want"
  done
  check_protocol_file "$proto"

  for f in "$root"/agents/pe-*.md; do
    pe="$(basename "$f" .md)"
    check_lean_agent "$f" "$pe"
  done
  check_agent_set "$root"

  # AC3 — sdlc:review proof-checks producer-classified absence receipts, keyed by teammate.
  [ -f "$skill" ] || { echo "review: SKILL.md missing"; return; }
  grep -qE '^#+ Negative-receipt proof check' "${docs[@]}" || echo "review: Phase 5 missing negative-receipt proof check"
  grep -qF 'accept without recommendation check (positive attestations, no gating)' "${docs[@]}" \
    && echo "review: Phase 4 still accepts every receipt unchecked"
  grep -qF 'receipt.claim == "absence"' "${docs[@]}" || echo "review: proof check not keyed on receipt.claim"
  grep -qF 'NEGATIVE_CLAIM' "${docs[@]}" && echo "review: keyword regex still classifies receipts"
  grep -qF 'unproven[name]' "${docs[@]}" || echo "review: proof re-dispatch not keyed by teammate name"
  grep -qF 'no reply == unproven' "${docs[@]}" || echo "review: receipt with no reply is not treated as unproven"
  grep -qF 'evidence covers only part of the claim' "${docs[@]}" || echo "review: proof check accepts partial evidence"
  grep -qF 're-classified by its producer' "${docs[@]}" && echo "review: proof check accepts a relabelled unproven receipt"
  grep -qF 'reply.attestation == receipt.attestation' "${docs[@]}" || echo "review: relabelled-not-narrowed reply is not treated as unproven"
  grep -qF 'every PE receipt; a demoted finding' "${docs[@]}" || echo "review: round-1 review file omits PE receipts"
  grep -qF 'snapshot = collected_outputs[name]' "${docs[@]}" || echo "review: proof-check reply overwrites the PE's full output"
  grep -qF 'remove receipt from snapshot.verification_receipts' "${docs[@]}" \
    || echo "review: a re-emitted finding leaves its receipt in the receipt list"
  # a receipt still unproven after its one re-dispatch stays a non-gating below_bar receipt with its original claim
  ub="$(unproven_branch "${docs[@]}")"
  printf '%s' "$ub" | grep -qF 'replace receipt in snapshot.verification_receipts' \
    || echo "review: unproven absence receipt is not kept in the receipt list"
  printf '%s' "$ub" | grep -qF 'claim: below_bar' || echo "review: unproven absence receipt is not retained as below_bar"
  printf '%s' "$ub" | grep -qF '"Absence unproven after one re-dispatch. Original claim: {receipt.attestation}"' \
    || echo "review: unproven receipt loses its original claim"
  printf '%s' "$ub" | grep -qE 'consolidated|remove receipt' && echo "review: unproven receipt is promoted or dropped"
  docs_block '^#+ Negative-receipt proof check' "${docs[@]}" | grep -qF 'Unproven safety claim' \
    && echo "review: unproven receipt re-promoted to a finding"
  # a receipt's presence is not proof; a finding lacking proof is kept as a receipt, never dropped
  pf="$(docs_block '^#+ Per-finding receipt check' "${docs[@]}")"
  printf '%s' "$pf" | grep -qF 'does not prove the actual problem' \
    || echo "review: per-finding check accepts a receipt that proves no problem"
  printf '%s' "$pf" | grep -qF 'preserve the original claim and missing proof' \
    || echo "review: per-finding check loses the original claim or missing proof"
  { printf '%s\n' "$pf"; docs_block '^#+ Schema enforcement' "${docs[@]}" | grep -F 'proving the problem'; } \
    | grep -qF 'OR drop' && echo "review: a finding lacking proof can be dropped instead of kept as a receipt"
  grep -qE '^elif any in-scope (LOW|INFO):' "${docs[@]}" && echo "review: LOW/INFO still gate the verdict"
  docs_block '^#+ Severity adjustment' "${docs[@]}" | grep -qF 'MEDIUM is never demoted here' \
    || echo "review: severity adjustment can demote a MEDIUM into advisory"
  docs_block '^#+ Severity adjustment' "${docs[@]}" | grep -F 'adjust to that level' | grep -qF 'never below MEDIUM' \
    || echo "review: severity adjustment can lower a proven HIGH/CRITICAL into advisory"
  docs_block '^#+ Severity adjustment' "${docs[@]}" | grep -qF 'do not retain by lowering severity' \
    || echo "review: severity adjustment can keep an unproven finding by lowering its severity"
  grep -qF 'every finding keeps its full entry under § In Scope Findings' "${docs[@]}" \
    || echo "review: Advisory Findings can replace In Scope entries"
  grep -qF 'Keep the SAME id' "${docs[@]}" || echo "review: proof re-dispatch does not pin the receipt id"
  grep -qF 'for reply in reply_entries whose id matches no receipt' "${docs[@]}" \
    || echo "review: unmatched proof-check reply findings are dropped"
  grep -qF "record the command + output as the receipt's evidence" "${docs[@]}" \
    && echo "review: promoted finding asks the author to edit a reviewer-owned receipt"
  schema="$(docs_section '^## YAML Schema' "${docs[@]}")"
  printf '%s' "$schema" | grep -qE '^[[:space:]]+evidence:' || echo "review: schema missing receipt evidence: field"
  printf '%s' "$schema" | grep -qE '^[[:space:]]+claim:' || echo "review: schema missing receipt claim: field"
  # one severity definition: LOW/INFO rows are advisory, MEDIUM gates
  LC_ALL=C grep -qE '^\| (🟢 LOW|ℹ️ INFO) \|.*CHANGES REQUESTED' "${docs[@]}" && echo "review: LOW/INFO severity rows still gate"
  LC_ALL=C grep -qE '^\| 🟡 MEDIUM \|.*CHANGES REQUESTED' "${docs[@]}" || echo "review: MEDIUM severity row does not gate"
  check_search_bounds "$root"
  check_governance_standard "$root"
  check_review_skill "$root"
  check_build_output "$root"
  check_shared_docs "$root"
}

# fenced <file> <heading-regex> — the code-fence lines under a "## " heading.
fenced() { section "$1" "$2" | awk '/^```/{f=!f; next} f'; }

# check_build_output <plugin-root> — front-end PEs never install into or write a build into the engineer's
# checkout and never build a production configuration: the engineer picks where front-end builds run (--auto
# takes the disposable worktree), build-plan.js places and picks each build, the dispatch carries it, the round
# releases the scratch directory, and a PE that cannot find a non-production build asks instead of building.
check_build_output() {
  local root="$1" f
  local dc="$root/skills/review/references/dispatch-and-collect.md" proto="$root/skills/review/references/pe-protocol.md"
  [ -f "$root/skills/review/bin/build-plan.js" ] || echo "review: script missing: build-plan.js"
  grep -qF 'bin/build-plan.js" plan' "$dc" || echo "review: dispatch does not run build-plan.js plan"
  docs_section '^## Round teardown' "$dc" | grep -qF 'bin/build-plan.js" release --dir "{session.build_scratch}"' \
    || echo "review: round teardown does not release the build scratch directory"
  for want in 'BUILD ROOT:     {session.build_root_line}' '{optional} BUILD PLAN:' \
              'session.search_roots += [session.build_scratch]' 'if r.swept:' \
              '"mode": "{mode}"' '"builds": "{session.builds, else worktree}"'; do
    grep -qF -- "$want" "$dc" || echo "review: dispatch missing: $want"
  done
  docs_section '^## Build root' "$dc" | grep -A1 -F 'elif session.auto:' | grep -qF 'session.builds = "worktree"' \
    || echo "review: --auto does not build in a disposable worktree"
  for want in '(worktree) "Disposable worktree' '(checkout) "My checkout, no install' '(off) "No front-end builds'; do
    docs_section '^## Build root' "$dc" | grep -qF -- "$want" || echo "review: build choice missing: $want"
  done
  for want in 'config --get "branch.{branch}.sdlcReviewBuilds"' 'config "branch.{branch}.sdlcReviewBuilds" "{session.builds}"' \
              'elif remembered in ["worktree", "checkout", "off"]:'; do
    docs_section '^## Build root' "$dc" | grep -qF -- "$want" || echo "review: build choice not remembered per branch: $want"
  done
  if [ -f "$root/skills/deliver/SKILL.md" ]; then
    grep -qF -- '--builds worktree|checkout|off' "$root/skills/deliver/SKILL.md" || echo "deliver: argument-hint missing --builds"
    grep -F 'session.review_args = ' "$root/skills/deliver/SKILL.md" | grep -qF 'session.builds_arg' || echo "deliver: --builds not threaded to review"
  fi
  docs_section '^## Build root' "$dc" | grep -qF 'branch_ok = branch != "HEAD" and branch matches ^[A-Za-z0-9._/-]+$' \
    || echo "review: branch name reaches git config unchecked"
  # shellcheck disable=SC2016 # awk's $0, not the shell's
  docs_section '^## Build root' "$dc" | awk '/config.*sdlcReviewBuilds/ && !/branch_ok/ && prev !~ /if branch_ok/ {bad=1} {prev=$0} END{exit !bad}' \
    && echo "review: a git config call skips the branch_ok guard"
  docs_section '^## Build root' "$dc" | grep -qF 'bin/build-plan.js" detect' || echo "review: front-end decided by PE routing, not by the project"
  docs_section '^## Collect' "$dc" | grep -qF '(skip-all) "' || echo "review: build-direction question has a single option"
  docs_section '^## Build root' "$dc" | grep -A1 -F 'elif remembered in' | grep -qF 'remembered for {branch}' || echo "review: remembered build choice applied silently"
  docs_section '^## Collect' "$dc" | awk '/first line is "build_direction"/{d=NR} /event is a YAML message m/{y=NR} END{exit !(d && y && d < y)}' \
    || echo "review: build_direction is not matched before YAML findings"
  grep -qE 'message: \{type: "?build_direction' "$dc" "$proto" && echo "review: build_direction sent as an object SendMessage rejects"
  grep -qF 'message: "build_direction answer: {answer}"' "$dc" || echo "review: lead's build direction reply is not a string"
  grep -qF 'the value after "--builds"' "$root/skills/review/SKILL.md" || echo "review: no --builds flag"
  grep -qF -- '--builds worktree|checkout|off' "$root/skills/review/SKILL.md" || echo "review: argument-hint missing --builds"
  docs_section '^## Collect' "$dc" | grep -qF 'name in awaiting_direction' \
    || echo "review: a PE awaiting build direction is nudged as stalled"
  docs_section '^## Collect' "$dc" | grep -qF 'if session.auto: answer = "skip"' \
    || echo "review: build direction blocks an unattended run"
  section "$proto" '^## Inputs' | grep -qF '**Build root**' || echo "protocol: Inputs missing build root"
  section "$proto" '^## Constraints' | grep -qF 'not scratch space' || echo "protocol: no rule keeping builds out of the checkout"
  section "$proto" '^## Constraints' | grep -qF 'bake an environment' || echo "protocol: build rule not scoped to builds that bake an environment"
  section "$proto" '^## Constraints' | grep -qF "Never run an install" || echo "protocol: no rule against installs in the checkout"
  section "$proto" '^## Constraints' | grep -qF 'message: "build_direction\nproject: ' || echo "protocol: no ask-for-direction rule"
  # shellcheck disable=SC2016 # literal backticks
  section "$proto" '^## Constraints' | grep -qF 'run only a `run` entry' || echo "protocol: engineer's checkout runs more than run entries"
  section "$proto" '^## Constraints' | grep -qF 'also skips that project'"'"'s tests, lint, and typecheck' \
    || echo "protocol: checks: skip does not stop tests in a checkout without node_modules"
  grep -F '{optional} BUILD PLAN:' "$dc" | grep -qF 'checks: skip' || echo "review: BUILD PLAN line never shows checks: skip"
  section "$proto" '^## Constraints' | grep -qF 'naming its configuration and output path' || echo "protocol: build receipt rule missing"
  for f in "$root"/agents/*.md; do
    fenced "$f" '^## Commands' | grep -qE -- '--configuration[= ]?(prod|production)([^A-Za-z-]|$)|-c (prod|production)([^A-Za-z-]|$)|build:prod' \
      && echo "$(basename "$f" .md): production build command"
  done
  for f in pe-angular pe-vue; do
    fenced "$root/agents/$f.md" '^## Commands' | grep -E '^npm (ci|install)' | grep -vqF "never in the engineer's checkout" \
      && echo "$f: installs without the BUILD ROOT guard"
    section "$root/agents/$f.md" '^## Commands' | grep -qF 'BUILD ROOT' || echo "$f: commands do not run from the BUILD ROOT"
  done
  grep -qF 'npm script instead' "$root/agents/pe-angular.md" && echo "pe-angular: build:prod fallback"
  section "$root/agents/pe-angular.md" '^## Commands' | grep -qF 'BUILD PLAN' || echo "pe-angular: builds outside the BUILD PLAN"
  fenced "$root/agents/pe-vue.md" '^## Commands' | grep -qE '^npm run (generate|build-storybook)' && echo "pe-vue: builds outside the BUILD PLAN"
  grep -qF -- '--configuration=production' "$root/README.md" && echo "readme: lists a production build"
}

# check_shared_docs <plugin-root> — the plugin's shared references and assets meet the authoring standard:
# a table of contents past 100 lines ("# Contents" as a comment in YAML) and no ticket narration.
check_shared_docs() {
  local root="$1" f
  for f in "$root"/references/*.md "$root"/assets/*.md "$root"/assets/*.yaml; do
    [ -f "$f" ] || continue
    [ "$(wc -l < "$f")" -le 100 ] || grep -qE '^#{1,2} Contents' "$f" || echo "shared: no table of contents: ${f#"$root"/}"
    narration "$f" | sed "s|^|shared: ticket narration: ${f#"$root"/}:|"
  done
}

# check_review_skill <plugin-root> — review SKILL.md is an orchestration overview: under 500 lines, references
# one level deep (each loaded from SKILL.md, none loading another, a TOC past 100 lines), no ticket narration,
# and the deterministic steps run as scripts instead of being restated.
check_review_skill() {
  local root="$1" f n want
  local skill="$root/skills/review/SKILL.md" refs="$root/skills/review/references" bin="$root/skills/review/bin"
  n="$(wc -l < "$skill")"; [ "$n" -lt 500 ] || echo "review: SKILL.md body is $n lines (limit 500)"
  narration "$skill" "$refs"/*.md | sed 's|^.*/skills/review/|review: ticket narration: |'
  for f in "$refs"/*.md; do
    n="$(wc -l < "$f")"
    [ "$n" -le 100 ] || grep -q '^## Contents' "$f" || echo "review: no table of contents: $(basename "$f")"
    grep -qF "\${CLAUDE_PLUGIN_ROOT}/skills/review/references/$(basename "$f")" "$skill" \
      || echo "review: reference not loaded from SKILL.md: $(basename "$f")"
    # any casing of read/load, optionally inflected, with the path bare, backticked or quoted
    # shellcheck disable=SC2016 # literal backtick in the pattern
    grep -qiE '(read|load)s?[[:space:]]+[`"]?\$\{CLAUDE_PLUGIN_ROOT\}/(skills/review/)?references/' "$f" \
      && echo "review: reference loads another reference: $(basename "$f")"
  done
  for want in 'scope.js" classify' 'scope.js" pe-tiers' 'findings.js" validate' 'findings.js" dedup' \
              'review-file.js" verdict' 'review-file.js" gate2' 'review-file.js" render' 'review-file.js" parse'; do
    grep -qF -- "bin/$want" "$skill" "$refs"/*.md || echo "review: SKILL.md does not run $want"
    [ -f "$bin/${want%%\"*}" ] || echo "review: script missing: ${want%%\"*}"
  done
  for want in 'PE_ROUTING_TABLE' 'REVIEW_EXCLUDE_PATTERNS =' 'duplicate_key =' 'size_large     ='; do
    grep -qF -- "$want" "$skill" "$refs"/*.md && echo "review: algorithm restated in prose: $want"
  done
  # A review-doc commit runs CI like any other: [skip ci] would leave required checks pending on HEAD.
  grep -nE 'commit.* -m .*\[skip ci\]' "$skill" "$refs"/*.md | sed 's|^.*/skills/review/|review: review-doc commit skips CI: |'
}

# check_protocol_file <file> — the shared protocol follows the authoring standard itself.
check_protocol_file() {
  local f="$1"
  [ "$(wc -l < "$f")" -lt 500 ] || echo "protocol: body is $(wc -l < "$f") lines (limit 500)"
  grep -q '^## Contents' "$f" || echo "protocol: no table of contents"
  ticket_refs "$f" | sed 's|^|protocol: ticket narration: |'
}

# check_lean_agent <file> <pe> — a migrated agent carries only stack knowledge, as judgment.
check_lean_agent() {
  local f="$1" pe="$2" n
  grep -qF 'PE PROTOCOL' "$f" || echo "$pe: does not defer to the PE PROTOCOL"
  grep -nE '^## (Inputs|Workflow|Pass 4|Pass 5|Scope Discipline|Output Format|Constraints)|^### (Calibration Anchor|Common Lenses)|REPORTING BAR:|negative_receipt_proof:' "$f" \
    | sed "s|^|$pe: restates the PE protocol: |"
  n="$(wc -l < "$f")"; [ "$n" -lt 500 ] || echo "$pe: body is $n lines (limit 500)"
  ticket_refs "$f" | sed "s|^|$pe: ticket narration: |"
  # judgment names categories, never severities (pe-governance's own table is checked separately)
  [ "$pe" = pe-governance ] && return
  grep -nE '(^|[^A-Za-z])(CRITICAL|HIGH|MEDIUM|LOW|INFO)([^A-Za-z]|$)' "$f" \
    | sed "s|^|$pe: hard-coded severity in stack heuristics: |"
}

# check_agent_set <plugin-root> — every agent is named for its file, every hand-off names a PE that ships,
# pe-github-actions owns the workflows (pe-aws-infra hands them off) and keeps its five baseline checks.
check_agent_set() {
  local root="$1" f name want
  for want in pe-go pe-rust pe-vue pe-aws-infra pe-governance pe-csharp pe-angular pe-sql-server pe-github-actions \
              pe-devtools pe-general-purpose plan-reviewer; do
    [ -f "$root/agents/$want.md" ] || echo "agents: missing $want"
  done
  for f in "$root"/agents/*.md; do
    name="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm && /^name:/ {print $2; exit}' "$f")"
    [ "$name" = "$(basename "$f" .md)" ] || echo "$(basename "$f" .md): frontmatter name is '$name'"
    section "$f" '^## Owned Files and Hand-offs' | grep -oE '\| pe-[a-z-]+ \|[[:space:]]*$' | grep -oE 'pe-[a-z-]+' | sort -u \
      | while IFS= read -r want; do
          [ -f "$root/agents/$want.md" ] || echo "$(basename "$f" .md): hand-off to a missing PE: $want"
        done
  done
  f="$root/agents/pe-github-actions.md"
  [ -f "$f" ] || { echo "pe-github-actions: agent missing"; return; }
  section "$root/agents/pe-aws-infra.md" '^## Owned Files and Hand-offs' | grep -F '.github/workflows' | grep -vqF 'pe-github-actions' \
    && echo "pe-aws-infra: owns .github/workflows"
  sed -n '1,/^## /p' "$root/agents/pe-aws-infra.md" | grep -qF 'Does NOT review .github/workflows' \
    || echo "pe-aws-infra: description does not hand .github/workflows to pe-github-actions"
  section "$root/agents/pe-devtools.md" '^## Owned Files and Hand-offs' | grep -F '.github/workflows' | grep -vqF 'pe-github-actions' \
    && echo "pe-devtools: owns .github/workflows"
  for want in 'tests run on pull requests' 'full commit SHAs' 'least-privilege' 'OIDC' 'protected environment'; do
    block "$f" '^### Workflow baseline$' | grep -qF -- "$want" || echo "pe-github-actions: baseline missing: $want"
  done
}

# check_governance_standard <plugin-root> — pe-governance + lens 5 enforce the skill-authoring
# standard in both directions, and pe-governance itself follows it.
check_governance_standard() {
  local root="$1" s want row keys
  local f="$root/agents/pe-governance.md" pb="$root/skills/review/references/dispatch-playbook.md"
  local skill="$root/skills/review/SKILL.md"
  [ -f "$f" ] || { echo "pe-governance: agent missing"; return; }
  # its own body stays under the 500-line limit it enforces
  [ "$(wc -l < "$f")" -lt 500 ] || echo "pe-governance: body is $(wc -l < "$f") lines (limit 500)"
  # no ticket-history narration (finding/receipt ids like MEDIUM-001 are schema, not tickets)
  ticket_refs "$f" | sed 's|^|pe-governance: ticket narration: |'
  # judgment content names no severity: severities live only in Severity Definitions
  awk '/^---$/ && NR==1 {fm=1; next} fm && /^---$/ {fm=0; next} fm {next}
       /^## Severity Definitions/ {skip=1; next} /^## / {skip=0} !skip' "$f" \
    | grep -nE '(^|[^A-Za-z])(CRITICAL|HIGH|MEDIUM|LOW|INFO)([^A-Za-z]|$)' \
    | sed 's|^|pe-governance: hard-coded severity in judgment content: |'
  # one severity for both directions: the MEDIUM row, and only that row, names each
  s="$(section "$f" '^## Severity Definitions')"
  for want in 'prose' 'over-specif'; do
    row="$(printf '%s\n' "$s" | grep -i -- "$want" | grep '^|')"
    { [ -n "$row" ] && ! printf '%s\n' "$row" | grep -qv 'MEDIUM'; } \
      || echo "pe-governance: '$want' is not exactly one MEDIUM severity row"
  done
  for want in '500 lines' 'table of contents' 'one level deep' 'ticket' 'eval' 'costume' 'prose heuristic'; do
    section "$f" '^## Pass 2' | grep -qi -- "$want" || echo "pe-governance: authoring check missing: $want"
  done
  # lens 5 enforces the standard in both directions, in the text it dispatches
  [ -f "$pb" ] || return
  for want in 'over-specif' 'prose heuristic' 'eval'; do
    block "$pb" '^### 5[.]' | sed -n '/prompt augmentation:/,$p' | grep -qi -- "$want" \
      || echo "playbook: lens 5 missing: $want"
  done
  block "$pb" '^### 5[.]' | grep -qF 'Flag any prose decision tree that should' \
    && echo "playbook: lens 5 enforces one direction only"
  # every lens key the dispatch prompt injects has a playbook definition
  keys="$(sed -nE 's/^### [0-9]+[.] //p' "$pb")"
  sed -nE 's/.*LENS_AUGMENTATIONS\["([^"]+)"\].*/\1/p' "$skill" "$root"/skills/review/references/*.md | sort -u | while IFS= read -r want; do
    printf '%s\n' "$keys" | grep -qxF -- "$want" || echo "playbook: no lens definition for key: $want"
  done
}

# check_search_bounds <plugin-root> — search roots, tier budgets, out-of-bounds receipts.
check_search_bounds() {
  local root="$1" f pe p5 fmt t want
  local skill="$root/skills/review/SKILL.md" pb="$root/skills/review/references/dispatch-playbook.md"
  local proto="$root/skills/review/references/pe-protocol.md"
  local docs=("$skill" "$root"/skills/review/references/*.md)
  # AC1/AC2 — the Inputs contract bounds every pass by SEARCH_ROOTS below DEEP.
  section "$proto" '^## Inputs' | grep -qF 'SEARCH_ROOTS bounds every search and read in every pass' \
    || echo "protocol: Inputs missing search boundary"
  # AC3/AC4 — only the PE's own absence needs proof; an out-of-bounds doc claim is indeterminate.
  p5="$(section "$proto" '^## Pass 5')"
  for want in 'absence       = YOUR OWN assertion' 'missing_source: <that system>' \
              'below DEEP, its source outside SEARCH_ROOTS'; do
    printf '%s' "$p5" | grep -qF -- "$want" || echo "protocol: Pass 5 missing: $want"
  done
  section "$proto" '^## Output Format' | grep -qF 'missing_source:' || echo "protocol: Output Format missing missing_source:"
  for f in "$proto" "$root"/agents/pe-*.md; do
    pe="$(basename "$f" .md)"; [ "$f" = "$proto" ] && pe=protocol
    grep -nE 'entire (workspace|solution)' "$f" | sed "s|^|$pe: unbounded workspace sweep: |"
  done
  grep -qE 'Flag unverified claims about runtime behavior → MEDIUM$' "$root/agents/pe-governance.md" \
    && echo "pe-governance: claim_verification promotes out-of-bounds claims"
  section "$root/agents/pe-governance.md" '^## Pass 3' | grep -qF 'below DEEP, an artifact outside SEARCH_ROOTS →' \
    || echo "pe-governance: claim_verification lacks the out-of-bounds indeterminate route"
  grep -qF 'any repository that calls this' "$root/agents/pe-github-actions.md" \
    && echo "pe-github-actions: unbounded reusable-workflow caller search"

  # AC5 — TRIVIAL/STANDARD carry a concrete budget and no open-ended widening.
  [ -f "$pb" ] || { echo "playbook: dispatch-playbook.md missing"; return; }
  for t in TRIVIAL STANDARD; do
    block "$pb" "^### $t\$" | grep -qF 'Budget: at most' || echo "playbook: $t has no budget"
  done
  grep -qF 'unless verifying a specific finding requires it' "$pb" && echo "playbook: STANDARD escape hatch"
  for want in 'SEARCH_ROOTS is a hard boundary' 'Never run find or grep -r'; do
    block "$pb" '^### Search Boundary' | grep -qF -- "$want" || echo "playbook: Search Boundary missing: $want"
  done

  # AC2/AC3 — the skill resolves + dispatches roots, appends the boundary below DEEP, never promotes OOB.
  for want in 'SEARCH_ROOTS:   {session.search_roots' '"searchRoots"' \
              '+ SEARCH_BOUNDARY  for t in [TRIVIAL, STANDARD]' 'and not out_of_bounds(reply)' \
              'path is an ancestor of repo_root or path == user_home or path is a filesystem/drive root' \
              'out_of_bounds(r) = r.claim == "indeterminate" AND r.missing_source is non-empty' \
              'below DEEP, a claim a reviewed document makes' \
              'TIER_CONTRACT:  {TIER_CONTRACTS[tier]}'; do
    grep -qF -- "$want" "${docs[@]}" || echo "review: SKILL.md missing: $want"
  done
  # escalation must re-key the contract (boundary + budget) on the new tier, not the PE's original one
  grep -qF 'DISPATCH_PROMPT(pe) with TIER=' "${docs[@]}" && echo "review: escalation keeps the original tier's contract"
  # both escalation sites hand the NEW tier to DISPATCH_PROMPT (re-spawn and live re-dispatch)
  grep -qF 'prompt = DISPATCH_PROMPT(pe, tier = new_tier))' "${docs[@]}" \
    || echo "review: escalation re-spawn drops the new tier"
  grep -qF 'SendMessage(to: name, DISPATCH_PROMPT(pe, tier = new_tier))' "${docs[@]}" \
    || echo "review: escalation re-dispatch drops the new tier"
  # every Collect re-spawn goes through respawn(), which keeps the teammate's CURRENT tier
  for want in 't = session.pe_dispatch[new].tier' 'model = model_for_tier(t) unless OMIT' \
              'prompt = DISPATCH_PROMPT(session.by_name[name], tier = t)'; do
    docs_block '^#+ Collect' "${docs[@]}" | grep -qF -- "$want" || echo "review: crash re-spawn drops an escalated tier: $want"
  done
  docs_block '^#+ Collect' "${docs[@]}" | grep -F '(re-dispatch)' | grep -vF 'respawn(name)' \
    | sed 's|^|review: (re-dispatch) option bypasses respawn(): |'
  docs_section '^## YAML Schema' "${docs[@]}" | grep -qE '^[[:space:]]+missing_source:' \
    || echo "review: schema missing receipt missing_source: field"
}

# --- the real tree satisfies the contract ---
out="$(check_tree "$PLUGIN")"
if [ -z "$out" ]; then pass "plugin tree satisfies the PE reporting-bar contract"
else fail "contract violations:"$'\n'"$out"; fi

# Trigger accuracy (real tree only): the review description keeps every trigger phrase.
desc="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm' "$PLUGIN/skills/review/SKILL.md")"
miss=""
grep -qxF 'name: review' <<<"$desc" || miss="$miss name"
for want in '"review my branch"' '"review PR #N"' '"code review"' '"/sdlc:review"' 'invokes review via the deliver orchestrator'; do
  grep -qF -- "$want" <<<"$desc" || miss="$miss $want"
done
if [ -z "$miss" ]; then pass "review frontmatter keeps every trigger phrase"; else fail "review frontmatter lost:$miss"; fi

# --- mutation cases: each injected regression must be caught ---
WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; wait; rm -rf "$WORK"' EXIT

# sedall <sed-expr> / grepvall <literal> — edit SKILL.md and every review reference, wherever the text now lives.
sedall() { local f; for f in skills/review/SKILL.md skills/review/references/*.md; do sed "$1" "$f" > "$f.t" && mv "$f.t" "$f"; done; }
grepvall() { local f; for f in skills/review/SKILL.md skills/review/references/*.md; do grep -vF -- "$1" "$f" > "$f.t"; mv "$f.t" "$f"; done; }

# copy_tree <dir> — a copy of every part of the plugin tree check_tree reads.
copy_tree() {
  local dir="$1"
  mkdir -p "$dir/skills/review"
  cp -R "$PLUGIN/agents" "$dir/agents"
  cp "$PLUGIN/skills/review/SKILL.md" "$dir/skills/review/SKILL.md"
  mkdir -p "$dir/skills/deliver" && cp "$PLUGIN/skills/deliver/SKILL.md" "$dir/skills/deliver/SKILL.md"
  cp -R "$PLUGIN/assets" "$dir/assets"
  cp "$PLUGIN/README.md" "$dir/README.md"
  cp -R "$PLUGIN/skills/review/references" "$dir/skills/review/references"
  cp -R "$PLUGIN/skills/review/bin" "$dir/skills/review/bin"
  cp -R "$PLUGIN/references" "$dir/references"
}

# Mutation cases are independent (each edits its own copy of the tree), so they run in the background,
# PE_TEST_JOBS at a time (default: the CPU count); each writes one PASS:/FAIL: line, and collect_cases
# folds them into the totals in the order they were declared.
CASE_JOBS="${PE_TEST_JOBS:-}"
[ -n "$CASE_JOBS" ] || CASE_JOBS="$( { nproc || sysctl -n hw.ncpu; } 2>/dev/null )"
case "$CASE_JOBS" in ''|*[!0-9]*|0) CASE_JOBS=2 ;; esac
RES="$WORK/results"; mkdir -p "$RES"
case_n=0
# spawn <PASS-line> <FAIL-line> <want: present|absent> <needle> <snippet> — run one case in the background
spawn() {
  local ok="$1" bad="$2" want="$3" needle="$4" snippet="$5" dir out
  case_n=$((case_n + 1)); dir="$WORK/case$case_n"; out="$RES/$(printf '%04d' "$case_n")"
  while [ "$(jobs -rp | wc -l)" -ge "$CASE_JOBS" ]; do sleep 0.05; done
  (
    copy_tree "$dir"
    ( cd "$dir" && eval "$snippet" )
    if grep -qF -- "$needle" <<<"$(check_tree "$dir")"; then hit=present; else hit=absent; fi
    if [ "$hit" = "$want" ]; then echo "PASS: $ok" > "$out"; else echo "FAIL: $bad" > "$out"; fi
  ) > "$out.log" 2>&1 &
}
# collect_cases — wait for every background case, then count each in declaration order. A case's verdict is in
# $RES/NNNN, its other output in $RES/NNNN.log, printed under a failure so the cause is in the log.
collect_cases() {
  local n f line
  wait
  for n in $(seq 1 "$case_n"); do
    f="$RES/$(printf '%04d' "$n")"
    line="$(cat "$f" 2>/dev/null)"
    case "$line" in
      "PASS: "*) pass "${line#PASS: }" ;;
      "FAIL: "*) fail "${line#FAIL: }"; sed 's/^/    | /' "$f.log" ;;
      *) fail "case $n wrote no verdict"; sed 's/^/    | /' "$f.log" 2>/dev/null ;;
    esac
  done
}

# mutant <name> <shell snippet run inside a copy of the tree> <expected substring in check output>
mutant() { spawn "mutation caught: $1" "mutation NOT caught: $1 (expected '$3')" present "$3" "$2"; }

# allowed <name> <shell snippet run inside a copy of the tree> <substring check output must NOT contain>
allowed() { spawn "allowed: $1" "false positive: $1 ('$3')" absent "$3" "$2"; }

mutant capitalized-valve \
  'printf "\nDowngrade to INFO when unsure.\n" >> agents/pe-go.md' 'pe-go: severity-downgrade valve'
mutant demote-stem \
  'printf "\nif unverifiable: demote to INFO\n" >> agents/pe-go.md' 'pe-go: severity-downgrade valve'
mutant silent-drop-valve \
  'printf "\n      if cannot verify → remove\n" >> agents/pe-vue.md' 'pe-vue: unverifiable valve drops'
mutant evidence-moved-out-of-output-format \
  'awk "/^## Output Format/{on=1} /^## Constraints/{on=0} !(on && /evidence:/)" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md && printf "\n- evidence: note\n" >> skills/review/references/pe-protocol.md' \
  'protocol: Output Format missing evidence:'
mutant bar-only-outside-pass-5 \
  'awk "/^## Pass 5/{on=1} /^## Scope Discipline/{on=0} !(on && /REPORTING BAR/)" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: Pass 5 missing: REPORTING BAR'
mutant protocol-not-read \
  'grepvall "PE_PROTOCOL        = read"' \
  'review: SKILL.md does not read the PE protocol'
mutant moves-not-read \
  'grepvall "REVIEW_MOVES       = read"' \
  'review: SKILL.md does not read the review moves'
mutant moves-not-dispatched \
  'sedall "s/{REVIEW_MOVES}//"' \
  'review: dispatch prompt does not inline the review moves'
mutant moves-coverage-not-asked \
  'grep -vF "moves_coverage:" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: Output Format missing moves_coverage:'
mutant move-dropped \
  'grep -vF "| M6 Falsify the test |" skills/review/references/review-moves.md > t && mv t skills/review/references/review-moves.md' \
  'moves: M6 Falsify the test missing from the move table'
mutant fix-diff-not-dispatched \
  'sedall "s/FIX DIFF:/FIX:/"' \
  'review: dispatch prompt does not carry FIX DIFF'
mutant prior-ids-not-validated \
  'sedall "s/, prior_ids: session.prior_ids}/}/"' \
  'review: validate does not get the prior round'"'"'s ids'
mutant preflight-dropped \
  'sedall "s/; if v.gating: print review-moves.md § Remediation Pre-flight[^#]*//"' \
  'review: a round with gating findings does not print the remediation pre-flight'
mutant finding-keys-dropped \
  'sedall "s/^## Finding Keys$/## Keys/"' \
  'moves: ## Finding Keys missing'
mutant protocol-not-dispatched \
  'sedall "s/{PE_PROTOCOL}//"' \
  'review: dispatch prompt does not inline the PE protocol'
# lean agents carry stack knowledge only, as judgment
mutant agent-restates-protocol \
  'printf "\n### Calibration Anchor\n" >> agents/pe-general-purpose.md' 'pe-general-purpose: restates the PE protocol'
mutant agent-restates-bar \
  'printf "\nREPORTING BAR: is it real?\n" >> agents/pe-general-purpose.md' 'pe-general-purpose: restates the PE protocol'
mutant agent-drops-protocol-pointer \
  'sed "s/PE PROTOCOL/protocol/g" agents/pe-general-purpose.md > t && mv t agents/pe-general-purpose.md' \
  'pe-general-purpose: does not defer to the PE PROTOCOL'
mutant agent-flag-trigger \
  'printf "\n- an unquoted variable: flag HIGH\n" >> agents/pe-general-purpose.md' \
  'pe-general-purpose: hard-coded severity in stack heuristics'
mutant agent-oversize \
  'seq 1 500 >> agents/pe-general-purpose.md' 'pe-general-purpose: body is'
mutant agent-narration \
  'printf "\n- added in ABC-1790\n" >> agents/pe-general-purpose.md' 'pe-general-purpose: ticket narration'
mutant agent-issue-narration \
  'printf "\n- added in #4321\n" >> agents/pe-go.md' 'pe-go: ticket narration'
mutant agent-two-digit-issue-narration \
  'printf "\n- since #20 merged (a regression from #17)\n" >> agents/pe-go.md' 'pe-go: ticket narration'
mutant agent-adjacent-issue-narration \
  'printf "\n- this reverts #20 #17\n" >> agents/pe-go.md' ':#17'
mutant agent-glued-issue-narration \
  'printf "\n- see ##30 and #20#17\n" >> agents/pe-go.md' ':#20'
allowed agent-glued-issue-second \
  'printf "\n- see ##30 and #20#17\n" >> agents/pe-go.md' ':#17'
allowed agent-doubled-hash \
  'printf "\n- see ##30 and #20#17\n" >> agents/pe-go.md' ':#30'
mutant review-reference-issue-narration \
  'printf "\n(fixed in #4321)\n" >> skills/review/references/checkout.md' 'review: ticket narration: references/'
allowed agent-entity-and-colour \
  'printf "\n- an em dash &#8212; and the colour #5319e7\n" >> agents/pe-go.md' 'pe-go: ticket narration'
allowed agent-placeholder-keys \
  'printf "\n- a branch such as feat/42-add-login, feat/LT-02-tuner, #123, #1234, ABC-1234\n" >> agents/pe-go.md' 'pe-go: ticket narration'
allowed shared-placeholder-keys \
  'printf "\nCloses #1234 (story LT-02, ticket ABC-123)\n" >> references/settings.md' 'shared: ticket narration'
# the agent set: every expert ships, names match files, hand-offs reach shipped PEs, workflows belong to pe-github-actions
mutant expert-missing \
  'mv agents/pe-sql-server.md agents/pe-sql-server.md.off' 'agents: missing pe-sql-server'
mutant agent-name-drift \
  'sed "s/^name: pe-go$/name: pe-golang/" agents/pe-go.md > t && mv t agents/pe-go.md' "pe-go: frontmatter name is 'pe-golang'"
mutant handoff-to-dropped-pe \
  'sed "s/| pe-go |\$/| pe-retired |/" agents/pe-github-actions.md > t && mv t agents/pe-github-actions.md' \
  'pe-github-actions: hand-off to a missing PE: pe-retired'
mutant aws-infra-owns-workflows \
  'sed "s|^This PE owns |This PE owns .github/workflows/*.yml, |" agents/pe-aws-infra.md > t && mv t agents/pe-aws-infra.md' \
  'pe-aws-infra: owns .github/workflows'
mutant devtools-owns-workflows \
  'sed "s|^This PE owns |This PE owns .github/workflows/**, |" agents/pe-devtools.md > t && mv t agents/pe-devtools.md' \
  'pe-devtools: owns .github/workflows'
mutant aws-infra-description-claims-workflows \
  'sed "s/Does NOT review .github\/workflows/Also reviews .github\/workflows/" agents/pe-aws-infra.md > t && mv t agents/pe-aws-infra.md' \
  'pe-aws-infra: description does not hand .github/workflows'
mutant github-actions-baseline-check-dropped \
  'grep -vF "authenticate with OIDC rather than" agents/pe-github-actions.md > t && mv t agents/pe-github-actions.md' \
  'pe-github-actions: baseline missing: OIDC'
mutant github-actions-restates-protocol \
  'printf "\n## Output Format\n" >> agents/pe-github-actions.md' 'pe-github-actions: restates the PE protocol'
mutant github-actions-flag-trigger \
  'printf "\n- an unpinned action: flag CRITICAL\n" >> agents/pe-github-actions.md' \
  'pe-github-actions: hard-coded severity in stack heuristics'
mutant protocol-oversize \
  'seq 1 500 >> skills/review/references/pe-protocol.md' 'protocol: body is'

# negative guards: re-inject each retired literal and assert its guard fires
mutant unchecked-receipts \
  'echo "accept without recommendation check (positive attestations, no gating)" >> skills/review/SKILL.md' \
  'review: Phase 4 still accepts every receipt unchecked'
mutant keyword-classifier \
  'echo "NEGATIVE_CLAIM" >> skills/review/SKILL.md' 'review: keyword regex still classifies receipts'
mutant relabel-accepted \
  'echo "re-classified by its producer" >> skills/review/SKILL.md' 'review: proof check accepts a relabelled unproven receipt'
mutant low-row-gates \
  'printf "| 🟢 LOW | Style | ⚠️ CHANGES REQUESTED (gate-locks) |\n" >> skills/review/SKILL.md' 'review: LOW/INFO severity rows still gate'
mutant verdict-low-gates \
  'printf "elif any in-scope LOW:      verdict = x\n" >> skills/review/SKILL.md' 'review: LOW/INFO still gate the verdict'
mutant anchor-every-severity-gates \
  'awk "{print} /^  REPORTING BAR:/{print \"  Every finding gates at ANY severity.\"}" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'anchor: claims every severity gates'
mutant medium-demotable \
  'grepvall "MEDIUM is never demoted here"' \
  'review: severity adjustment can demote a MEDIUM into advisory'
mutant advisory-replaces-in-scope \
  'sedall "s/every finding keeps its full entry under § In Scope Findings/x/"' \
  'review: Advisory Findings can replace In Scope entries'
# an unproven receipt stays a non-gating below_bar receipt carrying its original claim — never dropped or promoted
mutant unproven-receipt-dropped \
  'sedall "s/replace receipt in snapshot.verification_receipts, preserving id, title, location and category:/remove receipt from snapshot.verification_receipts/" && grepvall "claim: below_bar " && grepvall "Absence unproven after one re-dispatch"' \
  'review: unproven absence receipt is not kept in the receipt list'
mutant unproven-receipt-repromoted \
  'printf "      append to consolidated:\n        severity: MEDIUM, category: correctness\n        title: Unproven safety claim: {receipt.title}\n      remove receipt from snapshot.verification_receipts\n" > ins && awk "/replace receipt in snapshot.verification_receipts, preserving/{while ((getline l < \"ins\") > 0) print l; next} /claim: below_bar |Absence unproven after one re-dispatch/{next} {print}" skills/review/references/legitimacy-gate.md > t && mv t skills/review/references/legitimacy-gate.md' \
  'review: unproven receipt re-promoted to a finding'
mutant unproven-receipt-also-gates \
  'awk "{print} /Absence unproven after one re-dispatch/{print \"      append to consolidated: severity: MEDIUM, title: {receipt.title}\"}" skills/review/references/legitimacy-gate.md > t && mv t skills/review/references/legitimacy-gate.md' \
  'review: unproven receipt is promoted or dropped'
mutant unproven-receipt-relabelled \
  'sedall "s/claim: below_bar /claim: positive  /"' 'review: unproven absence receipt is not retained as below_bar'
mutant unproven-receipt-loses-claim \
  'sedall "s/ Original claim: {receipt.attestation}//"' 'review: unproven receipt loses its original claim'
# a receipt's presence is not proof; a finding lacking proof is kept as a receipt with its claim and missing proof
mutant per-finding-presence-only \
  'sedall "s/it is missing or does not prove the actual problem:/it is missing or empty:/"' \
  'review: per-finding check accepts a receipt that proves no problem'
mutant per-finding-drops \
  'sedall "s/move finding to verification_receipts\[\]/& OR drop/"' \
  'review: a finding lacking proof can be dropped instead of kept as a receipt'
mutant schema-row-drops \
  'sedall "s/never dropped; disproven/OR drop; disproven/"' \
  'review: a finding lacking proof can be dropped instead of kept as a receipt'
mutant per-finding-loses-claim \
  'grepvall "preserve the original claim and missing proof"' \
  'review: per-finding check loses the original claim or missing proof'
# severity adjustment re-rates a proven finding only within the gate; missing proof is never kept by lowering severity
mutant severity-adjust-unbounded \
  'sedall "s/adjust to that level, never below MEDIUM,/adjust to that level,/"' \
  'review: severity adjustment can lower a proven HIGH/CRITICAL into advisory'
mutant severity-adjust-keeps-unproven \
  'sedall "s/; do not retain by lowering severity//"' \
  'review: severity adjustment can keep an unproven finding by lowering its severity'
mutant blocking-bar \
  'printf "\nREPORTING BAR: would a senior reviewer block this PR on it?\n" >> agents/pe-go.md' 'blocking-only REPORTING BAR'
mutant pass5-downgrade \
  'awk "{print} /^  severity_honesty:/{print \"    if no to both: downgrade\"}" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: Pass 5 severity_honesty says downgrade'
mutant severity-one-level-lower \
  'sed "s/it is MEDIUM or below; rate it from Severity Definitions/rate it one level lower in Severity Definitions/" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: Pass 5 severity_honesty says one level lower'
mutant readme-blocking-bar \
  'printf "\nPEs report only what a senior reviewer would block the PR on.\n" >> README.md' 'blocking-only REPORTING BAR'
mutant receipt-edit-recommendation \
  "echo \"record the command + output as the receipt's evidence\" >> skills/review/SKILL.md" \
  'review: promoted finding asks the author to edit a reviewer-owned receipt'

# search boundary guards
mutant workspace-sweep \
  'printf "\n    grep the entire workspace for consumers\n" >> agents/pe-angular.md' 'pe-angular: unbounded workspace sweep'
mutant inputs-boundary-dropped \
  'sed "s/SEARCH_ROOTS bounds every search and read in every pass//" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: Inputs missing search boundary'
mutant own-absence-dropped \
  'sed "s/YOUR OWN assertion/assertion/" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' 'protocol: Pass 5 missing: absence       = YOUR OWN'
mutant governance-promotes-oob \
  'printf "\n  - Flag unverified claims about runtime behavior → MEDIUM\n" >> agents/pe-governance.md' \
  'pe-governance: claim_verification promotes out-of-bounds claims'
mutant standard-escape-hatch \
  'echo "unless verifying a specific finding requires it" >> skills/review/references/dispatch-playbook.md' \
  'playbook: STANDARD escape hatch'
mutant budget-missing \
  'awk "/^### TRIVIAL\$/{on=1} /^### STANDARD\$/{on=0} !(on && /Budget: at most/)" skills/review/references/dispatch-playbook.md > t && mv t skills/review/references/dispatch-playbook.md' \
  'playbook: TRIVIAL has no budget'
mutant oob-relabel-promoted \
  'sedall "s/ and not out_of_bounds(reply)//"' \
  'review: SKILL.md missing: and not out_of_bounds(reply)'
mutant dispatch-roots-dropped \
  'grepvall "SEARCH_ROOTS:   {session.search_roots"' \
  'review: SKILL.md missing: SEARCH_ROOTS:   {session.search_roots'
mutant root-rejection-dropped \
  'grepvall "is an ancestor of repo_root"' \
  'review: SKILL.md missing: path is an ancestor of repo_root'
mutant oob-ignores-missing-source \
  'sedall "s/ AND r.missing_source is non-empty//"' \
  'review: SKILL.md missing: out_of_bounds(r) ='
mutant governance-oob-route-reworded \
  'sed "s/below DEEP, an artifact outside SEARCH_ROOTS →/anything →/" agents/pe-governance.md > t && mv t agents/pe-governance.md' \
  'pe-governance: claim_verification lacks the out-of-bounds indeterminate route'
mutant github-actions-caller-sweep \
  'printf "\nsearch any repository that calls this reusable workflow\n" >> agents/pe-github-actions.md' \
  'pe-github-actions: unbounded reusable-workflow caller search'
mutant escalation-keeps-old-contract \
  'echo "DISPATCH_PROMPT(pe) with TIER=new_tier" >> skills/review/SKILL.md' "review: escalation keeps the original tier's contract"
mutant pass5-deep-qualifier-dropped \
  'sed "s/below DEEP, its source outside/its source outside/" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: Pass 5 missing: below DEEP, its source outside SEARCH_ROOTS'
mutant retry-drops-escalation \
  'sedall "s/DISPATCH_PROMPT(session.by_name\[name\], tier = t)/DISPATCH_PROMPT(session.by_name[name])/"' \
  'review: crash re-spawn drops an escalated tier'
mutant escalation-respawn-bare \
  'sedall "s/prompt = DISPATCH_PROMPT(pe, tier = new_tier))/prompt = DISPATCH_PROMPT(pe))/"' \
  'review: escalation re-spawn drops the new tier'
mutant escalation-redispatch-bare \
  'sedall "s/SendMessage(to: name, DISPATCH_PROMPT(pe, tier = new_tier))/SendMessage(to: name, DISPATCH_PROMPT(pe))/"' \
  'review: escalation re-dispatch drops the new tier'
mutant retry-tier-from-pe-tier \
  'sedall "s/t = session.pe_dispatch\[new\].tier/t = pe_tier(session.by_name[name])/"' \
  'review: crash re-spawn drops an escalated tier: t = session.pe_dispatch[new].tier'
mutant redispatch-bypasses-respawn \
  'awk "/^#+ Collect/{on=1} on && /\\(re-dispatch\\)/{sub(/ respawn\\(name\\)/, \"\")} {print}" skills/review/references/dispatch-and-collect.md > t && mv t skills/review/references/dispatch-and-collect.md' \
  'review: (re-dispatch) option bypasses respawn()'
# skill-authoring standard — pe-governance and lens 5
mutant governance-oversize \
  'seq 1 400 >> agents/pe-governance.md' 'pe-governance: body is'
mutant governance-narration \
  'printf "\n- missing tool (the #995 bug class)\n" >> agents/pe-governance.md' 'pe-governance: ticket narration'
mutant governance-story-narration \
  'printf "\n- added in ABC-1790 for story 04\n" >> agents/pe-governance.md' 'pe-governance: ticket narration'
mutant governance-flag-trigger \
  'awk "{print} /^## Pass 1/{print \"flag prose decision trees as LOW\"}" agents/pe-governance.md > t && mv t agents/pe-governance.md' \
  'pe-governance: hard-coded severity in judgment content'
mutant governance-lens-trigger \
  'awk "{print} /^### Stack-Specific/{print \"  if costume: flag HIGH\"}" agents/pe-governance.md > t && mv t agents/pe-governance.md' \
  'pe-governance: hard-coded severity in judgment content'
mutant governance-crossverify-trigger \
  'awk "{print} /^## Cross-verification/{print \"- a stale cross-reference: flag HIGH\"}" agents/pe-governance.md > t && mv t agents/pe-governance.md' \
  'pe-governance: hard-coded severity in judgment content'
mutant governance-filepatterns-trigger \
  'awk "{print} /^## File Patterns/{print \"A README drift is LOW.\"}" agents/pe-governance.md > t && mv t agents/pe-governance.md' \
  'pe-governance: hard-coded severity in judgment content'
mutant protocol-drops-is-pattern \
  'grep -v "is_pattern:" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: Output Format missing is_pattern:'
mutant protocol-read-unchecked \
  'grepvall "if PE_PROTOCOL is empty or lacks"' \
  'review: dispatch does not stop on an empty or unreadable PE protocol'
mutant governance-severity-drift \
  'LC_ALL=C awk "{print} /^\\|[^|]*MEDIUM[[:space:]]*\\|/{print \"| LOW | prose decision tree |\"}" agents/pe-governance.md > t && mv t agents/pe-governance.md' \
  "pe-governance: 'prose' is not exactly one MEDIUM severity row"
mutant governance-toc-check-dropped \
  'grep -v "has no table of contents near the top" agents/pe-governance.md > t && mv t agents/pe-governance.md' \
  'pe-governance: authoring check missing: table of contents'
# shellcheck disable=SC2016  # the awk program is literal; eval expands it in the mutant dir
mutant governance-eval-check-dropped \
  'awk "/^\\*\\*Eval coverage\\.\\*\\*/ {skip=1} skip && /^\\\`\\\`\\\`\$/ {if (++f == 2) {skip=0; next}} !skip" agents/pe-governance.md > t && mv t agents/pe-governance.md' \
  'pe-governance: authoring check missing: eval'
mutant lens5-one-way \
  'awk "{print} /^### 5\\./{print \"Flag any prose decision tree that should be pseudocode.\"}" skills/review/references/dispatch-playbook.md > t && mv t skills/review/references/dispatch-playbook.md' \
  'playbook: lens 5 enforces one direction only'
mutant lens5-overspec-dropped \
  'grep -v "^   Over-specified: judgment written" skills/review/references/dispatch-playbook.md > t && mv t skills/review/references/dispatch-playbook.md' \
  'playbook: lens 5 missing: over-specif'
mutant lens-key-drift \
  'sed "s/^### 5\\. .*/### 5. renamed-lens/" skills/review/references/dispatch-playbook.md > t && mv t skills/review/references/dispatch-playbook.md' \
  'playbook: no lens definition for key:'
mutant governance-oob-route-moved \
  'grep -vF "below DEEP, an artifact outside SEARCH_ROOTS →" agents/pe-governance.md > t && mv t agents/pe-governance.md && printf "\nbelow DEEP, an artifact outside SEARCH_ROOTS → indeterminate\n" >> agents/pe-governance.md' \
  'pe-governance: claim_verification lacks the out-of-bounds indeterminate route'

# review SKILL.md stays an orchestration overview over tested scripts
mutant skill-oversize \
  'seq 1 100 >> skills/review/SKILL.md' 'review: SKILL.md body is'
mutant skill-narration \
  'printf "\n- added in ABC-1790\n" >> skills/review/SKILL.md' 'review: ticket narration'
# shellcheck disable=SC2016  # the literal ${CLAUDE_PLUGIN_ROOT} is the text under test
mutant reference-without-toc \
  'seq 1 120 > skills/review/references/extra.md && echo "\${CLAUDE_PLUGIN_ROOT}/skills/review/references/extra.md" >> skills/review/SKILL.md' \
  'review: no table of contents: extra.md'
mutant reference-unloaded \
  'grepvall "skills/review/references/dispatch-and-collect.md"' 'review: reference not loaded from SKILL.md: dispatch-and-collect.md'
# shellcheck disable=SC2016
mutant reference-routes-reference \
  'echo "read \${CLAUDE_PLUGIN_ROOT}/skills/review/references/pe-protocol.md" >> skills/review/references/publish.md' \
  'review: reference loads another reference: publish.md'
# shellcheck disable=SC2016
mutant reference-routes-reference-capitalised \
  'echo "Read \`\${CLAUDE_PLUGIN_ROOT}/skills/review/references/pe-protocol.md\` first." >> skills/review/references/publish.md' \
  'review: reference loads another reference: publish.md'
# shellcheck disable=SC2016
mutant reference-routes-reference-loads \
  'echo "LOADS \${CLAUDE_PLUGIN_ROOT}/references/settings.md" >> skills/review/references/checkout.md' \
  'review: reference loads another reference: checkout.md'
mutant script-call-dropped \
  'grepvall "bin/findings.js\" dedup"' 'review: SKILL.md does not run findings.js" dedup'
mutant routing-table-restated \
  'echo "PE_ROUTING_TABLE:" >> skills/review/SKILL.md' 'review: algorithm restated in prose: PE_ROUTING_TABLE'

mutant shared-narration \
  'printf "\n(added in ABC-1790)\n" >> references/settings.md' 'shared: ticket narration: references/settings.md'
mutant shared-issue-narration \
  'printf "\n(fixed in #4321)\n" >> assets/slack-templates.md' 'shared: ticket narration: assets/slack-templates.md'
mutant shared-ac-label \
  'printf "\n# Fresh fetch (AC1): compare\n" >> references/version-collision-guard.md' 'shared: ticket narration: references/version-collision-guard.md'
mutant shared-plural-story \
  'printf "\n(templates in stories 04-07)\n" >> references/settings.md' 'shared: ticket narration: references/settings.md'
mutant shared-toc-missing \
  'seq 1 120 > references/extra.md' 'shared: no table of contents: references/extra.md'

mutant review-doc-skip-ci \
  'echo "    git commit -m \"docs: {name} code-review\" -m \"[skip ci]\"" >> skills/review/SKILL.md' \
  'review: review-doc commit skips CI'
allowed review-doc-never-skips-ci \
  'echo "The review-doc commit never carries [skip ci]." >> skills/review/SKILL.md' 'review: review-doc commit skips CI'

mutant angular-prod-build \
  'awk '"'"'{print} /^npx ng lint$/{print "npx ng build --configuration=production"}'"'"' agents/pe-angular.md > t && mv t agents/pe-angular.md' \
  'pe-angular: production build command'
mutant angular-build-prod-script \
  'awk '"'"'{print} /^npx ng lint$/{print "npm run build:prod"}'"'"' agents/pe-angular.md > t && mv t agents/pe-angular.md' \
  'pe-angular: production build command'
mutant angular-prod-fallback \
  'printf "\nWhen the configuration is unknown, run the build:prod npm script instead.\n" >> agents/pe-angular.md' \
  'pe-angular: build:prod fallback'
mutant vue-bare-generate \
  'awk '"'"'{print} /^npm run typecheck && npm test$/{print "npm run generate"}'"'"' agents/pe-vue.md > t && mv t agents/pe-vue.md' \
  'pe-vue: builds outside the BUILD PLAN'
mutant dispatch-build-root-dropped \
  'grepvall "BUILD ROOT:     {session.build_root_line}"' 'review: dispatch missing: BUILD ROOT:'
mutant build-scratch-not-a-search-root \
  'grepvall "session.search_roots += [session.build_scratch]"' 'review: dispatch missing: session.search_roots += [session.build_scratch]'
mutant build-scratch-not-released \
  'grepvall "bin/build-plan.js\" release"' 'review: round teardown does not release the build scratch directory'
mutant plan-builds-dropped \
  'sedall "s/, \"builds\": \"{session.builds, else worktree}\"//"' 'review: dispatch missing: "builds": "{session.builds, else worktree}"'
mutant plan-mode-dropped \
  'sedall "s/, \"mode\": \"{mode}\"//"' 'review: dispatch missing: "mode": "{mode}"'
mutant builds-auto-prompts \
  'sedall "s/elif session.auto:/elif False:/"' 'review: --auto does not build in a disposable worktree'
mutant builds-choice-dropped \
  'grepvall "(checkout) \"My checkout, no install"' 'review: build choice missing: (checkout)'
mutant builds-flag-dropped \
  'grepvall "the value after \"--builds\""' 'review: no --builds flag'
mutant builds-not-remembered \
  'grepvall "config --get \"branch.{branch}.sdlcReviewBuilds\""' 'review: build choice not remembered per branch'
mutant builds-not-saved \
  'grepvall "config \"branch.{branch}.sdlcReviewBuilds\" \"{session.builds}\""' 'review: build choice not remembered per branch'
mutant deliver-builds-dropped \
  'sed "s/, session.builds_arg//" skills/deliver/SKILL.md > t && mv t skills/deliver/SKILL.md' 'deliver: --builds not threaded to review'
mutant direction-after-yaml \
  'sedall "s/first line is \"build_direction\"/first line is \"build-direction\"/"' 'review: build_direction is not matched before YAML findings'
mutant direction-object \
  'sedall "s/message: \"build_direction answer: {answer}\"/message: {type: \"build_direction\", answer: answer}/"' 'review: build_direction sent as an object SendMessage rejects'
mutant branch-unchecked \
  'grepvall "branch_ok = branch"' 'review: branch name reaches git config unchecked'
mutant checks-skip-unrendered \
  'sedall "s/{[^}]*p.checks == .skip. else ..}//"' 'review: BUILD PLAN line never shows checks: skip'
mutant checks-skip-dropped \
  'sed "s/ An entry with .checks: skip. also skips[^.]*; record a receipt with its reason, not a failing command\.//" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: checks: skip does not stop tests in a checkout without node_modules'
mutant branch-read-unguarded \
  'sedall "s/ if branch_ok else \"\"//"' 'review: a git config call skips the branch_ok guard'
mutant branch-write-unguarded \
  'sedall "s/if branch_ok and session.builds != remembered/if session.builds != remembered/"' 'review: a git config call skips the branch_ok guard'
mutant fe-by-routing \
  'grepvall "bin/build-plan.js\" detect"' 'review: front-end decided by PE routing, not by the project'
mutant direction-single-option \
  'grepvall "(skip-all) \""' 'review: build-direction question has a single option'
mutant remembered-silent \
  'grepvall "remembered for {branch}"' 'review: remembered build choice applied silently'
mutant swept-silent \
  'grepvall "if r.swept:"' 'review: dispatch missing: if r.swept:'
# shellcheck disable=SC2016 # literal backticks
mutant protocol-checkout-any-build \
  'sed "s/run only a \`run\` entry/run any entry/" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  "protocol: engineer's checkout runs more than run entries"
mutant protocol-install-rule-dropped \
  'sed "s/Never run an install/Run an install/" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: no rule against installs in the checkout'
mutant angular-npm-ci-unguarded \
  'sed "s/^npm ci .*/npm ci/" agents/pe-angular.md > t && mv t agents/pe-angular.md' 'pe-angular: installs without the BUILD ROOT guard'
mutant vue-npm-ci-unguarded \
  'sed "s/^npm ci .*/npm ci/" agents/pe-vue.md > t && mv t agents/pe-vue.md' 'pe-vue: installs without the BUILD ROOT guard'
mutant direction-wait-nudged \
  'grepvall "name in awaiting_direction"' 'review: a PE awaiting build direction is nudged as stalled'
mutant direction-auto-blocks \
  'sedall "s/if session.auto: answer = \"skip\"/if False: answer = \"skip\"/"' 'review: build direction blocks an unattended run'
mutant protocol-build-input-dropped \
  'grep -vF "**Build root**" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: Inputs missing build root'
mutant protocol-build-rule-unscoped \
  'sed "s/bake an environment/build/" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: build rule not scoped to builds that bake an environment'
mutant protocol-direction-dropped \
  'grep -vF "message: \"build_direction" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: no ask-for-direction rule'
mutant protocol-receipt-dropped \
  'grep -vF "naming its configuration and output path" skills/review/references/pe-protocol.md > t && mv t skills/review/references/pe-protocol.md' \
  'protocol: build receipt rule missing'
mutant readme-prod-build \
  'printf "| pe-angular | ng build --configuration=production |\n" >> README.md' 'readme: lists a production build'
collect_cases

# model_for_tier keeps its forced tier aliases (TRIVIAL→haiku, STANDARD→sonnet).
check_tier_model_map() {  # <dispatch-and-collect.md>
  grep -qF 'case "TRIVIAL":  return "haiku"' "$1" || echo "model_for_tier lost its TRIVIAL mapping"
  grep -qF 'case "STANDARD": return "sonnet"' "$1" || echo "model_for_tier lost its STANDARD mapping"
}
DC="$PLUGIN/skills/review/references/dispatch-and-collect.md"
out=$(check_tier_model_map "$DC")
if [ -z "$out" ]; then pass "review tier→model aliases intact"; else fail "$out"; fi
TMPF="$WORK/dc.md"; grep -vF 'case "TRIVIAL":' "$DC" > "$TMPF"
if [ -n "$(check_tier_model_map "$TMPF")" ]; then pass "mutation caught: TRIVIAL tier alias dropped"
else fail "mutation NOT caught: TRIVIAL tier alias dropped"; fi

echo "$checks checks, $fails failed"
[ "$fails" -eq 0 ]
