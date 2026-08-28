#!/bin/bash
#
# Shared assertions for the agent-loop test suites. Sourced, never run.
#
# Both suites assert the same way — on the log lines a script printed and on the
# argv it handed to the stub CLIs in tests/bin — so the assertions live here and
# only the fixtures and cases differ.
#
# Expects the sourcing suite to set CURRENT to the name of the running case.

PASSED=0
FAILED=0
CURRENT=""

# check <description> <command...> — passes when the command succeeds.
check() {
  local what="$1"
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL [$CURRENT] $what"
  fi
}

# A failing grep dumps the file it searched: a missing line is nearly always
# explained by the lines that are there instead.
check_grep() {
  local pattern="$1" file="$2"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL [$CURRENT] does not contain: $pattern"
    sed 's/^/      | /' "$file" 2>/dev/null
  fi
}

# Assert that a pattern does NOT appear in a file. Inverse of check_grep. Dumps
# the file contents on failure to help diagnose why the pattern was present.
check_no_grep() {
  local pattern="$1" file="$2"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    FAILED=$((FAILED + 1))
    echo "  FAIL [$CURRENT] should not contain: $pattern"
    sed 's/^/      | /' "$file" 2>/dev/null
  else
    PASSED=$((PASSED + 1))
  fi
}

# Assert that a command's exit status matches the expected value. Special value
# "nonzero" matches any non-zero exit status.
check_status() {
  local expected="$1" actual="$2"
  if [[ "$expected" == "nonzero" ]]; then
    check "exit status is non-zero (got $actual)" test "$actual" -ne 0
  else
    check "exit status is $expected (got $actual)" test "$actual" -eq "$expected"
  fi
}

# report — the suite's last line and its exit status.
report() {
  echo
  echo "passed: $PASSED  failed: $FAILED"
  [[ "$FAILED" -eq 0 ]]
}
