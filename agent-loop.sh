#!/bin/bash
#
# agent-loop.sh
#
# Polls a fixed list of GitHub repositories and dispatches Orca workers at
# anything workable. Started by hand, runs until Ctrl-C.
#
# This build carries the daemon skeleton — config loading and validation, the
# PID lock, Orca runtime readiness, logging, the pass loop — the issue phase,
# which claims workable `ready-for-agent` issues and dispatches an Orca worker
# at them, the worktree inventory, which answers who holds a branch and reclaims
# stale claims at startup, the PR phase, which dispatches a thread-triage worker
# at open pull requests carrying unresolved review threads, the seen-list, which
# keeps a thread I left silent out of eligibility until a new comment lands on
# it, the close-out phase, which ticks, closes and unclaims an issue once its
# pull request has merged, and the sweep, which removes the loop's own finished
# worktrees at the end of every pass.
#
# Usage:
#   ./agent-loop.sh [--once] [--config <path>]
#   ./agent-loop.sh --branch-report <branch> [--config <path>]
#
# Requires: jq, git, orca, gh-axi (authenticated against github.com)

set -euo pipefail

# The config lives beside the script, so the loop can be started from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${AGENT_LOOP_CONFIG:-$SCRIPT_DIR/agent-loop.config.json}"
LOG_MAX_BYTES="${AGENT_LOOP_LOG_MAX_BYTES:-5242880}"
RUNTIME_WAIT_SECONDS="${AGENT_LOOP_RUNTIME_WAIT_SECONDS:-60}"
# How long a reused terminal is given to finish booting its agent before the
# prompt is typed into it. Bounded, because the loop must never wait on a worker.
TUI_WAIT_MS="${AGENT_LOOP_TUI_WAIT_MS:-60000}"
ONCE=false
BRANCH_REPORT=""
LOG_PATH=""
# The seen-list as a JSON array, refilled at the top of every PR phase. Empty
# until then, so a thread eligibility check that runs before it is loaded
# filters nothing rather than dying on an unbound variable.
SEEN_JSON='[]'
# Reset at the top of every pass. Initialised here only because the close-out
# that runs before the first pass bumps it too, and `set -u` would kill it
# otherwise — what it counts before the first pass is discarded, which is why
# that close-out reports one line per issue rather than a total.
SKIPS=0

usage() {
  cat <<'EOF'
Usage: agent-loop.sh [--once] [--config <path>]
       agent-loop.sh --branch-report <branch> [--config <path>]

Polls the GitHub repositories in the config and dispatches Orca workers at
anything workable. Started by hand, runs until Ctrl-C.

Options:
  --once              Run exactly one pass and exit instead of looping.
  --branch-report <branch>
                      Report who holds <branch> in each configured project and
                      exit, without taking the lock or running a pass.
  --config <path>     Config file to read (default: agent-loop.config.json
                      beside this script).
  -h, --help          Show this message.

Environment overrides (for tests and troubleshooting):
  AGENT_LOOP_CONFIG                 default config path
  AGENT_LOOP_LOG_MAX_BYTES          log size cap before rotation (default 5 MiB)
  AGENT_LOOP_RUNTIME_WAIT_SECONDS   how long to wait for the Orca runtime (default 60)
  AGENT_LOOP_TUI_WAIT_MS            how long a reused terminal gets to boot its
                                    agent before the prompt is typed (default 60000)

Requires: jq, git, orca, gh-axi
EOF
}

require_tools() {
  local tool
  for tool in jq git orca gh-axi; do
    command -v "$tool" >/dev/null 2>&1 || die "required command not found on PATH: $tool"
  done
}

# --- gh-axi ------------------------------------------------------------------

# `gh_json`, `gh_graphql` and `gh_error_class` live in gh.sh, which
# pr-writeback.sh sources as well. They used to exist twice, once in each
# script, and the copies drifted far enough apart that one of them had never
# worked against real GitHub. One definition is what stops that recurring.
# shellcheck source=gh.sh
source "$SCRIPT_DIR/gh.sh"

# --- logging -----------------------------------------------------------------

# Every decision the loop makes is one line, on stdout and appended to the log
# file, so silence means nothing happened rather than something was swallowed.
log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  printf '%s\n' "$line"
  [[ -n "$LOG_PATH" ]] || return 0
  rotate_log
  printf '%s\n' "$line" >> "$LOG_PATH"
}

# Keep one generation. A loop left running for weeks must not fill the disk.
rotate_log() {
  [[ -f "$LOG_PATH" ]] || return 0
  local size
  size=$(wc -c < "$LOG_PATH" | tr -d ' ')
  (( size < LOG_MAX_BYTES )) && return 0
  mv -f "$LOG_PATH" "$LOG_PATH.1"
}

die() {
  log "fatal: $*"
  exit 1
}

# --- config ------------------------------------------------------------------

expand_tilde() {
  case "$1" in
    "~/"*) printf '%s' "$HOME/${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

require_field() {
  local name="$1" value="$2"
  [[ -n "$value" ]] || die "config is missing $name: $CONFIG_PATH"
}

require_positive_int() {
  local name="$1" value="$2"
  require_field "$name" "$value"
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] \
    || die "config $name must be a positive integer, got: $value"
}

load_config() {
  [[ -f "$CONFIG_PATH" ]] || die "config not found: $CONFIG_PATH"
  jq empty "$CONFIG_PATH" 2>/dev/null || die "config is not valid JSON: $CONFIG_PATH"

  POLL_INTERVAL=$(jq -r '.pollIntervalSeconds // empty' "$CONFIG_PATH")
  MAX_WORKERS=$(jq -r '.maxWorkers // empty' "$CONFIG_PATH")
  SEEN_LIST_PATH=$(expand_tilde "$(jq -r '.seenListPath // empty' "$CONFIG_PATH")")
  LABEL_READY=$(jq -r '.labels.ready // empty' "$CONFIG_PATH")
  LABEL_CLAIMED=$(jq -r '.labels.claimed // empty' "$CONFIG_PATH")
  PROJECT_COUNT=$(jq -r '.projects | length' "$CONFIG_PATH" 2>/dev/null || echo 0)

  require_positive_int pollIntervalSeconds "$POLL_INTERVAL"
  require_positive_int maxWorkers "$MAX_WORKERS"
  require_field seenListPath "$SEEN_LIST_PATH"
  # The daemon never writes the file — the workers do — but it is the daemon
  # that knows the path is configured, so it is the daemon that makes sure a
  # worker has somewhere to append to. A directory that will not be created is
  # not fatal: the seen-list is disposable, and a loop that cannot keep one is
  # a loop that re-triages, not a loop that stops.
  mkdir -p "$(dirname "$SEEN_LIST_PATH")" \
    || log "could not create the seen-list directory for: $SEEN_LIST_PATH"
  require_field labels.ready "$LABEL_READY"
  require_field labels.claimed "$LABEL_CLAIMED"
  [[ "$PROJECT_COUNT" -gt 0 ]] || die "config lists no projects: $CONFIG_PATH"

  # logPath is loaded last so that everything above can already report through
  # log() — it just has nowhere but stdout to go until this is set.
  local configured_log
  configured_log=$(expand_tilde "$(jq -r '.logPath // empty' "$CONFIG_PATH")")
  require_field logPath "$configured_log"
  mkdir -p "$(dirname "$configured_log")" || die "could not create log directory for: $configured_log"
  LOG_PATH="$configured_log"
}

