#!/bin/bash
#
# test-pr-writeback.sh
#
# Runs the real pr-writeback.sh against the stub `gh-axi` in tests/bin and
# asserts on the argv it produced and on which channel each thing came out of.
# The stub directory is the only seam: no function inside pr-writeback.sh is
# reached into directly, because the whole point of the script is which command
# it issues and that it issues exactly one.
#
# Two properties get the most attention here, because nothing else tests them:
#
#   - **Exactly one write per invocation.** Every case counts the stub's calls,
#     so a verb that grew a second write fails loudly rather than quietly.
#   - **Channel discipline.** stdout is the write's response verbatim, stderr is
#     the seam's own prose. gh-axi puts a refusal on *stdout*, so the seam has to
#     move that text across channels correctly, and the loop pastes whatever
#     lands on stdout into an escalation comment.
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

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/pr-writeback-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

REPO="nywleswoey/agentloop"

setup() {
  CURRENT="$1"
  echo "== $CURRENT"
  WORK="$(mktemp -d "$SCRATCH/case.XXXXXX")"
  STUB_STATE="$WORK/state"
  STUB_CALLS="$WORK/calls.log"
  export STUB_STATE STUB_CALLS
  mkdir -p "$STUB_STATE"
  : > "$STUB_CALLS"
  unset STUB_GH_FAIL STUB_GH_STDERR
  OUT="$WORK/stdout.log"
  ERR="$WORK/stderr.log"
  : > "$OUT"
  : > "$ERR"
}

# run <args...> — the two channels are captured apart, because keeping them
# apart is half of what this suite checks.
run() {
  "$SCRIPT" "$@" > "$OUT" 2> "$ERR"
  STATUS=$?
}

# Every call this seam makes to gh-axi is a write — it never reads — so counting
# the stub's calls is counting writes.
check_writes() {
  local expected="$1"
  check "exactly $expected write(s) (got $(grep -c . "$STUB_CALLS"))" \
    test "$(grep -c . "$STUB_CALLS")" -eq "$expected"
}

# --- autofix --------------------------------------------------------------------

# The trigger text is the one string CodeRabbit parses, so the seam spells it
# once and it travels as a literal --body: a fixed string with no JSON shape
# cannot be reinterpreted, and it stays visible in the argv a stub records.
setup "autofix posts the CodeRabbit command the seam owns"
run autofix --repo "$REPO" --pr 12
check_status 0 "$STATUS"
check_grep "gh-axi pr comment 12 --repo $REPO --body @coderabbitai autofix" "$STUB_CALLS"
check_writes 1
# The response goes out verbatim on stdout, and the seam's prose on stderr.
check_grep "created: true" "$OUT"
check_no_grep "pr-writeback:" "$OUT"
check_grep "pr-writeback:" "$ERR"

setup "autofix takes no free text at all"
printf 'not the trigger\n' > "$WORK/body.md"
run autofix --repo "$REPO" --pr 12 --body-file "$WORK/body.md"
check_status 1 "$STATUS"
check_grep "--body-file is not a flag of autofix" "$ERR"
check_writes 0

# --- review ---------------------------------------------------------------------

# `review`, not `resume`: it is the measured gesture, and it is the one command
# that makes CodeRabbit review a pull request it has already skipped.
setup "review posts its own CodeRabbit command"
run review --repo "$REPO" --pr 12
check_status 0 "$STATUS"
check_grep "gh-axi pr comment 12 --repo $REPO --body @coderabbitai review" "$STUB_CALLS"
check_writes 1
check_no_grep "autofix" "$STUB_CALLS"

setup "review takes no free text either"
printf 'not the trigger\n' > "$WORK/body.md"
run review --repo "$REPO" --pr 12 --body-file "$WORK/body.md"
check_status 1 "$STATUS"
check_grep "--body-file is not a flag of review" "$ERR"
check_writes 0

# --- comment ----------------------------------------------------------------------

# The body used here is the shape the escalation actually posts — a markdown
# table, a JSON fragment and an HTML marker — because those are the bytes a
# --body would invite gh-axi to reinterpret.
setup "comment sends free text as a file, never as an inline argument"
cat > "$WORK/body.md" <<'MD'
**escalate** — the gate said no.

| veto | value |
|---|---|
| V1 | `{"level": "moderate"}` |

<!-- agent-loop:escalation sha=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef -->
MD
run comment --repo "$REPO" --pr 12 --body-file "$WORK/body.md"
check_status 0 "$STATUS"
check_grep "gh-axi pr comment 12 --repo $REPO --body-file $WORK/body.md" "$STUB_CALLS"
check_writes 1
check_no_grep "--body " "$STUB_CALLS"
# The body reached GitHub byte for byte, brackets, braces and marker intact.
check "the body arrived unaltered" \
  cmp -s "$WORK/body.md" "$STUB_STATE/pr-body-12.txt"

