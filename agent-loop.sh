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
# stale claims at startup, the PR phase, which is a reducer rather than a
# dispatcher: it enumerates every open pull request in every configured
# repository, derives that pull request's state from GitHub alone, logs it,
# asks CodeRabbit to fix its own findings, and puts the ones that are ready to
# judge through the risk gate — four vetoes over one head commit, three
# outcomes, and at most one merge per repository per pass, the close-out phase,
# which ticks, closes and unclaims an issue once its pull request has merged,
# and the sweep, which removes the loop's own finished worktrees at the end of
# every pass.
#
# The PR phase keeps **no local state at all**. Every pass re-derives from a
# fresh read, which is what makes "GitHub is the state store" true rather than
# aspirational: the loop survives a crash, a `--once` run and a machine rebuild
# for free, and the log line it prints per pull request is the only record a
# wait leaves.
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
ONCE=false
BRANCH_REPORT=""
LOG_PATH=""
# Holds the one irreversible write and nothing else. A flag rather than a config
# key on purpose: a persistent switch would be the confirmation gate this whole
# effort replaced walking back in as a boolean, and a `false` left in a file is a
# forgettable bypass. A flag is scoped to one invocation, grants nothing, and
# only withholds. With `--once` it is a genuine dry run.
NO_MERGE=false

# What the PR phase recognises on GitHub. Every constant in this stanza is
# CodeRabbit's surface rather than the loop's, and every one of them is an
# undocumented HTML marker or product string, so they are spelled once, here,
# where a change to any of them is one edit.
#
# The autofix trigger is spelled a second time in pr-writeback.sh, and the two
# copies are not a duplication to collapse. The seam owns what is *written* —
# its own constant, so a typo is an argument error rather than a silent no-op.
# This one is what the loop *recognises*, and it deliberately matches more: a
# trigger the operator typed into the GitHub UI by hand is an autofix in flight
# exactly as much as one the seam posted, and the loop must see it or it will
# fire a second run on top of it.
AUTOFIX_TRIGGER='@coderabbitai autofix'
AUTOFIX_STATUS_MARKER='<!-- This is an auto-generated comment: autofix status by CodeRabbit -->'
# The review nudge, and it is the **incremental** review command rather than the
# resume one. That is the measured choice: it demonstrably cleared a real
# four-and-a-half-hour wedge, and both of its reply shapes are on record.
#
# It exists because the cause that wedges a review does not clear on its own —
# CodeRabbit auto-pauses incremental reviews after five reviewed commits, and
# the counter resets **only when the pause is lifted**, which is a command. So
# *wait longer* was never an exit; the loop has to write.
#
# Spelled twice for the same reason the autofix trigger is: the seam owns what
# is written, this owns what the loop recognises. The failure the second copy
# guards against is worse here than there — a loop that posted one string and
# looked for another would nudge every pass forever, having never once
# recognised what it had already said.
REVIEW_TRIGGER='@coderabbitai review'
# The walkthrough comment, and the two things the risk gate reads out of it.
#
# The walkthrough is the comment CodeRabbit *edits* rather than replaces, which
# is why both of the gate's reads live in one body and why freshness anywhere
# near it is the **updated** timestamp: observed gaps of five and seven days sit
# between a walkthrough's creation and the edit that carries today's verdict.
#
# The rate-limit marker is tested **every pass regardless of timestamp**, and
# ahead of every veto. It arrives by that same edit, so there is no timestamp
# that could gate the test without missing it; and a throttled pull request
# keeps a *stale* verdict, which V1 would read as CodeRabbit changing shape and
# hand over permanently. The rate limit self-clears as usage ages out, so the
# defer it produces is the one thing in the gate exempt from the gate clock.
WALKTHROUGH_MARKER='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->'
RATE_LIMIT_MARKER='<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->'
# The merge-risk verdict, delimited inside the walkthrough. Its shape is
# `**Merge Risk:** _<emoji> <Level>_ · up to \`<abbrev>\`` — and the abbreviation
# is **five** characters on every capture taken, not the seven the prose around
# this feature says, which is exactly why the test is a prefix test rather than
# a length-sensitive one.
RISK_BLOCK_MARKER='<!-- final_review_risk_start -->'

# The risk gate's own policy — the loop's, not CodeRabbit's. These say what the
# loop will and will not merge unattended, and unlike everything above them a
# change here is a change of mind rather than a change of surface.
#
# The only level that clears V1. There is no documented ladder — searches across
# CodeRabbit's own documentation found the feature described nowhere at all — so
# an ordering cannot be assumed and anything that is not exactly this escalates.
RISK_LEVEL_MINIMAL='minimal'
# V4's blast radius: never minimal if merging it changes what runs unattended.
# The CI directory because a workflow is what runs on the next push, and these
# three files because they *are* the unattended machine — `gh.sh` included, which
# the ticket's "either of the loop's own scripts" predates: it is sourced by both
# and a change to it changes what both do.
#
# Matched on the repository-relative path, so a repository that happens to carry
# a file of the same name at its root escalates too. That is the safe direction,
# and the loop's own repository is deliberately in scope like any other with
# this guard doing the protecting instead of an exclusion.
#
# A comma-joined string rather than an array because it crosses into jq, which
# splits it back; a bash array cannot make that trip without being rebuilt as
# JSON on every call.
CI_WORKFLOW_DIR='.github/workflows/'
UNATTENDED_SCRIPTS='agent-loop.sh,pr-writeback.sh,gh.sh'
# What GitHub's merge endpoint accepts for `merge_method`, and the permission
# boolean the repository read answers each one with. Spelled here as well as in
# pr-writeback.sh for the same reason the autofix trigger is: the seam owns what
# it *sends*, this owns what the loop *validates the config against*, and the
# whole point of that validation is that it happens at startup. A fourth word is
# not a merge method the loop got wrong — it is one that does not exist, which
# GitHub answers with a 422 that classifies `refused`, which is the loop's *"I
# said yes and reality disagreed"* signal. A config typo must never be able to
# impersonate that, so it dies at second zero instead.
#
# The pairing is a lookup rather than a `case` because it is also what the
# permission check reads: GitHub exposes no default-merge-method field, only
# these three booleans saying what is permitted.
MERGE_METHODS='merge squash rebase'
MERGE_METHOD_PERMISSIONS='{"merge":"allow_merge_commit","squash":"allow_squash_merge","rebase":"allow_rebase_merge"}'
# The legacy commit-status context. Measured: on this account CodeRabbit reports
# review progress through the legacy status API and emits *zero* check runs,
# while its own changelog says check runs are now the default surface. So both
# are read, and either one terminal is terminal — one extra field on a read the
# phase already makes, against a default that could flip under the loop.
CODERABBIT_STATUS_CONTEXT='CodeRabbit'
# GraphQL renders a bot actor's login without the `[bot]` suffix REST puts on
# it, so this is matched as a prefix rather than compared whole.
CODERABBIT_LOGIN='coderabbitai'
# The handover's two surfaces, and the loop's own — not CodeRabbit's.
#
# The marker is what makes "already escalated at this head" a fact the phase
# reads for free: it is in the comment timeline the derivation already fetches,
# so detection costs zero new reads. It is keyed on the head commit **alone** —
# not on the kind, not on the author. A commit is what a handover is scoped to,
# and when the head moves the marker stops matching, which is the whole of the
# re-engagement rule: a push is both the fix and the way back in.
#
# The label is the flag rather than the record. One name serves all four kinds
# so that every escalated pull request across every repository is one
# open-pull-requests query away, and it is a constant rather than a config key
# because a per-operator name would make that one query impossible to write
# down. It is never removed — on merge or otherwise: untidy, and inert.
ESCALATION_MARKER_PREFIX='<!-- agent-loop-escalated: '
ESCALATION_MARKER_SUFFIX=' -->'
LABEL_ESCALATED='agent-escalated'
# Reset at the top of every pass. Initialised here only because the close-out
# that runs before the first pass bumps it too, and `set -u` would kill it
# otherwise — what it counts before the first pass is discarded, which is why
# that close-out reports one line per issue rather than a total.
SKIPS=0

# Print usage information to stdout showing command syntax, options, environment
# variables, and required tools. Called when --help is passed or on argument errors.
usage() {
  cat <<'EOF'
Usage: agent-loop.sh [--once] [--no-merge] [--config <path>]
       agent-loop.sh --branch-report <branch> [--config <path>]

Polls the GitHub repositories in the config and dispatches Orca workers at
anything workable. Started by hand, runs until Ctrl-C.

Options:
  --once              Run exactly one pass and exit instead of looping.
  --no-merge          Hold the merge, and only the merge. Everything reversible
                      still runs and the gate still logs the verdict it would
                      have acted on. Scoped to this invocation; there is no
                      config key for it. With --once it is a dry run.
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

Requires: jq, git, orca, gh-axi
EOF
}

# Verify all required commands are available on PATH. Fails with a fatal error
# if any tool is missing.
require_tools() {
  local tool
  for tool in jq git orca gh-axi; do
    command -v "$tool" >/dev/null 2>&1 || die "required command not found on PATH: $tool"
  done
}

# --- gh-axi ------------------------------------------------------------------

# `gh_json`, `gh_graphql` and `gh_error_class` live in gh.sh. They used to exist
# twice, once here and once in pr-writeback.sh, and the copies drifted far
# enough apart that one of them had never worked against real GitHub. One
# definition is what stops that recurring.
# shellcheck source=gh.sh
source "$SCRIPT_DIR/gh.sh"

# --- logging -----------------------------------------------------------------

# Log a message with ISO-8601 timestamp to both stdout and the log file. Every
# decision the loop makes is one line, on stdout and appended to the log file,
# so silence means nothing happened rather than something was swallowed.
log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  printf '%s\n' "$line"
  [[ -n "$LOG_PATH" ]] || return 0
  rotate_log
  printf '%s\n' "$line" >> "$LOG_PATH"
}

# Rotate the log file if it exceeds LOG_MAX_BYTES. Keep one generation. A loop
# left running for weeks must not fill the disk.
rotate_log() {
  [[ -f "$LOG_PATH" ]] || return 0
  local size
  size=$(wc -c < "$LOG_PATH" | tr -d ' ')
  (( size < LOG_MAX_BYTES )) && return 0
  mv -f "$LOG_PATH" "$LOG_PATH.1"
}

# Log a fatal error and exit with status 1.
die() {
  log "fatal: $*"
  exit 1
}

# --- config ------------------------------------------------------------------

# Expand tilde prefix in a path to the user's home directory. Paths without
# tilde are returned unchanged.
expand_tilde() {
  case "$1" in
    "~/"*) printf '%s' "$HOME/${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Verify a config field is present and non-empty. Dies with a fatal error if
# the field is missing or empty.
require_field() {
  local name="$1" value="$2"
  [[ -n "$value" ]] || die "config is missing $name: $CONFIG_PATH"
}

# Verify a config field is a positive integer. Dies with a fatal error if the
# field is missing, empty, or not a positive integer.
require_positive_int() {
  local name="$1" value="$2"
  require_field "$name" "$value"
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] \
    || die "config $name must be a positive integer, got: $value"
}

