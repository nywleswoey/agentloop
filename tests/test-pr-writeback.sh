#!/bin/bash
#
# test-pr-writeback.sh
#
# Runs the real pr-writeback.sh against the stub CLIs in tests/bin and asserts
# on what it printed and on the argv it handed to `git` and `gh-axi`. The stub
# directory is the only seam: no function inside pr-writeback.sh is reached into
# directly, because the whole point of the script is which commands it does and
# does not issue.
#
# Usage:
#   ./tests/test-pr-writeback.sh

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
SCRIPT="$ROOT/pr-writeback.sh"
FIXTURES="$ROOT/tests/fixtures"
PATH="$ROOT/tests/bin:$PATH"
export PATH STUB_FIXTURES="$FIXTURES"

# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/mr-writeback-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

setup() {
  CURRENT="$1"
  echo "== $CURRENT"
  WORK="$(mktemp -d "$SCRATCH/case.XXXXXX")"
  STUB_STATE="$WORK/state"
  STUB_CALLS="$WORK/calls.log"
  export STUB_STATE STUB_CALLS
  mkdir -p "$STUB_STATE"
  : > "$STUB_CALLS"
  export STUB_DIRTY="" STUB_REVLIST="" STUB_CONFLICT="" STUB_UNKNOWN_SHA=""
  export STUB_NOT_ANCESTOR=""
  unset STUB_PUSH_FAIL STUB_GH_FAIL
  PLAN="$WORK/plan.json"
}

# run [extra args...] — captures stdout+stderr in $OUT, status in $STATUS
run() {
  OUT="$WORK/out.log"
  "$SCRIPT" --plan "$PLAN" --repo "$WORK" "$@" > "$OUT" 2>&1
  STATUS=$?
}

# A plan with one FIX, one REFUSE, one ANSWER and one ESCALATE. Confirmation is
# per test — `write_plan <fix-confirmed> <refuse-confirmed>`.
write_plan() {
  cat > "$PLAN" <<JSON
{
  "repo": "nywleswoey/automation",
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "thread": "PRRT_dfix", "verdict": "FIX", "commit": "c1aaaaaa", "lastCommentId": 1001,
      "summary": "Passes a radix to parseInt.", "confirmed": $1 },
    { "thread": "PRRT_drefuse", "verdict": "REFUSE", "lastCommentId": 1002,
      "reply": "**Disagree** — the guard is three lines up.", "confirmed": $2 },
    { "thread": "PRRT_danswer", "verdict": "ANSWER", "lastCommentId": 1003, "confirmed": false },
    { "thread": "PRRT_descalate", "verdict": "ESCALATE", "lastCommentId": 1004, "confirmed": false }
  ]
}
JSON
}

# --- confirming nothing --------------------------------------------------------

setup "confirming nothing leaves the pull request completely untouched"
write_plan false false
export STUB_REVLIST="c1aaaaaa"
run
check_status 0 "$STATUS"
check_grep "nothing confirmed — pull request #517 is left exactly as it was" "$OUT"
check "no command was issued at all" test "$(wc -l < "$STUB_CALLS" | tr -d ' ')" -eq 0

# --- confirming everything -----------------------------------------------------