# --- lock --------------------------------------------------------------------

# The lockfile lives beside the log. A second daemon must never race the first
# over the same tracker.
acquire_lock() {
  LOCK_PATH="$(dirname "$LOG_PATH")/agent-loop.pid"

  if ! write_lock; then
    local pid
    pid=$(cat "$LOCK_PATH" 2>/dev/null || true)
    # ponytail: liveness is `kill -0`, so a recycled pid reads as still running
    # and the operator has to delete the lockfile by hand. Store a start time
    # alongside the pid if that ever bites.
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "already running (pid $pid)"
      exit 1
    fi
    log "clearing stale lockfile (pid ${pid:-unknown})"
    rm -f "$LOCK_PATH"
    write_lock || die "could not take lockfile: $LOCK_PATH"
  fi

  trap release_lock EXIT
  # HUP as well as INT/TERM: closing the terminal a hand-started daemon lives in
  # must release the lock, not strand it.
  trap shutdown INT TERM HUP
}

# Create the lockfile only if it does not already exist, so the check and the
# claim are one atomic step rather than two racing ones.
write_lock() {
  set -o noclobber
  { printf '%s\n' "$$" > "$LOCK_PATH"; } 2>/dev/null
  local created=$?
  set +o noclobber
  return "$created"
}

release_lock() {
  [[ -n "${LOCK_PATH:-}" && -f "$LOCK_PATH" ]] || return 0
  [[ "$(cat "$LOCK_PATH" 2>/dev/null || true)" == "$$" ]] || return 0
  rm -f "$LOCK_PATH"
}

# Ctrl-C releases the lock and exits. Workers already dispatched keep running.
shutdown() {
  log "shutting down"
  [[ -n "${SLEEP_PID:-}" ]] && kill "$SLEEP_PID" 2>/dev/null || true
  release_lock
  exit 0
}

# --- validation --------------------------------------------------------------

# The repo list is read once: it resolves every configured orcaRepoId and it
# carries the on-disk path the worktree inventory runs git against.
load_repos() {
  ORCA_REPOS=$(orca repo list --json) || die "could not list Orca repos"
}

# The on-disk path of a registered repo, or nothing if the id is not one. Repo
# ids are unique, so this is at most one line.
repo_path() {
  jq -r --arg id "$1" '.result.repos[]? | select(.id == $id) | .path' <<< "$ORCA_REPOS"
}

# GitHub resolves an issue's labels by name, and a name that does not exist yet
# is not created for you — unlike GitLab, where first use was enough. So the
# loop's own two labels are made to exist once, at startup, in every repo it
# polls. Anything already there is left exactly as it is, colour included.
ensure_labels() {
  local repo="$1" existing label response
  response=$(gh_json "/repos/$repo/labels" --paginate) \
    || { log "could not list labels in $repo, assuming they exist"; return 0; }
  existing=$(jq -r '.[].name' <<< "$response")
  for label in "$LABEL_READY" "$LABEL_CLAIMED"; do
    grep -qxF "$label" <<< "$existing" && continue
    if gh-axi label create --name "$label" --color ededed \
         --description "agent-loop" --repo "$repo" >/dev/null 2>&1; then
      log "created label $label in $repo"
    else
      log "could not create label $label in $repo"
    fi
  done
}

# A typo must fail at second zero rather than silently narrowing what gets
# polled, so every project and every Orca repo id is resolved before the first
# pass runs.
validate_config() {
  local repo_ids
  repo_ids=$(jq -r '.result.repos[].id' <<< "$ORCA_REPOS")

  local i github orca_id
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    github=$(jq -r ".projects[$i].github // empty" "$CONFIG_PATH")
    orca_id=$(jq -r ".projects[$i].orcaRepoId // empty" "$CONFIG_PATH")
    [[ -n "$github" ]] || die "projects[$i] has no github path"
    [[ -n "$orca_id" ]] || die "projects[$i] ($github) has no orcaRepoId"

    # GitHub names a repository by `<owner>/<name>` everywhere — in the REST
    # path, in the GraphQL query and on the command line — so unlike GitLab
    # there is no second numeric identifier to resolve and carry around. The
    # read is still made, because a typo must fail here and not on the first
    # query of the first pass.
    gh_json "/repos/$github" >/dev/null 2>&1 \
      || die "project does not resolve: $github"
    grep -qxF "$orca_id" <<< "$repo_ids" \
      || die "orcaRepoId does not resolve: $orca_id ($github)"

    ensure_labels "$github"
    log "validated $github -> orca repo $orca_id"
  done
}

# The Orca repo id a configured GitHub repository maps to, or nothing when the
# config does not list it — which is how "not this loop's business" is said.
# Both global pull-request reads name repositories by `<owner>/<name>` and
# nothing else, so both come back through here.
orca_id_for_project() {
  local i
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    if [[ "$(jq -r ".projects[$i].github" "$CONFIG_PATH")" == "$1" ]]; then
      jq -r ".projects[$i].orcaRepoId" "$CONFIG_PATH"
      return 0
    fi
  done
}

# "My" pull requests come from `author:<me>`, so no identity lives in the config
# — but the thread rule does need a name to compare comment authors against, and
# it is the same identity the token already carries.
load_identity() {
  ME=$(gh_json /user | jq -r '.login // empty') \
    || die "could not resolve the GitHub identity behind this token"
  [[ -n "$ME" ]] || die "could not resolve the GitHub identity behind this token"
  log "acting as $ME"
}

# --- orca runtime ------------------------------------------------------------

runtime_reachable() {
  [[ "$(orca status --json 2>/dev/null | jq -r '.result.runtime.reachable // false')" == "true" ]]
}

# Re-checked before every pass: an Orca restart mid-run must not turn every
# later pass into a stream of failed dispatches.
ensure_runtime() {
  runtime_reachable && return 0
  log "orca runtime not reachable, starting it"
  orca open --json >/dev/null 2>&1 || log "orca open failed, waiting in case it comes up anyway"
  local waited=0
  while (( waited < RUNTIME_WAIT_SECONDS )); do
    if runtime_reachable; then
      log "orca runtime ready"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  die "orca runtime did not become ready within ${RUNTIME_WAIT_SECONDS}s"
}

# --- worktree inventory ------------------------------------------------------

