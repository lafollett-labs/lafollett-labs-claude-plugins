#!/usr/bin/env bash
# Secret detection for the gitleaks CI job. Scans the commits a run brings in:
#   SCAN_BASE..SCAN_HEAD  the workflow passes the PR base and head, or the push's before and after
# Merge commits are diffed against each parent (-m), so a secret added while resolving a merge is not
# skipped. With no usable base (empty, all zeros on a first push, or absent from the clone) it scans the
# whole working tree, so a run never passes without a scan.
#
# .gitleaks.toml is the only allow-list. Before scanning, the script refuses (exit 2) the allow-list
# shapes checked below and any .gitleaksignore file; inline gitleaks:allow comments are ignored.
# Exit: gitleaks' status (0 clean, 1 finding), or 2 when the inputs or the allow-list are invalid.
set -u

config="${GITLEAKS_CONFIG:-.gitleaks.toml}"
zero=0000000000000000000000000000000000000000
before="${SCAN_BASE:-}"
head="${SCAN_HEAD:-}"

die() { echo "secret-scan: $1" >&2; exit 2; }

[ -n "$head" ] || die "missing SCAN_HEAD"
case "$head$before" in *[!0-9a-f]*) die "SCAN_BASE and SCAN_HEAD must be commit SHAs" ;; esac
[ -f "$config" ] || die "missing gitleaks config $config"

# Every [[allowlists]] entry: a description, condition = "AND", an exact value (stopwords, or one
# ^-anchored regex with no .* or .+), and exactly one anchored single-file path on the `paths =` line.
# No other allow-list form (legacy or per-rule tables, dotted keys, inline arrays), and no disabled
# default rule.
problems="$(awk -v q="'" '
  function flush() {
    if (!inblock) return
    if (!desc)       print "entry at line " start ": no description"
    if (!cond)       print "entry at line " start ": condition must be \"AND\""
    if (!val)        print "entry at line " start ": no exact value (regexes or stopwords)"
    if (paths != 1)  print "entry at line " start ": needs exactly one paths line naming one anchored file"
  }
  /^[[:space:]]*#/ { next }
  {
    key = $0; sub(/=.*/, "", key)
    if (tolower(key) ~ /allowlist/ && $0 !~ /^[[:space:]]*\[\[allowlists\]\][[:space:]]*(#.*)?$/)
      print "line " NR ": an allow-list outside a top-level [[allowlists]] table is not allowed"
  }
  /^[[:space:]]*disabledRules[[:space:]]*=/ { print "line " NR ": disabling default rules is not allowed" }
  /^[[:space:]]*\[\[allowlists\]\]/ { flush(); inblock = 1; desc = cond = val = paths = 0; start = NR; next }
  /^[[:space:]]*\[/ { flush(); inblock = 0; next }
  inblock && /^[[:space:]]*description[[:space:]]*=[[:space:]]*"[^"]+"/ { desc = 1 }
  inblock && /^[[:space:]]*condition[[:space:]]*=[[:space:]]*"AND"[[:space:]]*$/ { cond = 1 }
  inblock && /^[[:space:]]*stopwords[[:space:]]*=/ { val = 1 }
  inblock && /^[[:space:]]*regexes[[:space:]]*=/ {
    one = "^[[:space:]]*regexes[[:space:]]*=[[:space:]]*\\[" q q q "\\^[^" q "]+" q q q "\\][[:space:]]*$"
    pat = $0; sub("^[^" q "]*" q q q, "", pat); sub(q q q ".*$", "", pat); gsub(/\\./, "", pat)
    if ($0 ~ one && pat !~ /\.[*+{]/) val = 1
    else print "entry at line " start ": regexes must be one ^-anchored pattern on one line, with no .* or .+"
  }
  inblock && /^[[:space:]]*paths[[:space:]]*=/ {
    one = "^[[:space:]]*paths[[:space:]]*=[[:space:]]*\\[" q q q "\\^[A-Za-z0-9_./\\\\-]+[$]" q q q "\\][[:space:]]*$"
    if ($0 ~ one) paths++; else paths += 2
  }
  END { flush() }' "$config")"
[ -z "$problems" ] || die "$config allow-list is broader than one exact value in one file:
$problems"

ignorefiles="$(find . -name .gitleaksignore -not -path './.git/*' 2>/dev/null)"
[ -z "$ignorefiles" ] || die "remove the .gitleaksignore file(s); allow-list in $config instead: $ignorefiles"

if [ -z "$before" ] || [ "$before" = "$zero" ] || ! git cat-file -e "${before}^{commit}" 2>/dev/null; then
  echo "secret-scan: no usable base commit ($before); scanning the whole tree"
  exec gitleaks dir --config "$config" --ignore-gitleaks-allow --redact --no-banner --exit-code 1 .
fi

echo "secret-scan: scanning commits $before..$head"
exec gitleaks git --log-opts="-m $before..$head" --config "$config" --ignore-gitleaks-allow \
  --redact --no-banner --exit-code 1 .
