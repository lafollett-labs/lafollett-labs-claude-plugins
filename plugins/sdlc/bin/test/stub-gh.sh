#!/usr/bin/env bash
# Fake gh for the offline suites and evals: answers from a routes file and never reaches the network.
#
#   STUB_GH_DIR  directory holding `routes` and the response files (required)
#   STUB_GH_LOG  file each call is appended to, one line of space-joined args (default $STUB_GH_DIR/calls)
#
# routes: one route per line, tab-separated; the first route whose ERE matches the joined args wins.
# Blank lines and lines starting with # are skipped.
#   <ERE> <TAB> <exit code> <TAB> <response files, comma-separated, relative to STUB_GH_DIR>
# Each matching call takes the route's next response; the last one repeats. "-" prints nothing; a
# *.stderr file goes to stderr. With --jq/-q <expr>, a response is filtered through `jq -r <expr>`, as gh does.
# Stdin is appended to $STUB_GH_LOG.stdin when the args read it (--input -, --body-file -, -F k=@-).
# No route matches: "stub-gh: no route for: <args>" on stderr, exit 64.
set -u
dir="${STUB_GH_DIR:?STUB_GH_DIR is not set}"
log="${STUB_GH_LOG:-$dir/calls}"
args="$*"
printf '%s\n' "$args" >> "$log"

jq_expr=
prev=
for a in "$@"; do
  case "$prev" in --jq|-q) jq_expr="$a" ;; esac
  case "$a" in --jq=*) jq_expr="${a#--jq=}" ;; esac
  prev="$a"
done
case " $args " in
  *" --input - "*|*" --body-file - "*|*"=@- "*) { cat; printf '\n'; } >> "$log.stdin" ;;
esac

n=0
while IFS=$'\t' read -r re code resp || [ -n "${re:-}" ]; do
  n=$((n + 1))
  case "$re" in ''|'#'*) continue ;; esac
  printf '%s' "$args" | grep -Eq -- "$re" || continue
  IFS=, read -r -a files <<< "$resp"
  k="$(cat "$dir/.seen.$n" 2>/dev/null || echo 0)"
  echo $((k + 1)) > "$dir/.seen.$n"
  [ "$k" -lt "${#files[@]}" ] || k=$((${#files[@]} - 1))
  f="${files[$k]}"
  case "$f" in
    -) ;;
    *.stderr) cat "$dir/$f" >&2 ;;
    *) if [ -n "$jq_expr" ]; then jq -r -- "$jq_expr" < "$dir/$f"; else cat "$dir/$f"; fi ;;
  esac
  exit "$code"
done < "$dir/routes"
echo "stub-gh: no route for: $args" >&2
exit 64
