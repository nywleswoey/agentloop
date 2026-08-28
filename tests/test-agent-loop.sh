#!/bin/bash
#
# test-agent-loop.sh
#
# Runs the real agent-loop.sh against the stub CLIs in tests/bin and asserts on
# the log lines it emits and the argv it handed to those stubs. The stub
# directory is the suite's only seam — no function inside agent-loop.sh is
# reached into directly.
#
# Usage:
#   ./tests/test-agent-loop.sh

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
SCRIPT="$ROOT/agent-loop.sh"
FIXTURES="$ROOT/tests/fixtures"
PATH="$ROOT/tests/bin:$PATH"
export PATH STUB_FIXTURES="$FIXTURES"

# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"

# call_line <pattern> — line number of the first matching call, or 0.
call_line() {
  { grep -nF "$1" "$STUB_CALLS" 2>/dev/null || echo "0:"; } | head -1 | cut -d: -f1
}

# Templated so the suite honours TMPDIR — a bare `mktemp -d` on macOS ignores it.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/agent-loop-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# Fresh scratch dir, call log and stub state for one test case.
setup() {
  CURRENT="$1"
  echo "== $CURRENT"
  WORK="$(mktemp -d "$SCRATCH/case.XXXXXX")"
  STUB_STATE="$WORK/state"
  STUB_CALLS="$WORK/calls.log"
  export STUB_STATE STUB_CALLS
  mkdir -p "$STUB_STATE"
  : > "$STUB_CALLS"
  export STUB_ORCA_STATUS=ready STUB_ISSUES=none STUB_ORCA_PS=idle
  export STUB_CLAIMED=none STUB_WORKTREES=none STUB_DIRTY="" STUB_UNPUSHED=""
  export STUB_WORLD=none STUB_MERGED=none
  unset AGENT_LOOP_LOG_MAX_BYTES STUB_GH_FAIL STUB_ORCA_FAIL STUB_GIT_FAIL
  # Multi-pass cases number their passes from here.
  PASS_N=0
  # Unfrozen unless a case says otherwise, so the stub `date` is the real one
  # and a freeze can never leak from the case before.
  unset STUB_NOW
  CONFIG="$WORK/config.json"
  LOG="$WORK/agent-loop.log"
  LOCK="$WORK/agent-loop.pid"
  write_config "nywleswoey/automation" "repo-aaa"
}

# write_config <github-full-name> <orca-repo-id> [poll-interval-seconds] [max-workers] [autofix-timeout]
write_config() {
  cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": ${3:-300},
  "maxWorkers": ${4:-3},
  "autofixTimeoutSeconds": ${5:-5400},
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "$1", "orcaRepoId": "$2" }
  ]
}
JSON
}

# replay <world> <frozen-instant> — one pass against a whole-world snapshot,
# with the pass's own output kept in $PASS_LOG.
#
# A multi-pass case moves between captured worlds rather than letting the stub
# simulate what the previous pass changed. Simulating would bake in an
# assumption about when GitHub stamps a write and how CodeRabbit words its
# answer, and the suite would then be testing the loop against that assumption
# rather than against GitHub. $STUB_CALLS is deliberately *not* reset between
# passes: what a later pass must not do is measured against everything the
# earlier ones did.
replay() {
  export STUB_WORLD="$1" STUB_NOW="$2"
  run_once
  PASS_N=$((PASS_N + 1))
  PASS_LOG="$WORK/pass-$PASS_N.log"
  cp "$OUT" "$PASS_LOG"
}

# run_once [extra args...] — captures stdout+stderr in $OUT, status in $STATUS
run_once() {
  OUT="$WORK/out.log"
  "$SCRIPT" --once --config "$CONFIG" "$@" > "$OUT" 2>&1
  STATUS=$?
}

# run_report <branch> — one --branch-report run, same capture as run_once.
run_report() {
  OUT="$WORK/out.log"
  "$SCRIPT" --config "$CONFIG" --branch-report "$1" > "$OUT" 2>&1
  STATUS=$?
}

# Start the loop in the background, output in $OUT, pid in $LOOP_PID.
start_loop() {
  OUT="$WORK/out.log"
  : > "$OUT"
  # Job control puts the loop in its own process group. Without it a background
  # job of a non-interactive shell inherits SIGINT ignored, which bash will not
  # let the script trap — the opposite of what Ctrl-C in a terminal does.
  set -m
  "$SCRIPT" --config "$CONFIG" > "$OUT" 2>&1 &
  LOOP_PID=$!
  set +m
}

