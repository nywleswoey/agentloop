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
#   pr-writeback.sh autofix --repo <owner/name> --pr <n>
#   pr-writeback.sh review  --repo <owner/name> --pr <n>
#   pr-writeback.sh comment --repo <owner/name> --pr <n> --body-file <path>
#   pr-writeback.sh label   --repo <owner/name> --pr <n> --add <name>
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
#   exit code   0 the write landed; 1 an argument error or a failed write
#   stdout      the write's response, verbatim — gh-axi answers a refusal on
#               stdout too, and those `error:`/`code:` lines are exactly what
#               the loop's escalation comment pastes
#   stderr      this script's own words — the usage text, and one outcome line
#               prefixed `pr-writeback:` — for a human running it by hand
#
# A failed write and a bad argument share exit 1 deliberately: the loop's
# posture to both is the same — log it, re-derive next pass — so a distinction
# here is one nothing would read.
#
# **Argument validation only.** Whether the pull request is open, a draft, a
# fork head, mergeable, or in a configured repository is the loop's call.
# Re-deriving any of it here would be a second gate that could disagree with
# the first.
#
# **No configuration is read at all.** Everything the seam needs arrives on
# argv, the label name included.
#
# Requires: gh-axi (authenticated against github.com), mktemp

set -euo pipefail

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

usage() {
  cat <<'EOF'
Usage: pr-writeback.sh <verb> --repo <owner/name> --pr <n> [flags]

Makes exactly one write to one pull request and reports what GitHub answered.

Verbs:
  autofix   Post the CodeRabbit autofix command.
  review    Post the CodeRabbit review command.
  comment   Post a comment whose body is read from a file.
  label     Add a label.

Flags:
  --repo <owner/name>  The repository on GitHub. Not a path.
  --pr <n>             The pull-request number.
  --body-file <path>   comment only: the body, which must not be empty.
  --add <name>         label only: the label to add.
  -h, --help           Show this message.

Exit codes:
  0  the write landed
  1  an argument error, or the write failed

stdout carries GitHub's response verbatim; stderr carries this script's own
prose.
EOF
}

# Every word this script says for itself goes to stderr, so stdout stays the
# response and nothing else.
say() { printf 'pr-writeback: %s\n' "$*" >&2; }

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
  autofix|review|comment|label) VERB="$1"; shift ;;
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
esac

command -v gh-axi >/dev/null 2>&1 || die "required command not found on PATH: gh-axi"

# --- the write ------------------------------------------------------------------

# gh-axi's subcommand where one exists, never a raw API call: it matches what
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

write() {
  case "$VERB" in
    autofix) gh_write pr comment "$PR" --repo "$REPO" --body "$AUTOFIX_TRIGGER" ;;
    review)  gh_write pr comment "$PR" --repo "$REPO" --body "$REVIEW_TRIGGER" ;;
    comment) gh_write pr comment "$PR" --repo "$REPO" --body-file "$BODY_FILE" ;;
    label)   gh_write pr edit "$PR" --repo "$REPO" --add-label "$ADD_LABEL" ;;
    # Unreachable — the verb was matched on the way in — but a `case` with no
    # default returns 0, and a silent success having issued no write is the one
    # failure this script must not have.
    *) die "no write defined for verb: $VERB" ;;
  esac
}

if write; then
  say "$VERB: $REPO#$PR"
  exit 0
fi

# What went wrong is on stdout already, in GitHub's own words. Repeating it here
# would put the same bytes on two channels and invite a caller to read the wrong
# one.
say "$VERB failed on $REPO#$PR"
exit 1