# One `orca worktree ps` read, cached in ORCA_PS: the worker budget, the startup
# reclaim and the branch check all ask their question of the same snapshot. A
# failed read leaves the last good snapshot alone and returns non-zero, because
# "I could not look" and "nothing is running" must never read the same.
load_worktree_inventory() {
  local response
  response=$(orca worktree ps --json 2>/dev/null) || return 1
  jq -e '.result.worktrees' <<< "$response" >/dev/null 2>&1 || return 1
  ORCA_PS="$response"
}

# Every worktree Orca knows, one `<live|idle>\t<path>` line each. An agent that
# is `working` or `waiting` is live; `waiting` counts because a worker parked
# for my confirmation still holds its branch and owes me an answer — it is not
# finished. `orca terminal list` is not used for this: it cannot tell a busy
# terminal from an idle shell.
orca_worktrees() {
  jq -r '.result.worktrees[]?
    | select(.path != null)
    | [ (if any(.agents[]?.state; . == "working" or . == "waiting")
         then "live" else "idle" end), .path ]
    | @tsv' <<< "$ORCA_PS"
}

# Orca and git can name one directory differently — on macOS `/tmp` is a symlink
# to `/private/tmp` — so every path is resolved before it is compared. A path
# that does not exist is compared as written.
resolve_path() {
  if [[ -d "$1" ]]; then (cd "$1" && pwd -P); else printf '%s' "${1%/}"; fi
}

# worktree_state <path> — "live", "idle", or empty when Orca has no record of
# the directory at all.
worktree_state() {
  local target="" state path
  target=$(resolve_path "$1")
  while IFS=$'\t' read -r state path; do
    if [[ "$(resolve_path "$path")" == "$target" ]]; then
      printf '%s' "$state"
      return 0
    fi
  done < <(orca_worktrees)
}

# The loop signs its work in the only place that survives everything: the
# directory name. Ownership is asked here and nowhere else, so a worktree of
# mine can never be mistaken for one of the loop's.
is_loop_worktree() {
  [[ "${1##*/}" == agent-loop-* ]]
}

# count_live_workers <basename-regex> — live agents sitting in a worktree whose
# directory name matches.
count_live_workers() {
  local state path count=0
  while IFS=$'\t' read -r state path; do
    [[ "$state" == "live" ]] || continue
    if [[ "${path##*/}" =~ $1 ]]; then
      count=$((count + 1))
    fi
  done < <(orca_worktrees)
  printf '%s' "$count"
}

# maxWorkers is one budget for the whole loop rather than a quota per phase, so
# a quiet issue backlog leaves the capacity free for PR work. A worker is a
# worktree the loop created (`agent-loop-` prefix) whose agent is still going;
# `done` agents are finished work waiting to be swept, not spent budget.
count_active_workers() {
  count_live_workers '^agent-loop-'
}

# `git worktree list` is the authority on who holds a branch: it is local, it
# needs no Orca call, and it sees worktrees Orca does not manage. Prints the
# path of the worktree holding <branch>, nothing if the branch is free, and
# fails if git could not answer at all.
worktree_for_branch() {
  local repo="$1" branch="$2" porcelain
  porcelain=$(git -C "$repo" worktree list --porcelain) || return 1
  # No `exit` in the awk: it would close the pipe early and kill git with
  # SIGPIPE on a repo with enough worktrees to fill the buffer.
  awk -v want="branch refs/heads/$branch" '
    /^worktree /{ path = substr($0, 10) }
    $0 == want && !found { print path; found = 1 }
  ' <<< "$porcelain"
}

# branch_state <repo-path> <branch> — prints "<state>\t<path>", where state is
# one of:
#   free           nobody has it checked out
#   loop-live      a worktree the loop created, agent working or waiting
#   loop-done      a worktree the loop created, no agent still going
#   foreign-clean  a checkout the loop did not create, tree clean
#   foreign-dirty  a checkout the loop did not create, tree not clean
#   unknown        the question could not be answered — see below
#
# Cleanliness is part of the answer because the PR phase reuses a clean foreign
# worktree in place — normally my own checkout of a branch I was developing —
# and must never drop an agent on top of edits in progress. `unknown` exists so
# that a git that would not answer, or a loop worktree Orca has lost and can
# therefore no longer be reused by id, is never mistaken for a clean one.
branch_state() {
  local repo="$1" branch="$2" path dirty

  if ! path=$(worktree_for_branch "$repo" "$branch"); then
    printf 'unknown\t%s\n' "$repo"
    return 0
  fi

  if [[ -z "$path" ]]; then
    printf 'free\t\n'
    return 0
  fi

  if is_loop_worktree "$path"; then
    case "$(worktree_state "$path")" in
      live) printf 'loop-live\t%s\n' "$path" ;;
      idle) printf 'loop-done\t%s\n' "$path" ;;
      *)    printf 'unknown\t%s\n' "$path" ;;
    esac
    return 0
  fi

  if ! dirty=$(git -C "$path" status --porcelain); then
    printf 'unknown\t%s\n' "$path"
  elif [[ -n "$dirty" ]]; then
    printf 'foreign-dirty\t%s\n' "$path"
  else
    printf 'foreign-clean\t%s\n' "$path"
  fi
}

# --branch-report: answers "is anyone actually working on this branch?" for
# every configured project. It is a read, so it takes no lock and runs no pass,
# and it prints its answer rather than logging a decision.
branch_report() {
  local branch="$1" i github orca_id repo state path
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    github=$(jq -r ".projects[$i].github" "$CONFIG_PATH")
    orca_id=$(jq -r ".projects[$i].orcaRepoId" "$CONFIG_PATH")
    repo=$(repo_path "$orca_id")
    if [[ -z "$repo" ]]; then
      printf 'branch %s %s: unknown, orcaRepoId does not resolve: %s\n' "$branch" "$github" "$orca_id"
      continue
    fi
    IFS=$'\t' read -r state path < <(branch_state "$repo" "$branch")
    printf 'branch %s %s: %s%s\n' "$branch" "$github" "$state" "${path:+ $path}"
  done
}

# --- startup reclaim ---------------------------------------------------------

# The worktree a dispatch asked for is `agent-loop-<type>-<number>-<title-slug>`,
# and a name collision appends `-2` — so the number is anchored on both sides, or
# issue 1 would find issue 11's worker and stay claimed forever. The types are
# spelled out rather than matched as `[a-z]+`, which would let the PR phase's
# own `agent-loop-pr-17` answer for issue 17. `issue` is the name dispatches
# used before the type was part of it, and still names live workers.
ISSUE_BRANCH_TYPES='feat|fix|chore|docs|refactor|test|perf|build|ci|issue'

issue_has_live_worker() {
  [[ "$(count_live_workers '^agent-loop-('"$ISSUE_BRANCH_TYPES"')-'"$1"'(-.*)?$')" != "0" ]]
}