# await <line> — block until the line shows up in $OUT, up to 10s.
await() {
  local _
  for _ in $(seq 1 100); do
    grep -qF "$1" "$OUT" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# stop_loop <signal> — signal the loop, wait for it, leave status in $STATUS.
stop_loop() {
  local _
  kill -"$1" "$LOOP_PID" 2>/dev/null
  for _ in $(seq 1 100); do
    kill -0 "$LOOP_PID" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$LOOP_PID" 2>/dev/null
  wait "$LOOP_PID"
  STATUS=$?
}

# --- one pass and exit --------------------------------------------------------

setup "--once runs a single pass and exits"
run_once
check_status 0 "$STATUS"
check_grep "pass start" "$OUT"
# The default inventory carries one done, clean, pushed loop worktree, so every
# pass that reads it sweeps exactly that one.
check_grep "pass end dispatches=0 skips=0 sweeps=1" "$OUT"
check "log file was written" test -f "$LOG"
check_grep "pass start" "$LOG"
check "exactly one pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 1
check "lockfile released on exit" test ! -f "$LOCK"

# --- lockfile held by a live process -----------------------------------------

setup "a second instance refuses to start"
printf '%s\n' "$$" > "$LOCK"
run_once
check_status nonzero "$STATUS"
check_grep "already running (pid $$)" "$OUT"
check "lockfile left intact" test -f "$LOCK"
check "no pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 0

# --- stale lockfile ----------------------------------------------------------

setup "a stale lockfile is cleared"
printf '%s\n' "999999" > "$LOCK"
run_once
check_status 0 "$STATUS"
check_grep "clearing stale lockfile (pid 999999)" "$OUT"
check_grep "pass start" "$OUT"

# --- unresolvable project ----------------------------------------------------

setup "an unresolvable project fails startup"
write_config "nywleswoey/typo-project" "repo-aaa"
run_once
check_status nonzero "$STATUS"
check_grep "project does not resolve: nywleswoey/typo-project" "$OUT"
check "no pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 0
check "lockfile released" test ! -f "$LOCK"

# --- unresolvable orcaRepoId -------------------------------------------------

setup "an unresolvable orcaRepoId fails startup"
write_config "nywleswoey/automation" "repo-stale"
run_once
check_status nonzero "$STATUS"
check_grep "orcaRepoId does not resolve: repo-stale (nywleswoey/automation)" "$OUT"
check "no pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 0

# --- malformed config --------------------------------------------------------

setup "a malformed config fails startup"
printf '{ not json' > "$CONFIG"
run_once
check_status nonzero "$STATUS"
check_grep "config is not valid JSON" "$OUT"

setup "a config missing a required field fails startup"
printf '{ "maxWorkers": 3 }' > "$CONFIG"
run_once
check_status nonzero "$STATUS"
check_grep "config is missing pollIntervalSeconds" "$OUT"

# --- runtime not reachable ---------------------------------------------------

setup "a down runtime is started and waited for"
export STUB_ORCA_STATUS=down
run_once
check_status 0 "$STATUS"
check_grep "orca runtime not reachable, starting it" "$OUT"
check_grep "orca runtime ready" "$OUT"
check_grep "orca open --json" "$STUB_CALLS"
# The stub refuses `repo list` until the runtime is up, so this only passes if
# the daemon starts Orca before it validates orcaRepoIds against it.
check_grep "validated nywleswoey/automation -> orca repo repo-aaa" "$OUT"
check_grep "pass start" "$OUT"

# --- log rotation ------------------------------------------------------------

setup "the log rotates once it passes its size cap"
export AGENT_LOOP_LOG_MAX_BYTES=2000
head -c 5000 /dev/zero | tr '\0' 'x' > "$LOG"
run_once
check_status 0 "$STATUS"
check "rotated log exists" test -f "$LOG.1"
# The old content moved aside and the live log started fresh. Asserting on the
# live log's size instead would break every time a pass gains a line.
check_grep "xxxxxxxxxx" "$LOG.1"
check_no_grep "xxxxxxxxxx" "$LOG"
check_grep "pass start" "$LOG"

# --- the clock the suite controls ---------------------------------------------

# The point of these two is that the stub is load-bearing. A `date` stub nothing
# depends on passes silently forever, and the states this project is about to
# grow — an autofix that has been in flight too long, a merge gate with an age
# bound — are decided entirely by what time it is. If freezing the clock cannot
# be observed in the loop's own output, none of those can be tested either.
#
# Twins: one fixture, one config, one code path, two frozen instants. The only
# difference between the two cases below is $STUB_NOW, so whatever differs in
# what they produce is caused by the clock and by nothing else.

setup "a frozen clock reaches the loop's own timestamps"
# Both twins freeze at instants safely in the past. The unfrozen case below
# asserts their absence, and an instant near the present would give that
# assertion a window — a second or a day wide — in which it fails for reasons
# that have nothing to do with the stub.
export STUB_NOW=2011-11-11T11:11:11Z
run_once
check_status 0 "$STATUS"
check_grep "2011-11-11T11:11:11Z pass start" "$LOG"

setup "the same fixture at a different instant produces a different log"
export STUB_NOW=2019-03-04T05:06:07Z
run_once
check_status 0 "$STATUS"
check_grep "2019-03-04T05:06:07Z pass start" "$LOG"
# The other twin's instant, which the loop must not have produced from anywhere.
# Without this the pair would still pass if `date` were being read through a
# route the stub cannot see and both logs carried the real time.
check_no_grep "2011-11-11T11:11:11Z" "$LOG"

setup "an unfrozen clock is the real one"
run_once
check_status 0 "$STATUS"
check_no_grep "2011-11-11T11:11:11Z" "$LOG"
check_no_grep "2019-03-04T05:06:07Z" "$LOG"
check_grep "pass start" "$LOG"

# The invocation every bounded state in the spec is going to make: read now,
# read a timestamp that came out of a fixture, subtract. Frozen `now` and a
# conversion have to come from the same `date` and disagree about nothing, which
# is why the stub freezes only the clock and passes a named instant straight
# through. Ninety minutes against a 5400-second timeout is the shape an autofix
# timeout case will take.

# epoch_of <iso-8601> — whichever conversion spelling this platform's date takes.
# Tried rather than probed for, so this does not carry a second copy of the
# flavour test that lives in the stub and cannot disagree with it.
epoch_of() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s
}

setup "a frozen now can be compared against a timestamp out of a fixture"
export STUB_NOW=2026-08-27T12:00:00Z
NOW=$(date -u +%s)
THEN=$(epoch_of 2026-08-27T10:30:00Z)
check "now reads as the frozen instant" test "$NOW" -eq 1787832000
check "a named instant is not frozen with it" test "$THEN" -eq 1787826600
check "the difference is the ninety minutes the fixture describes" \
  test "$((NOW - THEN))" -eq 5400
# The conversion answers the same whether the clock is frozen or not: a case
# that froze time must not thereby change what its own fixtures mean.
unset STUB_NOW
check "the same conversion is unaffected by the freeze" \
  test "$(epoch_of 2026-08-27T10:30:00Z)" -eq "$THEN"

setup "an invocation that only looks like a conversion is still frozen"
export STUB_NOW=2026-08-27T12:00:00Z
# BSD's `-j` is a conversion only when it comes with `-f`; alone it is a plain
# read of the clock, and passing it through would answer it off wall time while
# the case believes time is frozen.
if date -u -j '+%Y' >/dev/null 2>&1; then
  check "-j without -f reads the frozen clock" \
    test "$(date -u -j '+%Y-%m-%dT%H:%M:%SZ')" = "2026-08-27T12:00:00Z"
  check "-j with -f still converts" \
    test "$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' 2020-01-01T00:00:00Z +%s)" -eq 1577836800
else
  check "this platform's date has no -j to confuse" true
fi

setup "an invocation that adjusts now is adjusted from the frozen instant"
export STUB_NOW=2026-08-27T12:00:00Z
# `date -v-90m` and `date -d '90 minutes ago'` both *read* the clock — they are
# not conversions, and handing them to the real date would answer them off wall
# time while the case believes time is frozen. Silent, and the same failure as
# reading the clock from a shell built-in.
if date -u -v-0S +%s >/dev/null 2>&1; then
  check "a -v adjustment lands on the frozen instant" \
    test "$(date -u -v-90M '+%Y-%m-%dT%H:%M:%SZ')" = "2026-08-27T10:30:00Z"
else
  # GNU date has no -v at all, so there is nothing to get wrong there.
  check "this platform's date has no -v to adjust" true
fi
# The GNU spelling cannot be answered from a frozen instant, so it is refused
# out loud rather than answered off the real clock.
date -u -d '90 minutes ago' +%s > "$WORK/relative.txt" 2>&1
check_status nonzero "$?"
check_grep "relative to now, which is frozen" "$WORK/relative.txt"

# --- time comes from date(1), and from nowhere else ---------------------------

# The stub only works because every clock read leaves the process. A shell
# built-in reads the real clock without touching PATH, so one `printf '%(%s)T'`
# would make a timeout test green against wall time while looking identical to
# a passing one — the same shape as a call that is well-formed in argv and wrong
# at the far end.
#
# Deliberately one assertion covering both scripts rather than one per suite:
# it is a single project-wide binding, and a copy in the writeback suite would
# be the same claim asserted twice.

