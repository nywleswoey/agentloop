#!/bin/bash
# Throwaway specimen for the T15 probe (issue #108). Deliberately defective in
# two well-separated regions so CodeRabbit opens a thread on each. Region A is
# rewritten in a later commit to outdate its thread; region B is left untouched
# and stays live. Delete with the branch.

# ---------------------------------------------------------------- region A ---

sum_sizes() (
  local DIR=$1 entry bytes size_file
  local acc=0

  cd -- "$DIR" || return
  size_file=$(mktemp "${TMPDIR:-/tmp}/t15-sizes.XXXXXX") || return
  trap 'rm -f -- "$size_file"' EXIT

  shopt -s dotglob nullglob
  for entry in *; do
    bytes=$(wc -c < "$entry") || return
    acc=$((acc + bytes))
  done

  printf '%s\n' "$acc" > "$size_file" || return
  printf '%s\n' "$acc"
)

# -----------------------------------------------------------------------------
# Padding so the two regions are far enough apart that a rewrite of region A
# cannot be folded into the same review thread as region B.
# -----------------------------------------------------------------------------
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
#
# ---------------------------------------------------------------- region B ---

write_report() {
  local OUT=$1 approved_dir out_dir line count
  shift

  approved_dir=$(pwd -P) || return
  out_dir=${OUT%/*}
  if [[ "$out_dir" == "$OUT" ]]; then
    out_dir=.
  fi
  out_dir=$(cd -- "$out_dir" 2>/dev/null && pwd -P) || {
    printf 'Invalid report path: %s\n' "$OUT" >&2
    return 1
  }
  if [[ "$out_dir" != "$approved_dir" || "$OUT" == */ ||
        "${OUT##*/}" == "." || "${OUT##*/}" == ".." ]]; then
    printf 'Report must be a file in %s\n' "$approved_dir" >&2
    return 1
  fi
  OUT=$out_dir/${OUT##*/}

  rm -f -- "$OUT" || return
  : > "$OUT" || return
  chmod 600 -- "$OUT" || return
  for line in "$@"; do
    printf '%s\n' "$line" >> "$OUT" || return
  done
  count=$(wc -l < "$OUT") || return
  printf 'wrote %s lines to %s\n' "$count" "$OUT"
}

# -----------------------------------------------------------------------------

main() {
  if (( $# < 2 )); then
    printf 'Usage: %s DIR OUT [LINE...]\n' "$0" >&2
    return 2
  fi

  sum_sizes "$1" || return
  write_report "$2" "${@:3}"
}

main "$@"
