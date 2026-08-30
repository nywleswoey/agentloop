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

# write_config <github-full-name> <orca-repo-id> [poll-interval-seconds] [max-workers] [autofix-timeout] [merge-gate-timeout] [merge-method]
write_config() {
  cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": ${3:-300},
  "maxWorkers": ${4:-3},
  "autofixTimeoutSeconds": ${5:-5400},
  "mergeGateTimeoutSeconds": ${6:-3600},
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "$1", "orcaRepoId": "$2", "mergeMethod": "${7:-squash}" }
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

setup "the reclaim asks for open claimed issues alone"
# A claim label stranded on a closed issue is invisible to the reclaim, and that
# is what stops it ever being re-dispatched — so close-out is free to take its
# time clearing one. The blindness is a clause in the query, so the query is
# where it is asserted: the fixtures are pre-filtered lists and could answer
# with a closed issue whatever the loop asked for.
export STUB_CLAIMED=mixed STUB_ORCA_PS=busy
run_once
check_status 0 "$STATUS"
check_grep 'gh-axi api POST graphql --field query={ repository(owner: "nywleswoey", name: "automation") { issues(labels: ["agent-in-progress"], states: OPEN, first: 100)' "$STUB_CALLS"

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

# --- an open pull request already delivers the issue ---------------------------

# A worker that finished leaves no process behind, which is exactly what a
# dispatch that crashed before it started leaves — so liveness alone cannot tell
# the two apart, and the reclaim used to read both as "nobody has worked on it".
# The evidence that separates them is an open pull request on the branch the
# dispatch asked for. Both doors onto an issue ask for it: the reclaim, and the
# issue phase, which a label applied by hand reaches without passing through the
# reclaim at all.
#
# The `open-issue-branch` world carries exactly one open pull request, #401 on
# `agent-loop-issue-17`.

setup "the reclaim leaves a claim whose pull request is open"
export STUB_CLAIMED=17 STUB_WORLD=open-issue-branch STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "left claimed nywleswoey/automation#17: pull request #401 already delivers it" "$OUT"
check_no_grep "--add-label ready-for-agent" "$STUB_CALLS"
# The pull request is still the PR phase's, which is what makes the reclaim's
# silence a decision rather than an empty pass.
check_grep "pr nywleswoey/automation#401" "$OUT"

setup "a claim no open pull request names is reclaimed exactly as before"
# #401 is on `agent-loop-issue-17`, and none of these four issues is 17. The
# number is anchored on both sides, so #1 must not read #17's pull request as
# its own.
export STUB_CLAIMED=mixed STUB_ORCA_PS=busy STUB_WORLD=open-issue-branch STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "reclaimed nywleswoey/automation#1:" "$OUT"
check_grep "reclaimed nywleswoey/automation#21" "$OUT"
check "exactly two issues were reclaimed" \
  test "$(grep -c -- '--add-label ready-for-agent' "$STUB_CALLS")" -eq 2

setup "a live worker is still answer enough on its own"
# The open-pull-request read is the second question, not a replacement for the
# first: #11 and #12 have workers and no pull request, and the line says so.
export STUB_CLAIMED=mixed STUB_ORCA_PS=busy STUB_WORLD=open-issue-branch STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "left claimed nywleswoey/automation#11: a live worker holds it" "$OUT"

setup "the issue phase skips a ready issue whose pull request is open"
export STUB_ISSUES=workable STUB_WORLD=open-issue-branch STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "issue nywleswoey/automation#17 skipped: pull request #401 already delivers it" "$OUT"
check_no_grep "issue edit" "$STUB_CALLS"
check_no_grep "worktree create" "$STUB_CALLS"
# Skipped before the blockers are read: an issue already delivered is not worth
# a second call to find out.
check_no_grep "issues/17/dependencies/blocked_by" "$STUB_CALLS"

setup "a draft pull request delivers its issue, though the PR phase ignores it"
# Drafts are exactly why the guard does not reuse the PR phase's enumeration:
# converting to draft is the operator's hold gesture, and work held back by hand
# is still work done. The PR phase's silence about #402 in the same pass is what
# makes the two reads visibly different rather than the same read twice.
export STUB_CLAIMED=17 STUB_WORLD=open-draft-branch STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "left claimed nywleswoey/automation#17: pull request #402 already delivers it" "$OUT"
check_no_grep "--add-label ready-for-agent" "$STUB_CALLS"
check_no_grep "pr nywleswoey/automation#402" "$OUT"

setup "an open pull request past the first page still delivers its issue"
# The one enumeration here that pages, because the single-page cap the others
# carry would fail *open* on this question: a pull request missing from the
# answer reads as "nothing delivers this issue", which is the duplicate dispatch
# the guard exists to stop. #411 is on the second page, and on a fork — the
# other exclusion the PR phase makes and this read deliberately does not.
export STUB_CLAIMED=17 STUB_WORLD=paged STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "left claimed nywleswoey/automation#17: pull request #411 already delivers it" "$OUT"
check_no_grep "--add-label ready-for-agent" "$STUB_CALLS"
check_no_grep "pr nywleswoey/automation#411" "$OUT"

setup "a single-page answer is never asked for a second page"
# The PR phase's read carries no cursor at all and the guard's first page asks
# `after: null`, so a world with no second page is proof the loop stopped: the
# stub makes a continuation it cannot answer a hard error rather than an empty
# one.
export STUB_CLAIMED=17 STUB_WORLD=open-issue-branch STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_no_grep "does not have" "$OUT"
check_grep "left claimed nywleswoey/automation#17: pull request #401 already delivers it" "$OUT"

setup "a merged pull request does not shield its issue from the reclaim"
# Deliberately excluded: merged pull requests are close-out's, and close-out
# runs first in both orderings. Counting them here would make an issue whose
# pull request merged but whose close-out failed look handled forever.
export STUB_CLAIMED=17 STUB_MERGED=set STUB_GH_FAIL=close
run_once
check_status 0 "$STATUS"
check_grep "close failed for nywleswoey/automation#17, leaving it claimed" "$OUT"
check_grep "reclaimed nywleswoey/automation#17" "$OUT"

setup "a reclaim that cannot ask about open pull requests reclaims nothing"
export STUB_CLAIMED=17 STUB_GH_FAIL=prs
run_once
check_status 0 "$STATUS"
check_grep "open-pr query failed: nywleswoey/automation, skipping its reclaim" "$OUT"
check_no_grep "--add-label ready-for-agent" "$STUB_CALLS"

setup "an issue phase that cannot ask about open pull requests dispatches nothing"
export STUB_ISSUES=workable STUB_GH_FAIL=prs
run_once
check_status 0 "$STATUS"
check_grep "open-pr query failed: nywleswoey/automation, skipping its issue phase" "$OUT"
check_no_grep "issue edit" "$STUB_CALLS"
check_no_grep "worktree create" "$STUB_CALLS"

setup "an empty backlog costs no open-pull-request read"
export STUB_ISSUES=none
run_once
check_status 0 "$STATUS"
check_no_grep "open-pr query failed" "$OUT"

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
# review that has to be terminal is the reviewer's own. Two CodeRabbit statuses
# three seconds apart carry the appended-status shape, and the clock runs from
# the older of them.
check_grep "pr nywleswoey/automation#203 203c203c203c203c203c203c203c203c203c203c reviewing review=pending threads=0 autofix=unspent age=230 bound=3600 origin=pending" "$OUT"

# 204 — the review finished with unresolved findings and no autofix has been
# attempted at this head. Two of its four threads count: one is resolved, and
# one I opened myself, which is a conversation rather than a finding.
check_grep "pr nywleswoey/automation#204 204d204d204d204d204d204d204d204d204d204d needs-autofix review=terminal threads=2 autofix=unspent action=triggered" "$OUT"

# 205 — reviewed, nothing unresolved to fix. It is the first pull request in
# this repository the gate clears, so it is the one that gets merged.
check_grep "pr nywleswoey/automation#205 205e205e205e205e205e205e205e205e205e205e assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=merged method=squash" "$OUT"

# 206 — autofix already ran at this head. Its findings are *still* unresolved,
# because autofix does not resolve what it fixes, and it is assessable anyway:
# unresolved threads are input to the fix trigger and to nothing else. It clears
# the gate as well, and is deferred to the next pass by the one-merge-per-
# repository bound — 205 has already moved the base under it.
#
# The spent token names **which** of the two sufficient reasons spent it. An
# operator asking why autofix did not fire cannot answer it from a blind
# *spent*, and this one is the trigger's.
check_grep "pr nywleswoey/automation#206 206f206f206f206f206f206f206f206f206f206f assessable review=terminal threads=3 autofix=spent:trigger verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=deferred bound=merge-per-repo" "$OUT"

# 207 — triggered an hour ago, CodeRabbit has not answered, still inside the
# bound.
check_grep "pr nywleswoey/automation#207 207a207a207a207a207a207a207a207a207a207a autofix-in-flight review=terminal threads=2 autofix=unspent age=3600 bound=5400" "$OUT"

# 208 and 212 — opened by a bot, and merging into a release branch rather than
# trunk. Neither is an exclusion: the rule has exactly two, and these are the
# two most often mistaken for a third.
check_grep "pr nywleswoey/automation#208 208b208b208b208b208b208b208b208b208b208b assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok" "$OUT"
check_grep "pr nywleswoey/automation#212 212f212f212f212f212f212f212f212f212f212f assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok" "$OUT"

# 209 and 210 — CodeRabbit reporting through a check run and no legacy status at
# all, which is the surface its own changelog says is now the default and which
# this account does not in fact emit. Both are read, either one terminal is
# terminal, and the pair differs only in the check run's status.
check_grep "pr nywleswoey/automation#209 209c209c209c209c209c209c209c209c209c209c assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok" "$OUT"
# 210's head is two and a half hours old and its check run started ninety
# seconds ago, which is the shape the review clock's origin was chosen for: a
# bound run from `headDate` would have expired this pull request the instant a
# legitimate review began.
check_grep "pr nywleswoey/automation#210 210d210d210d210d210d210d210d210d210d210d reviewing review=pending threads=0 autofix=unspent age=100 bound=3600 origin=pending" "$OUT"

# 211 — nothing rolled up on the head commit at all and no merge-risk block
# anywhere on the pull request, which is what a pull request CodeRabbit has
# never looked at reports. Absence is a real state, not a read that failed: one
# real pull request sat in exactly this shape for four and a half hours.
#
# Both of those routes hold at once here, and the tail says so rather than a
# second state name being invented for the pair.
check_grep "pr nywleswoey/automation#211 211e211e211e211e211e211e211e211e211e211e needs-review review=pending threads=0 autofix=unspent route=no-signal,no-block action=nudged" "$OUT"
# The remedy is a write, because the cause does not clear on its own: the
# review pause resets its counter only when the pause is lifted, and lifting it
# is a command.
check_grep "gh-axi pr comment 211 --repo nywleswoey/automation --body @coderabbitai review" "$STUB_CALLS"

# The commit named is the head, never a commit out of CodeRabbit's prose. The
# autofix status comment on 206 names a different one on purpose.
check_no_grep "dec0dec0dec0dec0dec0dec0dec0dec0dec0dec0" "$OUT"

# Exactly one line per pull request, and exactly one action across the pass.
check "one state line per pull request" test "$(grep -cE '^[0-9TZ:-]+ pr nywleswoey/automation#' "$OUT")" -eq 10
# Four of these clear the gate and exactly one of them is merged, which is the
# bound running along the axis configuration order provides.
check "exactly one merge this pass" \
  test "$(grep -cE 'pulls/[0-9]+/merge' "$STUB_CALLS")" -eq 1
check "and it is the first candidate, not any of the ones behind it" \
  test "$(grep -cF '/pulls/205/merge' "$STUB_CALLS")" -eq 1

# --- pr phase: the action goes through the real seam --------------------------------

# The loop has never once executed pr-writeback.sh: it used to embed the command
# as text in a worker's prompt and this suite grepped that string. With the
# worker deleted the chain runs unbroken from the loop to the CLI argv, which is
# the only reason the line below is observable at all.
check_grep "gh-axi pr comment 204 --repo nywleswoey/automation --body @coderabbitai autofix" "$STUB_CALLS"
check_grep "<!-- agent-loop-autofix-head: 204d204d204d204d204d204d204d204d204d204d -->" "$STUB_CALLS"
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

# The review nudge is spelled twice for the same reason and drifts the same way,
# except worse: the loop would nudge every pass forever, having never once
# recognised what it posted.
LOOP_NUDGE=$(sed -n "s/^REVIEW_TRIGGER='\(.*\)'$/\1/p" "$SCRIPT")
check "the loop names a review nudge at all" test -n "$LOOP_NUDGE"
check_grep "--body $LOOP_NUDGE" "$STUB_CALLS"

# The merge-risk block's parse is spelled **once**. Two readers need it — the
# chain, to ask whether the verdict names this head, and the gate, to judge the
# level it carries — and they read the block at deliberately different scopes,
# so a second copy is how they come to disagree about which commit a verdict
# covers. That is the one disagreement neither of them could detect from its own
# side, so the count is pinned here.
check "the capture is written exactly once" \
  test "$(grep -cF 'up to `(?<abbrev>' "$SCRIPT")" -eq 1
check "and both readers take it by definition" \
  test "$(grep -cF '"$RISK_BLOCK_PARSE"' "$SCRIPT")" -eq 2

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
check_grep "#207 207a207a207a207a207a207a207a207a207a207a autofix-stalled review=terminal threads=2 autofix=unspent age=5401 bound=5400 action=escalated kind=stalled label=added" "$OUT"
check_no_grep "autofix-in-flight" "$OUT"
# A stalled autofix is handed over, never re-triggered: the command CodeRabbit
# did not answer is not the command to send again.
check "no second trigger was posted for the stalled pull request" \
  test "$(grep -cF 'pr comment 207 --repo nywleswoey/automation --body @coderabbitai autofix' "$STUB_CALLS")" -eq 0

# --- pr phase: the needs-review predicate --------------------------------------------

# `needs-review` is three clauses — no CodeRabbit signal on the head, no
# merge-risk block anywhere on the pull request, or a block that parses and
# names some other commit — and this world separates all three, because a
# predicate whose clauses are only ever true together is one clause wearing
# three names.
setup "a pull request with no verdict on its head reaches needs-review by every route"
export STUB_WORLD=unreviewed STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"

# 260 — the false green. A `success` CodeRabbit status does not mean the code
# was reviewed: a draft gets one too, with a *review skipped* description, and
# un-drafting is not a push, so the head never moves. The discriminator is the
# **absent artifact**, not the status and not the description — the description
# is captured in the fixture and nothing reads it.
check_grep "pr nywleswoey/automation#260 260a260a260a260a260a260a260a260a260a260a needs-review review=terminal threads=0 autofix=unspent route=no-block action=nudged" "$OUT"
check_grep "gh-axi pr comment 260 --repo nywleswoey/automation --body @coderabbitai review" "$STUB_CALLS"
# The green status did not reach the gate, so the gate's tripwire never fired.
check_no_grep "#260 260a260a260a260a260a260a260a260a260a260a assessable" "$OUT"

# 261 — the rate-limit path posts a *passing check*, which is a second and
# independent route to the same false green. The predicate is cause-blind, so it
# catches this one too — and the rate-limit marker is tested first, so a
# throttled reviewer waits instead of escalating the queue.
check_grep "pr nywleswoey/automation#261 261b261b261b261b261b261b261b261b261b261b rate-limited review=terminal threads=0 autofix=unspent route=no-block" "$OUT"
check "a throttled pull request is not nudged" \
  test "$(grep -cF 'pr comment 261 --repo nywleswoey/automation --body @coderabbitai review' "$STUB_CALLS")" -eq 0
check_no_grep "#261 261b261b261b261b261b261b261b261b261b261b assessable" "$OUT"

# 262 — nothing rolled up on the head at all, and a merge-risk block that does
# name it. The first clause holds alone, which is what makes it a clause.
check_grep "pr nywleswoey/automation#262 262c262c262c262c262c262c262c262c262c262c needs-review review=pending threads=0 autofix=unspent route=no-signal action=nudged" "$OUT"
check_grep "gh-axi pr comment 262 --repo nywleswoey/automation --body @coderabbitai review" "$STUB_CALLS"