setup "no script reads the clock by any route but date(1)"
# Bare names, not `$NAME`: arithmetic context drops the sigil, so `(( SECONDS >
# n ))` and `${EPOCHSECONDS}` are the spellings a timeout would most naturally
# be written in and a `\$`-anchored pattern misses both. `_SECONDS` suffixes on
# config names are safe — the underscore is a word character, so there is no
# boundary in front of them.
#
# Comments are stripped first: this is a claim about code, and a header that
# names the built-ins in order to forbid them must not fail the check that
# forbids them.
#
# Globbed rather than listed, so a script added at the root later is covered by
# this the day it lands rather than the day someone remembers to add it here.
#
# The limit, stated rather than papered over: this catches the routes that look
# like ordinary shell and would therefore pass review — the built-ins, and the
# interpreters someone might reach for to format a timestamp. It cannot catch
# every conceivable way to read a clock. What makes that acceptable is that any
# clock read the loop grows will have a frozen-time test of its own, and a read
# that dodged this stub would fail that test loudly.
CLOCK_ROUTES='%\(.*\)T|\bEPOCHSECONDS\b|\bEPOCHREALTIME\b|\bSECONDS\b'
CLOCK_ROUTES="$CLOCK_ROUTES"'|\bsystime\(|/proc/uptime|kern\.boottime'
# An interpreter only counts when it is being asked for the time. A bare
# `node` also appears as an English word in the worker prompt, and a check
# that fires on prose gets deleted rather than fixed.
CLOCK_ROUTES="$CLOCK_ROUTES"'|(perl|python3?|ruby|node).*(strftime|localtime|gmtime|time\(\)|Date\.now|datetime)'
# Strip only unquoted comment starters. In particular, command substitutions in
# double-quoted strings still need scanning even when a literal `#` precedes
# them.
strip_shell_comments() {
  awk '
    {
      if (!continued) word_start = 1
      output = ""
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)
        if (state == "single") {
          output = output char
          if (char == sprintf("%c", 39)) state = ""
          continue
        }
        if (state == "double") {
          output = output char
          if (escaped) escaped = 0
          else if (char == "\\") escaped = 1
          else if (char == "\"") state = ""
          continue
        }
        if (char == "\\") {
          output = output char
          if (i < length($0)) {
            output = output substr($0, ++i, 1)
            word_start = 0
          } else {
            continued = 1
          }
          continue
        }
        if (char == sprintf("%c", 39)) {
          state = "single"
          word_start = 0
        } else if (char == "\"") {
          state = "double"
          word_start = 0
        } else if (char == "#" && word_start) {
          break
        } else if (char ~ /[[:space:];|&()<>]/) {
          word_start = 1
        } else {
          word_start = 0
        }
        output = output char
      }
      if (state == "double" && escaped) escaped = 0
      if (i > length($0)) continued = 0
      print output
    }
  ' "$1"
}
for _script in "$ROOT"/*.sh; do
  check "no clock read but date(1) in ${_script##*/}" \
    test "$(strip_shell_comments "$_script" | grep -cE "$CLOCK_ROUTES")" -eq 0
done

# --- the loop keeps passing ---------------------------------------------------

setup "without --once the loop sleeps and passes again"
write_config "nywleswoey/automation" "repo-aaa" 1
start_loop
for _ in $(seq 1 100); do
  [[ "$(grep -cF 'pass start' "$OUT")" -ge 2 ]] && break
  sleep 0.1
done
check "a second pass ran" test "$(grep -cF 'pass start' "$OUT")" -ge 2
check_grep "sleeping 1s" "$OUT"
stop_loop TERM
check_status 0 "$STATUS"

# --- SIGINT releases the lock ------------------------------------------------

setup "SIGINT releases the lockfile and exits cleanly"
write_config "nywleswoey/automation" "repo-aaa" 60
start_loop
await "sleeping 60s"
check "lockfile taken while running" test -f "$LOCK"
stop_loop INT
check_status 0 "$STATUS"
check_grep "shutting down" "$OUT"
check "lockfile released" test ! -f "$LOCK"

# --- issue phase: a workable issue is claimed and dispatched -------------------

# gh-axi edits labels as a delta, so the claim stays the one atomic call it was
# on GitLab — an add and a remove together, with the issue's other labels none
# of the loop's business.
CLAIM_CALL="gh-axi issue edit 17 --repo nywleswoey/automation --add-label agent-in-progress --remove-label ready-for-agent"
CREATE_CALL="orca worktree create --repo id:repo-aaa --name agent-loop-feat-17-agent-loop-issue-phase --no-parent --agent claude --prompt /implement https://github.com/nywleswoey/automation/issues/17 --json"

setup "a workable issue is claimed and dispatched"
export STUB_ISSUES=workable
run_once
check_status 0 "$STATUS"
check_grep 'gh-axi api POST graphql --field query={ repository(owner: "nywleswoey", name: "automation") { issues(labels: ["ready-for-agent"], states: OPEN, first: 100)' "$STUB_CALLS"
check_grep "$CLAIM_CALL" "$STUB_CALLS"
check_grep "$CREATE_CALL" "$STUB_CALLS"
check "the claim precedes the dispatch" test "$(call_line "$CLAIM_CALL")" -lt "$(call_line "$CREATE_CALL")"
check_grep "claimed nywleswoey/automation#17" "$OUT"
# The stub answers with a collision-renamed worktree, so this only passes if the
# handle is read back from the response rather than assumed from the name.
check_grep "dispatched nywleswoey/automation#17 -> worktree repo-aaa::/tmp/stub/automation/agent-loop-issue-17-2" "$OUT"
check_grep "pass end dispatches=1 skips=0 sweeps=1" "$OUT"

setup "the change type and title become the readable half of the name"
# The `bug` label maps onto `fix`, and punctuation, case, runs of separators and
# the trailing overflow all go from the title, so the branch stays typeable and
# the iid still sits between the type and the slug.
export STUB_ISSUES=messy-title
run_once
check_status 0 "$STATUS"
check_grep "--name agent-loop-fix-17-fix-login-timeout-retry-twice-on-every-s " "$STUB_CALLS"

setup "an issue with no type label is dispatched as a feat"
# `issues-none` aside, the other fixtures carry no labels block at all: the type
# is a reading aid, so a missing one is a default and never a failed dispatch.
export STUB_ISSUES=closed-blocker
run_once
check_status 0 "$STATUS"
check_grep "--name agent-loop-feat-17-agent-loop-issue-phase " "$STUB_CALLS"

# --- issue phase: a blocked issue is left alone --------------------------------

setup "a blocked issue is neither claimed nor dispatched"
export STUB_ISSUES=blocked
run_once
check_status 0 "$STATUS"
check_grep "issue nywleswoey/automation#18 skipped: blocked by 1 open blocker" "$OUT"
check_grep "gh-axi api /repos/nywleswoey/automation/issues/18/dependencies/blocked_by --paginate" "$STUB_CALLS"
check_no_grep "issue edit" "$STUB_CALLS"
check_no_grep "worktree create" "$STUB_CALLS"
check_grep "pass end dispatches=0 skips=1 sweeps=1" "$OUT"

setup "an issue whose only blocker is closed is workable"
# The blockers endpoint answers with the blocking issues themselves, so a
# blocker that has since been closed is visible as one and does not block.
export STUB_ISSUES=closed-blocker
run_once
check_status 0 "$STATUS"
check_grep "claimed nywleswoey/automation#17" "$OUT"
check_grep "dispatched nywleswoey/automation#17" "$OUT"
check_grep "pass end dispatches=1 skips=0 sweeps=1" "$OUT"

# --- issue phase: the worker budget is global ----------------------------------

setup "a candidate arriving at a full budget is deferred, not dispatched"
export STUB_ISSUES=workable STUB_ORCA_PS=busy
run_once
check_status 0 "$STATUS"
check_grep "issue nywleswoey/automation#17 deferred: worker budget full (3/3)" "$OUT"
check_no_grep "issue edit" "$STUB_CALLS"
check_no_grep "worktree create" "$STUB_CALLS"
check_grep "pass end dispatches=0 skips=1 sweeps=0" "$OUT"

setup "the budget counts loop workers across phases and spends the last slot once"
# Two live loop workers, one of them a PR worker: the budget is one pool, so
# only one of the two workable issues gets the remaining slot.
export STUB_ISSUES=mixed STUB_ORCA_PS=one-free
run_once
check_status 0 "$STATUS"
check_grep "issue nywleswoey/automation#18 skipped: blocked by 1 open blocker" "$OUT"
check_grep "dispatched nywleswoey/automation#17" "$OUT"
check_grep "issue nywleswoey/automation#19 deferred: worker budget full (3/3)" "$OUT"
check "exactly one worktree was created" test "$(grep -cF 'worktree create' "$STUB_CALLS")" -eq 1
check_grep "pass end dispatches=1 skips=2 sweeps=0" "$OUT"

