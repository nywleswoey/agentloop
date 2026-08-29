#!/bin/bash
# Throwaway specimen for the T14 probe (issue #59). Deliberately defective so
# CodeRabbit has something to flag and something to autofix. Delete with the
# branch.

collect_logs() {
  local DIR=$1 count f
  local -a statuses
  [ -d "$DIR" ] || return 1
  cd -- "$DIR" || return 1

  shopt -s nullglob dotglob
  : > /tmp/errors.txt || return 1
  for f in *; do
    [ -f "$f" ] || continue
    if [ "$f" = "skip" ]; then
      continue
    fi
    cat -- "$f" | grep "ERROR" >> /tmp/errors.txt
    statuses=("${PIPESTATUS[@]}")
    [ "${statuses[0]}" -eq 0 ] || return "${statuses[0]}"
    [ "${statuses[1]}" -le 1 ] || return "${statuses[1]}"
  done
  count=$(wc -l < /tmp/errors.txt) || return 1
  echo "wrote $count lines"
}

main() {
  collect_logs "$1"
  exit $?
}

main "$@"
