#!/bin/bash
#
# pr-writeback.sh
#
# The loop's writes to a pull request, one write per invocation.
#
# "Writeback" is now a slight misnomer — nothing is written *back* to a review
# thread any more — but the name is what the README, the exit-code contract and
# the standing decisions all say, so it stays and this comment carries the
# correction.
#
# The script used to be the far end of a confirmation gate: an Orca worker
# triaged review threads, prepared a commit per fix, wrote a plan file, and
# stopped until the operator marked entries `confirmed` and ran this against
# them. The worker, the plan and the gate are all deleted. What survives is the
# process boundary itself, on a new and narrower justification: **the merge is
# the single irreversible unattended write**, and a separate executable is a
# thing a human can also run by hand.
#
# Usage:
#   pr-writeback.sh autofix --repo <owner/name> --pr <n> [--sha <commit>]
#   pr-writeback.sh review  --repo <owner/name> --pr <n>
#   pr-writeback.sh comment --repo <owner/name> --pr <n> --body-file <path>
#   pr-writeback.sh label   --repo <owner/name> --pr <n> --add <name>
#   pr-writeback.sh merge   --repo <owner/name> --pr <n> --sha <commit> \
#                           --method <merge|squash|rebase>
#
# **Exactly one write per invocation.** That is the whole of the atomicity
# story: there is no sequence to be caught halfway through, so there is no
# half-written state to define. `label` in particular is reachable *alone*
# rather than bundled into an escalation verb, because escalation is
# comment-then-label and self-heals — a later pass re-adds a missing label
# without re-posting the comment it flags.
#
# **Free text travels as a body file; the seam's own constants travel as
# literal bodies.** `comment` takes `--body-file` because gh-axi would
# reinterpret a `--body` that happened to look like JSON, and a file has
# nothing left to reinterpret — the escalation body carries a markdown table
# and an HTML marker. `autofix` and `review` are verbs rather than callers of
# `comment` for the opposite reason: a CodeRabbit command is the seam's own
# constant, spelled once here, and routing it down the free-text channel would
# make a typo a silent no-op instead of an argument error.
#
# **Three channels cross the process boundary:**
#
#   exit code   0 the write landed; 1 an argument error or a failed write;
#               3 and 4 the merge's failure class, below
#   stdout      the write's response, verbatim — gh-axi answers a refusal on
#               stdout too, and those `error:`/`code:` lines are exactly what
#               the loop's escalation comment pastes
#   stderr      this script's own words — the usage text, and one outcome line
#               prefixed `pr-writeback:` — for a human running it by hand
#
# For the four reversible verbs a failed write and a bad argument share exit 1
# deliberately: the loop's posture to both is the same — log it, re-derive next
# pass — so a distinction here is one nothing would read.
#
# **`merge` is the exception, because it is the one irreversible unattended
# write.** Everywhere else the loop can simply try again next pass; here the
# difference between *GitHub said no* and *the network hiccuped* decides between
# handing the pull request to the operator and saying nothing at all. So the
# failure class crosses the boundary as an exit status, which is the channel a
# human running the seam by hand reads the same way the loop does:
#
#   0  merged
#   1  an argument error, or a fatal failure of this script
#   3  refused — GitHub answered, durably, no
#   4  transient — the call did not get a durable answer; ask again next pass
#
# **`2` is never used**, so it can never collide with gh-axi's own exit codes.
#
# The class is gh.sh's `gh_error_class` and nothing else. A second copy of that
# rule living here is exactly the drift that made the two GraphQL helpers
# disagree, and this is the one call site where being wrong is not recoverable.
#
# **Argument validation only, with one guard.** Whether the pull request is
# open, a draft, a fork head, mergeable, or in a configured repository is the
# loop's call. Re-deriving any of it here would be a second gate that could
# disagree with the first.
#
# The guard is that **`merge` requires the assessed commit**. It is what makes
# *assess, then merge that commit* structural rather than a convention the
# caller is trusted to keep: with no commit there is nothing to omit it in
# favour of except whatever happens to be at the head, which is the unreviewed
# code the assertion exists to refuse.
#
# **No configuration is read at all.** Everything the seam needs arrives on
# argv, the label name included.
#
# Requires: gh-axi (authenticated against github.com), mktemp

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# `gh_json` and `gh_error_class` live in gh.sh, which both this script and
# agent-loop.sh source. The merge is the only call here that needs it — the
# other four verbs have a gh-axi subcommand — but it needs both halves: the raw
# API call that can carry a commit assertion, and the rule that says what a
# failed one means.
# shellcheck source=gh.sh
source "$SCRIPT_DIR/gh.sh"