# --- issue phase: failures are logged, the pass survives -----------------------

setup "a failed issue query is logged and the pass continues"
export STUB_ISSUES=workable STUB_GH_FAIL=issues
run_once
check_status 0 "$STATUS"
check_grep "issue query failed: nywleswoey/automation" "$OUT"
check_grep "pass end" "$OUT"

setup "a GraphQL error body is a failed query, not an empty backlog"
export STUB_ISSUES=error
run_once
check_status 0 "$STATUS"
check_grep "issue query failed: nywleswoey/automation" "$OUT"
check_grep "pass end dispatches=0 skips=1 sweeps=1" "$OUT"

setup "a blocker read that will not answer skips the issue rather than guessing"
export STUB_ISSUES=workable STUB_GH_FAIL=blockers
run_once
check_status 0 "$STATUS"
check_grep "issue nywleswoey/automation#17 skipped: could not read its blockers" "$OUT"
check_no_grep "issue edit" "$STUB_CALLS"
check_no_grep "worktree create" "$STUB_CALLS"

setup "an unreadable worker inventory fails the budget closed"
export STUB_ISSUES=workable STUB_ORCA_FAIL=ps
run_once
check_status 0 "$STATUS"
check_grep "worker inventory unreadable, treating the budget as full for this pass" "$OUT"
check_grep "issue nywleswoey/automation#17 deferred: worker budget full (3/3)" "$OUT"
check_no_grep "worktree create" "$STUB_CALLS"

setup "a failed dispatch is logged and the pass continues"
export STUB_ISSUES=workable STUB_ORCA_FAIL=create
run_once
check_status 0 "$STATUS"
check_grep "$CLAIM_CALL" "$STUB_CALLS"
check_grep "dispatch failed for nywleswoey/automation#17" "$OUT"
check_grep "pass end dispatches=0 skips=1 sweeps=1" "$OUT"

# --- worktree inventory: the branch report -------------------------------------

setup "a branch nobody has checked out is free"
export STUB_WORKTREES=branches STUB_ORCA_PS=branches
run_report never-checked-out
check_status 0 "$STATUS"
check_grep "branch never-checked-out nywleswoey/automation: free" "$OUT"
# git, not Orca, is what the check reads the checkout from.
check_grep "git -C /tmp/stub/automation worktree list --porcelain" "$STUB_CALLS"

setup "a branch held by a live loop worker is reported live, by worktree"
export STUB_WORKTREES=branches STUB_ORCA_PS=branches
run_report pr-live
check_status 0 "$STATUS"
check_grep "branch pr-live nywleswoey/automation: loop-live /tmp/stub/automation/agent-loop-pr-13" "$OUT"
# Liveness is the agent's state, not whether a terminal or a worktree exists.
check_grep "orca worktree ps --json" "$STUB_CALLS"

setup "a loop worker parked waiting for my confirmation still counts as live"
export STUB_WORKTREES=branches STUB_ORCA_PS=branches
run_report pr-waiting
check_status 0 "$STATUS"
check_grep "branch pr-waiting nywleswoey/automation: loop-live /tmp/stub/automation/agent-loop-pr-15" "$OUT"

setup "a branch held by a finished loop worker is reported done"
export STUB_WORKTREES=branches STUB_ORCA_PS=branches
run_report pr-done
check_status 0 "$STATUS"
check_grep "branch pr-done nywleswoey/automation: loop-done /tmp/stub/automation/agent-loop-pr-14" "$OUT"

setup "a loop worktree Orca has lost is not reported as reusable"
export STUB_WORKTREES=branches STUB_ORCA_PS=branches
# agent-loop-pr-16 is in git's worktree list and in no Orca inventory, so there
# is no worktree id left to reuse it by — reporting it done would send the PR
# phase after a handle that does not exist.
run_report pr-lost
check_status 0 "$STATUS"
check_grep "branch pr-lost nywleswoey/automation: unknown /tmp/stub/automation/agent-loop-pr-16" "$OUT"

setup "a worktree the loop did not create is foreign, and clean when its tree is"
export STUB_WORKTREES=branches STUB_ORCA_PS=branches
run_report my-branch
check_status 0 "$STATUS"
# The worktree carries a `working` agent, so this only passes if foreignness is
# decided by the name rather than by the agent state.
check_grep "branch my-branch nywleswoey/automation: foreign-clean /tmp/stub/automation/my-own-checkout" "$OUT"
check_grep "git -C /tmp/stub/automation/my-own-checkout status --porcelain" "$STUB_CALLS"

setup "a foreign worktree with a dirty tree is reported dirty"
export STUB_WORKTREES=branches STUB_ORCA_PS=branches
export STUB_DIRTY="/tmp/stub/automation/my-own-checkout"
run_report my-branch
check_status 0 "$STATUS"
check_grep "branch my-branch nywleswoey/automation: foreign-dirty /tmp/stub/automation/my-own-checkout" "$OUT"

setup "a worktree Orca does not manage is still visible to the check"
export STUB_WORKTREES=branches STUB_ORCA_PS=branches
# /Users/stub/dev/automation-hotfix appears in git's worktree list and in no
# Orca inventory at all.
run_report hotfix
check_status 0 "$STATUS"
check_grep "branch hotfix nywleswoey/automation: foreign-clean /Users/stub/dev/automation-hotfix" "$OUT"

# --- startup reclaim -----------------------------------------------------------

setup "startup returns a claimed issue with no live worker to the ready label"
export STUB_CLAIMED=mixed STUB_ORCA_PS=busy
run_once
check_status 0 "$STATUS"
check_grep "reclaimed nywleswoey/automation#21" "$OUT"
check_grep "gh-axi issue edit 21 --repo nywleswoey/automation --add-label ready-for-agent --remove-label agent-in-progress" "$STUB_CALLS"
# #1 has no worktree either — and must not be matched by agent-loop-issue-11.
check_grep "reclaimed nywleswoey/automation#1:" "$OUT"
check_grep "gh-axi issue edit 1 --repo nywleswoey/automation --add-label ready-for-agent --remove-label agent-in-progress" "$STUB_CALLS"
# #11 has a `working` worker, #12 a `waiting` one parked for my confirmation.
check_grep "left claimed nywleswoey/automation#11" "$OUT"
check_grep "left claimed nywleswoey/automation#12" "$OUT"
check_no_grep "issue edit 11 " "$STUB_CALLS"
check_no_grep "issue edit 12 " "$STUB_CALLS"
check "exactly two issues were reclaimed" \
  test "$(grep -c -- '--add-label ready-for-agent' "$STUB_CALLS")" -eq 2
# Reclaim runs once at startup, not once per pass.
check "one reclaim line per issue" test "$(grep -cF 'reclaimed nywleswoey/automation#21' "$OUT")" -eq 1

setup "no claimed issues means no reclaim traffic"
run_once
check_status 0 "$STATUS"
check_no_grep "--add-label ready-for-agent" "$STUB_CALLS"
check_no_grep "reclaimed" "$OUT"

setup "an unreadable inventory skips the reclaim rather than reclaiming blindly"
export STUB_CLAIMED=mixed STUB_ORCA_FAIL=ps
run_once
check_status 0 "$STATUS"
check_grep "worker inventory unreadable, skipping startup reclaim" "$OUT"
check_no_grep "--add-label ready-for-agent" "$STUB_CALLS"

setup "a failed claimed-issue query is logged and startup continues"
export STUB_CLAIMED=mixed STUB_GH_FAIL=issues
run_once
check_status 0 "$STATUS"
check_grep "claimed-issue query failed: nywleswoey/automation" "$OUT"
check_grep "pass start" "$OUT"

