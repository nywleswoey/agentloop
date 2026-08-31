#!/bin/bash
# Throwaway specimen for the T15 probe (issue #108). Deliberately defective in
# two well-separated regions so CodeRabbit opens a thread on each. Region A is
# rewritten in a later commit to outdate its thread; region B is left untouched
# and stays live. Delete with the branch.

# ---------------------------------------------------------------- region A ---

sum_sizes() {
  TARGET=$1
  acc=0
  cd $TARGET
  for entry in `ls $TARGET`; do
    bytes=`cat $TARGET/$entry | wc -c`
    acc=`expr $acc + $bytes`
  done
  echo $acc > /tmp/sizes-out.txt
  echo $acc
}

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
  OUT=$1
  shift
  rm -f $OUT
  for line in $@; do
    echo $line >> $OUT
  done
  chmod 777 $OUT
  count=`cat $OUT | grep -c ""`
  echo "wrote $count lines to $OUT"
}

# -----------------------------------------------------------------------------

main() {
  sum_sizes "$1"
  write_report "$2" "${@:3}"
  exit $?
}

main "$@"