setup "comment refuses a body file that is not there"
run comment --repo "$REPO" --pr 12 --body-file "$WORK/missing.md"
check_status 1 "$STATUS"
check_grep "--body-file is not a readable file" "$ERR"
check_writes 0

setup "comment refuses an empty body file"
: > "$WORK/empty.md"
run comment --repo "$REPO" --pr 12 --body-file "$WORK/empty.md"
check_status 1 "$STATUS"
check_grep "--body-file is empty" "$ERR"
check_writes 0

setup "comment needs a body file"
run comment --repo "$REPO" --pr 12
check_status 1 "$STATUS"
check_grep "comment needs --body-file" "$ERR"
check_writes 0

# --- label ------------------------------------------------------------------------

# The label is reachable alone, and that is the whole point: escalation is
# comment-then-label, and it self-heals because a later pass can re-add a
# missing label without re-posting the comment.
setup "label adds a label and does nothing else"
run label --repo "$REPO" --pr 12 --add agent-needs-review
check_status 0 "$STATUS"
check_grep "gh-axi pr edit 12 --repo $REPO --add-label agent-needs-review" "$STUB_CALLS"
check_writes 1
check_no_grep "pr comment" "$STUB_CALLS"
check_grep "edited: true" "$OUT"

setup "label needs a name to add"
run label --repo "$REPO" --pr 12
check_status 1 "$STATUS"
check_grep "label needs --add" "$ERR"
check_writes 0

setup "label takes no body"
printf 'body\n' > "$WORK/body.md"
run label --repo "$REPO" --pr 12 --body-file "$WORK/body.md" --add agent-needs-review
check_status 1 "$STATUS"
check_grep "--body-file is not a flag of label" "$ERR"
check_writes 0

setup "comment takes no label"
printf 'body\n' > "$WORK/body.md"
run comment --repo "$REPO" --pr 12 --body-file "$WORK/body.md" --add agent-needs-review
check_status 1 "$STATUS"
check_grep "--add is not a flag of comment" "$ERR"
check_writes 0

# --- the arguments every verb takes -------------------------------------------------

setup "a missing verb is refused"
run
check_status 1 "$STATUS"
check_grep "Usage: pr-writeback.sh" "$ERR"
check_writes 0

setup "an unknown verb is refused"
run escalate --repo "$REPO" --pr 12
check_status 1 "$STATUS"
check_grep "unknown verb: escalate" "$ERR"
check_writes 0

setup "an unknown flag is refused"
run autofix --repo "$REPO" --pr 12 --dry-run
check_status 1 "$STATUS"
check_grep "unknown argument: --dry-run" "$ERR"
check_writes 0

setup "a missing repository is refused"
run autofix --pr 12
check_status 1 "$STATUS"
check_grep "--repo is required" "$ERR"
check_writes 0

setup "a repository that is not owner/name is refused"
run autofix --repo agentloop --pr 12
check_status 1 "$STATUS"
check_grep "--repo must be owner/name" "$ERR"
check_writes 0

setup "a repository given as a path is refused"
run autofix --repo /home/me/worktrees/agentloop --pr 12
check_status 1 "$STATUS"
check_grep "--repo must be owner/name" "$ERR"
check_writes 0

setup "a missing pull-request number is refused"
run autofix --repo "$REPO"
check_status 1 "$STATUS"
check_grep "--pr is required" "$ERR"
check_writes 0

for bad in 0 -3 12.5 twelve '#12'; do
  setup "a pull-request number of '$bad' is refused"
  run autofix --repo "$REPO" --pr "$bad"
  check_status 1 "$STATUS"
  check_grep "--pr must be a positive integer" "$ERR"
  check_writes 0
done

setup "a flag with no value is refused"
run autofix --repo "$REPO" --pr
check_status 1 "$STATUS"
check_grep "--pr needs a value" "$ERR"
check_writes 0

setup "--help explains itself and writes nothing"
run --help
check_status 0 "$STATUS"
check_grep "Usage: pr-writeback.sh" "$OUT"
check_writes 0

# --- the interface that was deleted ---------------------------------------------------

# The plan file, the worktree spelling of --repo, the seen list and the
# confirmation flag are gone. Each is refused as an ordinary unknown argument,
# so an operator running an old command line is told rather than obeyed.
for gone in --plan --seen-list --confirmed; do
  setup "$gone is no longer an argument"
  run comment "$gone" "$WORK/x" --repo "$REPO" --pr 12
  check_status 1 "$STATUS"
  check_grep "unknown argument: $gone" "$ERR"
  check_writes 0
done

# The old command line began with a flag, so it never reaches the loop above.
# It is told what changed rather than handed a bare usage block.
setup "the old command line is told what changed"
run --plan "$WORK/plan.json" --repo "$WORK" --seen-list "$WORK/seen.jsonl"
check_status 1 "$STATUS"
check_grep "no verb given: the verb comes before the flags" "$ERR"
check_grep "Usage: pr-writeback.sh" "$ERR"
check_writes 0