# --- worktree sweep -------------------------------------------------------------

# The sweep fixture carries one of everything: a removable loop worktree, a
# dirty one, one with unpushed commits, one parked `waiting`, one still
# `working`, and two the loop did not create.
SWEEP_DIRTY="/tmp/stub/automation/agent-loop-issue-32"
SWEEP_UNPUSHED="/tmp/stub/automation/agent-loop-issue-33"

setup "a done, clean, pushed loop worktree is swept"
export STUB_ORCA_PS=sweep STUB_DIRTY="$SWEEP_DIRTY" STUB_UNPUSHED="$SWEEP_UNPUSHED"
run_once
check_status 0 "$STATUS"
check_grep "orca worktree rm --worktree path:/tmp/stub/automation/agent-loop-issue-31 --json" "$STUB_CALLS"
check_grep "swept /tmp/stub/automation/agent-loop-issue-31" "$OUT"
check "exactly one worktree was removed" test "$(grep -cF 'worktree rm' "$STUB_CALLS")" -eq 1
check_grep "pass end dispatches=0 skips=0 sweeps=1" "$OUT"

setup "a dirty loop worktree is left alone and logged"
export STUB_ORCA_PS=sweep STUB_DIRTY="$SWEEP_DIRTY" STUB_UNPUSHED="$SWEEP_UNPUSHED"
run_once
check_status 0 "$STATUS"
check_grep "sweep skipped /tmp/stub/automation/agent-loop-issue-32: uncommitted changes" "$OUT"
check_no_grep "path:/tmp/stub/automation/agent-loop-issue-32" "$STUB_CALLS"

setup "a loop worktree with commits not on the remote is left alone and logged"
export STUB_ORCA_PS=sweep STUB_DIRTY="$SWEEP_DIRTY" STUB_UNPUSHED="$SWEEP_UNPUSHED"
run_once
check_status 0 "$STATUS"
check_grep "sweep skipped /tmp/stub/automation/agent-loop-issue-33: 2 commits not on the remote" "$OUT"
check_no_grep "path:/tmp/stub/automation/agent-loop-issue-33" "$STUB_CALLS"
# Push state is read from origin's branches rather than the tracking branch: an
# Orca checkout has no upstream, so `@{upstream}` would answer "nothing to push".
check_grep "rev-list --count HEAD --not --remotes=origin" "$STUB_CALLS"

setup "a git that will not answer the push question leaves the worktree alone"
export STUB_ORCA_PS=sweep STUB_GIT_FAIL=rev-list
run_once
check_status 0 "$STATUS"
check_grep "sweep skipped /tmp/stub/automation/agent-loop-issue-31: could not read its push state" "$OUT"
check_no_grep "worktree rm" "$STUB_CALLS"
check_grep "pass end dispatches=0 skips=0 sweeps=0" "$OUT"

setup "a loop worker parked waiting for my confirmation is left alone and logged"
export STUB_ORCA_PS=sweep STUB_DIRTY="$SWEEP_DIRTY" STUB_UNPUSHED="$SWEEP_UNPUSHED"
run_once
check_status 0 "$STATUS"
check_grep "sweep skipped /tmp/stub/automation/agent-loop-pr-34: its agent is still going" "$OUT"
check_no_grep "path:/tmp/stub/automation/agent-loop-pr-34" "$STUB_CALLS"
check_grep "sweep skipped /tmp/stub/automation/agent-loop-pr-35: its agent is still going" "$OUT"
check_no_grep "path:/tmp/stub/automation/agent-loop-pr-35" "$STUB_CALLS"

setup "a worktree the loop did not create is never removed"
export STUB_ORCA_PS=sweep STUB_DIRTY="$SWEEP_DIRTY" STUB_UNPUSHED="$SWEEP_UNPUSHED"
run_once
check_status 0 "$STATUS"
# my-own-checkout carries a `done` agent and a clean tree, so this only passes
# if foreignness is decided by the name before anything else is asked.
check_no_grep "path:/tmp/stub/automation/my-own-checkout" "$STUB_CALLS"
check_no_grep "path:/tmp/stub/automation/main" "$STUB_CALLS"
check_no_grep "sweep skipped /tmp/stub/automation/my-own-checkout" "$OUT"
check_no_grep "git -C /tmp/stub/automation/my-own-checkout status" "$STUB_CALLS"

setup "the sweep runs after the dispatches, at the end of the pass"
export STUB_ORCA_PS=sweep STUB_ISSUES=workable
export STUB_DIRTY="$SWEEP_DIRTY" STUB_UNPUSHED="$SWEEP_UNPUSHED"
run_once
check_status 0 "$STATUS"
check "the dispatch precedes the sweep" test "$(call_line 'worktree create')" -lt "$(call_line 'worktree rm')"
check_grep "pass end dispatches=1 skips=0 sweeps=1" "$OUT"

setup "a failed removal is logged and the pass survives"
export STUB_ORCA_PS=sweep STUB_ORCA_FAIL=rm
export STUB_DIRTY="$SWEEP_DIRTY" STUB_UNPUSHED="$SWEEP_UNPUSHED"
run_once
check_status 0 "$STATUS"
check_grep "sweep failed for /tmp/stub/automation/agent-loop-issue-31, leaving it in place" "$OUT"
check_grep "pass end dispatches=0 skips=0 sweeps=0" "$OUT"

setup "an unreadable inventory skips the sweep rather than sweeping blindly"
export STUB_ORCA_FAIL=ps
run_once
check_status 0 "$STATUS"
check_grep "worker inventory unreadable, skipping the sweep" "$OUT"
check_no_grep "worktree rm" "$STUB_CALLS"

# --- pr phase: scope --------------------------------------------------------------

# One pass over a world carrying every state the phase can derive at once, so
# the reducer is asserted whole rather than one hand-picked case at a time.
# `maxWorkers` is left at its default and the inventory is the busy one, which
# is the point of the last two assertions in this case.
setup "the PR phase derives, logs and acts on every open pull request"
export STUB_WORLD=states STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"

# Per repository, not through the global search index. Search lags the
# repository it indexes, so a pull request the loop should be acting on can
# simply be missing from it.
check_grep 'repository(owner: "nywleswoey", name: "automation") { pullRequests(states: OPEN' "$STUB_CALLS"
check_no_grep 'is:pr is:open' "$STUB_CALLS"
# The labels the escalation self-heal will want, fetched on the read that is
# already being made.
check_grep 'labels(first: 50) { nodes { name } }' "$STUB_CALLS"

# 201 is a draft — the operator's hold gesture — and 202's head is on a fork.
# Both are excluded on the enumeration read, so neither is ever read again: the
# stub errors out on a pull request its world does not carry, which is what
# turns "no state line" into a fact rather than an absence.
check_no_grep "#201" "$OUT"
check_no_grep "#202" "$OUT"
check_no_grep "pullRequest(number: 201)" "$STUB_CALLS"
check_no_grep "pullRequest(number: 202)" "$STUB_CALLS"

# --- pr phase: the state log ------------------------------------------------------

# One line per pull request per pass: repository, number, commit and state
# positionally, then the values that state was derived from. With no local
# state anywhere this line is the only record a wait leaves.

# 203 — CodeRabbit is still looking at the head commit. Its rollup also carries
# a green CI status, which is not CodeRabbit's and does not answer for it: the
# review that has to be terminal is the reviewer's own.
check_grep "pr nywleswoey/automation#203 203c203c203c203c203c203c203c203c203c203c reviewing review=pending threads=0 autofix=unspent" "$OUT"