# 263 — what a nudge that **worked** leaves behind. The skipped-review green
# status is still on the head, because un-drafting is not a push and the head
# never moved, and the review the nudge started has landed a pending status
# beside it. Terminal is decided by the **newest** signal, so this is a review in
# progress; decided by *any* signal it would read as finished, keep calling it
# needs-review, and hand it over one poll interval into a review that was
# running.
check_grep "pr nywleswoey/automation#263 263d263d263d263d263d263d263d263d263d263d reviewing review=pending threads=0 autofix=unspent age=120 bound=3600 origin=pending" "$OUT"
check "a review that started is not nudged again" \
  test "$(grep -cF 'pr comment 263 --repo nywleswoey/automation --body @coderabbitai review' "$STUB_CALLS")" -eq 0
check_no_grep "#263 263d263d263d263d263d263d263d263d263d263d nudge" "$OUT"

# 264 — the third clause, and the case the whole state was reshaped for: an
# autofix head. CodeRabbit put a nine-second *Review completed* on it and will
# not re-walkthrough its own commit, so the newest block still names the parent.
# V1's prefix test alone would veto this permanently, on a cause the loop's own
# write produced; the chain repairs it with the nudge instead.
#
# The tail carries the other half of the same rule on the same line: the head is
# CodeRabbit's own output, so autofix is spent on it before any trigger is
# considered — and `needs-review` sits ahead of `needs-autofix`, so the
# unresolved finding here is nudged for a verdict rather than fixed.
check_grep "pr nywleswoey/automation#264 264e264e264e264e264e264e264e264e264e264e needs-review review=terminal threads=1 autofix=spent:own-head route=other-head action=nudged" "$OUT"
check_grep "gh-axi pr comment 264 --repo nywleswoey/automation --body @coderabbitai review" "$STUB_CALLS"
check "no autofix is fired at a head CodeRabbit wrote" \
  test "$(grep -cF 'body @coderabbitai autofix' "$STUB_CALLS")" -eq 0
# The abbreviation really is the parent's rather than the head's, and the head
# really is CodeRabbit's — both pinned, so a fixture edited into agreement would
# fail here rather than quietly stop testing the clause.
check "264's newest block names a commit that is not its head" \
  test "$(jq -r '.data.repository.pullRequest.comments.nodes[0].body | test("up to .264e") | not' "$FIXTURES/worlds/unreviewed/pr-264.json")" = "true"
check "264's head commit is CodeRabbit's own" \
  test "$(jq -r '.data.repository.pullRequest.commits.nodes[-1].commit.author.user.login' "$FIXTURES/worlds/unreviewed/pr-264.json")" = "coderabbitai[bot]"

# The block test is per **pull request**, not per head, which is what leaves V1
# untouched: a block that is present but stale stays the gate's call exactly as
# written. Nothing here was merged and nothing was handed over.
check "nothing was merged" test "$(grep -cE 'pulls/[0-9]+/merge' "$STUB_CALLS")" -eq 0
check_no_grep "action=escalated" "$OUT"
check "one state line per pull request" \
  test "$(grep -cE '^[0-9TZ:-]+ pr nywleswoey/automation#' "$OUT")" -eq 5

# --- pr phase: the nudge chain ------------------------------------------------------

# Three whole-world snapshots: the nudge, the wait, and the handover — then the
# head moving and the whole thing starting again. The bound is one poll interval
# and there is no new config key behind it.
setup "a pull request needing a review is nudged once, then handed over"
PASS_N=0

# Pass one: no status, no block, no nudge. The loop writes.
replay nudge/pass1 2026-08-27T11:50:30Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#272 272a272a272a272a272a272a272a272a272a272a needs-review review=pending threads=0 autofix=unspent route=no-signal,no-block action=nudged" "$PASS_LOG"
check_grep "gh-axi pr comment 272 --repo nywleswoey/automation --body @coderabbitai review" "$STUB_CALLS"
# The incremental review command, not the resume command: it is the measured
# one, and it cleared a real four-and-a-half-hour wedge.
check_no_grep "@coderabbitai resume" "$STUB_CALLS"

# Pass two: the nudge is on the timeline and CodeRabbit has said nothing that
# reaches the head. One second inside the bound.
#
# The nudge comment was created at 11:55:00 and edited at 11:59:50. The created
# timestamp is the tested one — correct here specifically because **the loop
# authors it**; the updated-timestamp binding is about comments CodeRabbit
# edits. Read the updated one and this pass would be nine seconds old.
replay nudge/pass2 2026-08-27T11:59:59Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#272 272a272a272a272a272a272a272a272a272a272a nudge-in-flight review=pending threads=0 autofix=unspent route=no-signal,no-block age=299 bound=300" "$PASS_LOG"
check "once per head: no second nudge" \
  test "$(grep -cF 'pr comment 272 --repo nywleswoey/automation --body @coderabbitai review' "$STUB_CALLS")" -eq 1
check_no_grep "action=escalated" "$PASS_LOG"

# The mutant twin: the same world two seconds later, past the bound.
setup "the same nudge one second past its bound is handed over"
PASS_N=0
replay nudge/pass2 2026-08-27T12:00:01Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#272 272a272a272a272a272a272a272a272a272a272a nudge-stalled review=pending threads=0 autofix=unspent route=no-signal,no-block age=301 bound=300 action=escalated kind=stalled label=added" "$PASS_LOG"
check_no_grep "nudge-in-flight" "$PASS_LOG"
check "the stalled nudge is not sent again" \
  test "$(grep -cF 'pr comment 272 --repo nywleswoey/automation --body @coderabbitai review' "$STUB_CALLS")" -eq 0

BODY="$STUB_STATE/pr-body-272.txt"
check "the escalation body was captured" test -f "$BODY"
# `stalled`, not `stuck`: a command was triggered and CodeRabbit never answered.
check "the first line names the kind" \
  test "$(head -1 "$BODY")" = '**Escalated — `stalled`:** a CodeRabbit command was triggered and CodeRabbit never reported inside its bound.'
# The bound is cause-blind, so the documented non-triggers are never tracked —
# but the two the operator can actually do something about are named. This is
# the **two older routes'** text, and it is right here: CodeRabbit put nothing
# at all on this head. The third route gets its own, below.
check_grep "not be installed on this repository, or the organisation may be out of seats" "$BODY"
check_grep "age=301s bound=300s nudge=2026-08-27T11:55:00Z route=no-signal,no-block" "$BODY"
# No CodeRabbit prose is parsed. The reply is read once, here, and shipped
# verbatim as a raw value — nothing keys on it.
check_grep "CodeRabbit's reply to the nudge, verbatim and unparsed" "$BODY"
check_grep "**Actions performed**" "$BODY"
check_grep "Review triggered." "$BODY"

# Pass three: the head moved. The handover names the commit before it, the nudge
# is now older than the head, and the pull request is nudged again — which is
# the stated cost of a one-shot command.
setup "a new head is nudged again"
PASS_N=0
replay nudge/pass3 2026-08-27T12:15:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#272 272b272b272b272b272b272b272b272b272b272b needs-review review=pending threads=0 autofix=unspent route=no-signal,no-block action=nudged" "$PASS_LOG"
check_grep "gh-axi pr comment 272 --repo nywleswoey/automation --body @coderabbitai review" "$STUB_CALLS"
check_no_grep "272b272b272b272b272b272b272b272b272b272b escalated" "$PASS_LOG"

# --- pr phase: the third route's own chain ------------------------------------------

# The route the state was reshaped for, on the same two-pass shape as the nudge
# chain above: nudged at the head, handed over one poll interval later — and the
# handover's `no` row says something the other two routes' text cannot.
#
# 280's head is a **force push** rather than an autofix commit, which is the
# point: the clause is cause-blind, and discriminating between the two would
# need exactly the commit ancestry and authorship the V1 relaxation was rejected
# for. The remedy is the same either way.

setup "a verdict pinned to another commit is nudged"
PASS_N=0
replay other-head/pass1 2026-08-27T11:55:30Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#280 280a280a280a280a280a280a280a280a280a280a needs-review review=terminal threads=0 autofix=unspent route=other-head action=nudged" "$PASS_LOG"
check_grep "gh-axi pr comment 280 --repo nywleswoey/automation --body @coderabbitai review" "$STUB_CALLS"
# It never reached the gate, so V1's abbreviation branch never fired: that
# branch is now unreachable by construction and is kept only for the scope
# asymmetry between the two readers.
check_no_grep "280a280a280a280a280a280a280a280a280a280a assessable" "$PASS_LOG"
check_no_grep "action=escalated" "$PASS_LOG"

setup "the same verdict one second past the nudge's bound is handed over"
PASS_N=0
replay other-head/pass2 2026-08-27T12:00:01Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#280 280a280a280a280a280a280a280a280a280a280a nudge-stalled review=terminal threads=0 autofix=unspent route=other-head age=301 bound=300 action=escalated kind=stalled label=added" "$PASS_LOG"

OTHER_BODY="$STUB_STATE/pr-body-280.txt"
check "the escalation body was captured" test -f "$OTHER_BODY"
# **The `no` row branches on the route.** Every clause of the older text is
# false here — CodeRabbit is installed, has seats, and reported on this head in
# eleven seconds — so saying it would send the operator to look at a seat count
# when the real state is a verdict pinned to another commit.
check_grep "CodeRabbit reviewed this head and left its merge-risk verdict on another commit" "$OTHER_BODY"
check_no_grep "not be installed on this repository, or the organisation may be out of seats" "$OTHER_BODY"
check_grep "age=301s bound=300s nudge=2026-08-27T11:55:00Z route=other-head" "$OTHER_BODY"
# The kind is still `stalled` — a command was triggered and CodeRabbit never
# moved the verdict — and the route is on the passing row as well.
check "the first line names the kind" \
  test "$(head -1 "$OTHER_BODY")" = '**Escalated — `stalled`:** a CodeRabbit command was triggered and CodeRabbit never reported inside its bound.'
check_grep "route=other-head head=2026-08-27T11:50:00Z" "$OTHER_BODY"
check "the stalled nudge is not sent again" \
  test "$(grep -cF 'pr comment 280 --repo nywleswoey/automation --body @coderabbitai review' "$STUB_CALLS")" -eq 0

# 281 — the one route that can join the third, and the mutant that pins the
# lookup's exact match. Nothing at all rolled up on this head *and* the newest
# block names another commit, so both clauses fire. The older text is the true
# one here — CodeRabbit really did put nothing on this head — so the branch
# above must **not** take the third route's prose.
#
# `no-block` cannot join `other-head`: no block anywhere leaves nothing to parse
# an abbreviation out of. This is the only pairing there is.
check_grep "pr nywleswoey/automation#281 281b281b281b281b281b281b281b281b281b281b nudge-stalled review=pending threads=0 autofix=unspent route=no-signal,other-head age=301 bound=300 action=escalated kind=stalled label=added" "$PASS_LOG"
BOTH_BODY="$STUB_STATE/pr-body-281.txt"
check "the escalation body was captured" test -f "$BOTH_BODY"
check_grep "not be installed on this repository, or the organisation may be out of seats" "$BOTH_BODY"
check_no_grep "CodeRabbit reviewed this head and left its merge-risk verdict on another commit" "$BOTH_BODY"
check_grep "age=301s bound=300s nudge=2026-08-27T11:55:00Z route=no-signal,other-head" "$BOTH_BODY"

# --- pr phase: the review clock, proven by a mutant twin ----------------------------

# A pending status with nothing after it. This is a gate-style defer — *a signal
# not yet computed* is its exact definition — so it reuses the gate's key. Its
# **origin** is not the gate's: a real pull request sat four and a half hours
# between its head commit and its review starting.
#
# The head here is at 07:00 and the review started at 11:00. A clock from
# `headDate` would read 17999 seconds at the first instant below and hand the
# pull request over while CodeRabbit was working on it.

setup "a review inside the gate clock is still reviewing"
export STUB_WORLD=review-clock STUB_NOW=2026-08-27T11:59:59Z
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#250 250a250a250a250a250a250a250a250a250a250a reviewing review=pending threads=0 autofix=unspent age=3599 bound=3600 origin=pending" "$OUT"
check_no_grep "review-stuck" "$OUT"
# **No nudge on this path.** CodeRabbit has already acknowledged the work, the
# command is documented for the paused case, and a pending status is not a
# pause.
check_no_grep "@coderabbitai review" "$STUB_CALLS"

# 251 — a check run GitHub queued and never started, so its `startedAt` is null
# and the signal names no instant of its own. The head is the fallback origin,
# and the line says which one it used: a bound whose origin is not on the record
# cannot be checked against it.
check_grep "pr nywleswoey/automation#251 251b251b251b251b251b251b251b251b251b251b reviewing review=pending threads=0 autofix=unspent age=3599 bound=3600 origin=head" "$OUT"

setup "the same review one second past the gate clock is stuck"
export STUB_WORLD=review-clock STUB_NOW=2026-08-27T12:00:01Z
run_once
check_status 0 "$STATUS"
# Oldest pending, not newest. The two progress statuses land three seconds
# apart: read the newer one and this is 3598 seconds old and still reviewing.
check_grep "pr nywleswoey/automation#250 250a250a250a250a250a250a250a250a250a250a review-stuck review=pending threads=0 autofix=unspent age=3601 bound=3600 origin=pending action=escalated kind=stuck label=added" "$OUT"
check_no_grep "reviewing review=pending" "$OUT"
check_no_grep "@coderabbitai review" "$STUB_CALLS"
# 251's twin. No state in this phase waits without a bound, including the one
# whose signal reports no timestamp at all.
check_grep "pr nywleswoey/automation#251 251b251b251b251b251b251b251b251b251b251b review-stuck review=pending threads=0 autofix=unspent age=3601 bound=3600 origin=head action=escalated kind=stuck label=added" "$OUT"

BODY="$STUB_STATE/pr-body-250.txt"
check "the escalation body was captured" test -f "$BODY"
# `stuck`, not `stalled`, and the kind is what tells the operator whether to
# read the diff: CodeRabbit answered and is still thinking.
check "the first line names the kind" \
  test "$(head -1 "$BODY")" = '**Escalated — `stuck`:** signals are undecided and waiting will not decide them.'
check_grep "| ok | CodeRabbit acknowledged this commit — the review started | \`oldest-pending=2026-08-27T11:00:00Z origin=pending head=2026-08-27T07:00:00Z\` |" "$BODY"
check_grep "| no | the review has not finished inside the gate clock | \`age=3601s bound=3600s\` |" "$BODY"
check_grep "<!-- agent-loop-escalated: 250a250a250a250a250a250a250a250a250a250a stuck -->" "$BODY"

# --- pr phase: the handover ----------------------------------------------------------

# Escalation is a handover, not a notification, and the facts that make it are
# asserted here across five replayed passes: while a record stands at a head the
# loop stops acting, a record whose kind the chain re-derives unchanged is held
# rather than re-written, and when the head moves the record stops matching —
# the flag chasing it off on the same pass.

setup "a stalled autofix is handed over, and the handover is not repeated"
PASS_N=0

# Pass one: the trigger is a second past its bound and CodeRabbit never
# answered. The record goes up, then the flag.
replay escalation/pass1 2026-08-27T12:30:01Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#601 601a601a601a601a601a601a601a601a601a601a autofix-stalled review=terminal threads=2 autofix=unspent age=5401 bound=5400 action=escalated kind=stalled label=added handover=posted" "$PASS_LOG"

# Comment then label, in that order, both through the real seam. The order is
# what self-heals: the reverse would flag a pull request whose record never
# landed and re-post it every pass after.
check_grep "gh-axi pr comment 601 --repo nywleswoey/automation --body-file " "$STUB_CALLS"
check_grep "gh-axi pr edit 601 --repo nywleswoey/automation --add-label agent-escalated" "$STUB_CALLS"
check "the comment is written before the label" \
  test "$(call_line 'pr comment 601 --repo nywleswoey/automation --body-file')" \
     -lt "$(call_line 'pr edit 601 --repo nywleswoey/automation --add-label')"

# The record itself. Free text cannot survive the flattened argv line, so the
# stub keeps the body file byte for byte and it is read back here.
BODY="$STUB_STATE/pr-body-601.txt"
check "the escalation body was captured" test -f "$BODY"
# The kind is the first line, because it is what tells the operator whether to
# read the diff or go and look at CodeRabbit.
check "the first line names the kind" \
  test "$(head -1 "$BODY")" = '**Escalated — `stalled`:** a CodeRabbit command was triggered and CodeRabbit never reported inside its bound.'