# The claim label is written before the dispatch, so a crash in between leaves an
# issue claimed with nobody on it. Startup hands every such issue back, which
# also tidies whatever Ctrl-C left orphaned — a leftover worktree strands
# nothing.
reclaim_stale_claims() {
  # A reclaim on an inventory we could not read would hand back issues that do
  # have workers, so an unreadable inventory skips the reclaim entirely.
  if ! load_worktree_inventory; then
    log "worker inventory unreadable, skipping startup reclaim"
    return 0
  fi

  local i github numbers number
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    github=$(jq -r ".projects[$i].github" "$CONFIG_PATH")
    if ! numbers=$(query_claimed_issues "$github"); then
      log "claimed-issue query failed: $github"
      continue
    fi
    # stdin is closed for the body: gh-axi must not swallow the issue list.
    while IFS= read -r number; do
      [[ -n "$number" ]] || continue
      if issue_has_live_worker "$number"; then
        log "left claimed $github#$number: a live worker holds it"
      elif release_issue "$github" "$number" < /dev/null; then
        log "reclaimed $github#$number: no live worker, returned to $LABEL_READY"
      else
        log "reclaim failed for $github#$number, leaving it claimed"
      fi
    done <<< "$numbers"
  done
}

# --- github issues -----------------------------------------------------------

# One GraphQL call per repository and label.
query_issues_by_label() {
  local github="$1" label="$2" owner="${1%%/*}" name="${1##*/}" response
  response=$(gh_graphql "{ repository(owner: \"$owner\", name: \"$name\") { issues(labels: [\"$label\"], states: OPEN, first: 100) { nodes { number title url labels(first: 20) { nodes { name } } } } } }") || return 1
  # A GraphQL error can come back as a 200 with a null repository, which would
  # otherwise read as "this repository has no matching issues".
  jq -e '.data.repository != null' <<< "$response" >/dev/null || return 1
  printf '%s' "$response"
}