# 204 — the review finished with unresolved findings and no autofix has been
# attempted at this head. Two of its four threads count: one is resolved, and
# one I opened myself, which is a conversation rather than a finding.
check_grep "pr nywleswoey/automation#204 204d204d204d204d204d204d204d204d204d204d needs-autofix review=terminal threads=2 autofix=unspent action=triggered" "$OUT"

# 205 — reviewed, nothing unresolved to fix.
check_grep "pr nywleswoey/automation#205 205e205e205e205e205e205e205e205e205e205e assessable review=terminal threads=0 autofix=unspent" "$OUT"

# 206 — autofix already ran at this head. Its findings are *still* unresolved,
# because autofix does not resolve what it fixes, and it is assessable anyway:
# unresolved threads are input to the fix trigger and to nothing else.
check_grep "pr nywleswoey/automation#206 206f206f206f206f206f206f206f206f206f206f assessable review=terminal threads=3 autofix=spent" "$OUT"

# 207 — triggered an hour ago, CodeRabbit has not answered, still inside the
# bound.
check_grep "pr nywleswoey/automation#207 207a207a207a207a207a207a207a207a207a207a autofix-in-flight review=terminal threads=2 autofix=unspent age=3600 bound=5400" "$OUT"

# 208 and 212 — opened by a bot, and merging into a release branch rather than
# trunk. Neither is an exclusion: the rule has exactly two, and these are the
# two most often mistaken for a third.
check_grep "pr nywleswoey/automation#208 208b208b208b208b208b208b208b208b208b208b assessable review=terminal threads=0 autofix=unspent" "$OUT"
check_grep "pr nywleswoey/automation#212 212f212f212f212f212f212f212f212f212f212f assessable review=terminal threads=0 autofix=unspent" "$OUT"

# 209 and 210 — CodeRabbit reporting through a check run and no legacy status at
# all, which is the surface its own changelog says is now the default and which
# this account does not in fact emit. Both are read, either one terminal is
# terminal, and the pair differs only in the check run's status.
check_grep "pr nywleswoey/automation#209 209c209c209c209c209c209c209c209c209c209c assessable review=terminal threads=0 autofix=unspent" "$OUT"
check_grep "pr nywleswoey/automation#210 210d210d210d210d210d210d210d210d210d210d reviewing review=pending threads=0 autofix=unspent" "$OUT"

# 211 — nothing rolled up on the head commit at all, which is what a pull
# request CodeRabbit has never looked at reports. Absence is a real state, not a
# read that failed: one real pull request sat in exactly this shape for four and
# a half hours.
#
# ponytail: it lands in `reviewing` and waits forever. #32 splits it out as its
# own state, nudges it, and bounds what remains.
check_grep "pr nywleswoey/automation#211 211e211e211e211e211e211e211e211e211e211e reviewing review=pending threads=0 autofix=unspent" "$OUT"

# The commit named is the head, never a commit out of CodeRabbit's prose. The
# autofix status comment on 206 names a different one on purpose.
check_no_grep "dec0dec0dec0dec0dec0dec0dec0dec0dec0dec0" "$OUT"

# Exactly one line per pull request, and exactly one action across the pass.
check "one state line per pull request" test "$(grep -cE '^[0-9TZ:-]+ pr nywleswoey/automation#' "$OUT")" -eq 10

# --- pr phase: the action goes through the real seam --------------------------------

# The loop has never once executed pr-writeback.sh: it used to embed the command
# as text in a worker's prompt and this suite grepped that string. With the
# worker deleted the chain runs unbroken from the loop to the CLI argv, which is
# the only reason the line below is observable at all.
check_grep "gh-axi pr comment 204 --repo nywleswoey/automation --body @coderabbitai autofix" "$STUB_CALLS"
check "exactly one autofix trigger this pass" test "$(grep -cF 'body @coderabbitai autofix' "$STUB_CALLS")" -eq 1

# The trigger's text is spelled twice — once in the seam, which *writes* it, and
# once in the loop, which *recognises* it — and that is deliberate: the loop has
# to see a trigger the operator typed by hand as well as one the seam posted.
# But if the two ever disagreed the loop would post one string and look for
# another, find autofix never spent, and fire again every pass forever against a
# metered budget. This project has already been bitten once by two copies of one
# thing drifting apart, so the copies are pinned to each other here — through a
# real run of the seam, so what is compared is the argv that reached the CLI and
# not a second reading of the source.
LOOP_TRIGGER=$(sed -n "s/^AUTOFIX_TRIGGER='\(.*\)'$/\1/p" "$SCRIPT")
check "the loop names a trigger at all" test -n "$LOOP_TRIGGER"
check_grep "--body $LOOP_TRIGGER" "$STUB_CALLS"

# The phase spends no worktree, no checkout and no agent, so `orca terminal`
# has left the daemon entirely.
check_no_grep "worktree create" "$STUB_CALLS"
check_no_grep "orca terminal" "$STUB_CALLS"
# Nothing the loop does resolves a review thread on my behalf.
check_no_grep "resolveReviewThread" "$STUB_CALLS"
check_no_grep "addPullRequestReviewThreadReply" "$STUB_CALLS"

# --- pr phase: the autofix clock, proven by a mutant twin ---------------------------

# The same world at two frozen instants either side of the bound. Nothing but
# $STUB_NOW differs, so whatever differs in the verdict is caused by the clock
# and by nothing else.

setup "an autofix inside its bound is in flight"
export STUB_WORLD=states STUB_NOW=2026-08-27T12:29:59Z
run_once
check_status 0 "$STATUS"
check_grep "#207 207a207a207a207a207a207a207a207a207a207a autofix-in-flight review=terminal threads=2 autofix=unspent age=5399 bound=5400" "$OUT"
check_no_grep "autofix-stalled" "$OUT"

setup "the same autofix one second past its bound is stalled"
export STUB_WORLD=states STUB_NOW=2026-08-27T12:30:01Z
run_once
check_status 0 "$STATUS"
check_grep "#207 207a207a207a207a207a207a207a207a207a207a autofix-stalled review=terminal threads=2 autofix=unspent age=5401 bound=5400" "$OUT"
check_no_grep "autofix-in-flight" "$OUT"
# A stalled autofix is logged and otherwise left alone: no second trigger, and
# no escalation until #29 builds one.
check "no trigger was posted for the stalled pull request" \
  test "$(grep -cF 'pr comment 207' "$STUB_CALLS")" -eq 0

# --- pr phase: once per head, proven across three replayed passes --------------------

# The strongest form of the sensitivity proof the spec asks for: the same
# assertion at successive passes with opposite verdicts, against captured worlds
# rather than a simulated one.

setup "the autofix trigger fires at most once per head commit"
PASS_N=0

# Pass one: reviewed, findings unresolved, autofix never attempted here.
replay autofix-once/pass1 2026-08-27T12:00:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#301 301a301a301a301a301a301a301a301a301a301a needs-autofix review=terminal threads=2 autofix=unspent action=triggered" "$PASS_LOG"
check "the trigger was posted once" test "$(grep -cF 'pr comment 301' "$STUB_CALLS")" -eq 1

# Pass two: my trigger is on the timeline, CodeRabbit has not answered, and the
# head has not moved. The findings are still unresolved — so the fire condition
# on its own would fire again here.
replay autofix-once/pass2 2026-08-27T12:30:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#301 301a301a301a301a301a301a301a301a301a301a autofix-in-flight review=terminal threads=2 autofix=unspent age=1795 bound=5400" "$PASS_LOG"
check "still exactly one trigger after the second pass" test "$(grep -cF 'pr comment 301' "$STUB_CALLS")" -eq 1