setup "confirming everything pushes once and resolves only the fix"
write_plan true true
# The branch is exactly the confirmed fix, so there is nothing to replay.
export STUB_REVLIST="c1aaaaaa"
run
check_status 0 "$STATUS"
check_grep "git -C $WORK push origin HEAD:my-branch" "$STUB_CALLS"
check "exactly one push" test "$(grep -cF ' push origin' "$STUB_CALLS")" -eq 1
check "the branch was not rebuilt" test "$(grep -cF ' reset --hard' "$STUB_CALLS")" -eq 0
check "nothing was cherry-picked" test "$(grep -cF ' cherry-pick' "$STUB_CALLS")" -eq 0
# The reply cites the sha that is actually on the branch.
# The reply text travels as a GraphQL variable passed via --field.
check_grep 'gh-axi api POST graphql --field query=mutation($thread: ID!, $body: String!) {' "$STUB_CALLS"
check_grep '--field thread=PRRT_dfix --field body=Fixed in c1aaaaaa.' "$STUB_CALLS"
check_grep '--field thread=PRRT_drefuse --field body=**Disagree** — the guard is three lines up.' "$STUB_CALLS"
# Only a FIX resolves — the reviewer keeps the last word on a disagreement.
check_grep '--field thread=PRRT_dfix' "$STUB_CALLS"
check "exactly one thread was resolved" test "$(grep -cF 'resolveReviewThread(' "$STUB_CALLS")" -eq 1
# Scoped to the resolve mutation: the refusal above does post a reply naming
# this same thread, so a bare search for the thread id cannot tell "replied to"
# from "resolved" and would contradict that assertion.
check "the refused thread was not resolved" test "$(grep -F 'resolveReviewThread(' "$STUB_CALLS" | grep -cF 'thread=PRRT_drefuse')" -eq 0
# An ANSWER and an ESCALATE are reported and nothing else.
check_no_grep "PRRT_danswer" "$STUB_CALLS"
check_no_grep "PRRT_descalate" "$STUB_CALLS"
check_grep "| PRRT_danswer | ANSWER | — | reported only, nothing written |" "$OUT"
check_grep "| PRRT_descalate | ESCALATE | — | reported only, nothing written |" "$OUT"
check_grep "| PRRT_dfix | FIX | c1aaaaaa | replied and resolved |" "$OUT"
check_grep "| PRRT_drefuse | REFUSE | — | replied, left unresolved |" "$OUT"
# The history a reviewer has seen is never rewritten.
check_no_grep "--force" "$STUB_CALLS"
check_no_grep "git -C $WORK rebase" "$STUB_CALLS"

# --- partial confirmation ------------------------------------------------------

setup "a partial confirmation pushes and resolves only the confirmed subset"
cat > "$PLAN" <<JSON
{
  "repo": "nywleswoey/automation",
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "thread": "PRRT_dkeep", "verdict": "FIX", "commit": "c1aaaaaa",
      "summary": "Passes a radix to parseInt.", "confirmed": true },
    { "thread": "PRRT_ddrop", "verdict": "FIX", "commit": "c2bbbbbb",
      "summary": "Renames the flag.", "confirmed": false },
    { "thread": "PRRT_drefuse", "verdict": "REFUSE",
      "reply": "**Disagree** — already handled.", "confirmed": false }
  ]
}
JSON
export STUB_REVLIST="c1aaaaaa c2bbbbbb"
run
check_status 0 "$STATUS"
# The branch is rebuilt from base with only the confirmed fix on it.
check_grep "git -C $WORK reset --hard base000" "$STUB_CALLS"
check_grep "git -C $WORK cherry-pick c1aaaaaa" "$STUB_CALLS"
check_no_grep "cherry-pick c2bbbbbb" "$STUB_CALLS"
check "exactly one push" test "$(grep -cF ' push origin' "$STUB_CALLS")" -eq 1
# The reply cites the sha as it landed, not the sha before the rebuild.
check_grep '--field thread=PRRT_dkeep --field body=Fixed in picked1.' "$STUB_CALLS"
check_grep "| PRRT_dkeep | FIX | picked1 | replied and resolved |" "$OUT"
check "exactly one thread was resolved" test "$(grep -cF 'resolveReviewThread(' "$STUB_CALLS")" -eq 1
check_grep '--field thread=PRRT_dkeep' "$STUB_CALLS"
# The rejected fix leaves no debris and comes back as an escalation.
check_no_grep "PRRT_ddrop" "$STUB_CALLS"
check_grep "| PRRT_ddrop | ESCALATE | — | rejected, commit dropped |" "$OUT"
# The declined disagreement is not spoken either.
check_no_grep "PRRT_drefuse" "$STUB_CALLS"
check_grep "| PRRT_drefuse | REFUSE | — | rejected, nothing written |" "$OUT"
check_no_grep "--force" "$STUB_CALLS"
check_no_grep "git -C $WORK rebase" "$STUB_CALLS"

# --- a confirmed refusal on its own ---------------------------------------------