# The one string CodeRabbit parses for each command, spelled once. This is the
# reason `autofix` and `review` are verbs rather than callers of `comment`: the
# text is the seam's, so it lives in the seam.
AUTOFIX_TRIGGER='@coderabbitai autofix'
REVIEW_TRIGGER='@coderabbitai review'

VERB=""
REPO=""
PR=""
BODY_FILE=""
ADD_LABEL=""
SHA=""
METHOD=""

# What GitHub's merge endpoint accepts for `merge_method`, spelled once for the
# same reason the CodeRabbit triggers above are: a fourth word is not a merge
# method the loop got wrong — it is a merge method that does not exist, and
# GitHub answers one with a 422 that classifies `refused`. That is the loop's
# *"I said yes and reality disagreed"* signal, and a typo must never be able to
# impersonate it.
#
# The usage block below names the three again and cannot help it: its heredoc is
# quoted, which is what keeps the flag syntax in it from being expanded. Two
# copies, one of them inert prose, is the floor here — the argument error reads
# from this one.
MERGE_METHODS="merge squash rebase"

# Print usage information to stdout showing supported verbs, flags, exit codes,
# and examples. Called when --help is passed or when argument parsing fails.
usage() {
  cat <<'EOF'
Usage: pr-writeback.sh <verb> --repo <owner/name> --pr <n> [flags]

Makes exactly one write to one pull request and reports what GitHub answered.

Verbs:
  autofix   Post the CodeRabbit autofix command.
  review    Post the CodeRabbit review command.
  comment   Post a comment whose body is read from a file.
  label     Add a label.
  merge     Merge, asserting the commit that was assessed.

Flags:
  --repo <owner/name>  The repository on GitHub. Not a path.
  --pr <n>             The pull-request number.
  --body-file <path>   comment only: the body, which must not be empty.
  --add <name>         label only: the label to add.
  --sha <commit>       autofix: input head to record; merge: assessed commit.
  --method <name>      merge only: merge, squash or rebase. Required.
  -h, --help           Show this message.

Exit codes:
  0  the write landed
  1  an argument error, or the write failed
  3  merge only: GitHub refused it
  4  merge only: the merge failed transiently — try again next pass

2 is never used, so it cannot collide with gh-axi's own exit codes.

stdout carries GitHub's response verbatim; stderr carries this script's own
prose.
EOF
}

# Print a message to stderr prefixed with "pr-writeback:". Every word this
# script says for itself goes to stderr, so stdout stays the response and
# nothing else.
say() { printf 'pr-writeback: %s\n' "$*" >&2; }

# Print an error message to stderr and exit with status 1.
die() { say "$@"; exit 1; }

# --- arguments ----------------------------------------------------------------

# A flag that belongs to another verb is its own error rather than an unknown
# one, because `autofix --body-file` is a caller trying to send free text down
# a channel that does not take it, and saying so is more use than "unknown".
flag_of() {
  local flag="$1" verb="$2"
  [[ "$VERB" == "$verb" ]] || die "$flag is not a flag of ${VERB}"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 1 ;;
  autofix|review|comment|label|merge) VERB="$1"; shift ;;
  # The deleted interface began with a flag — `--plan`, `--repo <worktree>`,
  # `--seen-list`. An operator with that command line in their shell history is
  # told what changed rather than handed a bare usage block.
  -*) say "no verb given: the verb comes before the flags"; usage >&2; exit 1 ;;
  *) die "unknown verb: $1" ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; [[ -n "$REPO" ]] || die "--repo needs a value"; shift 2 ;;
    --pr) PR="${2:-}"; [[ -n "$PR" ]] || die "--pr needs a value"; shift 2 ;;
    --body-file)
      flag_of --body-file comment
      BODY_FILE="${2:-}"; [[ -n "$BODY_FILE" ]] || die "--body-file needs a value"; shift 2 ;;
    --add)
      flag_of --add label
      ADD_LABEL="${2:-}"; [[ -n "$ADD_LABEL" ]] || die "--add needs a value"; shift 2 ;;
    --sha)
      [[ "$VERB" == autofix || "$VERB" == merge ]] \
        || die "--sha is not a flag of ${VERB}"
      SHA="${2:-}"; [[ -n "$SHA" ]] || die "--sha needs a value"; shift 2 ;;
    --method)
      flag_of --method merge
      METHOD="${2:-}"; [[ -n "$METHOD" ]] || die "--method needs a value"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$REPO" ]] || die "--repo is required"