# Pass three: autofix answered, pushed nothing, and left every finding
# unresolved. Spent on this head all the same.
replay autofix-once/pass3 2026-08-27T13:00:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#301 301a301a301a301a301a301a301a301a301a301a assessable review=terminal threads=2 autofix=spent" "$PASS_LOG"
check "still exactly one trigger after the third pass" test "$(grep -cF 'pr comment 301' "$STUB_CALLS")" -eq 1

# --- pr phase: a failed autofix falls through, unparsed ------------------------------

# The same world as 206 in the omnibus case above, byte for byte, with only the
# autofix status comment's prose swapped for the failure shape — which shares no
# word with the success one. Identical verdict: what makes autofix spent is a
# status comment newer than the head, never what the comment says.
setup "a declined autofix falls through to assessable without its prose being read"
export STUB_WORLD=autofix-failed STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#206 206f206f206f206f206f206f206f206f206f206f assessable review=terminal threads=3 autofix=spent" "$OUT"
check "no trigger was posted at a head autofix has already been spent on" \
  test "$(grep -cF 'body @coderabbitai autofix' "$STUB_CALLS")" -eq 0

# --- pr phase: configuration order is the axis ---------------------------------------

setup "pull requests are enumerated per repository, in configuration order"
cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": 300,
  "maxWorkers": 3,
  "autofixTimeoutSeconds": 5400,
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "nywleswoey/automation", "orcaRepoId": "repo-aaa" },
    { "github": "nywleswoey/other", "orcaRepoId": "repo-bbb" }
  ]
}
JSON
export STUB_WORLD=two-repos STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#501 501a501a501a501a501a501a501a501a501a501a assessable" "$OUT"
check_grep "pr nywleswoey/other#502 502b502b502b502b502b502b502b502b502b502b assessable" "$OUT"
check "the first configured repository is enumerated first" \
  test "$(call_line 'name: "automation") { pullRequests(states: OPEN')" \
     -lt "$(call_line 'name: "other") { pullRequests(states: OPEN')"

# --- pr phase: the worker budget does not gate it -------------------------------------

setup "a full worker budget does not stop the PR phase"
# orca-ps-busy carries maxWorkers live loop workers, so the issue phase has
# nothing left to spend — and the PR phase spends none of it, because it opens
# no worktree, no checkout and no agent.
export STUB_ORCA_PS=busy STUB_ISSUES=workable
export STUB_WORLD=states STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "worker budget full" "$OUT"
check_grep "#204 204d204d204d204d204d204d204d204d204d204d needs-autofix" "$OUT"
check_grep "gh-axi pr comment 204 --repo nywleswoey/automation --body @coderabbitai autofix" "$STUB_CALLS"
check_no_grep "pr nywleswoey/automation#204 deferred" "$OUT"

# --- pr phase: failures are logged, the pass survives ----------------------------------

setup "a failed enumeration is logged and the pass continues"
export STUB_WORLD=states STUB_GH_FAIL=prs
run_once
check_status 0 "$STATUS"
check_grep "pr query failed: nywleswoey/automation" "$OUT"
check_grep "pass end dispatches=0 skips=1 sweeps=1" "$OUT"

setup "a failed per-pull-request read leaves that pull request alone"
export STUB_WORLD=states STUB_GH_FAIL=pr-state STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "pr state query failed: nywleswoey/automation#203" "$OUT"
check_no_grep "body @coderabbitai autofix" "$STUB_CALLS"

setup "a failed trigger is recorded on the state line and re-fired next pass"
export STUB_WORLD=states STUB_GH_FAIL=pr-comment STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "#204 204d204d204d204d204d204d204d204d204d204d needs-autofix review=terminal threads=2 autofix=unspent action=failed rc=1" "$OUT"
# Nothing is remembered, so nothing has to be unwound. The next pass re-derives,
# finds autofix still unspent on the same head, and fires again.
export STUB_GH_FAIL=""
run_once
check_status 0 "$STATUS"
check_grep "#204 204d204d204d204d204d204d204d204d204d204d needs-autofix review=terminal threads=2 autofix=unspent action=triggered" "$OUT"

setup "no open pull requests means no per-pull-request traffic"
run_once
check_status 0 "$STATUS"
check_grep 'repository(owner: "nywleswoey", name: "automation") { pullRequests(states: OPEN' "$STUB_CALLS"
check_no_grep "statusCheckRollup" "$STUB_CALLS"
check_no_grep "body @coderabbitai autofix" "$STUB_CALLS"
check_grep "pass end dispatches=0 skips=0 sweeps=1" "$OUT"

# --- config: the seen list is gone ------------------------------------------------------

# A key nothing reads would otherwise rot in the operator's file forever, since
# unknown keys are deliberately ignored.
setup "a config still naming the deleted seen list fails at startup"
cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": 300,
  "maxWorkers": 3,
  "autofixTimeoutSeconds": 5400,
  "seenListPath": "$WORK/seen.jsonl",
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "nywleswoey/automation", "orcaRepoId": "repo-aaa" }
  ]
}
JSON
run_once
check_status nonzero "$STATUS"
check_grep "config still names seenListPath" "$OUT"
check "no pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 0

setup "the autofix timeout is required, not defaulted"
cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": 300,
  "maxWorkers": 3,
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "nywleswoey/automation", "orcaRepoId": "repo-aaa" }
  ]
}
JSON
run_once
check_status nonzero "$STATUS"
check_grep "config is missing autofixTimeoutSeconds" "$OUT"
check "no pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 0

setup "the loop keeps no local state for the PR phase"
export STUB_WORLD=states STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "#207 207a207a207a207a207a207a207a207a207a207a autofix-in-flight" "$OUT"
# The phase used to leave three kinds of file beside the log: a seen list, a
# worker brief and a triage plan. A wait now leaves the log line above and
# nothing else, which is what makes the loop survive a crash, a `--once` run and
# a machine rebuild for free.
check "no seen list was written" \
  test "$(find "$WORK" -maxdepth 1 -name '*.jsonl' | wc -l | tr -d ' ')" -eq 0
check "no worker brief or triage plan was written" \
  test "$(find "$WORK" -maxdepth 1 -name 'agent-loop-pr-*' | wc -l | tr -d ' ')" -eq 0

# --- close-out phase -------------------------------------------------------------

# One pass over a fixture carrying every close-out case at once: a merged merge
# request whose issue is open and claimed, one whose issue has no checkboxes,
# one whose issue is already closed, one whose issue I claimed by hand, one from
# a branch that names no issue, one with the collision suffix, and one in a
# project the config does not list.
# The close and the unclaim are two calls in that order, so a failure can only
# ever leave the label on an issue that is already closed.
CLOSE_17="gh-axi issue close 17 --repo nywleswoey/automation"
UNCLAIM_17="gh-axi issue edit 17 --repo nywleswoey/automation --remove-label agent-in-progress"

setup "the close-out phase ticks and closes what it claimed and nothing else"
export STUB_MERGED=set
run_once
check_status 0 "$STATUS"
check_grep 'gh-axi api POST graphql --field query={ search(query: "is:pr is:merged author:nywleswoey sort:updated-desc"' "$STUB_CALLS"
check_grep "$CLOSE_17" "$STUB_CALLS"
check_grep "closed out nywleswoey/automation#17: pull request #201 merged" "$OUT"
# The description write lands before the close, so the tick is on the issue the
# close then freezes.
check "the tick precedes the close" test "$(call_line 'gh-axi issue edit 17 --repo nywleswoey/automation --body-file')" -lt "$(call_line "$CLOSE_17")"
check_grep "$UNCLAIM_17" "$STUB_CALLS"
check "the close precedes the unclaim" test "$(call_line "$CLOSE_17")" -lt "$(call_line "$UNCLAIM_17")"
# Every checkbox became ticked, nested ones included, and nothing else moved a
# byte — a `- [ ]` in a code span or mid-sentence is prose, not a checklist
# item, and GitHub counts it as neither.
printf '## Acceptance criteria\n\n- [x] First\n  - [x] Nested\n- [x] Second\n- [x] Third\n\nThe phase turns `- [ ] ` into `- [x] ` and leaves everything else alone.\nnot boxes: -[ ] and - [X] stay.\n' \
  > "$WORK/expected-17.txt"
