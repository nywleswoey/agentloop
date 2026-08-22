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
  export STUB_PRS=none STUB_THREADS=eligible STUB_MERGED=none
  unset AGENT_LOOP_LOG_MAX_BYTES STUB_GH_FAIL STUB_ORCA_FAIL STUB_GIT_FAIL
  CONFIG="$WORK/config.json"
  LOG="$WORK/agent-loop.log"
  LOCK="$WORK/agent-loop.pid"
  write_config "nywleswoey/automation" "repo-aaa"
}

# write_config <github-full-name> <orca-repo-id> [poll-interval-seconds] [max-workers]
write_config() {
  cat > "$CONFIG" <<JSON
{
  "pollIntervalSeconds": ${3:-300},
  "maxWorkers": ${4:-3},
  "seenListPath": "$WORK/seen.jsonl",
  "logPath": "$LOG",
  "labels": { "ready": "ready-for-agent", "claimed": "agent-in-progress" },
  "projects": [
    { "github": "$1", "orcaRepoId": "$2" }
  ]
}
JSON
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
check_grep 'gh-axi api POST /graphql --field query={ repository(owner: "nywleswoey", name: "automation") { issues(labels: ["ready-for-agent"], states: OPEN, first: 100)' "$STUB_CALLS"
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
# Two live loop workers, one of them an PR worker: the budget is one pool, so
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

# --- pr phase ------------------------------------------------------------------

# One pass over a fixture where every branch state in the claim table is
# represented at once, so the phase is asserted as a whole rather than one
# hand-picked case at a time. maxWorkers is raised out of the way — the budget
# has its own case below.
setup "the PR phase dispatches, reuses or skips by who holds the source branch"
write_config "nywleswoey/automation" "repo-aaa" 300 9
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
run_once
check_status 0 "$STATUS"

# 101 — nobody holds pr-free: a fresh worktree, checked out at the PR's own
# head branch. The PR title slugs onto the directory name, which is the
# worktree's alone — the branch is the PR's and does not change.
check_grep "orca worktree create --repo id:repo-aaa --name agent-loop-pr-101-agent-loop-pr-phase --no-parent --base-branch pr-free --agent claude --prompt " "$STUB_CALLS"
check_grep "dispatched pr nywleswoey/automation#101 (2 eligible threads) -> worktree repo-aaa::/tmp/stub/automation/agent-loop-pr-101" "$OUT"

# 102 — a loop worker is working on pr-live.
check_grep "pr nywleswoey/automation#102 skipped: branch pr-live held by a live worker (/tmp/stub/automation/agent-loop-pr-13)" "$OUT"

# 103 — a finished loop worktree holds pr-done: a new terminal in it, never a
# second checkout of the branch.
check_grep "orca terminal create --worktree path:/tmp/stub/automation/agent-loop-pr-14 --command claude --json" "$STUB_CALLS"
check_grep "dispatched pr nywleswoey/automation#103 (2 eligible threads) -> terminal term_stub_0001 in /tmp/stub/automation/agent-loop-pr-14" "$OUT"

# 104 — my own clean checkout of my-branch is reused in place.
check_grep "orca terminal create --worktree path:/tmp/stub/automation/my-own-checkout --command claude --json" "$STUB_CALLS"
check_grep "dispatched pr nywleswoey/automation#104 (2 eligible threads) -> terminal term_stub_0001 in /tmp/stub/automation/my-own-checkout" "$OUT"

# 105 — every thread on it is resolved, an individual note, or one I have spoken
# in, so there is nothing to dispatch a worker at.
check_grep "pr nywleswoey/automation#105 skipped: no eligible threads" "$OUT"

# 106 — a worker parked waiting for my confirmation still holds pr-waiting.
check_grep "pr nywleswoey/automation#106 skipped: branch pr-waiting held by a live worker (/tmp/stub/automation/agent-loop-pr-15)" "$OUT"

# 107 — a clean checkout Orca does not manage at all is still reused in place.
check_grep "orca terminal create --worktree path:/Users/stub/dev/automation-hotfix --command claude --json" "$STUB_CALLS"

# 108 — a loop worktree Orca has lost is not guessed at.
check_grep "pr nywleswoey/automation#108 skipped: could not determine who holds branch pr-lost" "$OUT"

# 900 lives in a repository the config does not list.
check_no_grep "#900" "$OUT"
check_no_grep "pullRequest(number: 900)" "$STUB_CALLS"

# Reuse never cuts a second checkout of a branch that is already out.
check "exactly one worktree was created" test "$(grep -cF 'worktree create' "$STUB_CALLS")" -eq 1
check "three terminals were created" test "$(grep -cF 'orca terminal create' "$STUB_CALLS")" -eq 3
# The line is sent only after the reused terminal has finished booting.
check_grep "orca terminal wait --terminal term_stub_0001 --for tui-idle --timeout-ms 60000 --json" "$STUB_CALLS"
check "each reused terminal was sent one line" test "$(grep -cF 'orca terminal send --terminal term_stub_0001' "$STUB_CALLS")" -eq 3
# `terminal send` writes raw to the pty, so every newline in its text is a press
# of Enter — the brief goes to a file and the terminal is sent one line.
check_grep "orca terminal send --terminal term_stub_0001 --text Read $WORK/agent-loop-pr-103-prompt.md and do exactly what it says. --enter --json" "$STUB_CALLS"
check "the brief was written for the reused worktree" test -s "$WORK/agent-loop-pr-103-prompt.md"
check_grep "Triage the review threads on pull request https://github.com/nywleswoey/automation/pull/103" "$WORK/agent-loop-pr-103-prompt.md"
# The prompt carries the PR, its branch, and the write-back script that is the
# only thing allowed to write to GitHub.
check_grep "https://github.com/nywleswoey/automation/pull/101" "$STUB_CALLS"
check_grep "pr-writeback.sh\" --plan \"$WORK/agent-loop-pr-101-plan.json\" --seen-list \"$WORK/seen.jsonl\"" "$STUB_CALLS"
# The daemon itself writes nothing to any PR — it dispatches and walks away.
check_no_grep "addPullRequestReviewThreadReply" "$STUB_CALLS"
check_no_grep "resolveReviewThread" "$STUB_CALLS"

# agent-loop-pr-14 was reused a moment ago, so the sweep must leave it alone
# even though the pass's snapshot still shows its old agent as finished.
check_grep "sweep skipped /tmp/stub/automation/agent-loop-pr-14: a worker was dispatched into it this pass" "$OUT"
check_no_grep "swept /tmp/stub/automation/agent-loop-pr-14" "$OUT"
check_grep "pass end dispatches=4 skips=4 sweeps=0" "$OUT"

setup "a PR whose branch is held by a dirty foreign worktree is skipped and logged"
write_config "nywleswoey/automation" "repo-aaa" 300 9
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
export STUB_DIRTY="/tmp/stub/automation/my-own-checkout"
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#104 skipped: branch my-branch held by a worktree with uncommitted changes (/tmp/stub/automation/my-own-checkout)" "$OUT"
check_no_grep "orca terminal create --worktree path:/tmp/stub/automation/my-own-checkout" "$STUB_CALLS"
check_grep "pass end dispatches=3 skips=5 sweeps=0" "$OUT"

setup "a PR whose every thread already has a note from me is not dispatched"
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
export STUB_THREADS=105
write_config "nywleswoey/automation" "repo-aaa" 300 9
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#101 skipped: no eligible threads" "$OUT"
check_no_grep "worktree create" "$STUB_CALLS"
check_no_grep "terminal create" "$STUB_CALLS"
check_grep "pass end dispatches=0 skips=8 sweeps=1" "$OUT"

setup "PR dispatch spends the same worker budget as the issue phase"
# orca-ps-branches carries two live loop workers, so maxWorkers 3 leaves exactly
# one slot for the four PRs that would otherwise be dispatched.
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
run_once
check_status 0 "$STATUS"
check "exactly one PR worker was dispatched" test "$(grep -cF 'dispatched pr ' "$OUT")" -eq 1
check_grep "pr nywleswoey/automation#103 deferred: worker budget full (3/3)" "$OUT"
check_grep "pr nywleswoey/automation#104 deferred: worker budget full (3/3)" "$OUT"
check_grep "pr nywleswoey/automation#107 deferred: worker budget full (3/3)" "$OUT"

setup "a failed PR query is logged and the pass continues"
export STUB_PRS=branches STUB_GH_FAIL=prs
run_once
check_status 0 "$STATUS"
check_grep "pr query failed" "$OUT"
check_grep "pass end dispatches=0 skips=1 sweeps=1" "$OUT"

setup "a failed thread query is logged and the PR is left alone"
write_config "nywleswoey/automation" "repo-aaa" 300 9
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
export STUB_GH_FAIL=threads
run_once
check_status 0 "$STATUS"
check_grep "thread query failed: nywleswoey/automation#101" "$OUT"
check_no_grep "worktree create" "$STUB_CALLS"

# --- seen-list ------------------------------------------------------------------

# The eligible-thread fixture carries two threads: d...0001, whose newest note is
# 900001, and d...0002, whose newest is 900003. A seen entry matching both is
# what a worker leaves behind after triaging PR 101 and getting no reply.
SEEN_101_CURRENT='{"project":"nywleswoey/automation","pr":101,"thread":"PRRT_thread001","lastCommentId":900001,"verdict":"ANSWER"}
{"project":"nywleswoey/automation","pr":101,"thread":"PRRT_thread002","lastCommentId":900003,"verdict":"ESCALATE"}'

setup "a thread with a matching seen entry and an unchanged newest note is filtered out"
write_config "nywleswoey/automation" "repo-aaa" 300 9
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
printf '%s\n' "$SEEN_101_CURRENT" > "$WORK/seen.jsonl"
run_once
check_status 0 "$STATUS"
check_grep "pr nywleswoey/automation#101 skipped: no eligible threads" "$OUT"
check_no_grep "agent-loop-pr-101" "$STUB_CALLS"
# The entries name PR 101 alone, so every other PR is dispatched as before.
check_grep "dispatched pr nywleswoey/automation#103 (2 eligible threads)" "$OUT"

setup "a newer note on the thread makes it eligible again"
write_config "nywleswoey/automation" "repo-aaa" 300 9
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
# Both entries name a note that is no longer the newest one on the thread.
cat > "$WORK/seen.jsonl" <<'JSON'
{"project":"nywleswoey/automation","pr":101,"thread":"PRRT_thread001","lastCommentId":900000,"verdict":"ANSWER"}
{"project":"nywleswoey/automation","pr":101,"thread":"PRRT_thread002","lastCommentId":900002,"verdict":"ESCALATE"}
JSON
run_once
check_status 0 "$STATUS"
check_grep "dispatched pr nywleswoey/automation#101 (2 eligible threads)" "$OUT"

setup "a seen entry for another pull request does not filter this one"
write_config "nywleswoey/automation" "repo-aaa" 300 9
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
printf '%s\n' "${SEEN_101_CURRENT//\"pr\":101/\"pr\":999}" > "$WORK/seen.jsonl"
run_once
check_status 0 "$STATUS"
check_grep "dispatched pr nywleswoey/automation#101 (2 eligible threads)" "$OUT"

setup "a missing seen-list filters nothing and does not stop the pass"
write_config "nywleswoey/automation" "repo-aaa" 300 9
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
check "no seen-list on disk" test ! -f "$WORK/seen.jsonl"
run_once
check_status 0 "$STATUS"
check_grep "dispatched pr nywleswoey/automation#101 (2 eligible threads)" "$OUT"

setup "an unreadable seen-list filters nothing and does not stop the pass"
write_config "nywleswoey/automation" "repo-aaa" 300 9
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
printf 'not json at all\n' > "$WORK/seen.jsonl"
run_once
check_status 0 "$STATUS"
check_grep "seen-list unreadable, filtering nothing this pass: $WORK/seen.jsonl" "$OUT"
check_grep "dispatched pr nywleswoey/automation#101 (2 eligible threads)" "$OUT"

setup "the daemon never writes the seen-list itself"
write_config "nywleswoey/automation" "repo-aaa" 300 9
export STUB_PRS=branches STUB_WORKTREES=branches STUB_ORCA_PS=branches
run_once
check_status 0 "$STATUS"
check_grep "dispatched pr nywleswoey/automation#101" "$OUT"
# Only a worker whose confirmation prompt I have answered writes an entry, and
# the write-back script is the only thing that writes one.
check "the loop created no seen-list" test ! -f "$WORK/seen.jsonl"

setup "no open PRs means no PR traffic"
run_once
check_status 0 "$STATUS"
check_grep 'gh-axi api POST /graphql --field query={ search(query: "is:pr is:open author:nywleswoey sort:updated-desc"' "$STUB_CALLS"
check_no_grep "reviewThreads" "$STUB_CALLS"
check_no_grep "dispatched mr" "$OUT"
check_grep "pass end dispatches=0 skips=0 sweeps=1" "$OUT"

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
check_grep 'gh-axi api POST /graphql --field query={ search(query: "is:pr is:merged author:nywleswoey sort:updated-desc"' "$STUB_CALLS"
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
# One open pull request, from the very branch the close-out phase reads issues
# out of: it must never reach the phase, because the phase asks GitHub for
# `state=merged` and nothing else.
export STUB_PRS=openissue STUB_WORKTREES=branches STUB_ORCA_PS=branches
run_once
check_status 0 "$STATUS"
check_grep "dispatched pr nywleswoey/automation#301" "$OUT"
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

# --- result ------------------------------------------------------------------

report