setup "a confirmed refusal replies without pushing and never resolves"
write_plan false true
export STUB_REVLIST="c1aaaaaa"
run
check_status 0 "$STATUS"
check_grep "no fix confirmed, nothing pushed" "$OUT"
check_no_grep "push origin" "$STUB_CALLS"
check_grep '--field thread=PRRT_drefuse --field body=' "$STUB_CALLS"
check_no_grep "resolveReviewThread(" "$STUB_CALLS"
check_grep "| PRRT_dfix | ESCALATE | — | rejected, commit dropped |" "$OUT"

# A refusal is words, not commits: whatever state the worktree happens to be in
# is none of its business.
setup "a confirmed refusal is posted even when the worktree is dirty"
write_plan false true
export STUB_REVLIST="c1aaaaaa" STUB_DIRTY="$WORK"
run
check_status 0 "$STATUS"
check_grep '--field thread=PRRT_drefuse --field body=' "$STUB_CALLS"
check_no_grep "reset --hard" "$STUB_CALLS"
check_no_grep "push origin" "$STUB_CALLS"

# --- a fix that will not replay --------------------------------------------------

setup "a confirmed fix that will not replay is dropped and escalated"
cat > "$PLAN" <<JSON
{
  "repo": "nywleswoey/automation",
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "thread": "PRRT_dclash", "verdict": "FIX", "commit": "c1aaaaaa",
      "summary": "Passes a radix.", "confirmed": true },
    { "thread": "PRRT_dkeep", "verdict": "FIX", "commit": "c2bbbbbb",
      "summary": "Renames the flag.", "confirmed": true }
  ]
}
JSON
# The branch carries a third, unconfirmed commit, so the rebuild path runs.
export STUB_REVLIST="c1aaaaaa c2bbbbbb c3cccccc"
export STUB_CONFLICT="c1aaaaaa"
run
check_status 0 "$STATUS"
check_grep "1 confirmed fix(es) would not replay and became escalations" "$OUT"
check_grep "git -C $WORK cherry-pick --abort" "$STUB_CALLS"
check_grep "| PRRT_dclash | ESCALATE | c1aaaaaa | would not replay, commit dropped |" "$OUT"
check_no_grep "PRRT_dclash" "$STUB_CALLS"
# The fix that did replay still lands.
check_grep '--field thread=PRRT_dkeep --field body=Fixed in picked1.' "$STUB_CALLS"
check_grep "| PRRT_dkeep | FIX | picked1 | replied and resolved |" "$OUT"
check "exactly one push" test "$(grep -cF ' push origin' "$STUB_CALLS")" -eq 1

# --- a failed push ---------------------------------------------------------------

setup "a failed push writes nothing to GitHub"
write_plan true true
export STUB_REVLIST="c1aaaaaa" STUB_PUSH_FAIL=1
run
check_status nonzero "$STATUS"
check_grep "push to my-branch failed; nothing was written to GitHub" "$OUT"
check_no_grep "addPullRequestReviewThreadReply(" "$STUB_CALLS"
check_no_grep "resolveReviewThread(" "$STUB_CALLS"

setup "a failed push after a rebuild puts the branch back where it was"
cat > "$PLAN" <<'JSON'
{
  "repo": "nywleswoey/automation",
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "thread": "PRRT_dkeep", "verdict": "FIX", "commit": "c1aaaaaa",
      "summary": "Passes a radix.", "confirmed": true },
    { "thread": "PRRT_ddrop", "verdict": "FIX", "commit": "c2bbbbbb",
      "summary": "Renames the flag.", "confirmed": false }
  ]
}
JSON
export STUB_REVLIST="c1aaaaaa c2bbbbbb" STUB_PUSH_FAIL=1
run
check_status nonzero "$STATUS"
# The rejected commit was already dropped by the reset, so a push that fails
# must hand the branch back rather than leave the work reachable only by reflog.
check_grep "branch restored to headsha0" "$OUT"
check_grep "git -C $WORK reset --hard headsha0" "$STUB_CALLS"
check_no_grep "gh-axi api" "$STUB_CALLS"

# --- the seen-list -----------------------------------------------------------------