check "the rewritten body differs only in the checkbox markers" \
  diff -q "$WORK/expected-17.txt" "$STUB_STATE/body-17.txt"

# 202 — issue 40 has no checkboxes, so it is closed with no description write.
check_grep "closed out nywleswoey/automation#40: pull request #202 merged" "$OUT"
check "no body was written for an issue with no checkboxes" \
  test ! -f "$STUB_STATE/body-40.txt"

# 203 — issue 41 is already closed: one read to find that out, and nothing else.
check_no_grep "issue 41 " "$STUB_CALLS"
check_no_grep "#41" "$OUT"

# 204 — issue 42 carries the ready label, not the claim: the loop did not claim
# it, so the loop does not touch it.
check_no_grep "issue 42 " "$STUB_CALLS"
check_no_grep "#42" "$OUT"

# 205 — issue 11's pull request closes issue 11 and never issue 1.
check_grep "closed out nywleswoey/automation#11: pull request #205 merged" "$OUT"
check_no_grep "issues/1 " "$STUB_CALLS"
check_no_grep "#1:" "$OUT"

# 206 — a name collision put the worker in agent-loop-issue-43-2, and Orca cut
# its branch under a namespace: `nywleswoey/agent-loop-issue-43-2`. Both the
# suffix and the prefix have to be seen through to reach issue 43.
check_grep "closed out nywleswoey/automation#43: pull request #206 merged" "$OUT"

# 207 — a branch that names no issue is a pull request I opened by hand.
# 907 — a merged pull request in a project the config does not list.
check_no_grep "issues/99" "$STUB_CALLS"
check_no_grep "#207" "$OUT"
check_no_grep "#907" "$OUT"

check "exactly four issues were closed" test "$(grep -cF 'gh-axi issue close ' "$STUB_CALLS")" -eq 4
# The close-out runs before the reclaim, so the pass that follows it sees the
# issues closed and repeats none of its own lines.
check "one close-out line per issue" test "$(grep -cF 'closed out nywleswoey/automation#17' "$OUT")" -eq 1

setup "an unmerged pull request leaves its issue alone"
# One open pull request, on the very branch the close-out phase reads issues out
# of: it must never reach the phase, because the phase asks GitHub for
# `state=merged` and nothing else. The PR phase does see it, which is what makes
# the close-out's silence a fact rather than an empty pass.
export STUB_WORLD=open-issue-branch STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#401 aaee17aaee17aaee17aaee17aaee17aaee17aaee assessable" "$OUT"
check_no_grep "gh-axi issue close" "$STUB_CALLS"
check_no_grep "issues/17 " "$STUB_CALLS"
check_no_grep "closed out" "$OUT"

setup "a closed-out issue is never handed back to the ready label"
export STUB_MERGED=set STUB_CLAIMED=mixed STUB_ORCA_PS=busy
run_once
check_status 0 "$STATUS"
check_grep "closed out nywleswoey/automation#11" "$OUT"
# #11 was closed out before the reclaim ran, so the reclaim never saw it — and
# #21, which no pull request names, is reclaimed exactly as before.
check_grep "reclaimed nywleswoey/automation#21" "$OUT"
check_no_grep "issue edit 11 --repo nywleswoey/automation --add-label ready-for-agent" "$STUB_CALLS"

setup "a failed checklist update is logged and the issue is closed anyway"
export STUB_MERGED=set STUB_GH_FAIL=body
run_once
check_status 0 "$STATUS"
check_grep "checklist update failed for nywleswoey/automation#17, closing it anyway" "$OUT"
check_grep "$CLOSE_17" "$STUB_CALLS"
check_grep "closed out nywleswoey/automation#17: pull request #201 merged" "$OUT"

setup "a failed close is logged and the pass continues"
export STUB_MERGED=set STUB_GH_FAIL=close
run_once
check_status 0 "$STATUS"
check_grep "close failed for nywleswoey/automation#17, leaving it claimed" "$OUT"
check_grep "pass start" "$OUT"
check_grep "pass end" "$OUT"

setup "a failed merged-pr query is logged and the pass continues"
export STUB_MERGED=set STUB_GH_FAIL=merged
run_once
check_status 0 "$STATUS"
check_grep "merged-pr query failed" "$OUT"
check_no_grep "gh-axi issue close" "$STUB_CALLS"
check_grep "pass end dispatches=0 skips=1 sweeps=1" "$OUT"

setup "a failed issue read is logged and the pass continues"
export STUB_MERGED=set STUB_GH_FAIL=issue
run_once
check_status 0 "$STATUS"
check_grep "close-out query failed: nywleswoey/automation#17" "$OUT"
check_no_grep "gh-axi issue close" "$STUB_CALLS"

setup "no merged pull requests means no close-out traffic"
run_once
check_status 0 "$STATUS"
check_no_grep "issues/" "$STUB_CALLS"
check_no_grep "closed out" "$OUT"

setup "the close-out query does not widen with the PR phase's scope"
run_once
check_status 0 "$STATUS"
# The open-pull-request read widened to every pull request in a configured
# repository. This one did not, and keeps its author filter: the branch name is
# the only pull-request-to-issue link there is, and the resolver behind it
# already drops a branch naming no issue.
check_grep 'query={ search(query: "is:pr is:merged author:nywleswoey sort:updated-desc"' "$STUB_CALLS"

# --- the deleted machinery ------------------------------------------------------

# The PR phase used to spend a worktree, a checkout and an Orca worker to
# produce fixes CodeRabbit writes itself from a one-line comment. Everything
# that served it is gone, and a grep is the cheapest guard against a piece of it
# coming back on the coat-tails of an unrelated change. Asserted on the source
# because these are absences, and an absence has no behaviour to observe.

setup "nothing of the PR worker survives in the daemon"
# `SEEN_LIST_PATH` is the one that matters: it is what the daemon read the
# configured path into, so its absence is the absence of every use of the seen
# list. `seenListPath` itself deliberately survives, in the tombstone that
# refuses a config still naming it, and is asserted by that config case above
# rather than counted here.
for _gone in SEEN_LIST_PATH SEEN_JSON load_seen_list count_eligible_threads \
             pr_worker_prompt dispatch_pr_fresh dispatch_pr_reuse pr_work_path \
             SWEEP_EXEMPT AGENT_LOOP_TUI_WAIT_MS; do
  check "$_gone is gone from agent-loop.sh" \
    test "$(grep -cF "$_gone" "$SCRIPT")" -eq 0
done
# `orca terminal` leaves the daemon entirely; only worktree creation survives,
# in the issue phase.
for _verb in create send wait; do
  check "orca terminal $_verb is gone from agent-loop.sh" \
    test "$(grep -cE "orca terminal +$_verb" "$SCRIPT")" -eq 0
done
check "the issue phase still creates worktrees" \
  test "$(grep -cF 'orca worktree create' "$SCRIPT")" -eq 1

# --- result ------------------------------------------------------------------

report
