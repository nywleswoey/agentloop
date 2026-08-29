#!/bin/bash
# Throwaway specimen for the T14 probe (issue #59). Deliberately defective so
# CodeRabbit has something to flag and something to autofix. Delete with the
# branch.

collect_logs() {
  DIR=$1
  cd $DIR
  for f in `ls`; do
    if [ $f == "skip" ]; then
      continue
    fi
    cat $f | grep "ERROR" > /tmp/errors.txt
  done
  echo "wrote " $(cat /tmp/errors.txt | wc -l) " lines"
}

main() {
  collect_logs $1
  exit $?
}

main "$@"
