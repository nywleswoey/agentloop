#!/bin/bash
#
# test-mr-writeback.sh
#
# Runs the real mr-writeback.sh against the stub CLIs in tests/bin and asserts
# on what it printed and on the argv it handed to `git` and `glab-axi`. The stub
# directory is the only seam: no function inside mr-writeback.sh is reached into
# directly, because the whole point of the script is which commands it does and
# does not issue.
#
# Usage:
#   ./tests/test-mr-writeback.sh

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
SCRIPT="$ROOT/mr-writeback.sh"
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
  unset STUB_PUSH_FAIL STUB_GLAB_FAIL
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
  "project": "selwyn_yeow/automation",
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "discussion": "dfix", "verdict": "FIX", "commit": "c1aaaaaa", "lastNoteId": 1001,
      "summary": "Passes a radix to parseInt.", "confirmed": $1 },
    { "discussion": "drefuse", "verdict": "REFUSE", "lastNoteId": 1002,
      "reply": "**Disagree** — the guard is three lines up.", "confirmed": $2 },
    { "discussion": "danswer", "verdict": "ANSWER", "lastNoteId": 1003, "confirmed": false },
    { "discussion": "descalate", "verdict": "ESCALATE", "lastNoteId": 1004, "confirmed": false }
  ]
}
JSON
}

# --- confirming nothing --------------------------------------------------------

setup "confirming nothing leaves the merge request completely untouched"
write_plan false false
export STUB_REVLIST="c1aaaaaa"
run
check_status 0 "$STATUS"
check_grep "nothing confirmed — merge request 517 is left exactly as it was" "$OUT"
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
check_grep "glab-axi api POST projects/57981/merge_requests/517/discussions/dfix/notes --raw-field body=Fixed in c1aaaaaa." "$STUB_CALLS"
check_grep "glab-axi api POST projects/57981/merge_requests/517/discussions/drefuse/notes --raw-field body=**Disagree** — the guard is three lines up." "$STUB_CALLS"
# Only a FIX resolves — the reviewer keeps the last word on a disagreement.
check_grep "glab-axi api PUT projects/57981/merge_requests/517/discussions/dfix --field resolved=true" "$STUB_CALLS"
check "exactly one thread was resolved" test "$(grep -cF -- '--field resolved=true' "$STUB_CALLS")" -eq 1
check_no_grep "discussions/drefuse --field resolved=true" "$STUB_CALLS"
# An ANSWER and an ESCALATE are reported and nothing else.
check_no_grep "discussions/danswer" "$STUB_CALLS"
check_no_grep "discussions/descalate" "$STUB_CALLS"
check_grep "| danswer | ANSWER | — | reported only, nothing written |" "$OUT"
check_grep "| descalate | ESCALATE | — | reported only, nothing written |" "$OUT"
check_grep "| dfix | FIX | c1aaaaaa | replied and resolved |" "$OUT"
check_grep "| drefuse | REFUSE | — | replied, left unresolved |" "$OUT"
# The history a reviewer has seen is never rewritten.
check_no_grep "--force" "$STUB_CALLS"
check_no_grep "git -C $WORK rebase" "$STUB_CALLS"

# --- partial confirmation ------------------------------------------------------