# The change type is read off the issue's own labels, so the branch says what
# kind of change it is without anyone writing it twice. A scoped label counts by
# its last segment (`type::fix`), GitHub's own default labels are mapped onto
# the conventional-commit words, and an issue that says nothing is a `feat` —
# the type is a reading aid on a branch name, not a decision anything depends on.
#
# The title comes last: it is the only field that can carry whitespace, so the
# reader can take it as the remainder of the line.
query_ready_issues() {
  query_issues_by_label "$1" "$LABEL_READY" | jq -r '
    def change_type:
      [.labels.nodes[]?.name | ascii_downcase | sub("^.*::"; "")]
      | map(if . == "bug" then "fix"
            elif . == "feature" or . == "enhancement" then "feat"
            elif . == "documentation" then "docs"
            else . end)
      | map(select(IN("feat","fix","chore","docs","refactor","test","perf","build","ci")))
      | first // "feat";
    .data.repository.issues.nodes[]?
    | [.number, .url, change_type, (.title // "")] | @tsv'
}

query_claimed_issues() {
  query_issues_by_label "$1" "$LABEL_CLAIMED" | jq -r '.data.repository.issues.nodes[]?.number'
}

# GitHub has no "these issues block this one" field on the issue itself, so the
# blockers are a second read. It answers with the blocking issues themselves,
# which is what makes "still open" answerable — a closed blocker does not block.
#
# Prints the number of open blockers, and fails if the question could not be put
# at all. The caller treats that as a skip: dispatching at an issue that may be
# blocked is worse than looking again next pass.
count_open_blockers() {
  local response
  response=$(gh_json "/repos/$1/issues/$2/dependencies/blocked_by" --paginate) || return 1
  jq -e 'type == "array"' <<< "$response" >/dev/null 2>&1 || return 1
  jq -r '[.[] | select(.state == "open")] | length' <<< "$response"
}

# gh-axi changes labels as a delta — an add and a remove in one call — which is
# the same shape GitLab's add_labels/remove_labels had. So the swap stays a
# single atomic write, and neither the claim nor the reclaim has to know what
# else the issue is wearing. The raw REST route would not do: its PATCH replaces
# the label set outright, and it has no way to send an empty one.
swap_labels() {
  gh-axi issue edit "$2" --repo "$1" --add-label "$3" --remove-label "$4" >/dev/null 2>&1
}

# The label swap is the claim: it is what tells the next pass, and any second
# daemon, that this issue is taken.
claim_issue() { swap_labels "$1" "$2" "$LABEL_CLAIMED" "$LABEL_READY"; }
release_issue() { swap_labels "$1" "$2" "$LABEL_READY" "$LABEL_CLAIMED"; }

# --- issue phase -------------------------------------------------------------

# The change type and title become the readable half of the worktree — and
# therefore branch — name: `agent-loop-fix-17-login-timeout-retry` says what the
# branch is for in every `git branch` listing and pull request. Kept short so
# the branch stays typeable, and lowercase alphanumerics only so it survives
# Orca's own slugify unchanged — Orca turns anything else, `/` included, into a
# dash, so a `fix/17-...` name is not on offer.
issue_slug() {
  local slug
  slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')
  slug=$(printf '%s' "$slug" | tr -s '-')
  slug="${slug#-}"
  slug="${slug:0:40}"
  printf '%s' "${slug%-}"
}

# The prompt is the issue URL and nothing else — the issue stays the single
# source of what to build.
dispatch_issue() {
  local orca_id="$1" number="$2" weburl="$3" type="$4" title="$5" slug response
  slug=$(issue_slug "$title")
  response=$(orca worktree create \
    --repo "id:$orca_id" \
    --name "agent-loop-$type-$number${slug:+-$slug}" \
    --no-parent \
    --agent claude \
    --prompt "/implement $weburl" \
    --json) || return 1
  # The requested name is slugified and a collision silently yields <name>-2, so
  # the handle is always read back from the response.
  jq -r '.result.worktree.id // empty' <<< "$response" | grep . || return 1
}

issue_phase() {
  local i github orca_id
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    github=$(jq -r ".projects[$i].github" "$CONFIG_PATH")
    orca_id=$(jq -r ".projects[$i].orcaRepoId" "$CONFIG_PATH")
    issue_phase_project "$github" "$orca_id"
  done
}

issue_phase_project() {
  local github="$1" orca_id="$2" issues number weburl type title blockers worktree_id

  # ponytail: the CLI's own error text goes to stderr, so it reaches the
  # terminal but not the log file. Capture it into the log line if reading the
  # log alone ever has to be enough.
  if ! issues=$(query_ready_issues "$github"); then
    log "issue query failed: $github"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  # stdin is closed for the body: gh-axi must not swallow the issue list.
  while IFS=$'\t' read -r number weburl type title; do
    [[ -n "$number" ]] || continue

    if ! blockers=$(count_open_blockers "$github" "$number" < /dev/null); then
      log "issue $github#$number skipped: could not read its blockers"
      SKIPS=$((SKIPS + 1))
      continue
    fi
    if (( blockers > 0 )); then
      log "issue $github#$number skipped: blocked by $blockers open blocker"
      SKIPS=$((SKIPS + 1))
      continue
    fi

    # Checked before every dispatch, not once per pass: each dispatch spends a
    # slot, and a candidate that arrives at a full budget waits for a later pass
    # rather than being dropped.
    if (( ACTIVE_WORKERS >= MAX_WORKERS )); then
      log "issue $github#$number deferred: worker budget full ($ACTIVE_WORKERS/$MAX_WORKERS)"
      SKIPS=$((SKIPS + 1))
      continue
    fi

    if ! claim_issue "$github" "$number" < /dev/null; then
      log "claim failed for $github#$number, leaving it ready"
      SKIPS=$((SKIPS + 1))
      continue
    fi
    log "claimed $github#$number"

    # The claim is already written, so a failed dispatch leaves the issue
    # claimed with no worker. Startup reclaim hands it back.
    if ! worktree_id=$(dispatch_issue "$orca_id" "$number" "$weburl" "$type" "$title" < /dev/null); then
      log "dispatch failed for $github#$number, issue left claimed"
      SKIPS=$((SKIPS + 1))
      continue
    fi

    log "dispatched $github#$number -> worktree $worktree_id"
    ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
    DISPATCHES=$((DISPATCHES + 1))
  done <<< "$issues"
}

# --- worktree sweep ----------------------------------------------------------

# Worktrees the PR phase dropped a fresh worker into this pass. The sweep reads
# the snapshot the pass opened with, where such a worktree is still the `done`
# one it was a moment ago — without this it would remove a checkout that has a
# worker in it, which is the one thing the sweep must never do.
sweep_exempt() {
  grep -qxF "$(resolve_path "$1")" <<< "$SWEEP_EXEMPT"
}

# Orca reaps nothing, so each pass ends with the loop sweeping up after itself.
# A worktree is removed only when the loop created it, its agent has finished,
# its tree is clean, and everything committed is on the remote. Anything else is
# left exactly where it is, with a line saying why.
sweep_worktrees() {
  local state path dirty unpushed
  while IFS=$'\t' read -r state path; do
    # Ownership is asked first: a worktree of mine is out of scope before any
    # other question is put to it, and before git is run against it at all.
    is_loop_worktree "$path" || continue

    if sweep_exempt "$path"; then
      log "sweep skipped $path: a worker was dispatched into it this pass"
      continue
    fi

    if [[ "$state" == "live" ]]; then
      log "sweep skipped $path: its agent is still going"
      continue
    fi

    if ! dirty=$(git -C "$path" status --porcelain 2>/dev/null); then
      log "sweep skipped $path: could not read its status"
      continue
    fi
    if [[ -n "$dirty" ]]; then
      log "sweep skipped $path: uncommitted changes"
      continue
    fi

    # Commits on HEAD that no origin branch carries. The comparison is against
    # the remote branches themselves rather than `@{upstream}`: an Orca checkout
    # has no upstream configured, so the usual upstream comparison would answer
    # "nothing to push" for a worktree whose commits are only local. Asking about
    # every origin branch rather than one named ref also keeps a
    # merged-and-deleted branch sweepable instead of pinned forever.
    #
    # ponytail: the remote is assumed to be `origin`. Read it off the branch's
    # config if a repo with a differently named remote ever goes through the loop.
    if ! unpushed=$(git -C "$path" rev-list --count HEAD --not --remotes=origin 2>/dev/null); then
      log "sweep skipped $path: could not read its push state"
      continue
    fi
    if (( unpushed > 0 )); then
      log "sweep skipped $path: $unpushed commits not on the remote"
      continue
    fi

    # No --force: the removal refuses a dirty tree outright and preserves a
    # branch that carries commits, and the checks above are belt and braces on
    # top of that. What it removes goes to a trash directory, not to nothing.
    #
    # ponytail: the CLI's own error text goes to stderr and is dropped here.
    # Capture it into the log line if a refused removal ever needs explaining.
    if orca worktree rm --worktree "path:$path" --json >/dev/null 2>&1; then
      log "swept $path"
      SWEEPS=$((SWEEPS + 1))
    else
      log "sweep failed for $path, leaving it in place"
    fi
  done < <(orca_worktrees)
}

# --- pr phase ----------------------------------------------------------------

# One global read. `author:<me>` resolves "mine" from the identity behind the
# token, so no repository needs a local checkout and adding a project costs a
# config line — the list is narrowed to the configured repositories by
# `nameWithOwner` afterwards.
query_open_prs() {
  local response
  response=$(gh_graphql "{ search(query: \"is:pr is:open author:$ME sort:updated-desc\", type: ISSUE, first: 100) { nodes { ... on PullRequest { number title url headRefName repository { nameWithOwner } } } } }") || return 1
  jq -e '.data.search.nodes | type == "array"' <<< "$response" >/dev/null 2>&1 || return 1
  # The title comes last: it is the only field that can carry whitespace, so the
  # reader can take it as the remainder of the line.
  jq -r '.data.search.nodes[]
    | select(.number != null)
    | [.repository.nameWithOwner, .number, .headRefName, .url, (.title // "")]
    | @tsv' <<< "$response"
}

# The seen-list as one JSON array, read fresh at the top of every PR phase: the
# workers dispatched by earlier passes append to it while the loop sleeps.
#
# It is disposable by design, so every way of failing to read it lands in the
# same place — an empty array, a line saying so, and a pass that filters nothing.
# A single malformed line costs the whole file, which is one repeated sweep of
# pull requests that were already triaged and nothing worse.
load_seen_list() {
  SEEN_JSON='[]'
  [[ -e "$SEEN_LIST_PATH" ]] || return 0
  SEEN_JSON=$(jq -s '.' "$SEEN_LIST_PATH" 2>/dev/null) && return 0
  SEEN_JSON='[]'
  log "seen-list unreadable, filtering nothing this pass: $SEEN_LIST_PATH"
}

# A thread is eligible when it is still unresolved, I have never spoken in it —
# once I have replied it is a human conversation and permanently off-limits —
# and no seen entry says a worker already triaged it and left it silent. Draft
# pull requests are not filtered anywhere: draft is a merge gate, not a review
# gate.
#
# GitHub's review threads need no `individual_note` test the way GitLab's
# discussions did: a plain PR comment is not a review thread at all and never
# appears here.
#
# The seen entry has to name the thread's newest comment as well as the thread,
# so the filter lapses the moment a reviewer replies: new information reopens
# the case.
count_eligible_threads() {
  local github="$1" number="$2" owner="${1%%/*}" name="${1##*/}" response
  response=$(gh_graphql "{ repository(owner: \"$owner\", name: \"$name\") { pullRequest(number: $number) { reviewThreads(first: 100) { nodes { id isResolved comments(first: 100) { nodes { databaseId author { login } } } } } } } }") || return 1
  jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' <<< "$response" \
    >/dev/null 2>&1 || return 1
  jq --arg me "$ME" --arg project "$github" --argjson pr "$number" --argjson seen "$SEEN_JSON" '
    [ .data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved != true)
      | select(all(.comments.nodes[]?; .author.login != $me))
      | . as $thread
      | ([$thread.comments.nodes[]?.databaseId] | max) as $last
      | select(
          $seen
          | any(.project == $project
                and .pr == $pr
                and .thread == $thread.id
                and .lastCommentId == $last)
          | not)
    ] | length' <<< "$response"
}

# Everything the loop leaves on disk for one PR worker — its brief and, later,
# the plan the worker writes — lives beside the log rather than in the checkout.
# A linked worktree's `.git` is a file, not a directory, so there is nowhere
# inside the checkout to put them that git will not notice.
pr_work_path() {
  printf '%s/agent-loop-pr-%s-%s' "$(dirname "$LOG_PATH")" "$1" "$2"
}

# The worker's whole brief. Both dispatch paths deliver this same text: a fresh
# worktree takes it as `--prompt`, a reused one reads it from a file.
#
# The rule it is built around is that the worker proposes and I dispose — so the
# only thing here that may write to GitHub is pr-writeback.sh, run against a
# plan I have confirmed.
pr_worker_prompt() {
  local weburl="$1" branch="$2" github="$3" number="$4"
  local owner="${3%%/*}" name="${3##*/}" plan
  plan=$(pr_work_path "$number" plan.json)
  cat <<EOF
Triage the review threads on pull request $weburl.

Its head branch \`$branch\` is already checked out in this worktree. The
repository is $github and the pull request number is $number.

List the threads with:

    gh-axi api POST /graphql --field query='{ repository(owner: "$owner", name: "$name") { pullRequest(number: $number) { reviewThreads(first: 100) { nodes { id isResolved isOutdated path line comments(first: 100) { nodes { databaseId author { login } body diffHunk } } } } } } }'

A readable summary of the same review, if you want the diff alongside it:

    gh-axi pr view $number --repo $github --reviews

A thread is eligible when \`isResolved\` is false and **no comment in it was
authored by \`$ME\`** — once $ME has spoken in a thread it is a human
conversation and is permanently off-limits to you. Work every eligible thread,
oldest first. Draft pull requests are in scope.

Record \`git rev-parse HEAD\` before you change anything; that is the plan's
\`baseSha\`. For each thread, record its node \`id\` as the plan's \`thread\`,
and the \`databaseId\` of its newest comment as that thread's
\`lastCommentId\`; the loop uses it to notice when a reviewer has replied to a
thread you left silent.

Give each eligible thread exactly one verdict:

- **FIX** — it names a concrete, contained change in the diff. Make the change.
  Run the repo's existing checks (lint, typecheck, tests as the repo provides)
  scoped to the code you touched. Commit it as one commit for that thread alone,
  with a message naming the thread's concern, and record the sha. Write one
  sentence saying what changed. If the checks fail and you cannot fix that, drop
  the commit and make the thread an ESCALATE instead.
- **REFUSE** — the premise is wrong: it misreads the code, it is already handled
  elsewhere, or it describes behaviour the diff does not have. Draft the reply
  \`**Disagree** — <reasoning and the evidence for it>\`. A REFUSE is never
  resolved.
- **ANSWER** — it asks a question about intent, scope or consequence and asks
  for no change. Prepare nothing.
- **ESCALATE** — it is valid but needs a decision above you, or is too large for
  this session. Prepare nothing.

While you prepare, these are absolute:

- Push nothing. Write nothing to GitHub — no comment, no resolve, no
  \`gh-axi api POST/PATCH/PUT/DELETE\`, no \`gh-axi pr/issue\` subcommand that
  writes (\`comment\`, \`edit\`, \`review\`, \`merge\`, \`close\`), and no GraphQL
  \`mutation\` of any kind.
- Never force-push and never rebase.
- Stay inside the pull request's diff unless a fix genuinely requires otherwise.
- Leave the worktree clean: everything you change is committed.

Then write your plan to \`$plan\`:

    {
      "repo": "$github",
      "prNumber": $number,
      "sourceBranch": "$branch",
      "baseSha": "<the sha you recorded>",
      "threads": [
        { "thread": "<node id>", "verdict": "FIX", "lastCommentId": <newest comment databaseId>,
          "commit": "<sha>", "summary": "<one sentence>", "confirmed": false },
        { "thread": "<node id>", "verdict": "REFUSE", "lastCommentId": <newest comment databaseId>,
          "reply": "**Disagree** — ...", "confirmed": false },
        { "thread": "<node id>", "verdict": "ANSWER", "lastCommentId": <newest comment databaseId>,
          "confirmed": false }
      ]
    }

Then stop and show me one table covering **every** thread you saw: the thread,
its verdict, the local commit sha if it has one, and the exact reply text you
propose to post. Ask me to confirm. I may confirm everything, a subset, or
nothing.

Set \`"confirmed": true\` on exactly what I confirm and nothing else, then run:

    "$SCRIPT_DIR/pr-writeback.sh" --plan "$plan" --seen-list "$SEEN_LIST_PATH"

That script is the only thing that pushes or writes to GitHub. It replays only
the confirmed fixes onto \`baseSha\`, pushes once to \`$branch\`, posts the
confirmed replies, and resolves only the confirmed fixes — a rejected fix has
its commit dropped and comes back as an escalation — so a fix's posted reply
cites the sha as it landed, which differs from the local one only when something
was rejected. If I confirm nothing, run it anyway with nothing marked confirmed;
the pull request stays exactly as it is, and it still records the threads I left
silent so the loop stops sending workers back at them until a reply lands.

Report what it printed and stop. Do not push, reply or resolve by any other
means.
EOF
}

# A free branch gets a fresh checkout. `--base-branch` is only safe here because
# the claim check has already established that nobody holds the branch: if it is
# held elsewhere, Orca silently cuts a new branch named after the directory and
# reports success.
#
# The name is the directory's alone — the checkout lands on the pull request's
# existing branch, so the title slug here buys a readable `orca worktree ps` and
# changes no branch. `pr` stays where an issue dispatch puts its change type, so
# a review worktree is never mistaken for the worker on the issue of that number.
dispatch_pr_fresh() {
  local orca_id="$1" number="$2" branch="$3" prompt="$4" title="$5" slug response
  slug=$(issue_slug "$title")
  response=$(orca worktree create \
    --repo "id:$orca_id" \
    --name "agent-loop-pr-$number${slug:+-$slug}" \
    --no-parent \
    --base-branch "$branch" \
    --agent claude \
    --prompt "$prompt" \
    --json) || return 1
  jq -r '.result.worktree.id // empty' <<< "$response" | grep . || return 1
}

# A branch that is already checked out — by a finished loop worker or by my own
# hand — gets a new agent terminal in the worktree that holds it, never a second
# checkout.
#
# The brief goes to disk and the terminal is sent one line pointing at it.
# Verified: `terminal send` writes its text to the pty raw, so every newline in
# it lands as a press of Enter — a multi-line brief would submit its first line
# and then feed the agent the remaining hundred as separate messages.
#
# The terminal also gets a bounded moment to finish booting first, or the line
# lands in a TUI that is not listening yet.
dispatch_pr_reuse() {
  local path="$1" number="$2" prompt="$3" brief response handle
  brief=$(pr_work_path "$number" prompt.md)
  printf '%s\n' "$prompt" > "$brief" || return 1
  response=$(orca terminal create --worktree "path:$path" --command claude --json) || return 1
  handle=$(jq -r '.result.terminal.handle // empty' <<< "$response")
  [[ -n "$handle" ]] || return 1
  orca terminal wait --terminal "$handle" --for tui-idle --timeout-ms "$TUI_WAIT_MS" --json \
    >/dev/null 2>&1 || true
  orca terminal send --terminal "$handle" \
    --text "Read $brief and do exactly what it says." --enter --json >/dev/null || return 1
  printf '%s' "$handle"
}

pr_phase() {
  local prs github number branch weburl title
  load_seen_list
  if ! prs=$(query_open_prs); then
    log "pr query failed"
    SKIPS=$((SKIPS + 1))
    return 0
  fi
  # stdin is closed for the body: gh-axi and orca must not swallow the PR list.
  while IFS=$'\t' read -r github number branch weburl title; do
    [[ -n "$github" && -n "$number" ]] || continue
    pr_phase_one "$github" "$number" "$branch" "$weburl" "$title" < /dev/null
  done <<< "$prs"
}

pr_phase_one() {
  local github="$1" number="$2" branch="$3" weburl="$4" title="$5"
  local orca_id="" repo eligible state path prompt handle worktree_id

  # A pull request in a repository the config does not list is not this loop's
  # business, and there is no Orca repo id to build a worktree from either.
  orca_id=$(orca_id_for_project "$github")
  [[ -n "$orca_id" ]] || return 0

  if ! eligible=$(count_eligible_threads "$github" "$number"); then
    log "thread query failed: $github#$number"
    SKIPS=$((SKIPS + 1))
    return 0
  fi
  if [[ "$eligible" == "0" ]]; then
    log "pr $github#$number skipped: no eligible threads"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  repo=$(repo_path "$orca_id")
  if [[ -z "$repo" ]]; then
    log "pr $github#$number skipped: orcaRepoId does not resolve: $orca_id"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  # The claim is the checkout: whoever holds the branch decides what happens.
  IFS=$'\t' read -r state path < <(branch_state "$repo" "$branch")
  case "$state" in
    loop-live)
      log "pr $github#$number skipped: branch $branch held by a live worker ($path)"
      SKIPS=$((SKIPS + 1))
      return 0
      ;;
    foreign-dirty)
      log "pr $github#$number skipped: branch $branch held by a worktree with uncommitted changes ($path)"
      SKIPS=$((SKIPS + 1))
      return 0
      ;;
    unknown)
      log "pr $github#$number skipped: could not determine who holds branch $branch"
      SKIPS=$((SKIPS + 1))
      return 0
      ;;
  esac

  # Checked here rather than once per pass: each dispatch spends a slot, and a
  # candidate arriving at a full budget waits for a later pass.
  if (( ACTIVE_WORKERS >= MAX_WORKERS )); then
    log "pr $github#$number deferred: worker budget full ($ACTIVE_WORKERS/$MAX_WORKERS)"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  prompt=$(pr_worker_prompt "$weburl" "$branch" "$github" "$number")

  if [[ "$state" == "free" ]]; then
    if ! worktree_id=$(dispatch_pr_fresh "$orca_id" "$number" "$branch" "$prompt" "$title"); then
      log "dispatch failed for pr $github#$number"
      SKIPS=$((SKIPS + 1))
      return 0
    fi
    log "dispatched pr $github#$number ($eligible eligible threads) -> worktree $worktree_id"
  else
    if ! handle=$(dispatch_pr_reuse "$path" "$number" "$prompt"); then
      log "dispatch failed for pr $github#$number, reusing $path"
      SKIPS=$((SKIPS + 1))
      return 0
    fi
    log "dispatched pr $github#$number ($eligible eligible threads) -> terminal $handle in $path"
    SWEEP_EXEMPT+="$(resolve_path "$path")"$'\n'
  fi

  ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))
  DISPATCHES=$((DISPATCHES + 1))
}

# --- close-out phase ---------------------------------------------------------

# Merged pull requests, the same one global read as the open-PR query: no
# repository needs a local checkout, and the list is narrowed to the configured
# repositories by `nameWithOwner` afterwards.
#
# ponytail: one page, so an issue whose pull request has fallen past the 100
# most recently updated merges is never closed out. Page, or filter on
# `updated:>`, if a loop ever falls that far behind.
query_merged_prs() {
  local response
  response=$(gh_graphql "{ search(query: \"is:pr is:merged author:$ME sort:updated-desc\", type: ISSUE, first: 100) { nodes { ... on PullRequest { number headRefName repository { nameWithOwner } } } } }") || return 1
  jq -e '.data.search.nodes | type == "array"' <<< "$response" >/dev/null 2>&1 || return 1
  jq -r '.data.search.nodes[]
    | select(.number != null)
    | [.repository.nameWithOwner, .number, .headRefName] | @tsv' <<< "$response"
}

# The branch is the link between a pull request and the issue it came from: the
# description is the worker's to write and carries no reliable trailer, but a
# dispatch at issue 17 works in `agent-loop-fix-17-<title-slug>` and the branch
# keeps that name long after the worktree is swept. The number is anchored on
# both sides — a known type before it, `-` or end of name after it — or issue
# 11's pull request would close issue 1. Everything past the number is the title
# slug and the `-2` a name collision appends, and neither is read.
# Orca namespaces the branches it cuts — a worktree named
# `agent-loop-fix-17-login-timeout` lands on `<owner>/agent-loop-fix-17-login-timeout`
# — so an optional leading path is allowed before the name the dispatch asked
# for. Everything after the last `/` is anchored exactly as before, and a branch
# whose *last* segment does not carry the name still matches nothing.
issue_for_branch() {
  [[ "$1" =~ ^([^/]+/)*agent-loop-($ISSUE_BRANCH_TYPES)-([0-9]+)(-.*)?$ ]] || return 1
  printf '%s' "${BASH_REMATCH[3]}"
}

# One REST read: state, labels and body in a single call, because all three are
# needed and each one alone decides nothing.
#
# GitHub numbers issues and pull requests out of one sequence and answers both
# on the issues endpoint, so a `pull_request` key means the number names a pull
# request rather than the issue the branch claimed — and nothing on it is the
# loop's to touch.
query_issue() {
  local github="$1" number="$2" response
  response=$(gh_json "/repos/$github/issues/$number") || return 1
  jq -e 'type == "object" and has("state") and (has("pull_request") | not)' <<< "$response" \
    >/dev/null 2>&1 || return 1
  printf '%s' "$response"
}

# GitHub has no per-checkbox API, so ticking one box means rewriting the whole
# body. Nothing else in it is the loop's to touch.
# The body is the one thing that goes over as a file rather than as a --field:
# it is free text, and gh-axi would reinterpret a body that happened to look
# like JSON as JSON. A file has nothing left to reinterpret.
#
# ponytail: `issue edit --body-file` may normalise the file's trailing newline.
# It costs one cosmetic byte on an issue that is closed in the same breath and
# never read again; revisit if a body write ever has to survive a re-read.
update_description() {
  local github="$1" number="$2" file status
  file="$(dirname "$LOG_PATH")/agent-loop-body-$number.md"
  printf '%s' "$3" > "$file" || return 1
  gh-axi issue edit "$number" --repo "$github" --body-file "$file" >/dev/null 2>&1
  status=$?
  rm -f "$file"
  return "$status"
}

# The close and the unclaim are two calls, because gh-axi closes an issue and
# edits its labels through different subcommands. So the order is the whole
# guarantee. Closing first means a failed unclaim leaves a closed issue still
# wearing the claim label: untidy, and inert, because every query the loop makes
# asks for open issues alone. Unclaiming first would mean a failed close leaves
# an open issue wearing neither label — work the loop has quietly forgotten.
close_issue() {
  local github="$1" number="$2"
  gh-axi issue close "$number" --repo "$github" >/dev/null 2>&1 || return 1
  gh-axi issue edit "$number" --repo "$github" --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1 \
    || log "unclaim failed for $github#$number, leaving the label on a closed issue"
}

# Every checkbox on the checklist, ticked. Anchored at the start of its line,
# because that is the only place GitHub counts one — a `- [ ]` inside a code
# span or mid-sentence is prose, and rewriting it would change a byte that is
# not the loop's to change.
tick_checklist() {
  sed 's/^\([[:space:]]*\)- \[ \]/\1- [x]/'
}

closeout_phase() {
  local prs github prnumber branch
  if ! prs=$(query_merged_prs); then
    log "merged-pr query failed"
    SKIPS=$((SKIPS + 1))
    return 0
  fi
  # stdin is closed for the body: gh-axi must not swallow the PR list.
  while IFS=$'\t' read -r github prnumber branch; do
    [[ -n "$github" && -n "$branch" ]] || continue
    closeout_one "$github" "$prnumber" "$branch" < /dev/null
  done <<< "$prs"
}

closeout_one() {
  local github="$1" prnumber="$2" branch="$3"
  local number issue description ticked

  # A branch that names no issue is a pull request I opened by hand.
  number=$(issue_for_branch "$branch") || return 0

  # A pull request in a repository the config does not list is not the loop's
  # business.
  [[ -n "$(orca_id_for_project "$github")" ]] || return 0

  if ! issue=$(query_issue "$github" "$number"); then
    log "close-out query failed: $github#$number"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  # An issue that is already closed, or one I claimed by hand, is not the
  # loop's to touch — and every merged pull request is read again on every
  # pass, so saying so would be the same line forever. Both leave silently.
  [[ "$(jq -r '.state' <<< "$issue")" == "open" ]] || return 0
  # `$label` would be a jq keyword, so the claim label rides in as `$claimed`.
  jq -e --arg claimed "$LABEL_CLAIMED" 'any(.labels[]?.name; . == $claimed)' <<< "$issue" \
    >/dev/null || return 0

  # The trailing newlines a body ends with are part of it: `-j` stops jq adding
  # one of its own, and the sentinel stops command substitution eating the ones
  # that were already there.
  description=$(jq -j '.body // ""' <<< "$issue"; printf x)
  description="${description%x}"
  # The merge is the acceptance: what review took is what gets ticked.
  ticked=$(printf '%s' "$description" | tick_checklist; printf x)
  ticked="${ticked%x}"
  # Nothing left to tick is no write at all, rather than an identical rewrite
  # every pass.
  if [[ "$ticked" != "$description" ]]; then
    update_description "$github" "$number" "$ticked" \
      || log "checklist update failed for $github#$number, closing it anyway"
  fi

  # The close is what stops the re-dispatch, so it happens whatever the
  # description write did: a lost tick costs a wrong-looking checklist, a lost
  # close costs a duplicate worker.
  if close_issue "$github" "$number"; then
    log "closed out $github#$number: pull request #$prnumber merged"
  else
    log "close failed for $github#$number, leaving it claimed"
    SKIPS=$((SKIPS + 1))
  fi
}

# --- pass --------------------------------------------------------------------

run_pass() {
  log "pass start"
  DISPATCHES=0
  SKIPS=0
  SWEEPS=0
  SWEEP_EXEMPT=""
  # A budget that failed open would dispatch a fresh maxWorkers on top of the
  # workers it failed to see.
  local inventory=true
  if load_worktree_inventory; then
    ACTIVE_WORKERS=$(count_active_workers)
  else
    inventory=false
    log "worker inventory unreadable, treating the budget as full for this pass"
    ACTIVE_WORKERS="$MAX_WORKERS"
  fi
  # Close-out first: an issue whose pull request has merged must be off the
  # board before the issue phase looks at the backlog again.
  closeout_phase
  issue_phase
  pr_phase
  if $inventory; then
    # The snapshot is the one the pass opened with, so a worker that finished
    # mid-pass is swept by the next pass rather than this one.
    sweep_worktrees
  else
    log "worker inventory unreadable, skipping the sweep"
  fi
  log "pass end dispatches=$DISPATCHES skips=$SKIPS sweeps=$SWEEPS"
}

# --- main --------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) ONCE=true; shift ;;
    --branch-report) BRANCH_REPORT="${2:-}"; [[ -n "$BRANCH_REPORT" ]] || die "--branch-report needs a branch"; shift 2 ;;
    --config) CONFIG_PATH="${2:-}"; [[ -n "$CONFIG_PATH" ]] || die "--config needs a path"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

require_tools
load_config

# A report is a read: it must answer while the daemon is running, so it never
# takes the lock — and it never writes the daemon's log either, or a report run
# by hand could rotate that log out from under the daemon.
if [[ -n "$BRANCH_REPORT" ]]; then
  LOG_PATH=""
  ensure_runtime
  load_repos
  load_worktree_inventory || die "could not read the Orca worktree inventory"
  branch_report "$BRANCH_REPORT"
  exit 0
fi

acquire_lock
# The runtime comes up before validation, not after: validation resolves every
# orcaRepoId against `orca repo list`, and a down runtime would make a correct
# config look like a stale id.
ensure_runtime
load_repos
validate_config
load_identity
# Before the reclaim, not after: the reclaim hands back every claim with no live
# worker, and a merged issue whose worktree has already been swept is exactly
# that — so closing it out first is what stops it being dispatched a second time.
closeout_phase
reclaim_stale_claims

while true; do
  ensure_runtime
  run_pass
  if $ONCE; then
    break
  fi
  log "sleeping ${POLL_INTERVAL}s"
  # Sleep in the background and wait on it, so a signal is handled the moment it
  # arrives instead of at the end of the interval.
  sleep "$POLL_INTERVAL" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=""
done