# Every reason, and the raw values behind each — including the condition that
# **passed**, because the operator is owed the whole picture the phase saw.
check_grep "| ok | CodeRabbit's review finished on this commit | \`review=terminal threads=2\` |" "$BODY"
check_grep "| no | the autofix trigger has gone unanswered past its bound | \`trigger=2026-08-27T11:00:00Z age=5401s bound=5400s head=2026-08-27T10:30:00Z\` |" "$BODY"
# The three gestures that already exist. This is what makes it a handover.
check_grep "**Merge it by hand.**" "$BODY"
check_grep "**Push a commit.**" "$BODY"
check_grep "**Convert it to draft.**" "$BODY"
check_grep "There is no override label." "$BODY"
# The marker, stamped with the head **and the kind** — the second is what lets a
# later pass tell *this same claim, still true* from *a different claim about
# the same commit*.
check_grep "<!-- agent-loop-escalated: 601a601a601a601a601a601a601a601a601a601a stalled -->" "$BODY"
check_no_grep "<!-- agent-loop-escalated: 601b601b601b601b601b601b601b601b601b601b" "$BODY"
# The sentence that had to change. The record promises a duration the loop now
# honours, and says who ends it.
check_grep "while this record stands" "$BODY"
check_no_grep "until the head moves" "$BODY"
check_grep "**withdraws this record on its own**" "$BODY"
# The read timestamp goes once, above the table, so every row below it reads as
# an observation made at one instant rather than as a standing claim.
check "the read timestamp sits above the table" \
  test "$(grep -n 'Read at 2026-08-27T12:30:01Z.' "$BODY" | cut -d: -f1)" \
     -lt "$(grep -n '| Verdict | What | Raw values |' "$BODY" | cut -d: -f1)"
# And the legend below it, which is what keeps a `defer` row beside a `no` row
# from being read as a second finding.
check "the legend sits below the table" \
  test "$(grep -n 'blocked the merge' "$BODY" | cut -d: -f1)" \
     -gt "$(grep -n '| Verdict | What | Raw values |' "$BODY" | cut -d: -f1)"
check_grep "**Ways back in** — none of them required; the loop may clear this itself." "$BODY"
# The captured world the next passes replay carries the loop's own words rather
# than a paraphrase of them, so a change to the body cannot quietly stop the
# marker being found.
check "the world the next pass replays carries the body just posted" \
  test "$(jq -r '.data.repository.pullRequest.comments.nodes[] | select((.body | contains("agent-loop-escalated"))) | .body' "$FIXTURES/worlds/escalation/pass2/pr-601.json")" = "$(cat "$BODY")"

# Pass two: the record is on the timeline and the flag is on the pull request.
# **The chain re-derives all the way to the state it derived before** — the line
# says `autofix-stalled`, not `escalated`, because that is what this pull
# request is — and the record is held rather than re-written, because the kind
# it carries is the kind the chain just derived again.
replay escalation/pass2 2026-08-27T13:00:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#601 601a601a601a601a601a601a601a601a601a601a autofix-stalled review=terminal threads=2 autofix=unspent age=7200 bound=5400 handover=held label=present" "$PASS_LOG"
# The state formerly known as escalated is gone. It was never a state — no
# signal put a pull request in it — and a chain that re-derives has nothing left
# to park in.
check_no_grep "601a601a601a601a601a601a601a601a601a601a escalated" "$PASS_LOG"
check "held writes nothing at all" \
  test "$(grep -cE 'issues/comments/' "$STUB_CALLS")" -eq 0
check "still exactly one escalation comment" \
  test "$(grep -cF 'pr comment 601 --repo nywleswoey/automation --body-file' "$STUB_CALLS")" -eq 1
check "still exactly one label add" \
  test "$(grep -cF 'pr edit 601 --repo nywleswoey/automation --add-label' "$STUB_CALLS")" -eq 1
# Detection cost nothing: the marker is in the comment timeline the derivation
# already reads, so no read was made for it.
check "the head is still read exactly once per pass" \
  test "$(grep -cF 'pullRequest(number: 601)' "$STUB_CALLS")" -eq 2

# Pass three: the flag is gone — removed by hand, or its write failed — and the
# record still stands. The label is re-added and nothing is posted. This is the
# self-heal the write order was chosen for.
replay escalation/pass3 2026-08-27T13:30:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#601 601a601a601a601a601a601a601a601a601a601a autofix-stalled review=terminal threads=2 autofix=unspent age=9000 bound=5400 handover=held label=added" "$PASS_LOG"
check "the label was added a second time" \
  test "$(grep -cF 'pr edit 601 --repo nywleswoey/automation --add-label agent-escalated' "$STUB_CALLS")" -eq 2
check "and no second comment was posted" \
  test "$(grep -cF 'pr comment 601 --repo nywleswoey/automation --body-file' "$STUB_CALLS")" -eq 1

# Pass four: the head moved. The record names the commit before it, so it no
# longer matches, the loop acts — and **the flag comes off on the same pass**,
# because the label chases the marker in both directions. The chase is delivery
# rather than action, so it runs alongside the trigger instead of consuming it.
replay escalation/pass4 2026-08-27T14:05:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#601 601b601b601b601b601b601b601b601b601b601b needs-autofix review=terminal threads=2 autofix=unspent action=triggered label=removed" "$PASS_LOG"
check_no_grep "601b601b601b601b601b601b601b601b601b601b escalated" "$PASS_LOG"
check_grep "gh-axi pr comment 601 --repo nywleswoey/automation --body @coderabbitai autofix" "$STUB_CALLS"
check_grep "gh-axi pr edit 601 --repo nywleswoey/automation --remove-label agent-escalated" "$STUB_CALLS"
# The record naming the old head is left exactly where it is. Nothing was edited
# — a record of a handover that is over is history, not a false claim.
check "a record at a head that has moved on is not rewritten" \
  test "$(grep -cE 'issues/comments/' "$STUB_CALLS")" -eq 0

# Pass five: the new head stalls the same way, so it is escalated again — and
# only because it failed again. The new record names the new commit.
replay escalation/pass5 2026-08-27T15:35:01Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#601 601b601b601b601b601b601b601b601b601b601b autofix-stalled review=terminal threads=2 autofix=unspent age=5401 bound=5400 action=escalated kind=stalled label=added handover=posted" "$PASS_LOG"
check "one escalation per head, and two heads have now failed" \
  test "$(grep -cF 'pr comment 601 --repo nywleswoey/automation --body-file' "$STUB_CALLS")" -eq 2
check_grep "<!-- agent-loop-escalated: 601b601b601b601b601b601b601b601b601b601b stalled -->" "$STUB_STATE/pr-body-601.txt"
# The record at the new head is a **new comment**, not an edit of the one at the
# old head: the handover write is deliberately not metered per head, and the
# comment the loop may edit is only ever one carrying a marker for the head
# being derived.
check "no comment was edited across all five passes" \
  test "$(grep -cE 'issues/comments/' "$STUB_CALLS")" -eq 0

# The flag came off exactly once — on the pass after the marker stopped matching
# — and went back on when a new record went up. Five passes and two heads have
# gone by above, so the chase has a run of real behaviour behind it rather than
# standing alone.
check "the flag came off once, on the pass the marker stopped matching" \
  test "$(grep -cE 'gh-axi pr edit .*--remove-label agent-escalated' "$STUB_CALLS")" -eq 1

# --- pr phase: the handover's failure modes -------------------------------------------

# The asymmetry the whole path rests on: delivery is retried until it lands, and
# the action it reports is never retried. Which half failed decides which.

setup "a handover whose comment never lands says nothing and flags nothing"
export STUB_WORLD=escalation/pass1 STUB_NOW=2026-08-27T12:30:01Z STUB_GH_FAIL=pr-comment
run_once
check_status 0 "$STATUS"
check_grep "#601 601a601a601a601a601a601a601a601a601a601a autofix-stalled review=terminal threads=2 autofix=unspent age=5401 bound=5400 action=escalate-failed kind=stalled rc=1" "$OUT"
# The label is the flag on a record that does not exist, so it is not written.
check_no_grep "pr edit 601 --repo nywleswoey/automation --add-label" "$STUB_CALLS"
check_grep "pass end dispatches=0 skips=1 sweeps=1" "$OUT"
# Nothing was said and nothing is flagged, so there is nothing to unwind: the
# next pass re-derives the same stall and escalates again.
export STUB_GH_FAIL=""
run_once
check_status 0 "$STATUS"
check_grep "#601 601a601a601a601a601a601a601a601a601a601a autofix-stalled review=terminal threads=2 autofix=unspent age=5401 bound=5400 action=escalated kind=stalled label=added handover=posted" "$OUT"

setup "a handover whose label never lands keeps the record and is healed next pass"
export STUB_WORLD=escalation/pass1 STUB_NOW=2026-08-27T12:30:01Z STUB_GH_FAIL=pr-edit
run_once
check_status 0 "$STATUS"
check_grep "#601 601a601a601a601a601a601a601a601a601a601a autofix-stalled review=terminal threads=2 autofix=unspent age=5401 bound=5400 action=escalated kind=stalled label=failed rc=1" "$OUT"
check_grep "gh-axi pr comment 601 --repo nywleswoey/automation --body-file " "$STUB_CALLS"
check_grep "pass end dispatches=0 skips=1 sweeps=1" "$OUT"
# The record landed, so the next pass reads the marker and adds the label alone
# — which is exactly the world pass3 captures.
export STUB_GH_FAIL="" STUB_WORLD=escalation/pass3 STUB_NOW=2026-08-27T13:30:00Z
run_once
check_status 0 "$STATUS"
check_grep "#601 601a601a601a601a601a601a601a601a601a601a autofix-stalled review=terminal threads=2 autofix=unspent age=9000 bound=5400 handover=held label=added" "$OUT"
check "the record was posted once across both passes" \
  test "$(grep -cF 'pr comment 601 --repo nywleswoey/automation --body-file' "$STUB_CALLS")" -eq 1

# --- pr phase: un-latching, on the one head whose signals change -------------------

# **The world the suite never had.** Every other multi-pass world here moves the
# head between passes, so the suite has asserted idempotence at a fixed commit
# and has never once asserted *signal change* at one — which is exactly the
# shape the defect had. This replays the specimen: a handover written on a `no`
# that a check retracted twenty-nine seconds later and that then stood for just
# under two hours.
#
# One head, three passes. `BLOCKED` with a check still pending; the same head
# with the check reported and the state clean; then the same head again with the
# record withdrawn.

setup "a record whose claim stops being true is withdrawn by the loop itself"
PASS_N=0

# Pass one: the required check reported **badly**, so V2 says no; the merge state
# carries the same underlying fact through the other field and defers on it,
# because its causes are not V3's. A veto beats the clock, so the record goes up
# carrying both rows.
#
# The veto here is the failing check and not the merge state, and that is the
# specimen read correctly rather than a change of subject: a check that has not
# *reported* beside `BLOCKED` is exactly the shape that must **defer**, so a case
# about a record that stops being true needs a veto that really said no. This is
# the second row of the driven-cycle register — a failing check, re-run green.
replay unlatch/pass1 2026-08-27T11:35:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#401 401a401a401a401a401a401a401a401a401a401a assessable review=terminal threads=0 autofix=unspent verdict=escalate risk=ok checks=no mergeability=defer blast=ok age=300 bound=3600 action=escalated kind=escalate label=added handover=posted" "$PASS_LOG"

BODY="$STUB_STATE/pr-body-401.txt"
check "the escalation body was captured" test -f "$BODY"
check "the first line names the kind" \
  test "$(head -1 "$BODY")" = '**Escalated — `escalate`:** a veto is present and says no.'
