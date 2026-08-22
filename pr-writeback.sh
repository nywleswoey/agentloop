#!/bin/bash
#
# pr-writeback.sh
#
# The only thing that pushes a pull-request worker's fixes or writes to a review
# thread. The worker triages threads, prepares a local commit per fix, writes a
# plan, and asks the operator to confirm; nothing reaches GitHub until this
# script is run against a plan whose entries the operator marked `confirmed`.
#
# Keeping every write in one script is what makes "nothing before confirmation"
# checkable rather than a promise: the worker's own instructions forbid any
# other push, comment or resolve, and this issues no write for a thread that was
# not confirmed.
#
# It is also where the loop's seen-list is written. A thread this run leaves
# silent — a question, an escalation, a proposal the operator declined — gets one
# line appended naming the thread and its newest comment, so the next pass can
# tell "already triaged, nothing new" from "never looked at". Because only this
# script appends, and only the operator's answer gets it run, a worker still
# parked for confirmation records nothing at all.
#
# Usage:
#   ./pr-writeback.sh --plan <plan.json> [--repo <path>] [--seen-list <path>]
#
# Plan shape:
#   {
#     "repo": "nywleswoey/automation",
#     "prNumber": 517,
#     "sourceBranch": "my-branch",
#     "baseSha": "<the branch tip before the worker committed anything>",
#     "threads": [
#       { "thread": "<node id>", "verdict": "FIX", "lastCommentId": 900001,
#         "commit": "<local sha>", "summary": "<one sentence>",
#         "confirmed": true },
#       { "thread": "<node id>", "verdict": "REFUSE", "lastCommentId": 900002,
#         "reply": "**Disagree** — ...", "confirmed": false },
#       { "thread": "<node id>", "verdict": "ANSWER", "lastCommentId": 900003 }
#     ]
#   }
#
# Requires: jq, git, gh-axi (authenticated against github.com)

set -euo pipefail

PLAN=""
REPO="$PWD"
SEEN_LIST=""
DROPPED=0
SURVIVING=0
ORIGINAL_HEAD=""
# `<thread node id>\t<sha as it landed on the branch>` per confirmed fix that
# survived. Keyed by the thread rather than by position, so the reply can never
# cite another thread's commit.
PUSHED_MAP=""

usage() {
  cat <<'EOF'
Usage: pr-writeback.sh --plan <plan.json> [--repo <path>] [--seen-list <path>]

Pushes the confirmed fixes on a pull-request triage plan and posts the confirmed
replies and resolves. Issues nothing at all for a thread that is not confirmed.

Options:
  --plan <path>        The triage plan the worker wrote and the operator confirmed.
  --repo <path>        Worktree holding the PR's head branch (default: cwd).
  --seen-list <path>   Append one line per thread this run leaves silent, so the
                       loop stops re-dispatching at it until a reply lands.
                       Nothing is recorded when this is not given.
  -h, --help           Show this message.
EOF
}

die() {
  printf 'pr-writeback: %s\n' "$*" >&2
  exit 1
}

say() { printf '%s\n' "$*"; }

plan_get() { jq -r "$1" "$PLAN"; }

# --- plan --------------------------------------------------------------------