setup "a silent verdict is recorded and a confirmed one is not"
write_plan true true
export STUB_REVLIST="c1aaaaaa"
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
check_grep '{"project":"nywleswoey/automation","pr":517,"thread":"PRRT_danswer","lastCommentId":1003,"verdict":"ANSWER"}' "$WORK/seen.jsonl"
check_grep '{"project":"nywleswoey/automation","pr":517,"thread":"PRRT_descalate","lastCommentId":1004,"verdict":"ESCALATE"}' "$WORK/seen.jsonl"
# Both of these wrote into their thread under my identity, so the "no note
# authored by me" rule already makes them ineligible next pass.
check_no_grep '"thread":"PRRT_dfix"' "$WORK/seen.jsonl"
check_no_grep '"thread":"PRRT_drefuse"' "$WORK/seen.jsonl"
check "exactly two entries" test "$(wc -l < "$WORK/seen.jsonl" | tr -d ' ')" -eq 2

setup "a proposal I declined is recorded as DECLINED"
write_plan false false
export STUB_REVLIST="c1aaaaaa"
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
check_grep '{"project":"nywleswoey/automation","pr":517,"thread":"PRRT_dfix","lastCommentId":1001,"verdict":"DECLINED"}' "$WORK/seen.jsonl"
check_grep '{"project":"nywleswoey/automation","pr":517,"thread":"PRRT_drefuse","lastCommentId":1002,"verdict":"DECLINED"}' "$WORK/seen.jsonl"
check "every thread was recorded" test "$(wc -l < "$WORK/seen.jsonl" | tr -d ' ')" -eq 4
# Confirming nothing still costs the pull request nothing.
check_grep "nothing confirmed — pull request #517 is left exactly as it was" "$OUT"
check "no command was issued at all" test "$(wc -l < "$STUB_CALLS" | tr -d ' ')" -eq 0

setup "the seen-list is only ever appended to"
write_plan false false
export STUB_REVLIST="c1aaaaaa"
printf '{"project":"other/repo","pr":1,"thread":"PRRT_dold","lastCommentId":1,"verdict":"ANSWER"}\n' \
  > "$WORK/seen.jsonl"
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
check_grep '"thread":"PRRT_dold"' "$WORK/seen.jsonl"
check "the existing entry survived" test "$(wc -l < "$WORK/seen.jsonl" | tr -d ' ')" -eq 5

setup "no seen-list path means nothing is recorded"
write_plan false false
export STUB_REVLIST="c1aaaaaa"
run
check_status 0 "$STATUS"
check "no seen-list was written" test ! -f "$WORK/seen.jsonl"

setup "a confirmed fix that would not replay is recorded as an escalation"
cat > "$PLAN" <<'JSON'
{
  "repo": "nywleswoey/automation",
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "thread": "PRRT_dclash", "verdict": "FIX", "commit": "c1aaaaaa", "lastCommentId": 2001,
      "summary": "Passes a radix.", "confirmed": true },
    { "thread": "PRRT_dkeep", "verdict": "FIX", "commit": "c2bbbbbb", "lastCommentId": 2002,
      "summary": "Renames the flag.", "confirmed": true }
  ]
}
JSON
export STUB_REVLIST="c1aaaaaa c2bbbbbb c3cccccc" STUB_CONFLICT="c1aaaaaa"
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
# Nothing was written to the thread, so the loop needs the entry to stop
# re-dispatching at it.
check_grep '{"project":"nywleswoey/automation","pr":517,"thread":"PRRT_dclash","lastCommentId":2001,"verdict":"ESCALATE"}' "$WORK/seen.jsonl"
check_no_grep '"thread":"PRRT_dkeep"' "$WORK/seen.jsonl"

setup "a thread with no lastCommentId records nothing and says so"
cat > "$PLAN" <<'JSON'
{
  "repo": "nywleswoey/automation",
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "thread": "PRRT_danswer", "verdict": "ANSWER" },
    { "thread": "PRRT_descalate", "verdict": "ESCALATE", "lastCommentId": 1004 }
  ]
}
JSON
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
check_grep "nothing recorded in the seen-list for thread 0: no lastCommentId" "$OUT"
# An entry with no note to compare against could never match, so the thread it
# names would stay eligible anyway — the line would be noise and nothing else.
check_no_grep '"thread":"PRRT_danswer"' "$WORK/seen.jsonl"
check_grep '"thread":"PRRT_descalate"' "$WORK/seen.jsonl"
check "exactly one entry" test "$(wc -l < "$WORK/seen.jsonl" | tr -d ' ')" -eq 1