setup "a partial confirmation pushes and resolves only the confirmed subset"
cat > "$PLAN" <<JSON
{
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "discussion": "dkeep", "verdict": "FIX", "commit": "c1aaaaaa",
      "summary": "Passes a radix to parseInt.", "confirmed": true },
    { "discussion": "ddrop", "verdict": "FIX", "commit": "c2bbbbbb",
      "summary": "Renames the flag.", "confirmed": false },
    { "discussion": "drefuse", "verdict": "REFUSE",
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
check_grep "discussions/dkeep/notes --raw-field body=Fixed in picked1." "$STUB_CALLS"
check_grep "| dkeep | FIX | picked1 | replied and resolved |" "$OUT"
check "exactly one thread was resolved" test "$(grep -cF -- '--field resolved=true' "$STUB_CALLS")" -eq 1
check_grep "discussions/dkeep --field resolved=true" "$STUB_CALLS"
# The rejected fix leaves no debris and comes back as an escalation.
check_no_grep "discussions/ddrop" "$STUB_CALLS"
check_grep "| ddrop | ESCALATE | — | rejected, commit dropped |" "$OUT"
# The declined disagreement is not spoken either.
check_no_grep "discussions/drefuse" "$STUB_CALLS"
check_grep "| drefuse | REFUSE | — | rejected, nothing written |" "$OUT"
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
check_grep "discussions/drefuse/notes" "$STUB_CALLS"
check_no_grep "--field resolved=true" "$STUB_CALLS"
check_grep "| dfix | ESCALATE | — | rejected, commit dropped |" "$OUT"

# A refusal is words, not commits: whatever state the worktree happens to be in
# is none of its business.
setup "a confirmed refusal is posted even when the worktree is dirty"
write_plan false true
export STUB_REVLIST="c1aaaaaa" STUB_DIRTY="$WORK"
run
check_status 0 "$STATUS"
check_grep "discussions/drefuse/notes" "$STUB_CALLS"
check_no_grep "reset --hard" "$STUB_CALLS"
check_no_grep "push origin" "$STUB_CALLS"

# --- a fix that will not replay --------------------------------------------------

setup "a confirmed fix that will not replay is dropped and escalated"
cat > "$PLAN" <<JSON
{
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "discussion": "dclash", "verdict": "FIX", "commit": "c1aaaaaa",
      "summary": "Passes a radix.", "confirmed": true },
    { "discussion": "dkeep", "verdict": "FIX", "commit": "c2bbbbbb",
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
check_grep "| dclash | ESCALATE | c1aaaaaa | would not replay, commit dropped |" "$OUT"
check_no_grep "discussions/dclash" "$STUB_CALLS"
# The fix that did replay still lands.
check_grep "| dkeep | FIX | picked1 | replied and resolved |" "$OUT"
check "exactly one push" test "$(grep -cF ' push origin' "$STUB_CALLS")" -eq 1

# --- a failed push ---------------------------------------------------------------

setup "a failed push writes nothing to GitLab"
write_plan true true
export STUB_REVLIST="c1aaaaaa" STUB_PUSH_FAIL=1
run
check_status nonzero "$STATUS"
check_grep "push to my-branch failed; nothing was written to GitLab" "$OUT"
check_no_grep "glab-axi api POST" "$STUB_CALLS"
check_no_grep "resolved=true" "$STUB_CALLS"

setup "a failed push after a rebuild puts the branch back where it was"
cat > "$PLAN" <<'JSON'
{
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "discussion": "dkeep", "verdict": "FIX", "commit": "c1aaaaaa",
      "summary": "Passes a radix.", "confirmed": true },
    { "discussion": "ddrop", "verdict": "FIX", "commit": "c2bbbbbb",
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
check_no_grep "glab-axi api" "$STUB_CALLS"

# --- the seen-list -----------------------------------------------------------------

setup "a silent verdict is recorded and a confirmed one is not"
write_plan true true
export STUB_REVLIST="c1aaaaaa"
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
check_grep '{"project":"selwyn_yeow/automation","mr":517,"discussion":"danswer","lastNoteId":1003,"verdict":"ANSWER"}' "$WORK/seen.jsonl"
check_grep '{"project":"selwyn_yeow/automation","mr":517,"discussion":"descalate","lastNoteId":1004,"verdict":"ESCALATE"}' "$WORK/seen.jsonl"
# Both of these wrote into their thread under my identity, so the "no note
# authored by me" rule already makes them ineligible next pass.
check_no_grep '"discussion":"dfix"' "$WORK/seen.jsonl"
check_no_grep '"discussion":"drefuse"' "$WORK/seen.jsonl"
check "exactly two entries" test "$(wc -l < "$WORK/seen.jsonl" | tr -d ' ')" -eq 2

setup "a proposal I declined is recorded as DECLINED"
write_plan false false
export STUB_REVLIST="c1aaaaaa"
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
check_grep '{"project":"selwyn_yeow/automation","mr":517,"discussion":"dfix","lastNoteId":1001,"verdict":"DECLINED"}' "$WORK/seen.jsonl"
check_grep '{"project":"selwyn_yeow/automation","mr":517,"discussion":"drefuse","lastNoteId":1002,"verdict":"DECLINED"}' "$WORK/seen.jsonl"
check "every thread was recorded" test "$(wc -l < "$WORK/seen.jsonl" | tr -d ' ')" -eq 4
# Confirming nothing still costs the merge request nothing.
check_grep "nothing confirmed — merge request 517 is left exactly as it was" "$OUT"
check "no command was issued at all" test "$(wc -l < "$STUB_CALLS" | tr -d ' ')" -eq 0

setup "the seen-list is only ever appended to"
write_plan false false
export STUB_REVLIST="c1aaaaaa"
printf '{"project":"other/repo","mr":1,"discussion":"dold","lastNoteId":1,"verdict":"ANSWER"}\n' \
  > "$WORK/seen.jsonl"
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
check_grep '"discussion":"dold"' "$WORK/seen.jsonl"
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
  "project": "selwyn_yeow/automation",
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "discussion": "dclash", "verdict": "FIX", "commit": "c1aaaaaa", "lastNoteId": 2001,
      "summary": "Passes a radix.", "confirmed": true },
    { "discussion": "dkeep", "verdict": "FIX", "commit": "c2bbbbbb", "lastNoteId": 2002,
      "summary": "Renames the flag.", "confirmed": true }
  ]
}
JSON
export STUB_REVLIST="c1aaaaaa c2bbbbbb c3cccccc" STUB_CONFLICT="c1aaaaaa"
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
# Nothing was written to the thread, so the loop needs the entry to stop
# re-dispatching at it.
check_grep '{"project":"selwyn_yeow/automation","mr":517,"discussion":"dclash","lastNoteId":2001,"verdict":"ESCALATE"}' "$WORK/seen.jsonl"
check_no_grep '"discussion":"dkeep"' "$WORK/seen.jsonl"