load_plan() {
  [[ -f "$PLAN" ]] || die "plan not found: $PLAN"
  jq empty "$PLAN" 2>/dev/null || die "plan is not valid JSON: $PLAN"

  # `<owner>/<name>` is the whole identifier on GitHub: it addresses the API and
  # it is what the daemon matches seen-list entries against, so unlike GitLab
  # there is no second numeric id riding alongside it.
  PROJECT=$(plan_get '.repo // empty')
  PR_NUMBER=$(plan_get '.prNumber // empty')
  SOURCE_BRANCH=$(plan_get '.sourceBranch // empty')
  BASE_SHA=$(plan_get '.baseSha // empty')

  [[ -n "$PROJECT" ]]       || die "plan is missing repo"
  [[ -n "$PR_NUMBER" ]]     || die "plan is missing prNumber"
  [[ -n "$SOURCE_BRANCH" ]] || die "plan is missing sourceBranch"
  [[ -n "$BASE_SHA" ]]      || die "plan is missing baseSha"
  [[ "$(plan_get '.threads | type')" == "array" ]] || die "plan is missing a threads array"
  THREAD_COUNT=$(plan_get '.threads | length')

  # A malformed confirmed entry stops the whole run rather than half-writing a
  # thread: a FIX with no commit would push nothing and still say "Fixed in".
  # The jq is run in its own step so a jq that *errors* cannot read as "nothing
  # was wrong" — an empty answer must mean an empty answer.
  local bad
  bad=$(jq -r '
    .threads[]
    | select(.confirmed == true)
    | select(
        (.thread // "") == ""
        or (.verdict == "FIX"    and (((.commit // "") == "") or ((.summary // "") == "")))
        or (.verdict == "REFUSE" and ((.reply // "") == ""))
        or (([.verdict] | inside(["FIX", "REFUSE", "ANSWER", "ESCALATE"])) | not)
      )
    | .thread // "<no thread id>"' "$PLAN") \
    || die "plan could not be validated: $PLAN"
  [[ -z "$bad" ]] || die "confirmed thread is incomplete: $(tr '\n' ' ' <<< "$bad")"
}

# The confirmed fixes in plan order — the order they are replayed onto the
# branch. `confirmed_fixes` is shas alone, for comparing against the branch;
# `confirmed_fix_rows` carries the thread each sha belongs to.
confirmed_fixes() {
  jq -r '.threads[] | select(.verdict == "FIX" and .confirmed == true) | .commit' "$PLAN"
}

confirmed_fix_rows() {
  jq -r '.threads[]
    | select(.verdict == "FIX" and .confirmed == true)
    | [.thread, .commit] | @tsv' "$PLAN"
}

confirmed_count() {
  jq -r '[.threads[] | select(.confirmed == true)] | length' "$PLAN"
}

confirmed_fix_count() {
  jq -r '[.threads[] | select(.verdict == "FIX" and .confirmed == true)] | length' "$PLAN"
}

# --- git ---------------------------------------------------------------------

git_repo() { git -C "$REPO" "$@"; }

# Shas compare as one space-separated line, so an empty list and a blank line
# never read differently.
normalise_shas() { tr '\n' ' ' <<< "${1:-}" | tr -s ' ' | sed 's/^ //; s/ $//'; }

pushed_sha() { awk -F'\t' -v d="$1" '$1 == d { print $2; exit }' <<< "$PUSHED_MAP"; }

# Nothing here may run against a tree carrying work that is not in the plan:
# rebuilding the branch resets it, and a reset would take uncommitted edits with
# it. Every confirmed commit must also actually sit between baseSha and HEAD, or
# the plan is describing a branch this is not.
check_git_preconditions() {
  git_repo rev-parse --verify "$BASE_SHA" >/dev/null 2>&1 \
    || die "baseSha is not a commit in this repo: $BASE_SHA"
  git_repo merge-base --is-ancestor "$BASE_SHA" HEAD \
    || die "baseSha is not an ancestor of HEAD: $BASE_SHA"

  local dirty
  dirty=$(git_repo status --porcelain) || die "could not read the worktree state"
  [[ -z "$dirty" ]] || die "worktree has uncommitted changes; commit or stash them first"

  local sha
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    git_repo merge-base --is-ancestor "$sha" HEAD \
      || die "confirmed commit is not on this branch: $sha"
    git_repo merge-base --is-ancestor "$BASE_SHA" "$sha" \
      || die "confirmed commit predates baseSha: $sha"
  done < <(confirmed_fixes)
}

# Replay only the confirmed fixes onto baseSha. A rejected fix is simply never
# picked, so it leaves no revert and no debris behind — and because every commit
# involved is still unpushed, this rewrites nothing a reviewer has ever seen and
# the push that follows is still a fast-forward.
#
# When the confirmed set already *is* the branch, the branch is left exactly as
# it stands, so the ordinary "confirm everything" case keeps the very shas the
# worker showed in its table.
rebuild_branch() {
  local wanted current did sha
  wanted=$(confirmed_fixes)
  current=$(git_repo rev-list --reverse "$BASE_SHA..HEAD") \
    || die "could not list the branch's commits"

  if [[ "$(normalise_shas "$wanted")" == "$(normalise_shas "$current")" ]]; then
    while IFS=$'\t' read -r did sha; do
      [[ -n "$did" ]] || continue
      PUSHED_MAP+="$did"$'\t'"$sha"$'\n'
      SURVIVING=$((SURVIVING + 1))
    done < <(confirmed_fix_rows)
    return 0
  fi

  # Recorded before the reset so a failed push can put the branch back exactly
  # as the worker left it, rather than leaving the dropped commits reachable
  # only through the reflog.
  ORIGINAL_HEAD=$(git_repo rev-parse HEAD)
  git_repo reset --hard "$BASE_SHA" >/dev/null || die "could not reset the branch to baseSha"
  while IFS=$'\t' read -r did sha; do
    [[ -n "$did" ]] || continue
    if git_repo cherry-pick "$sha" >/dev/null 2>&1; then
      PUSHED_MAP+="$did"$'\t'"$(git_repo rev-parse HEAD)"$'\n'
      SURVIVING=$((SURVIVING + 1))
    else
      git_repo cherry-pick --abort >/dev/null 2>&1 || true
      DROPPED=$((DROPPED + 1))
    fi
  done < <(confirmed_fix_rows)
}

# One push, explicitly onto the PR's head branch: an Orca checkout has no
# upstream, so a bare `git push` has nothing to push to. Never --force.
push_branch() {
  if git_repo push origin "HEAD:$SOURCE_BRANCH"; then
    return 0
  fi
  if [[ -n "$ORIGINAL_HEAD" ]] && git_repo reset --hard "$ORIGINAL_HEAD" >/dev/null 2>&1; then
    say "branch restored to $ORIGINAL_HEAD"
  fi
  die "push to $SOURCE_BRANCH failed; nothing was written to GitHub"
}

# --- github ------------------------------------------------------------------

# gh-axi renders every answer as TOON and has no JSON output mode, so what a
# mutation replied cannot be read back as JSON directly. `tojson | @base64` is
# the one shape TOON has nothing left to restructure: a single opaque token that
# decodes to the response byte for byte.
#
# It matters here because GitHub answers a refused mutation with a 200 and an
# `errors` block. Without reading the body back, a thread that was never
# replied to would report as replied — which is the one thing this script must
# never get wrong.
gh_graphql() {
  local query="$1" variables="$2" response body
  response=$(gh-axi api POST /graphql \
    --field query="$query" --field variables="$variables" \
    --jq 'tojson|@base64' --full 2>/dev/null) || return 1
  [[ "$response" == error:* ]] && return 1
  body=$(sed -n 's/^  body: //p' <<< "$response")
  [[ -n "$body" ]] || return 1
  response=$(base64 -d <<< "$body" 2>/dev/null) || return 1
  jq -e 'has("errors") | not' <<< "$response" >/dev/null 2>&1
}

# Both writes are GraphQL mutations, because a review thread is a GraphQL object
# on GitHub: the node id the worker recorded is the whole address, and the REST
# reply route would need the thread's first comment id instead.
#
# The reply text travels as a GraphQL variable rather than inside the query, so
# a reviewer's own words can never be read as part of the document — and it is
# built with jq, so gh-axi is handed JSON rather than something it has to guess
# the shape of.
post_comment() {
  local thread="$1" body="$2"
  gh_graphql 'mutation($thread: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) {
        comment { databaseId }
      }
    }' \
    "$(jq -nc --arg thread "$thread" --arg body "$body" '{thread: $thread, body: $body}')"
}

resolve_thread() {
  local thread="$1"
  gh_graphql 'mutation($thread: ID!) {
      resolveReviewThread(input: {threadId: $thread}) {
        thread { isResolved }
      }
    }' \
    "$(jq -nc --arg thread "$thread" '{thread: $thread}')"
}

# --- seen-list -----------------------------------------------------------------

# One line per thread this run leaves silent, naming the thread and the newest
# comment on it. The entry stops matching the moment a reviewer replies, so new
# information reopens the case rather than sealing it.
#
# The file is append-only and disposable: losing it costs one repeated sweep of
# pull requests that were already triaged, and nothing worse. A run given no
# --seen-list, or a thread whose newest comment the worker did not record,
# records nothing and says so rather than write a line the daemon could never
# match.
record_seen() {
  local index="$1" verdict="$2" line
  [[ -n "$SEEN_LIST" ]] || return 0
  # lastCommentId is read out of the plan rather than passed in, so a comment id
  # that is not a number stays the plan's problem instead of becoming a shell one.
  line=$(jq -c --arg project "$PROJECT" --argjson pr "$PR_NUMBER" --arg verdict "$verdict" \
    ".threads[$index] | select(.lastCommentId != null) | {
       project: \$project,
       pr: \$pr,
       thread: .thread,
       lastCommentId: .lastCommentId,
       verdict: \$verdict
     }" "$PLAN") && [[ -n "$line" ]] \
    || { say "nothing recorded in the seen-list for thread $index: no lastCommentId"; return 0; }
  printf '%s\n' "$line" >> "$SEEN_LIST" \
    || say "seen-list append failed for thread $index: $SEEN_LIST"
}

# --- write-back ---------------------------------------------------------------

# One pass over the plan, in order. Only a confirmed FIX that made it onto the
# branch is resolved; a REFUSE gets its reply and the reviewer keeps the last
# word; everything else is reported and left alone.
write_back() {
  local t did verdict confirmed reply summary commit pushed short

  printf '\n| thread | verdict | commit | outcome |\n|---|---|---|---|\n'
  for (( t = 0; t < THREAD_COUNT; t++ )); do
    did=$(plan_get ".threads[$t].thread // empty")
    verdict=$(plan_get ".threads[$t].verdict // empty")
    # The same predicate jq selected on, so the two can never disagree about
    # what "confirmed" means.
    confirmed=$(plan_get ".threads[$t].confirmed == true")

    if [[ "$verdict" != "FIX" && "$verdict" != "REFUSE" ]]; then
      # A verdict the daemon would not recognise is reported like any other but
      # never recorded — an entry it cannot read is worse than no entry.
      if [[ "$verdict" == "ANSWER" || "$verdict" == "ESCALATE" ]]; then
        record_seen "$t" "$verdict"
      fi
      printf '| %s | %s | — | reported only, nothing written |\n' "$did" "$verdict"
      continue
    fi

    if [[ "$confirmed" != "true" ]]; then
      # I saw what the worker proposed and chose not to take it. Nothing lands on
      # the thread, so only the seen-list keeps the loop off it.
      record_seen "$t" DECLINED
      if [[ "$verdict" == "FIX" ]]; then
        printf '| %s | ESCALATE | — | rejected, commit dropped |\n' "$did"
      else
        printf '| %s | REFUSE | — | rejected, nothing written |\n' "$did"
      fi
      continue
    fi

    if [[ "$verdict" == "REFUSE" ]]; then
      reply=$(plan_get ".threads[$t].reply")
      if post_comment "$did" "$reply"; then
        printf '| %s | REFUSE | — | replied, left unresolved |\n' "$did"
      else
        printf '| %s | REFUSE | — | reply FAILED |\n' "$did"
      fi
      continue
    fi

    commit=$(plan_get ".threads[$t].commit")
    pushed=$(pushed_sha "$did")
    if [[ -z "$pushed" ]]; then
      # Confirmed, but nothing reached the thread, so it is as silent as an
      # escalation prepared by hand and is recorded as one.
      record_seen "$t" ESCALATE
      printf '| %s | ESCALATE | %s | would not replay, commit dropped |\n' "$did" "$commit"
      continue
    fi

    short="${pushed:0:8}"
    summary=$(plan_get ".threads[$t].summary")
    if ! post_comment "$did" "Fixed in $short.

$summary"; then
      printf '| %s | FIX | %s | reply FAILED, left unresolved |\n' "$did" "$short"
      continue
    fi
    if resolve_thread "$did"; then
      printf '| %s | FIX | %s | replied and resolved |\n' "$did" "$short"
    else
      printf '| %s | FIX | %s | replied, resolve FAILED |\n' "$did" "$short"
    fi
  done
}

# --- main --------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) PLAN="${2:-}"; [[ -n "$PLAN" ]] || die "--plan needs a path"; shift 2 ;;
    --repo) REPO="${2:-}"; [[ -n "$REPO" ]] || die "--repo needs a path"; shift 2 ;;
    --seen-list) SEEN_LIST="${2:-}"; [[ -n "$SEEN_LIST" ]] || die "--seen-list needs a path"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$PLAN" ]] || { usage >&2; exit 1; }
for tool in jq git gh-axi; do
  command -v "$tool" >/dev/null 2>&1 || die "required command not found on PATH: $tool"
done

load_plan

# Confirming nothing is a valid answer, and it must cost the PR nothing at all —
# no push, no comment, no resolve, not even a git read. The run still goes
# through write_back, which issues no command either when nothing is confirmed,
# and which is where the threads I left silent reach the seen-list.
#
# git is touched only when a fix is actually going to be pushed. A run that only
# carries confirmed refusals writes replies and nothing else, so it must not be
# blocked by the state of the worktree it happens to be run in.
if [[ "$(confirmed_count)" == "0" ]]; then
  say "nothing confirmed — pull request #$PR_NUMBER is left exactly as it was"
elif [[ "$(confirmed_fix_count)" != "0" ]]; then
  check_git_preconditions
  rebuild_branch

  # The push comes before any comment, so a reply never cites a commit that is
  # not on the branch, and a failed push exits without writing to GitHub at all.
  if (( SURVIVING > 0 )); then
    push_branch
    say "pushed $SURVIVING commit(s) to $SOURCE_BRANCH"
  else
    say "no fix survived, nothing pushed"
  fi
  if (( DROPPED > 0 )); then
    say "$DROPPED confirmed fix(es) would not replay and became escalations"
  fi
else
  say "no fix confirmed, nothing pushed"
fi

write_back