check_grep "| no | a status check on this commit is not green | \`green=2 pending=0 failed=1 total=3 failing=pg-gate=FAILURE\` |" "$BODY"
# **One signal, one veto**, in the record itself: the merge state reports the
# same underlying fact and says nothing about it, because it does not own it.
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=BLOCKED\` |" "$BODY"
check_grep "<!-- agent-loop-escalated: 401a401a401a401a401a401a401a401a401a401a escalate -->" "$BODY"
# The world the next pass replays carries the loop's own words rather than a
# paraphrase of them, so a change to the body cannot quietly stop the marker
# being found — or its kind being read.
check "the world the next pass replays carries the record just posted" \
  test "$(jq -r '.data.repository.pullRequest.comments.nodes[] | select((.body | contains("agent-loop-escalated"))) | .body' "$FIXTURES/worlds/unlatch/pass2/pr-401.json")" = "$(cat "$BODY")"

# Pass two: the same commit, the check reported, the state clean. The gate would
# merge — and **that is precisely what the record promised would not happen** —
# so the loop takes its own record down and spends the pass doing it.
replay unlatch/pass2 2026-08-27T11:40:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#401 401a401a401a401a401a401a401a401a401a401a assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=deferred bound=retraction handover=retracted label=removed" "$PASS_LOG"
# The record never stands while the loop does the thing it promised not to do,
# so the merge waits a pass.
check "no merge is written on the pass that retracts" \
  test "$(grep -cF 'pulls/401/merge' "$STUB_CALLS")" -eq 0
# **The retraction is an edit and a label removal, in that order, and nothing
# else.** A counter-comment would churn the timeline two comments per base move
# and push the record out of the window the derivation reads it from.
check_grep "gh-axi api PATCH /repos/nywleswoey/automation/issues/comments/5379000411 --field body=@" "$STUB_CALLS"
check_grep "gh-axi pr edit 401 --repo nywleswoey/automation --remove-label agent-escalated" "$STUB_CALLS"
check "the comment is written before the label, on the way down as well as up" \
  test "$(call_line 'issues/comments/5379000411')" \
     -lt "$(call_line 'pr edit 401 --repo nywleswoey/automation --remove-label')"
check "no comment is posted on a retraction" \
  test "$(grep -cF 'pr comment 401 --repo nywleswoey/automation --body-file' "$STUB_CALLS")" -eq 1

WITHDRAWN="$STUB_STATE/comment-body-5379000411.txt"
check "the retraction body was captured" test -f "$WITHDRAWN"
check "the first line withdraws the record" \
  test "$(head -1 "$WITHDRAWN")" = '**Withdrawn.** A handover stood on this pull request at `401a401a401a401a401a401a401a401a401a401a`; the loop re-derived, the picture had changed, and it took the record down. The previous version of this comment holds what the gate saw.'
# **Removing the marker is the retraction.** Nothing else has to come down,
# because the marker is the whole of what the derivation reads.
check_no_grep "agent-loop-escalated" "$WITHDRAWN"
# **No live gate rows.** A notice saying the gate now says merge would be a
# record written against a moving signal — the exact defect this path exists to
# correct — so the body states only what is permanently true and leaves the
# verdict to GitHub's own edit history.
check_no_grep "| Verdict |" "$WITHDRAWN"
check_no_grep "mergeable=" "$WITHDRAWN"

# Pass three: no record, no flag, and the pull request derives like any other.
replay unlatch/pass3 2026-08-27T11:45:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#401 401a401a401a401a401a401a401a401a401a401a assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=merged method=squash" "$PASS_LOG"
check_grep "gh-axi api PUT /repos/nywleswoey/automation/pulls/401/merge --field sha=401a401a401a401a401a401a401a401a401a401a" "$STUB_CALLS"
# The whole of the fix, in one line: the loop merged the commit it had vetoed,
# on its own, without the head moving and without a human touching it.
check "the head never moved across all three passes" \
  test "$(grep -cF 'pullRequest(number: 401)' "$STUB_CALLS")" -eq 3

setup "a retraction that never lands leaves the record standing and retracts again"
PASS_N=0
export STUB_WORLD=unlatch/pass2 STUB_NOW=2026-08-27T11:40:00Z STUB_GH_FAIL=comment-edit
run_once
check_status 0 "$STATUS"
check_grep "#401 401a401a401a401a401a401a401a401a401a401a assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=deferred bound=retraction handover=retract-failed rc=1" "$OUT"
# **The label is not touched.** Comment then label is what makes that safe: the
# record still stands, so the flag on it is still true, and the next pass finds
# exactly the world this one did.
check_no_grep "--remove-label" "$STUB_CALLS"
check_grep "pass end dispatches=0 skips=1 sweeps=1" "$OUT"
check "and nothing was merged behind a record that is still standing" \
  test "$(grep -cF 'pulls/401/merge' "$STUB_CALLS")" -eq 0
export STUB_GH_FAIL=""
run_once
check_status 0 "$STATUS"
check_grep "#401 401a401a401a401a401a401a401a401a401a401a assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=deferred bound=retraction handover=retracted label=removed" "$OUT"

# --- pr phase: what the latch does with a record it did not just write -------------

# Four pull requests at one head each, and a fifth that is the control. Every
# one of the first four carries a standing record; none of them may be merged,
# triggered or nudged while it does, and what happens to the record itself is
# the whole of what separates them.

setup "a standing record is held, replaced, retracted or left alone by whose it is"
export STUB_WORLD=unlatch-cases STUB_NOW=2026-08-27T12:30:01Z
run_once
check_status 0 "$STATUS"

# 410 — **the kind change.** A `stuck` record standing where the chain now
# derives `escalate`: a different claim about the same commit, so the record is
# replaced wholesale by an edit rather than retracted and re-posted a pass
# later, which would leave the pull request carrying no record in between.
check_grep "pr nywleswoey/automation#410 410a410a410a410a410a410a410a410a410a410a assessable review=terminal threads=0 autofix=unspent verdict=escalate risk=ok checks=no mergeability=ok blast=ok action=escalated kind=escalate label=added handover=posted" "$OUT"
check_grep "gh-axi api PATCH /repos/nywleswoey/automation/issues/comments/5379000415 --field body=@" "$STUB_CALLS"
KIND_CHANGE="$STUB_STATE/comment-body-5379000415.txt"
check "the replacement body was captured" test -f "$KIND_CHANGE"
check "the first line names the new kind" \
  test "$(head -1 "$KIND_CHANGE")" = '**Escalated — `escalate`:** a veto is present and says no.'
check_grep "<!-- agent-loop-escalated: 410a410a410a410a410a410a410a410a410a410a escalate -->" "$KIND_CHANGE"
check_no_grep "agent-loop-escalated: 410a410a410a410a410a410a410a410a410a410a stuck" "$KIND_CHANGE"
# It is a replacement and not a withdrawal: the record is a record throughout.
check_no_grep "**Withdrawn.**" "$KIND_CHANGE"
# The label stays. Nothing takes it off a pull request whose record was replaced
# rather than withdrawn.
check "the label stays on a kind change" \
  test "$(grep -cF 'pr edit 410 --repo nywleswoey/automation --remove-label' "$STUB_CALLS")" -eq 0

# 420 — **the foreign record.** The marker is there and it says the same thing,
# but the loop did not write the comment carrying it, so it cannot un-write it.
# The label chase is all that happens, and the line says why.
# **The bound it names is the honest one.** No retraction is coming for a record
# the loop cannot rewrite, so the line does not promise one: this pull request
# waits on the operator, and the bounded-exit invariant is only worth carrying
# if the row says which bound it is actually under.
check_grep "pr nywleswoey/automation#420 420a420a420a420a420a420a420a420a420a420a assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=deferred bound=operator handover=foreign label=added" "$OUT"
check_no_grep "#420 420a420a420a420a420a420a420a420a420a420a assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=deferred bound=retraction" "$OUT"
check_grep "gh-axi pr edit 420 --repo nywleswoey/automation --add-label agent-escalated" "$STUB_CALLS"
# **No comment the loop did not author is ever passed to the edit.** The one
# comment carrying that marker has id 5379000425, and it is never named.
check "a comment the loop did not write is never edited" \
  test "$(grep -cF 'issues/comments/5379000425' "$STUB_CALLS")" -eq 0
check "and no second record is posted beside it" \
  test "$(grep -cF 'pr comment 420 --repo nywleswoey/automation --body-file' "$STUB_CALLS")" -eq 0
# The cost, accepted: this pull request holds at this head until the operator
# moves it, and the gate saying merge does not change that.
check "nothing is merged behind a record the loop cannot take down" \
  test "$(grep -cF 'pulls/420/merge' "$STUB_CALLS")" -eq 0

# 430 — **the migration.** A marker written before the kind existed still
# matches on its head, and reports no kind — which is no kind the chain can
# derive, so the record is retracted and re-posted in the one write that does
# both, and comes back carrying the kind. It happens once, and never again at
# that head.
check_grep "pr nywleswoey/automation#430 430a430a430a430a430a430a430a430a430a430a autofix-stalled review=terminal threads=2 autofix=unspent age=5401 bound=5400 action=escalated kind=stalled label=added handover=posted" "$OUT"
MIGRATED="$STUB_STATE/comment-body-5379000436.txt"
check "the migrated body was captured" test -f "$MIGRATED"
check_grep "<!-- agent-loop-escalated: 430a430a430a430a430a430a430a430a430a430a stalled -->" "$MIGRATED"
check "the migration is one write and not a new comment" \
  test "$(grep -cF 'pr comment 430 --repo nywleswoey/automation --body-file' "$STUB_CALLS")" -eq 0
# The record promises no autofix trigger, and a record being migrated is still a
# record: nothing is fired at this head.
check "no autofix trigger is written behind a standing record" \
  test "$(grep -cF 'pr comment 430 --repo nywleswoey/automation --body @coderabbitai autofix' "$STUB_CALLS")" -eq 0

# 440 — **the refused record.** The gate says merge, as it did on the pass that
# was refused, and would say it again on every pass after. **A record naming
# this head is a head-keyed merge spend**, read out of the comment the response
# already carries, so the merge does not go out and the pass is spent taking the
# record down instead.
check_grep "pr nywleswoey/automation#440 440a440a440a440a440a440a440a440a440a440a assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=deferred bound=retraction handover=retracted label=removed" "$OUT"
check "no merge write happens at a head carrying a refused record" \
  test "$(grep -cF 'pulls/440/merge' "$STUB_CALLS")" -eq 0

# 450 — the control, and the reason the four negatives above mean anything: the
# identical shape with no record on it merges on this very pass.
check_grep "pr nywleswoey/automation#450 450a450a450a450a450a450a450a450a450a450a assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=merged method=squash" "$OUT"
check_grep "gh-axi api PUT /repos/nywleswoey/automation/pulls/450/merge --field sha=450a450a450a450a450a450a450a450a450a450a" "$STUB_CALLS"

# **No `pr comment` is ever written on a retraction or a replacement** — only the
# edit. Three records were rewritten in this pass and the timeline grew by
# nothing at all.
check "not one comment was posted across the whole world" \
  test "$(grep -cE 'gh-axi pr comment [0-9]+ --repo nywleswoey/automation --body-file' "$STUB_CALLS")" -eq 0

# The bill for un-latching a `refused` record, recorded on the row it falls on
# rather than left for someone to find. **Retraction halves the oscillator; it
# does not kill it.** The record naming the head is what suppresses the merge,
# and the retraction that un-latches the pull request takes that fact down with
# it — so the pass after a retraction merges again, and a refusal that is
# permanent posts a fresh record, because the withdrawn comment no longer
# carries a marker for the loop to write over.
#
# `unlatch/pass3` is the world one pass after a retraction, so no new fixture is
# needed: it is the same commit with the record already withdrawn.

setup "a retraction re-arms the merge, and a refusal at that head posts a new record"
export STUB_WORLD=unlatch/pass3 STUB_NOW=2026-08-27T11:45:00Z
export STUB_GH_FAIL=merge STUB_GH_ERROR=405-conflict
run_once
check_status 0 "$STATUS"
check_grep "#401 401a401a401a401a401a401a401a401a401a401a assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok merge=refused rc=3 action=escalated kind=refused label=added handover=posted" "$OUT"
# The withdrawn comment is not the one written to. A record the loop withdrew
# carries no marker, so there is nothing at this head for the edit to name, and
# the handover write is deliberately not metered per head — it has to stay
# re-postable or a retraction could never re-escalate.
check "the refusal posts a comment rather than editing the withdrawn one" \
  test "$(grep -cF 'pr comment 401 --repo nywleswoey/automation --body-file' "$STUB_CALLS")" -eq 1
check "and the withdrawn comment is left alone" \
  test "$(grep -cF 'issues/comments/5379000411' "$STUB_CALLS")" -eq 0
REFUSED="$STUB_STATE/pr-body-401.txt"
check "the refusal body was captured" test -f "$REFUSED"
check "the first line names the kind" \
  test "$(head -1 "$REFUSED")" = '**Escalated — `refused`:** the gate said merge and GitHub said no.'
check_grep "<!-- agent-loop-escalated: 401a401a401a401a401a401a401a401a401a401a refused -->" "$REFUSED"

# --- pr phase: the escalation label exists -------------------------------------------

# `--add-label` naming a label that does not exist is refused, so a handover
# would post its record and then fail to flag it forever, on a self-heal that
# can never land. The loop makes it exist for the same reason it makes its other
# two exist.
setup "the escalation label is created at startup alongside the loop's own two"
run_once
check_status 0 "$STATUS"
check_grep "gh-axi label create --name agent-escalated" "$STUB_CALLS"
check_grep "created label agent-escalated in nywleswoey/automation" "$OUT"

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
# unresolved. Spent on this head all the same, and the token names the reason —
# **by a trigger**, which is the reason the mutant below does not have.
replay autofix-once/pass3 2026-08-27T13:00:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#301 301a301a301a301a301a301a301a301a301a301a assessable review=terminal threads=2 autofix=spent:trigger verdict=merge risk=ok checks=ok mergeability=ok blast=ok" "$PASS_LOG"
check "still exactly one trigger after the third pass" test "$(grep -cF 'pr comment 301' "$STUB_CALLS")" -eq 1

# Pass four: the head moved, and **CodeRabbit wrote it**. The nudge the third
# route fires has since run a full review at that head, which moved the block
# onto it and minted two new findings on the autofix's own diff — the cycle the
# third route arms. Autofix is spent by the second sufficient reason, so the
# loop does not turn it: *the loop does not act on its own output.*
#
# This is the sensitivity proof in its strongest form — the same assertion at
# successive passes with **opposite verdicts**, against captured worlds. Nothing
# about this pull request's findings changed; the head's author did.
replay autofix-once/pass4 2026-08-27T13:30:00Z
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#301 301b301b301b301b301b301b301b301b301b301b assessable review=terminal threads=2 autofix=spent:own-head verdict=escalate risk=no checks=ok mergeability=ok blast=ok action=escalated kind=escalate label=added" "$PASS_LOG"
check "no autofix trigger is written at a head CodeRabbit authored" \
  test "$(grep -cF 'body @coderabbitai autofix' "$STUB_CALLS")" -eq 1
# The accepted cost, and the backstop that makes it the right one: the new
# findings reach the gate **unfixed**, the full review has moved the block onto
# this head, so V1 judges the new review's level — and a bad autofix escalates
# rather than being silently re-fixed by the thing that produced it.
check_grep "| no | CodeRabbit's merge-risk verdict does not clear this commit | \`block=parsed level=high abbrev=301b3 head=301b301b301b301b301b301b301b301b301b301b\` |" "$STUB_STATE/pr-body-301.txt"
check "the head really is CodeRabbit's own" \
  test "$(jq -r '.data.repository.pullRequest.commits.nodes[-1].commit.author.user.login' "$FIXTURES/worlds/autofix-once/pass4/pr-301.json")" = "coderabbitai[bot]"
# And the head is not spent by a trigger: the only trigger on the timeline
# records the head before this one, so the two reasons are genuinely separate.
check "the trigger on the timeline names the previous head" \
  test "$(jq -r '[.data.repository.pullRequest.comments.nodes[] | select(.body | contains("agent-loop-autofix-head")) | .body | test("agent-loop-autofix-head: 301a")] | all' "$FIXTURES/worlds/autofix-once/pass4/pr-301.json")" = "true"

# --- pr phase: a status from an earlier head does not spend this one ----------------

# The same world as 206 in the omnibus case above, with a failed status whose
# paired trigger records the preceding head. Its `_none_` result is not an input
# identity, and its newer timestamp cannot suppress autofix on the current head.
setup "an autofix status for an earlier head does not spend the current head"
export STUB_WORLD=autofix-failed STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#206 206f206f206f206f206f206f206f206f206f206f needs-autofix review=terminal threads=3 autofix=unspent action=triggered" "$OUT"
check "one trigger was posted for the unspent current head" \
  test "$(grep -cF 'body @coderabbitai autofix' "$STUB_CALLS")" -eq 1

# --- pr phase: the risk gate ----------------------------------------------------------

# Four vetoes over one head commit and three outcomes — `merge`, `escalate` and
# `defer` — asserted whole against one world carrying a pull request for each.
#
# The division of labour is what the fixtures are built around: **CodeRabbit's
# verdict is a necessary input, not the verdict.** V1 is the reviewer's judgement
# of the code; V2, V3 and V4 are the loop's own judgement of merge mechanics and
# blast radius; each holds a veto, and every one of them is proven to escalate on
# its own below.

# This world carries sixteen pull requests, fifteen of which reach the gate —
# 221's verdict names another commit, so the chain diverts it before the gate is
# reached, which is itself one of the cases below. Four of the fifteen clear
# every veto, and the loop merges at most one per repository per pass, so a plain run
# would act on the first and defer the other three, mixing the bound into a case
# that is about the rubric. `--no-merge` holds the one irreversible write and
# nothing else, which is exactly the reading this case wants: every verdict is
# reached and logged, and none of them is acted on. The merge itself is proven
# in its own world below.
setup "the risk gate judges every assessable pull request"
export STUB_WORLD=gate STUB_NOW=2026-08-27T12:00:00Z
run_once --no-merge
check_status 0 "$STATUS"

GATE_PR="pr nywleswoey/automation"
GATE_TAIL="review=terminal threads=0 autofix=unspent"

# --- the merge verdict, which the flag holds -------------------------------------------

# Everything clears, the loop says so, and the flag stops it there.
check_grep "$GATE_PR#220 220a220a220a220a220a220a220a220a220a220a assessable $GATE_TAIL verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=would-merge method=squash" "$OUT"
check "nothing at all was merged" \
  test "$(grep -cE 'pulls/[0-9]+/merge' "$STUB_CALLS")" -eq 0
# A merge verdict is silent on the pull request itself: no comment, no label.
check_no_grep "pr comment 220 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "pr edit 220 --repo nywleswoey/automation" "$STUB_CALLS"

# --- V1: CodeRabbit's verdict ----------------------------------------------------------

# What reaches V1 is now a terminal review **and** a block naming this head, so
# only the level and the parse can still say no. Both are the same tripwire for
# CodeRabbit changing shape, and every escalation carries the raw values behind
# it.

# 221's verdict names some other commit, and it never gets here: that is the
# third route into `needs-review`, which is nudged and bounded before the gate
# is reached. V1's abbreviation branch is kept anyway — the two readers work at
# different scopes, and the safe direction for that asymmetry is for the
# stricter one to escalate — but nothing can reach it, and this is the case that
# says so.
check_grep "$GATE_PR#221 221b221b221b221b221b221b221b221b221b221b needs-review $GATE_TAIL route=other-head action=nudged" "$OUT"
check_no_grep "221b221b221b221b221b221b221b221b221b221b assessable" "$OUT"
check "the diverted pull request was nudged rather than handed over" \
  test "$(grep -cF 'pr comment 221 --repo nywleswoey/automation --body @coderabbitai review' "$STUB_CALLS")" -eq 1
check "no handover was posted for it" test ! -f "$STUB_STATE/pr-body-221.txt"

# A level that is not minimal. There is no documented ladder of levels anywhere,
# so nothing may be inferred about ordering: anything but minimal escalates.
check_grep "$GATE_PR#222 222c222c222c222c222c222c222c222c222c222c assessable $GATE_TAIL verdict=escalate risk=no checks=ok mergeability=ok blast=ok action=escalated kind=escalate label=added" "$OUT"
check_grep "| no | CodeRabbit's merge-risk verdict does not clear this commit | \`block=parsed level=high abbrev=222c2 head=222c222c222c222c222c222c222c222c222c222c\` |" "$STUB_STATE/pr-body-222.txt"

# The block is there and its line is a shape nothing parses. This is the case the
# veto exists for: an unparseable verdict is not a missing one, and reading it as
# absent would be reading CodeRabbit changing shape as CodeRabbit having nothing
# to say.
check_grep "$GATE_PR#223 223d223d223d223d223d223d223d223d223d223d assessable $GATE_TAIL verdict=escalate risk=no checks=ok mergeability=ok blast=ok action=escalated kind=escalate label=added" "$OUT"
check_grep "| no | CodeRabbit's merge-risk verdict does not clear this commit | \`block=unparseable level=none abbrev=none head=223d223d223d223d223d223d223d223d223d223d\` |" "$STUB_STATE/pr-body-223.txt"

# The observed abbreviation is **five** characters, not the seven the prose
# around this feature says — which is exactly why the test is a prefix test. The
# fixture is pinned to that, so a rubric quietly rewritten to compare whole
# strings or a fixed seven would fail here rather than in production.
GATE_ABBREV=$(jq -r '.data.repository.pullRequest.comments.nodes[0].body' \
  "$FIXTURES/worlds/gate/pr-220.json" | sed -n 's/.*up to `\(.*\)`.*/\1/p')
check "the captured abbreviation is five characters" test "${#GATE_ABBREV}" -eq 5
check "and it is a prefix of the head, not the whole of it" \
  test "220a220a220a220a220a220a220a220a220a220a" != "$GATE_ABBREV"

# --- V2: checks ------------------------------------------------------------------------

# **Every** rollup context, not just the required ones. Required-ness is
# structurally always false once repository protection is out of scope, so a
# gate that only looked at required checks would have no check that could ever
# block a merge. The failing context on 224 carries `isRequired: false` in the
# fixture and the query never asks for the field at all, which is the strongest
# available form of "it plays no part".
check_grep "$GATE_PR#224 224e224e224e224e224e224e224e224e224e224e assessable $GATE_TAIL verdict=escalate risk=ok checks=no mergeability=ok blast=ok action=escalated kind=escalate label=added" "$OUT"
check_grep "| no | a status check on this commit is not green | \`green=1 pending=0 failed=1 total=2 failing=ci/build=FAILURE\` |" "$STUB_STATE/pr-body-224.txt"
check "the failing check is one nothing requires" \
  test "$(jq -r '[.data.repository.pullRequest.commits.nodes[-1].commit.statusCheckRollup.contexts.nodes[] | select(.context == "ci/build") | .isRequired] | .[0]' "$FIXTURES/worlds/gate/pr-224.json")" = "false"
check_no_grep "isRequired" "$STUB_CALLS"

# --- V3: conflicts and base drift -------------------------------------------------------

# **One signal, one veto.** V3 owns the facts that are functions of `(head, base
# tip)` alone, and says nothing about the values it reads but does not own. 230
# is the specimen's own pair — `MERGEABLE` with `BLOCKED`, which is GitHub
# saying *a required check has not reported yet* through a second field. V2 owns
# that fact, so V3's merge-state axis defers on it and the pull request waits in
# silence instead of being handed over on a cause that retracts itself.
check_grep "$GATE_PR#230 230e230e230e230e230e230e230e230e230e230e assessable $GATE_TAIL verdict=defer risk=ok checks=ok mergeability=defer blast=ok age=1800 bound=3600" "$OUT"
check_no_grep "pr comment 230 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "pr edit 230 --repo nywleswoey/automation" "$STUB_CALLS"

# A branch that is behind escalates, and — the point of the veto — **is never
# updated**. That write would move the head, void the verdict just validated and
# spend metered review budget re-reviewing what was already reviewed.
check_grep "$GATE_PR#225 225f225f225f225f225f225f225f225f225f225f assessable $GATE_TAIL verdict=escalate risk=ok checks=ok mergeability=no blast=ok action=escalated kind=escalate label=added" "$OUT"
# **Two rows, not one**, so a verdict of `no` never appears beside a raw value
# reading `mergeable`. The conflict axis passed; the drift axis is the veto.
check_grep "| ok | GitHub reports no conflict between this head and its base | \`mergeable=MERGEABLE\` |" "$STUB_STATE/pr-body-225.txt"
check_grep "| no | the base has moved on past this pull request's merge base | \`state=BEHIND\` |" "$STUB_STATE/pr-body-225.txt"
check_no_grep "update-branch" "$STUB_CALLS"
check_no_grep "updatePullRequestBranch" "$STUB_CALLS"

# --- V4: blast radius ------------------------------------------------------------------

# *Never minimal if merging it changes what runs unattended.*
check_grep "$GATE_PR#226 226a226a226a226a226a226a226a226a226a226a assessable $GATE_TAIL verdict=escalate risk=ok checks=ok mergeability=ok blast=no action=escalated kind=escalate label=added" "$OUT"
check_grep "| no | this pull request changes what runs unattended | \`files=2 guarded=.github/workflows/test.yml\` |" "$STUB_STATE/pr-body-226.txt"
check_grep "$GATE_PR#227 227b227b227b227b227b227b227b227b227b227b assessable $GATE_TAIL verdict=escalate risk=ok checks=ok mergeability=ok blast=no action=escalated kind=escalate label=added" "$OUT"
# All three of the loop's own files in one row, so the guard list is proven
# whole rather than by its first entry. `gh.sh` is guarded on the same principle
# as the other two — it is sourced by both and a change to it changes what both
# do — which is a deliberate widening of the ticket's "either of the loop's own
# scripts", and the assertion is where that widening is visible.
check_grep "| no | this pull request changes what runs unattended | \`files=4 guarded=agent-loop.sh,gh.sh,pr-writeback.sh\` |" "$STUB_STATE/pr-body-227.txt"
LOOP_GUARDED=$(sed -n "s/^UNATTENDED_SCRIPTS='\(.*\)'$/\1/p" "$SCRIPT")
check "the guard list is exactly the three files the fixture touches" \
  test "$LOOP_GUARDED" = "agent-loop.sh,pr-writeback.sh,gh.sh"

# **There is no diff-size ceiling** — declined as an unmeasured number with an
# asymmetric failure mode. Ninety files that touch nothing unattended merge.
check_grep "$GATE_PR#233 233b233b233b233b233b233b233b233b233b233b assessable $GATE_TAIL verdict=merge risk=ok checks=ok mergeability=ok blast=ok" "$OUT"
check "the large change really is large" \
  test "$(jq -r '.data.repository.pullRequest.files.totalCount' "$FIXTURES/worlds/gate/pr-233.json")" -eq 90

# What does escalate is not size but **not being able to see**: a file list
# longer than the page the read carries means the blast radius is unknown, and a
# workflow change hidden past the boundary is precisely what this veto exists to
# catch.
check_grep "$GATE_PR#231 231f231f231f231f231f231f231f231f231f231f assessable $GATE_TAIL verdict=escalate risk=ok checks=ok mergeability=ok blast=no action=escalated kind=escalate label=added" "$OUT"
check_grep "| no | the changed-file list is longer than one page, so the blast radius is unknown | \`files=137 listed=100\` |" "$STUB_STATE/pr-body-231.txt"

# A check that ran and declined to judge is green. This is the one place the
# gate reads a value the ticket does not enumerate, so it is asserted rather than
# left buried: a path-filtered workflow reports `SKIPPED` on most commits, so
# reading it as not-green would escalate nearly every pull request in a
# repository that uses path filters. It also agrees with GitHub rather than
# inventing a second opinion — `mergeStateStatus: CLEAN`, which V3 separately
# requires, says the same thing about the same commit.
check_grep "$GATE_PR#235 235d235d235d235d235d235d235d235d235d235d assessable $GATE_TAIL verdict=merge risk=ok checks=ok mergeability=ok blast=ok" "$OUT"
check "the check really did not run" \
  test "$(jq -r '[.data.repository.pullRequest.commits.nodes[-1].commit.statusCheckRollup.contexts.nodes[] | select(.__typename == "CheckRun") | .conclusion] | .[0]' "$FIXTURES/worlds/gate/pr-235.json")" = "SKIPPED"

# --- defer: a signal that is simply not computed yet -----------------------------------

# `defer` is not a failure. A check still running and a mergeability GitHub has
# not finished calculating are re-derived next pass **in silence** — no comment,
# no label, nothing but the state line, which with no local state anywhere is the
# only record the wait leaves.
check_grep "$GATE_PR#228 228c228c228c228c228c228c228c228c228c228c assessable $GATE_TAIL verdict=defer risk=ok checks=defer mergeability=ok blast=ok age=1800 bound=3600" "$OUT"
check_grep "$GATE_PR#229 229d229d229d229d229d229d229d229d229d229d assessable $GATE_TAIL verdict=defer risk=ok checks=ok mergeability=defer blast=ok age=1800 bound=3600" "$OUT"
check_no_grep "pr comment 228 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "pr edit 228 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "pr comment 229 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "pr edit 229 --repo nywleswoey/automation" "$STUB_CALLS"

# --- every veto evaluates, and escalate beats defer ------------------------------------

# 234 has a veto **and** an undecided signal. Nothing short-circuits, so the
# message carries both rows and the two that passed as well; and the kind is the
# veto's rather than the clock's, because the veto is the one the operator can
# act on. Its veto is the **level**, because a verdict naming another commit no
# longer reaches the gate at all.
check_grep "$GATE_PR#234 234c234c234c234c234c234c234c234c234c234c assessable $GATE_TAIL verdict=escalate risk=no checks=ok mergeability=defer blast=ok age=1800 bound=3600 action=escalated kind=escalate label=added" "$OUT"
GATE_BOTH="$STUB_STATE/pr-body-234.txt"
check "the first line names the kind" \
  test "$(head -1 "$GATE_BOTH")" = '**Escalated — `escalate`:** a veto is present and says no.'
check_grep "| no | CodeRabbit's merge-risk verdict does not clear this commit |" "$GATE_BOTH"
check_grep "| defer | GitHub has not settled whether this pull request conflicts | \`mergeable=UNKNOWN\` |" "$GATE_BOTH"
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=UNKNOWN\` |" "$GATE_BOTH"
# The rows that **passed** are carried too: an operator reading a handover is
# owed the complete picture the gate saw, because the passing rows are what tell
# them where *not* to look.
check_grep "| ok | every status check on this commit is green | \`green=2 pending=0 failed=0 total=2\` |" "$GATE_BOTH"
check_grep "| ok | nothing here changes what runs unattended | \`files=1 guarded=none\` |" "$GATE_BOTH"
# **The clock judged nothing**, and its row says so: `note` is the fourth token
# and the escalation here is the veto's, not the clock's.
check_grep "| note | the merge-gate clock has not run out yet | \`age=1800s bound=3600s head=2026-08-27T11:30:00Z\` |" "$GATE_BOTH"
check "one row per veto — V3 in two — plus the clock, plus the table head" \
  test "$(grep -cE '^\|' "$GATE_BOTH")" -eq 8

# --- freshness is the updated timestamp, never the created one -------------------------

# CodeRabbit delivers by **editing an existing comment** — observed gaps of five
# and seven days between a walkthrough's creation and the edit carrying today's
# verdict. 232 carries two walkthroughs whose orderings disagree: the newest by
# creation holds a stale verdict, the newest by update holds this head's. A merge
# verdict is only reachable through the second.
#
# It now proves the same thing about the **chain's** read as well. The third
# route reads the newest block too, so a chain that read *any* block would find
# the stale one, divert this pull request into `needs-review` and nudge it —
# and it would never reach a verdict at all.
check_grep "$GATE_PR#232 232a232a232a232a232a232a232a232a232a232a assessable $GATE_TAIL verdict=merge risk=ok checks=ok mergeability=ok blast=ok" "$OUT"
check "the two walkthroughs really do order differently" \
  test "$(jq -r '[.data.repository.pullRequest.comments.nodes | max_by(.createdAt).databaseId, max_by(.updatedAt).databaseId] | .[0] == .[1]' "$FIXTURES/worlds/gate/pr-232.json")" = "false"
check "the stale one really does name another commit" \
  test "$(jq -r '.data.repository.pullRequest.comments.nodes | max_by(.createdAt).body | test("up to .232a") | not' "$FIXTURES/worlds/gate/pr-232.json")" = "true"
check_no_grep "pr comment 232 --repo nywleswoey/automation --body @coderabbitai review" "$STUB_CALLS"

# --- the prohibitions ------------------------------------------------------------------

# **The pull request's reviews are never read for a verdict.** The read does not
# ask for them at all, which is what makes this a fact rather than a promise. The
# reasoning is not squeamishness: an approving CodeRabbit review is contingent on
# comments being *resolved*, and autofix does not resolve what it fixes, so the
# only exit would be the loop resolving threads itself and merging on the
# approval that produced.
check_no_grep "reviews(" "$STUB_CALLS"
check_no_grep "latestReviews" "$STUB_CALLS"
check_no_grep "reviewDecision" "$STUB_CALLS"

# **Pre-merge checks are ignored and never parsed** — subsumed by the merge-risk
# verdict, computed from the same review, and measuring hygiene rather than merge
# risk. 220's walkthrough reports two of them failing and it still reaches a
# merge verdict, which is the mutant that proves nothing reads them.
check "the merged verdict's own walkthrough reports failing pre-merge checks" \
  test "$(jq -r '.data.repository.pullRequest.comments.nodes[0].body | contains("Pre-merge checks | ❌ 2")' "$FIXTURES/worlds/gate/pr-220.json")" = "true"
check_no_grep "pre_merge" "$OUT"
check_no_grep "Pre-merge" "$OUT"

# **The gate never reads thread resolution.** Unresolved threads are input to the
# fix trigger and to nothing else — forced, because autofix does not resolve the
# threads it fixes, so "threads are clean" can never be a termination condition.
check_no_grep "resolveReviewThread" "$STUB_CALLS"

# One line per pull request, and one action at most on each.
check "one state line per pull request" \
  test "$(grep -cE '^[0-9TZ:-]+ pr nywleswoey/automation#' "$OUT")" -eq 16

# --- pr phase: the gate clock, proven by a mutant twin ---------------------------------

# One world at two frozen instants either side of the bound. Nothing but
# $STUB_NOW differs, so whatever differs in the verdict is caused by the clock
# and by nothing else. Both pull requests share a head date, so the clock says
# the same thing about both — and only one of them is exempt from it.

setup "an undecided signal inside the gate clock defers in silence"
export STUB_WORLD=gate-clock STUB_NOW=2026-08-27T12:59:59Z
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#240 240a240a240a240a240a240a240a240a240a240a assessable review=terminal threads=0 autofix=unspent verdict=defer risk=ok checks=ok mergeability=defer blast=ok age=3599 bound=3600" "$OUT"
check_no_grep "kind=stuck" "$OUT"
check_no_grep "pr comment 240 --repo nywleswoey/automation" "$STUB_CALLS"

setup "the same signal one second past the gate clock is handed over as stuck"
export STUB_WORLD=gate-clock STUB_NOW=2026-08-27T13:00:01Z
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#240 240a240a240a240a240a240a240a240a240a240a assessable review=terminal threads=0 autofix=unspent verdict=escalate risk=ok checks=ok mergeability=defer blast=ok age=3601 bound=3600 action=escalated kind=stuck label=added" "$OUT"
# `stuck`, not `escalate`: nothing said no, the signals simply never arrived, and
# the kind is what tells the operator to go and look at the checks rather than at
# the diff.
STUCK="$STUB_STATE/pr-body-240.txt"
check "the first line names the kind" \
  test "$(head -1 "$STUCK")" = '**Escalated — `stuck`:** signals are undecided and waiting will not decide them.'
# **`escalate` is never reached from a `defer` at expiry.** The deferring rows
# still read `defer` and still name what they are waiting on — nothing is
# reclassified, because what would retract them is the signal landing on its own
# and the operator cannot do it. The clock's own row reads `note`: it judged
# nothing, and the verdict reads the expiry boolean rather than this row.
check_grep "| defer | GitHub has not settled whether this pull request conflicts | \`mergeable=UNKNOWN\` |" "$STUCK"
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=UNKNOWN\` |" "$STUCK"
check_grep "| note | the merge-gate clock has run out | \`age=3601s bound=3600s head=2026-08-27T12:00:00Z\` |" "$STUCK"
check_no_grep "| no |" "$STUCK"

# --- pr phase: the rate limit defers, ahead of every veto and outside the clock --------

# A throttled pull request keeps a **stale** verdict — 241's walkthrough puts
# the level at high, which V1 alone would escalate on. The marker is tested
# ahead of every veto, so it defers instead: the handover would otherwise turn a
# transient throttle into a permanent one, and fair-usage throttling would
# escalate the whole queue whenever the reviewer is merely slow.
#
# It is also **exempt from the gate clock**, which is why it is in this world:
# 241 shares 240's head date, so it is equally far past the bound at the second
# instant and defers anyway. That is safe because unlike a review pause the rate
# limit self-clears as usage ages out; the comment even ships its own estimate.
check_grep "pr nywleswoey/automation#241 241b241b241b241b241b241b241b241b241b241b assessable review=terminal threads=0 autofix=unspent verdict=defer gate=rate-limited" "$OUT"
check_no_grep "pr comment 241 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "pr edit 241 --repo nywleswoey/automation" "$STUB_CALLS"
check "the throttled pull request really does carry a verdict V1 would veto" \
  test "$(jq -r '.data.repository.pullRequest.comments.nodes[0].body | test("Merge Risk:.*High")' "$FIXTURES/worlds/gate-clock/pr-241.json")" = "true"
# It also names this head, so it reaches the gate at all: a verdict pinned to
# another commit is the chain's business now, and would never get here.
check "and it names this head" \
  test "$(jq -r '.data.repository.pullRequest.comments.nodes[0].body | test("up to .241b")' "$FIXTURES/worlds/gate-clock/pr-241.json")" = "true"

# The same fixture inside the clock defers too, which is what "regardless of
# timestamp" means: the test has no clock of its own to be inside or outside of.
setup "a rate-limited pull request defers on every pass, at any age"
export STUB_WORLD=gate-clock STUB_NOW=2026-08-27T12:00:01Z
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#241 241b241b241b241b241b241b241b241b241b241b assessable review=terminal threads=0 autofix=unspent verdict=defer gate=rate-limited" "$OUT"
check_no_grep "pr comment 241 --repo nywleswoey/automation" "$STUB_CALLS"
# The rate-limit block arrives by an **edit**, so the comment carrying it can be
# a week older than the pull request's head. The fixture is pinned to that gap.
check "the rate-limit block arrived by editing a much older comment" \
  test "$(jq -r '.data.repository.pullRequest.comments.nodes[0] | (.createdAt < .updatedAt)' "$FIXTURES/worlds/gate-clock/pr-241.json")" = "true"

# --- pr phase: V3's classification, value by value --------------------------------------

# **One signal, one veto**, exhaustively. Seventeen pull requests, one per value of
# each of the two fields V3 reads, all else held constant — so what differs in
# the verdict is caused by the classification and by nothing else.
#
# The fourteen that enumerate the two fields each carry a *guarded* path, so V4
# says no and the handover is always written: that is what makes the two V3 rows
# readable in a captured body for the values that would otherwise defer or merge
# in silence, and it holds the constant veto off V3's own axes. The last three —
# 264, 265 and 266 — drop it, and are about what the gate does with V3's answer
# rather than what the answer is. The log tail's `mergeability=` key carries the
# strictest of the two axes, which is V3's own outcome; the rows carry the axes.
#
# The classification, restated as the rule the fixtures encode — for a veto `X`
# and a value `v`, over the repository conditions `cause(v)` that can produce it:
#
#   1  every fact in it is owned by another veto            → `ok`
#   2  fully known, wholly X's, operator-retractable, and
#      not produced by the loop's own writes                → `no`
#   3  otherwise — mixed, unknown, unowned, self-retracting → `defer`
#
# Rule 1 returns `ok` rather than `defer` because a veto that deferred on another
# veto's fact would suppress the owner's own `no`. Rule 3 is what makes this safe
# under the rows GitHub does not document: `defer` is closed under union of
# causes where `no` and `ok` are not.
#
# No `--no-merge` here, unlike the omnibus gate world: not one of these seventeen
# reaches a merge verdict, so the per-repository merge bound never comes into it
# and the assertion at the bottom that nothing was merged is a finding rather
# than a restatement of the flag.
setup "V3 classifies every merge state and every conflict value by its causes"
export STUB_WORLD=gate-mergeability STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"

MG_PR="pr nywleswoey/automation"
MG_TAIL="review=terminal threads=0 autofix=unspent"
MG_HEAD="head=2026-08-27T11:30:00Z"
MG_CLOCK="| note | the merge-gate clock has not run out yet | \`age=1800s bound=3600s $MG_HEAD\` |"
# The clock row's third branch. It keeps the age and the bound — which is the
# point of it: an operator who gets a handover on the first pass must be able to
# see that the timeout is not mis-set.
MG_PERMANENT_CLOCK="| note | the merge-gate clock does not apply — a deferring cause above is permanent | \`age=1800s bound=3600s permanent="

# The conflict axis passes on every one of these, and its row is the same row
# each time — which is the point of splitting: a `no` on the drift axis never
# appears beside a raw value reading `mergeable`.
MG_CONFLICT_OK="| ok | GitHub reports no conflict between this head and its base | \`mergeable=MERGEABLE\` |"

# `CLEAN` — rule 1. Nothing in it is V3's, so V3 passes it.
check_grep "$MG_PR#250 250a250a250a250a250a250a250a250a250a250a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=ok blast=no" "$OUT"
check_grep "$MG_CONFLICT_OK" "$STUB_STATE/pr-body-250.txt"
check_grep "| ok | GitHub's merge state raises nothing this veto owns | \`state=CLEAN\` |" "$STUB_STATE/pr-body-250.txt"

# `DIRTY` — rule 1, reclassified from `no`. It is the conflict fact, and the
# conflict axis owns it: `mergeable` discriminates about it and this field does
# not, so this axis says nothing about it in either direction.
check_grep "$MG_PR#251 251a251a251a251a251a251a251a251a251a251a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=ok blast=no" "$OUT"
check_grep "$MG_CONFLICT_OK" "$STUB_STATE/pr-body-251.txt"
check_grep "| ok | GitHub's merge state raises nothing this veto owns | \`state=DIRTY\` |" "$STUB_STATE/pr-body-251.txt"

# `UNSTABLE` — rule 1, reclassified from `no`. It is the check fact, which V2
# owns and reads far more directly: V2's rollup names the context and separates
# pending from failed, where `UNSTABLE` names nothing.
check_grep "$MG_PR#252 252a252a252a252a252a252a252a252a252a252a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=ok blast=no" "$OUT"
check_grep "$MG_CONFLICT_OK" "$STUB_STATE/pr-body-252.txt"
check_grep "| ok | GitHub's merge state raises nothing this veto owns | \`state=UNSTABLE\` |" "$STUB_STATE/pr-body-252.txt"

# `BEHIND` — rule 2, and one of only two `no`s left in the whole veto. Base drift
# is wholly V3's, fully known, and retracts only because someone acts.
check_grep "$MG_PR#253 253a253a253a253a253a253a253a253a253a253a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=no blast=no" "$OUT"
check_grep "$MG_CONFLICT_OK" "$STUB_STATE/pr-body-253.txt"
check_grep "| no | the base has moved on past this pull request's merge base | \`state=BEHIND\` |" "$STUB_STATE/pr-body-253.txt"

# `BLOCKED` — rule 3, reclassified from `no`, and the specimen's own value. Its
# causes are mixed and partly undocumented: a required check that has not
# reported yet is one of them, and that one retracts itself.
check_grep "$MG_PR#254 254a254a254a254a254a254a254a254a254a254a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=no" "$OUT"
check_grep "$MG_CONFLICT_OK" "$STUB_STATE/pr-body-254.txt"
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=BLOCKED\` |" "$STUB_STATE/pr-body-254.txt"
check_grep "$MG_CLOCK" "$STUB_STATE/pr-body-254.txt"

# `DRAFT` — rule 3, reclassified from `no`. Draft is the scope filter's fact and
# not V3's. The enumeration drops drafts, so the only pull request that reaches
# here carrying this value is one drafted between that read and this one — the
# fixture is not draft, because what is under test is the classification and not
# the race that delivers it.
check_grep "$MG_PR#255 255a255a255a255a255a255a255a255a255a255a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=no age=1800 bound=3600 permanent=DRAFT" "$OUT"
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=DRAFT\` |" "$STUB_STATE/pr-body-255.txt"
# **Marked permanent.** Both clauses hold: the cause set is sourced, and nothing
# in it can be retracted by elapsed time alone. The verdict is still `defer` —
# the mark rides on the reason and the routing outside the gate reads it.
check_grep "${MG_PERMANENT_CLOCK}DRAFT head=2026-08-27T11:30:00Z\` |" "$STUB_STATE/pr-body-255.txt"
check_no_grep "$MG_CLOCK" "$STUB_STATE/pr-body-255.txt"
check_grep "$MG_CONFLICT_OK" "$STUB_STATE/pr-body-255.txt"

# `HAS_HOOKS` — rule 3, reclassified from `no`. A pre-receive hook is a
# repository condition no veto owns.
check_grep "$MG_PR#256 256a256a256a256a256a256a256a256a256a256a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=no age=1800 bound=3600 permanent=HAS_HOOKS" "$OUT"
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=HAS_HOOKS\` |" "$STUB_STATE/pr-body-256.txt"
check_grep "${MG_PERMANENT_CLOCK}HAS_HOOKS head=2026-08-27T11:30:00Z\` |" "$STUB_STATE/pr-body-256.txt"
check_no_grep "$MG_CLOCK" "$STUB_STATE/pr-body-256.txt"
check_grep "$MG_CONFLICT_OK" "$STUB_STATE/pr-body-256.txt"

# `UNKNOWN` — rule 3, unchanged. GitHub is still computing.
check_grep "$MG_PR#257 257a257a257a257a257a257a257a257a257a257a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=no" "$OUT"
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=UNKNOWN\` |" "$STUB_STATE/pr-body-257.txt"
check_grep "$MG_CONFLICT_OK" "$STUB_STATE/pr-body-257.txt"

# Empty — rule 3, reclassified from `no`. A field that did not arrive is an
# unknown cause set, and unknown classifies as self-retracting.
check_grep "$MG_PR#258 258a258a258a258a258a258a258a258a258a258a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=no" "$OUT"
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=none\` |" "$STUB_STATE/pr-body-258.txt"
check_grep "$MG_CONFLICT_OK" "$STUB_STATE/pr-body-258.txt"

# A value the loop has never heard of — rule 3, and the `else` arm inverted from
# `no`. **A merge state GitHub adds tomorrow defers that one pull request rather
# than escalating the queue.**
check_grep "$MG_PR#259 259a259a259a259a259a259a259a259a259a259a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=no" "$OUT"
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=SOMETHING_GITHUB_ADDED\` |" "$STUB_STATE/pr-body-259.txt"
check_grep "$MG_CONFLICT_OK" "$STUB_STATE/pr-body-259.txt"

# --- the conflict axis, against a merge state that raises nothing -----------------------

MG_STATE_OK="| ok | GitHub's merge state raises nothing this veto owns | \`state=CLEAN\` |"

# `CONFLICTING` — rule 2, and the second of the two `no`s. Wholly V3's, fully
# known, and it takes a push to retract.
check_grep "$MG_PR#260 260a260a260a260a260a260a260a260a260a260a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=no blast=no" "$OUT"
check_grep "| no | this pull request conflicts with its base | \`mergeable=CONFLICTING\` |" "$STUB_STATE/pr-body-260.txt"
check_grep "$MG_STATE_OK" "$STUB_STATE/pr-body-260.txt"

# `UNKNOWN` — rule 3, unchanged. Reading it as *no conflicts detected* is how a
# gate merges a conflicted pull request.
check_grep "$MG_PR#261 261a261a261a261a261a261a261a261a261a261a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=no" "$OUT"
check_grep "| defer | GitHub has not settled whether this pull request conflicts | \`mergeable=UNKNOWN\` |" "$STUB_STATE/pr-body-261.txt"
check_grep "$MG_STATE_OK" "$STUB_STATE/pr-body-261.txt"

# Empty — rule 3, reclassified from `no`.
check_grep "$MG_PR#262 262a262a262a262a262a262a262a262a262a262a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=no" "$OUT"
check_grep "| defer | GitHub has not settled whether this pull request conflicts | \`mergeable=none\` |" "$STUB_STATE/pr-body-262.txt"
check_grep "$MG_STATE_OK" "$STUB_STATE/pr-body-262.txt"

# A conflict value the loop has never heard of — rule 3, reclassified from `no`.
check_grep "$MG_PR#263 263a263a263a263a263a263a263a263a263a263a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=no" "$OUT"
check_grep "| defer | GitHub has not settled whether this pull request conflicts | \`mergeable=SOMETHING_NEW\` |" "$STUB_STATE/pr-body-263.txt"
check_grep "$MG_STATE_OK" "$STUB_STATE/pr-body-263.txt"

# --- the clock is emitted on a defer and on nothing else --------------------------------

# The clock's row is a `note` — *a row that judged nothing at all* — and it
# appears whenever anything defers and never when nothing does. 250 and 253 are
# the two ends of that: neither defers, and neither carries a clock row.
check_no_grep "| note |" "$STUB_STATE/pr-body-250.txt"
check_no_grep "age=" "$STUB_STATE/pr-body-250.txt"
check_no_grep "| note |" "$STUB_STATE/pr-body-253.txt"
check_grep "$MG_CLOCK" "$STUB_STATE/pr-body-257.txt"
check_grep "$MG_CLOCK" "$STUB_STATE/pr-body-263.txt"
# And the tail agrees with the table: no clock keys on a pass where nothing
# deferred, which is what makes the log line diagnosable without a round-trip.
check_grep "$MG_PR#250 250a250a250a250a250a250a250a250a250a250a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=ok blast=no action=escalated kind=escalate label=added" "$OUT"
check_grep "$MG_PR#257 257a257a257a257a257a257a257a257a257a257a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=no age=1800 bound=3600 action=escalated kind=escalate label=added" "$OUT"

# --- a failing check is never delayed by a clock ----------------------------------------

# 264 is the one pull request here V4 clears, and it carries a red check beside a
# deferring merge state. **The most actionable veto in the gate is never delayed:**
# it escalates on the pass it is derived, names the context, and the kind is the
# veto's rather than the clock's — even though the merge state is deferring at
# the same instant and the clock has 1800 seconds left to run.
check_grep "$MG_PR#264 264a264a264a264a264a264a264a264a264a264a assessable $MG_TAIL verdict=escalate risk=ok checks=no mergeability=defer blast=ok age=1800 bound=3600 action=escalated kind=escalate label=added" "$OUT"
MG_RED="$STUB_STATE/pr-body-264.txt"
check "the first line names the kind" \
  test "$(head -1 "$MG_RED")" = '**Escalated — `escalate`:** a veto is present and says no.'
check_grep "| no | a status check on this commit is not green | \`green=1 pending=0 failed=1 total=2 failing=ci/build=FAILURE\` |" "$MG_RED"
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=BLOCKED\` |" "$MG_RED"
check_grep "$MG_CLOCK" "$MG_RED"

# --- an unrecognised value is a bounded surprise ----------------------------------------

# 265 carries the same merge state GitHub has not documented as 259 and nothing
# else wrong. **It defers that one pull request** — silently, re-derived next
# pass — rather than escalating it, and the other fourteen in the same pass reach
# their own verdicts regardless. That is the whole of what the inverted `else`
# arm buys: a schema change GitHub ships is a bounded surprise.
check_grep "$MG_PR#265 265a265a265a265a265a265a265a265a265a265a assessable $MG_TAIL verdict=defer risk=ok checks=ok mergeability=defer blast=ok age=1800 bound=3600" "$OUT"
check_no_grep "pr comment 265 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "pr edit 265 --repo nywleswoey/automation" "$STUB_CALLS"

# --- the specimen, whole ----------------------------------------------------------------

# 266 is the shape the defect was found in: **one fact reported twice through two
# fields.** A required check has not reported yet, so the rollup carries it as
# `pg-gate` pending and `mergeStateStatus` carries the same fact as `BLOCKED`.
# V2 owns it and defers naming the context; V3's merge-state axis defers because
# the cause is not its own; the conflict axis passes. Nothing says no, so the
# verdict is `defer` and the pull request waits in silence until the check lands
# — where before this it was handed over on a cause that retracted itself
# twenty-nine seconds later.
check_grep "$MG_PR#266 266a266a266a266a266a266a266a266a266a266a assessable $MG_TAIL verdict=defer risk=ok checks=defer mergeability=defer blast=ok age=1800 bound=3600" "$OUT"
check_no_grep "pr comment 266 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "pr edit 266 --repo nywleswoey/automation" "$STUB_CALLS"
check "the two fields really do carry the one fact" \
  test "$(jq -r '[.data.repository.pullRequest.mergeStateStatus, ([.data.repository.pullRequest.commits.nodes[-1].commit.statusCheckRollup.contexts.nodes[] | select(.state == "PENDING") | .context] | join(","))] | join(" ")' "$FIXTURES/worlds/gate-mergeability/pr-266.json")" = "BLOCKED pg-gate"

# --- a deferring cause the clock cannot buy an answer to ---------------------------------

# 267 carries the same permanent merge state as 256 and **nothing else wrong** —
# V4 clears it, the checks are green, the conflict axis passes. It is the only
# pull request here whose handover the mark alone produces, and it arrives on the
# **first pass**: the cause set is sourced and no member of it can be retracted
# by elapsed time, so the clock would decide nothing and is not waited out.
#
# The kind is `stuck` and not `escalate`. Nothing said no — the gate owns
# judgement, the clock owns duration, and *waiting will not decide this* is what
# `stuck` now means for both of its populations.
check_grep "$MG_PR#267 267a267a267a267a267a267a267a267a267a267a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=ok age=1800 bound=3600 permanent=HAS_HOOKS action=escalated kind=stuck label=added handover=posted" "$OUT"
MG_PERM="$STUB_STATE/pr-body-267.txt"
check "the first line names the kind" \
  test "$(head -1 "$MG_PERM")" = '**Escalated — `stuck`:** signals are undecided and waiting will not decide them.'
# The deferring row is **not** reclassified by the mark either: the mark changes
# when the handover arrives and nothing else.
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=HAS_HOOKS\` |" "$MG_PERM"
check_grep "${MG_PERMANENT_CLOCK}HAS_HOOKS head=2026-08-27T11:30:00Z\` |" "$MG_PERM"
check_no_grep "| no |" "$MG_PERM"

# 268 carries the same permanent merge state **beside an ordinary one** — a check
# that has not reported yet, whose cause set is sourced but clears itself, so it
# cannot be marked. The pull request still escalates on the first pass: the
# marked cause is not going to clear, so waiting would buy only the unmarked
# one's answer, and the handover carries both rows.
check_grep "$MG_PR#268 268a268a268a268a268a268a268a268a268a268a assessable $MG_TAIL verdict=escalate risk=ok checks=defer mergeability=defer blast=ok age=1800 bound=3600 permanent=HAS_HOOKS action=escalated kind=stuck label=added handover=posted" "$OUT"
MG_BOTH="$STUB_STATE/pr-body-268.txt"
check_grep "| defer | a status check on this commit has not reported yet | \`green=1 pending=1 failed=0 total=2 waiting=ci/build\` |" "$MG_BOTH"
check_grep "| defer | GitHub's merge state is not one this veto can conclude from | \`state=HAS_HOOKS\` |" "$MG_BOTH"
# One clock row for both, naming only what is marked: the mark is a property of
# a reason, and the unmarked one is still waiting and still says so.
check_grep "${MG_PERMANENT_CLOCK}HAS_HOOKS head=2026-08-27T11:30:00Z\` |" "$MG_BOTH"
check "the clock still gets exactly one row" \
  test "$(grep -cF '| note |' "$MG_BOTH")" -eq 1

# One line per pull request, one action at most on each, and nothing merged.
check "one state line per pull request" \
  test "$(grep -cE '^[0-9TZ:-]+ pr nywleswoey/automation#' "$OUT")" -eq 19
check "nothing at all was merged" \
  test "$(grep -cE 'pulls/[0-9]+/merge' "$STUB_CALLS")" -eq 0

# --- the mark is what changes the timing, proven by a mutant twin ------------------------

# The identical world at a second frozen instant, an hour and a half further on
# and well past the bound. **The marked pull requests reach the same verdict at
# both instants** — they never waited — while the two that defer on ordinary
# causes only reach `stuck` here. One fixture, one code path, two clocks: what
# differs is caused by the mark and by nothing else.
setup "a marked cause does not wait out the clock, and an unmarked one does"
export STUB_WORLD=gate-mergeability STUB_NOW=2026-08-27T13:30:01Z
run_once
check_status 0 "$STATUS"
check_grep "$MG_PR#267 267a267a267a267a267a267a267a267a267a267a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=ok age=7201 bound=3600 permanent=HAS_HOOKS action=escalated kind=stuck label=added handover=posted" "$OUT"
# 265's cause set is not established, so it cannot be marked; 266's clears
# itself. Both waited the whole bound out to arrive where 267 already was.
check_grep "$MG_PR#265 265a265a265a265a265a265a265a265a265a265a assessable $MG_TAIL verdict=escalate risk=ok checks=ok mergeability=defer blast=ok age=7201 bound=3600 action=escalated kind=stuck label=added handover=posted" "$OUT"
check_grep "$MG_PR#266 266a266a266a266a266a266a266a266a266a266a assessable $MG_TAIL verdict=escalate risk=ok checks=defer mergeability=defer blast=ok age=7201 bound=3600 action=escalated kind=stuck label=added handover=posted" "$OUT"
# The expired clock reads `note` too, and says which of its three branches it is
# in. Neither the mark nor expiry reclassifies a deferring row.
check_grep "| note | the merge-gate clock has run out | \`age=7201s bound=3600s $MG_HEAD\` |" "$STUB_STATE/pr-body-265.txt"
check_grep "| defer | a status check on this commit has not reported yet | \`green=1 pending=1 failed=0 total=2 waiting=pg-gate\` |" "$STUB_STATE/pr-body-266.txt"
check_no_grep "permanent=" "$STUB_STATE/pr-body-266.txt"

# --- pr phase: the merge ---------------------------------------------------------------

# The line the loop exists to cross. Everything before it is reversible; this is
# not, so the three guards that make crossing it safe are what the cases below
# are about: the commit named is the one the gate assessed, the bound is one
# merge per repository per pass, and `--no-merge` holds the write and nothing
# else.
#
# The world carries three pull requests: two the gate clears, so the bound has
# something to bind, and one with findings still open, so *non-merge actions are
# unbounded* is provable after the pass has spent its merge.
#
# The commits are mnemonic and pairwise distinct on purpose, and the decoy is in
# the **fixture** rather than in an assertion: 310's walkthrough carries the
# review-details line CodeRabbit really writes, naming a second full-length
# commit next to the head. A merge that read the wrong one names itself instead
# of blending into forty characters of hex.
MERGE_SHA_310=310a310a310a310a310a310a310a310a310a310a   # the commit the gate assesses
MERGE_SHA_311=311b311b311b311b311b311b311b311b311b311b   # the candidate behind it
MERGE_SHA_312=312c312c312c312c312c312c312c312c312c312c   # not a candidate at all
MERGE_DECOY=dec0dec0dec0dec0dec0dec0dec0dec0dec0dec0     # named in 310's own walkthrough
MERGE_RESPONSE_SHA=11ee66e511ee66e511ee66e511ee66e511ee66e5  # what GitHub answers with

# check_merge_argv <repo> <number> <sha> <method> — the **whole** recorded argv
# line. A grep for the commit alone passes on a call that also sent the wrong
# method, and a grep for the method alone passes on a call that merged the wrong
# commit; only the line as a whole fails on either. It spells gh_json's own
# `--full --jq` tail, and that coupling is the point rather than a leak: what is
# being pinned is the exact command the loop caused to be issued.
check_merge_argv() {
  local want="gh-axi api PUT /repos/$1/pulls/$2/merge --field sha=$3 --field merge_method=$4 --full --jq tojson|@base64"
  check "the merge call is exactly: $want" grep -qxF -- "$want" "$STUB_CALLS"
}

# The guard that keeps every "it named the one it assessed" assertion below
# non-vacuous: were any two of these ever edited to the same value, a wrong read
# would satisfy the assertion for the right one.
setup "the merge fixtures make a wrong commit visible"
check "the two candidates are distinct" test "$MERGE_SHA_310" != "$MERGE_SHA_311"
check "neither is the pull request that is not a candidate" \
  test "$MERGE_SHA_310" != "$MERGE_SHA_312" -a "$MERGE_SHA_311" != "$MERGE_SHA_312"
check "none of them is the decoy in 310's own walkthrough" \
  test "$MERGE_SHA_310" != "$MERGE_DECOY" -a "$MERGE_SHA_311" != "$MERGE_DECOY" \
    -a "$MERGE_SHA_312" != "$MERGE_DECOY"
check "and none is the commit GitHub answers the merge with" \
  test "$MERGE_SHA_310" != "$MERGE_RESPONSE_SHA" -a "$MERGE_DECOY" != "$MERGE_RESPONSE_SHA"
check "the decoy really is in the fixture, or it is guarding nothing" \
  grep -qF "$MERGE_DECOY" "$FIXTURES/worlds/merge/pr-310.json"

setup "a minimal-risk pull request is merged, and the merge names the assessed commit"
export STUB_WORLD=merge STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#310 $MERGE_SHA_310 assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=merged method=squash" "$OUT"
check_merge_argv nywleswoey/automation 310 "$MERGE_SHA_310" squash
# Not the subcommand: `gh-axi pr merge` has no way to say which commit, which is
# the whole reason the seam reaches for the raw endpoint.
check_no_grep "pr merge" "$STUB_CALLS"
# The three commits a wrong read could have named instead.
check_no_grep "sha=$MERGE_DECOY" "$STUB_CALLS"
check_no_grep "sha=$MERGE_SHA_311" "$STUB_CALLS"
check_no_grep "$MERGE_RESPONSE_SHA" "$STUB_CALLS"
# **Assess, then merge that commit** — asserted by call position, so the order is
# a fact about the run rather than a reading of the source.
check "the pull request is read before it is merged" \
  test "$(call_line 'pullRequest(number: 310)')" -lt "$(call_line '/pulls/310/merge')"
# Branch deletion needs no key and no call: the repository's delete-on-merge
# setting is honoured by GitHub on the merge itself.
check_no_grep "--delete-branch" "$STUB_CALLS"
check_no_grep "DELETE /repos/nywleswoey/automation/git/refs" "$STUB_CALLS"
# A merge is silent on the pull request itself: the loop says nothing where
# GitHub has already said everything.
check_no_grep "pr comment 310 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "pr edit 310 --repo nywleswoey/automation" "$STUB_CALLS"

# A mutant twin on the method: the same fixture and the same commit, one config
# key apart. Without it a merge method hard-coded to `squash` would pass every
# assertion above.
setup "the configured merge method reaches the call rather than being defaulted"
write_config "nywleswoey/automation" "repo-aaa" 300 3 5400 3600 rebase
export STUB_WORLD=merge STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#310 $MERGE_SHA_310 assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=merged method=rebase" "$OUT"
check_merge_argv nywleswoey/automation 310 "$MERGE_SHA_310" rebase
check_no_grep "merge_method=squash" "$STUB_CALLS"

setup "at most one merge per repository per pass, and non-merge actions are unbounded"
export STUB_WORLD=merge STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check "exactly one merge this pass" \
  test "$(grep -cE 'pulls/[0-9]+/merge' "$STUB_CALLS")" -eq 1
# 311 clears the gate exactly as 310 does, and is deferred rather than dropped —
# said out loud, because with no local state this line is the only record the
# candidate leaves. A merge changes the base under it, so its verdict has to be
# re-derived next pass rather than acted on now.
check_grep "pr nywleswoey/automation#311 $MERGE_SHA_311 assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=deferred bound=merge-per-repo" "$OUT"
check_no_grep "/pulls/311/merge" "$STUB_CALLS"
# 312 is behind the merge in the enumeration and still acted on: the bound is on
# merges, and a trigger changes no base.
check_grep "pr nywleswoey/automation#312 $MERGE_SHA_312 needs-autofix review=terminal threads=2 autofix=unspent action=triggered" "$OUT"
check_grep "gh-axi pr comment 312 --repo nywleswoey/automation --body @coderabbitai autofix" "$STUB_CALLS"
check "the trigger is fired after the merge has already been spent" \
  test "$(call_line '/pulls/310/merge')" -lt "$(call_line 'pr comment 312')"

# --- pr phase: --no-merge, proven by a mutant twin -------------------------------------

# The same world at the same instant, one flag apart. Everything up to the
# action is identical, which is what makes the difference attributable to the
# flag and to nothing else.
MERGE_STATE_310="pr nywleswoey/automation#310 $MERGE_SHA_310 assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok"

setup "--no-merge holds the merge, and holds nothing else"
export STUB_WORLD=merge STUB_NOW=2026-08-27T12:00:00Z
run_once --no-merge
check_status 0 "$STATUS"
# The verdict it would have acted on is logged, and the write is not made.
check_grep "$MERGE_STATE_310 action=would-merge method=squash" "$OUT"
check "nothing at all was merged" \
  test "$(grep -cE 'pulls/[0-9]+/merge' "$STUB_CALLS")" -eq 0
check_no_grep "$MERGE_SHA_310" "$STUB_CALLS"
# Everything reversible still runs.
check_grep "pr nywleswoey/automation#312 $MERGE_SHA_312 needs-autofix review=terminal threads=2 autofix=unspent action=triggered" "$OUT"
check_grep "gh-axi pr comment 312 --repo nywleswoey/automation --body @coderabbitai autofix" "$STUB_CALLS"
# The bound is spent by the held merge too, so `--once --no-merge` reports the
# same set of actions a real pass would take rather than every candidate it can
# see. The flag withholds the write, not the arithmetic.
check_grep "pr nywleswoey/automation#311 $MERGE_SHA_311 assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=deferred bound=merge-per-repo" "$OUT"

setup "the same pass without the flag merges instead"
export STUB_WORLD=merge STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "$MERGE_STATE_310 action=merged method=squash" "$OUT"
check_merge_argv nywleswoey/automation 310 "$MERGE_SHA_310" squash

# A flag, never a key. A config that names one is a config with an unknown key
# in it, and unknown keys are ignored — so the merge happens, which is the only
# way to say "this is not a switch" out loud.
setup "--no-merge is a flag and not a config key"
cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": 300,
  "maxWorkers": 3,
  "autofixTimeoutSeconds": 5400,
  "mergeGateTimeoutSeconds": 3600,
  "noMerge": true,
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "nywleswoey/automation", "orcaRepoId": "repo-aaa", "mergeMethod": "squash" }
  ]
}
JSON
export STUB_WORLD=merge STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status 0 "$STATUS"
check_grep "$MERGE_STATE_310 action=merged method=squash" "$OUT"
check_merge_argv nywleswoey/automation 310 "$MERGE_SHA_310" squash

# --- pr phase: a merge GitHub refuses --------------------------------------------------

# Measured against real GitHub: a merge naming a commit that is no longer the
# head comes back `Head branch was modified` with the status suffix intact,
# which classifies `refused`. So a race with a human push **escalates rather
# than retrying** — which is the entire reason the assessed commit is sent as an
# assertion in the first place.
setup "a merge racing a human push escalates rather than retrying"
export STUB_WORLD=merge STUB_NOW=2026-08-27T12:00:00Z
export STUB_GH_FAIL=merge STUB_GH_ERROR=409-race
run_once
check_status 0 "$STATUS"
check_grep "$MERGE_STATE_310 merge=refused rc=3 action=escalated kind=refused label=added" "$OUT"
check "the merge was attempted exactly once" \
  test "$(grep -cE 'pulls/[0-9]+/merge' "$STUB_CALLS")" -eq 1
REFUSED="$STUB_STATE/pr-body-310.txt"
# Its own kind, because *I said yes and reality disagreed* is evidence the
# rubric is wrong rather than a fact about this pull request.
check "the first line names the kind" \
  test "$(head -1 "$REFUSED")" = '**Escalated — `refused`:** the gate said merge and GitHub said no.'
# GitHub's answer and the seam's exit status, verbatim — the whole of what the
# operator has to go on.
check_grep 'rc=3 method=squash head=310a310a310a310a310a310a310a310a310a310a response=error: "gh: Head branch was modified. Review and try the merge again. (HTTP 409)" code: UNKNOWN' "$REFUSED"
# The rows that led the gate to say yes travel with it: an operator asked to
# believe the rubric is wrong is owed what the rubric saw.
check_grep "| ok | CodeRabbit puts merge risk at minimal for this commit |" "$REFUSED"
check_grep "| ok | every status check on this commit is green |" "$REFUSED"
check_grep "| ok | GitHub reports no conflict between this head and its base |" "$REFUSED"
check_grep "| ok | GitHub's merge state raises nothing this veto owns |" "$REFUSED"
check_grep "| ok | nothing here changes what runs unattended |" "$REFUSED"
# Nothing deferred, so there is no clock row: four vetoes with V3 in two rows,
# the refusal, and the table head.
check_no_grep "| note |" "$REFUSED"
check "four vetoes — V3 in two — the refusal, and the table head" \
  test "$(grep -cE '^\|' "$REFUSED")" -eq 8
check_grep "gh-axi pr edit 310 --repo nywleswoey/automation --add-label agent-escalated" "$STUB_CALLS"
# A refusal is not a skip. The loop set out to act on this pull request and did
# — the action turned out to be the handover, and the handover landed. Only a
# handover that fails to land counts against the pass.
check_grep "pass end dispatches=0 skips=0" "$OUT"
# The bound is spent by the attempt, so the pass stops touching this repository's
# merge candidates whatever the answer was.
check_grep "pr nywleswoey/automation#311 $MERGE_SHA_311 assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=deferred bound=merge-per-repo" "$OUT"

# --- pr phase: a merge that fails transiently ------------------------------------------

# The other class. Nothing durable came back, so nothing is escalated — a
# handover is never retried, and posting one on a network blip would park a good
# pull request until a human noticed. Nothing is retried inside the pass either:
# the poll interval is the whole of the backoff and the next pass re-derives.
setup "a transient merge failure is neither escalated nor retried"
export STUB_WORLD=merge STUB_NOW=2026-08-27T12:00:00Z
export STUB_GH_FAIL=merge STUB_GH_ERROR=500
run_once
check_status 0 "$STATUS"
check_grep "$MERGE_STATE_310 merge=failed class=transient rc=4" "$OUT"
check "the merge was attempted exactly once" \
  test "$(grep -cE 'pulls/[0-9]+/merge' "$STUB_CALLS")" -eq 1
check_no_grep "pr comment 310 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "pr edit 310 --repo nywleswoey/automation" "$STUB_CALLS"
check_no_grep "kind=refused" "$OUT"
# It counts against the pass, because `pass end` is where a run that failed to
# do what it set out to do is supposed to say so.
check_grep "pass end dispatches=0 skips=1" "$OUT"

# --- the merge method is per repository, required, and checked at startup --------------

setup "a config with no merge method fails at startup"
cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": 300,
  "maxWorkers": 3,
  "autofixTimeoutSeconds": 5400,
  "mergeGateTimeoutSeconds": 3600,
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "nywleswoey/automation", "orcaRepoId": "repo-aaa" }
  ]
}
JSON
run_once
check_status nonzero "$STATUS"
check_grep "projects[0] (nywleswoey/automation) has no mergeMethod" "$OUT"
check "no pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 0

setup "a merge method that is not one fails at startup"
write_config "nywleswoey/automation" "repo-aaa" 300 3 5400 3600 fast-forward
run_once
check_status nonzero "$STATUS"
check_grep "mergeMethod must be one of: merge squash rebase, got: fast-forward" "$OUT"
check "no pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 0

# The one that matters most. A method the repository forbids comes back from
# GitHub as a refusal, which classifies `refused` and reaches the operator as
# *I said yes and reality disagreed* — the kind that exists precisely to say the
# rubric is wrong. A config typo must never be able to impersonate that, so it
# dies at second zero against the repository's own permission booleans.
setup "a merge method the repository forbids fails at startup, not at the merge"
write_config "nywleswoey/merge-only" "repo-aaa" 300 3 5400 3600 squash
export STUB_WORLD=merge STUB_NOW=2026-08-27T12:00:00Z
run_once
check_status nonzero "$STATUS"
check_grep "nywleswoey/merge-only does not permit mergeMethod squash (allow_squash_merge is false)" "$OUT"
check "no pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 0
check "and nothing was merged on the way to finding out" \
  test "$(grep -cE 'pulls/[0-9]+/merge' "$STUB_CALLS")" -eq 0
# Checked against the read that already happens, so the guard costs no new call.
check "the permission read is the repository read the loop already makes" \
  test "$(grep -cxF 'gh-axi api /repos/nywleswoey/merge-only --full --jq tojson|@base64' "$STUB_CALLS")" -eq 1

# The same repository with the method it does permit starts, which is what keeps
# the case above about the method rather than about the repository.
setup "the same repository with a method it permits starts"
write_config "nywleswoey/merge-only" "repo-aaa" 300 3 5400 3600 merge
run_once
check_status 0 "$STATUS"
check_grep "validated nywleswoey/merge-only -> orca repo repo-aaa, merging by merge" "$OUT"
check_grep "pass end" "$OUT"

# --- pr phase: configuration order is the axis ---------------------------------------

setup "pull requests are enumerated per repository, in configuration order"
cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": 300,
  "maxWorkers": 3,
  "autofixTimeoutSeconds": 5400,
  "mergeGateTimeoutSeconds": 3600,
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "nywleswoey/automation", "orcaRepoId": "repo-aaa", "mergeMethod": "squash" },
    { "github": "nywleswoey/other", "orcaRepoId": "repo-bbb", "mergeMethod": "squash" }
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

# The one-merge bound is **per repository**, and this is where that is visible:
# both pull requests clear the gate and both are merged in the same pass. A
# merge changes the base under the other pull requests in its own repository and
# under nothing else, so a global bound would have parked the second repository
# behind the first for a whole poll interval, every pass, forever.
check_grep "pr nywleswoey/automation#501 501a501a501a501a501a501a501a501a501a501a assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=merged method=squash" "$OUT"
check_grep "pr nywleswoey/other#502 502b502b502b502b502b502b502b502b502b502b assessable review=terminal threads=0 autofix=unspent verdict=merge risk=ok checks=ok mergeability=ok blast=ok action=merged method=squash" "$OUT"
check "one merge in each repository, not one across both" \
  test "$(grep -cE 'pulls/[0-9]+/merge' "$STUB_CALLS")" -eq 2
check "and each names its own repository's commit" \
  grep -qxF -- 'gh-axi api PUT /repos/nywleswoey/other/pulls/502/merge --field sha=502b502b502b502b502b502b502b502b502b502b --field merge_method=squash --full --jq tojson|@base64' "$STUB_CALLS"

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
# The example config is a shipped artifact, and the one piece of documentation
# that can be wrong in a way prose cannot: an operator copies it and the loop
# refuses to start. It is checked against the config `write_config` writes —
# which every passing case in this suite starts the loop on, so it is the shape
# the loop is *known* to accept — rather than against a second written-down copy
# of the rules, which would be one more thing to keep in sync.
setup "the example config carries the shape the loop requires"
EXAMPLE="$ROOT/agent-loop.config.example.json"
key_shape() {
  # Every scalar's path, with array indices flattened, so two configs carrying a
  # different number of projects still compare by shape rather than by size.
  jq -r '[paths(scalars)
          | map(if type == "number" then "[]" else . end)
          | join(".")] | unique | .[]' "$1" 2>/dev/null
}
EXAMPLE_KEYS=$(key_shape "$EXAMPLE")
KNOWN_GOOD_KEYS=$(key_shape "$CONFIG")
# A bare string comparison would report only its own label, where the rest of
# this suite dumps what it found. The differing key goes in the label instead.
KEY_DIFF=$(diff <(printf '%s\n' "$KNOWN_GOOD_KEYS") <(printf '%s\n' "$EXAMPLE_KEYS") \
  | grep -E '^[<>]' | tr '\n' ' ')
check "the example config is valid JSON with keys in it" test -n "$EXAMPLE_KEYS"
check "the example config carries exactly the keys the loop requires${KEY_DIFF:+ — $KEY_DIFF}" \
  test "$EXAMPLE_KEYS" = "$KNOWN_GOOD_KEYS"
# The dead seen-list key gets no assertion of its own. It would be a *negative*
# one standing alone, which is the shape this suite refuses everywhere else —
# and it would pass for the wrong reason on an unparseable example, where jq
# prints nothing and `check` does not abort. The comparison above already
# carries it: a config still naming `seenListPath` differs in shape and says so.

# The method the example suggests has to be one the loop will actually start on,
# and that is a claim about behaviour rather than about the source. So it is
# asserted the way the two cases above assert it — by starting the loop on a
# config carrying that method. Reading `MERGE_METHODS=` out of the script would
# be the project's *second* assertion over its own source, and the README says
# there is one.
setup "the merge method the example suggests is one the loop starts on"
EXAMPLE="$ROOT/agent-loop.config.example.json"
write_config "nywleswoey/automation" "repo-aaa" 300 3 5400 3600 \
  "$(jq -r '.projects[0].mergeMethod' "$EXAMPLE")"
run_once
check_status 0 "$STATUS"
check_grep "merging by $(jq -r '.projects[0].mergeMethod' "$EXAMPLE")" "$OUT"
check_grep "pass end" "$OUT"

setup "a config still naming the deleted seen list fails at startup"
cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": 300,
  "maxWorkers": 3,
  "autofixTimeoutSeconds": 5400,
  "mergeGateTimeoutSeconds": 3600,
  "seenListPath": "$WORK/seen.jsonl",
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "nywleswoey/automation", "orcaRepoId": "repo-aaa", "mergeMethod": "squash" }
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
  "mergeGateTimeoutSeconds": 3600,
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "nywleswoey/automation", "orcaRepoId": "repo-aaa", "mergeMethod": "squash" }
  ]
}
JSON
run_once
check_status nonzero "$STATUS"
check_grep "config is missing autofixTimeoutSeconds" "$OUT"
check "no pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 0

# The gate clock is required on the same argument and thinner evidence: this
# config has no defaults anywhere, and there is no sample at all behind the
# number. A default would be a guess wearing a number's clothes.
setup "the merge-gate timeout is required, not defaulted"
cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": 300,
  "maxWorkers": 3,
  "autofixTimeoutSeconds": 5400,
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "nywleswoey/automation", "orcaRepoId": "repo-aaa", "mergeMethod": "squash" }
  ]
}
JSON
run_once
check_status nonzero "$STATUS"
check_grep "config is missing mergeGateTimeoutSeconds" "$OUT"
check "no pass ran" test "$(grep -cF 'pass start' "$OUT")" -eq 0

setup "a merge-gate timeout that is not a positive integer fails at startup"
write_config "nywleswoey/automation" "repo-aaa" 300 3 5400 0
run_once
check_status nonzero "$STATUS"
check_grep "config mergeGateTimeoutSeconds must be a positive integer, got: 0" "$OUT"

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
# one whose issue is closed and unclaimed, one whose issue is closed and still
# claimed, one whose issue I claimed by hand, one from a branch that names no
# issue, one with the collision suffix, and one in a project the config does not
# list.
# The close and the unclaim are two calls in that order, so a failure can only
# ever leave the label on an issue that is already closed.
CLOSE_17="gh-axi issue close 17 --repo nywleswoey/automation"
UNCLAIM_17="gh-axi issue edit 17 --repo nywleswoey/automation --remove-label agent-in-progress"

# Nothing in this build merges anything, so every pull request the close-out
# reads here was merged by a hand — which is exactly the guarantee an escalated
# pull request needs. Close-out reads merged pull requests from GitHub and
# cannot tell whose hand pressed the button, so taking one over by hand does not
# cost the operator the tick and the close.
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

# 203 — issue 41 is closed and carries no claim label, so close-out has already
# finished with it: one read to find that out, and nothing else. This is the
# steady state every closed-out issue lands in, and it is what keeps the phase
# from repeating a line for as long as the pull request stays merged.
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

# 208 — issue 44's pull request body carried a closing keyword, so GitHub closed
# the issue itself at merge, a pass before close-out ever read it. The tick and
# the unclaim are still outstanding; the close is not, and re-closing a closed
# issue is a write with nothing behind it.
check_grep "closed out nywleswoey/automation#44: pull request #208 merged, issue already closed" "$OUT"
check_no_grep "gh-axi issue close 44 " "$STUB_CALLS"
check_grep "gh-axi issue edit 44 --repo nywleswoey/automation --remove-label agent-in-progress" "$STUB_CALLS"
printf -- '- [x] closed by a keyword\n' > "$WORK/expected-44.txt"
check "an already-closed issue still gets its checklist ticked" \
  diff -q "$WORK/expected-44.txt" "$STUB_STATE/body-44.txt"

# 207 — a branch that names no issue is a pull request I opened by hand.
# 907 — a merged pull request in a project the config does not list.
check_no_grep "issues/99" "$STUB_CALLS"
check_no_grep "#207" "$OUT"
check_no_grep "#907" "$OUT"

check "exactly four issues were closed" test "$(grep -cF 'gh-axi issue close ' "$STUB_CALLS")" -eq 4
# The close-out runs before the reclaim, so the pass that follows it sees the
# issues closed and repeats none of its own lines.
check "one close-out line per issue" test "$(grep -cF 'closed out nywleswoey/automation#17' "$OUT")" -eq 1

setup "close-out goes quiet on a second pass over the same merged pull requests"
# The whole of the fix is that the silence is keyed on the claim label. So the
# proof is two passes over an unchanged set of merged pull requests: the first
# does the work, the second reads the same pull requests, finds the claim gone
# from every issue, and says nothing — including about #44, which GitHub had
# already closed and which the old state-keyed guard passed over in silence
# while its label was still on.
export STUB_MERGED=set
run_once
cp "$OUT" "$WORK/pass-1.log"
check_grep "closed out nywleswoey/automation#44: pull request #208 merged, issue already closed" "$WORK/pass-1.log"
run_once
check_status 0 "$STATUS"
check_no_grep "closed out" "$OUT"
check_no_grep "unclaim failed" "$OUT"

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
check_grep "checklist update failed for nywleswoey/automation#17, closing it out anyway" "$OUT"
check_grep "$CLOSE_17" "$STUB_CALLS"
check_grep "closed out nywleswoey/automation#17: pull request #201 merged" "$OUT"

setup "a failed close is logged and the pass continues"
export STUB_MERGED=set STUB_GH_FAIL=close
run_once
check_status 0 "$STATUS"
check_grep "close failed for nywleswoey/automation#17, leaving it claimed" "$OUT"
check_grep "pass start" "$OUT"
check_grep "pass end" "$OUT"

setup "a failed unclaim leaves a closed issue for the next close-out to finish"
# Every label edit fails, so every unclaim does. Close-out runs twice in a
# --once run — at startup, before the reclaim, and again inside the pass — which
# is what makes the recovery visible in a single run.
#
# The startup close-out closes #17, #40, #11 and #43 and cannot unclaim them:
# the close is what stops the re-dispatch, so it still counts as a close-out.
# #44 GitHub had already closed, so the unclaim is the whole of the work there
# and losing it is a skip rather than a partial success — no `closed out` line.
#
# The pass's close-out then reads all five back closed and still claimed, which
# is the state the guard now keys on, and retries every one of them. That is the
# self-heal: a lost unclaim is retried until it lands, and until then it is five
# skips rather than five issues quietly stranded.
export STUB_MERGED=set STUB_GH_FAIL=claim
run_once
check_status 0 "$STATUS"
check_grep "unclaim failed for nywleswoey/automation#17, leaving the label on a closed issue" "$OUT"
check_grep "closed out nywleswoey/automation#17: pull request #201 merged" "$OUT"
check_grep "unclaim failed for nywleswoey/automation#44, leaving the label on a closed issue" "$OUT"
check_no_grep "closed out nywleswoey/automation#44" "$OUT"
check_grep "pass end dispatches=0 skips=5" "$OUT"
# The retry is an unclaim and never a second close: #17 is closed once, by the
# close-out that found it open.
check "a closed issue is never closed twice" \
  test "$(grep -cF 'gh-axi issue close 17 --repo nywleswoey/automation' "$STUB_CALLS")" -eq 1

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