# `<owner>/<name>` is the whole identifier on GitHub. The old script read
# --repo as a worktree path, so a stale command line would otherwise be taken
# for a repository named after a directory.
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "--repo must be owner/name, got: $REPO"

[[ -n "$PR" ]] || die "--pr is required"
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || die "--pr must be a positive integer, got: $PR"

case "$VERB" in
  autofix)
    if [[ -n "$SHA" && ! "$SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
      die "--sha must be a full 40-character commit, got: $SHA"
    fi
    ;;
  comment)
    [[ -n "$BODY_FILE" ]] || die "comment needs --body-file"
    [[ -r "$BODY_FILE" && -f "$BODY_FILE" ]] || die "--body-file is not a readable file: $BODY_FILE"
    # An empty body posts a blank comment. On the escalation path that destroys
    # the record while the marker's absence claims nothing was ever posted, so
    # the next pass neither re-posts nor recovers.
    [[ -s "$BODY_FILE" ]] || die "--body-file is empty: $BODY_FILE"
    ;;
  label)
    [[ -n "$ADD_LABEL" ]] || die "label needs --add"
    ;;
  merge)
    # The one guard that is not merely argument shape: without it the seam would
    # merge whatever is at the head, which is the unreviewed code the assertion
    # exists to refuse.
    [[ -n "$SHA" ]] || die "merge needs --sha: the commit the gate assessed"
    # In full, and never abbreviated. The point of the argument is that GitHub
    # compares it against the head and refuses a mismatch; a prefix is a weaker
    # claim than the one the gate made, and `HEAD` is not a claim at all.
    [[ "$SHA" =~ ^[0-9a-fA-F]{40}$ ]] || die "--sha must be a full 40-character commit, got: $SHA"
    [[ -n "$METHOD" ]] || die "merge needs --method"
    [[ " $MERGE_METHODS " == *" $METHOD "* ]] \
      || die "--method must be one of: $MERGE_METHODS, got: $METHOD"
    ;;
esac

# gh-axi alone, still. Sourcing gh.sh does not import its `jq` requirement: the
# one call this seam makes through it is a single-page write, and `gh_json`
# reaches for jq only on the paginated branch, which no write can take.
# Demanding a tool that cannot be run would fail the four verbs that worked
# before for a reason none of them has.
command -v gh-axi >/dev/null 2>&1 || die "required command not found on PATH: gh-axi"

# --- the write ------------------------------------------------------------------

# gh-axi's subcommand where one exists, and a raw API call only where none can
# carry what the call has to say. It matches what
# the loop already does for its issue writes, `--body-file` is handled by the
# tool rather than by a `--field` it might reinterpret, and the recorded argv
# stays a line a human can read.
#
# The response goes out on stdout whichever way the call went. gh-axi renders a
# refusal as TOON on stdout as well, so the same forwarding carries both, and
# the caller reads its meaning off the exit code rather than off the channel.
#
# Not every failure is one gh-axi renders, though. A rejected flag or a broken
# token is gh-axi's own failure rather than GitHub's: it goes to stderr and
# leaves stdout empty. Dropping that would hand the loop an empty `out=$(...)`
# and an escalation comment with nothing pasted into it, which is the one thing
# this channel exists to prevent — so stderr stands in when, and only when,
# stdout is empty. Nothing is ever merged into a response gh-axi did render.
#
# "Verbatim" up to one detail: a command substitution eats trailing newlines and
# the printf below puts exactly one back. Nothing reading this channel counts
# blank lines, and gh.sh forwards its own failure text the same way.
gh_write() {
  local out status=0 errors
  errors=$(mktemp "${TMPDIR:-/tmp}/pr-writeback.XXXXXX") || die "could not create a temporary file"
  out=$(gh-axi "$@" 2>"$errors") || status=$?
  if [[ -z "$out" && "$status" -ne 0 ]]; then out=$(cat "$errors"); fi
  rm -f "$errors"
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; fi
  return "$status"
}

