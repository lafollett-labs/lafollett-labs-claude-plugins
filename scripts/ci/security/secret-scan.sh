#!/usr/bin/env bash
# Secret detection for the gitleaks CI job. Scans the commits a run brings in:
#   SCAN_BASE..SCAN_HEAD  the workflow passes the PR base and head, or the push's before and after
# Merge commits are diffed against each parent (-m), so a secret added while resolving a merge is not
# skipped. With no usable base (empty, all zeros on a first push, or absent from the clone) it scans the
# whole working tree, so a run never passes without a scan.
#
# .gitleaks.toml is the only allow-list. Before scanning, the script refuses (exit 2) a config that
# check-allowlist.py rejects and any .gitleaksignore file; inline gitleaks:allow comments are ignored.
# Exit: gitleaks' status (0 clean, 1 finding), or 2 when the inputs or the allow-list are invalid.
set -u

config="${GITLEAKS_CONFIG:-.gitleaks.toml}"
zero=0000000000000000000000000000000000000000
before="${SCAN_BASE:-}"
head="${SCAN_HEAD:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "secret-scan: $1" >&2; exit 2; }

[ -n "$head" ] || die "missing SCAN_HEAD"
case "$head$before" in *[!0-9a-f]*) die "SCAN_BASE and SCAN_HEAD must be commit SHAs" ;; esac
[ -f "$config" ] || die "missing gitleaks config $config"

# The allow-list shape (one exact value in one exact file, no rules, [extend] only useDefault = true)
# is checked on the parsed TOML by check-allowlist.py, so no spelling of a key gets past it.
command -v python3 >/dev/null 2>&1 || die "python3 (3.11+) is required to check $config"
problems="$(python3 "$HERE/check-allowlist.py" "$config" 2>&1)"
case $? in
  0) ;;
  1) die "$config is outside the allowed shape (one exact value in one exact file; see check-allowlist.py):
$problems" ;;
  *) die "cannot check $config: $problems" ;;
esac

ignorefiles="$(find . -name .gitleaksignore -not -path './.git/*' 2>/dev/null)"
[ -z "$ignorefiles" ] || die "remove the .gitleaksignore file(s); allow-list in $config instead: $ignorefiles"

if [ -z "$before" ] || [ "$before" = "$zero" ] || ! git cat-file -e "${before}^{commit}" 2>/dev/null; then
  echo "secret-scan: no usable base commit ($before); scanning the whole tree"
  exec gitleaks dir --config "$config" --ignore-gitleaks-allow --redact --no-banner --exit-code 1 .
fi

echo "secret-scan: scanning commits $before..$head"
exec gitleaks git --log-opts="-m $before..$head" --config "$config" --ignore-gitleaks-allow \
  --redact --no-banner --exit-code 1 .