# On GitHub `<owner>/<name>` is the whole address — it names the pull request
# the mutations write to as well as the project the seen-list is keyed on — so a
# plan without one is refused outright rather than run with the recording off.
setup "a plan with no repo refuses the whole run"
cat > "$PLAN" <<'JSON'
{
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "thread": "PRRT_danswer", "verdict": "ANSWER", "lastCommentId": 1003 }
  ]
}
JSON
run --seen-list "$WORK/seen.jsonl"
check_status nonzero "$STATUS"
check_grep "plan is missing repo" "$OUT"
check "no seen-list was written" test ! -f "$WORK/seen.jsonl"
check "no command was issued at all" test "$(wc -l < "$STUB_CALLS" | tr -d ' ')" -eq 0

# --- guards ----------------------------------------------------------------------

setup "a dirty worktree refuses the whole run"
write_plan true true
export STUB_REVLIST="c1aaaaaa" STUB_DIRTY="$WORK"
run
check_status nonzero "$STATUS"
check_grep "worktree has uncommitted changes" "$OUT"
check_no_grep "reset --hard" "$STUB_CALLS"
check_no_grep "push origin" "$STUB_CALLS"
check_no_grep "gh-axi api" "$STUB_CALLS"

setup "a baseSha that is not behind HEAD refuses the whole run"
write_plan true true
export STUB_REVLIST="c1aaaaaa" STUB_NOT_ANCESTOR="base000"
run
check_status nonzero "$STATUS"
check_grep "baseSha is not an ancestor of HEAD: base000" "$OUT"
check_no_grep "reset --hard" "$STUB_CALLS"
check_no_grep "gh-axi api" "$STUB_CALLS"

setup "a confirmed commit that is not on the branch refuses the whole run"
write_plan true true
export STUB_REVLIST="c1aaaaaa" STUB_NOT_ANCESTOR="c1aaaaaa"
run
check_status nonzero "$STATUS"
check_grep "confirmed commit is not on this branch: c1aaaaaa" "$OUT"
check_no_grep "gh-axi api" "$STUB_CALLS"

setup "a confirmed FIX with no commit refuses the whole run"
cat > "$PLAN" <<'JSON'
{
  "repo": "nywleswoey/automation",
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "thread": "PRRT_dfix", "verdict": "FIX", "summary": "No sha here.", "confirmed": true }
  ]
}
JSON
run
check_status nonzero "$STATUS"
check_grep "confirmed thread is incomplete: PRRT_dfix" "$OUT"
check "no command was issued at all" test "$(wc -l < "$STUB_CALLS" | tr -d ' ')" -eq 0

# The plan is hand-edited, so the guard has to survive a second entry being the
# broken one — a check that stops at the first thread would wave this through
# and post a reply with no summary behind it.
setup "a later confirmed FIX with no summary refuses the whole run"
cat > "$PLAN" <<'JSON'
{
  "repo": "nywleswoey/automation",
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "thread": "PRRT_dok", "verdict": "FIX", "commit": "c1aaaaaa",
      "summary": "Passes a radix.", "confirmed": true },
    { "thread": "PRRT_dbad", "verdict": "FIX", "commit": "c2bbbbbb", "confirmed": true }
  ]
}
JSON
export STUB_REVLIST="c1aaaaaa c2bbbbbb"
run
check_status nonzero "$STATUS"
check_grep "confirmed thread is incomplete: PRRT_dbad" "$OUT"
check_no_grep "push origin" "$STUB_CALLS"
check_no_grep "gh-axi api" "$STUB_CALLS"

setup "a confirmed thread with an unknown verdict refuses the whole run"
cat > "$PLAN" <<'JSON'
{
  "repo": "nywleswoey/automation",
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "thread": "PRRT_dweird", "verdict": "MAYBE", "confirmed": true }
  ]
}
JSON
run
check_status nonzero "$STATUS"
check_grep "confirmed thread is incomplete: PRRT_dweird" "$OUT"
check_no_grep "gh-axi api" "$STUB_CALLS"

setup "a malformed plan refuses the whole run"
printf '{ not json' > "$PLAN"
run
check_status nonzero "$STATUS"
check_grep "plan is not valid JSON" "$OUT"

# --- result ------------------------------------------------------------------

report