setup "a thread with no lastNoteId records nothing and says so"
cat > "$PLAN" <<'JSON'
{
  "project": "selwyn_yeow/automation",
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "discussion": "danswer", "verdict": "ANSWER" },
    { "discussion": "descalate", "verdict": "ESCALATE", "lastNoteId": 1004 }
  ]
}
JSON
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
check_grep "nothing recorded in the seen-list for thread 0: no lastNoteId" "$OUT"
# An entry with no note to compare against could never match, so the thread it
# names would stay eligible anyway — the line would be noise and nothing else.
check_no_grep '"discussion":"danswer"' "$WORK/seen.jsonl"
check_grep '"discussion":"descalate"' "$WORK/seen.jsonl"
check "exactly one entry" test "$(wc -l < "$WORK/seen.jsonl" | tr -d ' ')" -eq 1

setup "a plan with no project path records nothing and says so"
cat > "$PLAN" <<'JSON'
{
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "discussion": "danswer", "verdict": "ANSWER", "lastNoteId": 1003 }
  ]
}
JSON
run --seen-list "$WORK/seen.jsonl"
check_status 0 "$STATUS"
check_grep "plan has no project path, nothing will be recorded in the seen-list" "$OUT"
check "no seen-list was written" test ! -f "$WORK/seen.jsonl"

# --- guards ----------------------------------------------------------------------

setup "a dirty worktree refuses the whole run"
write_plan true true
export STUB_REVLIST="c1aaaaaa" STUB_DIRTY="$WORK"
run
check_status nonzero "$STATUS"
check_grep "worktree has uncommitted changes" "$OUT"
check_no_grep "reset --hard" "$STUB_CALLS"
check_no_grep "push origin" "$STUB_CALLS"
check_no_grep "glab-axi api" "$STUB_CALLS"

setup "a baseSha that is not behind HEAD refuses the whole run"
write_plan true true
export STUB_REVLIST="c1aaaaaa" STUB_NOT_ANCESTOR="base000"
run
check_status nonzero "$STATUS"
check_grep "baseSha is not an ancestor of HEAD: base000" "$OUT"
check_no_grep "reset --hard" "$STUB_CALLS"
check_no_grep "glab-axi api" "$STUB_CALLS"

setup "a confirmed commit that is not on the branch refuses the whole run"
write_plan true true
export STUB_REVLIST="c1aaaaaa" STUB_NOT_ANCESTOR="c1aaaaaa"
run
check_status nonzero "$STATUS"
check_grep "confirmed commit is not on this branch: c1aaaaaa" "$OUT"
check_no_grep "glab-axi api" "$STUB_CALLS"

setup "a confirmed FIX with no commit refuses the whole run"
cat > "$PLAN" <<'JSON'
{
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "discussion": "dfix", "verdict": "FIX", "summary": "No sha here.", "confirmed": true }
  ]
}
JSON
run
check_status nonzero "$STATUS"
check_grep "confirmed thread is incomplete: dfix" "$OUT"
check "no command was issued at all" test "$(wc -l < "$STUB_CALLS" | tr -d ' ')" -eq 0

# The plan is hand-edited, so the guard has to survive a second entry being the
# broken one — a check that stops at the first thread would wave this through
# and post a reply with no summary behind it.
setup "a later confirmed FIX with no summary refuses the whole run"
cat > "$PLAN" <<'JSON'
{
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "discussion": "dok", "verdict": "FIX", "commit": "c1aaaaaa",
      "summary": "Passes a radix.", "confirmed": true },
    { "discussion": "dbad", "verdict": "FIX", "commit": "c2bbbbbb", "confirmed": true }
  ]
}
JSON
export STUB_REVLIST="c1aaaaaa c2bbbbbb"
run
check_status nonzero "$STATUS"
check_grep "confirmed thread is incomplete: dbad" "$OUT"
check_no_grep "push origin" "$STUB_CALLS"
check_no_grep "glab-axi api" "$STUB_CALLS"

setup "a confirmed thread with an unknown verdict refuses the whole run"
cat > "$PLAN" <<'JSON'
{
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "base000",
  "threads": [
    { "discussion": "dweird", "verdict": "MAYBE", "confirmed": true }
  ]
}
JSON
run
check_status nonzero "$STATUS"
check_grep "confirmed thread is incomplete: dweird" "$OUT"
check_no_grep "glab-axi api" "$STUB_CALLS"

setup "a malformed plan refuses the whole run"
printf '{ not json' > "$PLAN"
run
check_status nonzero "$STATUS"
check_grep "plan is not valid JSON" "$OUT"

# --- result ------------------------------------------------------------------

report