# The verdict vocabulary and the two GraphQL mutations went with the plan file
# that fed them. `FIX` is checked as `verdict` rather than as its own word,
# because it is a substring of `AUTOFIX_TRIGGER` and the bare grep would fail on
# the very constant this ticket adds.
setup "no verb speaks the old verdict vocabulary"
for gone in verdict REFUSE ANSWER ESCALATE; do
  check_no_grep "$gone" "$SCRIPT"
done
check_no_grep "addPullRequestReviewThreadReply" "$SCRIPT"
check_no_grep "resolveReviewThread" "$SCRIPT"

# --- no configuration -------------------------------------------------------------------

# Everything the seam needs arrives on argv. Pointed at a config file that is
# not even JSON, it neither reads it nor notices it.
setup "the seam reads no configuration at all"
printf 'this is not json\n' > "$WORK/agent-loop.config.json"
mkdir -p "$WORK/home"
(
  export HOME="$WORK/home" AGENT_LOOP_CONFIG="$WORK/agent-loop.config.json"
  "$SCRIPT" label --repo "$REPO" --pr 12 --add agent-needs-review
) > "$OUT" 2> "$ERR"
STATUS=$?
check_status 0 "$STATUS"
check_grep "gh-axi pr edit 12 --repo $REPO --add-label agent-needs-review" "$STUB_CALLS"
check_writes 1

# --- no second gate ------------------------------------------------------------------------

# A repository the stub has never heard of and a pull-request number that
# cannot exist: the seam does not look at either, so the write is attempted and
# the far end is left to answer. Anything it checked here would be a second gate
# able to disagree with the loop's.
setup "the seam does not check anything about the pull request itself"
printf 'hello\n' > "$WORK/body.md"
run comment --repo "someone/never-configured" --pr 99999 --body-file "$WORK/body.md"
check_status 0 "$STATUS"
check_grep "gh-axi pr comment 99999 --repo someone/never-configured --body-file" "$STUB_CALLS"
check_writes 1

# --- the three channels ------------------------------------------------------------------

# gh-axi puts a refusal on stdout as TOON and exits 1. The seam forwards that
# text on stdout — the channel the loop's `out=$(...)` capture actually reads,
# and the bytes its escalation comment pastes — and keeps its own prose on
# stderr, where it can never be mistaken for what GitHub said.
setup "a refused write forwards the response verbatim on stdout"
export STUB_GH_FAIL=pr-comment
run autofix --repo "$REPO" --pr 12
check_status 1 "$STATUS"
check_grep 'error: "gh: Not Found (HTTP 404)"' "$OUT"
check_grep "code: UNKNOWN" "$OUT"
check_no_grep "pr-writeback:" "$OUT"
# The prose says the verb failed and does not restate what GitHub said.
check_grep "pr-writeback:" "$ERR"
check_no_grep "HTTP 404" "$ERR"
check_writes 1

setup "a refused label write is reported the same way"
export STUB_GH_FAIL=pr-edit
run label --repo "$REPO" --pr 12 --add agent-needs-review
check_status 1 "$STATUS"
check_grep 'error: "gh: Not Found (HTTP 404)"' "$OUT"
check_grep "pr-writeback:" "$ERR"
check_writes 1

# gh-axi's own failures — a rejected flag, a broken token — are not GitHub
# refusals: they go to stderr and leave stdout empty. Forwarding stdout alone
# would hand the loop nothing at all to paste into its escalation comment, which
# is the one thing this channel exists to carry.
setup "a failure gh-axi reports on stderr still reaches stdout"
export STUB_GH_FAIL=pr-comment STUB_GH_STDERR=1
run autofix --repo "$REPO" --pr 12
check_status 1 "$STATUS"
check_grep 'error: "gh: Not Found (HTTP 404)"' "$OUT"
check_grep "code: UNKNOWN" "$OUT"
check_grep "pr-writeback:" "$ERR"
check_writes 1

# The other half of the same rule: a response gh-axi did render is never mixed
# with anything else.
setup "a rendered response is forwarded on its own"
run label --repo "$REPO" --pr 12 --add agent-needs-review
check_status 0 "$STATUS"
check "stdout is the response and nothing else" \
  test "$(cat "$OUT")" = "$(printf 'pr:\n  number: 12\n  edited: true')"

# An argument error and a failed write get the same posture from the loop —
# log it, re-derive next pass — so both are exit 1 and the seam draws no
# distinction the caller would have to read.
setup "an argument error and a failed write share one exit code"
printf 'hello\n' > "$WORK/body.md"
export STUB_GH_FAIL=pr-comment
run comment --repo "$REPO" --pr 12 --body-file "$WORK/body.md"
check_status 1 "$STATUS"

# --- result ------------------------------------------------------------------

report