# The merge is the one call that does not go through `gh_write`, and it is the
# `gh-axi pr merge` subcommand it does not go through either. That subcommand
# takes a pull request and a method and nothing else: there is no way to spell
# *merge this, and only if its head is still the commit I assessed*. The raw
# endpoint takes `sha`, GitHub compares it against the head, and a push that
# raced the gate loses with a 409 instead of being merged unreviewed. So the
# asymmetry with the other four verbs is not a preference — it is the only shape
# that can carry the assertion.
#
# `gh_json` is called **unsubstituted**, which is what makes `$GH_ERROR` live
# afterwards: run inside `$(...)` the assignment would die with the subshell and
# the classifier would read whatever was there before, or nothing. Its stdout —
# the decoded response on success, gh-axi's `error:`/`code:` lines on a refusal
# — passes straight through to ours, which is the channel the escalation pastes.
#
# **It does not get `gh_write`'s stderr fallback, and that is deliberate.**
# `gh_json` discards stderr, so a failure gh-axi reported there arrives as empty
# text and classifies transient. Standing the fallback up here would change no
# class and buy nothing: every refusal GitHub renders comes back on *stdout* —
# measured, all three of them, in T13 — and gh-axi's own failures carry neither
# an `(HTTP nnn)` suffix nor a FORBIDDEN/VALIDATION_ERROR code, so they classify
# transient whichever channel they are read from. What makes that safe is not
# the classifier but the order of the pass: the merge is the last call after a
# chain of successful reads through the same tool and the same token, so the
# failures that would be durable here — a rejected flag, a broken token — have
# already stopped the pass long before it reaches this line.
merge_write() {
  gh_json PUT "/repos/$REPO/pulls/$PR/merge" \
    --field "sha=$SHA" --field "merge_method=$METHOD"
}

# Execute the write operation for the given verb. Dispatches to the appropriate
# GitHub API call based on VERB (autofix, review, comment, label, or merge).
# Returns the exit status of the underlying gh-axi or gh_json call.
write() {
  case "$VERB" in
    autofix)
      local body="$AUTOFIX_TRIGGER"
      if [[ -n "$SHA" ]]; then
        body="$body"$'\n'"<!-- agent-loop-autofix-head: $SHA -->"
      fi
      gh_write pr comment "$PR" --repo "$REPO" --body "$body"
      ;;
    review)  gh_write pr comment "$PR" --repo "$REPO" --body "$REVIEW_TRIGGER" ;;
    comment) gh_write pr comment "$PR" --repo "$REPO" --body-file "$BODY_FILE" ;;
    label)   gh_write pr edit "$PR" --repo "$REPO" --add-label "$ADD_LABEL" ;;
    merge)   merge_write ;;
    # Unreachable — the verb was matched on the way in — but a `case` with no
    # default returns 0, and a silent success having issued no write is the one
    # failure this script must not have.
    *) die "no write defined for verb: $VERB" ;;
  esac
}


if write; then
  # The merge names what it asserted, where the other four have nothing to name.
  # Both of its failure lines carry the commit, and an outcome line a human reads
  # by hand is worth as much on the pass as on the refusal.
  if [[ "$VERB" == merge ]]; then
    say "merge: $REPO#$PR at $SHA by $METHOD"
  else
    say "$VERB: $REPO#$PR"
  fi
  exit 0
fi

# What went wrong is on stdout already, in GitHub's own words. Repeating it here
# would put the same bytes on two channels and invite a caller to read the wrong
# one.
if [[ "$VERB" != merge ]]; then
  say "$VERB failed on $REPO#$PR"
  exit 1
fi

# Which of the two the merge failure was, decided by gh.sh's rule rather than by
# a reading of the text made here. `gh_error_class` takes no argument, so it
# reads `$GH_ERROR` — the text `gh_json` just captured, still live because the
# call above was not substituted.
#
# Empty text classifies transient, and that is the honest answer rather than a
# gap: a failure gh-axi never rendered — a rejected flag, a broken token, a torn
# response — says nothing about the pull request, so the only thing to do is ask
# again. Nothing escalates on that path, so the empty stdout it leaves costs no
# escalation its paste.
#
# Transient is deliberately unbounded and needs no machinery: the merge is the
# last call after a chain of successful reads, every durable failure is already
# refused, and the loop's poll interval is the whole of the backoff.
if [[ "$(gh_error_class)" == "refused" ]]; then
  say "merge refused on $REPO#$PR at $SHA"
  exit 3
fi
say "merge failed transiently on $REPO#$PR at $SHA"
exit 4