# Load and validate the agent loop configuration file. Reads JSON config from
# CONFIG_PATH, validates required fields, and populates global variables for
# poll interval, worker limits, timeouts, labels, and project list. Fails fast
# with descriptive errors if config is missing, invalid JSON, or lacks required
# fields.
load_config() {
  [[ -f "$CONFIG_PATH" ]] || die "config not found: $CONFIG_PATH"
  jq empty "$CONFIG_PATH" 2>/dev/null || die "config is not valid JSON: $CONFIG_PATH"

  # The seen-list is gone with the PR worker that wrote it, and a key nothing
  # reads is a key that rots. Unknown keys are otherwise ignored on purpose —
  # enumerating every valid one would be machinery to keep in sync forever, and
  # it would forbid an operator keeping a note in their own file — so this one
  # dead key is named explicitly instead. It is deletable once no config in the
  # world still carries it.
  #
  # It adds no failure event of its own: an old config already stops on the
  # missing `autofixTimeoutSeconds` below. Checked first all the same, because
  # this is the message that says what to *do*.
  jq -e 'has("seenListPath") | not' "$CONFIG_PATH" >/dev/null 2>&1 \
    || die "config still names seenListPath, which no longer exists: remove the key. The PR phase keeps no local state — every pass re-derives from GitHub. ($CONFIG_PATH)"

  POLL_INTERVAL=$(jq -r '.pollIntervalSeconds // empty' "$CONFIG_PATH")
  MAX_WORKERS=$(jq -r '.maxWorkers // empty' "$CONFIG_PATH")
  AUTOFIX_TIMEOUT=$(jq -r '.autofixTimeoutSeconds // empty' "$CONFIG_PATH")
  MERGE_GATE_TIMEOUT=$(jq -r '.mergeGateTimeoutSeconds // empty' "$CONFIG_PATH")
  LABEL_READY=$(jq -r '.labels.ready // empty' "$CONFIG_PATH")
  LABEL_CLAIMED=$(jq -r '.labels.claimed // empty' "$CONFIG_PATH")
  PROJECT_COUNT=$(jq -r '.projects | length' "$CONFIG_PATH" 2>/dev/null || echo 0)

  require_positive_int pollIntervalSeconds "$POLL_INTERVAL"
  require_positive_int maxWorkers "$MAX_WORKERS"
  # Required, not defaulted. This config has no defaults anywhere — every key in
  # it is required and a missing one is fatal — and the number itself is an
  # admitted guess off a single seventeen-minute sample, so defaulting it would
  # add the file's first default *and* hide the guess behind it.
  require_positive_int autofixTimeoutSeconds "$AUTOFIX_TIMEOUT"
  # Required for the same reason, and on thinner evidence still: this key bounds
  # the risk gate's `defer`, and there is **no sample at all** behind that use of
  # it. A default here would be a guess wearing a number's clothes.
  require_positive_int mergeGateTimeoutSeconds "$MERGE_GATE_TIMEOUT"
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

# Create the lockfile atomically only if it does not already exist, so the
# check and the claim are one atomic step rather than two racing ones. Returns
# 0 on success, non-zero if the lock could not be created.
write_lock() {
  set -o noclobber
  { printf '%s\n' "$$" > "$LOCK_PATH"; } 2>/dev/null
  local created=$?
  set +o noclobber
  return "$created"
}

# Remove the lockfile if it exists and belongs to this process. Safe to call
# even if no lock was acquired.
release_lock() {
  [[ -n "${LOCK_PATH:-}" && -f "$LOCK_PATH" ]] || return 0
  [[ "$(cat "$LOCK_PATH" 2>/dev/null || true)" == "$$" ]] || return 0
  rm -f "$LOCK_PATH"
}

# Signal handler: release the lock and exit gracefully. Ctrl-C releases the
# lock and exits. Workers already dispatched keep running.
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
# loop's own three labels are made to exist once, at startup, in every repo it
# polls. Anything already there is left exactly as it is, colour included.
#
# The escalation label is here for the same reason the other two are, and the
# cost of leaving it out is worse: an `--add-label` naming a label that does not
# exist is refused, so every handover would post its comment and then fail to
# flag it, forever, on a self-heal that can never land.
ensure_labels() {
  local repo="$1" existing label response
  response=$(gh_json "/repos/$repo/labels" --paginate) \
    || { log "could not list labels in $repo, assuming they exist"; return 0; }
  existing=$(jq -r '.[].name' <<< "$response")
  for label in "$LABEL_READY" "$LABEL_CLAIMED" "$LABEL_ESCALATED"; do
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

  local i github orca_id method repo_json permission permitted
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    github=$(jq -r ".projects[$i].github // empty" "$CONFIG_PATH")
    orca_id=$(jq -r ".projects[$i].orcaRepoId // empty" "$CONFIG_PATH")
    method=$(jq -r ".projects[$i].mergeMethod // empty" "$CONFIG_PATH")
    [[ -n "$github" ]] || die "projects[$i] has no github path"
    [[ -n "$orca_id" ]] || die "projects[$i] ($github) has no orcaRepoId"
    # Per repository, because it mirrors a repository setting, and required,
    # because there is nothing to default it from: GitHub exposes no
    # default-merge-method field.
    [[ -n "$method" ]] || die "projects[$i] ($github) has no mergeMethod"
    [[ " $MERGE_METHODS " == *" $method "* ]] \
      || die "projects[$i] ($github) mergeMethod must be one of: $MERGE_METHODS, got: $method"

    # GitHub names a repository by `<owner>/<name>` everywhere — in the REST
    # path, in the GraphQL query and on the command line — so unlike GitLab
    # there is no second numeric identifier to resolve and carry around. The
    # read is still made, because a typo must fail here and not on the first
    # query of the first pass — and it is the read the merge method is checked
    # against, which is what puts that failure at startup rather than at the
    # merge.
    repo_json=$(gh_json "/repos/$github" 2>/dev/null) \
      || die "project does not resolve: $github"
    permission=$(jq -r --arg m "$method" '.[$m]' <<< "$MERGE_METHOD_PERMISSIONS")
    # `// false`, so a repository read that carries no such field fails closed.
    # This is a read at startup, so the cost of being wrong is a loud refusal to
    # start; the cost of the other direction is a merge refused unattended and
    # reported as the rubric being wrong.
    permitted=$(jq -r --arg p "$permission" '.[$p] // false' <<< "$repo_json")
    [[ "$permitted" == "true" ]] \
      || die "$github does not permit mergeMethod $method ($permission is $permitted)"
    grep -qxF "$orca_id" <<< "$repo_ids" \
      || die "orcaRepoId does not resolve: $orca_id ($github)"

    ensure_labels "$github"
    log "validated $github -> orca repo $orca_id, merging by $method"
  done
}

# The Orca repo id a configured GitHub repository maps to, or nothing when the
# config does not list it — which is how "not this loop's business" is said.
# The close-out read is global and names repositories by `<owner>/<name>` and
# nothing else, so it comes back through here. The open-pull-request read no
# longer needs it: it runs per configured repository, so everything it returns
# is in scope by construction.
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

# Check whether the Orca runtime is reachable. Returns 0 if reachable, non-zero
# otherwise.
runtime_reachable() {
  [[ "$(orca status --json 2>/dev/null | jq -r '.result.runtime.reachable // false')" == "true" ]]
}

# Ensure the Orca runtime is reachable, starting it if needed. Re-checked
# before every pass: an Orca restart mid-run must not turn every later pass
# into a stream of failed dispatches.
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

# Check whether a worktree path belongs to the loop by its directory name. The
# loop signs its work in the only place that survives everything: the directory
# name. Ownership is asked here and nowhere else, so a worktree of mine can
# never be mistaken for one of the loop's.
is_loop_worktree() {
  [[ "${1##*/}" == agent-loop-* ]]
}

# Count live workers in worktrees whose directory name matches the given regex.
# Prints the count. count_live_workers <basename-regex> — live agents sitting
# in a worktree whose directory name matches.
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

# Count active workers: loop-owned worktrees with agents still running. Prints
# the count. maxWorkers now governs the issue phase alone. It used to be one
# budget for the whole loop, spent by both phases; the PR phase spends no
# worktree, no checkout and no agent any more, so gating it on a worktree
# budget would be a category error — and worse, a long-running issue would
# stall every pull request in every repository behind it. A worker is a
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
# Cleanliness is part of the answer because `--branch-report` is asked *"is
# anyone actually working on this?"*, and a clean checkout of a branch nobody
# has touched is a different answer from one with edits in progress. `unknown`
# exists so that a git that would not answer, or a loop worktree Orca has lost,
# is never mistaken for a clean one.
#
# The PR phase used to be the other caller: it reused a clean foreign worktree
# in place rather than cutting a second checkout. That phase spends no checkout
# at all now, so the report is the whole of it.
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

# --- open pull requests ------------------------------------------------------

# A worker that **finished** leaves no process behind, which is exactly what a
# dispatch that **crashed before it started** leaves — so liveness alone cannot
# tell the two apart, and a reclaim that asks only that question reads a
# finished worker as a crashed one, hands its issue back to the backlog, and a
# second worker rebuilds the same feature from scratch. The evidence that
# separates them is an open pull request on the branch the dispatch asked for,
# and this is what reads it.
#
# One read per repository, in configuration order — the same shape the PR phase
# settled on, and for the same reason: the global `is:pr is:open` search is an
# index and lags behind the repository, and a delivered issue that is merely
# missing from that index is the whole defect this guard exists to stop.
#
# Not `query_repo_open_prs` itself, which the PR phase makes. That read excludes
# drafts and fork heads, and both exclusions are wrong here: a draft pull
# request is work already done and held back by hand, not an invitation to build
# it again, and a fork head is a pull request the loop will not merge unattended
# rather than one it should duplicate.
#
# **Open, and only open.** Merged pull requests are close-out's, and close-out
# runs before both callers in both orderings; counting them here would make an
# issue whose pull request merged but whose checklist failed to tick look
# handled forever, with nothing left to notice. Closed-unmerged ones are
# abandoned work, and abandoning a pull request should return its issue to the
# loop — asking for `states: OPEN` alone is what keeps both true.
#
# **This one pages, and every other enumeration here does not.** The single-page
# cap the rest carry only degrades triage: a pull request past the hundredth is
# looked at a pass later. Here it would fail *open* — a pull request missing
# from the answer reads as "nothing delivers this issue", which is the duplicate
# dispatch this whole guard exists to stop, and it would happen in silence. So
# the read follows the cursor to the end, and a repository too busy even for
# that fails closed rather than answering off a list known to be partial.
#
# ponytail: a second read of a list the PR phase reads again later in the pass.
# Not worth sharing until a repository is busy enough to notice: the reclaim
# runs before any pass at all, so there is no earlier read for it to share.
# Prints one `<pull request>\t<branch>` line per open pull request — the pair in
# GitHub's own order, which `load_open_pr_issues` then turns around into the
# issue-keyed map the callers ask their question of.
query_repo_open_pr_branches() {
  local owner="${1%%/*}" name="${1##*/}" response cursor='null' page=0
  # Twenty pages is two thousand open pull requests. The bound is here so a
  # cursor GitHub never stops handing back cannot spin the loop forever.
  while (( page < 20 )); do
    response=$(gh_graphql "{ repository(owner: \"$owner\", name: \"$name\") { pullRequests(states: OPEN, first: 100, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { number headRefName } } } }") || return 1
    # A GraphQL error can come back as a 200 with a null repository, which would
    # otherwise read as "this repository has no open pull requests" — and read
    # that way by this caller, it would wave every claimed issue through.
    jq -e '.data.repository.pullRequests.nodes | type == "array"' <<< "$response" \
      >/dev/null 2>&1 || return 1
    jq -r '.data.repository.pullRequests.nodes[]?
      | select(.number != null and .headRefName != null)
      | [ (.number | tostring), .headRefName ] | @tsv' <<< "$response"
    # Only GitHub's explicit terminal answer is a complete read. Missing or
    # malformed pagination data must not be mistaken for an empty next page.
    jq -e '.data.repository.pullRequests.pageInfo.hasNextPage == false' <<< "$response" \
      >/dev/null 2>&1 && return 0
    jq -e '.data.repository.pullRequests.pageInfo.hasNextPage == true' <<< "$response" \
      >/dev/null 2>&1 || return 1
    cursor=$(jq -c '.data.repository.pullRequests.pageInfo.endCursor' <<< "$response")
    # A next page GitHub will not give a cursor for is unreadable, not empty.
    [[ -n "$cursor" && "$cursor" != "null" ]] || return 1
    page=$((page + 1))
  done
  # Every page spent and GitHub still says there is more. The caller skips.
  return 1
}

# One repository's open pull requests, resolved to the issues they deliver: a
# `<issue>\t<pull request>` line each, held for whichever caller loaded it.
#
# **Emptied before every load, not only written after a good one.** A read that
# failed must not leave the *previous* repository's answer standing here, where
# it could shield an issue no pull request in this repository names. Both
# callers skip on a failed load and never reach it either way; this is what
# makes that belt-and-braces rather than the only thing holding.
OPEN_PR_ISSUES=''

# Fails when the read failed. It never fails for an empty answer: a repository
# with no open pull requests is a fact, and an unanswerable question is not.
load_open_pr_issues() {
  local branches prnumber branch number loaded=''
  OPEN_PR_ISSUES=''
  branches=$(query_repo_open_pr_branches "$1") || return 1
  while IFS=$'\t' read -r prnumber branch; do
    [[ -n "$prnumber" && -n "$branch" ]] || continue
    # The branch is the only pull-request-to-issue link there is, and it is the
    # same one `closeout_phase` follows coming the other way.
    number=$(issue_for_branch "$branch") || continue
    # The separator is spelled rather than typed: a literal tab is invisible,
    # and one an editor expanded would leave every line unsplittable — read back
    # as an issue number that matches nothing, which fails open.
    loaded+="$number"$'\t'"$prnumber"$'\n'
  done <<< "$branches"
  OPEN_PR_ISSUES="$loaded"
}

# open_pr_for_issue <number> — prints the number of an open pull request that
# already delivers the issue, and fails when nothing does. The first match wins:
# two open pull requests on one issue is still one answer, and which of them the
# line names changes nothing either caller does.
open_pr_for_issue() {
  local number prnumber
  while IFS=$'\t' read -r number prnumber; do
    [[ "$number" == "$1" ]] || continue
    printf '%s' "$prnumber"
    return 0
  done <<< "$OPEN_PR_ISSUES"
  return 1
}

# --- startup reclaim ---------------------------------------------------------

# The worktree a dispatch asked for is `agent-loop-<type>-<number>-<title-slug>`,
# and a name collision appends `-2` — so the number is anchored on both sides, or
# issue 1 would find issue 11's worker and stay claimed forever. The types are
# spelled out rather than matched as `[a-z]+`, which would let an
# `agent-loop-pr-17` answer for issue 17. The PR phase that cut those is gone,
# but the ones it left on disk are not, and `pr` must stay off this list for as
# long as any of them survive. `issue` is the name dispatches used before the
# type was part of it, and still names live workers.
ISSUE_BRANCH_TYPES='feat|fix|chore|docs|refactor|test|perf|build|ci|issue'

# Check whether an issue number has a live worker already running. Returns 0 if
# a worker exists, non-zero otherwise.
issue_has_live_worker() {
  [[ "$(count_live_workers '^agent-loop-('"$ISSUE_BRANCH_TYPES"')-'"$1"'(-.*)?$')" != "0" ]]
}

# The claim label is written before the dispatch, so a crash in between leaves an
# issue claimed with nobody on it. Startup hands every such issue back, which
# also tidies whatever Ctrl-C left orphaned — a leftover worktree strands
# nothing.
#
# Two questions, not one. A claim is only stale when **nobody is on it and
# nothing has come of it**: liveness answers the first, an open pull request the
# second, and either one on its own hands back work that is already delivered.
reclaim_stale_claims() {
  # A reclaim on an inventory we could not read would hand back issues that do
  # have workers, so an unreadable inventory skips the reclaim entirely.
  if ! load_worktree_inventory; then
    log "worker inventory unreadable, skipping startup reclaim"
    return 0
  fi

  local i github numbers number prnumber
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    github=$(jq -r ".projects[$i].github" "$CONFIG_PATH")
    if ! numbers=$(query_claimed_issues "$github"); then
      log "claimed-issue query failed: $github"
      continue
    fi
    # Nothing claimed here: no second question to ask, and no read to spend
    # asking it.
    [[ -n "$numbers" ]] || continue
    # Fail closed. A reclaim that cannot see this repository's open pull
    # requests would hand back every issue one of them already delivers, and the
    # loop polls: an unanswered read costs one interval, where a duplicate costs
    # a whole rebuild.
    if ! load_open_pr_issues "$github"; then
      log "open-pr query failed: $github, skipping its reclaim"
      continue
    fi
    # stdin is closed for the body: gh-axi must not swallow the issue list.
    while IFS= read -r number; do
      [[ -n "$number" ]] || continue
      if issue_has_live_worker "$number"; then
        log "left claimed $github#$number: a live worker holds it"
      elif prnumber=$(open_pr_for_issue "$number"); then
        log "left claimed $github#$number: pull request #$prnumber already delivers it"
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

# Query all claimed issues in a repository. Prints issue numbers, one per line.
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

# Claim an issue by swapping its label from ready to claimed. The label swap is
# the claim: it is what tells the next pass, and any second daemon, that this
# issue is taken.
claim_issue() { swap_labels "$1" "$2" "$LABEL_CLAIMED" "$LABEL_READY"; }

# Release an issue by swapping its label from claimed back to ready.
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

# Run the issue phase for all configured projects. Claims workable issues and
# dispatches Orca workers at them, respecting the maxWorkers budget.
issue_phase() {
  local i github orca_id
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    github=$(jq -r ".projects[$i].github" "$CONFIG_PATH")
    orca_id=$(jq -r ".projects[$i].orcaRepoId" "$CONFIG_PATH")
    issue_phase_project "$github" "$orca_id"
  done
}

# Run the issue phase for one project. Queries ready issues, checks blockers,
# respects the worker budget, claims issues and dispatches workers at them.
issue_phase_project() {
  local github="$1" orca_id="$2" issues number weburl type title blockers worktree_id
  local prnumber

  # ponytail: the CLI's own error text goes to stderr, so it reaches the
  # terminal but not the log file. Capture it into the log line if reading the
  # log alone ever has to be enough.
  if ! issues=$(query_ready_issues "$github"); then
    log "issue query failed: $github"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  # An empty backlog has no second question to ask, and no read to spend asking
  # it.
  [[ -n "$issues" ]] || return 0

  # The second door onto an issue. The reclaim guards the first, but a ready
  # label applied by hand reaches this phase without passing through the reclaim
  # at all — so the question is asked again here, and fails closed the same way:
  # a phase that cannot see the open pull requests dispatches at none of this
  # repository's issues rather than risk re-dispatching at a delivered one.
  if ! load_open_pr_issues "$github"; then
    log "open-pr query failed: $github, skipping its issue phase"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  # stdin is closed for the body: gh-axi must not swallow the issue list.
  while IFS=$'\t' read -r number weburl type title; do
    [[ -n "$number" ]] || continue

    # First, and before the blocker read: an issue something already delivers is
    # not worth a second call to find out whether it is also blocked.
    if prnumber=$(open_pr_for_issue "$number"); then
      log "issue $github#$number skipped: pull request #$prnumber already delivers it"
      SKIPS=$((SKIPS + 1))
      continue
    fi

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

# The phase is a reducer, not a dispatcher. It spends no worktree, no checkout
# and no agent: it reads GitHub, derives one state per open pull request, logs
# it, and — for three of those states — writes. Nothing is remembered between
# passes.
#
# **Every derived state has a bounded exit, and the bound and its origin are
# named.** An unattended bot must not have a state with no way out, and the
# claim is only worth making if it can be checked one row at a time:
#
#   state              bound                       origin
#   ---------------------------------------------------------------------------
#   reviewing          mergeGateTimeoutSeconds     oldest pending signal on H,
#                                                  or H itself when none names
#                                                  an instant
#   autofix-in-flight  autofixTimeoutSeconds       the trigger comment
#   nudge-in-flight    one poll interval           the nudge comment
#   unreviewed         acts on the pass it is derived
#   needs-autofix      acts on the pass it is derived
#   assessable         mergeGateTimeoutSeconds     headDate, inside the gate (V5)
#   rate-limited       external                    the fair-usage rolling window
#   escalated          the head moving
#
# `rate-limited` is the one state with no loop-owned clock, and that is recorded
# as **correct** rather than left as a hole: unlike the review pause, the rate
# limit self-clears as usage ages out, so its bound is external and documented.
#
# The three timeouts run off **three different origins** on purpose, which is
# also why the two configured keys stay separate: the merge-gate key alone has
# two consumers, and the measurements behind them differ by orders of magnitude.

# One read per repository, in configuration order. Not the global
# `is:pr is:open` search the phase used to make: search is an index and lags
# behind the repository, so a pull request the loop should be acting on can
# simply be missing from it, and a long repository list eventually runs the
# query into a length ceiling. Configuration order also becomes the axis the
# one-merge-per-repository bound will run along.
#
# **Exactly two exclusions, and both are free on this read.** Drafts, because
# converting to draft is the operator's hold gesture — GitHub already gives it,
# so there is no hold label and no config key for one. Fork heads, because
# untrusted code is never merged unattended. Bots, non-trunk bases and the
# loop's own repository are deliberately *not* excluded.
#
# Both exclusions are spelled `== false` rather than `!= true`, which is the
# fail-closed direction: a field GitHub stopped sending would drop every pull
# request in the repository, and a phase that logs nothing at all is loud, where
# a fork head slipping into scope would be silent.
#
# `labels` is read for exactly one thing: whether the escalation label is
# already on this pull request. That is what makes the self-heal free — the
# comment says whether the handover happened, this says whether it is flagged,
# and both facts arrive on reads the phase was making anyway. `author` and
# `baseRefName` are fetched and read by nothing at all, and that is the point —
# the scope rule has exactly two exclusions, and neither who opened the pull
# request nor what it is merging into is one of them.
query_repo_open_prs() {
  local github="$1" owner="${1%%/*}" name="${1##*/}" response
  response=$(gh_graphql "{ repository(owner: \"$owner\", name: \"$name\") { pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number title url isDraft isCrossRepository author { login } baseRefName headRefName headRefOid labels(first: 50) { nodes { name } } } } } }") || return 1
  # A GraphQL error can come back as a 200 with a null repository, which would
  # otherwise read as "this repository has no open pull requests".
  jq -e '.data.repository.pullRequests.nodes | type == "array"' <<< "$response" \
    >/dev/null 2>&1 || return 1
  # ponytail: one page, so a repository with more than a hundred open pull
  # requests silently drops the least recently updated of them. The same cap the
  # global search this replaced had. Page if a repository ever gets that busy.
  #
  # Two fields per pull request, tab-separated: the number, and whether the
  # escalation label is on it. Neither can be empty, so the pair is safe to read
  # back with a single `read` — unlike the derivation's facts, three of which
  # routinely are.
  jq -r --arg esc "$LABEL_ESCALATED" '.data.repository.pullRequests.nodes[]?
    | select(.number != null)
    | select(.isDraft == false)
    | select(.isCrossRepository == false)
    | [ (.number | tostring),
        (if ([.labels.nodes[]?.name] | index($esc)) then "labelled" else "unlabelled" end) ]
    | @tsv' <<< "$response"
}

# Everything the derivation needs about one pull request, in one call: the head
# commit and its committer date, the whole status-check rollup on that commit —
# which is the only API that carries legacy statuses and check runs together —
# the review threads, and the comment timeline.
#
# `commits(last: 1)` is the head; `comments(last: 100)` is the *newest* hundred,
# which is the end of the timeline the freshness tests ask about.
#
# `mergeable` and `mergeStateStatus` are the risk gate's V3, and they are two
# fields rather than one because `mergeable: MERGEABLE` is *also* true of the
# unstable and blocked states — the two a naive mergeability test gets wrong.
# Both are computed lazily and both can come back `UNKNOWN` on a first read,
# with no documented retry contract anywhere; that is what `defer` is for.
#
# `files` is V4's blast radius. `totalCount` is fetched alongside the page so a
# pull request with more than a hundred files is *known* to be truncated rather
# than read as a short list — a workflow change hiding past the page boundary is
# precisely the thing this veto exists to catch, so truncation escalates.
#
# ponytail: that window changed job with the handover and the change is worth
# naming. Every other test over it is a *freshness* test — newest-first, so a
# hundred is always enough — but the escalation marker is an *existence* test,
# and an escalated pull request that then collects a hundred newer comments
# would read as never escalated: a duplicate handover, and the loop acting again
# at a head it handed over. The label cannot stand in, because it is not
# head-scoped and would suppress the next head's handover instead. Page the
# comments, or ask for the marker directly, if a pull request ever gets that
# talkative. The status
# `description` and the thread `path`/`line` are fetched and read by nothing:
# the fixtures behind this are whole captures, and a query narrowed to what
# today's derivation happens to use would couple them silently to it.
query_pr_state() {
  local github="$1" number="$2" owner="${1%%/*}" name="${1##*/}" response
  response=$(gh_graphql "{ repository(owner: \"$owner\", name: \"$name\") { pullRequest(number: $number) { number headRefOid mergeable mergeStateStatus files(first: 100) { totalCount nodes { path } } commits(last: 1) { nodes { commit { oid committedDate statusCheckRollup { state contexts(first: 100) { nodes { __typename ... on StatusContext { context state description createdAt creator { login } } ... on CheckRun { name status conclusion startedAt completedAt checkSuite { app { slug } } } } } } } } } reviewThreads(first: 100) { nodes { id isResolved isOutdated path line comments(first: 100) { nodes { databaseId createdAt author { login } } } } } comments(last: 100) { nodes { databaseId createdAt updatedAt body author { login } } } } } }") || return 1
  jq -e '.data.repository.pullRequest != null' <<< "$response" >/dev/null 2>&1 || return 1
  printf '%s' "$response"
}

# The fourteen facts the state machine runs on, one per line — see the caller
# for why they are not one tab-separated line:
#
#   head        the head commit
#   headDate    its committer date, ISO-8601
#   terminal    true when CodeRabbit's review on that commit has finished
#   threads     unresolved CodeRabbit review threads on the pull request
#   statusAt    newest autofix-status comment, ISO-8601, empty if none
#   statusHead  input head recorded by that status's trigger, empty if unknown
#   triggerAt   newest autofix trigger I posted, ISO-8601, empty if none
#   escalated   true when a handover has already been posted at that head
#   signal      true when CodeRabbit has reported *anything* on that commit
#   pendingAt   oldest CodeRabbit signal on it that has not reported, ISO-8601
#   block       present | absent — a merge-risk block anywhere on the PR
#   limited     CodeRabbit newest review comment carries the rate-limit marker
#   nudgeAt     newest review nudge I posted, ISO-8601, empty if none
#   reply       CodeRabbit's newest comment after that nudge, verbatim
#
# Seven judgements are made here and are worth naming:
#
# **Terminal is per commit, reads both surfaces, and is decided by the *newest*
# signal rather than by any of them.** A legacy status is terminal at `SUCCESS`,
# `FAILURE` or `ERROR`; `PENDING` and `EXPECTED` are not. A check run is
# terminal at `COMPLETED`. The absence of both is not terminal.
#
# Newest and not *any*, because statuses append and a head can carry a finished
# review followed by a fresh one. That is not hypothetical: it is exactly what a
# successful nudge produces on a pull request whose green status meant *review
# skipped* — the skipped-review `SUCCESS` stays, because un-drafting is not a
# push and the head never moves, and the review the nudge started lands a
# `PENDING` beside it. Read as *any*, the loop would call that terminal, keep
# calling it unreviewed, and hand it over one poll interval into a review that
# was running. `success` means *the review ran*, never *the review
# found nothing* — a pull request with five findings and a high merge risk
# carries the same green status as a clean one.
#
# **`signal` is the absence test `terminal` cannot make.** *Nothing reported* and
# *reported and not finished* are the same value of `terminal` and completely
# different states: the first is a pull request CodeRabbit never looked at, and
# it is nudged; the second is a review in progress, and it is waited on. So the
# emptiness of CodeRabbit's contribution to the rollup is its own fact.
#
# **The pending origin is the oldest signal, not the newest, and not the head.**
# Oldest because the observed progress statuses land three seconds apart and are
# then followed by a hundred seconds of silence — they are phase markers, not
# heartbeats, so a clock reset by each one would expire at the same moment while
# claiming a guarantee it does not have. Not the head, because a real pull
# request sat four and a half hours between `headDate` and its review starting.
#
# **The merge-risk block is looked for by its marker, and anywhere on the pull
# request.** A marker test, not prose parsing, and cause-blind — which is what
# makes it catch the rate-limit path's passing check as well as the skipped
# review's green status. It is deliberately broader than the gate's own read of
# the same block, which is scoped to CodeRabbit's newest walkthrough: absent
# here implies absent there, so a pull request that reaches the gate always has
# a block for V1 to judge, and V1's tripwire keeps meaning *CodeRabbit changed
# shape*.
#
# **A thread is CodeRabbit's when CodeRabbit opened it.** The first comment's
# author decides, not any comment's: a thread I opened that the bot replied to
# is my conversation, not its finding. That is also the bot's own precondition
# — autofix processes unresolved CodeRabbit threads — so the loop's trigger
# condition and the bot's are the same predicate, and a metered run that would
# do nothing cannot be fired by construction.
#
# **CodeRabbit comment freshness is the *updated* timestamp; mine is the
# created one.** CodeRabbit delivers by editing comments it already posted, so
# a created timestamp can be days stale. My own trigger and my own nudge are
# never edited by me, and their creation is the event.
#
# **The escalation marker is matched on the head commit and on nothing else** —
# no author test, no timestamp test. The commit is what a handover is scoped to,
# and a marker naming this head means the record exists whoever put it there:
# an operator who quoted the comment back has said the same thing the loop said,
# and a marker naming any other commit is a record of a handover that is over.
# No timestamp is consulted because a comment cannot predate the commit it
# names.
#
# The reply is carried so the handover can paste it and for no other reason.
# **Nothing keys on it** — a performed reply with no status is a CodeRabbit
# failure and a not-completed reply is a refusal, and both escalate — so it is
# flattened onto one line like every other value here rather than parsed.
pr_facts() {
  jq -r \
    --arg crctx "$CODERABBIT_STATUS_CONTEXT" \
    --arg crlogin "$CODERABBIT_LOGIN" \
    --arg me "$ME" \
    --arg trigger "$AUTOFIX_TRIGGER" \
    --arg nudge "$REVIEW_TRIGGER" \
    --arg statusmarker "$AUTOFIX_STATUS_MARKER" \
    --arg walkthrough "$WALKTHROUGH_MARKER" \
    --arg ratelimit "$RATE_LIMIT_MARKER" \
    --arg riskstart "$RISK_BLOCK_MARKER" \
    --arg escprefix "$ESCALATION_MARKER_PREFIX" \
    --arg escsuffix "$ESCALATION_MARKER_SUFFIX" '
    def is_coderabbit: (. // "") | ascii_downcase | startswith($crlogin);
    # A newline or a tab inside a value would reshape the one-value-per-line
    # protocol at the bottom of this program into a *different* set of values
    # rather than corrupt one visibly. Only the reply can carry either, and it
    # is the one value here written by something other than a machine.
    def flat: (. // "") | gsub("[\n\t]"; " ");
    .data.repository.pullRequest as $pr
    | ($pr.commits.nodes[-1].commit // {}) as $head
    # Everything CodeRabbit put on the head commit, either surface, kept whole
    # so that *how many* and *how old* can be asked of it as well as *finished*.
    | [ $head.statusCheckRollup.contexts.nodes[]?
        | if .__typename == "StatusContext" then
            (if (.context == $crctx or (.creator.login | is_coderabbit))
             then { terminal: (((.state // "") | ascii_upcase) | IN("SUCCESS","FAILURE","ERROR")),
                    at: .createdAt }
             else empty end)
          elif .__typename == "CheckRun" then
            (if ((.name // "") == $crctx or (.checkSuite.app.slug | is_coderabbit))
             then { terminal: (((.status // "") | ascii_upcase) == "COMPLETED"),
                    at: .startedAt }
             else empty end)
          else empty end ] as $signals
    | [ $pr.reviewThreads.nodes[]?
        | select(.isResolved != true)
        | select(.comments.nodes[0].author.login | is_coderabbit) ] as $threads
    | [ $pr.comments.nodes[]?
        | select((.body // "") | contains($statusmarker))
        | { createdAt, updatedAt } ]
        | max_by(.updatedAt) as $status
    | [ $pr.comments.nodes[]?
        | select(((.author.login // "") | ascii_downcase) == ($me | ascii_downcase))
        | select((.body // "") | contains($trigger))
        | { createdAt,
            head: (try ((.body // "")
              | capture("<!-- agent-loop-autofix-head: (?<sha>[0-9a-fA-F]{40}) -->").sha)
              catch "") } ] as $triggers
    | [ $triggers[]
        | select(.createdAt <= ($status.createdAt // "")) ]
        | max_by(.createdAt) as $statusTrigger
    # My own nudge, newest by the timestamp I control. The two commands do not
    # collide: `@coderabbitai autofix` does not contain `@coderabbitai review`.
    | ([ $pr.comments.nodes[]?
         | select(((.author.login // "") | ascii_downcase) == ($me | ascii_downcase))
         | select((.body // "") | contains($nudge))
         | .createdAt ] | max // "") as $nudgeAt
    # CodeRabbit newest word on its own review, by its **updated** timestamp —
    # which is the only timestamp worth reading here, because the rate-limit
    # block is delivered by *editing* the walkthrough that was already posted.
    #
    # It is scoped rather than a scan of every comment, and the scope is what
    # makes the rate limit a wait the loop can leave a clock off. A marker found
    # anywhere at all would still be found three heads later, and this is the one
    # state with no clock of its own: an unscoped read would park a pull request
    # forever on a throttle that lifted days ago.
    #
    # Either marker admits the comment, because a walkthrough is not guaranteed
    # to exist yet — a pull request throttled before its first review has the
    # rate-limit comment and nothing to have edited. The gate reads the same
    # marker out of the walkthrough alone, which is narrower and correct there:
    # it is asking whether the verdict it is about to read is throttled, where
    # this is asking whether the reviewer is.
    | ([ $pr.comments.nodes[]?
         | select(.author.login | is_coderabbit)
         | select(((.body // "") | contains($walkthrough))
                  or ((.body // "") | contains($ratelimit))) ]
       | max_by(.updatedAt // "")) as $walk
    # Whatever CodeRabbit said after it. Selected by the created timestamp
    # because a reply is a new comment rather than an edit of an old one — the
    # updated-timestamp binding is about the walkthrough, which CodeRabbit
    # rewrites in place.
    | ([ $pr.comments.nodes[]?
         | select(.author.login | is_coderabbit)
         | select($nudgeAt != "" and (.createdAt // "") > $nudgeAt) ]
       | max_by(.createdAt // "")) as $reply
    | (if ($head.oid // "") == "" then false
       else ([ $pr.comments.nodes[]?
               | select((.body // "")
                   | contains($escprefix + $head.oid + $escsuffix)) ]
             | length) > 0
       end) as $escalated
    | [ ($head.oid // ""),
        ($head.committedDate // ""),
        ((($signals | max_by(.at // "") | .terminal) // false) | tostring),
        ($threads | length | tostring),
        ($status.updatedAt // ""),
        ($statusTrigger.head // ""),
        ($triggers | map(.createdAt) | max // ""),
        ($escalated | tostring),
        ((($signals | length) > 0) | tostring),
        ([ $signals[] | select(.terminal | not) | .at | select(. != null) ] | min // ""),
        # Anywhere on the pull request, whoever posted it — except a handover
        # the loop wrote, which is not a review artifact and which pastes
        # CodeRabbit words verbatim. Without that one exclusion a reply that
        # happened to quote the block would let the record the loop wrote answer
        # the question that record exists because nothing else could answer.
        #
        # This is a deliberate narrowing of *anywhere on the pull request*, and
        # the only one: what the loop wrote is not evidence about what
        # CodeRabbit did. Without it the phase could answer its own question,
        # and a self-referential marker is a trap this project has already been
        # caught in once.
        #
        # ponytail: no fixture reaches it. Neither measured reply shape carries a
        # block, and inventing one would test the loop against a shape of
        # CodeRabbit nobody has seen.
        (if ([ $pr.comments.nodes[]?
               | select((.body // "") | contains($escprefix) | not)
               | select((.body // "") | contains($riskstart)) ]
             | length) > 0 then "present" else "absent" end),
        ((($walk.body // "") | contains($ratelimit)) | tostring),
        $nudgeAt,
        ($reply.body | flat) ]
    | .[]'
}

# An ISO-8601 instant as epoch seconds, whichever conversion spelling this
# platform's date takes. Time comes from `date(1)` and from nowhere else in this
# project — a shell built-in would read the real clock without touching PATH,
# which is exactly how a timeout test goes green for the wrong reason.
epoch_of() {
  [[ -n "$1" ]] || return 1
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null
}

# The autofix trigger. It goes through pr-writeback.sh rather than
# calling gh-axi here, because the seam is a thing a human can also run by hand
# and because the trigger's text is the seam's own constant.
#
# ponytail: the seam's stdout — GitHub's answer, verbatim — and its stderr are
# dropped; only the exit status reaches the log line. Capture them into the tail
# if a failed trigger ever needs explaining beyond "it failed".
post_autofix_trigger() {
  "$SCRIPT_DIR/pr-writeback.sh" autofix --repo "$1" --pr "$2" --sha "$3" >/dev/null 2>&1
}

# The review nudge. Unlike the autofix trigger it records no head: *once per
# head* is decided here by the nudge being newer than the head commit, not by a
# marker in its body, so there is nothing for the seam to carry. That also keeps
# the comment a bare command, which is what a nudge the operator might type by
# hand looks like.
#
# ponytail: the same as the trigger's — stdout and stderr are dropped and only
# the exit status reaches the log line.
post_review_nudge() {
  "$SCRIPT_DIR/pr-writeback.sh" review --repo "$1" --pr "$2" >/dev/null 2>&1
}

# The one irreversible write. merge_pr <repo> <number> <assessed-commit> <method>
#
# The commit is the one the gate assessed and never the head as GitHub reports
# it now: the seam turns it into an assertion GitHub compares against the head,
# so a push that raced the gate loses with a 409 instead of being merged
# unreviewed. The method comes from the configuration that was validated against
# this repository's own permission booleans at startup.
#
# Unlike the trigger, **stdout is kept**. It is GitHub's answer verbatim, and on
# a refusal it is the text the handover pastes — the whole of what the operator
# has to go on when the gate said yes and reality disagreed. stderr is the
# seam's own prose for a human running it by hand, and is dropped.
#
# The exit status is the seam's contract and passes through untouched: 0 merged,
# 3 refused, 4 transient, 1 an argument error or a fatal failure of the seam.
merge_pr() {
  "$SCRIPT_DIR/pr-writeback.sh" merge --repo "$1" --pr "$2" --sha "$3" --method "$4" 2>/dev/null
}

# --- the handover -------------------------------------------------------------
#
# Escalation is a handover, not a notification, and the reason is a fact about
# GitHub rather than a preference: **the loop acts as the operator's own account,
# and GitHub never notifies you of your own actions.** No arrangement of writes
# can push. So the job is not to notify — it is to make an escalated pull
# request legible in a view the operator already visits, and then to stop
# touching it.
#
# What follows from that is the asymmetry the whole path is built on:
# **delivery is retried until it lands; the action it reports is never retried.**

# One row of the record. A reason is a verdict, what was judged, and the raw
# values that produced the judgement — never a conclusion on its own. The rows
# that **passed** are carried too: an operator reading a handover is owed the
# complete picture the gate saw, not the subset that said no, because the
# passing rows are what tell them where *not* to look.
#
# The verdict column reads `ok`, `no`, `defer` — and `note` for a row that
# judged nothing at all. There is exactly one of those: CodeRabbit's reply to a
# nudge, pasted verbatim because **nothing keys on it**. Giving it `ok` would
# claim a judgement was made about prose the loop is specifically forbidden to
# parse.
# The tab is the join and the newline ends the row, so either one inside a field
# would reshape the row into a different one rather than corrupt it visibly —
# the one failure a record must not have. The reader is a `read` with `IFS`, and
# a `read` stops at the first newline, so a value carrying one loses everything
# after it *silently*.
#
# That is no longer hypothetical: the refused merge's raw value is GitHub's own
# answer, forwarded verbatim through the seam, and gh-axi renders it as two
# lines. Without the second substitution the `code:` line is dropped from the
# one record the operator has to go on.
#
# md_cell substitutes newlines as well, and that is not this: it renders a value
# that has already survived being read back. By then the loss has happened.
reason() {
  local verdict="${1//$'\t'/ }" what="${2//$'\t'/ }" raw="${3//$'\t'/ }"
  printf '%s\t%s\t%s' "${verdict//$'\n'/ }" "${what//$'\n'/ }" "${raw//$'\n'/ }"
}

# A table cell. Three characters can break one: the pipe that draws the table,
# and — because the raw column is rendered inside a code span — the backtick
# that closes it and the newline that ends the row. Today's values are
# `key=value` and carry none of them; the kinds still to come paste text
# CodeRabbit and GitHub wrote, and a record that renders as a broken table is
# worth less than one that renders as an ugly line.
md_cell() {
  # A backtick cannot be escaped inside a code span, so it is substituted rather
  # than escaped. The pipe can be, and the newline is what ends a row.
  local tick="'" cell="${1//|/\\|}"
  cell="${cell//\`/$tick}"
  printf '%s' "${cell//$'\n'/ }"
}

# The record itself. Everything head-scoped the loop knows lives here, because
# with no local state a comment on the pull request is the only place a
# head-scoped record can live at all.
#
# The kind is the first line because it is what tells the operator what to do
# next — whether to read the diff, go and look at CodeRabbit, or go and look at
# the rubric. All four have callers, and two of them have more than one:
# `stalled` from the autofix clock and from the nudge clock, `stuck` from the
# risk gate and from the review clock, `escalate` from the gate's vetoes, and
# `refused` from the merge.
escalation_body() {
  local kind="$1" head="$2" meaning r verdict what raw
  shift 2

  case "$kind" in
    escalate) meaning="a veto is present and says no" ;;
    stuck)    meaning="signals are still undecided past the merge-gate timeout" ;;
    stalled)  meaning="a CodeRabbit command was triggered and CodeRabbit never reported inside its bound" ;;
    refused)  meaning="the gate said merge and GitHub said no" ;;
    # Not reachable from this file, and it still must not lose the record: a
    # kind with no gloss is worth less to the operator than one with, and worth
    # far more than a comment that was never posted.
    *)        meaning="" ;;
  esac

  if [[ -n "$meaning" ]]; then
    printf '**Escalated — `%s`:** %s.\n\n' "$kind" "$meaning"
  else
    printf '**Escalated — `%s`.**\n\n' "$kind"
  fi

  printf 'The loop takes no further action on this pull request at `%s` — no merge, no autofix trigger, no nudge — until the head moves.\n\n' "$head"

  printf '| Verdict | What | Raw values |\n|---|---|---|\n'
  for r in "$@"; do
    IFS=$'\t' read -r verdict what raw <<< "$r"
    printf '| %s | %s | `%s` |\n' "$(md_cell "$verdict")" "$(md_cell "$what")" "$(md_cell "$raw")"
  done

  # The three gestures that already exist, which is what makes this a handover
  # rather than a notice. There is deliberately no fourth: an override label
  # would be an unscoped bypass token for the only gate left standing.
  printf '\n**Ways back in**\n\n'
  printf -- '- **Merge it by hand.** Close-out still ticks and closes the issue this branch names: it reads merged pull requests from GitHub and cannot tell whose hand pressed the button.\n'
  printf -- '- **Push a commit.** The head moves, this record stops matching it, and the loop re-derives from scratch on the next pass.\n'
  printf -- '- **Convert it to draft.** Draft is the hold gesture, and the loop stops seeing this pull request at all.\n\n'
  printf 'There is no override label. A push is both the fix and the re-engagement.\n\n'

  printf '%s%s%s\n' "$ESCALATION_MARKER_PREFIX" "$head" "$ESCALATION_MARKER_SUFFIX"
}

# The flag, on its own. Reachable alone because that is what the self-heal is: a
# pass that finds the record posted and the label missing adds the label and
# says nothing else.
add_escalation_label() {
  "$SCRIPT_DIR/pr-writeback.sh" label --repo "$1" --pr "$2" \
    --add "$LABEL_ESCALATED" >/dev/null 2>&1
}

# The handover, in its fixed order: **comment, then label.**
#
# That order is not a preference either. It self-heals: a pass that finds the
# comment posted and the label missing adds the label without re-posting
# anything, whereas label-then-comment would leave a flagged pull request whose
# record never landed and post the record again on every pass after.
#
# The label is added unconditionally, even when the enumeration already saw it
# there — a pull request whose previous head was escalated keeps the flag, since
# it is never removed. Making the second write conditional on a fact from the
# *other* read would trade one idempotent write for an invariant that no longer
# holds by inspection: as written, an escalation that returns 0 has always ended
# with the label on.
#
#   0  both landed
#   1  the comment did not land — nothing was said and nothing is flagged, so
#      the next pass re-derives and escalates again from scratch
#   2  the comment landed and the label did not — the record is on the pull
#      request, so the next pass reads the marker, adds the label, and posts
#      nothing
#
# $ESCALATE_RC carries the seam's own exit status for whichever write failed,
# because the phase's log line is the only record a failure leaves.
# The state line's tail for one handover attempt, spelled once. Every kind to
# come reports its outcome the same three ways, and a switch copied per caller
# is how two of them end up disagreeing about what `label=failed` means.
#
# The skip accounting deliberately stays at the call site: this runs in a
# command substitution, so an increment made here would die with the subshell.
escalation_kv() {
  local kind="$1" status="$2"
  case "$status" in
    0) printf 'action=escalated kind=%s label=added' "$kind" ;;
    # The record is on the pull request and the flag is not. The next pass reads
    # the marker, adds the label, and posts nothing.
    2) printf 'action=escalated kind=%s label=failed rc=%s' "$kind" "$ESCALATE_RC" ;;
    # Nothing was said and nothing is flagged, so there is nothing to unwind:
    # the next pass re-derives the same failure and escalates again. The poll
    # interval is the whole of the backoff.
    *) printf 'action=escalate-failed kind=%s rc=%s' "$kind" "$ESCALATE_RC" ;;
  esac
}

# Post an escalation handover to a pull request: a comment carrying the verdict
# table and an escalation label. Runs in two phases (comment then label) to
# enable self-healing: a pass that finds the comment but no label will add the
# label without reposting. Returns 0 if both succeed, 1 if comment fails, 2 if
# comment succeeds but label fails. Sets ESCALATE_RC to the exit code of
# whichever write failed.
ESCALATE_RC=0
escalate() {
  local github="$1" number="$2" head="$3" kind="$4"
  shift 4
  local body status=0
  ESCALATE_RC=0

  # Free text travels to the seam as a file: gh-axi would reinterpret a --body
  # that happened to look like JSON, and this body is a markdown table.
  body=$(mktemp "${TMPDIR:-/tmp}/agent-loop-escalation.XXXXXX") || { ESCALATE_RC=1; return 1; }
  if ! escalation_body "$kind" "$head" "$@" > "$body"; then
    rm -f "$body"
    ESCALATE_RC=1
    return 1
  fi

  "$SCRIPT_DIR/pr-writeback.sh" comment --repo "$github" --pr "$number" \
    --body-file "$body" >/dev/null 2>&1 || status=$?
  rm -f "$body"
  if (( status != 0 )); then ESCALATE_RC=$status; return 1; fi

  status=0
  add_escalation_label "$github" "$number" || status=$?
  if (( status != 0 )); then ESCALATE_RC=$status; return 2; fi
  return 0
}

# --- the risk gate ------------------------------------------------------------
#
# Four vetoes over one head commit, and three outcomes: `merge`, `escalate` and
# `defer`. The division of labour is the thing to hold on to — **CodeRabbit's
# verdict is a necessary input, not the verdict.** The reviewer judges the code;
# the loop judges blast radius and merge mechanics; each holds a veto. That is
# forced rather than chosen: the gate never reads thread resolution, because
# autofix does not resolve what it fixes, so the rubric cannot lean on "threads
# are clean" as a proxy for "concerns addressed".
#
# `defer` is the third outcome and it is not a failure. A signal that is simply
# **not computed yet** — a check still running, a mergeability GitHub has not
# finished calculating — is re-derived next pass in silence, because an unknown
# mergeability state is routine and has no documented retry contract to follow.
# What stops that being forever is the clock, V5.
#
# **All four vetoes evaluate — no short-circuit — and escalate beats defer.**
# One message carries every reason, the passes as well as the failures: an
# operator reading a handover needs to know where *not* to look as much as where
# to.

# Everything the gate runs on, one value per line, in the order the reader below
# takes them. Same protocol as pr_facts and for the same reason: several of
# these are routinely empty, and `read` folding a run of tabs would silently
# shift one field into another's slot.
#
#   limited      the walkthrough carries the rate-limit marker
#   level        the merge-risk level, letters only and lowercased
#   abbrev       the commit abbreviation the verdict was computed for
#   block        parsed | unparseable | absent
#   mergeable    GitHub's conflict axis
#   mergestate   GitHub's everything-else axis
#   green/pending/failed/total   the rollup, counted by verdict
#   pendingnames the contexts that have not reported
#   failednames  the contexts that reported badly, with what they said
#   files        how many files the pull request touches
#   truncated    more files than the page carries, so the list is not the whole
#   guarded      the touched paths V4 refuses to merge unattended
#
# **Required-ness is not read, and its absence from the query is the proof.**
# It is structurally always false once repository protection is out of scope, so
# a gate that only looked at required checks would have no check that could ever
# block a merge.
#
# **Pre-merge checks are not read either.** They are computed from the same
# review as the merge-risk verdict, they measure hygiene rather than merge risk,
# and the verdict subsumes them — so this parses no part of that block.
gate_facts() {
  jq -r \
    --arg crlogin "$CODERABBIT_LOGIN" \
    --arg walkthrough "$WALKTHROUGH_MARKER" \
    --arg ratelimit "$RATE_LIMIT_MARKER" \
    --arg riskstart "$RISK_BLOCK_MARKER" \
    --arg workflows "$CI_WORKFLOW_DIR" \
    --arg scripts "$UNATTENDED_SCRIPTS" '
    def is_coderabbit: (. // "") | ascii_downcase | startswith($crlogin);
    # A newline or a tab inside a value would reshape the one-value-per-line
    # protocol at the bottom of this program into a *different* set of values
    # rather than corrupt one visibly — the one failure a machine-read record
    # must not have. Nothing GitHub allows in a check name or a path produces
    # either today; this is what keeps that true when something does.
    def flat: (. // "") | gsub("[\n\t]"; " ");
    .data.repository.pullRequest as $pr
    | ($pr.commits.nodes[-1].commit // {}) as $head
    # The walkthrough, newest by its **updated** timestamp. CodeRabbit delivers
    # by editing what it already posted, so the created one can be a week stale.
    | ([ $pr.comments.nodes[]?
         | select(.author.login | is_coderabbit)
         | select((.body // "") | contains($walkthrough)) ]
       | max_by(.updatedAt // "")) as $walk
    | ($walk.body // "") as $body
    # capture emits nothing on no match, so it is collected into an array first:
    # bound bare, an unparseable block would make this whole program produce no
    # output at all rather than say the block was unparseable.
    | ([ $body | capture("final_review_risk_start -->\\s*\\*\\*Merge Risk:\\*\\*\\s*_(?<level>[^_]+)_\\s*·\\s*up to `(?<abbrev>[0-9a-fA-F]+)`") ]
       | .[0]) as $risk
    | [ $head.statusCheckRollup.contexts.nodes[]?
        | if .__typename == "StatusContext" then
            ((.state // "") | ascii_upcase) as $s
            | { name: (.context // "?"), raw: $s,
                verdict: (if $s == "SUCCESS" then "green"
                          elif $s | IN("PENDING","EXPECTED") then "pending"
                          else "failed" end) }
          elif .__typename == "CheckRun" then
            ((.status // "") | ascii_upcase) as $s
            | ((.conclusion // "") | ascii_upcase) as $c
            | { name: (.name // "?"), raw: ($s + "/" + (if $c == "" then "none" else $c end)),
                # Neutral and skipped are green: a check that ran and declined to
                # judge has not failed, and a required-looking name is not read.
                verdict: (if $s != "COMPLETED" then "pending"
                          elif $c | IN("SUCCESS","NEUTRAL","SKIPPED") then "green"
                          else "failed" end) }
          else empty end ] as $checks
    | [ $pr.files.nodes[]?.path | select(. != null) ] as $paths
    | ($pr.files.totalCount // 0) as $filecount
    | ($scripts | split(",")) as $guardedfiles
    | [ $paths[] | select(startswith($workflows) or IN($guardedfiles[])) | flat ] as $guarded
    | [ (($body | contains($ratelimit)) | tostring),
        (if $risk then ($risk.level | ascii_downcase | gsub("[^a-z]"; "")) else "" end),
        (($risk.abbrev // "") | ascii_downcase),
        (if ($body | contains($riskstart)) then (if $risk then "parsed" else "unparseable" end) else "absent" end),
        (($pr.mergeable // "") | ascii_upcase),
        (($pr.mergeStateStatus // "") | ascii_upcase),
        ([ $checks[] | select(.verdict == "green") ] | length | tostring),
        ([ $checks[] | select(.verdict == "pending") ] | length | tostring),
        ([ $checks[] | select(.verdict == "failed") ] | length | tostring),
        ($checks | length | tostring),
        ([ $checks[] | select(.verdict == "pending") | (.name | flat) ] | join(",")),
        ([ $checks[] | select(.verdict == "failed") | "\(.name | flat)=\(.raw | flat)" ] | join(",")),
        ($filecount | tostring),
        (($filecount > ($paths | length)) | tostring),
        ($guarded | join(",")) ]
    | .[]'
}

# The gate's answer, left in globals because it is three things — a verdict, the
# log line's tail, and the rows a handover would carry — and a command
# substitution would strip the array back to a string.
GATE_VERDICT=""
GATE_KIND=""
GATE_KV=""
GATE_REASONS=()

# risk_gate <head> <headDate> <headEpoch> <now> <response> — leaves its verdict
# in the globals above, and returns non-zero when the read it runs on could not
# be made sense of.
risk_gate() {
  local head="$1" head_date="$2" head_epoch="$3" now="$4" response="$5"
  local limited=false level="" abbrev="" block="" mergeable="" mergestate=""
  local green=0 pending=0 failed=0 total=0 pendingnames="" failednames=""
  local filecount=0 truncated=false guarded=""
  local v1 v2 v3 v4 age clock="" deferred=false expired=false

  GATE_VERDICT=defer
  GATE_KIND=""
  GATE_KV=""
  GATE_REASONS=()

  # Either all fifteen values arrive or the gate does not judge at all.
  #
  # Failing closed here would mean failing closed to a **write**: with every
  # value empty, V1 sees no verdict and escalates, so a jq that hiccuped would
  # post a handover on a pull request nothing is wrong with — and a handover is
  # never retried, so that mistake would stick until the head moved. A read that
  # cannot be made sense of is the same event as the unreadable state above, and
  # gets the same answer: say so, skip, re-derive next pass.
  #
  # The last `read` is the one tested because it is the only one that can tell a
  # short answer from a complete one; `|| true` on the block keeps `set -e` from
  # taking the whole daemon down over one pull request.
  #
  # ponytail: no test reaches this. The suite's only seam is the stub CLIs, and
  # every answer they can give is JSON this program has already been through
  # once as `pr_facts` — so a short read is not reachable from outside the
  # script, and the only way to test it would be a seam that exists for the
  # test. It stays because the failure it prevents is a write.
  local complete=false
  {
    read -r limited
    read -r level
    read -r abbrev
    read -r block
    read -r mergeable
    read -r mergestate
    read -r green
    read -r pending
    read -r failed
    read -r total
    read -r pendingnames
    read -r failednames
    read -r filecount
    read -r truncated
    read -r guarded && complete=true
  } < <(gate_facts <<< "$response") || true
  $complete || return 1

  # **Ahead of every veto, and every pass regardless of timestamp.** A
  # rate-limited pull request keeps a stale verdict; V1 would catch that
  # staleness and route it to a handover, turning a transient throttle into a
  # permanent one — and throttling would then escalate the whole queue whenever
  # the reviewer is merely slow. So this defers, and it is the one defer the
  # gate clock does not bound: the comment ships its own estimate, and unlike a
  # review pause the rate limit self-clears as usage ages out.
  if [[ "$limited" == "true" ]]; then
    GATE_VERDICT=defer
    GATE_KV="verdict=defer gate=rate-limited"
    return 0
  fi

  # V1 — CodeRabbit's verdict. The abbreviation must be a **prefix of the head**,
  # which is what scopes the verdict to the code being merged, and the level
  # exactly minimal. Anything else escalates: an unrecognised level, an
  # unparseable line, a block that is not there. There is no documented ladder of
  # levels to order, so this is the tripwire for CodeRabbit changing shape.
  #
  # A missing block no longer reaches this line: *no merge-risk block anywhere on
  # the pull request* is one of the two routes into `unreviewed`, which is
  # nudged and bounded before the gate is ever reached. So the `absent` arm here
  # is unreachable by construction and is kept anyway — the predicate upstream
  # reads the marker across every comment where this reads it out of
  # CodeRabbit's newest walkthrough, and the safe direction for that asymmetry
  # is for the stricter reader to escalate rather than to fall through.
  if [[ "$block" == "parsed" && "$level" == "$RISK_LEVEL_MINIMAL" \
        && -n "$abbrev" && "$head" == "$abbrev"* ]]; then
    v1=ok
    GATE_REASONS+=("$(reason ok "CodeRabbit puts merge risk at minimal for this commit" \
      "level=$level abbrev=$abbrev head=$head")")
  else
    v1=no
    GATE_REASONS+=("$(reason no "CodeRabbit's merge-risk verdict does not clear this commit" \
      "block=${block:-unreadable} level=${level:-none} abbrev=${abbrev:-none} head=$head")")
  fi

  # V2 — checks. **Every** rollup context, not just the required ones. A failure
  # is a veto; a context that has not reported yet is undecided rather than bad,
  # and so is a rollup with nothing in it at all.
  #
  # An empty rollup is not reachable from here today — the review that has to be
  # terminal to get this far is itself read off the rollup — but it is spelled
  # out rather than left to fall through, because GitHub reports "a check is
  # running" and "there are no checks" with the same rollup state, and reading
  # the empty case as green is how a gate merges an unchecked commit.
  if (( failed > 0 )); then
    v2=no
    GATE_REASONS+=("$(reason no "a status check on this commit is not green" \
      "green=$green pending=$pending failed=$failed total=$total failing=$failednames")")
  elif (( pending > 0 || total == 0 )); then
    v2=defer
    GATE_REASONS+=("$(reason defer "a status check on this commit has not reported yet" \
      "green=$green pending=$pending failed=$failed total=$total waiting=${pendingnames:-none}")")
  else
    v2=ok
    GATE_REASONS+=("$(reason ok "every status check on this commit is green" \
      "green=$green pending=$pending failed=$failed total=$total")")
  fi

  # V3 — mergeability. Both axes, because `mergeable` alone is true of the
  # unstable and blocked states too. `UNKNOWN` on either is GitHub still
  # calculating, which is a defer and not a verdict — a gate that read it as
  # "no conflicts detected" would merge conflicted pull requests.
  #
  # **A branch that is behind is never updated.** That write would move the head,
  # void the verdict just validated, and spend metered review budget re-reviewing
  # what was already reviewed. It escalates instead.
  if [[ "$mergeable" == "MERGEABLE" && "$mergestate" == "CLEAN" ]]; then
    v3=ok
    GATE_REASONS+=("$(reason ok "GitHub reports this pull request mergeable and clean" \
      "mergeable=$mergeable state=$mergestate")")
  elif [[ -z "$mergeable" || -z "$mergestate" || "$mergeable" == "UNKNOWN" || "$mergestate" == "UNKNOWN" ]]; then
    v3=defer
    GATE_REASONS+=("$(reason defer "GitHub has not finished computing mergeability" \
      "mergeable=${mergeable:-none} state=${mergestate:-none}")")
  else
    v3=no
    GATE_REASONS+=("$(reason no "GitHub does not report this pull request both mergeable and clean" \
      "mergeable=$mergeable state=$mergestate")")
  fi

  # V4 — blast radius. *Never minimal if merging it changes what runs
  # unattended.* There is deliberately **no diff-size ceiling**: a big change is
  # not a risky one, and a number saying otherwise would be unmeasured with an
  # asymmetric failure mode. Ninety files that touch nothing unattended merge.
  #
  # A file list longer than the page the read carries escalates, and that is a
  # different claim: not *this change is too big* but *this veto could not see*.
  # Merging on a list known to be partial would let a workflow change past the
  # page boundary through — the one thing the veto exists to stop — so the
  # unknown fails the way every other unknown here does.
  #
  # ponytail: it is still a hundred-file cliff an operator will experience as a
  # ceiling. Page the file connection until it is exhausted or a guarded path
  # turns up, and the cliff goes away along with this branch.
  if [[ "$truncated" == "true" ]]; then
    v4=no
    GATE_REASONS+=("$(reason no "the changed-file list is longer than one page, so the blast radius is unknown" \
      "files=$filecount listed=100")")
  elif [[ -n "$guarded" ]]; then
    v4=no
    GATE_REASONS+=("$(reason no "this pull request changes what runs unattended" \
      "files=$filecount guarded=$guarded")")
  else
    v4=ok
    GATE_REASONS+=("$(reason ok "nothing here changes what runs unattended" \
      "files=$filecount guarded=none")")
  fi

  if [[ "$v2" == "defer" || "$v3" == "defer" ]]; then deferred=true; fi

  # V5 — the clock, and it only exists because a `defer` is silent. It runs from
  # the head commit's date, so no pull request can sit undecided forever.
  #
  # Whether it has run out is decided **once**, here, and read twice below: the
  # row the handover carries and the verdict the loop acts on must never be able
  # to disagree about what the clock said.
  age=$(( now - head_epoch ))
  if (( age > MERGE_GATE_TIMEOUT )); then expired=true; fi
  if $deferred; then
    clock=" age=$age bound=$MERGE_GATE_TIMEOUT"
    if $expired; then
      GATE_REASONS+=("$(reason no "a signal is still undecided past the gate clock" \
        "age=${age}s bound=${MERGE_GATE_TIMEOUT}s head=$head_date")")
    else
      GATE_REASONS+=("$(reason defer "the gate clock has not run out yet" \
        "age=${age}s bound=${MERGE_GATE_TIMEOUT}s head=$head_date")")
    fi
  fi

  # **Escalate beats defer**, and a veto beats the clock: a pull request with
  # both a veto and an undecided signal is a handover about the veto, because
  # that is the one the operator can do something about.
  if [[ "$v1" == "no" || "$v2" == "no" || "$v3" == "no" || "$v4" == "no" ]]; then
    GATE_VERDICT=escalate
    GATE_KIND=escalate
  elif $deferred; then
    if $expired; then
      GATE_VERDICT=escalate
      # `stuck`, not `escalate`: nothing here said no, the signals simply never
      # arrived, and the kind is what tells the operator to go and look at the
      # checks rather than at the diff.
      GATE_KIND=stuck
    else
      GATE_VERDICT=defer
    fi
  else
    GATE_VERDICT=merge
  fi

  # `mergeability`, not `mergeable`: this is V3's *outcome*, and the raw
  # `mergeable=MERGEABLE` GitHub answered with travels in the handover's table.
  # One name for two different things is how a reader learns the wrong one.
  GATE_KV="verdict=$GATE_VERDICT risk=$v1 checks=$v2 mergeability=$v3 blast=$v4$clock"
}

# Run the PR phase for all configured projects. Enumerates open pull requests,
# derives state from GitHub, logs it, triggers CodeRabbit autofix, runs the risk
# gate over what is assessable, and escalates when appropriate.
pr_phase() {
  local i github method
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    github=$(jq -r ".projects[$i].github" "$CONFIG_PATH")
    # Validated against this repository's own permission booleans at startup, so
    # by here it is a method the repository is known to allow.
    method=$(jq -r ".projects[$i].mergeMethod" "$CONFIG_PATH")
    pr_phase_project "$github" "$method"
  done
}

# **At most one merge per repository per pass**, reset here, at the top of each
# repository — which is the axis the bound runs along, and the one configuration
# order already provides.
#
# A merge changes the base under every other open pull request in that
# repository: mergeability, check results and the commit each verdict was scoped
# to are all invalidated by it. So the loop merges once and then stops touching
# that repository's merge candidates, letting the next pass re-derive them from
# a base that has settled. Other repositories are unaffected, and **non-merge
# actions stay unbounded** — a trigger or a handover changes no base.
#
# Spent on the *attempt*, not on the success. A transient failure is the reason:
# it means no durable answer came back, so the merge may well have landed and
# the base may already have moved. A refusal did move nothing, but it escalates,
# and an escalated pull request is one the loop has stopped acting on anyway.
REPO_MERGE_SPENT=false

# Run the PR phase for one project. Queries open pull requests and processes
# each one through pr_phase_one.
pr_phase_project() {
  local github="$1" method="$2" numbers number labelled
  REPO_MERGE_SPENT=false
  if ! numbers=$(query_repo_open_prs "$github"); then
    log "pr query failed: $github"
    SKIPS=$((SKIPS + 1))
    return 0
  fi
  # stdin is closed for the body: gh-axi must not swallow the PR list.
  while IFS=$'\t' read -r number labelled; do
    [[ -n "$number" ]] || continue
    pr_phase_one "$github" "$number" "$labelled" "$method" < /dev/null
  done <<< "$numbers"
}

# One pull request, one pass, at most one action — and exactly one log line
# whichever way it goes. That line is the tested interface and, with no local
# state anywhere, the only record a wait leaves: a positional head naming the
# repository, the number, the commit and the state, then a `key=value` tail
# carrying the values the state was derived from. The tail is what keeps a new
# reason from being a suite-wide edit.
pr_phase_one() {
  local github="$1" number="$2" labelled="$3" method="$4"
  local response head head_date terminal threads status_at status_head trigger_at escalated
  local signal pending_at block limited nudge_at reply
  local now head_epoch status_epoch trigger_epoch pending_epoch nudge_epoch
  local spent in_flight age status unreviewed route origin
  local state review kv merge_out merge_status escalate_status

  if ! response=$(query_pr_state "$github" "$number"); then
    log "pr state query failed: $github#$number"
    SKIPS=$((SKIPS + 1))
    return 0
  fi
  # One value per line, not one tab-separated line: five of the fourteen are
  # routinely empty, and bash's `read` folds a run of tabs into a single
  # delimiter — so a pull request with no autofix status would silently have its
  # trigger read as its status, and every one of them would look spent.
  #
  # `|| true`, because a jq that answered nothing leaves `read` at end of input
  # and `set -e` would take the whole daemon down over one unreadable pull
  # request. The empty head below is what says so instead.
  head=""; head_date=""; terminal=""; threads=0; status_at=""; status_head=""; trigger_at=""
  escalated=false; signal=false; pending_at=""; block=""; limited=false; nudge_at=""; reply=""
  {
    read -r head
    read -r head_date
    read -r terminal
    read -r threads
    read -r status_at
    read -r status_head
    read -r trigger_at
    read -r escalated
    read -r signal
    read -r pending_at
    read -r block
    read -r limited
    read -r nudge_at
    read -r reply
  } < <(pr_facts <<< "$response") || true

  # The head commit is the identity used by `spent`, and its date is the origin
  # for the in-flight clock. A pull request that will not yield either is not
  # guessed at: an unparseable date read as epoch zero would make every trigger
  # appear newer than the head.
  head_epoch=$(epoch_of "$head_date") || head_epoch=""
  if [[ -z "$head" || -z "$head_epoch" ]]; then
    log "pr state unreadable: $github#$number"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  now=$(date -u +%s)
  # Empty when the comment is not there and empty when its timestamp would not
  # parse, which are the same thing to everything below: a comparison that
  # cannot be made is not made.
  status_epoch=$(epoch_of "$status_at") || status_epoch=""
  trigger_epoch=$(epoch_of "$trigger_at") || trigger_epoch=""

  # **Autofix is spent on this head** when the newest autofix-status comment is
  # paired with a trigger that records this head as its input. CodeRabbit's
  # visible `Commit:` is an output commit on success and `_none_` on failure, so
  # neither can identify the input. The loop records that identity in its own
  # trigger instead and never parses CodeRabbit's result prose.
  spent=unspent
  if [[ -n "$status_head" && "$status_head" == "$head" ]]; then
    spent=spent
  fi

  # In flight is the trigger paired with the answer: my trigger newer than the
  # head, and no autofix status posted since it. Unresolved threads cannot
  # bound this — autofix does not resolve the threads it fixes, which is the
  # decisive constraint on the whole design.
  in_flight=false
  age=0
  if [[ -n "$trigger_epoch" ]] && (( trigger_epoch > head_epoch )); then
    if [[ -z "$status_epoch" ]] || (( trigger_epoch > status_epoch )); then
      in_flight=true
      age=$(( now - trigger_epoch ))
    fi
  fi

  # **`U` — the pull request CodeRabbit never reviewed.** Two clauses, either
  # one enough, and the states below all test *this* rather than restating it,
  # so the chain cannot drift from the definition:
  #
  #   no signal   CodeRabbit put neither a status nor a check run on the head
  #   no block    there is no merge-risk block anywhere on the pull request
  #
  # The second clause is what makes a **green status that means no review ran**
  # visible. A `success` CodeRabbit status does not mean the code was reviewed:
  # a draft gets one too, with a *review skipped* description, and un-drafting
  # is not a push, so the head never moves. The discriminator is the missing
  # artifact, not the status and not the description — and the fact that makes
  # it safe was checked before anything was built on it: **a clean review still
  # carries the block**, so *no block* cannot mean *clean review*.
  #
  # It is cause-blind, which is why it also catches the rate-limit path's
  # *passing check* — a second, independent route to the same false green — and
  # why the documented list of other non-triggers never has to be tracked.
  #
  # Which clause fired goes in the tail rather than into a second state name:
  # the two routes are the same state and want the same remedy, and the log line
  # is where the difference belongs.
  unreviewed=false
  route=""
  if [[ "$signal" != "true" ]]; then
    unreviewed=true
    route="no-signal"
  fi
  if [[ "$block" == "absent" ]]; then
    unreviewed=true
    route="${route:+$route,}no-block"
  fi

  # First match wins.
  review=terminal
  [[ "$terminal" == "true" ]] || review=pending
  kv="review=$review threads=$threads autofix=$spent"

  # **Before every other test, and this is the whole of the handover rule.** Once
  # the loop has escalated this pull request at this head it takes no further
  # action on it at that head — no merge, no autofix trigger, no nudge — until
  # the head moves. A handover that kept acting would be a notification, and the
  # operator would learn to ignore it.
  #
  # The one thing that still happens here is **delivery**: the record is posted
  # and the flag may not be, so a missing label is added. That is the asymmetry
  # the write order buys — the report is retried until it lands, the action it
  # reports is never retried.
  if [[ "$escalated" == "true" ]]; then
    state=escalated
    if [[ "$labelled" == "labelled" ]]; then
      kv="$kv label=present"
    else
      status=0
      add_escalation_label "$github" "$number" || status=$?
      if (( status == 0 )); then
        kv="$kv label=added"
      else
        # The comment stands whatever happens here, so nothing is lost and
        # nothing is duplicated: the next pass reads the same marker and tries
        # the same one write again.
        kv="$kv label=failed rc=$status"
        SKIPS=$((SKIPS + 1))
      fi
    fi
  elif [[ "$signal" == "true" && "$review" != "terminal" ]]; then
    # A review that started and has not finished. This **is** a gate-style
    # `defer` — *a signal not yet computed* is its exact definition — so it
    # reuses the gate's key rather than inventing one. It was unbounded only
    # because V5 lives inside the gate and this short-circuits before reaching
    # it.
    #
    # **The origin is not `headDate`.** A real pull request sat four and a half
    # hours between its head commit and its review starting, and the rate-limit
    # exemption is designed to let a pull request wait hours — so a clock from
    # the commit would already be expired the instant a legitimate review began.
    # It runs from the oldest signal that has not reported instead.
    #
    # **And no nudge on this path.** Every term of the nudge argument inverts
    # here: CodeRabbit has already acknowledged the work, the command is
    # documented for the *paused* case, and a pending status is not a pause.
    #
    # The origin is named on the line as well as measured, because the whole
    # claim this phase makes is that every wait has a bound *and* an origin, and
    # a bound whose origin is not on the record cannot be checked against it.
    origin=pending
    pending_epoch=$(epoch_of "$pending_at") || pending_epoch=""
    if [[ -z "$pending_epoch" ]]; then
      # A signal that names no instant of its own — a check run GitHub has
      # queued and not yet started, whose `startedAt` is null. `headDate` is the
      # fallback, and it is the one place in this phase where using it is right:
      # a signal cannot predate the commit it sits on, so the commit is a lower
      # bound on when it began, and the clock can therefore only run *early*.
      #
      # Early is the safe direction here and nowhere else. The argument against
      # `headDate` is about a review that *started* late; this is a signal that
      # has not started at all, and a queued check still queued an hour after
      # the commit is the stuck case by any reading. An unbounded wait is
      # invisible; an early handover is not.
      origin=head
      pending_epoch="$head_epoch"
      pending_at="$head_date"
    fi
    age=$(( now - pending_epoch ))
    kv="$kv age=$age bound=$MERGE_GATE_TIMEOUT origin=$origin"
    if (( age <= MERGE_GATE_TIMEOUT )); then
      state=reviewing
    else
      # `stuck`, not `stalled`, and the break in the naming pattern is the
      # point: `stalled` means *a command was triggered and CodeRabbit never
      # answered*, this means *CodeRabbit answered and is still thinking*, and
      # the kind is what tells the operator whether to read the diff.
      state=review-stuck
      status=0
      escalate "$github" "$number" "$head" stuck \
        "$(reason ok "CodeRabbit acknowledged this commit — the review started" \
             "oldest-pending=$pending_at origin=$origin head=$head_date")" \
        "$(reason no "the review has not finished inside the gate clock" \
             "age=${age}s bound=${MERGE_GATE_TIMEOUT}s")" \
        || status=$?
      kv="$kv $(escalation_kv stuck "$status")"
      (( status == 0 )) || SKIPS=$((SKIPS + 1))
    fi
  elif $in_flight; then
    kv="$kv age=$age bound=$AUTOFIX_TIMEOUT"
    if (( age <= AUTOFIX_TIMEOUT )); then
      state=autofix-in-flight
    else
      # The first state with a caller into the handover. A command was
      # triggered and CodeRabbit never answered inside its bound, which is what
      # `stalled` means; the row that *passed* goes into the record too, because
      # "the review finished and the fix did not" is what tells the operator to
      # go and look at CodeRabbit rather than at the diff.
      state=autofix-stalled
      status=0
      escalate "$github" "$number" "$head" stalled \
        "$(reason ok "CodeRabbit's review finished on this commit" \
             "review=$review threads=$threads")" \
        "$(reason no "the autofix trigger has gone unanswered past its bound" \
             "trigger=$trigger_at age=${age}s bound=${AUTOFIX_TIMEOUT}s head=$head_date")" \
        || status=$?
      kv="$kv $(escalation_kv stalled "$status")"
      (( status == 0 )) || SKIPS=$((SKIPS + 1))
    fi
  elif $unreviewed; then
    kv="$kv route=$route"
    # **The rate-limit marker is tested first**, and a match waits rather than
    # nudging: a throttled reviewer is not a paused one, and nudging it would
    # escalate the whole queue whenever the reviewer is merely slow.
    #
    # This is the one state in the phase with **no loop-owned clock**, and that
    # is recorded as correct rather than left as a hole: unlike the review
    # pause, the rate limit **self-clears** as usage ages out, so its bound is
    # external — the fair-usage rolling window, and the estimate the comment
    # ships with.
    if [[ "$limited" == "true" ]]; then
      state=rate-limited
    else
      nudge_epoch=$(epoch_of "$nudge_at") || nudge_epoch=""
      if [[ -n "$nudge_epoch" ]] && (( nudge_epoch > head_epoch )); then
        # The bound is **one poll interval** — no new config key and no new
        # clock — and that is a measurement rather than a convenience: command
        # replies and review-queued statuses arrive in *seconds*, where autofix
        # earned a key of its own at nearly eighteen minutes.
        #
        # The nudge's **created** timestamp is the one read, correct here
        # specifically because the loop authors it. The updated-timestamp
        # binding is about comments CodeRabbit edits.
        age=$(( now - nudge_epoch ))
        kv="$kv age=$age bound=$POLL_INTERVAL"
        if (( age <= POLL_INTERVAL )); then
          state=nudge-in-flight
        else
          # Past the bound with still no status. `stalled`, like the autofix
          # clock: a command was triggered and CodeRabbit never answered.
          #
          # The bound is **cause-blind** — a curable cause was cured by the
          # nudge, an incurable one arrives here — so none of the documented
          # non-triggers is tracked. The two an operator can act on are named
          # all the same, because a handover exists to be acted on.
          state=nudge-stalled
          status=0
          escalate "$github" "$number" "$head" stalled \
            "$(reason ok "the review nudge was posted at this head" \
                 "nudge=$nudge_at route=$route head=$head_date")" \
            "$(reason no "CodeRabbit never reported a review inside the bound — it may not be installed on this repository, or the organisation may be out of seats" \
                 "age=${age}s bound=${POLL_INTERVAL}s nudge=$nudge_at")" \
            "$(reason note "CodeRabbit's reply to the nudge, verbatim and unparsed" \
                 "${reply:-none}")" \
            || status=$?
          kv="$kv $(escalation_kv stalled "$status")"
          (( status == 0 )) || SKIPS=$((SKIPS + 1))
        fi
      else
        # The remedy, and it is a **write** because the cause does not clear on
        # its own: CodeRabbit auto-pauses incremental reviews after five
        # reviewed commits and the counter resets only when the pause is lifted,
        # which is a command. *Wait longer* was never an exit.
        #
        # Once per head, decided by the nudge being newer than the head commit.
        # The command is one-shot, so a pull request taking pushes re-wedges
        # roughly every five commits and is nudged again at each new head — the
        # stated cost of choosing the measured verb.
        state=unreviewed
        status=0
        post_review_nudge "$github" "$number" || status=$?
        if (( status == 0 )); then
          kv="$kv action=nudged"
        else
          # Nothing is remembered, so nothing has to be unwound: the next pass
          # re-derives, finds the pull request still unreviewed and still
          # un-nudged, and writes again. The poll interval is the backoff.
          kv="$kv action=failed rc=$status"
          SKIPS=$((SKIPS + 1))
        fi
      fi
    fi
  elif (( threads > 0 )) && [[ "$spent" == "unspent" ]]; then
    state=needs-autofix
    status=0
    post_autofix_trigger "$github" "$number" "$head" || status=$?
    if (( status == 0 )); then
      kv="$kv action=triggered"
    else
      # Nothing is remembered, so nothing has to be unwound: the next pass
      # re-derives, finds autofix still unspent on the same head, and fires
      # again. The poll interval is the whole of the backoff. It still counts
      # against the pass, because `pass end` is where a run that achieved
      # nothing is supposed to say so.
      kv="$kv action=failed rc=$status"
      SKIPS=$((SKIPS + 1))
    fi
  else
    # The gate. Every veto evaluates, the verdict lands in the tail, and a
    # `defer` is silent by design and re-derived next pass.
    state=assessable
    if ! risk_gate "$head" "$head_date" "$head_epoch" "$now" "$response"; then
      log "pr gate unreadable: $github#$number"
      SKIPS=$((SKIPS + 1))
      return 0
    fi
    kv="$kv $GATE_KV"
    if [[ "$GATE_VERDICT" == "escalate" ]]; then
      status=0
      # The `[@]+` guard is bash 3.2 refusing to expand an empty array under
      # `set -u`. Every veto appends a row, so this can never be empty — and the
      # cost of being wrong about that is the daemon dying mid-pass.
      escalate "$github" "$number" "$head" "$GATE_KIND" \
        "${GATE_REASONS[@]+"${GATE_REASONS[@]}"}" || status=$?
      kv="$kv $(escalation_kv "$GATE_KIND" "$status")"
      (( status == 0 )) || SKIPS=$((SKIPS + 1))
    elif [[ "$GATE_VERDICT" == "merge" ]]; then
      # The line the whole daemon exists to cross. Everything before it is
      # reversible; this is not, so the three things that make crossing it safe
      # are all here: the commit named is the one the gate assessed, the bound
      # is spent before the write rather than after it, and the flag holds the
      # write and nothing else.
      if $REPO_MERGE_SPENT; then
        # Deferred to the next pass rather than dropped, and said out loud: with
        # no local state this line is the only record the candidate leaves.
        kv="$kv action=deferred bound=merge-per-repo"
      elif $NO_MERGE; then
        # The bound is spent here too, so a `--once --no-merge` run reports the
        # same set of actions a real pass would take rather than every candidate
        # it could see. The flag withholds the write, not the arithmetic.
        REPO_MERGE_SPENT=true
        kv="$kv action=would-merge method=$method"
      else
        REPO_MERGE_SPENT=true
        merge_status=0
        merge_out=$(merge_pr "$github" "$number" "$head" "$method") || merge_status=$?
        case "$merge_status" in
          0)
            # Branch deletion needs no key and no call: the repository's
            # delete-on-merge setting is honoured by GitHub on the merge itself.
            kv="$kv action=merged method=$method"
            ;;
          3)
            # Refused: GitHub answered, durably, no. Its own kind, because *I
            # said yes and reality disagreed* is evidence the rubric is wrong
            # rather than a fact about this pull request — and the record
            # carries what GitHub said, verbatim, alongside the rows that led
            # the gate to say yes.
            #
            # A merge racing a human push arrives here: the assertion on the
            # assessed commit loses with a 409, which classifies refused. It
            # escalates rather than retrying, which is the whole point of
            # asserting the commit at all.
            escalate_status=0
            escalate "$github" "$number" "$head" refused \
              "${GATE_REASONS[@]+"${GATE_REASONS[@]}"}" \
              "$(reason no "GitHub refused the merge of the commit the gate cleared" \
                   "rc=$merge_status method=$method head=$head response=${merge_out:-none}")" \
              || escalate_status=$?
            kv="$kv merge=refused rc=$merge_status $(escalation_kv refused "$escalate_status")"
            # Only a handover that did not land counts against the pass. The
            # refusal itself is not a skip: the loop set out to act on this pull
            # request and did — the action turned out to be the handover.
            (( escalate_status == 0 )) || SKIPS=$((SKIPS + 1))
            ;;
          4)
            # Transient: the call did not get a durable answer. **Not escalated
            # and not retried within the pass** — the poll interval is the whole
            # of the backoff, retrying a merge is idempotent because an
            # already-merged pull request answers 200, and the next pass
            # re-derives everything from a fresh read.
            kv="$kv merge=failed class=transient rc=$merge_status"
            SKIPS=$((SKIPS + 1))
            ;;
          *)
            # The seam's exit 1 — an argument error, or a fatal failure of the
            # seam itself. Nothing was classified, so nothing durable is known,
            # and the posture is the transient one: say so, act no further, let
            # the next pass re-derive.
            kv="$kv merge=failed class=unknown rc=$merge_status"
            SKIPS=$((SKIPS + 1))
            ;;
        esac
      fi
    fi
  fi

  log "pr $github#$number $head $state $kv"
}

# --- close-out phase ---------------------------------------------------------

# Merged pull requests, one global search narrowed to the configured
# repositories by `nameWithOwner` afterwards. The open-pull-request read used to
# be the same shape and no longer is — it runs per repository now — but this one
# deliberately did not widen with it: the branch name is the only
# pull-request-to-issue link there is, and `author:$ME` is what keeps the
# resolver looking at branches this loop cut.
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

# Run the closeout phase: query merged pull requests authored by this loop,
# identify their corresponding issues, tick checklists, and close them.
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

# Close out a single merged pull request: tick the checklist in the linked
# issue's description and close the issue. Only acts on open issues with the
# claimed label that belong to configured projects. Silently skips pull requests
# opened by hand (branch names no issue) and issues already closed or claimed by
# hand.
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

# Run one complete pass: load the worktree inventory, run closeout, issue, and
# PR phases, then sweep finished worktrees. Logs pass start, end, and summary.
run_pass() {
  log "pass start"
  DISPATCHES=0
  SKIPS=0
  SWEEPS=0
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
    --no-merge) NO_MERGE=true; shift ;;
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
