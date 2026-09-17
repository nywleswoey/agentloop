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
# One poll interval (#129): a runtime back within one cycle never costs a
# restart, and one that is not ends the loop into a death record.
RUNTIME_WAIT_SECONDS="${AGENT_LOOP_RUNTIME_WAIT_SECONDS:-300}"
ONCE=false
BRANCH_REPORT=""
LOG_PATH=""
# The log-sized name of what is loaded. Filled in by measure_build once, before
# startup work that can move HEAD.
BUILD=""
# The full object ID behind BUILD. Kept separate so a changing abbreviation
# length cannot look like drift when HEAD itself has not moved.
BUILD_COMMIT=""
# Holds the one irreversible write and nothing else. A flag rather than a config
# key on purpose: a persistent switch would be the confirmation gate this whole
# effort replaced walking back in as a boolean, and a `false` left in a file is a
# forgettable bypass. A flag is scoped to one invocation, grants nothing, and
# only withholds. With `--once` it is a genuine dry run.
NO_MERGE=false
# What the death record (#129) is built from, all of it memory: the message
# `die` stashes before it exits, whether the loop began passing, how many passes
# it finished, the drift the last of them measured, and when the process began.
FATAL_MESSAGE=""
BEGAN_PASSING=false
PASSES=0
LAST_DRIFT=unknown
STARTED_AT=""

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
# The walkthrough comment, which carries the verdict the risk gate reads.
#
# The walkthrough is the comment CodeRabbit *edits* rather than replaces, which
# is why freshness anywhere near it is the **updated** timestamp: observed gaps
# of five and seven days sit between a walkthrough's creation and the edit that
# carries today's verdict.
#
# The rate-limit block that edit can also carry is deliberately not read — see
# the commentary at the top of risk_gate's vetoes.
WALKTHROUGH_MARKER='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->'
# The merge-risk verdict, delimited inside the walkthrough. Its shape is
# `**Merge Risk:** _<emoji> <Level>_ · up to \`<abbrev>\`` — and the abbreviation
# is **five** characters on every capture taken, not the seven the prose around
# this feature says, which is exactly why the test is a prefix test rather than
# a length-sensitive one.
RISK_BLOCK_MARKER='<!-- final_review_risk_start -->'
# The parse of that block, as a jq definition, because **two readers need it**:
# the chain, to ask whether the verdict names the head it is about to act on,
# and the gate, to judge the level it carries. Spelled once and concatenated
# into both programs rather than copied into each — a second copy is how the two
# come to disagree about which commit a verdict covers, and that is the one
# disagreement neither of them could detect from its own side.
#
# `capture` emits nothing at all on no match, so the result is collected into an
# array and indexed: bound bare, an unparseable block would make the whole
# program produce no output rather than say the block was unparseable.
#
# It re-spells the marker above rather than taking it as an argument, and unlike
# the trigger's two copies that is a limitation rather than a choice: this is a
# jq *program fragment*, so the marker would have to reach it as a `--arg` every
# caller passes and then be spliced into a regex — where the `<!--` would need
# escaping and a marker that gained a metacharacter would silently stop
# matching. The copies cannot drift far: a marker changed here and not there
# reads every block as unparseable, which V1 escalates on loudly. There is no
# such backstop for the trigger, which is why that one is pinned by a test.
RISK_BLOCK_PARSE='def risk_block:
  [ (. // "") | capture("final_review_risk_start -->\\s*\\*\\*Merge Risk:\\*\\*\\s*_(?<level>[^_]+)_\\s*·\\s*up to `(?<abbrev>[0-9a-fA-F]+)`") ] | .[0];
'

# The risk gate's own policy — the loop's, not CodeRabbit's. These say what the
# loop will and will not merge unattended, and unlike everything above them a
# change here is a change of mind rather than a change of surface.
#
# The levels that clear V1, space-separated. There is no documented ladder —
# searches across CodeRabbit's own documentation found the feature described
# nowhere at all — so an ordering cannot be assumed: this is an **allowlist**,
# and a level not named here escalates, however low it sounds. `low` joined
# `minimal` because the observed levels run Minimal, Low, Moderate, High, and
# `low` alone was handing over pull requests nothing else vetoed.
RISK_LEVELS_CLEAR='minimal low'
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
# The one description that means a review actually ran. **An allowlist of a
# single value, never a denylist** — the vocabulary is a closed set *observed*
# rather than a documented interface, so a value CodeRabbit renames must read as
# *ask again* and never as an acceptance. A denylist would read a rename as an
# acceptance and stop, which is the one direction *degrade toward asking*
# forbids.
#
# The rule for the whole project, stated once here: the description is **control
# input only through this one comparison**, and **diagnosis input only
# verbatim**. Nothing in between. No branch anywhere tests a description against
# a second string, because doing so would mint a loop-owned vocabulary out of
# CodeRabbit's.
CODERABBIT_STATUS_REVIEWED='Review completed'
# The handover's two surfaces, and the loop's own — not CodeRabbit's.
#
# The marker is what makes "a record stands at this head" a fact the phase reads
# for free: it is in the comment timeline the derivation already fetches, so
# detection costs zero new reads. It carries the head commit and the kind, in
# that order, and **nothing else** — no author, and no verdict rows. A commit is
# what a handover is scoped to; the kind is there because the latch has to be
# able to tell *the same claim, still true* from *a different claim about the
# same commit*, and it cannot ask that of a kind-blind marker. The rows stay out
# of it because they are the previous version of the comment being edited, which
# arrives on the same read — a payload here would be a second copy of them for
# the latch to parse and to disagree with.
#
# **The match is a `contains` on the head, with the kind read out separately.**
# A marker posted before the kind existed still matches, so nothing standing is
# orphaned; it simply reports no kind, which equals no kind the chain can
# derive, so it retracts and re-posts once and is migrated.
#
# The label is the flag rather than the record. One name serves all four kinds
# so that every escalated pull request across every repository is one
# open-pull-requests query away, and it is a constant rather than a config key
# because a per-operator name would make that one query impossible to write
# down. **It chases the marker in both directions** — added when a record stands
# and it is missing, taken off on the first pass after the marker stops matching
# — which is what keeps that one query from filling with pull requests the loop
# let go of hours ago.
ESCALATION_MARKER_PREFIX='<!-- agent-loop-escalated: '
ESCALATION_MARKER_SUFFIX=' -->'
# The withdrawal notice's own marker — the escalation marker's shape, one prefix
# over, and read the same way: a `contains` on prefix-plus-head with the kind
# read out separately.
#
# **It is a spend record, not a claim.** The one thing the withdrawal notice may
# not carry is a live verdict, because a record written against a moving signal
# is the exact defect the retraction path exists to correct. This asserts
# nothing about mergeability and carries no rows: it says the loop wrote a
# record of that kind at that commit and then took it down, which is
# permanently true of that head and moves with nothing.
#
# **What it buys is the one head-keyed fact that survives a withdrawal.** A
# standing record is itself a merge spend — no merge write happens while one
# stands, whatever its kind — so un-latching used to take the spend down with
# the record, and a head whose refusal was permanent merged again, was refused
# again, and grew a fresh comment every second pass, unbounded, on a pull
# request already asking for a human. The token is what the pass after a
# withdrawal reads instead.
#
# **A distinct prefix, so the two tests cannot see each other.** *A record
# stands at this head* is a `contains` on `<!-- agent-loop-escalated: <head>`
# and this is `<!-- agent-loop-withdrawn: <head>`; neither string contains the
# other, so a withdrawn marker never reads as a standing record and a standing
# record never reads as a withdrawal.
#
# **One vocabulary read two ways, rather than two vocabularies.** A bespoke
# `refused`-only token would be narrower, but it would mint a second marker
# shape and put a kind-shaped branch inside a function whose kind-blindness is
# settled: the marker is written on every retraction, of every kind, and only
# the reader asks which kind it names.
#
# **Tokens accumulate at a head rather than replacing one another, and the read
# is a set test because of it.** A record standing at a head the loop has
# already withdrawn one at is posted as a *new* comment — the withdrawn one
# carries no record marker to write over — so the older notice survives beside
# it, and its own withdrawal later writes a second token elsewhere on the
# timeline. A read that took only the newest would let a `stuck` withdrawal
# mask a `refused` one at the same commit and re-arm a merge GitHub durably
# refused. What each token says is true of that commit forever, so *any* of
# them naming a kind is that kind's spend.
WITHDRAWN_MARKER_PREFIX='<!-- agent-loop-withdrawn: '
WITHDRAWN_MARKER_SUFFIX=' -->'
LABEL_ESCALATED='agent-escalated'
# The flag on an issue the loop refuses to dispatch: one refusal, one label, and
# the reason in the comment rather than in the name. A constant for the same
# reason the escalation label is one — a per-operator name makes the single
# query that finds every refused issue impossible to write down — and separate from
# `agent-escalated` because the two have opposite lifecycles and that one's
# query is over pull requests: one query answers which issues the loop refused,
# and a different one which pull requests need a human.
#
# **It is a live flag, not a latch.** The issue phase re-derives the predicates
# behind it on every pass it can see the issue, adds it with the swap that takes
# `ready-for-agent` off, and takes it back off on its own the first pass they all
# pass. The comment it goes on with is the opposite: a record of an event, never
# withdrawn.
LABEL_REFUSED='agent-refused'

# The verbs. An issue declares what the loop should *do* with it in its labels,
# on top of the ready label, and the loop dispatches by that declaration: a
# ticket is implemented, a spec is decomposed into tickets. There is no default
# — an issue declaring none, or both, is refused rather than dispatched under a
# guess — because a forgotten label costs a stalled issue you can see and a
# default costs a wrong build you find out about later.
#
# **Constants rather than config keys**, and for a different reason than the two
# flags above: a verb name is *welded to a prompt string*. `labels.ready` and
# `labels.claimed` are config because the loop only ever compares them to
# themselves — rename them and nothing downstream cares. A verb names a slash
# command that has to exist in the worker's skill set, so an operator-supplied
# name behind a hardcoded prompt is incoherent: renaming it either breaks the
# dispatch or changes nothing.
#
# Bare words with no namespace prefix. The `::` the change-type reader parses is
# code-only — no label in any configured repository uses it — and the ones that
# do carry a namespace use a single colon, so following the code's convention
# would put a third punctuation style in one label list.
VERB_IMPLEMENT='implement'
VERB_TO_TICKETS='to-tickets'

# The marker on a spec the loop decomposed. Terminal, latching, and **not** a
# reuse of `agent-escalated`: that one means *the loop refused to act* and this
# means the opposite, its writes go through the pull-request seam rather than
# through an issue edit, and — decisively — a handover is deliberately
# un-latching, re-derived every pass and withdrawn when it stops being true.
# This records a one-shot historical fact that no pass re-derives, so under a
# label whose whole contract is not-latching the first thing to touch it would
# take it down.
LABEL_DECOMPOSED='agent-decomposed'

# The one definition of *which of the loop's own labels an issue is wearing*,
# shared by both readers of the label queries. It is a jq fragment rather than
# two copies because the two streams have to agree on it exactly: the verb the
# gate refuses on and the verb close-out scopes on are the same fact, read off
# two different payload shapes, and a second copy is a second chance for them to
# disagree.
#
# Three properties, all load-bearing:
#
#   - **Evidence, not a conclusion.** `reason`'s contract is the raw values that
#     produced the judgement. *You wrote no verb* and *you wrote both verbs*
#     need opposite fixes from the operator reading the refusal, so the column
#     names what was found rather than the verdict it produced.
#   - **Never empty.** A tab is IFS whitespace, so `read` collapses a run of
#     them and an empty field anywhere but the end of the line disappears,
#     shifting every field after it up. A verbless issue would then reach the
#     gate declaring its own *title* as its verb. `-` is the placeholder that
#     stops that.
#   - **Whitespace-free by construction**, because it is an intersection with a
#     closed set of constants — so it can never pick up an operator label
#     containing a space, which is the property that keeps the title last.
#
# The order is the *set's* order and not GraphQL's, so a fixture is
# deterministic and an issue wearing its labels the other way round produces the
# same line.
OWN_LABELS_JQ='
  def own(set):
    [.labels.nodes[]?.name] as $names
    | [set[] | select(. as $l | $names | index($l))]
    | if length == 0 then "-" else join(",") end;'
# Reset at the top of every pass. Initialised here only because the close-out
# that runs before the first pass bumps them too, and `set -u` would kill them
# otherwise — what they count before the first pass is discarded, which is why
# that close-out reports one line per issue rather than a total.
SKIPS=0
REFUSALS=0
FAILURES=0

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
  AGENT_LOOP_RUNTIME_WAIT_SECONDS   how long to wait for the Orca runtime (default 300)

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

# Log a fatal error and exit with status 1. The message is stashed first, where
# the EXIT trap's death record reads it, so it survives a log that cannot write.
# Only a `die` in the main shell reaches it: one inside `$(...)` or a pipeline
# sets the subshell's copy, and its parent's death is recorded as having no
# fatal message.
die() {
  FATAL_MESSAGE="$*"
  log "fatal: $*"
  exit 1
}

# --- the failure family --------------------------------------------------------

# A read that did not answer or a write that did not land, as decided in #124.
# **Membership is a call to `read_failed` or `write_failed`**, so `grep` over
# those two names is the family's whole list, and nobody joins it by typing
# `log ...; SKIPS=$((SKIPS + 1))` the way all twenty-three sites used to.
#
# **What a failure means is not decided here.** Each entry point takes the
# class `gh_error_class` printed, because gh.sh is the one place that reads it
# and it lived twice before and drifted. What changed is that the verdict now
# reaches the call sites at all: every wrapper between the seam and the family
# used to `|| return 1` or pipe into `jq`, and a call site saw a bare exit code.
# So a wrapper captures its response before `jq` and passes the failure text
# out — on stdout when it is called in a substitution, in `$FAILURE_TEXT` when
# it is called bare — the same split gh.sh's own header draws.
#
# **git and Orca join without a second code path.** Neither has a classifier,
# and their call sites classify empty text, which gh.sh already calls
# transient for the reason that applies here too: a failure that says nothing
# about the object says only *ask again*.
#
# **Two names rather than one with a kind argument**, because the two halves
# expire differently — a refused read dies, a refused write flags its object —
# and a kind argument would make the wrong expiry reachable by typo, silently.
#
# The skip accounting stays at each call site. `skips=` is unchanged by this
# family; `failures=` is its own count, and only these two move it.
FAILURE_TEXT=""

# read_failed <class> <project> <line>
#
# **Transient: the skip is the exit, and the half is deliberately unbounded.**
# A bound is a clock and a clock needs an origin, and a failed read carries
# none — that is what makes it a failed read. Manufacturing one would take a
# marker write for a wait that never fired in 513 passes, and that write would
# itself be a member of this family. So the line says which kind it was, the
# pass counts it, and the next pass re-derives from scratch.
#
# **Refused: `die`, with the project on the line.** A refused read is not a
# wait but an answer — a token scope, a config entry, a repository somebody
# renamed — and asking again next pass is re-asking a question already
# answered. The reader's action is on none of the loop's GitHub objects, so a
# comment there would be a handover with nothing for its reader to do. The
# stated cost: one repository's 404 stops every other project. Taken
# deliberately, over a loop that quietly serves two of three projects forever.
#
# Anything but `refused` is transient, which is the classifier's own default
# pointing the same way.
read_failed() {
  local class="$1" project="$2" line="$3"
  if [[ "$class" == "refused" ]]; then
    die "$line class=refused project=$project"
  fi
  log "$line class=transient"
  FAILURES=$((FAILURES + 1))
}

# write_failed <class> <issue|pr|-> <github> <number> <write> <line>
#
# The object is the issue or pull request the write targeted, named by kind,
# repository and number, and <write> is a short name for the write itself.
# `-` is a write with no GitHub object, which only Orca makes and which can
# therefore only ever be transient.
#
# An empty <line> is a write whose caller reports it on a line of its own — the
# pull-request chain, whose one state line per pull request is logged at the
# bottom of the pass and carries `class=` in its tail.
#
# **Transient: exactly as for a read.** One failed write costs one poll
# interval, the next pass re-derives and writes again, and the line says so.
#
# **Refused: `agent-escalated` and one record, on the object the write
# targeted.** This is the one case in the family where the reader's action is
# on a GitHub object — restore a deleted label, reopen or unlock the issue, fix
# the branch protection — so, unlike a refused read, the record belongs there.
# The alternatives were rejected on #124: `die` throws every other project
# away over one object's fault, and leaving the write in the transient row
# makes *leaving it claimed* permanent, because a refused write never lands.
#
# **A live flag, not a latch.** The predicate behind it is the write attempt
# itself, which the loop makes every pass it reaches the object anyway, so the
# flag comes off on the pass the write lands — see `withdraw_write_flag` — and
# nothing is remembered in between.
#
# **One record however many passes refuse it**, gated by a marker in the
# object's own comments, the shape the pull-request handover already uses.
#
# **An escalation write that is itself refused dies.** That is what makes the
# read half and the write half one policy: a global permission loss refuses the
# escalation too and sorts itself into the refused-read answer, while a 422 on
# one issue's label stays on that issue with every other project still running.
write_failed() {
  local class="$1" kind="$2" github="$3" number="$4" write="$5" line="$6"
  # Taken before anything below can clear it.
  local text="$FAILURE_TEXT"
  [[ "$class" == "refused" ]] || class=transient
  if [[ -n "$line" ]]; then
    log "$line class=$class"
  fi
  FAILURES=$((FAILURES + 1))
  [[ "$class" == "refused" ]] || return 0
  # Unreachable today — only Orca makes a write with no object, and Orca never
  # classifies refused — and an answer all the same: a refused write with nowhere to
  # put its record is an escalation that cannot be written.
  if [[ "$kind" != "issue" && "$kind" != "pr" ]]; then
    die "$write refused with no object to flag class=refused"
  fi
  escalate_refused_write "$kind" "$github" "$number" "$write" "$text"
}

# gh-axi for one write, with stdout — where a refusal GitHub rendered arrives —
# left in `$FAILURE_TEXT` when it fails, for a caller that calls it bare.
# stderr is dropped, as `gh_json` drops it. `swap_labels` and the writeback
# seam do read it — merged in, or where stdout is empty — and that changes no
# class against the real CLI: its own failures on stderr carry no status, so
# they classify transient whichever channel they are read from.
axi_write() {
  local out
  FAILURE_TEXT=""
  out=$(gh-axi "$@" 2>/dev/null) && return 0
  FAILURE_TEXT="$out"
  return 1
}

# The same, for the writeback seam, whose stdout is the write's response
# verbatim — the refusal text included — by its own contract.
writeback_write() {
  local out
  FAILURE_TEXT=""
  out=$("$SCRIPT_DIR/pr-writeback.sh" "$@" 2>/dev/null) && return 0
  FAILURE_TEXT="$out"
  return 1
}

# The refused write's record marker. A distinct prefix from the handover's two,
# so no test for a standing record or a withdrawal can see it, and it names the
# write so each refused write on one object is recorded once of its own.
WRITE_REFUSED_MARKER_PREFIX='<!-- agent-loop-write-refused: '
WRITE_REFUSED_MARKER_SUFFIX=' -->'

# Every object a refused write escalated this pass, as ` <github>#<number> `
# words. Read where a flag would otherwise be taken off on the pass it went up:
# the pull-request chase, and a later write on the same issue that landed.
#
# **Per pass rather than per object**, because one issue can be reached twice
# with different writes: close-out's merged path and then the reclaim run over
# the same claims, and a close refused on the merged path must not have its flag
# taken down by the reclaim's release landing a moment later. Cleared at the top
# of every pass.
WRITE_ESCALATED_OBJECTS=""

# write_escalated <github> <number> — whether a refused write escalated this
# object this pass.
write_escalated() {
  [[ "$WRITE_ESCALATED_OBJECTS" == *" $1#$2 "* ]]
}

write_refused_body() {
  local kind="$1" write="$2" text="$3" noun=issue
  [[ "$kind" == "pr" ]] && noun="pull request"
  printf '**Escalated — GitHub refused the loop'"'"'s `%s` on this %s.**\n\n' "$write" "$noun"
  printf 'GitHub'"'"'s answer is a durable no, so asking again every pass will not land it on its own. The loop still makes the write each pass it reaches this %s, and takes `%s` off by itself on the pass it lands. This comment is a record of that answer and stays.\n\n' "$noun" "$LABEL_ESCALATED"
  # Four backticks, so a response carrying a fence of its own cannot close it.
  printf 'What GitHub said, verbatim:\n\n````\n%s\n````\n\n' "${text:-gh-axi said nothing}"
  printf '**Where to look** — a label somebody deleted, an issue or pull request locked, transferred or closed by hand, or a rule on this repository the loop'"'"'s token cannot satisfy.\n\n'
  printf '%s%s%s\n' "$WRITE_REFUSED_MARKER_PREFIX" "$write" "$WRITE_REFUSED_MARKER_SUFFIX"
}

# escalate_refused_write <issue|pr> <github> <number> <write> <text>
#
# Record, then flag, in that order and for the handover's reason: a flag with no
# record behind it is the one state the reader cannot act on, and a later pass
# that finds the record and no flag adds the flag without posting again.
#
# The gate is a read of the object's comments, paged in full, rather than the
# label: the label is shared by every kind of *a human must look*, so it cannot
# say whether *this* refused write was recorded. The read is paid only on a
# refused write,
# which has not fired once in 513 passes. Both object kinds answer on the issues
# endpoint, since GitHub numbers them from one sequence.
#
# Each of these writes is a member of the family in its own right, and joins it
# through the same door with no object: a transient one is logged and counted
# and the next pass tries again from the top; a refused one dies here.
escalate_refused_write() {
  local kind="$1" github="$2" number="$3" write="$4" text="$5"
  local marker comments seen file posted=false status=0 class
  WRITE_ESCALATED_OBJECTS+=" $github#$number "
  marker="$WRITE_REFUSED_MARKER_PREFIX$write$WRITE_REFUSED_MARKER_SUFFIX"

  if ! comments=$(gh_json "/repos/$github/issues/$number/comments" --paginate); then
    read_failed "$(gh_error_class "$comments")" "$github" \
      "refused-write record unreadable on $github#$number, flagging nothing this pass"
    return 0
  fi
  if ! seen=$(jq -r --arg me "$ME" --arg marker "$marker" \
       'any(.[]?; (.user.login // "") == $me and ((.body // "") | contains($marker)))' \
       <<< "$comments" 2>/dev/null) || [[ "$seen" != "true" && "$seen" != "false" ]]; then
    read_failed "$(gh_error_class "")" "$github" \
      "refused-write record unreadable on $github#$number, flagging nothing this pass"
    return 0
  fi

  if [[ "$seen" == "false" ]]; then
    # Free text travels as a file, as every other record here does.
    if ! file=$(mktemp "${TMPDIR:-/tmp}/agent-loop-refused-write.XXXXXX"); then
      FAILURE_TEXT=""
      status=1
    elif ! write_refused_body "$kind" "$write" "$text" > "$file"; then
      FAILURE_TEXT=""
      status=1
    elif [[ "$kind" == "pr" ]]; then
      writeback_write comment --repo "$github" --pr "$number" --body-file "$file" || status=1
    else
      axi_write issue comment "$number" --repo "$github" --body-file "$file" || status=1
    fi
    [[ -z "$file" ]] || rm -f "$file"
    if (( status != 0 )); then
      class=$(gh_error_class "$FAILURE_TEXT")
      [[ "$class" != "refused" ]] \
        || die "refused-write record refused on $github#$number class=refused project=$github"
      write_failed "$class" - "" "" record "refused-write record failed on $github#$number, flagging nothing this pass"
      return 0
    fi
    posted=true
  fi

  if [[ "$kind" == "pr" ]]; then
    writeback_write label --repo "$github" --pr "$number" --add "$LABEL_ESCALATED" || status=1
  else
    axi_write issue edit "$number" --repo "$github" --add-label "$LABEL_ESCALATED" || status=1
  fi
  if (( status != 0 )); then
    class=$(gh_error_class "$FAILURE_TEXT")
    [[ "$class" != "refused" ]] \
      || die "refused-write flag refused on $github#$number class=refused project=$github"
    write_failed "$class" - "" "" flag "refused-write flag failed on $github#$number, the record is up and the next pass adds it"
    return 0
  fi
  # Said on the attempt that put the record up, and never again: the site's own
  # line already says `class=refused` on every pass after.
  if $posted; then
    log "$github#$number flagged $LABEL_ESCALATED: its $write was refused"
  fi
}

# withdraw_write_flag <github> <number> <flagged|unflagged> [why]
#
# The other half of the live flag, on an issue: called where a family write on
# it landed, with whether the issue wore the flag — the word the label streams
# already use for a flag — read off a payload the caller
# already holds, so steady state costs nothing and a withdrawal costs one write.
# Pull requests need no call: the handover's label chase already takes the flag
# off on any pass with no record standing and no refused write this pass.
#
# Not on a pass where a refused write escalated this same issue: a close that
# landed would take down the flag its unclaim just raised, and a reclaim that
# landed the flag a refused close raised earlier in the same pass.
#
# **The flag is kind-blind**, and on an issue that is safe by construction
# rather than by luck: every other *a human must look* kind on an issue is
# withdrawn when the claim goes or the work delivers, which are exactly the
# writes that call this. The line names the refused write unless the caller
# names a cause of its own: the decomposition swap is also what takes down the
# spec handover's flag (#140).
#
# The withdrawal is an escalation write, and fails like one: refused dies,
# transient is retried by the next pass that lands the same write — and where
# no later pass will, the flag stands until a human takes it off.
withdraw_write_flag() {
  local github="$1" number="$2" wore="$3" why="${4:-its refused write landed}" class
  [[ "$wore" == "flagged" ]] || return 0
  ! write_escalated "$github" "$number" || return 0
  if axi_write issue edit "$number" --repo "$github" --remove-label "$LABEL_ESCALATED"; then
    log "$github#$number withdrew $LABEL_ESCALATED: $why"
    return 0
  fi
  class=$(gh_error_class "$FAILURE_TEXT")
  [[ "$class" != "refused" ]] \
    || die "refused-write flag withdrawal refused on $github#$number class=refused project=$github"
  write_failed "$class" - "" "" withdraw "refused-write flag withdrawal failed on $github#$number"
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
  REVIEW_RETRY_TIMEOUT=$(jq -r '.reviewRetryTimeoutSeconds // empty' "$CONFIG_PATH")
  WORKER_TIMEOUT=$(jq -r 'if has("workerTimeoutSeconds") then .workerTimeoutSeconds else 86400 end' "$CONFIG_PATH")
  LABEL_READY=$(jq -r '.labels.ready // empty' "$CONFIG_PATH")
  LABEL_CLAIMED=$(jq -r '.labels.claimed // empty' "$CONFIG_PATH")
  PROJECT_COUNT=$(jq -r '.projects | length' "$CONFIG_PATH" 2>/dev/null || echo 0)
  DEATH_REPO=$(jq -r '.deathRepo // empty' "$CONFIG_PATH")

  require_positive_int pollIntervalSeconds "$POLL_INTERVAL"
  require_positive_int maxWorkers "$MAX_WORKERS"
  # Required, not defaulted. Every key in this config but the worker bound is
  # required and a missing one is fatal, and the number itself is an admitted
  # guess off a single seventeen-minute sample, so defaulting it would hide the
  # guess behind a default.
  require_positive_int autofixTimeoutSeconds "$AUTOFIX_TIMEOUT"
  # Required for the same reason, and on thinner evidence still: this key bounds
  # the risk gate's `defer`, and there is **no sample at all** behind that use of
  # it. A default here would be a guess wearing a number's clothes.
  #
  # It is **a floor, not a tuned number**, and the block above the PR phase says
  # what raising it costs. Nothing here validates that floor — the slowest
  # legitimate check run is a property of the operator's repositories, not of
  # this file — so all this can check is that a number was supplied.
  require_positive_int mergeGateTimeoutSeconds "$MERGE_GATE_TIMEOUT"
  # The bound on asking again after CodeRabbit refuses the command. Required
  # like every other key here, and its own key because neither existing one
  # fits: the poll interval measures how fast a *reply* arrives and is already
  # the in-flight bound one layer up, and the merge-gate clock lands exactly on
  # CodeRabbit's rolling sixty-minute window — so a window bound by it would
  # expire at the moment the limit is most likely to lift. The example config
  # ships 5400, which clears that window with thirty minutes of margin and is
  # about seventeen retries at a five-minute poll.
  require_positive_int reviewRetryTimeoutSeconds "$REVIEW_RETRY_TIMEOUT"
  # How long a worker may stay live on a claim with no pull request before the
  # loop asks a human to look at it, from its worktree's `createdAt` (#122).
  # **The file's one default**, and not a guess hidden behind one: #122 derived
  # 86400 from the dispatch-to-pull-request population — about 2.6 times the
  # longest observed, nine hours ten — and decided it with the default. A key
  # that is present is validated like every other timeout, so `0`, `null` or a
  # string still stops start-up.
  require_positive_int workerTimeoutSeconds "$WORKER_TIMEOUT"
  require_field labels.ready "$LABEL_READY"
  require_field labels.claimed "$LABEL_CLAIMED"
  [[ "$PROJECT_COUNT" -gt 0 ]] || die "config lists no projects: $CONFIG_PATH"
  # Where a death is recorded (#129). Required, because an optional key leaves
  # the default deployment with no record at all; and its own key rather than a
  # project's, because project order is a declared priority and reordering it
  # must never move the death channel.
  require_field deathRepo "$DEATH_REPO"

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

  trap on_exit EXIT
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

# The EXIT trap. A loop that dies after it began passing files one issue in
# deathRepo on the way out (#129): restart is manual and nothing supervises the
# process, so without it a dead loop reads exactly like one never started.
#
# The gate is the status rather than `die`, so a `set -e` exit that never logged
# `fatal:` is recorded too; and it is the began-passing flag rather than the
# call site, so the start-up failures a human is reading off stdout write
# nothing, and an in-loop exit added later is covered without being listed.
# Ctrl-C, SIGTERM and SIGHUP exit 0 through `shutdown` and write nothing.
#
# The order is the decision's. The status is captured before any command can
# clobber it. The lock goes before the write, so a hung `gh-axi` holds nothing
# and a restart never meets `already running`. Then one best-effort write, and
# an explicit exit with the captured status.
on_exit() {
  local status=$?
  # A failing command in here must not end the trap before the exit below. And
  # a signal during a hung write takes its default action rather than
  # `shutdown`'s, which would exit 0 and pass the death off as a clean stop.
  set +e
  trap - INT TERM HUP
  release_lock
  if $BEGAN_PASSING && (( status != 0 )); then
    write_death_record "$status"
  fi
  exit "$status"
}

# One attempt, no retry, and never `die`: a death path that can re-enter `die`
# can loop. What gh-axi said rides on the failure line from both channels, the
# way a failed label swap's does. A GitHub that is unreachable at death leaves
# that line as the only record, which #129 accepts.
write_death_record() {
  local status="$1" title file error
  if [[ -n "$FATAL_MESSAGE" ]]; then
    # GitHub refuses a title past 256 characters, and a refused title would
    # lose the whole record. The body carries the message whole.
    title="agent-loop died: ${FATAL_MESSAGE:0:200}"
  else
    title="agent-loop died: exit $status, no fatal message"
  fi
  if ! file=$(mktemp "${TMPDIR:-/tmp}/agent-loop-death.XXXXXX"); then
    log "death record failed: could not create a body file"
    return 0
  fi
  if ! death_body "$status" > "$file"; then
    log "death record failed: could not write body file"
    rm -f "$file"
    return 0
  fi
  if ! error=$(gh-axi issue create --repo "$DEATH_REPO" --title "$title" --body-file "$file" 2>&1); then
    error="${error//$'\n'/ }"
    log "death record failed: gh-axi: ${error:-said nothing}"
  fi
  rm -f "$file"
}

# The death record's body, from memory and the local log only. No GitHub, Orca
# or git read happens here: the loop may be dying because those reads fail, and
# a record that queried would hang or come back empty at the one moment it is
# needed. That is also why `drift=` is the last pass's rather than a fresh one.
# The log tail duplicates the log on purpose — the log is on a machine nobody is
# reading.
death_body() {
  local status="$1" now elapsed uptime=unknown
  if [[ -n "$STARTED_AT" ]] && now=$(date -u +%s) && [[ "$now" =~ ^[0-9]+$ ]]; then
    elapsed=$(( now - STARTED_AT ))
    uptime=$(printf '%dh%02dm%02ds' $(( elapsed / 3600 )) $(( elapsed % 3600 / 60 )) $(( elapsed % 60 )))
  fi
  printf 'The loop died after it began passing, and nothing restarts it. Fix the cause, then restart it by hand.\n\n' || return 1
  if [[ -n "$FATAL_MESSAGE" ]]; then
    printf 'fatal: %s\n\n' "$FATAL_MESSAGE" || return 1
  else
    printf 'no fatal message: the loop exited without passing through `die`, most likely under `set -e`.\n\n' || return 1
  fi
  printf 'exit=%s\nbuild=%s drift=%s\nuptime=%s\npasses=%s\n\n' \
    "$status" "${BUILD:-unknown}" "$LAST_DRIFT" "$uptime" "$PASSES" || return 1
  # Four backticks, so a log line carrying a three-backtick fence of its own
  # cannot close this one.
  printf 'The last 20 log lines:\n\n````\n' || return 1
  tail -n 20 "$LOG_PATH" 2>/dev/null || return 1
  printf '````\n'
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
# loop's own labels are made to exist once, at startup, in every repo it polls.
# Anything already there is left exactly as it is, colour included.
#
# The three flag constants are here for the same reason the two in the config
# are, and the cost of leaving any of them out is worse: an `--add-label` naming
# a label that does not exist is refused, so a handover would post its comment
# and then fail to flag it, forever, on a chase that can never land — and a
# refusal, which writes its label first, would never get past the swap and would
# leave the issue ready and silent on every pass.
#
# **The two verbs are here for a different argument, and it is the stronger
# one.** The loop never writes a verb label — it only ever reads one — so the
# refused-`--add-label` reasoning does not reach them. What does is that the
# verb gate fails closed: *the marker has to be appliable everywhere before the
# rule that demands it arrives.* Without this, shipping the gate refuses every
# issue in a repository that has no `to-tickets` label, with no fix that does
# not start with creating one.
#
# Cosmetic divergence, recorded so it is not rediscovered as a bug: the verb
# labels created by hand ahead of this are `aaaaaa` where this creates at
# `ededed`, and the skip is by name, so they will never be recoloured. Fixable
# only at the constant below, and not worth fixing.
ensure_labels() {
  local repo="$1" existing label response
  response=$(gh_json "/repos/$repo/labels" --paginate) \
    || { log "could not list labels in $repo, assuming they exist"; return 0; }
  existing=$(jq -r '.[].name' <<< "$response")
  for label in "$LABEL_READY" "$LABEL_CLAIMED" "$LABEL_ESCALATED" "$LABEL_REFUSED" \
               "$VERB_IMPLEMENT" "$VERB_TO_TICKETS" "$LABEL_DECOMPOSED"; do
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

  local i github orca_id method repo_json permission permitted has_issues pull
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

  # Resolved here, beside the projects, because a death record whose home was
  # mistyped fails at the one moment it was needed (#129). Startup proves only
  # that issues are enabled and this identity can read the repository; issue
  # creation permission is not knowable here, so creation remains best effort.
  # `// false`, so a read carrying neither field fails closed.
  repo_json=$(gh_json "/repos/$DEATH_REPO" 2>/dev/null) \
    || die "deathRepo does not resolve: $DEATH_REPO"
  has_issues=$(jq -r '.has_issues // false' <<< "$repo_json")
  pull=$(jq -r '.permissions.pull // false' <<< "$repo_json")
  [[ "$has_issues" == "true" && "$pull" == "true" ]] \
    || die "deathRepo must have issues enabled and be readable by this identity: $DEATH_REPO (has_issues is $has_issues, permissions.pull is $pull)"
  log "validated deathRepo $DEATH_REPO"
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
  local response
  # Captured, then `jq`, the rule every wrapper in the file follows.
  response=$(gh_json /user) \
    || die "could not resolve the GitHub identity behind this token"
  ME=$(jq -r '.login // empty' <<< "$response") \
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

# Ready means what this loop actually depends on, which is more than `orca
# status` says: the runtime is reachable **and** `orca worktree ps` reads. This
# is the file's only inventory read, so a ready runtime always leaves a snapshot
# behind it. A failure leaves `RUNTIME_UNREADY_REASON` naming the half that
# failed: `unreachable` or `inventory`.
RUNTIME_UNREADY_REASON=''
runtime_ready() {
  if ! runtime_reachable; then
    RUNTIME_UNREADY_REASON=unreachable
    return 1
  fi
  if ! load_worktree_inventory; then
    RUNTIME_UNREADY_REASON=inventory
    return 1
  fi
}

# Ensure the Orca runtime is ready, starting it if it is not reachable.
# Re-checked before every pass: an Orca restart mid-run must not turn every later
# pass into a stream of failed dispatches.
#
# **`worker inventory unreadable` is not a member of the failure family**
# (#124), and the reason is a fact rather than a preference: it is the one wait
# in the family where a bound with an origin already exists. A family member's
# transient skip is unbounded because a failed read carries no origin, and
# manufacturing one would cost a write. This wait needs neither — the readiness
# loop below is its origin — and it is the widest-blast wait in the file: one
# unreadable `orca worktree ps` used to fail the budget closed and skip the
# sweep, so a pass dispatched nothing and swept nothing, logged exactly like the
# narrowest skip and repeated with no bound. `runtime_reachable` asked `orca
# status` while the loop depends on `worktree ps`, and the gap between those two
# reads was the whole of the case, so it is closed in the predicate rather than
# papered over with a clock of its own.
#
# - **During:** re-read on the readiness clock, with **no `orca open`**. Status
#   already says the runtime is up, so starting it answers nothing, and an
#   action taken to break the loop's own wait is argued rather than inherited
#   (#121).
# - **Bound:** `RUNTIME_WAIT_SECONDS`, with the wait loop as its origin. Nothing
#   is remembered between passes, and nothing needs to be.
# - **Expiry:** `die`, which files a death record once the loop is passing
#   (#129). The line names the inventory, so its reader goes looking for why
#   Orca answers `status` but not `worktree ps`; the not-reachable line is kept
#   verbatim.
#
# Rejected on #124: `die` on the first failed read, which kills the daemon over
# one hiccup that costs nothing to re-read; and a family row with
# `class=transient`, which leaves the pass silently doing nothing.
ensure_runtime() {
  runtime_ready && return 0
  if [[ "$RUNTIME_UNREADY_REASON" == unreachable ]]; then
    log "orca runtime not reachable, starting it"
    orca open --json >/dev/null 2>&1 || log "orca open failed, waiting in case it comes up anyway"
  else
    log "worker inventory unreadable, waiting on runtime readiness"
  fi
  local waited=0
  while (( waited < RUNTIME_WAIT_SECONDS )); do
    if runtime_ready; then
      log "orca runtime ready"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  local why=''
  if [[ "$RUNTIME_UNREADY_REASON" == inventory ]]; then
    why=': worker inventory unreadable'
  fi
  die "orca runtime did not become ready within ${RUNTIME_WAIT_SECONDS}s$why"
}

# --- worktree inventory ------------------------------------------------------

# One `orca worktree ps` read, cached in ORCA_PS, and taken by readiness and
# nothing else (#124): the worker budget, the sweep, close-out, the reclaim and
# the branch check all ask their question of the snapshot readiness
# took, so none of them has an unreadable branch of its own. A failed read leaves
# the last good snapshot alone and returns non-zero, because "I could not look"
# and "nothing is running" must never read the same — and readiness dies rather
# than hand that stale snapshot to anyone.
ORCA_PS=''
load_worktree_inventory() {
  local response
  response=$(orca worktree ps --json 2>/dev/null) || return 1
  jq -e '.result.worktrees | arrays' <<< "$response" >/dev/null 2>&1 || return 1
  ORCA_PS="$response"
}

# Every worktree Orca knows, one `<live|idle>\t<createdAt>\t<worktreeId>\t<path>`
# line each. An agent that is `working` or `waiting` is live; `waiting` counts
# because a worker parked for my confirmation still holds its branch and owes me
# an answer — it is not finished. `orca terminal list` is not used for this: it
# cannot tell a busy terminal from an idle shell.
#
# **`createdAt` is the one durable origin the sweep and the reclaim can put a
# clock on** (#130, declared by #136). It is the worktree's, in epoch-ms, and
# the loop remembers nothing between passes, so an origin has to be a fact some
# read already carries — this read carries it. The agent's `stateStartedAt` sits
# right beside it and is never used: it resets on every transition, so a clock
# against it restarts each time a worker goes `working` → `waiting` → `working`.
#
# `createdAt` is absent exactly on the main worktree (`isMainWorktree`, captured
# against Orca 1.4.200 in docs/orca-worktree-ps-capture.md), which
# `is_loop_worktree` already excludes. Anywhere else, absent or unparseable, it
# projects as `-` rather than as an empty field — `read` collapses adjacent tabs,
# so an empty column would shift the path into it — and never as a number: a
# guessed origin is a bound that silently vanishes. What `-` means is each
# consumer's to decide, in its own fail-closed direction, and on its own line.
# The upper limit rejects anything past year 2286, which is garbage rather than
# an instant, and keeps the value inside shell arithmetic.
#
# `worktreeId` is `<orcaRepoId>::<path>`, and config maps `orcaRepoId` to
# `github`, so `${worktree_id%%::*}` names a worktree's repository with no new
# read. The path stays last so that `read` hands it any whitespace it carries.
orca_worktrees() {
  jq -r '.result.worktrees[]?
    | select(.path != null)
    | [ (if any(.agents[]?.state; . == "working" or . == "waiting")
         then "live" else "idle" end),
        (if (.createdAt | type) == "number" and .createdAt > 0 and .createdAt < 1e13
         then (.createdAt | floor | tostring) else "-" end),
        (if (.worktreeId | type) == "string" and .worktreeId != ""
         then .worktreeId else "-" end),
        .path ]
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
  while IFS=$'\t' read -r state _ _ path; do
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

# Count live workers in one repository whose directory name matches the given
# regex. Prints the count. count_live_workers <github> <basename-regex> — live
# agents sitting in a matching worktree belonging to that repository.
count_live_workers() {
  local github="$1" pattern="$2" state worktree_id path count=0
  while IFS=$'\t' read -r state _ worktree_id path; do
    [[ "$state" == "live" ]] || continue
    [[ "$(project_for_orca_id "${worktree_id%%::*}")" == "$github" ]] || continue
    if [[ "${path##*/}" =~ $pattern ]]; then
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
# `done` agents are finished work waiting to be swept, not spent budget. So is a
# live worker whose issue is delivered or no longer claimed: see
# `worker_disposition`.
count_active_workers() {
  local state created worktree_id path count=0
  while IFS=$'\t' read -r state created worktree_id path; do
    [[ "$state" == "live" ]] || continue
    is_loop_worktree "$path" || continue
    [[ "$(worker_disposition "$created" "$worktree_id" "$path")" == released$'\t'* ]] && continue
    count=$((count + 1))
  done < <(orca_worktrees)
  printf '%s' "$count"
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
# **The reclaim pays for this read again, on purpose** (#136). It runs in
# close-out, ahead of the budget and the issue phase, which share one read of
# their own later in the same pass. Sharing the reclaim's read with them would
# be wrong, not merely awkward: a cached map is older than a fresh one, and
# older fails open here — a pull request opened in between reads as *nothing
# delivers this issue*, which is the duplicate this read pages to the end to
# prevent. The callers also skip differently, the reclaim its reclaim and the
# issue phase its whole phase, and one shared failed read would take out both.
#
# Prints one `<pull request>\t<branch>` line per open pull request — the pair in
# GitHub's own order, which `load_open_pr_issues` then turns around into the
# issue-keyed map the callers ask their question of.
query_repo_open_pr_branches() {
  local owner="${1%%/*}" name="${1##*/}" response cursor='null' page=0 rows='' page_rows
  # Twenty pages is two thousand open pull requests. The bound is here so a
  # cursor GitHub never stops handing back cannot spin the loop forever.
  #
  # The rows are held until the read is complete rather than printed per page,
  # so a failure on a later page puts its failure text on stdout alone and the
  # caller never classifies a page of pull requests as if it were an error.
  while (( page < 20 )); do
    if ! response=$(gh_graphql "{ repository(owner: \"$owner\", name: \"$name\") { pullRequests(states: OPEN, first: 100, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { number headRefName } } } }"); then
      printf '%s' "$response"
      return 1
    fi
    # A GraphQL error can come back as a 200 with a null repository, which would
    # otherwise read as "this repository has no open pull requests" — and read
    # that way by this caller, it would wave every claimed issue through.
    jq -e '.data.repository.pullRequests.nodes | type == "array"' <<< "$response" \
      >/dev/null 2>&1 || return 1
    page_rows=$(jq -r '.data.repository.pullRequests.nodes[]?
      | select(.number != null and .headRefName != null)
      | [ (.number | tostring), .headRefName ] | @tsv' <<< "$response") || return 1
    rows+="$page_rows"$'\n'
    # Only GitHub's explicit terminal answer is a complete read. Missing or
    # malformed pagination data must not be mistaken for an empty next page.
    if jq -e '.data.repository.pullRequests.pageInfo.hasNextPage == false' <<< "$response" \
      >/dev/null 2>&1; then
      printf '%s' "$rows"
      return 0
    fi
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

# Both fail when the read failed. Neither fails for an empty answer: a
# repository with no open pull requests is a fact, and an unanswerable question
# is not.
#
# Every caller calls them bare, because they fill a global, so a failure's text
# is left in `$FAILURE_TEXT` rather than on stdout.
#
# read_open_pr_issues <github> — a fresh read, kept for nobody. The reclaim's,
# because a read it shared would be older than the one it guards: see
# `query_repo_open_pr_branches`.
read_open_pr_issues() {
  local branches prnumber branch number loaded=''
  OPEN_PR_ISSUES=''
  FAILURE_TEXT=''
  if ! branches=$(query_repo_open_pr_branches "$1"); then
    FAILURE_TEXT="$branches"
    return 1
  fi
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

# load_open_pr_issues <github> — the pass's read, kept for the pass.
load_open_pr_issues() {
  local github number prnumber loaded='' kept=''
  # **Once per repository per pass.** The worker budget asks this read before
  # the issue phase does (#122), and both are answered by the one read; a failed
  # read is not kept, so the next caller asks again.
  if [[ "$PASS_OPEN_PRS_READ" == *" $1 "* ]]; then
    OPEN_PR_ISSUES=''
    FAILURE_TEXT=''
    while IFS=$'\t' read -r github number prnumber; do
      [[ "$github" == "$1" ]] || continue
      loaded+="$number"$'\t'"$prnumber"$'\n'
    done <<< "$PASS_OPEN_PRS"
    OPEN_PR_ISSUES="$loaded"
    return 0
  fi
  read_open_pr_issues "$1" || return 1
  while IFS=$'\t' read -r number prnumber; do
    [[ -n "$number" ]] || continue
    kept+="$1"$'\t'"$number"$'\t'"$prnumber"$'\n'
  done <<< "$OPEN_PR_ISSUES"
  PASS_OPEN_PRS+="$kept"
  PASS_OPEN_PRS_READ+=" $1 "
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

# --- a worker that is still going --------------------------------------------

# Decided in #122. A live loop worker used to be spent budget until its agent
# went idle, and nothing else ever looked at it: `#103`'s worker delivered, its
# pull request merged, and its slot stayed counted against `maxWorkers` for
# 7h20m. A hung worker would have held its slot *and* its claim, silently.
#
# **Row A — delivered and still live.** A live worker whose issue an open pull
# request delivers, or whose claim is gone, is finished agent-phase work: it is
# released from `count_active_workers`. That writes nothing to GitHub and
# touches nothing on disk, so a session a human adopted is never disturbed, and
# nothing is killed. The skip itself stays unbounded on purpose: with the slot
# released it costs nothing. The accepted imprecision is `closeout_claims`'
# own: a worker that opens a draft pull request early stops being counted while
# it still works.
#
# **Row B — live, claim held, no pull request.** Bounded by
# `workerTimeoutSeconds` from the worktree's `createdAt`. Past it the sweep
# flags the claimed issue `agent-escalated` with one comment naming the
# worktree, and the slot stays spent: releasing it would stack fresh agents on
# one that may still be working. A missing `createdAt` falls through to the
# unbounded skip, and the line says so, because a bound that silently vanishes
# is worse than none.
#
# `issue_has_live_worker` asks *is anyone in this repository on this issue*, and
# this asks *how much is the loop spending*.
#
# The claims come off close-out's claimed-issue query. Delivery comes off the
# issue phase's open-pull-request read, which the budget now asks first. That
# costs a read the pass did not make before on one kind of pass: an empty
# backlog in a repository with a claimed live worker, because Row B cannot say
# *no pull request* without it. Neither read is ever a guess: a repository
# whose read failed keeps its workers counted and flags nothing, for the whole
# pass, even if the issue phase's own retry lands — so the budget and the sweep
# line never tell different stories.
PASS_CLAIMS=''
PASS_CLAIMS_READ=''
PASS_OPEN_PRS=''
PASS_OPEN_PRS_READ=''
PASS_OPEN_PRS_FAILED=''
# The pass's clock, read once at the top of the pass: the reclaim's grace, its
# dirty-tree bound and the worker bound are all measured against it.
PASS_NOW=0
# Every claimed spec past the handover's bound this pass, as ` <github>#<number> `
# words (#140). Its flag is the handover's, so neither the budget nor the sweep
# asks anything of it.
PASS_HANDED_OVER=''

# spec_handed_over <github> <number> — whether close-out found the spec past
# the handover's bound this pass.
spec_handed_over() {
  [[ "$PASS_HANDED_OVER" == *" $1#$2 "* ]]
}

# forget_claim <github> <number> — a claim close-out dropped this pass, after
# the read that recorded it.
forget_claim() {
  local github number escalation kept=''
  while IFS=$'\t' read -r github number escalation; do
    [[ -n "$github" ]] || continue
    [[ "$github" == "$1" && "$number" == "$2" ]] && continue
    kept+="$github"$'\t'"$number"$'\t'"$escalation"$'\n'
  done <<< "$PASS_CLAIMS"
  PASS_CLAIMS="$kept"
}

# claim_flag <github> <number> — prints `flagged` or `unflagged` for an issue
# this pass read as claimed, and fails for one it did not.
claim_flag() {
  local github number escalation
  while IFS=$'\t' read -r github number escalation; do
    [[ "$github" == "$1" && "$number" == "$2" ]] || continue
    printf '%s' "$escalation"
    return 0
  done <<< "$PASS_CLAIMS"
  return 1
}

# delivering_pr <github> <number> — prints the open pull request this pass read
# as delivering the issue, and fails when none does.
delivering_pr() {
  local github number prnumber
  while IFS=$'\t' read -r github number prnumber; do
    [[ "$github" == "$1" && "$number" == "$2" ]] || continue
    printf '%s' "$prnumber"
    return 0
  done <<< "$PASS_OPEN_PRS"
  return 1
}

# project_for_orca_id <orcaRepoId> — the first configured repository that maps
# to it, which is how a worktree's `worktreeId` names its repository.
project_for_orca_id() {
  local i
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    if [[ "$(jq -r ".projects[$i].orcaRepoId" "$CONFIG_PATH")" == "$1" ]]; then
      jq -r ".projects[$i].github" "$CONFIG_PATH"
      return 0
    fi
  done
  return 1
}

# The delivery reads the budget needs before the issue phase runs. Asked after
# close-out, whose claim read it depends on. A delivery read is made only for a
# repository holding a claimed loop worker that is live, or whose issue wears
# the flag, since those are the only workers it decides.
load_worker_facts() {
  local state path worktree_id github number flag tried=''
  while IFS=$'\t' read -r state _ worktree_id path; do
    is_loop_worktree "$path" || continue
    number=$(issue_for_branch "${path##*/}") || continue
    github=$(project_for_orca_id "${worktree_id%%::*}") || continue
    flag=$(claim_flag "$github" "$number") || continue
    # A flag the spec handover holds up decides nothing here, and reading for
    # it would be a read on every pass the spec waits for a human.
    if [[ "$state" != "live" ]] && { [[ "$flag" != "flagged" ]] || spec_handed_over "$github" "$number"; }; then
      continue
    fi
    [[ "$PASS_OPEN_PRS_READ$tried" != *" $github "* ]] || continue
    tried+=" $github "
    # stdin is closed for the read: gh-axi must not swallow the inventory.
    if ! load_open_pr_issues "$github" < /dev/null; then
      PASS_OPEN_PRS_FAILED+=" $github "
      read_failed "$(gh_error_class "$FAILURE_TEXT")" "$github" "open-pr query failed: $github, counting its live workers"
    fi
  done < <(orca_worktrees)
}

# worker_disposition <createdAt> <worktreeId> <path> — for a live loop worker,
# `<released|counted|expired>\t<github>\t<number>\t<flag>\t<reason>`, with `-`
# for a field that does not apply. Pure: it reads only what `load_worker_facts`
# and close-out left for the pass, so the budget and the sweep cannot disagree.
worker_disposition() {
  local created="$1" worktree_id="$2" path="$3" github number flag prnumber age
  if ! number=$(issue_for_branch "${path##*/}"); then
    printf 'counted\t-\t-\t-\tits worktree names no issue'
    return 0
  fi
  if ! github=$(project_for_orca_id "${worktree_id%%::*}"); then
    printf 'counted\t-\t%s\t-\tits worktree names no configured repository' "$number"
    return 0
  fi
  if [[ "$PASS_CLAIMS_READ" != *" $github "* ]]; then
    printf 'counted\t%s\t%s\t-\tthe claims on %s could not be read' "$github" "$number" "$github"
    return 0
  fi
  if ! flag=$(claim_flag "$github" "$number"); then
    printf 'released\t%s\t%s\t-\t%s#%s is no longer claimed' "$github" "$number" "$github" "$number"
    return 0
  fi
  if [[ "$PASS_OPEN_PRS_READ" != *" $github "* || "$PASS_OPEN_PRS_FAILED" == *" $github "* ]]; then
    printf 'counted\t%s\t%s\t%s\tthe open pull requests on %s could not be read' "$github" "$number" "$flag" "$github"
    return 0
  fi
  if prnumber=$(delivering_pr "$github" "$number"); then
    printf 'released\t%s\t%s\t%s\tpull request #%s delivers %s#%s' "$github" "$number" "$flag" "$prnumber" "$github" "$number"
    return 0
  fi
  if [[ "$created" == "-" ]]; then
    printf 'counted\t%s\t%s\t%s\t%s#%s is claimed with no pull request, and its worktree has no createdAt, so nothing bounds it' \
      "$github" "$number" "$flag" "$github" "$number"
    return 0
  fi
  # `createdAt` is epoch-ms; the bound is in seconds.
  age=$(( PASS_NOW - created / 1000 ))
  if (( age > WORKER_TIMEOUT )); then
    printf 'expired\t%s\t%s\t%s\t%s#%s is claimed with no pull request, live %ss of %ss, past its bound' \
      "$github" "$number" "$flag" "$github" "$number" "$age" "$WORKER_TIMEOUT"
  else
    printf 'counted\t%s\t%s\t%s\t%s#%s is claimed with no pull request, live %ss of %ss' \
      "$github" "$number" "$flag" "$github" "$number" "$age" "$WORKER_TIMEOUT"
  fi
}

# set_claim_flag <github> <number> <flagged|unflagged> — what this pass wrote,
# so a `-2` sibling worktree of the same issue neither posts a second record
# nor withdraws twice.
set_claim_flag() {
  forget_claim "$1" "$2"
  PASS_CLAIMS+="$1"$'\t'"$2"$'\t'"$3"$'\n'
}

HUNG_WORKER_MARKER_PREFIX='<!-- agent-loop-hung-worker: '
HUNG_WORKER_MARKER_SUFFIX=' -->'

hung_worker_body() {
  local path="$1" reason="$2"
  printf '**Escalated — this issue'"'"'s worker has been live past `workerTimeoutSeconds` with no pull request.**\n\n'
  printf 'Its worktree is `%s`. Look at the agent there, and answer it or kill it.\n\n' "$path"
  printf 'The loop cannot tell a hung agent from a slow one, so it never kills a worker, and it keeps this one'"'"'s slot spent. It takes `%s` off by itself on the pass the work delivers, the claim goes, or the worker goes. A worktree removed by hand leaves the flag standing. This comment is a record and stays.\n\n' "$LABEL_ESCALATED"
  printf 'What the sweep derived: %s\n\n' "$reason"
  printf '%s%s%s\n' "$HUNG_WORKER_MARKER_PREFIX" "$path" "$HUNG_WORKER_MARKER_SUFFIX"
}

# escalate_hung_worker <github> <number> <path> <reason>
#
# Record, then flag, for the handover's reason: a flag with no record behind it
# is the one state its reader cannot act on. The record has its own marker keyed
# to the worktree, because `agent-escalated` is shared by every kind of human
# intervention and cannot say whether this worker has its record. A failed flag
# write therefore retries the flag without posting the comment again.
#
# These are escalation writes, and fail like `escalate_refused_write`'s: a
# refused one dies, and a transient one is logged, counted and tried again.
escalate_hung_worker() {
  local github="$1" number="$2" path="$3" reason="$4"
  local marker comments seen flag file="" status=0 class
  marker="$HUNG_WORKER_MARKER_PREFIX$path$HUNG_WORKER_MARKER_SUFFIX"

  if ! comments=$(gh_json "/repos/$github/issues/$number/comments" --paginate); then
    read_failed "$(gh_error_class "$comments")" "$github" \
      "hung-worker record unreadable on $github#$number, flagging nothing this pass"
    return 0
  fi
  if ! seen=$(jq -r --arg me "$ME" --arg marker "$marker" \
       'any(.[]?; (.user.login // "") == $me and ((.body // "") | contains($marker)))' \
       <<< "$comments" 2>/dev/null) || [[ "$seen" != "true" && "$seen" != "false" ]]; then
    read_failed "$(gh_error_class "")" "$github" \
      "hung-worker record unreadable on $github#$number, flagging nothing this pass"
    return 0
  fi

  if [[ "$seen" == "false" ]]; then
    if ! file=$(mktemp "${TMPDIR:-/tmp}/agent-loop-hung-worker.XXXXXX"); then
      FAILURE_TEXT=""
      status=1
    elif ! hung_worker_body "$path" "$reason" > "$file"; then
      FAILURE_TEXT=""
      status=1
    else
      axi_write issue comment "$number" --repo "$github" --body-file "$file" || status=1
    fi
    [[ -z "$file" ]] || rm -f "$file"
    if (( status != 0 )); then
      class=$(gh_error_class "$FAILURE_TEXT")
      [[ "$class" != "refused" ]] \
        || die "hung-worker record refused on $github#$number class=refused project=$github"
      write_failed "$class" - "" "" record "hung-worker record failed on $github#$number, flagging nothing this pass"
      return 0
    fi
  fi

  flag=$(claim_flag "$github" "$number") || flag=unflagged
  [[ "$flag" == "unflagged" ]] || return 0

  # Taken as flagged once this worktree's record is up, whether or not the flag
  # lands, so siblings do not make redundant flag writes in the same pass.
  set_claim_flag "$github" "$number" flagged
  if ! axi_write issue edit "$number" --repo "$github" --add-label "$LABEL_ESCALATED"; then
    class=$(gh_error_class "$FAILURE_TEXT")
    [[ "$class" != "refused" ]] \
      || die "hung-worker flag refused on $github#$number class=refused project=$github"
    write_failed "$class" - "" "" flag "hung-worker flag failed on $github#$number, the record is up and the next pass adds it"
    return 0
  fi
  log "$github#$number flagged $LABEL_ESCALATED: its worker is past workerTimeoutSeconds ($path)"
}

# withdraw_hung_worker_flag <github> <number> <why>
#
# **Kind-blind, as `withdraw_write_flag` is**, and for the same reason it is
# safe: the other kind a claimed issue can wear is a refused write, whose own
# write raises the flag again on the pass it is refused. Not on a pass where a
# refused write escalated this same issue.
withdraw_hung_worker_flag() {
  local github="$1" number="$2" why="$3" class
  ! write_escalated "$github" "$number" || return 0
  if axi_write issue edit "$number" --repo "$github" --remove-label "$LABEL_ESCALATED"; then
    set_claim_flag "$github" "$number" unflagged
    log "$github#$number withdrew $LABEL_ESCALATED: $why"
    return 0
  fi
  class=$(gh_error_class "$FAILURE_TEXT")
  [[ "$class" != "refused" ]] \
    || die "hung-worker flag withdrawal refused on $github#$number class=refused project=$github"
  write_failed "$class" - "" "" withdraw "hung-worker flag withdrawal failed on $github#$number"
}

# --- the reclaim -------------------------------------------------------------

# The worktree a dispatch asked for is `agent-loop-<type>-<number>-<title-slug>`,
# and a name collision appends `-2` — so the number is anchored on both sides, or
# issue 1 would find issue 11's worker and stay claimed forever. The types are
# spelled out rather than matched as `[a-z]+`, which would let an
# `agent-loop-pr-17` answer for issue 17. The PR phase that cut those is gone,
# but the ones it left on disk are not, and `pr` must stay off this list for as
# long as any of them survive. `issue` is the name dispatches used before the
# type was part of it, and still names live workers.
ISSUE_BRANCH_TYPES='feat|fix|chore|docs|refactor|test|perf|build|ci|issue'

# Check whether an issue in a repository has a live worker already running.
# Returns 0 if a worker exists, non-zero otherwise.
issue_has_live_worker() {
  [[ "$(count_live_workers "$1" '^agent-loop-('"$ISSUE_BRANCH_TYPES"')-'"$2"'(-.*)?$')" != "0" ]]
}

# How long a dispatch has to read live before the reclaim may take its worktree
# as abandoned (#136). A constant and not a config key: it is a property
# of how long Orca takes to start a worker, which nobody tuning it would know
# better than the measurement, and not `2 * pollIntervalSeconds`, which would
# weld that fact to how often the loop polls. 900 because the costs are
# lopsided: too short is a duplicate build, too long is a claim sitting fifteen
# minutes, against a measured baseline of eleven days.
DISPATCH_GRACE_SECONDS=900

# The claim label is written before the dispatch, so a crash in between leaves an
# issue claimed with nobody on it, and so does a worker that died, or finished
# without a pull request. The reclaim hands every such issue back, on every pass,
# as close-out's else-branch over the claimed set close-out already reads
# (#136). It used to run once, at startup, and `#133`'s claim sat for eleven
# days because nothing ran it again.
#
# A claim is only stale when **nobody is on it and nothing has come of it**:
# liveness answers the first, an open pull request the second, and either one on
# its own hands back work that is already delivered.
#
# **Liveness alone is not "nobody".** At startup nothing was in flight; at
# cadence a dispatch from the pass before can still read `idle` — `#102` did for
# a full poll interval (#137) — and handing its claim back puts a second worker
# on work the first is building. And an agent between states after a long sleep
# reads not live with a dirty tree, and is live again a pass later (#144). So a
# claim is reclaimable only when every matching worktree is not live, not dirty
# within `workerTimeoutSeconds` of its `createdAt`, and not younger than
# DISPATCH_GRACE_SECONDS; a missing `createdAt` counts as inside both. With no
# matching worktree at all there is nothing that could be starting up, and the
# claim goes on the pass that sees it.
#
# **The expiry is `release_issue` and no record** (#121): the loop needs no human
# to hand a claim back. A dirty tree past its bound is released the same way and
# left on disk. There is no `agent-escalated` exemption, because that flag is
# un-latching: it is already off by the pass the reclaim can fire.
#
# **A claimed `to-tickets` issue is never handed back.** Neither question can be
# asked of a decomposition — it produces issues rather than a pull request, so
# the second is answered `no` by construction — and handing a spec back means
# decomposing it a second time, into a duplicate set of child tickets a human
# may approve without noticing it is the second batch. The exemption is on the
# **verb** and not on the child count: a worker that links its children by prose
# alone leaves the count at zero, and the duplication would arrive by the other
# door. **Close-out is therefore the only path that clears a spec's claim**, and
# what bounds a spec nothing clears is a handover to a human, not a hand-back:
# see `hand_over_spec` (#140).
#
# **Liveness is asked before the verb**, and the order is about what the line
# means rather than what it costs: neither order saves a read. A live
# decomposition logs `a live worker holds it` like anything else, and only a
# spec that is exempt *and* has nobody on it *and* is inside the grace logs the
# exemption, which is the one case with a reader and an end.

# claim_hold <github> <number> — for a claim no matching worktree reads live on,
# what still holds it, as one `<kind>\t<detail>` line — a dirty tree inside the
# bound being a worker too:
#   unreadable  a matching tree git would not give a status for; detail is its path
#   dirty       a matching tree with uncommitted changes, inside the worker bound
#   unborn      a matching worktree with no `createdAt`
#   young       a matching worktree inside the grace; detail is its age in seconds
#   gone        matching worktrees, all past both; detail is the youngest's age
#   none        no matching worktree at all
# Asked only once liveness has answered no, of the pass-start snapshot. The tree
# is read only where it could still hold the claim: one `git status` per
# matching worktree inside its bound.
claim_hold() {
  local github="$1" number="$2" pattern created worktree_id path age dirty unborn=false youngest=''
  pattern='^agent-loop-('"$ISSUE_BRANCH_TYPES"')-'"$number"'(-.*)?$'
  while IFS=$'\t' read -r _ created worktree_id path; do
    [[ "${path##*/}" =~ $pattern ]] || continue
    [[ "$(project_for_orca_id "${worktree_id%%::*}")" == "$github" ]] || continue
    age=''
    # `createdAt` is epoch-ms; the bounds are in seconds.
    [[ "$created" == "-" ]] || age=$(( PASS_NOW - created / 1000 ))
    if [[ -z "$age" ]] || (( age <= WORKER_TIMEOUT )); then
      # git has no classifier and passes no text; the caller fails closed.
      if ! dirty=$(git -C "$path" status --porcelain 2>/dev/null); then
        printf 'unreadable\t%s\n' "$path"
        return 0
      fi
      if [[ -n "$dirty" ]]; then
        printf 'dirty\t%s\n' "$path"
        return 0
      fi
    fi
    if [[ -z "$age" ]]; then
      unborn=true
    elif [[ -z "$youngest" ]] || (( age < youngest )); then
      youngest="$age"
    fi
  done < <(orca_worktrees)
  if $unborn; then
    printf 'unborn\t-\n'
  elif [[ -z "$youngest" ]]; then
    printf 'none\t-\n'
  elif (( youngest < DISPATCH_GRACE_SECONDS )); then
    printf 'young\t%s\n' "$youngest"
  else
    printf 'gone\t%s\n' "$youngest"
  fi
}

# reclaim_claim <github> <number> <flagged|unflagged> — one claim close-out has
# found no live worker on and no `to-tickets` verb, against the reclaim's own
# open-pull-request read in OPEN_PR_ISSUES.
reclaim_claim() {
  local github="$1" number="$2" escalation="$3" prnumber hold kind='' detail='' why
  if prnumber=$(open_pr_for_issue "$number"); then
    log "left claimed $github#$number: pull request #$prnumber already delivers it"
    return 0
  fi
  # A hold that would not answer leaves `kind` empty, which the last arm holds.
  hold=$(claim_hold "$github" "$number") || hold=''
  IFS=$'\t' read -r kind detail <<< "$hold"
  case "$kind" in
    none)   why="no worktree" ;;
    gone)   why="worker gone $(( detail / 60 ))m after dispatch" ;;
    dirty)
      log "left claimed $github#$number: a dirty worktree holds it"
      return 0
      ;;
    unborn)
      log "left claimed $github#$number: a worktree with no createdAt holds it"
      return 0
      ;;
    young)
      log "left claimed $github#$number: a worktree inside the dispatch grace holds it (${detail}s of ${DISPATCH_GRACE_SECONDS}s)"
      return 0
      ;;
    *)
      # `unreadable`, or nothing at all: never a release.
      read_failed "$(gh_error_class "")" - "left claimed $github#$number: could not read the status of ${detail:-its worktrees}"
      return 0
      ;;
  esac
  if release_issue "$github" "$number"; then
    log "reclaimed $github#$number: $why, returned to $LABEL_READY"
    # The claim is gone for the rest of the pass too, so the budget and the
    # sweep do not act on it, and the flag comes off here rather than there.
    forget_claim "$github" "$number"
    withdraw_write_flag "$github" "$number" "$escalation"
  else
    # Refused, *leaving it claimed* is forever — the reclaim is the only
    # thing that hands a claim back — so it flags the issue.
    write_failed "$(gh_error_class "$FAILURE_TEXT")" issue "$github" "$number" reclaim \
      "reclaim failed for $github#$number, leaving it claimed"
  fi
}

# --- github issues -----------------------------------------------------------

# One GraphQL call per repository and label.
#
# `body` is in the selection set because the ready-issue reader needs it and a
# selected field costs no extra request — it rides back in the response that
# already produced the candidate. It is not free of *payload*: up to a hundred
# whole issue bodies now come back on every read, and the claimed-issue reader
# takes only the number and the verb and discards its copy of the body
# entirely. That is the price of one query shape rather than two, and it is
# bounded — `gh_json` passes `--full`, so a bigger response cannot start being
# truncated.
#
# The claimed read used to happen once per startup. It is now once per
# repository per pass and never at startup, because close-out's second entry
# path and the reclaim enumerate the loop's claims — which is the read both are
# costed on.
#
# `labels(first: 100)` is what both readers derive the change type, the verb and
# the refusal flag from. It **truncates**: an issue wearing more than one hundred
# labels can have its verb fall off the end of the page and be refused for
# declaring none. That fails closed — a stalled issue you can see — and no
# repository is near the limit. Named here so it is not rediscovered as a
# mystery.
#
# **Oldest first, server-side** (#123). The order goes in the query rather than
# a local sort because `first: 100` is applied there, before any local sort
# could run: the oldest hundred are kept rather than an arbitrary hundred, and
# the same issues stop winning every pass. Creation time, not when the issue
# became ready — that would cost a timeline read per candidate per pass — so an
# old issue labelled ready today jumps the queue, once. The claimed read
# inherits the order; the reclaim walks all of them regardless. The cap's canary
# is not here: `log` writes to stdout, and this function's stdout is the
# response. It sits in `issue_phase_project`.
query_issues_by_label() {
  local github="$1" label="$2" owner="${1%%/*}" name="${1##*/}" response
  # On a failure `$response` is gh-axi's own text, and it goes out on stdout
  # for the call site to classify rather than being dropped at `|| return 1`.
  if ! response=$(gh_graphql "{ repository(owner: \"$owner\", name: \"$name\") { issues(labels: [\"$label\"], states: OPEN, first: 100, orderBy: {field: CREATED_AT, direction: ASC}) { nodes { number title url body labels(first: 100) { nodes { name } } } } } }"); then
    printf '%s' "$response"
    return 1
  fi
  # A GraphQL error can come back as a 200 with a null repository, which would
  # otherwise read as "this repository has no matching issues". There is no
  # failure text to pass out for it, so it classifies transient.
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
#
# The body would be a second such field, and a worse one: it carries newlines and
# tabs, which are the separators themselves. `@tsv` does not put those on the
# line raw — it escapes them to a literal `\n` and `\t` — so what a raw body
# would break is not the line but the *body*, which would arrive escaped with
# nothing on the read side to put it back. So it travels base64-encoded, which
# leaves it in an alphabet holding neither separator and hands it back byte for
# byte, and sits *before* the title so the title stays the readable remainder.
# It is the same trick the GitHub seam uses to put a whole JSON response over a
# line-based boundary.
#
# A null or absent body is an ordinary answer — GraphQL types `body` as a
# nullable string — and it must not encode to an *empty* field. A tab is IFS
# whitespace, so `read` collapses a run of them: an empty field anywhere but at
# the end of the line simply disappears, and every field after it shifts up. An
# issue with no body would silently hand its title to the reader as its body and
# dispatch a worktree named after nothing. Hence the appended newline, which
# makes the encoded field non-empty for every body there is. It costs nothing
# coming back: the decode is read through a command substitution, which strips
# trailing newlines from a real body just the same.
#
# The refusal flag and the verb ride the same line, and both cost no read at
# all: the selection set already asks for the labels, because the change type is
# read off them. So a fail-closed gate on every dispatch, and the clear that
# lifts it, buy nothing extra.
#
# The flag travels as a **word** — `flagged` or `unflagged` — rather than as the
# label set, for the reason the body travels encoded — a label name may carry a tab or a comma, and either
# would break the line or the field. Two words rather than one and an empty
# string, because an empty field in the middle of a tab-separated line vanishes
# under `read` and shifts every field after it up.
#
# The verb cannot be a word in that sense: *which* verbs were found is what the
# refusal has to report, since *you wrote no verb* and *you wrote both* need
# opposite fixes from the operator. So it travels as the intersection
# `OWN_LABELS_JQ` builds — see the properties recorded there, the never-empty
# one included, which are what let it sit on this line safely.
#
# **The refusal never happens here.** Dropping a verbless issue at query time
# would make it vanish from the phase with no skip line, no comment and no
# label. The row is emitted so the gate can refuse it audibly.
query_ready_issues() {
  local response
  # Captured, then `jq`: piped, the failure text would be consumed by `jq` and
  # `pipefail` would keep only the status.
  if ! response=$(query_issues_by_label "$1" "$LABEL_READY"); then
    printf '%s' "$response"
    return 1
  fi
  jq -r \
    --arg implement "$VERB_IMPLEMENT" \
    --arg to_tickets "$VERB_TO_TICKETS" \
    --arg refused "$LABEL_REFUSED" \
    --arg escalated "$LABEL_ESCALATED" "$OWN_LABELS_JQ"'
    def change_type:
      [.labels.nodes[]?.name | ascii_downcase | sub("^.*::"; "")]
      | map(if . == "bug" then "fix"
            elif . == "feature" or . == "enhancement" then "feat"
            elif . == "documentation" then "docs"
            else . end)
      | map(select(IN("feat","fix","chore","docs","refactor","test","perf","build","ci")))
      | first // "feat";
    def refusal_flag:
      if ([.labels.nodes[]?.name] | index($refused)) then "flagged" else "unflagged" end;
    def escalation_flag:
      if ([.labels.nodes[]?.name] | index($escalated)) then "flagged" else "unflagged" end;
    .data.repository.issues.nodes[]?
    | [.number, .url, change_type, refusal_flag, escalation_flag, own([$implement, $to_tickets]),
       ((.body // "") + "\n" | @base64), (.title // "")]
    | @tsv' <<< "$response"
}

# Query all claimed issues in a repository. Prints `number`, `verb`,
# tab-separated, one per line.
#
# Open ones only, because `query_issues_by_label` asks for `states: OPEN` — so a
# claim label left on a *closed* issue is invisible here and can never be
# re-dispatched. That blindness is load-bearing rather than incidental: close-out
# is the only path that clears such a label, and it reaches a closed issue on
# every pass for as long as the merged pull request is readable, so the reclaim
# never has to see one.
#
# **The verb rides alongside the number for free.** The shared query already
# fetches `labels(first: 20)` and this reader used to discard them whole. Both
# readers of this stream need the verb — the reclaim to exempt a claimed spec,
# close-out to tell a decomposition from an implementation after the claim swap
# has taken the ready label off — and it is the same intersection, in the same
# constant order, that the ready-issue stream carries.
#
# **And the refused-write flag, as a third word**, for the reason the ready
# stream carries it: the reclaim takes it down on the pass its release lands,
# and reading it here is what makes that free. `flagged` or `unflagged`, never
# empty, and last, so the verb before it stays whole.
query_claimed_issues() {
  local response
  # Captured, then `jq`, so a failure's text survives to the caller.
  if ! response=$(query_issues_by_label "$1" "$LABEL_CLAIMED"); then
    printf '%s' "$response"
    return 1
  fi
  jq -r \
    --arg implement "$VERB_IMPLEMENT" \
    --arg to_tickets "$VERB_TO_TICKETS" \
    --arg escalated "$LABEL_ESCALATED" "$OWN_LABELS_JQ"'
    .data.repository.issues.nodes[]?
    | [.number, own([$implement, $to_tickets]),
       (if ([.labels.nodes[]?.name] | index($escalated)) then "flagged" else "unflagged" end)]
    | @tsv' <<< "$response"
}

# GitHub has no "these issues block this one" field on the issue itself, so the
# blockers are a second read. It answers with the blocking issues themselves,
# which is what makes "still open" answerable — a closed blocker does not block.
#
# Prints one edge per line as `full_name`, `number`, `state`, tab-separated —
# every edge the endpoint carries, whatever its state. The closed ones are
# printed too because the payload has more than one reader and they disagree
# about what a closed edge means: the open-blocker gate below discards them,
# while a check comparing a body's written blocking claim against the graph
# takes one as perfectly good evidence that the dependency was recorded.
#
# Every edge carries its own repository in the same response, so the
# `(repository, number)` pair a cross-repository comparison needs costs no extra
# request. An edge that arrives without one is attributed to the issue's own
# repository — the only repository a same-repository edge could mean.
#
# Fails if the question could not be put at all. The caller treats that as a
# skip: dispatching at an issue that may be blocked is worse than looking again
# next pass.
read_blocker_edges() {
  local response
  if ! response=$(gh_json "/repos/$1/issues/$2/dependencies/blocked_by" --paginate); then
    printf '%s' "$response"
    return 1
  fi
  jq -e 'type == "array"' <<< "$response" >/dev/null 2>&1 || return 1
  jq -r --arg repo "$1" \
    '.[] | [(.repository.full_name // (.repository_url | strings | sub("^https://api.github.com/repos/"; "")) // $repo), .number, .state] | @tsv' <<< "$response"
}

# How many of those edges are still open, over the lines `read_blocker_edges`
# printed. Pure: it asks GitHub nothing of its own, so the gate and every other
# reader of that payload cost one request between them rather than one each.
#
# `awk` rather than the `while IFS=$'\t' read` this file uses everywhere else it
# consumes a tab-separated stream: the one caller is inside the loop over the
# ready issues, where a `read` would need its own `< /dev/null` discipline to
# keep off that stream. A here-string cannot touch it at all.
count_open_blockers() {
  awk -F'\t' '$3 == "open" { n++ } END { print n + 0 }' <<< "$1"
}

# --- the blocking claim ------------------------------------------------------

# Every blocking claim a body makes, as `(repository, number)` pairs rendered
# `owner/repo#N`, one per line, in the order the body names them and each named
# once.
#
# **A line anchors a claim when its leading token is `Blocked by` or `Blocked
# on`** — case-insensitively, optionally followed by a colon — after stripping
# heading marks, list markers and emphasis off the front of it. That covers the
# canonical `## Blocked by` heading, the inline `Blocked by: #a, #b` line, the
# `**Blocked by:**` label with the list under it, and the shapes nobody has
# authored yet. The two skills that write prose and no edge are vendored from
# `mattpocock/skills` and hash-locked, so a local edit is clobbered on the next
# update and an upstream change is not ours to land: the predicate covers what
# they emit rather than the other way round.
#
# **Scope depends on which kind of line anchored.** A heading scopes from the
# heading itself — so `## Blocked by #7` is a claim — to the next heading of any
# level or the end of the body. A non-heading anchor scopes to the remainder of
# its own line plus the list items immediately under it. A single blank line
# between them does not close it — that widening is what `**Blocked by:**` with
# its list a line below needs, which is the shape a body writes most often — but
# a second one does, and so does any line that is not a list item. **A fenced
# code block anchors nothing at all**: a ticket that shows the template rather
# than uses it must not be refused for showing it. Claims **union** over the
# whole body, so splitting one across two sections does not let half of it
# through.
#
# **What never anchors**, each ruled out for its own reason. A bare `#N` in
# ordinary prose is a routine cross-reference, and ruling it in would refuse most
# of a backlog — which is why the scope is computed rather than the whole body
# scanned. `## Parent` is a containment relation rather than a precedence one: a
# spec stays open until its tickets land, so ruling it in would refuse every
# child permanently. The reverse `Blocks #N` form is a claim about the *other*
# issue, and refusing the ticket whose body was honest while the one actually at
# risk sails through is the wrong target; landing it correctly needs a body-wide
# cross-index, so **it ships as a stated limit** — a block written only in the
# reverse form is invisible to the loop. And `blocked on` mid-sentence is
# narrative, not structure.
#
# Inside a claim, everything that is not a referent is prose and is discarded.
# That is what makes the two empty-ish forms pass rather than strand a ticket:
# `Blocked by: None — can start immediately` and `Blocked by: the design review`
# both yield no referents. It is also what reads the markdown link in
# `- [#93](https://…/issues/93) — split the read`, where both halves name the
# same referent and the deduplication leaves one.
blocking_claims() {
  awk -v repo="$2" '
    # One spelling of a list item, shared by the marker a claim may be written
    # behind and the marker a list item under a claim is recognised by. Two
    # spellings would mean `1. Blocked by: #7` anchoring nothing while `1. #7`
    # continued a claim, which is a distinction nothing wants.
    BEGIN { BULLET = "^[ \t]*([-+*]|[0-9]+[.)])[ \t]+" }
    # `owner/repo#N` and the full issue URL both normalize to the pair; a bare
    # `#N` binds to the repository the candidate is in.
    function normalize(tok,   num) {
      if (tok ~ /github\.com\//) {
        sub(/^.*github\.com\//, "", tok)
        num = tok
        sub(/^.*\/issues\//, "", num)
        sub(/\/issues\/[0-9]+$/, "", tok)
        return tok "#" num
      }
      if (index(tok, "/")) return tok
      return repo tok
    }
    # Leftmost-longest, so `owner/repo#7` is one referent rather than a bare
    # `#7` with a repository sitting unread in front of it, and the URL form is
    # not mistaken for a path.
    function referents(s) {
      while (match(s, /(https?:\/\/)?(www\.)?github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/issues\/[0-9]+|([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?#[0-9]+/)) {
        print normalize(substr(s, RSTART, RLENGTH))
        s = substr(s, RSTART + RLENGTH)
      }
    }
    # 1 when the line anchors, with CLAIM_TAIL set to what follows the phrase.
    #
    # A list marker needs whitespace after it, which is what tells `* Blocked by`
    # apart from the emphasis in `**Blocked by:**`. The phrase is located once,
    # on the lowercased copy, and measured off it — a second spelling of the
    # same words is how two spellings end up disagreeing about where they end.
    function anchors(line,   s, low, n) {
      s = line
      sub(/^[ \t]+/, "", s)
      if (s ~ /^#+([ \t]|$)/) sub(/^#+[ \t]*/, "", s)
      else if (s ~ BULLET) sub(BULLET, "", s)
      sub(/^[*_]+[ \t]*/, "", s)
      low = tolower(s)
      if (!match(low, /^blocked[ \t]+(by|on)/)) return 0
      n = RLENGTH
      # The phrase has to end at a boundary — whitespace, a colon, an emphasis
      # mark or the end of the line — or `Blocked ontology` reads as a claim.
      if (substr(low, n + 1) !~ /^([ \t:*_]|$)/) return 0
      if (match(substr(low, n + 1), /^[ \t]*:/)) n += RLENGTH
      CLAIM_TAIL = substr(s, n + 1)
      return 1
    }
    {
      # A fenced block is quoted text rather than structure. A ticket that shows
      # the template in a code fence — this repository writes several — must not
      # be refused for showing it.
      fence_line = $0
      sub(/^[ \t]*/, "", fence_line)
      marker = substr(fence_line, 1, 1)
      if (marker == "`" || marker == "~") {
        run = 1
        while (substr(fence_line, run + 1, 1) == marker) run++
        if (run >= 3) {
          if (!fence_marker) {
            fence_marker = marker
            fence_run = run
            next
          }
          if (marker == fence_marker && run >= fence_run && substr(fence_line, run + 1) ~ /^[ \t]*$/) {
            fence_marker = ""
            fence_run = 0
            next
          }
        }
      }
      if (fence_marker) next

      # A heading needs whitespace or an end of line after its marks, so `#93`
      # at the start of a line is a referent rather than a first-level heading.
      # Any heading closes a running list scope and re-decides the section one.
      if ($0 ~ /^[ \t]*#+([ \t]|$)/) {
        list = 0
        section = anchors($0)
        if (section) referents(CLAIM_TAIL)
        next
      }
      if (anchors($0)) { list = 1; blanks = 0; referents(CLAIM_TAIL); next }
      if (list) {
        # One blank line is the separator markdown puts between a label and its
        # list, and between the items of a loose one. A second is a gap, and a
        # gap ends the claim.
        if ($0 ~ /^[ \t]*$/) { if (++blanks > 1) list = 0; next }
        blanks = 0
        if ($0 ~ BULLET) { referents($0); next }
        list = 0
      }
      if (section) referents($0)
    }
  ' <<< "$1" | awk '!seen[$0]++'
}

# The referents a body claims that the graph does not carry, one per line, in the
# body's own order. Empty output is the verdict *pass*.
#
# **A pure set difference against the full edge set, closed edges included.** No
# referent's state is resolved: doing so would have the graph defer to prose in
# the acquitting direction — a second representation of blocked, by another name
# — and would cost a REST call per unmatched referent, landing hardest exactly
# where the queue is worst. So a closed edge verifies its claim without blocking.
#
# The edge lines are `read_blocker_edges`'s own, which is what makes this check
# cost nothing: the payload it compares against was already read for the
# open-blocker gate, and the body already rode in on the candidate stream.
# The edge set travels into awk **comma-delimited rather than newline-delimited**,
# and is tested with a substring lookup over the delimiters. `awk -v` runs escape
# processing over its value and one-true-awk refuses a literal newline in it
# outright, so the obvious `split(carried, e, "\n")` dies on macOS. A comma
# cannot appear in either half of an `owner/repo#N` — GitHub's own alphabet for
# both is `A-Za-z0-9_.-` — so the delimiter cannot collide with a value.
unverified_claims() {
  local body="$1" repo="$2" edges="$3" carried
  carried=$(awk -F'\t' 'NF >= 2 { printf ",%s#%s", $1, $2 } END { print "," }' <<< "$edges")
  blocking_claims "$body" "$repo" | awk -v carried="$carried" 'index(carried, "," $0 ",") == 0'
}

# gh-axi changes labels as a delta — an add and a remove in one call — which is
# the same shape GitLab's add_labels/remove_labels had, so neither the claim nor
# the reclaim has to know what else the issue is wearing. The raw REST route
# would not do: its PATCH replaces the label set outright, and it has no way to
# send an empty one.
#
# **One call is not one write.** The add and the remove can land apart. #149
# lost its claim that way: `ready-for-agent` came off, `agent-in-progress` never
# went on, the call failed, and the issue sat wearing neither label — in no
# query the loop makes, under a line saying it had been left ready, with the
# reason sent to /dev/null.
#
# So a failed call is not taken at its word. The labels are read back and the
# swap ends in one of the two states every caller already names: landed, or not
# landed at all. A half is undone — the removed label put back on, or the added
# one taken back off — which is what keeps "leaving it ready" and "leaving it
# claimed" true. A failed call whose swap landed anyway is a landed swap, since
# the label is the claim. What gh-axi said rides on the line in every case, from
# both channels: a refusal arrives on stdout, a failure of its own on stderr.
swap_labels() {
  local github="$1" number="$2" add="$3" remove="$4" error issue wears
  FAILURE_TEXT=""
  error=$(gh-axi issue edit "$number" --repo "$github" --add-label "$add" --remove-label "$remove" 2>&1) \
    && return 0
  # What the caller classifies, unflattened. Every swap caller calls it bare, so
  # the global is live when they read it; the read-back below substitutes and
  # the undo discards, so neither can overwrite it.
  FAILURE_TEXT="$error"
  error="${error//$'\n'/ }"
  error="gh-axi: ${error:-said nothing}"

  if ! issue=$(query_issue "$github" "$number"); then
    log "label swap failed for $github#$number, and its labels could not be read back ($error)"
    return 1
  fi
  # `$add` and `$remove` wear the add and the remove as booleans, tab-joined.
  wears=$(jq -r --arg add "$add" --arg remove "$remove" '
    [.labels[]?.name] as $names
    | "\($names | index($add) != null)\t\($names | index($remove) != null)"' <<< "$issue")

  case "$wears" in
    $'true\tfalse')
      log "label swap failed for $github#$number but landed ($error)"
      return 0
      ;;
    $'false\ttrue')
      log "label swap failed for $github#$number, nothing landed ($error)"
      ;;
    $'false\tfalse')
      if gh-axi issue edit "$number" --repo "$github" --add-label "$remove" >/dev/null 2>&1; then
        log "label swap half landed for $github#$number: $remove came off and $add did not go on, so $remove is back on ($error)"
      else
        log "label swap half landed for $github#$number: $remove came off and $add did not go on, and $remove would not go back on — it wears neither ($error)"
      fi
      ;;
    $'true\ttrue')
      if gh-axi issue edit "$number" --repo "$github" --remove-label "$add" >/dev/null 2>&1; then
        log "label swap half landed for $github#$number: $add went on and $remove did not come off, so $add is back off ($error)"
      else
        log "label swap half landed for $github#$number: $add went on and $remove did not come off, and $add would not come back off — it wears both ($error)"
      fi
      ;;
    *)
      log "label swap failed for $github#$number, and its labels could not be read back ($error)"
      ;;
  esac
  return 1
}

# Claim an issue by swapping its label from ready to claimed. The label swap is
# the claim: it is what tells the next pass, and any second daemon, that this
# issue is taken.
claim_issue() { swap_labels "$1" "$2" "$LABEL_CLAIMED" "$LABEL_READY"; }

# Release an issue by swapping its label from claimed back to ready.
release_issue() { swap_labels "$1" "$2" "$LABEL_READY" "$LABEL_CLAIMED"; }

# --- the refusal -------------------------------------------------------------

# The issue phase's handover. Where the PR phase's escalation hands a pull
# request back, this hands an *issue* back: the loop read it, would not dispatch
# at it, and says why on the issue itself.
#
# **One disposition with a predicate per row, not one disposition per
# predicate.** There are two predicates now — the blocking claim the graph does
# not carry, and the issue that declares no verb or two — and **nothing
# short-circuits**: both always evaluate, and an issue failing both is refused
# *once*, naming both. That is the rule the PR phase already writes down — *all
# four vetoes evaluate, so one handover carries every reason, the ones that
# passed included* — and it transfers unchanged, for the reason given there: the
# passing rows tell the operator where **not** to look.
#
# The opposing argument was put on the record and rejected. The verb is free —
# already in hand on the ready-issue row — where the blocker read is a paid REST
# call per candidate, so refusing on the verb first would save the paid read. It
# loses on the count above; on the currencies being asymmetric, a saved request
# against a human round trip (fix the verb, re-label, wait a pass, get refused
# again for something knowable the first time); on the saving being nearly zero
# anyway, since a refusal is terminal and the issue leaves the queue, so the
# read is paid once per refused issue ever rather than once per pass; and
# because a verb-first refusal would stop comparing the body's claims against
# the graph for exactly the issues most likely to be badly authored. Stated as a
# choice rather than left as an oversight: **a free predicate is deliberately
# deferred past a paid read it does not need, because the refusal evaluates as a
# unit since it reports as a unit.**
#
# **One label for both**, and the reason in the comment rather than in the name.
# A second `needs-verb` label would be two representations of one fact;
# `agent-escalated` already serves four kinds the same way; and the loop's label
# family names *what the loop did*, not what the human must do. The accepted
# cost, named: the flag says *go look*, not *look at this*.

# The refusal's comment, and it is **the gate's record rather than prose** — the
# same shape `escalation_body` writes, from the same `reason` rows and the same
# `md_cell`, so the second predicate arrived as a second row rather than as a
# rewrite.
#
# Rows that passed are carried too, for the reason the handover carries them:
# they tell the operator where *not* to look. With two predicates that has
# stopped being vacuous — an issue whose verb is wrong and whose edges are fine
# says so in one comment.
#
# Two things `escalation_body` has are deliberately absent. **No kind word** —
# the rows already say which predicate failed, and a kind would be a second
# representation of the fact the single label exists to keep singular. **No
# `Read at` line** — the gate needs one because it edits its comment in place, so
# its rows outlive the instant they were read; this posts a new comment every
# time and never edits one, so GitHub's own timestamp is exact and a printed one
# would be a second copy that can disagree.
#
# **The legend carries two verdicts, not four.** The refusal has no clock and
# judges everything it reads, so `defer` and `note` are unreachable.
#
# **It never says the issue is blocked.** The blocking-claim predicate resolves
# no referent state, so a closed edge verifies a claim without blocking. The
# honest sentence is *this claim could not be verified*.
#
# The ways back in are instruction rather than record, and that is a deliberate
# departure from the loop's other comments: a one-way label with no stated way
# back is a trap. **They are per row**, off the row's fourth field: a partial fix
# refuses again and the comment then names only what is still wrong, so progress
# is legible in the record. `reason` sanitises four fields and renders three, and
# what the fourth one *means* belongs to whoever reads it — the permanence mark
# is the PR gate's reading of it, and this table's is the way back in.
refusal_body() {
  local r verdict what raw way
  printf '**Refused — this issue was not dispatched.**\n\n'
  printf '`%s` is off and `%s` is on. The loop re-derives this every pass it can see the issue, and clears the flag on its own once every row below reads `ok`.\n\n' \
    "$LABEL_READY" "$LABEL_REFUSED"

  reason_table "$@"

  printf '\n`ok` passed · `no` stopped the dispatch.\n'

  printf '\n**Ways back in** — then re-apply `%s`.\n\n' "$LABEL_READY"
  for r in "$@"; do
    IFS=$'\t' read -r verdict what raw way <<< "$r"
    [[ "$verdict" == "no" && -n "$way" ]] || continue
    printf -- '- %s\n' "$way"
  done
}

# The two writes, one pass, **label first**.
#
# Direct, not through the writeback seam: the seam's comment and label verbs are
# pull-request-addressed and cannot reach an issue, and its label verb takes
# exactly one of add or remove rather than the delta. The issue phase has never
# used the seam and already writes direct at four sites; this is its fifth.
#
# Splitting the two writes across two passes was rejected — the one-action-per-
# pass convention governs dispatch actions, not writes, and a crash between
# passes leaves an issue labelled and silent.
#
# **The status answers one question: did the issue leave the ready queue.** The
# swap is the terminal act, so a refusal whose swap lands is terminal whatever
# becomes of the record — that is what the caller's counter counts. A lost swap
# is the only nothing-happened outcome, and the next pass derives the same
# verdict and refuses again from scratch.
#
# Which write was lost is said on its own log line rather than in the status: no
# caller branches on it, and both failures are read by an operator rather than by
# the loop. Every way the record can be lost ends on the same line, because a
# flagged issue with no record is the one state an operator cannot read off the
# issue and a silent return would leave exactly that.
refuse_issue() {
  local github="$1" number="$2" file status=0
  shift 2

  # Label first, and the swap is the one add/remove delta the claim and
  # the release already use.
  if ! swap_labels "$github" "$number" "$LABEL_REFUSED" "$LABEL_READY"; then
    # Refused, the next pass derives the same verdict and is refused again,
    # forever, so it flags the issue.
    write_failed "$(gh_error_class "$FAILURE_TEXT")" issue "$github" "$number" refusal-swap \
      "refusal label swap failed for $github#$number, leaving it ready"
    return 1
  fi

  # Free text travels to gh-axi as a file: a --body that happened to look like
  # JSON would be reinterpreted, and this body is a markdown table.
  if file=$(mktemp "${TMPDIR:-/tmp}/agent-loop-refusal.XXXXXX"); then
    refusal_body "$@" > "$file" || status=1
    if (( status == 0 )); then
      gh-axi issue comment "$number" --repo "$github" --body-file "$file" \
        >/dev/null 2>&1 || status=$?
    fi
    rm -f "$file"
  else
    status=1
  fi
  (( status == 0 )) \
    || log "refusal comment failed for $github#$number, the flag is on and the record did not land"
  return 0
}

# The flag coming off, on its own. **The comment is a record of an event** —
# on this pass, this issue claimed a blocker the graph did not carry, or
# declared no verb — which was true then and stays true, so it is never
# withdrawn. **The label is a live flag** over facts the loop re-derives every
# pass it can see the issue, so it does withdraw. A strictly one-way label was
# rejected: it leaves a fixed, re-labelled, dispatched issue wearing a flag that
# is now false, forever.
clear_refusal() {
  gh-axi issue edit "$2" --repo "$1" --remove-label "$LABEL_REFUSED" >/dev/null 2>&1
}

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

# The prompt table: **a closed table with the prompt written out per row**, and
# a table miss is no prompt at all.
#
# Rejected: an allow-list plus pure substitution (`/$verb $weburl`). It looks
# identical for the `implement` row and is not the same design. **The table is
# the refusal** — membership and derivation are one artifact, so *the loop does
# not know this verb* and *the loop will not build a prompt for it* are the same
# line of code and cannot drift apart. And substitution has nowhere to put the
# decomposition instruction below.
#
# The `*)` arm is defence in depth and not the gate: the refusal fires before
# the dispatch, so an unrecognised verb never reaches here. It exists because
# the table's own contract is that an unknown verb yields no prompt.
#
# The arms interpolate the verb constant into their own slash command rather
# than spelling it a second time, and that is **not** the substitution rejected
# above. What was rejected removes the table; this keeps every row written out
# and only single-sources the weld the constant exists for — the label names a
# slash command, so renaming the constant has to rename the command with it or
# the dispatch is incoherent. Membership and derivation stay one artifact.
#
# **The four clauses ride in the prompt as code.** `dispatch_issue` is one
# daemon over the whole `projects` array, so an instruction here travels to
# every configured repository in the file whose invariant depends on it. A
# user-scope skill was reachable — Orca worktrees share this `$HOME` — and was
# rejected on a different ground: an invariant whose residual is *a worker
# instruction* must be auditable by reading this file, not a directory no repo
# tracks and no test sees.
#
# Clause 4 is load-bearing and is phrased as the **situation** rather than as
# "step 4", so a reworded or renumbered upstream skill cannot strand it pointing
# at nothing. Left unsaid, a dispatched agent with no immediate user very often
# answers its own quiz — and a worker that self-approves badly costs a human's
# handover rather than a retry, because a claimed `to-tickets` issue is never
# handed back (#140).
issue_prompt() {
  local verb="$1" weburl="$2"
  case "$verb" in
    "$VERB_IMPLEMENT")
      printf '/%s %s' "$VERB_IMPLEMENT" "$weburl"
      ;;
    "$VERB_TO_TICKETS")
      printf '/%s %s\n' "$VERB_TO_TICKETS" "$weburl"
      printf '\n'
      printf 'Four things about this run:\n\n'
      printf -- '- Link every child issue to this issue by GitHub'"'"'s native sub-issue relationship (`gh-axi issue subissue add <this issue> <child>`), not by a prose `## Parent` section. A prose link is invisible to the loop, and this edge is the only evidence that this decomposition finished.\n'
      printf -- '- Do not apply the `%s` label to any child issue.\n' "$LABEL_READY"
      printf -- '- Apply the `%s` label to every child issue.\n' "$VERB_IMPLEMENT"
      printf -- '- No user is at the keyboard yet, and one will come to this session. Present the breakdown, then wait for their approval before publishing anything. Do not approve it yourself.\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# The prompt is the issue URL and the verb the issue declared — the issue stays
# the single source of what to build, and of which of the loop's two things to
# do with it.
dispatch_issue() {
  local orca_id="$1" number="$2" weburl="$3" type="$4" verb="$5" title="$6" slug prompt response
  slug=$(issue_slug "$title")
  # The branch name is deliberately unchanged for a decomposition run:
  # `change_type`'s whitelist is closed, so `to-tickets` falls through to the
  # `feat` default. A harmless lie, and `feat` is in `ISSUE_BRANCH_TYPES` so the
  # liveness check still finds the worker. Adding a `spec` type would widen one
  # alphabet shared by *two* readers, and the second maps merged pull requests
  # back to issues — it has no business ever matching a branch that cannot
  # become one.
  prompt=$(issue_prompt "$verb" "$weburl") || return 1
  response=$(orca worktree create \
    --repo "id:$orca_id" \
    --name "agent-loop-$type-$number${slug:+-$slug}" \
    --no-parent \
    --agent claude \
    --prompt "$prompt" \
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
  local github="$1" orca_id="$2" issues number weburl type title edges blockers worktree_id
  local prnumber body64 body refusal missing verbs rows kv refused escalation blocker_text readable
  local position=0 candidates

  # On a failure `$issues` holds gh-axi's failure text rather than candidates,
  # and it is read for its class and nothing else.
  if ! issues=$(query_ready_issues "$github"); then
    read_failed "$(gh_error_class "$issues")" "$github" "issue query failed: $github"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  # An empty backlog has no second question to ask, and no read to spend asking
  # it.
  [[ -n "$issues" ]] || return 0

  # One candidate per line — the body rides base64'd, so no field breaks one.
  candidates=$(( $(wc -l <<< "$issues") ))

  # **The truncation canary** (#123). Past `first: 100` the rest are not
  # deferred, they are never seen: no line, no skip, no position. The loop cannot
  # name the issues it cannot see, so a log line is the whole surface, and the
  # fix — pagination was rejected against an observed depth of 14 — is written
  # the day it fires. Exactly 100 with nothing cut off reads as a false positive,
  # which is the honest direction to err.
  if (( candidates >= 100 )); then
    log "issue queue $github truncated: $candidates candidates (cap 100)"
  fi

  # The second door onto an issue. The reclaim guards the first, but a ready
  # label applied by hand reaches this phase without passing through the reclaim
  # at all — so the question is asked again here, and fails closed the same way:
  # a phase that cannot see the open pull requests dispatches at none of this
  # repository's issues rather than risk re-dispatching at a delivered one.
  if ! load_open_pr_issues "$github"; then
    read_failed "$(gh_error_class "$FAILURE_TEXT")" "$github" "open-pr query failed: $github, skipping its issue phase"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  # stdin is closed for the body: gh-axi must not swallow the issue list.
  #
  # The label-derived words sit together after the type, and `body64` sits
  # between them and the title, so the title is still the remainder of the line.
  # `escalation` is whether the refused-write flag is up, read so the claim or
  # the refusal that lands can take it down at no read of its own.
  while IFS=$'\t' read -r number weburl type refusal escalation verbs body64 title; do
    [[ -n "$number" ]] || continue
    # Every candidate counts towards the position, whatever becomes of it, so
    # the deferred line's `queue=` is its place in the whole ordered queue.
    position=$((position + 1))

    # First, and before the blocker read: an issue something already delivers is
    # not worth a second call to find out whether it is also blocked.
    if prnumber=$(open_pr_for_issue "$number"); then
      log "issue $github#$number skipped: pull request #$prnumber already delivers it"
      SKIPS=$((SKIPS + 1))
      continue
    fi

    # Decoded here rather than in the query, so an issue something already
    # delivers does not pay even this. The blocking-claim check below is what
    # reads it. An undecodable field is left empty rather than fatal: the body
    # is not what a dispatch turns on, an empty body passes the check, and
    # `set -e` would otherwise take the whole pass down over one candidate.
    body=$(base64 -d <<< "$body64" 2>/dev/null) || body=""

    # Both halves of the split stay under a handler, so the count is under the
    # same one the single function's failure was under: a bare assignment
    # would put an unreadable count under `set -e` and take the daemon down
    # where the phase means to skip one issue.
    #
    # Two arms rather than one condition, because only the read has failure
    # text: on a failed read `$edges` is what gh-axi said, and a count that
    # fails over a read that landed has nothing to classify.
    blocker_text=""
    readable=true
    if ! edges=$(read_blocker_edges "$github" "$number" < /dev/null); then
      blocker_text="$edges"
      readable=false
    elif ! blockers=$(count_open_blockers "$edges"); then
      readable=false
    fi
    if ! $readable; then
      read_failed "$(gh_error_class "$blocker_text")" "$github" \
        "issue $github#$number skipped: could not read its blockers"
      SKIPS=$((SKIPS + 1))
      continue
    fi

    # **The gate, before the open-blocker skip**, because a skip is a retry and
    # a refusal is terminal. Ordering the skip first would give an issue that is
    # both blocked and unverified exactly the repeated skip and repeated read
    # the refusal exists to end — suppression whose duration is set by an
    # unrelated event. It cannot precede the read above, though: `$edges` *is*
    # the dependencies payload, so the placement is semantic rather than a cost
    # argument.
    #
    # Three arms over the predicates **as a set** — `refuse` when either fails,
    # `pass-and-clear` when both pass and the flag is on, and `pass`. Nothing
    # short-circuits: an issue failing both is refused once, naming both, and a
    # partial fix refuses again with a new record naming only what is still
    # wrong, so progress is legible in the issue's own comment history.
    rows=()
    kv=""
    refused=false

    # The verb first, because it is the row the operator most often has to fix
    # and the record reads top-down. It costs nothing to evaluate — the column
    # arrived on the candidate stream.
    #
    # **Exactly one**, asked of the column's cardinality rather than of its
    # value: `-` is none and a comma is two, and everything else is one by
    # construction, because the column is an intersection with the closed set.
    # So an unrecognised verb refuses through this same door — it is simply
    # absent from the intersection, and there is no separate emptiness check to
    # be forgotten — and a third verb costs a constant, an `ensure_labels` entry
    # and a `case` row, and not a line here.
    kv="verb=$verbs"
    if [[ "$verbs" != "-" && "$verbs" != *,* ]]; then
      rows+=("$(reason ok "this issue declares exactly one verb" "verbs=$verbs")")
    else
      # One row for none and for both, because they are one refusal to the loop
      # — but the raw column carries what was found, so *you wrote no verb* and
      # *you wrote both verbs*, which need opposite fixes, stay distinguishable
      # to the operator reading it.
      rows+=("$(reason no "this issue declares exactly one verb" "verbs=$verbs" \
        "**Declare exactly one verb** — \`$VERB_IMPLEMENT\` or \`$VERB_TO_TICKETS\`, not both.")")
      refused=true
    fi

    # A predicate that could not be evaluated at all reads as *pass*, not as
    # refuse. Under-refusing is safe and over-refusing is not, and there is no
    # input here that can fail to be read: the body arrived on the candidate
    # stream and the edges arrived above.
    missing=$(unverified_claims "$body" "$github" "$edges") || missing=""
    if [[ -z "$missing" ]]; then
      kv="$kv edges=ok"
      rows+=("$(reason ok "every blocking claim in the body is carried by the graph" "missing=-")")
    else
      missing=$(tr '\n' ',' <<< "$missing")
      missing="${missing%,}"
      kv="$kv edges=missing:$missing"
      rows+=("$(reason no "every blocking claim in the body is carried by the graph" "missing=$missing" \
        "**Add the native dependency edge** for every referent named above.")")
      refused=true
    fi

    if $refused; then
      # **The verdict per predicate, derived once**, so the log line and the
      # record cannot tell different stories. Every predicate's key is on the
      # line, the passing ones included — the same *where not to look* property
      # the record's rows have, and what makes a refusal fully diagnosable
      # without opening the issue.
      #
      # The line goes down before the writes, because it reports what the pass
      # *derived* and that is true whether or not the writes land. A write that
      # fails says so on its own line, underneath. The budget does not suppress
      # it either — a full budget defers a *dispatch*, and there is no dispatch
      # here to defer.
      log "issue $github#$number refused $kv"
      # `"${rows[@]}"` is unguarded because both predicates always append,
      # whichever way they went. A predicate that ever refused without adding
      # its row would expand an empty array under `set -u`, which older bash
      # treats as unbound.
      #
      # The counter counts issues that actually left the ready queue, which is
      # what makes a refusal terminal. A lost label swap is the one outcome that
      # is not: the issue is still ready and the next pass refuses it again, so
      # it is accounted the way a lost claim is — as a skip.
      if refuse_issue "$github" "$number" "${rows[@]}" < /dev/null; then
        REFUSALS=$((REFUSALS + 1))
        withdraw_write_flag "$github" "$number" "$escalation" < /dev/null
      else
        SKIPS=$((SKIPS + 1))
      fi
      continue
    fi

    # The flag is live, not permanent: every predicate passed, so a flag
    # standing over them is now false and comes off. **Delivery rather than
    # action** — nothing else is written, no counter moves, and the issue goes
    # on through the remaining gates on this same pass, where a dispatch is
    # already counted as a dispatch. A counter here would count one issue twice.
    if [[ "$refusal" == "flagged" ]]; then
      if clear_refusal "$github" "$number" < /dev/null; then
        log "issue $github#$number refusal cleared"
      else
        log "issue $github#$number refusal flag removal failed"
      fi
    fi

    # **Deliberately unclocked, and the loop writes nothing** (#123). A native
    # dependency edge the operator declared is the whole record: it renders on
    # GitHub's own issue page, and the exit — closing the blocker — is the move
    # they set up themselves. A handover would tell its reader what that page
    # already says, and the count is enough to say *go look*.
    if (( blockers > 0 )); then
      log "issue $github#$number skipped: blocked by $blockers open blocker"
      SKIPS=$((SKIPS + 1))
      continue
    fi

    # Checked before every dispatch, not once per pass: each dispatch spends a
    # slot, and a candidate that arrives at a full budget waits for a later pass
    # rather than being dropped.
    #
    # **Its bound is an ordering, not a clock** (#123). The issue lost on
    # allocation, so a handover at expiry could only say *I have been busy* to a
    # reader who can wait or raise `maxWorkers`. Within a project the queue is
    # oldest first, so the wait is at most the older ready issues ahead of it and
    # the position can only improve, but for an older issue labelled ready later,
    # which jumps ahead once; `queue=` is that bound, spent where it can
    # be seen. Across projects it is deliberately unbounded: the budget is
    # global and `projects` is walked in array order, which is a declared
    # priority. The bound holds only while slots keep freeing — that is #122's.
    if (( ACTIVE_WORKERS >= MAX_WORKERS )); then
      log "issue $github#$number deferred: worker budget full ($ACTIVE_WORKERS/$MAX_WORKERS) queue=$position/$candidates"
      SKIPS=$((SKIPS + 1))
      continue
    fi

    if ! claim_issue "$github" "$number" < /dev/null; then
      # Refused, *leaving it ready* would be forever: the next pass claims again
      # and is refused again. So it flags the issue.
      write_failed "$(gh_error_class "$FAILURE_TEXT")" issue "$github" "$number" claim \
        "claim failed for $github#$number, leaving it ready" < /dev/null
      SKIPS=$((SKIPS + 1))
      continue
    fi
    log "claimed $github#$number"
    withdraw_write_flag "$github" "$number" "$escalation" < /dev/null

    # The claim is already written, so a failed dispatch leaves the issue
    # claimed with no worktree. The next pass's reclaim hands it back, or, for
    # a spec, the handover hands it to a human.
    #
    # Orca passes no text, so this is transient by construction: the issue is
    # named as the write's object, and nothing can ever flag it from here.
    if ! worktree_id=$(dispatch_issue "$orca_id" "$number" "$weburl" "$type" "$verbs" "$title" < /dev/null); then
      write_failed "$(gh_error_class "")" issue "$github" "$number" dispatch "dispatch failed for $github#$number, issue left claimed"
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
# its tree is clean, and everything committed is on the remote or its issue has
# landed. Anything else is left exactly where it is, with a line saying why.
sweep_worktrees() {
  local state created worktree_id path dirty unpushed disposition verdict github number flag reason prnumber issue
  while IFS=$'\t' read -r state created worktree_id path; do
    # Ownership is asked first: a worktree of mine is out of scope before any
    # other question is put to it, and before git is run against it at all.
    is_loop_worktree "$path" || continue

    if [[ "$state" == "live" ]]; then
      # The line goes down every pass, naming its disposition, so `released`
      # and `still counted` are told apart by `grep` rather than by arithmetic.
      disposition=$(worker_disposition "$created" "$worktree_id" "$path")
      IFS=$'\t' read -r verdict github number flag reason <<< "$disposition"
      if [[ "$verdict" == "released" ]]; then
        log "sweep skipped $path: its agent is still going, released: $reason"
      else
        log "sweep skipped $path: its agent is still going, still counted: $reason"
      fi
      # Row B's flag, raised past the bound and withdrawn once Row A holds. A
      # released worker whose claim is gone carries no flag word: close-out and
      # the reclaim already withdraw the flag with the claim they drop.
      if [[ "$verdict" == "expired" ]]; then
        escalate_hung_worker "$github" "$number" "$path" "$reason" < /dev/null
      elif [[ "$verdict" == "released" && "$flag" == "flagged" ]]; then
        withdraw_hung_worker_flag "$github" "$number" \
          "pull request #$(delivering_pr "$github" "$number") delivers it" < /dev/null
      fi
      continue
    fi

    # The worker goes: a flagged claim with no live worker left on it, or one
    # its work now delivers, is no longer Row B, so its flag comes off. Asked
    # of the issue rather than of this worktree, because a `-2` sibling may
    # still be live and holding the flag up.
    #
    # Not of a spec close-out handed over: its flag is the handover's now, and
    # taking it down would post the handover's record again on the next pass.
    # That is #140's named residual — a spec Row B flagged that then dies gets
    # no second record.
    if number=$(issue_for_branch "${path##*/}") \
       && github=$(project_for_orca_id "${worktree_id%%::*}") \
       && [[ "$(claim_flag "$github" "$number")" == "flagged" ]] \
       && ! spec_handed_over "$github" "$number"; then
      if prnumber=$(delivering_pr "$github" "$number"); then
        withdraw_hung_worker_flag "$github" "$number" "pull request #$prnumber delivers it" < /dev/null
      elif ! issue_has_live_worker "$github" "$number"; then
        withdraw_hung_worker_flag "$github" "$number" "its worker is gone" < /dev/null
      fi
    fi

    # git has no classifier and passes no text: empty text, transient, and a
    # local read names no project because it can never be refused.
    if ! dirty=$(git -C "$path" status --porcelain 2>/dev/null); then
      read_failed "$(gh_error_class "")" - "sweep skipped $path: could not read its status"
      continue
    fi
    # **Never removed, delivered or landed or not** (#144). No pull request
    # carries uncommitted work and Orca retains commits only, so this skip is the
    # working tree's one guard. Untracked files count: one may be a new source
    # file nobody `git add`ed. The line goes down every pass and names what the
    # reclaim makes of the tree, so `grep` tells the one it waits on from the one
    # that only costs disk.
    if [[ -n "$dirty" ]]; then
      log "sweep skipped $path: uncommitted changes$(dirty_disposition "$created" "$worktree_id" "$path")"
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
      read_failed "$(gh_error_class "")" - "sweep skipped $path: could not read its push state"
      continue
    fi
    if (( unpushed > 0 )); then
      # **Pinned, and swept once its issue has landed** (#125 Row A, #135). Orca
      # keeps the local branch of any worktree ahead of its base — unpushed,
      # pushed and squash-merged alike, all captured — so for landed work this
      # skip protected nothing the removal does not, and it was the one wait
      # whose exit was never the loop's own. Landed and not delivered, because
      # landing is never undone.
      #
      # One issue read per pinned worktree per pass, and none for any other: a
      # pin is rare, the read is self-contained where the pass's per-project
      # pull-request maps are not, and a failed read falls closed into exactly
      # the skip below. No GitHub record: there is nothing for a reader to do.
      #
      # **Not landed keeps the skip**, and its exit is the reclaim's retry: the
      # redispatch delivers, the pull request merges, and this worktree
      # graduates into the removal. **Named residual:** a worktree whose name
      # carries no issue number can be read for nothing, and stays pinned until a
      # human removes it.
      if number=$(issue_for_branch "${path##*/}") \
         && github=$(project_for_orca_id "${worktree_id%%::*}"); then
        if ! issue=$(query_issue "$github" "$number" < /dev/null); then
          read_failed "$(gh_error_class "$issue")" "$github" \
            "sweep skipped $path: $unpushed commits not on the remote, could not read whether $github#$number has landed"
          continue
        fi
        # Close-out closes an issue on the pass its pull request merges, and a
        # merge's closing keyword closes it as completed too, so a completed
        # close is the landing. Closed as not planned is not.
        #
        # **Named residual:** an issue closed as completed by hand, with nothing
        # merged, reads as landed. One issue read cannot see the merge — close-out
        # closes by its own hand, so no closing pull request is recorded on the
        # issue — and the cost is bounded by the branch Orca keeps. Rejected:
        # keying on close-out's merged-pull-request search, which is one page,
        # global and not kept for the pass — #125's rejected cross-phase map.
        if jq -e '.state == "closed" and .state_reason == "completed"' <<< "$issue" >/dev/null 2>&1; then
          sweep_landed_worktree "$path" "$github" "$number" "$unpushed"
          continue
        fi
      fi
      log "sweep skipped $path: $unpushed commits not on the remote"
      continue
    fi

    if remove_worktree "$path"; then
      log "swept $path"
      SWEEPS=$((SWEEPS + 1))
    fi
  done < <(orca_worktrees)
}

# remove_worktree <path> — the sweep's one removal, its JSON response left in
# REMOVAL_RESPONSE for a caller that names what Orca kept.
#
# No --force. That does not guard the working tree: nothing captured says Orca
# refuses a dirty one, and the sweep's `uncommitted changes` skip precedes every
# call, so Orca never sees one. What the removal does keep is the local branch
# of any worktree ahead of its base (#135), and that branch is the only thing
# that survives it. Orca's trash directory is empty at rest and recovers
# nothing.
#
# A failure logs its own line, with the removal's stderr on it, so a sweep that
# failed says why. Orca's text carries no status, so the failure is transient by
# construction and names no GitHub object to flag.
#
# The response is left in a global rather than on stdout for `FAILURE_TEXT`'s
# reason: the helper is called bare, because its status is the answer and its
# failure line is its own, and a command substitution would run it in a
# subshell where `write_failed`'s count is lost.
REMOVAL_RESPONSE=''
remove_worktree() {
  local path="$1" errfile err=''
  REMOVAL_RESPONSE=''
  errfile=$(mktemp "${TMPDIR:-/tmp}/agent-loop-sweep.XXXXXX") || errfile=/dev/null
  if REMOVAL_RESPONSE=$(orca worktree rm --worktree "path:$path" --json 2>"$errfile" < /dev/null); then
    [[ "$errfile" == /dev/null ]] || rm -f "$errfile"
    return 0
  fi
  if [[ "$errfile" != /dev/null ]]; then
    # One line, whatever the CLI wrote: the log is line-oriented.
    err=$(tr -s '\n\t' '  ' < "$errfile")
    err="${err% }"
    rm -f "$errfile"
  fi
  write_failed "$(gh_error_class "")" - "" "" sweep \
    "sweep failed for $path, leaving it in place${err:+: $err}"
  return 1
}

# sweep_landed_worktree <path> <github> <number> <unpushed> — the removal of a
# pinned worktree whose issue has landed, on its own line. It is the one removal
# that leans on Orca's retention rather than on the loop's own proof, so the
# line names the branch and head the commits were left on, read off the
# removal's response rather than derived, and anything abandoned stays findable
# from the log alone.
sweep_landed_worktree() {
  local path="$1" github="$2" number="$3" unpushed="$4" kept
  remove_worktree "$path" || return 0
  SWEEPS=$((SWEEPS + 1))
  kept=$(jq -r '.result.preservedBranch
    | select(type == "object" and (.branchName | type) == "string" and (.head | type) == "string")
    | "\(.branchName) at \(.head)"' <<< "$REMOVAL_RESPONSE" 2>/dev/null) || kept=''
  if [[ -n "$kept" ]]; then
    log "swept $path: $github#$number has landed, its $unpushed commits not on the remote kept on branch $kept"
  else
    # Never captured: every worktree ahead of its base came back with the
    # branch named. Said rather than guessed at if Orca ever changes that.
    log "swept $path: $github#$number has landed, and the removal named no branch it kept"
  fi
}

# dirty_disposition <createdAt> <worktreeId> <path> — the suffix the sweep's
# `uncommitted changes` line carries (#144): `, holding its claim` while the
# reclaim would still count this tree as a worker — inside
# `workerTimeoutSeconds` of its `createdAt`, or with no `createdAt` at all, the
# bound `claim_hold` puts on each matching tree — and `, claim released` past
# that bound or once the claim is gone. Past the bound it is this tree that
# releases the claim: a claim still held by something else — an open pull
# request, a spec's exemption, a sibling worktree — is not this line's. Empty
# when the tree names no issue or no configured repository, and when that
# repository's claims could not be read this pass, since then there is no claim
# to speak of. Pure: it reads only the claims close-out left for the pass, after
# any the reclaim dropped.
dirty_disposition() {
  local created="$1" worktree_id="$2" path="$3" github number
  number=$(issue_for_branch "${path##*/}") || return 0
  github=$(project_for_orca_id "${worktree_id%%::*}") || return 0
  [[ "$PASS_CLAIMS_READ" == *" $github "* ]] || return 0
  if ! claim_flag "$github" "$number" >/dev/null; then
    printf ', claim released'
  # `createdAt` is epoch-ms; the bound is in seconds.
  elif [[ "$created" == "-" ]] || (( PASS_NOW - created / 1000 <= WORKER_TIMEOUT )); then
    printf ', holding its claim'
  else
    printf ', claim released'
  fi
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
#   needs-review       acts on the pass it is      the retraction, when one has
#                      derived; one poll interval  to come down first
#                      later when a standing
#                      handover must be retracted
#                      first
#   needs-review,      reviewRetryTimeoutSeconds   the first nudge at this head
#     retrying a
#     refused command
#   needs-autofix      acts on the pass it is      the retraction, when one has
#                      derived; one poll interval  to come down first
#                      later when a standing
#                      handover must be retracted
#                      first
#   assessable         mergeGateTimeoutSeconds;    the head commit's date,
#                      the pass it is derived      applied outside the gate —
#                      when a deferring reason is  and the retraction, when one
#                      marked permanent; one poll  has to come down first
#                      interval later when a
#                      standing handover must be
#                      retracted first
#   merge withheld at  external                    a push, or a merge by hand
#   a refused head
#
# The retry row is separate from the plain `needs-review` one because it bounds
# something that row cannot speak to: the retry spans passes that are each
# individually `needs-review` and each individually act on the pass they are
# derived, and *acts on the pass it is derived* says nothing at all about the
# span.
#
# **`rate-limited` is gone, and so is the paragraph that defended it as correct
# rather than a hole.** Both halves of that defence were measurably false: the
# loop never read the estimate the comment ships with, and one pull request sat
# three hours and twenty minutes on a block whose own banner said five minutes.
# The state accounted for 316 passes across seven pull requests, the longest run
# 9h38m, and its wait was a deadlock rather than a bound — the walkthrough's
# rate-limit block is a slot rewritten only by a review, and a review is the one
# thing the state forbade asking for, so **the exit condition could only be
# produced by the action the wait forbade.** An external bound nobody can observe
# is not a bound. The remedy is the retry row above: ask again, because asking
# into a limit costs nothing but latency.
#
# **Adding a state means adding a row.** There is no `escalated` row because
# there is no such state, and the table is checkable one row at a time only
# because of that: a pull request carrying a handover is in whichever state its
# signals actually put it, and that row's bound is the row's own.
#
# **The last row is not a state, and it is the one exception that rule needs.**
# A pull request whose merge is withheld at a refused head is `assessable` — its
# signals put it there and the gate ran to completion. What no state row covers
# is the *wait*: `assessable`'s bound is the gate clock, and the gate has already
# decided, so nothing on that row reaches this. A standing handover needs no row
# for the opposite reason — the wait it causes is one pass of retraction, and
# that cost is written on the rows of the states whose action it delays. This one
# is neither one pass nor the loop's to end, so it is either a row of its own or
# a wait with no bound written down anywhere, which is exactly what this table
# exists to make impossible.
#
# **Every loop-owned bound in this table expires into a handover, and the
# one-pass cost of retraction is on every row whose action a standing record
# delays.** Those are
# the only three writes a standing record holds — the nudge, the autofix trigger
# and the merge — so they are the only rows that can carry the cost, and a fourth
# action added to the chain adds a fourth. The tail's own writes are not among
# them: the handover, the retraction and the label chase are what *consumes* the
# record rather than what the record withholds. A record the loop cannot rewrite
# is not one pass but the operator's move, which is what `bound=operator` says on
# the log line. The cost is written on the rows rather than in a footnote so that
# nobody adds a fifth handover kind without seeing the bill.
#
# **The one externally-bounded row clears the bar `rate-limited` failed, and
# that is why it is a bound rather than a second deadlock.** A merge withheld at
# a head whose refusal was withdrawn has no loop-owned clock, because the loop
# has already asked GitHub about this exact commit and been told no, and it does
# not ask twice. What makes the wait bounded is the two things the rate limit
# never had: **the exit is observable** — a push moves the head, a merge by hand
# ends the pull request, and both are events on the pull request the next pass
# reads off the same query — and **the exit is not the action the wait
# forbids.** What is withheld is one merge write; what ends the wait is an
# operator gesture the loop never held back. `rate-limited` could say neither.
#
# **It is still a decision rather than a property of GitHub, and the cost is
# stated rather than hidden.** `refused` is every durable answer the merge call
# can come back with, and a few of them clear without anybody pushing — an
# unsatisfied review requirement approved, say. The loop will not go back and
# look. What that buys is the end of a two-pass oscillator on a pull request
# already asking for a human; what it costs is that the push is what re-arms it.
# The row expires into re-derivation rather than into a handover, silently,
# which is the whole of what being bound outside the loop means here.
#
# **A standing handover is the other thing here with no loop-owned bound, and
# that is correct rather than a hole.** Its exits are the operator's three —
# merge by hand, push, convert to draft — plus the loop's own **retraction**,
# when re-derivation stops agreeing with the record. That is a real exit an
# observer can see, which is exactly what `rate-limited` never had.
#
# The three timeouts run off **three different origins** on purpose, which is
# also why the two configured keys stay separate: the merge-gate key alone has
# two consumers, and the measurements behind them differ by orders of magnitude.
#
# **`mergeGateTimeoutSeconds` is a floor with a named cost, not a tuned number,
# and this file deliberately sets none.** Its population divides in two. For
# transient computation — a check still running, a conflict axis GitHub has not
# finished calculating — it is a **floor**: the clock must outlast the slowest
# legitimate check run in the repository, or the loop hands over pull requests
# that were merely slow. For a permanent blocker no veto owns it is **pure
# latency**: nothing the wait buys can change the answer, and every second of it
# is an operator kept waiting. One number cannot be right for both, so the number
# stays the operator's. Deriving it from a single observed specimen was rejected
# — one sample is a floor observation, not a timeout — and so was splitting the
# gate's consumer into a config key of its own, which is real ergonomics debt but
# a breaking required-key change.
#
# **A second invariant, with its own register: no cycle in the PR phase may turn
# without an external event.** Un-latching restores derivation rather than
# writes, so the metered writes are untouched; what it makes possible is a pull
# request that oscillates between states. Every cycle the phase can turn is
# listed here with the event that drives it, and a cycle with no driver is a
# defect:
#
#   cycle                                            driver
#   ---------------------------------------------------------------------------
#   BEHIND -> retract on UNKNOWN -> re-escalate      a merge into the base branch
#   V2 FAILURE -> retract on a re-run going
#     pending -> re-escalate on a second failure     the operator re-running a
#                                                    check
#   needs-autofix -> autofix pushes a CodeRabbit-
#     authored head -> nudge and review -> gate ->
#     needs-autofix at the next human head           a human push
#   nudge -> refusal -> nudge                        **none** — bounded in
#                                                    aggregate instead, by
#                                                    reviewRetryTimeoutSeconds
#                                                    into an absorbing `declined`
#                                                    record
#
# **Bounded per turn is not bounded in aggregate, and the register turns on the
# difference.** A repetition bounded only per turn is still a cycle: it can
# oscillate forever, because there is no state it cannot leave. This one is
# bounded *in aggregate* — at most `ceil(reviewRetryTimeoutSeconds /
# pollIntervalSeconds)` turns, and then it enters `declined`, which **gates the
# write that turns it**. A repetition with an absorbing terminal state is a
# sequence, not a cycle, and leaving that state takes a genuine external event:
# a push, the operator, or a review that lands. Neither tempting argument is
# used, and both are wrong — *the refusal is CodeRabbit's, so the cycle is
# driven* (it is caused by the loop's own write and carries no new information)
# and *bounded, therefore licensed* (that is what killed the `refused` state).
#
# **A third party's automatic reaction to a loop-authored write is not an
# external event.** Admitting it would make the invariant unfalsifiable, since
# every loop write provokes some reaction. The line is the loop's causal closure:
# a human *choosing* to re-run a check is outside it; a bot firing because the
# loop pushed is not.
#
# **The register shipped one undriven row and no longer does.** `merge ->
# refused -> retract on the gate saying merge again -> merge -> refused` turned
# on nothing at all: the merge spend was derived from the record and went down
# with it. The withdrawal notice's marker is the head-keyed fact that survives
# the withdrawal, so the cycle stops turning and stops being a cycle. The row is
# gone rather than driven, and the state it leaves behind is a row in the table
# above instead.
#
# **A third invariant, with its own register: no metered write may be spent
# where it provably cannot change anything.** Stated absolutely — a metered
# write with no such bound is a **defect** — because the rule was already being
# enforced ad hoc at three sites with no shared name, and the one site that
# stated its argument as settled is the one that was wrong. The register is
# closed rather than a sample: `pr-writeback.sh` has six verbs, and the other
# three — `comment`, `edit` and `label` — are the handover writes, which are
# deliberately not metered per head for the reason given at the escalate seam
# below.
#
#   metered write     bound
#   ---------------------------------------------------------------------------
#   review (nudge)    aggregate-bounded into an absorbing `declined` record by
#                     reviewRetryTimeoutSeconds. A passing row, and what passing
#                     looks like
#   merge             at most one per repository per pass, and withheld at a
#                     head a standing record already refused — including across
#                     a withdrawal, now that the notice carries the head-keyed
#                     marker that survives it (#100, closed)
#   autofix trigger   once per head (`spent:trigger`), and never at a head the
#                     loop minted (`spent:own-head`) — **but nothing bounds
#                     re-firing across heads at threads the bot has already
#                     fixed.** A failing row: accepted and priced, tracked as
#                     #131
#
# **The failing row is not a reason to soften the invariant to fit it.** The
# precedent is exact and it is one register up: *a cycle with no driver is a
# defect* is stated absolutely, and the register then lists the one row whose
# driver is **none** and argues it in the open rather than rewording the rule
# until the row passes. A register that lists only what passes is not a
# register.
#
# **Why the autofix row fails.** Autofix does not resolve the threads it fixes,
# so `threads > 0` is satisfied by already-fixed threads forever and the trigger
# fires a fully metered run at every future human head on that pull request. The
# bot takes it in full — *"Coding task started for 8 unresolved review
# comments"* — with no dedup and no decline (#128). The domain fact underneath,
# which no count could have carried: on a pull request autofix has run on,
# **"unresolved" has stopped meaning "outstanding".**
#
# **Two clauses were retracted from the `threads` derivation commentary below,
# and they were falsified separately and for unrelated reasons (#110).** State
# them separately or the retraction misleads: the first does not imply the
# second, so nobody should try to repair the second by fixing the first. They
# were also in the wrong place, and that is positional rather than a matter of
# degree — the paragraph they sat in is `pr_facts` per-field derivation
# commentary, where every neighbour answers *how is this field computed*, and a
# spend claim was parked in a derivation note.
#
#   *the loop's trigger condition and the bot's are the same predicate* — false
#   **narrowly and by choice.** The bot's documented precondition has three
#   conjuncts (#107, verbatim: *"Autofix only processes unresolved CodeRabbit
#   review threads with valid fix instructions"*); the loop tests two; the third
#   was priced and declined (#111).
#
#   *a metered run that would do nothing cannot be fired by construction* —
#   false for an **unrelated** reason. #128's eight already-fixed threads all
#   *satisfy* the bot's precondition, so on that axis loop and bot genuinely are
#   the same predicate and the run still does nothing. **The bot's precondition
#   was never a usefulness test.**
#
# **The weakened fallback is rejected rather than kept**: *the loop never fires
# a run the bot would refuse outright* is true, and true-but-misleading. It is
# true precisely because the bot refuses nothing.
#
# **The honest version is a superset, and it is on the record: the loop tests
# two of the bot's three documented conjuncts, knowingly.** The third — *valid
# fix instructions* — costs **+122% of the entire state response on every pass,
# per open pull request**, for zero observed benefit: 44 of 44 threads carried
# the block (#111). The price is written next to the decision so it can be
# re-opened on evidence rather than re-litigated on intuition. And #111's fourth
# argument inverts the usual one: the unfiltered superset **announces itself**
# in the log at every head where a filtered subset would fail silently, so
# visibility is a reason for the waste rather than a consolation for it.
#
# **The decision, in one line: the `needs-autofix` trigger's thread count does
# not filter, on any predicate, at any of its three consumers** — the trigger,
# the `kv` line, and the stalled handover's `ok` row. Six tickets went looking
# for a filter that would stop the re-fire; there is none. The pointer sits at
# the derivation, where the temptation is; the argument sits here, with the
# other spend arguments, so the file has one place where spend is argued.
#
# **`isOutdated` is the filter everybody reaches for, and it is dead.** Autofix
# acts on outdated threads and will follow a stale thread over the live file,
# and it rewrites the very lines its own threads anchor to — so after one run
# **every** thread on the pull request is outdated, and the filter takes the
# count to zero permanently on exactly the pull requests the trigger exists for
# (#108). Under-firing on live findings is strictly worse than the waste.
#
# **The derivation emits one number and keeps emitting one.** A second column is
# structurally cheap — the emit list is positional and the caller reads it with
# a `read -r` sequence — and #109 considered both free candidates and **declined
# both on truthfulness rather than cost**, so a cheaper derivation does not
# reopen the question: `outdated=` re-commits the conflation this decision
# forbids, and a locally-derived *predates the last autofix status* reads 8 of 8
# at the head where autofix hung and fixed nothing. `threads=8` on the `kv` line
# stays **raw**, so the number matches what GitHub's own UI shows the operator.
#
# **The query is not the place to fix this either.** `isOutdated`, `id`, `path`
# and `line` are fetched every pass for every open pull request and read by
# nothing. That is real, and it is a change to how the count is *read* rather
# than to what it filters, so it goes to #112, which has to rewrite that
# selection anyway. `isOutdated` **stays** — its presence is what keeps the
# pointer at the derivation honest, because the pointer warns against filtering
# on a field that is genuinely sitting right there.
#
# **What would reopen #131**, named here so it is reachable from the row: the
# bot gaining an already-fixed signal on the wire, or a free head-keyed fact
# that survives. Neither exists today. The counter worth revisiting first is
# that autofix metering is **silent** — #128 measured 24m27s to acceptance and
# then 1h52m still at *started*, with no refusal comment ever, where `review`
# refuses loudly in seconds. The loop cannot see that backpressure, so if
# autofix ever gains a visible signal the way `review` has one, this accounting
# is worth re-opening.
#
# **The rule all three invariants lean on is: the loop does not act on its own
# output.** It has exactly two sites, and they are meant to read as one
# principle — terminality's ban on a `no` resting on a cause the loop's own
# writes produced, and autofix's ban on a spend at a head the loop minted.

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
# already on this pull request. That is what makes the chase free — the comment
# says whether a record stands, this says whether it is flagged, and both facts
# arrive on reads the phase was making anyway. The chase now runs in both
# directions off the same one field: a flag with no record behind it is as much
# a disagreement as a record with no flag. `author` and
# `baseRefName` are fetched and read by nothing at all, and that is the point —
# the scope rule has exactly two exclusions, and neither who opened the pull
# request nor what it is merging into is one of them.
query_repo_open_prs() {
  local github="$1" owner="${1%%/*}" name="${1##*/}" response
  # A failure's text goes out on stdout for the call site to classify.
  if ! response=$(gh_graphql "{ repository(owner: \"$owner\", name: \"$name\") { pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number title url isDraft isCrossRepository author { login } baseRefName headRefName headRefOid labels(first: 50) { nodes { name } } } } } }"); then
    printf '%s' "$response"
    return 1
  fi
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
# The head commit's **author** is one extra field on a request already being
# made, and it is what stops autofix acting on the loop's own output: a head
# CodeRabbit wrote is a head the loop does not fire autofix at. Author rather
# than committer, knowingly over-broad — GitHub's *Commit suggestion* button
# attributes the author to whoever suggested the change, so this over-fires
# there, and the operator recovers by hand-typing the command, which the loop
# already recognises as an autofix in flight. Under-firing would cost the
# invariant with no backstop at all, and the committer test rests on an
# unverified assumption about what GitHub stamps on a bot push.
#
# `mergeable` and `mergeStateStatus` are the risk gate's V3, and they are two
# fields rather than one because they carry different facts: the first is the
# conflict axis, the second is everything else GitHub folds into one enum, of
# which V3 owns base drift alone. Both are computed lazily and both can come back
# `UNKNOWN` on a first read, with no documented retry contract anywhere; that is
# what `defer` is for.
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
# talkative.
#
# The status `description` and the check run's `title` are **CodeRabbit's own
# answer to the command** — one description, two surfaces — and they are what
# `signalDesc` reads. `description` was already fetched and read by nothing;
# `title` is the one word this query grew for it. The thread `path`/`line` are
# still fetched and read by nothing: the fixtures behind this are whole
# captures, and a query narrowed to what today's derivation happens to use would
# couple them silently to it.
query_pr_state() {
  local github="$1" number="$2" owner="${1%%/*}" name="${1##*/}" response
  if ! response=$(gh_graphql "{ repository(owner: \"$owner\", name: \"$name\") { pullRequest(number: $number) { number headRefOid mergeable mergeStateStatus files(first: 100) { totalCount nodes { path } } commits(last: 1) { nodes { commit { oid committedDate author { user { login } } statusCheckRollup { state contexts(first: 100) { nodes { __typename ... on StatusContext { context state description createdAt creator { login } } ... on CheckRun { name title status conclusion startedAt completedAt checkSuite { app { slug } } } } } } } } } reviewThreads(first: 100) { nodes { id isResolved isOutdated path line comments(first: 100) { nodes { databaseId createdAt author { login } } } } } comments(last: 100) { nodes { databaseId createdAt updatedAt body author { login } } } } } }"); then
    printf '%s' "$response"
    return 1
  fi
  jq -e '.data.repository.pullRequest != null' <<< "$response" >/dev/null 2>&1 || return 1
  printf '%s' "$response"
}

# The twenty-two facts the state machine runs on, one per line — see the caller
# for why they are not one tab-separated line:
#
#   head        the head commit
#   headDate    its committer date, ISO-8601
#   ownHead     true when the head commit's author is CodeRabbit
#   terminal    true when CodeRabbit's review on that commit has finished
#   threads     unresolved CodeRabbit review threads on the pull request
#   statusAt    newest autofix-status comment, ISO-8601, empty if none
#   statusHead  input head recorded by that status's trigger, empty if unknown
#   triggerAt   newest autofix trigger I posted, ISO-8601, empty if none
#   escalated   true when a record stands at that head, whoever wrote it
#   escKind     the kind that record carries, empty when it carries none
#   escComment  the newest *loop-authored* comment carrying it, empty if none
#   wdnKinds    every kind a withdrawal notice at that head names, space-
#               separated, empty when no record has been withdrawn at it
#   signal      true when CodeRabbit has reported *anything* on that commit
#   pendingAt   oldest CodeRabbit signal on it that has not reported, ISO-8601
#   signalDesc  what CodeRabbit's newest signal on the head says, verbatim,
#               empty when there is none
#   signalAt    that signal's timestamp, ISO-8601, empty when there is none
#   block       present | absent — a merge-risk block anywhere on the PR
#   blockAbbrev the commit abbreviation that block names, empty when there is
#               no block or its line does not parse
#   nudgeAt     newest review nudge I posted, ISO-8601, empty if none
#   nudgeFirstAt oldest review nudge I posted *at this head*, empty if none
#   nudgeCount  how many review nudges I posted on this pull request
#   reply       CodeRabbit's newest comment after that nudge, verbatim
#
# Eight judgements are made here and are worth naming:
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
# calling it needs-review, and hand it over one poll interval into a review that
# was running. `success` means *the review ran*, never *the review
# found nothing* — a pull request with five findings and a high merge risk
# carries the same green status as a clean one.
#
# **`signalDesc` is what that same newest signal *said*, and it is selected off
# the same node `terminal` is computed from** — one `max_by(.at)`, bound once,
# read twice — so the two facts can never come to describe different signals.
# That is the discipline `RISK_BLOCK_PARSE` already keeps by having one spelling
# for two readers, applied to one node instead of one parse.
#
# It is read from **both surfaces**: `StatusContext.description` and
# `CheckRun.title`. One description, two deliveries — a rate limit arrives as a
# status on this account and as *a passing check titled Review rate limited*
# where check runs are the default — and a fact that read only one of them would
# be blind on half the accounts the loop runs against.
#
# It is carried **verbatim**, flattened only on newline and tab like the reply
# and for the same protocol reason. It is `terminal`'s orthogonal partner:
# `terminal` says *did CodeRabbit stop*, `signalDesc` says *what did it stop
# saying*. `terminal` is deliberately unchanged by it — a refusal **is**
# CodeRabbit stopping, and making a refusal non-terminal would park the pass in
# the pending branch for the whole gate clock.
#
# **`signalAt` earns its place as the freshness test and nothing else.** The
# status carries no invocation id, so attributing a refusal to the loop's own
# command could only ever be timestamp ordering wearing a stronger name;
# `signalAt > nudgeAt` is the honest version of the same question, and it is the
# shape `$reply` already uses. Without it a pass running four seconds after a
# nudge would read the pre-nudge word and fire again before CodeRabbit answered.
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
# **The abbreviation comes off the newest of those blocks and is parsed by the
# gate's own definition**, not a second copy of it. Newest by the *updated*
# timestamp for the same reason everything else about a walkthrough is: a pull
# request can carry a stale walkthrough created later than the one CodeRabbit
# has been editing, and reading *any* block would let the stale one answer for
# the head. The scope stays broader than the gate's; only the parse is shared,
# so the two cannot come to disagree about which commit a verdict names.
#
# **A thread is CodeRabbit's when CodeRabbit opened it.** The first comment's
# author decides, not any comment's: a thread I opened that the bot replied to
# is my conversation, not its finding. That is also the bot's own precondition
# — autofix processes unresolved CodeRabbit threads.
#
# This paragraph used to draw a spend conclusion from that last sentence. It is
# **retracted**, and the retraction lives with the third invariant above (#110).
#
# **CodeRabbit comment freshness is the *updated* timestamp; mine is the
# created one.** CodeRabbit delivers by editing comments it already posted, so
# a created timestamp can be days stale. My own trigger and my own nudge are
# never edited by me, and their creation is the event.
#
# **The escalation marker splits into three facts, because editing turned a read
# into a write target.** *Does a record stand at this head?* is matched on the
# head commit and on nothing else — no author test, no timestamp test, and no
# kind test. The commit is what a handover is scoped to, and a marker naming
# this head means the record exists whoever put it there: an operator who quoted
# the comment back has said the same thing the loop said, and a marker naming
# any other commit is a record of a handover that is over. No timestamp is
# consulted because a comment cannot predate the commit it names.
#
# *Which comment may the loop edit?* is a different question and gets a
# different answer: the newest comment carrying that marker **that the loop
# itself wrote**, empty when there is none. Both `databaseId` and `author.login`
# are already in the query, so the split costs no read at all. Narrowing the
# existence test to loop-authored comments as well was rejected — an operator's
# echo of the record would stop suppressing a duplicate handover — and the price
# of not narrowing it is paid where it belongs, at the one write that would
# otherwise land on someone else's comment.
#
# *What does it claim?* is the kind, read off that same comment. Absent — a
# marker from before the kind existed — is not a kind, so it equals nothing the
# chain can derive and migrates itself on the next pass.
#
# **The withdrawal marker splits into one fact, and it is the set of kinds.**
# Whether a record was ever withdrawn at this head is not on its own worth
# carrying — nothing acts on a withdrawal as such — so the existence test and
# the kind collapse into one value: every kind a withdrawal notice at this head
# names, one word each, space-separated and empty when there are none. Each is
# read *exactly* as the record's kind is, on the same two constants and by
# splitting rather than by a second spelling of the marker as a regex, for the
# same reason: a marker changed in one place and not the other would read as no
# kind on every pass forever.
#
# **Every notice at the head answers, not the newest one.** A withdrawn kind is
# a record of a write the loop already made, so it is true of that commit
# forever and nothing later can make it false — where the newest-wins reading
# the record's own kind uses would let a second withdrawal *mask* the first. A
# head really can carry two: a record standing at a head the loop has already
# withdrawn one at is **posted as a new comment**, because the withdrawn one
# carries no record marker to write over, so the older notice survives intact
# and the newer one is written elsewhere. Read newest-first, a `refused` spend
# would vanish the moment a `stuck` record came and went at the same commit,
# and the oscillator this whole marker exists to kill would come back.
#
# Not author-scoped, for the same reason the record's existence test is not —
# whoever wrote a marker naming this head has said the thing it says. The price
# differs, though, and is worth stating: a foreign quote of a withdrawal notice
# **withholds a merge** at that head. That fails in the safe direction, unlike
# the record's own case — withholding is the conservative act, the pull request
# is one a human has already been asked to look at, and the hand-merge exit is
# untouched — so it is named here rather than guarded against.
#
# The reply is carried so the handover can paste it, and so the chain can tell
# a comment-only answer from silence. **It is keyed on its presence, never on
# its content** (#143) — a reply with no status is a stall, silence is not, and
# nothing reads what the reply says — so it is flattened onto one line like
# every other value here rather than parsed.
pr_facts() {
  jq -r \
    --arg crctx "$CODERABBIT_STATUS_CONTEXT" \
    --arg crlogin "$CODERABBIT_LOGIN" \
    --arg me "$ME" \
    --arg trigger "$AUTOFIX_TRIGGER" \
    --arg nudge "$REVIEW_TRIGGER" \
    --arg statusmarker "$AUTOFIX_STATUS_MARKER" \
    --arg riskstart "$RISK_BLOCK_MARKER" \
    --arg escprefix "$ESCALATION_MARKER_PREFIX" \
    --arg escsuffix "$ESCALATION_MARKER_SUFFIX" \
    --arg wdnprefix "$WITHDRAWN_MARKER_PREFIX" \
    --arg wdnsuffix "$WITHDRAWN_MARKER_SUFFIX" "$RISK_BLOCK_PARSE"'
    def is_coderabbit: (. // "") | ascii_downcase | startswith($crlogin);
    # A newline or a tab inside a value would reshape the one-value-per-line
    # protocol at the bottom of this program into a *different* set of values
    # rather than corrupt one visibly. Only the reply can carry either, and it
    # is the one value here written by something other than a machine.
    def flat: (. // "") | gsub("[\n\t]"; " ");
    # The kind a marker in this body carries, cut apart on the two constants the
    # match already uses — **not by a second spelling of the marker as a regex.**
    # A regex copy would have to be escaped by hand against a marker that might
    # one day gain a metacharacter, and worse, a marker changed in one place and
    # not the other would read as no kind on every pass forever: the record would
    # be replaced, the replacement would be just as unreadable, and the loop would
    # rewrite it once per pass. Splitting cannot drift, because there is nothing
    # to keep in step.
    #
    # <head_prefix> is the marker prefix with the head already on it, so a body
    # carrying two markers cannot answer with the wrong one. `split` yields a
    # one-element array on no match, so the absent cases fall through as null and
    # then as "" — which is the answer a marker from before the kind existed has
    # to be able to give. The result is a bare lowercase word or nothing: a marker
    # whose suffix went missing would otherwise hand the rest of the comment over
    # as a "kind", and every kind the loop writes is one lowercase word.
    #
    # One definition, two markers: the kind on a standing record and the kind on
    # a withdrawal are the same question asked of different prefixes, and a
    # second copy of this is how the two come to disagree about what a kind is.
    def marker_kind(head_prefix; suffix):
      (((((. // "") | split(head_prefix))[1] // "")
        | (split(suffix)[0] // "") | ltrimstr(" ")) as $k
       | if ($k | test("^[a-z]+$")) then $k else "" end);
    .data.repository.pullRequest as $pr
    | ($pr.commits.nodes[-1].commit // {}) as $head
    # Everything CodeRabbit put on the head commit, either surface, kept whole
    # so that *how many* and *how old* can be asked of it as well as *finished*.
    | [ $head.statusCheckRollup.contexts.nodes[]?
        | if .__typename == "StatusContext" then
            (if (.context == $crctx or (.creator.login | is_coderabbit))
             then { terminal: (((.state // "") | ascii_upcase) | IN("SUCCESS","FAILURE","ERROR")),
                    at: .createdAt,
                    desc: (.description // "") }
             else empty end)
          elif .__typename == "CheckRun" then
            (if ((.name // "") == $crctx or (.checkSuite.app.slug | is_coderabbit))
             then { terminal: (((.status // "") | ascii_upcase) == "COMPLETED"),
                    at: .startedAt,
                    desc: (.title // "") }
             else empty end)
          else empty end ] as $signals
    # **Bound once, read three times.** `terminal`, `signalDesc` and `signalAt`
    # all come off this one node, so no arrangement of the emit list below can
    # make them describe different signals. `max_by` on an empty array is null,
    # and null indexes to null, which falls through to the defaults each of the
    # three names for itself.
    | ($signals | max_by(.at // "")) as $newest
    # **This count does not filter, on any predicate — and least of all on
    # `isOutdated`, which is fetched by the query above and read by nothing, so
    # adding `select(.isOutdated != true)` here is the most inviting one-token
    # edit in the file.** It is not a trim. Autofix rewrites the lines its own
    # threads anchor to, so after one run **every** thread is outdated: the
    # filter takes this count to zero permanently, on exactly the pull requests
    # the trigger exists for, and the loop loses autofix in silence (#108). The
    # full argument, and the decision that this count stays unfiltered at all
    # three of its consumers, is with the third invariant above.
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
    # My own nudges, by the timestamp I control. The two commands do not
    # collide: `@coderabbitai autofix` does not contain `@coderabbitai review`.
    #
    # The array is kept rather than reduced on the spot, because the retry wants
    # three things out of it and only one of them is the newest one. All three
    # come off a read the phase was making anyway.
    | [ $pr.comments.nodes[]?
        | select(((.author.login // "") | ascii_downcase) == ($me | ascii_downcase))
        | select((.body // "") | contains($nudge))
        | .createdAt ] as $nudges
    | ($nudges | max // "") as $nudgeAt
    # The origin of the retry window, and **the only head-scoped nudge fact
    # there is**: empty exactly when no command of mine stands at this head, which is
    # what the caller reads instead of spelling `nudgeAt > headDate` a second
    # time in bash. One predicate, in one language.
    #
    # Head-scoped because a push has to reset the clock: unscoped, a nudge
    # posted at the commit before this one would start the window in the past,
    # and the first refusal at fresh code would hand over on the spot.
    #
    # ISO-8601 with a `Z` sorts lexicographically the way it sorts
    # chronologically, so a string comparison does a clock job here.
    | ([ $nudges[] | select(. > ($head.committedDate // "")) ] | min // "") as $nudgeFirstAt
    # Whatever CodeRabbit said after it. Selected by the created timestamp
    # because a reply is a new comment rather than an edit of an old one — the
    # updated-timestamp binding is about the walkthrough, which CodeRabbit
    # rewrites in place.
    | ([ $pr.comments.nodes[]?
         | select(.author.login | is_coderabbit)
         | select($nudgeAt != "" and (.createdAt // "") > $nudgeAt) ]
       | max_by(.createdAt // "")) as $reply
    # The newest comment carrying a merge-risk block, whoever posted it — except
    # a handover the loop wrote, which is not a review artifact and which pastes
    # CodeRabbit words verbatim. Without that one exclusion a reply that happened
    # to quote the block would let the record the loop wrote answer the question
    # that record exists because nothing else could answer.
    #
    # This is a deliberate narrowing of *anywhere on the pull request*, and the
    # only one: what the loop wrote is not evidence about what CodeRabbit did.
    # Without it the phase could answer its own question, and a self-referential
    # marker is a trap this project has already been caught in once.
    #
    # ponytail: no fixture reaches the exclusion. Neither measured reply shape
    # carries a block, and inventing one would test the loop against a shape of
    # CodeRabbit nobody has seen.
    #
    # ponytail: the handover the loop wrote is the only exclusion, so a *human*
    # comment quoting a merge-risk block can now answer for CodeRabbit — and
    # since the third route reads the abbreviation out of that comment, a quote
    # naming another commit mints an `other-head` nudge and, one interval later,
    # a handover. That was already true of the presence test before the third
    # route existed; the route makes it visible rather than introducing it. It
    # fails in the safe direction — a quote can only stop a merge, never cause
    # one — and narrowing this read to comments CodeRabbit itself posted while
    # the presence test stays broad would put the two halves of one fact at
    # different scopes. Narrow both, together, if a real pull request ever hits
    # it.
    | ([ $pr.comments.nodes[]?
         | select((.body // "") | contains($escprefix) | not)
         | select((.body // "") | contains($riskstart)) ]
       | max_by(.updatedAt // "")) as $blockComment
    # Every record standing at this head, and then the one of them the loop may
    # write over. The `contains` stops at the head rather than running on to the
    # suffix, which is what keeps a marker posted before the kind existed
    # matching.
    | [ $pr.comments.nodes[]?
        | select(($head.oid // "") != "")
        | select((.body // "") | contains($escprefix + $head.oid)) ] as $records
    | (($records | length) > 0) as $escalated
    | ([ $records[]
         | select(((.author.login // "") | ascii_downcase) == ($me | ascii_downcase)) ]
       | max_by(.createdAt // "")) as $record
    # The kind, read off that same comment.
    | ($record.body | marker_kind($escprefix + $head.oid; $escsuffix)) as $escKind
    # Every withdrawal notice at this head, read the same way over a prefix that
    # cannot collide with it, and over the comment bodies this response already
    # carries — **no new read**. Sorted and de-duplicated, so the value is stable
    # across passes whatever order the comments arrive in.
    | ([ $pr.comments.nodes[]?
         | select(($head.oid // "") != "")
         | select((.body // "") | contains($wdnprefix + $head.oid))
         | (.body | marker_kind($wdnprefix + $head.oid; $wdnsuffix))
         | select(. != "") ]
       | unique | join(" ")) as $wdnKinds
    | [ ($head.oid // ""),
        ($head.committedDate // ""),
        (($head.author.user.login | is_coderabbit) | tostring),
        ((($newest.terminal) // false) | tostring),
        ($threads | length | tostring),
        ($status.updatedAt // ""),
        ($statusTrigger.head // ""),
        ($triggers | map(.createdAt) | max // ""),
        ($escalated | tostring),
        $escKind,
        (($record.databaseId // "") | tostring),
        $wdnKinds,
        ((($signals | length) > 0) | tostring),
        ([ $signals[] | select(.terminal | not) | .at | select(. != null) ] | min // ""),
        (($newest.desc // "") | flat),
        ($newest.at // ""),
        (if $blockComment then "present" else "absent" end),
        (((($blockComment.body // "") | risk_block).abbrev // "") | ascii_downcase),
        $nudgeAt,
        $nudgeFirstAt,
        ($nudges | length | tostring),
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
# The seam's stdout — GitHub's answer, verbatim — is kept in `$FAILURE_TEXT` on
# a failure, which is what the state line's `class=` is read from. Its stderr is
# the seam's own prose for a human, and is dropped.
post_autofix_trigger() {
  writeback_write autofix --repo "$1" --pr "$2" --sha "$3"
}

# The review nudge. Unlike the autofix trigger it records no head: *once per
# head* is decided here by the nudge being newer than the head commit, not by a
# marker in its body, so there is nothing for the seam to carry. That also keeps
# the comment a bare command, which is what a nudge the operator might type by
# hand looks like.
#
# Its failure text is kept the way the trigger's is.
post_review_nudge() {
  writeback_write review --repo "$1" --pr "$2"
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
# judged nothing at all. There are two of those, and both are rows the reader
# needs beside a judgement rather than as one. CodeRabbit's reply to a nudge is
# pasted verbatim because **nothing keys on its content**, and giving it `ok` would claim
# a judgement was made about prose the loop is specifically forbidden to parse.
# The gate clock's row carries the age and the bound and nothing else: the clock
# is not a veto, so any verdict on that row would be a judgement the combination
# does not read and the operator would have to reconcile against the rows that
# actually deferred.
#
# **The fourth field is the permanence mark, and it is not rendered.** It names
# the value whose cause set is fully sourced and cannot be retracted by elapsed
# time alone — *the gate owns judgement; the clock owns duration.* It rides on
# the row rather than in a variable beside it so that a veto which grows a new
# marked defer arm is picked up by the combination without that line being
# re-enumerated, exactly as `deferred` is stated over the whole set. What the
# operator sees of it is the clock's own row and the tail's `permanent=` token.
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
  local mark="${4-}"
  mark="${mark//$'\t'/ }"
  printf '%s\t%s\t%s\t%s' "${verdict//$'\n'/ }" "${what//$'\n'/ }" \
    "${raw//$'\n'/ }" "${mark//$'\n'/ }"
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

# The rows, rendered. Spelled once because two records now write it — the
# handover's and the refusal's — and a copy per record is how the two end up
# disagreeing about how a raw value is escaped.
#
# The fourth field is `reason`'s permanence mark, read so that it cannot leak
# into the raw column and rendered nowhere: what it changes is the merge clock's
# own row and the log line's tail.
reason_table() {
  local r verdict what raw mark
  printf '| Verdict | What | Raw values |\n|---|---|---|\n'
  for r in "$@"; do
    IFS=$'\t' read -r verdict what raw mark <<< "$r"
    printf '| %s | %s | `%s` |\n' "$(md_cell "$verdict")" "$(md_cell "$what")" "$(md_cell "$raw")"
  done
}

# The record itself. Everything head-scoped the loop knows lives here, because
# with no local state a comment on the pull request is the only place a
# head-scoped record can live at all.
#
# The kind is the first line because it is what tells the operator what to do
# next — whether to read the diff, go and look at CodeRabbit, or go and look at
# the rubric. All five have callers, and two of them have more than one:
# `stalled` from the autofix clock and from the nudge clock, `stuck` from the
# risk gate and from the review clock, `escalate` from the gate's vetoes,
# `declined` from the review-retry clock, and `refused` from the merge.
escalation_body() {
  local kind="$1" head="$2" read_at="$3" meaning
  shift 3

  case "$kind" in
    escalate) meaning="a veto is present and says no" ;;
    # Restated: the older line — *past the merge-gate timeout* — is false for the
    # population that reaches `stuck` with the clock unspent, on a deferring
    # cause marked permanent. This sentence is true for both, and is the better
    # one for the old population too, the timeout having only ever been a proxy
    # for it.
    stuck)    meaning="signals are undecided and waiting will not decide them" ;;
    stalled)  meaning="a CodeRabbit command was triggered and CodeRabbit never reported inside its bound" ;;
    # The third of the three things CodeRabbit can do with a command, and the
    # only one that used to have no kind: `stalled` is *never reported*, `stuck`
    # is *reported and still thinking*, and this is *reported, and the answer was
    # no* — with any silence after the refusal inheriting it (#143), which is
    # why the gloss no longer claims CodeRabbit answered every command. Giving
    # it `stalled` would make `stalled`'s own gloss false of it, and `refused`
    # is the merge's.
    declined) meaning="CodeRabbit refused at this head and never ran a review inside the retry window" ;;
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

  # **"while this record stands", not "until the head moves"** — the sentence
  # that had to change, because the old one promised the operator a duration the
  # loop no longer honours and never should have: it went on holding the pull
  # request long after its own reasons had evaporated. The promise now names the
  # record, and the record is re-derived every pass.
  printf 'The loop is holding this pull request at `%s` — no merge, no autofix trigger, no nudge — while this record stands. It re-reads every pass and **withdraws this record on its own** if the picture changes.\n\n' "$head"

  # **Once, above the table**, so that every row below reads as an observation
  # made at one instant rather than as a standing claim. A per-row timestamp
  # would say the opposite of what this record now means.
  printf 'Read at %s.\n\n' "$read_at"

  reason_table "$@"

  # The legend, and it earns its line by keeping a `defer` row beside a `no` row
  # from being read as a second finding: one of them blocked the merge and the
  # other had not been computed when the table was written, and nothing in the
  # word itself says which.
  printf '\n`ok` passed · `no` blocked the merge · `defer` not yet computed when this was read · `note` judged nothing at all.\n'

  # The three gestures that already exist, which is what makes this a handover
  # rather than a notice. There is deliberately no fourth: an override label
  # would be an unscoped bypass token for the only gate left standing. **None of
  # them is required any more** — the loop can now clear this itself — and the
  # line says so, because an operator who thinks a push is the only exit will
  # push one they did not need.
  printf '\n**Ways back in** — none of them required; the loop may clear this itself.\n\n'
  printf -- '- **Merge it by hand.** Close-out still ticks and closes the issue this branch names: it reads merged pull requests from GitHub and cannot tell whose hand pressed the button.\n'
  printf -- '- **Push a commit.** The head moves, this record stops matching it, and the loop re-derives from scratch on the next pass.\n'
  printf -- '- **Convert it to draft.** Draft is the hold gesture, and the loop stops seeing this pull request at all.\n\n'
  printf 'There is no override label. A push is both the fix and the re-engagement.\n\n'

  printf '%s%s %s%s\n' "$ESCALATION_MARKER_PREFIX" "$head" "$kind" "$ESCALATION_MARKER_SUFFIX"
}

# The withdrawal. It replaces the record wholesale, and **removing the marker is
# the retraction** — there is nothing else to take down, because the marker is
# the whole of what the derivation reads.
#
# A counter-comment was rejected: it churns two comments per base move,
# unbounded, and pushes the record out of the hundred-comment window the
# derivation reads at twice the rate — *the mechanism that flaps is the
# mechanism that blinds the derivation to its own record.* The stated cost of
# editing, losing the trail, is false: GitHub keeps native comment edit history,
# so the platform renders the diff and the loop never stores or parses an old
# verdict.
#
# **It carries no live gate rows.** A notice saying the gate now defers on some
# veto would be a record written against a moving signal — the exact defect this
# path exists to correct — so it states only what is permanently true: a record
# stood here, it does not any more, and the previous version holds what was
# seen.
#
# **The marker at the foot is the one thing that is not prose, and it is not a
# row.** It names the head and the kind of the record that came down, which is a
# fact about a write the loop has already made and is permanently true of that
# commit — so the ban above, which is on a live verdict, is not the one it
# crosses. It renders invisibly and it is the only head-keyed thing that
# survives the retraction: without it the merge spend a `refused` record carried
# comes down with the record, and the head oscillates.
#
# The kind is an argument rather than a read. Every caller of the retraction
# already holds it, and the retraction itself stays kind-blind — it fires on
# every kind, unconditionally, and only what it *writes* names one.
retraction_body() {
  printf '**Withdrawn.** A handover stood on this pull request at `%s`; the loop re-derived, the picture had changed, and it took the record down. The previous version of this comment holds what the gate saw.\n\n' "$1"
  printf 'The loop is deriving this pull request normally again.\n'
  printf '\n%s%s %s%s\n' "$WITHDRAWN_MARKER_PREFIX" "$1" "$2" "$WITHDRAWN_MARKER_SUFFIX"
}

# The flag, on its own, in both directions. Reachable alone because that is what
# the chase is: a pass that finds the label disagreeing with the marker fixes
# the label and says nothing else.
add_escalation_label() {
  "$SCRIPT_DIR/pr-writeback.sh" label --repo "$1" --pr "$2" \
    --add "$LABEL_ESCALATED" >/dev/null 2>&1
}

remove_escalation_label() {
  "$SCRIPT_DIR/pr-writeback.sh" label --repo "$1" --pr "$2" \
    --remove "$LABEL_ESCALATED" >/dev/null 2>&1
}

# One comment rewritten. The caller has already established that this comment is
# one the loop itself wrote — that is the whole of the wrong-comment guard, and
# it lives at the derivation because that is where the authorship is known.
#
# A failure leaves the seam's stdout — GitHub's refusal, verbatim — in
# `$FAILURE_TEXT` for the retraction's classification.
edit_comment() {
  writeback_write edit --repo "$1" --comment "$2" --body-file "$3"
}

# The flag chasing the marker, in whichever direction it has to go. <want> is
# `on` or `off`; <labelled> is what the enumeration already saw, so the chase
# costs a write only when the two disagree.
#
# The label is **delivery**, not action: it is retried until it lands and it
# never consumes the pass's one action, so a chase runs alongside whatever else
# the pass did.
#
# Sets CHASE_KV rather than printing it, for the same reason consume_record
# does: the skip accounting has to survive, and a command substitution would
# take every increment down with the subshell.
CHASE_KV=""
chase_label() {
  local github="$1" number="$2" want="$3" labelled="$4" status=0
  CHASE_KV=""
  if [[ "$want" == "on" ]]; then
    if [[ "$labelled" == "labelled" ]]; then
      CHASE_KV="label=present"
      return 0
    fi
    add_escalation_label "$github" "$number" || status=$?
    if (( status == 0 )); then CHASE_KV="label=added"; fi
  else
    [[ "$labelled" == "labelled" ]] || return 0
    remove_escalation_label "$github" "$number" || status=$?
    if (( status == 0 )); then CHASE_KV="label=removed"; fi
  fi
  if (( status != 0 )); then CHASE_KV="label=failed rc=$status"; fi
  return "$status"
}

# The handover, in its fixed order: **comment, then label.**
#
# That order is not a preference either. It self-heals: a pass that finds the
# comment posted and the label missing adds the label without re-posting
# anything, whereas label-then-comment would leave a flagged pull request whose
# record never landed and post the record again on every pass after.
#
# The label is added unconditionally on this path, even when the enumeration
# already saw it there. Making the second write conditional on a fact from the
# *other* read would trade one idempotent write for an invariant that no longer
# holds by inspection: as written, an escalation that returns 0 has always ended
# with the label on. The chase is the conditional one, and it is reached only
# when no record was written this pass — so the two cannot both fire and the
# invariant survives the label becoming removable.
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

# Put the record up: a comment carrying the verdict table, then the label. Runs
# in two phases for the reason above. Returns 0 if both succeed, 1 if the record
# fails, 2 if the record lands and the label fails. Sets ESCALATE_RC to the exit
# code of whichever write failed.
#
# <comment> is the loop-authored record already standing at this head, empty
# when there is none. **Empty posts; non-empty replaces that comment
# wholesale.** The second is the kind change — one claim about this commit
# giving way to another — and it is one write rather than a retraction followed
# by a post on the next pass, because taking a record down and putting a
# different one up in its place is one decision, and spending two passes on it
# would leave the pull request carrying no record in between.
#
# The handover write is the one write here that is **deliberately not metered
# per head.** It has to stay re-postable at the same commit or a retraction
# could never re-escalate, and the record's own presence is what suppresses the
# duplicate the meter would otherwise be for.
ESCALATE_RC=0
escalate() {
  local github="$1" number="$2" head="$3" kind="$4" read_at="$5" comment="$6"
  shift 6
  local body status=0
  ESCALATE_RC=0

  # Free text travels to the seam as a file: gh-axi would reinterpret a --body
  # that happened to look like JSON, and this body is a markdown table.
  body=$(mktemp "${TMPDIR:-/tmp}/agent-loop-escalation.XXXXXX") || { ESCALATE_RC=1; return 1; }
  if ! escalation_body "$kind" "$head" "$read_at" "$@" > "$body"; then
    rm -f "$body"
    ESCALATE_RC=1
    return 1
  fi

  if [[ -n "$comment" ]]; then
    edit_comment "$github" "$comment" "$body" || status=$?
  else
    "$SCRIPT_DIR/pr-writeback.sh" comment --repo "$github" --pr "$number" \
      --body-file "$body" >/dev/null 2>&1 || status=$?
  fi
  rm -f "$body"
  if (( status != 0 )); then ESCALATE_RC=$status; return 1; fi

  status=0
  add_escalation_label "$github" "$number" || status=$?
  if (( status != 0 )); then ESCALATE_RC=$status; return 2; fi
  return 0
}

# Take the record down. The withdrawal notice replaces the body wholesale and
# the record's marker goes with it, which is the whole of the retraction — the
# label is the caller's next move, in that order and never the other one.
#
# What replaces it is the withdrawal's own marker, which is a different prefix
# and cannot read as a standing record. <kind> is the kind that came down, and
# the caller holds it already: it is the kind the derivation read off the record
# this call is about to overwrite.
#
# **Comment then label, here as well as on the way up.** Dying between the two
# writes in the other order would leave a standing marker with no label, the
# chase would put the label back, and the retraction would have undone itself.
retract() {
  local github="$1" head="$2" comment="$3" kind="$4" body status=0
  # Cleared, so a body file that could not be made reads as empty text rather
  # than as whatever an earlier write left behind.
  FAILURE_TEXT=""
  body=$(mktemp "${TMPDIR:-/tmp}/agent-loop-retraction.XXXXXX") || return 1
  if ! retraction_body "$head" "$kind" > "$body"; then
    rm -f "$body"
    return 1
  fi
  edit_comment "$github" "$comment" "$body" || status=$?
  rm -f "$body"
  return "$status"
}

# The handover the chain derived, held until the tail. The chain no longer
# writes the record itself: whether what it derived becomes a new record, a
# wholesale replacement of one, or nothing at all depends on what is already
# standing at this head, and that is the tail's business rather than the
# deriving branch's.
HANDOVER_KIND=""
HANDOVER_REASONS=()
want_handover() {
  HANDOVER_KIND="$1"
  shift
  HANDOVER_REASONS=("$@")
}

# The tail. The chain has derived its state; this decides what becomes of the
# record that was standing when the pass began, and it is the only place in the
# phase that writes one.
#
#   handover=posted     a record went up, or replaced one of another kind
#   handover=held       the same kind is still true, so nothing was written
#   handover=retracted  the picture changed and the record came down
#   handover=foreign    a record stands that the loop did not write
#
# Sets HANDOVER_KV rather than printing it: the skip accounting has to survive,
# and a command substitution would take every increment down with the subshell.
HANDOVER_KV=""
consume_record() {
  local github="$1" number="$2" head="$3" read_at="$4" labelled="$5" \
        stands="$6" kind="$7" comment="$8"
  local status=0
  HANDOVER_KV=""

  # **A record the loop did not write is one it cannot un-write.** It does the
  # label chase and nothing else — no edit, no second record — and says so on
  # the line, because the cost is real and is accepted: this pull request holds
  # at this head until the operator moves it, with all three manual exits
  # working. A bot rewriting a human's comment is the worse failure.
  if [[ "$stands" == "true" && -z "$comment" ]]; then
    HANDOVER_KV="handover=foreign"
    chase_label "$github" "$number" on "$labelled" || SKIPS=$((SKIPS + 1))
    HANDOVER_KV="$HANDOVER_KV${CHASE_KV:+ $CHASE_KV}"
    return 0
  fi

  if [[ -n "$HANDOVER_KIND" ]]; then
    # **The same kind, still true.** The one outcome that writes nothing at all:
    # re-posting it would churn the record for no new information, and the
    # operator's own reading of it is still current. The label still self-heals,
    # because delivery is retried until it lands.
    if [[ "$stands" == "true" && "$kind" == "$HANDOVER_KIND" ]]; then
      HANDOVER_KV="handover=held"
      chase_label "$github" "$number" on "$labelled" || SKIPS=$((SKIPS + 1))
      HANDOVER_KV="$HANDOVER_KV${CHASE_KV:+ $CHASE_KV}"
      return 0
    fi
    escalate "$github" "$number" "$head" "$HANDOVER_KIND" "$read_at" "$comment" \
      "${HANDOVER_REASONS[@]+"${HANDOVER_REASONS[@]}"}" || status=$?
    HANDOVER_KV="$(escalation_kv "$HANDOVER_KIND" "$status")"
    # The disposition is only claimed once the record is actually on the pull
    # request. A comment that never landed changed nothing, and the line already
    # says so in its own words.
    if (( status == 0 || status == 2 )); then
      HANDOVER_KV="$HANDOVER_KV handover=posted"
    fi
    (( status == 0 )) || SKIPS=$((SKIPS + 1))
    return 0
  fi

  # Nothing to record. Either a record stands whose claim the pass has just
  # disproved, or there is no record and the flag may be left over from one.
  if [[ "$stands" != "true" ]]; then
    # **Except a flag a refused write raised this pass.** That flag has no
    # handover record behind it by design — its record is the refused write's
    # own — so chasing it off here would undo the escalation on the pass it
    # went up and flap it every pass after. On the pass the write lands this
    # guard is down and the chase withdraws it, which is the live flag working.
    if write_escalated "$github" "$number"; then
      return 0
    fi
    chase_label "$github" "$number" off "$labelled" || SKIPS=$((SKIPS + 1))
    HANDOVER_KV="$CHASE_KV"
    return 0
  fi

  retract "$github" "$head" "$comment" "$kind" || status=$?
  if (( status != 0 )); then
    # The record still stands and the flag is still on it, which is the right
    # pair to fail into: the next pass re-derives, finds the same record false,
    # and retracts again. Nothing was said that has to be unsaid.
    #
    # Unless GitHub refused the edit, when *retracts again* is forever and the
    # pull request holds behind a record the loop knows is false. Then it gets
    # the refused write's record too; the flag it needs is already on.
    local class
    class=$(gh_error_class "$FAILURE_TEXT")
    HANDOVER_KV="handover=retract-failed rc=$status class=$class"
    write_failed "$class" pr "$github" "$number" retract ""
    SKIPS=$((SKIPS + 1))
    return 0
  fi
  HANDOVER_KV="handover=retracted"
  chase_label "$github" "$number" off "$labelled" || SKIPS=$((SKIPS + 1))
  HANDOVER_KV="$HANDOVER_KV${CHASE_KV:+ $CHASE_KV}"
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
# **One signal, one veto, and terminality.** Two rules govern what a veto may
# say, and every veto below is written to them:
#
#   - For every underlying *fact* about a pull request, exactly one veto owns it,
#     and only the owner may let that fact move its verdict. A veto reading a
#     value whose causes include a fact it does not own must return a verdict
#     carrying no information about that fact.
#   - A veto may say `no` only on a cause that is **operator-retractable** and
#     **not produced by the loop's own writes**. Self-retracting causes rot —
#     the record is false before anyone reads it — and loop-produced causes are
#     the loop's to clear, not the operator's. Unknown classifies as
#     self-retracting and defers. The second half of that is the rule **the loop
#     does not act on its own output**, stated here at its first of two sites;
#     the other is autofix refusing to spend at a head the loop minted.
#
# `ok`, `defer` and `merge` cannot go stale, because the gate derives and acts on
# the same pass. Only `escalate` is written down, so **a recorded `no` is the
# only gate output that can rot**, and the second rule is about that one output.
#
# `defer` is the third outcome and it is not a failure. A signal that is simply
# **not computed yet** — a check still running, a conflict axis GitHub has not
# finished calculating — is re-derived next pass in silence, because an unknown
# mergeability state is routine and has no documented retry contract to follow.
# What stops that being forever is the clock, V5. And *silent* means only
# GitHub-visible: `GATE_KV` is on the per-pass log line for every verdict, so a
# `defer` is fully diagnosable without a round-trip.
#
# **All four vetoes evaluate — no short-circuit.** One message carries every
# reason, the passes as well as the failures: an operator reading a handover
# needs to know where *not* to look as much as where to. A veto beats the clock,
# and that costs nothing now that a `no` is only ever a cause an operator can
# retract: the failing check that reaches here is the most actionable veto in the
# gate, and delaying it behind a clock would buy no information.
#
# **The ownership map**, which the classification below is derived from.
# Ownership goes to the veto that reads the fact **most directly** — the input
# that discriminates most about it:
#
#   fact                                             owner
#   ---------------------------------------------------------------------------
#   CodeRabbit's merge-risk judgement                V1
#   the state of every check on the head             V2
#   whether head and base tip conflict               V3
#   whether base has moved past the merge base       V3
#   what the change touches                          V4
#   elapsed time                                     the clock, not a veto
#   draft                                            the scope filter
#   the walkthrough's commit abbreviation            loop-produced — no owner
#   the repository's non-check merge rules, and
#     the *existence* of required contexts           deliberately unowned
#
# **Checking a fifth veto against those two rules** — the procedure, so the
# property survives the next person to add one. Step 4's *three rules* are the
# classification's three rows, which are how the two rules above are applied to
# a value; the *four* are what rule 2 requires all of:
#
#   1  Name the fact it exists to judge, positively, as a function of inputs.
#   2  Claim it. If another veto owns it, resolve by directness; the loser
#      applies rule 1 of the classification and returns `ok`.
#   3  For every value of every field it reads, write the cause set — the set of
#      repository conditions, not the value's gloss.
#   4  Apply the three rules. A `no` needs all four of: cause set fully known,
#      wholly owned, operator-retractable, not loop-produced.
#   5  Any cause set not establishable from a primary source is `defer`.
#
# **A veto whose `no` arm is an `else` has not done step 3.** V3's is gone. V1's
# and V4's are still there, and auditing them against this procedure would be
# well-founded work.
#
# **Two facts stay unestablished and are shipped that way on purpose.** The full
# cause set behind `mergeStateStatus = BLOCKED` — which is why it defers and why
# it cannot be marked permanent — and whether `statusCheckRollup.contexts`
# carries an entry for a required context that has never reported. Every
# classification here is deliberately robust to both.

# Everything the gate runs on, one value per line, in the order the reader below
# takes them. Same protocol as pr_facts and for the same reason: several of
# these are routinely empty, and `read` folding a run of tabs would silently
# shift one field into another's slot.
#
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
# Reading every context is strictly stricter than reading the required ones, and
# it holds however a given repository happens to be configured.
#
# The justification this used to carry — *required-ness is structurally always
# false once repository protection is out of scope* — was simply false, and is
# named here rather than quietly deleted. The specimen repository has an active
# ruleset; *out of scope* means the loop does not **provision** protection, not
# that no repository has any. V2's behaviour is unaffected and better founded
# without it.
#
# **Pre-merge checks are not read either.** They are computed from the same
# review as the merge-risk verdict, they measure hygiene rather than merge risk,
# and the verdict subsumes them — so this parses no part of that block.
gate_facts() {
  jq -r \
    --arg crlogin "$CODERABBIT_LOGIN" \
    --arg walkthrough "$WALKTHROUGH_MARKER" \
    --arg riskstart "$RISK_BLOCK_MARKER" \
    --arg workflows "$CI_WORKFLOW_DIR" \
    --arg scripts "$UNATTENDED_SCRIPTS" "$RISK_BLOCK_PARSE"'
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
    # The same parse the chain runs, by definition rather than by copy: the two
    # read the block at different scopes on purpose, and the one thing they must
    # never disagree about is which commit a verdict names.
    | ($body | risk_block) as $risk
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
    | [ (if $risk then ($risk.level | ascii_downcase | gsub("[^a-z]"; "")) else "" end),
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
  local level="" abbrev="" block="" mergeable="" mergestate=""
  local green=0 pending=0 failed=0 total=0 pendingnames="" failednames=""
  local filecount=0 truncated=false guarded=""
  local v1 v2 v3 v3conflict v3state v4 age clock="" deferred=false expired=false
  local marked="" r rverdict rwhat rraw rmark

  GATE_VERDICT=defer
  GATE_KIND=""
  GATE_KV=""
  GATE_REASONS=()

  # Either all fourteen values arrive or the gate does not judge at all.
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

  # **The gate does not ask whether CodeRabbit is throttled** (#120). A test
  # stood here that deferred on the walkthrough's rate-limit marker, ahead of
  # every veto and outside the gate clock, and it is gone, so nobody re-derives
  # it from the argument that defended it: *a throttled pull request keeps a
  # stale verdict, which V1 would read as CodeRabbit changing shape and hand over
  # permanently.*
  #
  # - **Its own fixture contradicted it.** The suite's case asserted, in the same
  #   breath, that the throttled verdict named this head and carried High — a
  #   current, head-scoped verdict. The defer's only effect was to suppress a
  #   correct escalation.
  # - **"Stale" was the chain's population, not the gate's.** The chain's reader
  #   routes a block naming another commit to `needs-review`, nudged and bounded
  #   into `declined` before this is called (Aug 22 → Sep 1: `route=other-head`
  #   38 times, `route=no-block` 330). What can still arrive is the two readers
  #   agreeing — V1 then judges the level the head was actually reviewed at — or
  #   disagreeing, where V1 escalates **with or without the marker**, because
  #   the disagreement drives it. The test resolved neither; it silenced both.
  # - **"Permanent" stopped being true when handovers became retractable.** The
  #   worst it could have prevented was one retraction and one re-escalation.
  # - **And the wait was the chain's deadlock one scope up:** the marker lives
  #   in a slot only a review rewrites, and the gate is downstream of the only
  #   thing that asks for one.
  #
  # `gate=rate-limited` never appeared in the log over the same window — 4958
  # lines, 33 gate verdicts. That sample is small and carries none of this; the
  # reachability argument does, and the count is only consistent with it.
  #
  # Throttling is a fact about the reviewer; the gate's business is the verdict,
  # and a verdict already written and scoped to this commit is not made wrong by
  # its author being busy. The chain's head-scoped status read is the loop's one
  # throttle surface, and it reads both deliveries. What this costs, deliberately:
  # the gate can merge while CodeRabbit is throttled.

  # V1 — CodeRabbit's verdict. The abbreviation must be a **prefix of the head**,
  # which is what scopes the verdict to the code being merged, and the level
  # one of the allowlisted few. Anything else escalates: an unrecognised level, an
  # unparseable line, a block that is not there. There is no documented ladder of
  # levels to order, so this is the tripwire for CodeRabbit changing shape.
  #
  # **Two of the four ways to fail here are unreachable by construction, and
  # both are kept.** *No merge-risk block anywhere on the pull request* and *a
  # block naming some other commit* are two of the three routes into
  # `needs-review`, which is nudged and bounded before the gate is ever reached
  # — so what actually arrives here is a terminal review **and** a block naming
  # this head, and only the level and the parse can still say no.
  #
  # They are kept because the two readers work at different scopes: the
  # predicate upstream reads the block across every comment where this reads it
  # out of CodeRabbit's newest walkthrough, and the safe direction for that
  # asymmetry is for the stricter reader to escalate rather than to fall
  # through. The parse itself is shared, so the one thing they cannot disagree
  # about is which commit a verdict names.
  if [[ "$block" == "parsed" && -n "$level" && " $RISK_LEVELS_CLEAR " == *" $level "* \
        && -n "$abbrev" && "$head" == "$abbrev"* ]]; then
    v1=ok
    GATE_REASONS+=("$(reason ok "CodeRabbit puts merge risk at $level for this commit" \
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

  # V3 — conflicts and base drift, and **nothing else**. One signal, one veto:
  # for every underlying fact about a pull request exactly one veto owns it, and
  # a veto reading a value whose causes include a fact it does not own must
  # return a verdict carrying no information about that fact. V3 owns the facts
  # that are functions of `(head, base tip)` alone — whether head and base tip
  # conflict, and whether base has moved past the merge base — and it is silent
  # about checks in either direction.
  #
  # That second clause is the one today's specimen lacked. `mergeStateStatus`
  # reports *a required check has not reported yet* as `BLOCKED`; reading that as
  # a permanent veto handed over a pull request whose check went green
  # twenty-nine seconds later, while V2 was simultaneously and correctly
  # deferring on the same underlying fact through a different field.
  #
  # The classification, for a veto `X` and a value `v`, over the set `cause(v)`
  # of repository conditions that can produce it:
  #
  #   1  every fact in it is owned by another veto            → `ok`
  #   2  fully known, wholly X's, operator-retractable, and
  #      not produced by the loop's own writes                → `no`
  #   3  otherwise — mixed, unknown, unowned, self-retracting → `defer`
  #
  # Rule 1 returns `ok` rather than `defer` because a veto that deferred on
  # another veto's fact would suppress the owner's own `no`. Rule 3 is what makes
  # this safe under the rows GitHub does not document: `defer` is closed under
  # union of causes where `no` and `ok` are not, so the `else` arm on both axes
  # defers. **There is no ordering logic anywhere** — precedence between
  # simultaneous merge-state values is undocumented, and classifying by cause set
  # never needs it.
  #
  # **Two rows, one veto.** The axes are reported separately so that a `no` never
  # appears in the handover beside a raw value reading `mergeable`, and V3's
  # outcome is the strictest of the two. "Strictest wins" over a total order is
  # associative, which is what makes the split free — and what would make a fifth
  # veto verdict-neutral.
  #
  # **A branch that is behind is never updated.** That write would move the head,
  # void the verdict just validated, and spend metered review budget re-reviewing
  # what was already reviewed. It escalates instead.
  # The conflict axis. Both named values are fully known and wholly V3's, so
  # this axis may speak decisively in either direction — and `CONFLICTING`
  # satisfies rule 2 in full, because a conflict retracts only when somebody
  # pushes.
  case "$mergeable" in
    MERGEABLE)
      v3conflict=ok
      GATE_REASONS+=("$(reason ok "GitHub reports no conflict between this head and its base" \
        "mergeable=$mergeable")") ;;
    CONFLICTING)
      v3conflict=no
      GATE_REASONS+=("$(reason no "this pull request conflicts with its base" \
        "mergeable=$mergeable")") ;;
    # Rule 3 — `UNKNOWN` is GitHub still calculating, and empty or unrecognised
    # is a cause set that cannot be established at all. Reading either as "no
    # conflicts detected" is how a gate merges a conflicted pull request.
    *)
      v3conflict=defer
      GATE_REASONS+=("$(reason defer "GitHub has not settled whether this pull request conflicts" \
        "mergeable=${mergeable:-none}")") ;;
  esac

  # The merge-state axis. GitHub folds a dozen unrelated repository conditions
  # into one enum here, and exactly one of them is V3's.
  case "$mergestate" in
    # Rule 2 — base drift, the other half of what V3 owns. It is fully known,
    # wholly V3's, and clears only because somebody acts.
    BEHIND)
      v3state=no
      GATE_REASONS+=("$(reason no "the base has moved on past this pull request's merge base" \
        "state=$mergestate")") ;;
    # Rule 1. `CLEAN` is check-derived by definition, so requiring it here would
    # re-import V2's fact; `DIRTY` is the conflict fact, which the axis above
    # owns and reads far more directly; `UNSTABLE` is the check fact, which V2
    # owns — its rollup names the context and separates pending from failed,
    # where `UNSTABLE` names nothing.
    CLEAN|DIRTY|UNSTABLE)
      v3state=ok
      GATE_REASONS+=("$(reason ok "GitHub's merge state raises nothing this veto owns" \
        "state=$mergestate")") ;;
    # Rule 3, **marked permanent**. `DRAFT` is the scope filter's fact — the
    # enumeration drops drafts, so only a pull request drafted between that read
    # and this one arrives here — and `HAS_HOOKS` is a repository condition no
    # veto owns. Neither is V3's to judge, so both defer; but both pass the
    # two-clause permanence test, so the mark rides on the row and the routing
    # outside the gate reads it.
    #
    #   1  the cause set is fully established from a primary source
    #   2  no member of it can be retracted by elapsed time alone — every member
    #      is a standing property of the repository or the pull request, not an
    #      in-flight computation and not an unreported signal
    #
    # Clause 2 is stated against what the clock can buy, which is the only lever
    # in question: an admin removing a pre-receive hook retracts `HAS_HOOKS`,
    # and waiting does not. Clause 1 is what stops the class growing through
    # `BLOCKED` or the `else` arm below — both are unestablished cause sets, so
    # both fail it permanently until somebody sources them, and unmarked stays
    # closed under union of causes exactly as `defer` is.
    #
    # **The mark is a lookup in this table, not a runtime judgement.** No veto
    # inspects duration, and the verdict stays `defer`: `no` was rejected because
    # it fails the classification's ownership clause, and a fourth verdict bin
    # was rejected because it has no honest position in `no > defer > ok` and
    # would cost the associativity that makes splitting a veto free.
    #
    # ponytail: both members are unreachable in practice — `HAS_HOOKS` is
    # GitHub-Enterprise-only and `DRAFT` is filtered at the read. **The value is
    # the test, not the members.**
    DRAFT|HAS_HOOKS)
      v3state=defer
      GATE_REASONS+=("$(reason defer "GitHub's merge state is not one this veto can conclude from" \
        "state=$mergestate" "$mergestate")") ;;
    # Rule 3, ordinary — `BLOCKED` (mixed causes, one of which retracts itself),
    # `UNKNOWN`, and the `else`: empty, or a value GitHub adds tomorrow. The
    # `else` defers **one pull request** rather than escalating the queue, which
    # is what makes a schema change a bounded surprise.
    #
    # None of these can be marked, and clause 1 is why: `BLOCKED`'s cause set is
    # an undocumented union, `UNKNOWN` is GitHub still computing, and a value
    # nobody has seen has no cause set at all.
    #
    # ponytail: the accepted cost of this arm is a pull request GitHub blocks on
    # a required review, an unresolved conversation, a deployment, a signature or
    # a linear-history rule — checks green, merge refused, and no veto owning the
    # reason. It defers to the gate clock and arrives as `stuck` where it used to
    # be handed over on the first pass. Nothing here can tell those apart from a
    # check that has not reported yet, because `BLOCKED`'s cause set is not
    # documented; a fact that discriminates between them would let this arm split
    # and would settle the mark for it at the same time.
    *)
      v3state=defer
      GATE_REASONS+=("$(reason defer "GitHub's merge state is not one this veto can conclude from" \
        "state=${mergestate:-none}")") ;;
  esac

  # The strictest of the two axes is the veto's outcome.
  if [[ "$v3conflict" == "no" || "$v3state" == "no" ]]; then
    v3=no
  elif [[ "$v3conflict" == "defer" || "$v3state" == "defer" ]]; then
    v3=defer
  else
    v3=ok
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

  # **Any veto**, not `v2 || v3`. Stated over the whole set so that a defer arm
  # added to a veto that has none today cannot be missed here. It reads V3's
  # outcome rather than its two axes, which is the same test — the strictest
  # wins, so V3 defers exactly when an axis does — and it is the right one: a
  # veto that splits again must not have to be re-enumerated at this line.
  if [[ "$v1" == "defer" || "$v2" == "defer" || "$v3" == "defer" \
        || "$v4" == "defer" ]]; then deferred=true; fi

  # **The gate owns judgement; the clock owns duration.** The mark is read back
  # off the rows rather than tracked in a variable beside them, for the same
  # reason `deferred` is stated over the whole set: a veto that grows a marked
  # defer arm is picked up here without this line being re-enumerated, and a row
  # and its mark cannot come to disagree.
  #
  # Only a `defer` row can carry one. An `ok` or a `no` has already decided, and
  # a `note` judged nothing at all.
  for r in "${GATE_REASONS[@]+"${GATE_REASONS[@]}"}"; do
    IFS=$'\t' read -r rverdict rwhat rraw rmark <<< "$r"
    [[ "$rverdict" == "defer" && -n "$rmark" ]] || continue
    marked="${marked:+$marked,}$rmark"
  done

  # V5 — the clock, and it only exists because a `defer` is silent on GitHub. It
  # runs from the head commit's date, so no pull request can sit undecided
  # forever.
  #
  # **The clock is not a veto, and an expired defer is not a `no`.** Its row
  # judged nothing at all, so it carries `note` — the fourth token — and it is
  # the same row either side of the bound. A `no` here would itself break
  # terminality: what retracts *a signal has not arrived* is the signal arriving
  # on its own, which is not something an operator can do.
  #
  # For the same reason **the deferring rows are never reclassified at expiry**.
  # A handover that is still waiting says so, and still names what it is waiting
  # on; the kind on its first line is what carries the fact that the wait ran
  # long.
  #
  # Whether it has run out is decided **once**, here, and read as a boolean by
  # the combination below rather than through a row verdict: the row the handover
  # carries and the verdict the loop acts on must never be able to disagree about
  # what the clock said.
  age=$(( now - head_epoch ))
  if (( age > MERGE_GATE_TIMEOUT )); then expired=true; fi
  if $deferred; then
    clock=" age=$age bound=$MERGE_GATE_TIMEOUT${marked:+ permanent=$marked}"
    # Three branches, and the age and the bound are on all three. Keeping them on
    # the third is the point of it: an operator who gets a handover on the first
    # pass must be able to see that the timeout is not mis-set, or they will go
    # and change a number that had nothing to do with it.
    if [[ -n "$marked" ]]; then
      GATE_REASONS+=("$(reason note "the merge-gate clock does not apply — a deferring cause above is permanent" \
        "age=${age}s bound=${MERGE_GATE_TIMEOUT}s permanent=$marked head=$head_date")")
    elif $expired; then
      GATE_REASONS+=("$(reason note "the merge-gate clock has run out" \
        "age=${age}s bound=${MERGE_GATE_TIMEOUT}s head=$head_date")")
    else
      GATE_REASONS+=("$(reason note "the merge-gate clock has not run out yet" \
        "age=${age}s bound=${MERGE_GATE_TIMEOUT}s head=$head_date")")
    fi
  fi

  # **A veto beats the clock:** a pull request with both a veto and an undecided
  # signal is a handover about the veto, because that is the one the operator can
  # do something about. It costs nothing now that a `no` is only ever a cause an
  # operator can retract — the failing check that reaches here is the most
  # actionable veto in the gate, and delaying it behind a clock would buy no
  # information.
  if [[ "$v1" == "no" || "$v2" == "no" || "$v3" == "no" || "$v4" == "no" ]]; then
    GATE_VERDICT=escalate
    GATE_KIND=escalate
  elif $deferred; then
    # **Two sufficient conditions, and the mark is the second.** A deferring
    # cause whose cause set is fully sourced and cannot be retracted by elapsed
    # time alone escalates on the pass it is derived, rather than waiting out a
    # clock that will decide nothing. An operator should not wait an hour for
    # information the loop already had.
    #
    # A marked cause standing beside an unmarked one still escalates here, and
    # that is right: the marked one is not going to clear, so the wait would buy
    # only the unmarked one's answer, and the handover carries both rows.
    if $expired || [[ -n "$marked" ]]; then
      GATE_VERDICT=escalate
      # `stuck`, not `escalate`: nothing here said no, the signals are simply
      # undecided, and the kind is what tells the operator to go and look at the
      # checks rather than at the diff. **One kind, two populations** — signals
      # genuinely in flight, and pull requests GitHub will never merge for a
      # reason no veto owns. Splitting was rejected: `BLOCKED`'s cause set is
      # undocumented, so any second kind would rest on a proxy, and the
      # handover's table already discriminates — V2 `defer` reads as in flight,
      # V2 `ok` beside V3 `defer` reads as green but blocked.
      GATE_KIND=stuck
    else
      GATE_VERDICT=defer
    fi
  else
    GATE_VERDICT=merge
  fi

  # `mergeability`, not `mergeable`: this is V3's *outcome* — the strictest of
  # its two axes — and the raw `mergeable=MERGEABLE` GitHub answered with travels
  # in the handover's table, one axis per row. One name for two different things
  # is how a reader learns the wrong one.
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
    read_failed "$(gh_error_class "$numbers")" "$github" "pr query failed: $github"
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
#
# **The tail is strictly `key=value` with one deliberate exception, and the
# exception is always last.** `signal=` carries CodeRabbit's own description
# verbatim, which is the only value in the project that can contain a space.
# Positioned last, everything after `signal=` is the value and nothing can be
# shadowed by it; positioned anywhere else it would reshape the rest of the
# line. It is appended after the handover's own keys for that reason, and it is
# omitted entirely when nothing refused.
pr_phase_one() {
  local github="$1" number="$2" labelled="$3" method="$4"
  local response head head_date own_head terminal threads status_at status_head trigger_at escalated
  local esc_kind esc_comment wdn_kinds signal pending_at signal_desc signal_at block block_abbrev
  local nudge_at nudge_first_at nudge_count reply
  local now read_at head_epoch status_epoch trigger_epoch pending_epoch nudge_epoch
  local signal_epoch first_epoch status_answered status_stands answer_refused ask signal_kv declined_rows
  local spent in_flight age status needs_review route origin stalled_reason
  local state review kv merge_out merge_status stands withheld class

  if ! response=$(query_pr_state "$github" "$number"); then
    read_failed "$(gh_error_class "$response")" "$github" "pr state query failed: $github#$number"
    SKIPS=$((SKIPS + 1))
    return 0
  fi
  # One value per line, not one tab-separated line: eleven of the twenty-two are
  # routinely empty, and bash's `read` folds a run of tabs into a single
  # delimiter — so a pull request with no autofix status would silently have its
  # trigger read as its status, and every one of them would look spent.
  #
  # `|| true`, because a jq that answered nothing leaves `read` at end of input
  # and `set -e` would take the whole daemon down over one unreadable pull
  # request. The empty head below is what says so instead.
  head=""; head_date=""; own_head=false; terminal=""; threads=0; status_at=""; status_head=""
  trigger_at=""; escalated=false; esc_kind=""; esc_comment=""; wdn_kinds=""; signal=false
  pending_at=""; signal_desc=""; signal_at=""; block=""; block_abbrev=""
  nudge_at=""; nudge_first_at=""; nudge_count=0; reply=""
  HANDOVER_KIND=""; HANDOVER_REASONS=()
  # The one free-text value on the log line, held here so it can be appended
  # after everything else — see the `log` call at the bottom.
  signal_kv=""
  {
    read -r head
    read -r head_date
    read -r own_head
    read -r terminal
    read -r threads
    read -r status_at
    read -r status_head
    read -r trigger_at
    read -r escalated
    read -r esc_kind
    read -r esc_comment
    read -r wdn_kinds
    read -r signal
    read -r pending_at
    read -r signal_desc
    read -r signal_at
    read -r block
    read -r block_abbrev
    read -r nudge_at
    read -r nudge_first_at
    read -r nudge_count
    read -r reply
  } < <(pr_facts <<< "$response") || true

  # The head commit is the identity used by `spent`, and its date is the origin
  # for the in-flight clock. A pull request that will not yield either is not
  # guessed at: an unparseable date read as epoch zero would make every trigger
  # appear newer than the head.
  head_epoch=$(epoch_of "$head_date") || head_epoch=""
  if [[ -z "$head" || -z "$head_epoch" ]]; then
    # The read landed and would not parse, so GitHub said nothing to classify:
    # empty text, and transient by gh.sh's own rule.
    read_failed "$(gh_error_class "")" "$github" "pr state unreadable: $github#$number"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  now=$(date -u +%s)
  # The instant a record written this pass will say it was read at. A second
  # call to the same clock rather than a conversion of `now`: the two conversion
  # spellings differ by platform, `epoch_of` runs the trip the other way only,
  # and a record that could not name when it was read would still be worth
  # posting — so there is nothing here worth an error path.
  read_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Empty when the comment is not there and empty when its timestamp would not
  # parse, which are the same thing to everything below: a comparison that
  # cannot be made is not made.
  status_epoch=$(epoch_of "$status_at") || status_epoch=""
  trigger_epoch=$(epoch_of "$trigger_at") || trigger_epoch=""

  # **Autofix is spent on this head** for either of two sufficient reasons, and
  # the token carries which one: an operator asking why autofix did not fire
  # cannot answer it from a blind *spent*.
  #
  #   spent:trigger   the newest autofix-status comment is paired with a trigger
  #                   that records this head as its input. CodeRabbit's visible
  #                   `Commit:` is an output commit on success and `_none_` on
  #                   failure, so neither can identify the input; the loop
  #                   records that identity in its own trigger instead and never
  #                   parses CodeRabbit's result prose.
  #   spent:own-head  the head commit is CodeRabbit's own. **The loop does not
  #                   act on its own output** — the same rule terminality states
  #                   when it forbids a `no` resting on a loop-produced cause,
  #                   stated here at its second site. Whose commit it is comes
  #                   from the read, decided by the same `is_coderabbit` that
  #                   answers every other authorship question in this file: one
  #                   definition, not a second one spelled in bash.
  #
  # The second exists because the third route into `needs-review` arms a cycle
  # that used to be inert: the nudge runs a full review at an autofix head,
  # which can mint new threads on the autofix's own diff, which the loop would
  # autofix, minting another head — a fix chain that turns with no human in it.
  # The stop is structural rather than a cap on turns, because a cap needs a
  # number and concedes all but one turn of the churn it bounds.
  #
  # The cost is accepted and is the right backstop: new findings on an autofix
  # commit reach the gate unfixed, where the full review has moved the block
  # onto that head, so V1 judges the new review's level and a bad autofix
  # escalates rather than being silently re-fixed by the thing that produced it.
  #
  # The trigger reason is tested first because it is evidence about this head
  # specifically; the author test is a property of the commit and holds whether
  # or not anything was ever triggered at it.
  spent=unspent
  if [[ -n "$status_head" && "$status_head" == "$head" ]]; then
    spent=spent:trigger
  elif [[ "$own_head" == "true" ]]; then
    spent=spent:own-head
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

  # **`needs-review` — no merge-risk verdict covers this head, and the remedy is
  # a write.** Three clauses, any one enough, and the states below all test
  # *this* rather than restating it, so the chain cannot drift from the
  # definition:
  #
  #   no signal   CodeRabbit put neither a status nor a check run on the head
  #   no block    there is no merge-risk block anywhere on the pull request
  #   other head  the block parses, and the abbreviation it names is not a
  #               prefix of the head
  #
  # *Unreviewed* was accurate with two clauses and is false with three: under
  # the third CodeRabbit **did** review the head. *Stale block* was rejected as
  # a name for the same reason — *stale* implies it will refresh, and the
  # finding is that it will not.
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
  # **The third clause is why this state exists in this shape at all.**
  # CodeRabbit will not re-walkthrough its own autofix commit — in five of nine
  # recently merged pull requests the head's walkthrough named a different
  # commit — and autofix is the loop's primary path, so V1's prefix test alone
  # would veto nearly every pull request the loop itself fixes, permanently, on
  # a cause the loop's own write produced and the operator cannot clear.
  # Relaxing V1 to accept the parent's verdict was rejected: the nine-second
  # *Review completed* on an autofix head is almost certainly a **skip**, so
  # clearing on it would merge a diff no verdict covers. The mismatch is
  # loop-produced, so terminality forbids a `no`; it is permanent at that head,
  # so permanence forbids a useful `defer`; but it is loop-**retractable** — a
  # cause that does not self-clear whose remedy is a write. So the gate judges
  # and the chain repairs.
  #
  # It is **cause-blind**, so a force-pushed head takes the same remedy and
  # stands on firmer ground there, that head really being new code.
  # Discriminating would need exactly the commit ancestry and authorship the
  # relaxation was rejected for.
  #
  # Which clause fired goes in the tail rather than into a second state name:
  # the routes are the same state and want the same remedy, and the log line is
  # where the difference belongs.
  needs_review=false
  route=""
  if [[ "$signal" != "true" ]]; then
    needs_review=true
    route="no-signal"
  fi
  if [[ "$block" == "absent" ]]; then
    needs_review=true
    route="${route:+$route,}no-block"
  fi
  # An unparseable block is deliberately not this clause: it names no
  # abbreviation, so there is nothing to test against the head, and it belongs
  # to V1's tripwire for CodeRabbit changing shape rather than to a remedy.
  if [[ -n "$block_abbrev" && "$head" != "$block_abbrev"* ]]; then
    needs_review=true
    route="${route:+$route,}other-head"
  fi

  # First match wins.
  review=terminal
  [[ "$terminal" == "true" ]] || review=pending
  kv="review=$review threads=$threads autofix=$spent"

  # **A standing record is no longer a state and no longer short-circuits the
  # chain.** Un-latching is a deletion: the test that used to sit above every
  # other one is gone, the whole state machine re-derives from scratch every
  # pass, and it costs nothing to do so — the record was always derived from the
  # comment timeline this phase already reads, so the short-circuit was
  # downstream of the read rather than saving one. What the record now decides is
  # settled in the tail, by `consume_record`.
  #
  # What survives of the latch is exactly this: **while a record stands the loop
  # does not do the thing the record promised it would not.** No merge, no
  # autofix trigger, no nudge — and those are the only three writes the chain
  # makes, so `$stands` is tested at exactly three sites below: the nudge, the
  # autofix trigger, and the merge. **A fourth action added to this chain needs a
  # fourth test, and the world in `unlatch-cases` is where that is caught** — it
  # holds one pull request per disposition and asserts that the pass wrote
  # nothing at any of their heads.
  #
  # `$withheld` is the tail such a site prints, decided once here rather than
  # spelled at each of them, and it names the bound honestly in both cases: the
  # loop's own record comes down on this very pass, and one it cannot rewrite
  # comes down when the operator moves the pull request. A line claiming a
  # retraction that is never coming would break the one thing the tail exists to
  # carry.
  stands=false
  withheld=""
  if [[ "$escalated" == "true" ]]; then
    stands=true
    if [[ -n "$esc_comment" ]]; then
      withheld="action=deferred bound=retraction"
    else
      withheld="action=deferred bound=operator"
    fi
  fi

  if [[ "$signal" == "true" && "$review" != "terminal" ]]; then
    # A review that started and has not finished. This **is** a gate-style
    # `defer` — *a signal not yet computed* is its exact definition — so it
    # reuses the gate's key rather than inventing one. It was unbounded only
    # because V5 lives inside the gate and this short-circuits before reaching
    # it.
    #
    # **The origin is not `headDate`.** A real pull request sat four and a half
    # hours between its head commit and its review starting — so a clock from
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
      want_handover stuck \
        "$(reason ok "CodeRabbit acknowledged this commit — the review started" \
             "oldest-pending=$pending_at origin=$origin head=$head_date")" \
        "$(reason no "the review has not finished inside the gate clock" \
             "age=${age}s bound=${MERGE_GATE_TIMEOUT}s")"
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
      want_handover stalled \
        "$(reason ok "CodeRabbit's review finished on this commit" \
             "review=$review threads=$threads")" \
        "$(reason no "the autofix trigger has gone unanswered past its bound" \
             "trigger=$trigger_at age=${age}s bound=${AUTOFIX_TIMEOUT}s head=$head_date")"
    fi
  elif $needs_review; then
    kv="$kv route=$route"
    # **Did CodeRabbit answer the command I sent?** An answer is any CodeRabbit
    # output newer than the latest nudge — a status (`signalAt > nudgeAt`) **or**
    # a comment (`$reply`, selected by the same freshness shape) — and it is
    # keyed on its **presence, never on its content** (#143). What an answer
    # *means* comes from the status alone, below. Timestamp ordering is the only
    # attribution available: the status carries no invocation id, so anything
    # stronger would be ordering wearing a better name. Without a nudge to be
    # newer than there is nothing to answer, so an empty `nudgeAt` is unanswered
    # by construction.
    signal_epoch=$(epoch_of "$signal_at") || signal_epoch=""
    nudge_epoch=$(epoch_of "$nudge_at") || nudge_epoch=""
    # **The origin of the refusal run is the *first* nudge at this head**, read
    # here because two things below measure from it: the retry window, and which
    # status silence may inherit. The fallback is the newest nudge, which can
    # only make the window run late by the width of one retry, and is reachable
    # only if a timestamp the loop wrote will not parse.
    first_epoch=$(epoch_of "$nudge_first_at") || first_epoch=""
    [[ -n "$first_epoch" ]] || first_epoch="$nudge_epoch"
    status_answered=false
    if [[ -n "$nudge_epoch" && -n "$signal_epoch" ]] && (( signal_epoch > nudge_epoch )); then
      status_answered=true
    fi
    # **Silence inherits the answer that stands in its refusal run.** No status
    # and no comment after the latest nudge carries no meaning of its own, so
    # past one poll interval it takes the newest status since the run's first
    # nudge — and a refusal followed by silence is still a refusal, retried
    # under `reviewRetryTimeoutSeconds` rather than handed over as `stalled`.
    #
    # The premise this replaced — *a rate limit always writes a status, so it
    # always answers* — held for 25 nudges inside refusal runs on `#117` and
    # `#141`, each answered within ~10s, and was falsified by `#142`: its second
    # nudge at 04:43:28Z drew no status, no `queued`, no comment, ever, and one
    # poll interval later the loop handed over a record whose reader's only move
    # was the nudge the retry row exists to make. Nothing the loop can read says
    # why a command was ignored, so the rule is cause-blind by necessity.
    #
    # **Within one poll interval of the latest nudge silence inherits nothing**,
    # so it stays `nudge-in-flight` below. That keeps *a command in flight is
    # never pre-empted* true by construction rather than by timing — unreachable
    # at today's cadence, where a pass never follows its nudge by less than an
    # interval, and true at any cadence.
    #
    # **A comment is not silence**, which is why presence counts it: a
    # comment-only answer carrying no status — the `Already reviewed the last
    # commit` shape — inherits nothing and stalls on the poll-interval clock.
    # Counting statuses alone would hold it in the run for the whole retry
    # window and surface it as `declined`, late and under the wrong kind.
    status_stands=false
    if $status_answered; then
      status_stands=true
    elif [[ -z "$reply" && -n "$nudge_epoch" && -n "$signal_epoch" ]] \
        && (( now - nudge_epoch > POLL_INTERVAL && signal_epoch > first_epoch )); then
      status_stands=true
    fi
    # **And was that answer a refusal?** One bash comparison against a one-value
    # allowlist, beside where `route` is derived: jq keeps emitting facts, bash
    # keeps making policy. `Review completed` is the only description that means
    # a run happened; everything else — known, renamed or absent — means no run,
    # and the `else` arm swallowing both `Review skipped:` values is correct for
    # both, the `<10 stars` one being precisely what the nudge remedies and the
    # draft one being a stale leftover, drafts never reaching here.
    #
    # **The fact is one-way.** It may only ever make the loop *ask*; it may never
    # conclude *reviewed* and never remove a route. A `Review completed` newer
    # than the nudge therefore changes nothing here — the meter stays spent and
    # the poll-interval clock below runs exactly as it does today — and *was this
    # head reviewed* stays the merge-risk block test's sole property, so a
    # two-second no-op review is still caught where it is caught today.
    #
    # It is read off the *standing* status, so an inherited `Review completed`
    # is exactly as inert as a fresh one, and silence after it stalls.
    answer_refused=false
    if $status_stands && [[ "$signal_desc" != "$CODERABBIT_STATUS_REVIEWED" ]]; then
      answer_refused=true
    fi
    # **The meter, and it is *awaiting an answer* rather than *asked once
    # here*.** A nudge newer than the head used to be the whole of it; it keeps
    # only its second job now — telling a first nudge from a subsequent one —
    # and a refusal **un-spends** it, so the head's one chance is not burned by
    # a command that did nothing.
    #
    # **Two clocks are live at one head and the order below is what keeps them
    # from racing.** The retry window is read *only* on the arm where nothing is
    # outstanding: a command already in flight is never pre-empted by the outer
    # bound, because it may be the one that lands and pre-empting it would post
    # a record the next pass has to retract. Silence inherits nothing inside
    # that interval, so the window may overrun by up to one poll interval before
    # `declined` posts — the slack every clock in this phase already has. Past
    # it, a silent tail stays in the retry sequence, and `nudge-stalled` is
    # reachable inside a run only by a comment-only answer.
    ask=false
    # **`nudgeFirstAt` is the whole of *is a command of mine outstanding at this
    # head*.** The head-scoping is done once, in jq, and read here as an
    # emptiness test — rather than spelled a second time in bash as
    # `nudgeAt > headDate`. The two would be one predicate in two languages, one
    # comparing strings and one comparing epochs, with the head-scoping *policy*
    # living in both.
    #
    # The empty-`nudge_epoch` arm beside it is a **parse guard and not a second
    # copy of the head test**: a timestamp that will not convert cannot start a
    # clock, and the honest reading of that is *no command outstanding*, which
    # asks again rather than waiting on a number that does not exist.
    if [[ -z "$nudge_first_at" || -z "$nudge_epoch" ]]; then
      # The remedy, and it is a **write** because the cause does not clear on
      # its own: CodeRabbit auto-pauses incremental reviews after five
      # reviewed commits and the counter resets only when the pause is lifted,
      # which is a command. *Wait longer* was never an exit.
      #
      # No command has been sent at this head, so there is nothing to be an
      # answer to and no `answer=` on the line at all.
      state=needs-review
      ask=true
    elif ! $answer_refused; then
      # A command is outstanding — either unanswered, or answered by a
      # `Review completed` the one-way rule forbids concluding anything from.
      # The meter stays spent and this is the clock it has always been.
      #
      # The bound is **one poll interval** — no new config key and no new
      # clock — and that is a measurement rather than a convenience: command
      # replies and review-queued statuses arrive in *seconds*, where autofix
      # earned a key of its own at nearly eighteen minutes.
      #
      # The nudge's **created** timestamp is the one read, correct here
      # specifically because the loop authors it. The updated-timestamp
      # binding is about comments CodeRabbit edits.
      age=$(( now - nudge_epoch ))
      kv="$kv age=$age bound=$POLL_INTERVAL answer=none"
      if (( age <= POLL_INTERVAL )); then
        state=nudge-in-flight
      else
        # Past the bound with still no answer. `stalled`, like the autofix
        # clock: a command was triggered and CodeRabbit never answered.
        #
        # **What reaches here is a stall** (#143): silence with no refusal
        # standing since the first nudge at this head, or a comment-only answer
        # carrying no status — the `Already reviewed the last commit` reply,
        # which writes no status ever and so is no refusal by the glossary's
        # definition. The one-way rule's `Review completed` still arrives here
        # too, fresh or inherited, exactly as before. Silence after a refusal no
        # longer does: it inherits the refusal above and is retried. What is
        # left is that reply, a force-push orphan, a review still in flight past
        # the bound, and a `Review completed` that moved nothing — and the two
        # causes an operator can act on are defensible for every one of them.
        #
        # The bound is **cause-blind** — a curable cause was cured by the
        # nudge, an incurable one arrives here — so none of the documented
        # non-triggers is tracked. The two an operator can act on are named
        # all the same, because a handover exists to be acted on.
        state=nudge-stalled
        # **The `no` row branches on the route**, and it is a lookup rather
        # than a second derivation: the route is already computed above.
        #
        # Under `other-head` alone every clause of the older text is false —
        # CodeRabbit is installed, has seats, and reported on this head in
        # nine seconds — so saying it would send the operator to look at a
        # seat count when the real state is a verdict pinned to another
        # commit. Any route carrying `no-signal` keeps the older text, because
        # then CodeRabbit really did put nothing on this head.
        #
        # The exact match reads as if it missed a case and does not: the only
        # route that can join `other-head` is `no-signal`. `no-block` means
        # there is no block anywhere, which leaves nothing to parse an
        # abbreviation out of, so the two cannot both fire.
        if [[ "$route" == "other-head" ]]; then
          stalled_reason="CodeRabbit reviewed this head and left its merge-risk verdict on another commit — the nudge did not move it, so no verdict covers the code being merged"
        else
          stalled_reason="CodeRabbit never reported a review inside the bound — it may not be installed on this repository, or the organisation may be out of seats"
        fi
        want_handover stalled \
          "$(reason ok "the review nudge was posted at this head" \
               "nudge=$nudge_at route=$route head=$head_date")" \
          "$(reason no "$stalled_reason" \
               "age=${age}s bound=${POLL_INTERVAL}s nudge=$nudge_at route=$route")" \
          "$(reason note "CodeRabbit's reply to the nudge, verbatim and unparsed" \
               "${reply:-none}")"
      fi
    else
      # **My command was refused.** Asking again is free — the review meter is
      # per repository and a refused command consumes neither a review nor any
      # delay before the next one — so what is lost by not asking is latency,
      # and a slot that refills at `05:23` is used at `05:23`.
      #
      # **Bounded in aggregate, not merely per turn**, which is the distinction
      # that makes this a sequence rather than a cycle: it turns at most
      # `ceil(reviewRetryTimeoutSeconds / pollIntervalSeconds)` times and then
      # enters `declined`, which gates the very write that turns it. The bound
      # is a clock rather than a cap because every other wait in the phase is
      # `age`/`bound`/`origin` and a cap measures the wrong thing — the poll
      # interval is a config value, so *N attempts* is not a duration.
      #
      # It cannot be unbounded at any cadence: `comments(last: 100)` is the
      # window every comment-derived fact reads, a retry posts two comments a
      # pass, and an unbounded retry would poison the loop's own inputs in about
      # fifty passes. `retries=` on the line is that canary.
      #
      # **The origin is the *first* nudge at this head**, so the window measures
      # the whole wait rather than resetting on every retry — and a push resets
      # it, because the fact itself is head-scoped. A silent tail runs on the
      # same clock: silence inherits the run's refusal, so the run is one wait
      # with one origin. The fallback is read where `first_epoch` is.
      age=$(( now - first_epoch ))
      # `retries=` counts every nudge on the pull request rather than only those
      # at this head, and that is deliberate: it is the **read-budget canary**,
      # and the window it is warning about — `comments(last: 100)`, which every
      # comment-derived fact is read out of — does not reset when the head
      # moves. Climbing toward 50 means that window is closing. The head-scoped
      # number beside it is `origin=first-nudge`.
      kv="$kv retries=$nudge_count age=$age bound=$REVIEW_RETRY_TIMEOUT origin=first-nudge answer=refused"
      # CodeRabbit's own words, verbatim, and **last on the line** — see the log
      # call at the bottom of this function for why it is held rather than
      # appended here.
      signal_kv="signal=$signal_desc"
      if (( age <= REVIEW_RETRY_TIMEOUT )); then
        state=needs-review
        ask=true
      else
        # The bounded exit, and its **own kind**: `stalled` means CodeRabbit
        # never reported inside the bound and would become false of this, where
        # what happened here is that CodeRabbit refused at this head and nothing
        # after the refusal changed it. `refused` was not available — the merge
        # owns it, and re-using a kind across two subsystems is worse than a
        # new word.
        #
        # **One kind, whether the run's tail was refused or silent** (#143). A
        # `declined-silent` kind was rejected: a retraction cost in the handover
        # register for a difference the reader does not act on. The rows say
        # only what is true of both, and the gap between `last-nudge=` and
        # `answered-at=` is where a silent tail shows.
        state=nudge-declined
        # Built as a local list and handed over in one call, like the gate's
        # own variable-length rows: `want_handover` is the only writer of the
        # handover globals in this file, and a second one is how the two come to
        # disagree about what a pending handover is.
        declined_rows=()
        declined_rows+=("$(reason ok "CodeRabbit refused at this head and never ran a review" \
          "first-nudge=$nudge_first_at retries=$nudge_count route=$route head=$head_date")")
        # **The description is pasted verbatim**, and that is safe *precisely
        # because* the status is newer than the run's first nudge — which is
        # what got the pass here, whether it answered the last nudge or silence
        # inherited it: it is still an answer to a command the loop wrote
        # rather than a stale slot. This is the diagnosis half of the rule the
        # allowlist above states the control half of — verbatim, and nothing in
        # between.
        declined_rows+=("$(reason no "the retry window closed with no review run — its newest answer since the first nudge was \"$signal_desc\"" \
          "age=${age}s bound=${REVIEW_RETRY_TIMEOUT}s last-nudge=$nudge_at answered-at=$signal_at route=$route")")
        # The one route with **no remaining path to a verdict at all**, said out
        # loud because the operator cannot derive it from the other rows: autofix
        # is spent at a CodeRabbit-authored head and will not run again there,
        # and the review that head needs is the thing being refused. That is the
        # difference between *wait for the limit to lift* and *go and look now*.
        if [[ "$spent" == "spent:own-head" ]]; then
          declined_rows+=("$(reason no "the loop has no remaining path to a verdict on this pull request — autofix will not run again at a CodeRabbit-authored head, and the review it needs is being refused" \
            "autofix=$spent route=$route")")
        fi
        declined_rows+=("$(reason note "CodeRabbit's reply to the last nudge, verbatim and unparsed" \
          "${reply:-none}")")
        want_handover declined "${declined_rows[@]}"
      fi
    fi
    if $ask; then
      # Once per head *while a command is outstanding*, and again on the pass
      # after a refusal. The command is one-shot, so a pull request taking
      # pushes re-wedges roughly every five commits and is nudged again at each
      # new head — the stated cost of choosing the measured verb.
      if $stands; then
        # The record promises no nudge, so the pass spends its one action on
        # taking the record down instead and the nudge lands on the next one.
        # Deferred rather than dropped, and said out loud: with no local state
        # this line is the only record the withheld write leaves.
        #
        # This is also what stops the retry once a `declined` record stands: the
        # record gates the nudge site, so the pull request parks with a record
        # and a label where today it parks with neither.
        kv="$kv $withheld"
      else
        status=0
        post_review_nudge "$github" "$number" || status=$?
        if (( status == 0 )); then
          kv="$kv action=nudged"
        else
          # Nothing is remembered, so nothing has to be unwound: the next pass
          # re-derives, finds the pull request still needing a review and
          # still un-nudged, and writes again. The poll interval is the
          # backoff.
          #
          # A refused nudge would be re-asked forever on that argument, so it
          # flags the pull request instead; the state line carries the class.
          class=$(gh_error_class "$FAILURE_TEXT")
          kv="$kv action=failed rc=$status class=$class"
          write_failed "$class" pr "$github" "$number" nudge ""
          SKIPS=$((SKIPS + 1))
        fi
      fi
    fi
  elif (( threads > 0 )) && [[ "$spent" == "unspent" ]]; then
    state=needs-autofix
    if $stands; then
      # The same rule as the nudge's, for the same reason: the record promises
      # no autofix trigger.
      kv="$kv $withheld"
    else
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
        #
        # Refused, *fires again* is forever, so it flags the pull request.
        class=$(gh_error_class "$FAILURE_TEXT")
        kv="$kv action=failed rc=$status class=$class"
        write_failed "$class" pr "$github" "$number" trigger ""
        SKIPS=$((SKIPS + 1))
      fi
    fi
  else
    # The gate. Every veto evaluates, the verdict lands in the tail, and a
    # `defer` is silent by design and re-derived next pass.
    state=assessable
    if ! risk_gate "$head" "$head_date" "$head_epoch" "$now" "$response"; then
      # Same as the unreadable state above: a parse of a read that landed, with
      # nothing GitHub said to classify.
      read_failed "$(gh_error_class "")" "$github" "pr gate unreadable: $github#$number"
      SKIPS=$((SKIPS + 1))
      return 0
    fi
    kv="$kv $GATE_KV"
    if [[ "$GATE_VERDICT" == "escalate" ]]; then
      # The `[@]+` guard is bash 3.2 refusing to expand an empty array under
      # `set -u`. Every veto appends a row, so this can never be empty — and the
      # cost of being wrong about that is the daemon dying mid-pass.
      want_handover "$GATE_KIND" "${GATE_REASONS[@]+"${GATE_REASONS[@]}"}"
    elif [[ "$GATE_VERDICT" == "merge" ]]; then
      # The line the whole daemon exists to cross. Everything before it is
      # reversible; this is not, so the three things that make crossing it safe
      # are all here: the commit named is the one the gate assessed, the bound
      # is spent before the write rather than after it, and the flag holds the
      # write and nothing else.
      if $stands; then
        # The record promises no merge, so the pass spends its one action on
        # taking the record down and the merge is re-derived next pass. **This
        # is the first half of what keeps a `refused` record from oscillating**:
        # the gate would say `merge` again at the same head, and a record naming
        # that head is a head-keyed merge spend, read out of the comment the
        # response already carries. Whatever the record's kind, no merge write
        # happens while it stands.
        kv="$kv $withheld"
      elif [[ " $wdn_kinds " == *" refused "* ]]; then
        # **The second half, and the one that makes the spend survive.** Taking
        # the record down un-latches the pull request, and without this the
        # merge spend would come down with it: the gate says `merge` at the same
        # head, GitHub refuses again, and a fresh record is posted, because the
        # withdrawn comment carries no record marker to write over. One merge
        # attempt and one new comment every two passes, unbounded, on a pull
        # request that is already asking for a human.
        #
        # The withdrawal notice is what survives, and the kind it names is what
        # makes this a merge spend rather than a latch: only `refused` says *the
        # loop asked GitHub to merge this commit and GitHub said no*, which is
        # permanently true of the commit. A withdrawn record of any other kind
        # is a claim about signals that have since changed, and it withholds
        # nothing. **Any** notice at this head naming `refused` answers, not the
        # newest one — a head can carry several, and a later withdrawal of some
        # other kind must not mask this one.
        #
        # **Silent, and the reason is on the pass line.** Posting anything here
        # would be the comment growth this exists to stop, and the log carries
        # every verdict GitHub never sees.
        #
        # **The merge only.** The handover write is deliberately not metered per
        # head, so a re-escalation of a different kind at this head still posts
        # its record — and the per-repository merge budget is not spent either,
        # because nothing was merged.
        #
        # `merge=spent:<why>` rather than a bare `bound=` value, on the shape
        # `autofix=spent:trigger` already uses: an operator asking why the merge
        # did not go out cannot answer it from a blind *deferred*, and the same
        # question about autofix is answered the same way one line over.
        #
        # The bound is external and the exits are the operator's: a push moves
        # the head and the token stops matching it, and a merge by hand ends the
        # pull request. That is the bounded-exit table's second externally-bound
        # row, recorded as correct rather than as a hole.
        #
        # **Not asking again is the decision, and `refused` is broader than
        # *GitHub will never merge this*.** It is every durable status the call
        # can return, and a few of them clear on their own — a required review
        # that is later approved leaves the head where it is. The loop will not
        # notice, and the operator's push is what re-arms it. That is the price
        # of killing the oscillator, paid here rather than left to be found.
        kv="$kv action=deferred bound=external merge=spent:withdrawn-refusal"
      elif $REPO_MERGE_SPENT; then
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
            want_handover refused \
              "${GATE_REASONS[@]+"${GATE_REASONS[@]}"}" \
              "$(reason no "GitHub refused the merge of the commit the gate cleared" \
                   "rc=$merge_status method=$method head=$head response=${merge_out:-none}")"
            # The refusal itself is not a skip: the loop set out to act on this
            # pull request and did — the action turned out to be the handover,
            # and only a handover that did not land counts against the pass.
            kv="$kv merge=refused rc=$merge_status"
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

  # The record, consumed after the chain has derived and before the line is
  # written. Everything above decided what is *true* of this pull request now;
  # this decides what happens to what the loop said about it last time.
  consume_record "$github" "$number" "$head" "$read_at" "$labelled" \
    "$stands" "$esc_kind" "$esc_comment"

  # **`signal=` is last on the line, and it is last *because* it is free text.**
  # `signalDesc` is the only value in the project that can contain a space,
  # the tail is otherwise strictly `key=value`, and positioned last everything
  # after `signal=` is the value — so nothing can be shadowed by it. It is
  # appended here rather than into `$kv` so that the handover's own keys cannot
  # land behind it, and it is **omitted entirely when nothing refused**, which
  # makes the field's presence itself the fact that something answered.
  log "pr $github#$number $head $state $kv${HANDOVER_KV:+ $HANDOVER_KV}${signal_kv:+ $signal_kv}"
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
  if ! response=$(gh_graphql "{ search(query: \"is:pr is:merged author:$ME sort:updated-desc\", type: ISSUE, first: 100) { nodes { ... on PullRequest { number headRefName repository { nameWithOwner } } } } }"); then
    printf '%s' "$response"
    return 1
  fi
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
  if ! response=$(gh_json "/repos/$github/issues/$number"); then
    printf '%s' "$response"
    return 1
  fi
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
  FAILURE_TEXT=""
  printf '%s' "$3" > "$file" || return 1
  axi_write issue edit "$number" --repo "$github" --body-file "$file"
  status=$?
  rm -f "$file"
  return "$status"
}

# Dropping the claim label is what ends the loop's hold on an issue, and it is
# the last write close-out makes. It stands on its own because close-out reaches
# it two ways: after a close of its own, and on an issue GitHub closed at merge,
# where there is no close left to make. The failure line lives here rather than
# at either caller, because both say the same sentence and only the accounting
# differs — a reworded copy at one caller would be a lie at the other.
unclaim_issue() {
  local github="$1" number="$2"
  axi_write issue edit "$number" --repo "$github" --remove-label "$LABEL_CLAIMED" && return 0
  # Refused, *picked up by the next pass* is forever, so it flags the issue —
  # the one write whose object is already closed, and still the object whose
  # label the reader has to take off.
  write_failed "$(gh_error_class "$FAILURE_TEXT")" issue "$github" "$number" unclaim \
    "unclaim failed for $github#$number, leaving the label on a closed issue"
  return 1
}

# The close and the unclaim are two calls, because gh-axi closes an issue and
# edits its labels through different subcommands. So the order is the whole
# guarantee. Closing first means a failed unclaim leaves a closed issue still
# wearing the claim label: untidy, and picked up by the next pass, because
# close-out keys its silence on the label rather than on the state. Unclaiming
# first would mean a failed close leaves an open issue wearing neither label —
# work the loop has quietly forgotten.
close_issue() {
  local github="$1" number="$2"
  # A failed close leaves its text in `$FAILURE_TEXT`; nothing after it runs.
  axi_write issue close "$number" --repo "$github" || return 1
  # The close landed, so the close-out succeeded; a lost unclaim has already
  # said so on its own line and the next pass will try it again.
  unclaim_issue "$github" "$number" || :
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
  # **The two entry paths are two enumerations, and neither gates the other.**
  # They read different things — one a global merged-pull-request search, the
  # other a per-repository claim query — and a hiccup in the first must not
  # silently leave every decomposed spec claimed for the pass, with no line
  # naming it.
  if prs=$(query_merged_prs); then
    # stdin is closed for the body: gh-axi must not swallow the PR list.
    while IFS=$'\t' read -r github prnumber branch; do
      [[ -n "$github" && -n "$branch" ]] || continue
      closeout_one "$github" "$prnumber" "$branch" < /dev/null
    done <<< "$prs"
  else
    # The search is global rather than per repository, so a refused search is
    # every configured project's at once, and the fatal line names them all.
    read_failed "$(gh_error_class "$prs")" \
      "$(jq -r '[.projects[].github] | join(",")' "$CONFIG_PATH")" "merged-pr query failed"
    SKIPS=$((SKIPS + 1))
  fi
  # The merged path before the claims, not after: the reclaim hands back a
  # claim with no worktree, and a merged issue whose worktree has already been
  # swept is exactly that — so closing it out first is what stops it being
  # dispatched a second time.
  closeout_claims
}

# Close-out's **second entry path**, and not a new phase. `query_claimed_issues`
# rests its whole argument on an invariant — *close-out is the only path that
# clears such a label, and it reaches a closed issue on every pass* — and a
# second claim-clearing phase would falsify that sentence and the blindness it
# justifies. What widens is close-out's *description*: it stops being **the
# phase that reads merged pull requests** and becomes **the phase that
# enumerates the loop's holds and releases the ones with evidence behind them.**
#
# A ticket's exit evidence is a merged pull request. A decomposition produces
# issues and never a pull request, so its evidence is the **native sub-issue
# edges** it created — the same *class* of thing: a structural artifact that
# carries the work, rather than the worker's claim about itself. Every signal
# the loop acts on today is third-party, and a `decomposed` label written by the
# worker would be the first time the loop believed a worker about its own
# completion.
#
# It inherits the open-pull-request predicate's imprecision **knowingly**: a
# worker that publishes 3 of 8 tickets and dies reads as finished, exactly as a
# draft pull request with half a feature in it reads as delivered. Same
# imprecision, one level up, accepted rather than overlooked.
#
# One GraphQL per repository per pass, plus one REST read per claimed **spec**,
# which is bounded by `maxWorkers` because a spec drops out of the claimed set
# the moment it is flagged, plus the reclaim's own open-pull-request read for a
# repository with anything claimed.
#
# **The reclaim is this loop's else-branch** (#136): a spec's claim exits here on
# its edges, and every other claim with nothing behind it exits through
# `reclaim_claim`. The two partition the claimed set. Close-out precedes the
# issue phase, so no dispatch of this pass can be raced; one from an earlier pass
# is covered by the grace.
closeout_claims() {
  local i github rows number verb escalation reclaimable
  for (( i = 0; i < PROJECT_COUNT; i++ )); do
    github=$(jq -r ".projects[$i].github" "$CONFIG_PATH")
    if ! rows=$(query_claimed_issues "$github"); then
      read_failed "$(gh_error_class "$rows")" "$github" "claimed-issue query failed: $github"
      SKIPS=$((SKIPS + 1))
      continue
    fi
    # Kept for the pass: whether a live worker's claim is gone, and whether its
    # issue wears the flag, are asked of this read and of no second one (#122).
    PASS_CLAIMS_READ+=" $github "
    # Nothing claimed here: no second question to ask, and no read to spend
    # asking it.
    [[ -n "$rows" ]] || continue
    # Fail closed. A reclaim that cannot see this repository's open pull
    # requests would hand back every issue one of them already delivers, and the
    # loop polls: an unanswered read costs one interval, where a duplicate costs
    # a whole rebuild. Only the reclaim is skipped; a spec's exit reads no pull
    # request.
    reclaimable=true
    if ! read_open_pr_issues "$github" < /dev/null; then
      read_failed "$(gh_error_class "$FAILURE_TEXT")" "$github" "open-pr query failed: $github, skipping its reclaim"
      SKIPS=$((SKIPS + 1))
      reclaimable=false
    fi
    # stdin is closed for the body: gh-axi must not swallow the issue list.
    #
    # The flag word is kept for the pass, and the reclaim takes a refused
    # write's flag down with the claim it drops.
    while IFS=$'\t' read -r number verb escalation; do
      [[ -n "$number" ]] || continue
      PASS_CLAIMS+="$github"$'\t'"$number"$'\t'"$escalation"$'\n'
      # Asked of the snapshot readiness took, so never of an inventory that
      # could not be read, which would answer *nobody is on it* (#124).
      if issue_has_live_worker "$github" "$number"; then
        log "left claimed $github#$number: a live worker holds it"
        continue
      fi
      # **Verb scope**, and it is load-bearing rather than tidy: without it the
      # spec exit fires on any claimed issue that happens to have children — a
      # wayfinder map wearing a ready label by accident, or any epic-shaped
      # ticket.
      #
      # The verb is read here, off the claim query, rather than off the REST
      # payload the child count comes from — which was the other candidate and
      # would have put the same question to two payloads. Reading it here scopes
      # **before** the read rather than after it, so an ordinary claimed ticket
      # costs no request at all: one REST read per claimed *spec*, not per
      # claimed issue. The reclaim needs this row's verb anyway, so the answer
      # is already in hand.
      if [[ "$verb" != "$VERB_TO_TICKETS" ]]; then
        if $reclaimable; then
          reclaim_claim "$github" "$number" "$escalation" < /dev/null
        fi
        continue
      fi
      # The exemption is said by the handover, and only while it has an end.
      closeout_claim "$github" "$number" "$escalation" < /dev/null
    done <<< "$rows"
  done
}

# One claimed spec. The predicate has three conjuncts and each one is
# load-bearing: **the verb is `to-tickets`** (the caller's), **no live worker
# holds it**, and **`sub_issues_summary.total > 0`**. With the liveness guard,
# the question is the exact mirror of the reclaim's own two-question shape —
# *nobody is on it, and something has come of it.*
#
# The exit is **unclaim + flag + leave open**. Not closed: the children land
# inert pending a human, and closing the spec hides the one artifact that most
# needs one. Not unflagged either: a spec wearing neither ready nor claimed is
# indistinguishable from one nobody has touched, and a human who re-applies the
# ready label to it gets a second decomposition with no warning. The open,
# flagged spec **is** the arrival signal — the trick `agent-escalated` already
# plays, and the only one available, since the loop acts as the operator's own
# account and GitHub never notifies you of your own actions.
#
# The cost, recorded rather than waved past: this adds a **terminal-but-open**
# state to a tracker where terminal has meant closed.
#
# **No record comment — the flag alone.** The two-tier convention exists because
# a refusal is a *judgement* the human cannot otherwise reconstruct. This is
# not: its entire evidence is `sub_issues_summary`, which GitHub already renders
# as a sub-issue list with a progress bar, and a comment saying *I found 8
# children* beneath a panel listing 8 children is a conclusion on its own.
#
# **At zero children the spec is handed over**, not left: see `hand_over_spec`.
closeout_claim() {
  local github="$1" number="$2" escalation="$3" issue total wore
  # The caller has already asked liveness, of the snapshot readiness took, and
  # comes here only when nobody is on it. `/to-tickets` publishes its issues one
  # at a time in dependency order, so `total > 0` goes true on the **first**
  # one. Without the caller's guard a pass landing in that window unclaims a spec whose
  # worker is still running and logs that it closed it out. Orca holds a
  # `waiting` agent as live, so a worker parked for a human's approval is held
  # with no new machinery.

  if ! issue=$(query_issue "$github" "$number"); then
    read_failed "$(gh_error_class "$issue")" "$github" "close-out query failed: $github#$number"
    SKIPS=$((SKIPS + 1))
    return 0
  fi
  # A payload with no such key reads as zero: no child to exit on.
  total=$(jq -r '.sub_issues_summary.total // 0' <<< "$issue")
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  if (( total == 0 )); then
    hand_over_spec "$github" "$number" "$escalation"
    return 0
  fi

  # One swap, the same delta shape the claim uses: the marker on, the
  # claim off. The verb label stays — it is a modifier and nothing removes it —
  # and the ready label was taken off at claim and is never restored, so the
  # spec is now in no loop query at all. Steady-state cost zero.
  if swap_labels "$github" "$number" "$LABEL_DECOMPOSED" "$LABEL_CLAIMED"; then
    log "decomposed $github#$number: $total sub-issues, unclaimed and flagged $LABEL_DECOMPOSED, left open"
    forget_claim "$github" "$number"
    wore=$(jq -r --arg esc "$LABEL_ESCALATED" \
      'if any(.labels[]?.name; . == $esc) then "flagged" else "unflagged" end' <<< "$issue") \
      || wore=unflagged
    # The swap also takes down the handover's flag, so a spec that gains
    # children stops asking for attention.
    withdraw_write_flag "$github" "$number" "$wore" "it has $total sub-issues"
  else
    # Refused, *leaving it claimed* is forever, so it flags the spec.
    write_failed "$(gh_error_class "$FAILURE_TEXT")" issue "$github" "$number" decomposition-swap \
      "decomposition close-out failed for $github#$number, leaving it claimed"
    SKIPS=$((SKIPS + 1))
  fi
}

# **The spec handover** (#140, under #121). A claimed spec close-out found no
# live worker on and no sub-issue under. The reclaim never hands a spec back and
# close-out's exit needs a child, so nothing else in the file frees this claim,
# and without an end the exemption would be said on every pass, forever.
#
# **Bound:** the reclaim's DISPATCH_GRACE_SECONDS, against the youngest matching
# worktree's `createdAt`, or the pass that sees it when there is no worktree at
# all. The hold is the reclaim's own `claim_hold`, so a dirty tree inside the
# worker bound holds it too — that is still a worker — and so does a worktree
# with no `createdAt`, which says so every pass exactly as it does for a reclaim:
# that row is #136's, inherited here rather than decided again.
#
# **Expiry:** one record and `agent-escalated`, and **the claim is kept**. The
# reader's move is the one the reclaim will not make blind: a worker that linked
# its children by prose alone leaves the count at zero too, so they look for
# those first, then re-apply the ready label or abandon the spec.
#
# **No read after success.** The first gate is the claimed query's own flag word:
# a flagged spec gets no comment read, no write and no line. An unflagged spec
# past the bound reads its comments for the handover's stable marker. If the
# record is already there after a failed flag write, the next pass retries only
# the flag. So each spec gets at most one record, and the line is written only
# on the pass that adds the flag. What that costs, named:
#
# - **A spec already flagged by the sweep's Row B that then dies gets no second
#   record.** The hung-worker record already names its worktree, and the flag
#   stays up.
# - Until the flag lands, each pass pays one paged comment read to distinguish a
#   missing record from a record whose flag write failed.
#
# The flag comes off with the claim — the `agent-decomposed` swap takes it down,
# and so does a claim after a human re-arms the spec — and the sweep leaves it
# alone meanwhile, which is what `PASS_HANDED_OVER` is for.
#
# Its writes are escalation writes, and fail like `escalate_hung_worker`'s: a
# refused one dies, and a transient one is logged, counted and tried again.
SPEC_HANDOVER_MARKER='<!-- agent-loop-spec-handover -->'

hand_over_spec() {
  local github="$1" number="$2" escalation="$3" hold kind='' detail='' why file="" status=0 class
  local comments seen
  # A hold that would not answer leaves `kind` empty, which the last arm holds.
  hold=$(claim_hold "$github" "$number") || hold=''
  IFS=$'\t' read -r kind detail <<< "$hold"
  case "$kind" in
    none) why="no worktree" ;;
    gone) why="worker gone $(( detail / 60 ))m after dispatch" ;;
    dirty)
      log "left claimed $github#$number: a $VERB_TO_TICKETS issue is never handed back, and a dirty worktree holds it"
      return 0
      ;;
    young)
      log "left claimed $github#$number: a $VERB_TO_TICKETS issue is never handed back, and a worktree inside the dispatch grace holds it (${detail}s of ${DISPATCH_GRACE_SECONDS}s)"
      return 0
      ;;
    unborn)
      log "left claimed $github#$number: a $VERB_TO_TICKETS issue is never handed back, and a worktree with no createdAt holds it"
      return 0
      ;;
    *)
      # `unreadable`, or nothing at all: never a handover.
      read_failed "$(gh_error_class "")" - "left claimed $github#$number: could not read the status of ${detail:-its worktrees}"
      return 0
      ;;
  esac
  PASS_HANDED_OVER+=" $github#$number "
  [[ "$escalation" == "unflagged" ]] || return 0

  if ! comments=$(gh_json "/repos/$github/issues/$number/comments" --paginate); then
    read_failed "$(gh_error_class "$comments")" "$github" \
      "spec handover record unreadable on $github#$number, flagging nothing this pass"
    return 0
  fi
  if ! seen=$(jq -r --arg me "$ME" --arg marker "$SPEC_HANDOVER_MARKER" \
       'any(.[]?; (.user.login // "") == $me and ((.body // "") | contains($marker)))' \
       <<< "$comments" 2>/dev/null) || [[ "$seen" != "true" && "$seen" != "false" ]]; then
    read_failed "$(gh_error_class "")" "$github" \
      "spec handover record unreadable on $github#$number, flagging nothing this pass"
    return 0
  fi

  if [[ "$seen" == "false" ]]; then
    if ! file=$(mktemp "${TMPDIR:-/tmp}/agent-loop-spec-handover.XXXXXX"); then
      FAILURE_TEXT=""
      status=1
    elif ! spec_handover_body "$why" > "$file"; then
      FAILURE_TEXT=""
      status=1
    else
      axi_write issue comment "$number" --repo "$github" --body-file "$file" || status=1
    fi
    [[ -z "$file" ]] || rm -f "$file"
    if (( status != 0 )); then
      class=$(gh_error_class "$FAILURE_TEXT")
      [[ "$class" != "refused" ]] \
        || die "spec handover record refused on $github#$number class=refused project=$github"
      write_failed "$class" - "" "" record "spec handover record failed on $github#$number, flagging nothing this pass"
      return 0
    fi
  fi

  if ! axi_write issue edit "$number" --repo "$github" --add-label "$LABEL_ESCALATED"; then
    class=$(gh_error_class "$FAILURE_TEXT")
    [[ "$class" != "refused" ]] \
      || die "spec handover flag refused on $github#$number class=refused project=$github"
    write_failed "$class" - "" "" flag "spec handover flag failed on $github#$number, the record is up and the next pass adds it"
    return 0
  fi
  set_claim_flag "$github" "$number" flagged
  log "handed over $github#$number: its $VERB_TO_TICKETS worker is gone with no sub-issue ($why), flagged $LABEL_ESCALATED, claim kept"
}

# spec_handover_body <why> — the handover's record, with what close-out derived.
spec_handover_body() {
  local why="$1"
  printf '**Escalated — this spec'"'"'s decomposition worker is gone, and no sub-issue is linked to it.**\n\n'
  printf 'The loop keeps `%s` on it and will not hand it back by itself: a worker that linked its children by prose alone leaves the sub-issue count at zero too, and handing this spec back would decompose it a second time.\n\n' "$LABEL_CLAIMED"
  printf '**What to do** — first look for child issues that point here by prose, such as a `## Parent` section. If there are some, link them to this issue as sub-issues, and the next pass unclaims it as `%s`. If there are none, swap `%s` for `%s` to decompose it again, or abandon the spec.\n\n' "$LABEL_DECOMPOSED" "$LABEL_CLAIMED" "$LABEL_READY"
  printf 'The loop takes `%s` off by itself on the pass it unclaims or claims this spec again. This comment is a record and stays.\n\n' "$LABEL_ESCALATED"
  printf 'What close-out derived: %s\n\n' "$why"
  printf '%s\n' "$SPEC_HANDOVER_MARKER"
}

# Close out a single merged pull request: tick the checklist in the linked
# issue's description, then close the issue — or, where GitHub already closed
# it, just drop the claim. Only acts on issues wearing the claim label that
# belong to configured projects. Silently skips pull requests opened by hand
# (branch names no issue) and issues the loop never claimed.
closeout_one() {
  local github="$1" prnumber="$2" branch="$3"
  local number issue state description ticked wore

  # A branch that names no issue is a pull request I opened by hand.
  number=$(issue_for_branch "$branch") || return 0

  # A pull request in a repository the config does not list is not the loop's
  # business.
  [[ -n "$(orca_id_for_project "$github")" ]] || return 0

  if ! issue=$(query_issue "$github" "$number"); then
    read_failed "$(gh_error_class "$issue")" "$github" "close-out query failed: $github#$number"
    SKIPS=$((SKIPS + 1))
    return 0
  fi

  # The claim label alone decides whether an issue is the loop's to touch, and
  # every merged pull request is read again on every pass, so saying otherwise
  # would be the same line forever: an issue the loop never claimed, and one
  # close-out has already finished with, both leave silently. The state is
  # deliberately not part of this test. Keying on `open` was the same silence
  # for a while, but a pull request whose body carries `Closes #N` has GitHub
  # close the issue at merge — a pass before close-out ever reads it — and that
  # guard then dropped the one case with work still in it, stranding the label
  # and the unticked checklist together. The unclaim is what makes the next
  # pass silent, so the label is the honest thing to key on.
  # `$label` would be a jq keyword, so the claim label rides in as `$claimed`.
  jq -e --arg claimed "$LABEL_CLAIMED" 'any(.labels[]?.name; . == $claimed)' <<< "$issue" \
    >/dev/null || return 0
  state=$(jq -r '.state' <<< "$issue")
  # Whether a refused write's flag is up, off the read already in hand.
  # A payload `query_issue` already vetted; the fallback is for `set -e`, and
  # reads as no flag, which withdraws nothing.
  wore=$(jq -r --arg esc "$LABEL_ESCALATED" \
    'if any(.labels[]?.name; . == $esc) then "flagged" else "unflagged" end' <<< "$issue") \
    || wore=unflagged

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
    # A refused tick flags the issue even though the close goes ahead: the
    # reader's action — tick it by hand — is real. Once the close lands this
    # write is never attempted again, so that flag stands until a human takes it
    # off, the one place a refused write's flag outlives its write.
    update_description "$github" "$number" "$ticked" \
      || write_failed "$(gh_error_class "$FAILURE_TEXT")" issue "$github" "$number" checklist \
           "checklist update failed for $github#$number, closing it out anyway"
  fi

  # GitHub got there first: it closed the issue at merge, on the strength of a
  # closing keyword in the pull request body. Only the unclaim is left, and it
  # is the whole of the work here — losing it means the pass finished nothing,
  # so it counts as a skip. An unclaim lost after a close of the loop's own is
  # not counted at the site that lost it, because the close it followed is what
  # the pass came to do; the issue then arrives back here on the next pass,
  # closed and still claimed, and is retried and counted from this branch until
  # the label comes off.
  if [[ "$state" != "open" ]]; then
    if unclaim_issue "$github" "$number"; then
      log "closed out $github#$number: pull request #$prnumber merged, issue already closed"
      withdraw_write_flag "$github" "$number" "$wore"
    else
      SKIPS=$((SKIPS + 1))
    fi
    return 0
  fi

  # The close is what stops the re-dispatch, so it happens whatever the
  # description write did: a lost tick costs a wrong-looking checklist, a lost
  # close costs a duplicate worker.
  if close_issue "$github" "$number"; then
    log "closed out $github#$number: pull request #$prnumber merged"
    withdraw_write_flag "$github" "$number" "$wore"
  else
    # A refused close is the forever-channel: *leaving it claimed* argues one
    # failed close, and a refused one never lands, so it flags the issue.
    write_failed "$(gh_error_class "$FAILURE_TEXT")" issue "$github" "$number" close \
      "close failed for $github#$number, leaving it claimed"
    SKIPS=$((SKIPS + 1))
  fi
}

# --- which build is running ---------------------------------------------------

# The stable identity used for drift comparison. This must be the full object ID:
# a fetch can introduce an abbreviation collision and lengthen `--short` without
# moving HEAD.
current_head() {
  git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null
}

# Short IDs are presentation only: they are read by eye off a log line and typed
# back into `git show <sha>:agent-loop.sh`.
short_commit() {
  git -C "$SCRIPT_DIR" rev-parse --short "$1" 2>/dev/null
}

# `build=` is what is loaded, measured once at start-up and never again. Bash
# parses the whole file before it can execute the pass loop, so EOF is reached
# before pass one and nothing is ever re-read: the bytes running now are the
# bytes on disk at start-up, whether an editor truncated the file in place or
# wrote-and-renamed it the way git does. One measurement is therefore exact for
# the life of the process rather than merely convenient.
#
# A sha rather than a hash of the loaded files, because the field has a second
# job a hash cannot do: `git show <sha>:agent-loop.sh` reads the code that
# parked.
#
# The `-dirty` suffix is not decoration. A dirty tree means the loaded bytes are
# not any commit, so the field stops claiming to name one.
#
# Every value is greppable and every failure is fail-safe: a read that cannot
# answer never lets the field claim a commit it cannot stand behind.
measure_build() {
  local head short dirty
  BUILD_COMMIT=""
  if ! head=$(current_head) || ! short=$(short_commit "$head"); then
    # No readable checkout: nothing can be said about what is loaded, and the
    # per-pass comparison has nothing to compare against either.
    BUILD="unknown"
    return 0
  fi
  # Unreadable is not clean: a dirty tree and a status read that failed both
  # leave the loaded bytes unpinnable to a commit.
  if ! dirty=$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null) || [[ -n "$dirty" ]]; then
    BUILD="$short-dirty"
  else
    BUILD="$short"
    BUILD_COMMIT="$head"
  fi
}

# `drift=` is whether the checkout has moved, derived every pass rather than
# frozen: the loop cannot re-read itself, but the disk under it changes.
#
# Named for the fact rather than the source, following the house pattern where
# the key stays put and the value carries the verdict — `edges=ok` /
# `edges=missing:...`, `action=nudged` / `action=failed rc=...`. Raw
# `build=X head=Y` would mean spotting drift by noticing two short hashes
# differ: workable on one line, useless across hundreds. `grep -v 'drift=none'`
# lists every stale pass in the log.
#
# Commentary on the tear `build=` does not cover: it covers the frozen pair only
# — this script, and the `gh.sh` sourced above. `pr-writeback.sh` is exec'd as a
# subprocess and re-read from disk on every invocation, and it sources its own
# fresh copy of `gh.sh`; config is frozen too, read once by `load_config`
# before the loop. So a stale loop is not uniformly stale — it runs old logic and
# new writebacks. During a drift window the daemon loop logic is running X, but
# the whole system is not necessarily running X: **X decides, Y writes**. A
# reader who assumes `build=` covers the whole system will misattribute a
# writeback bug to it.
current_drift() {
  local head short
  # A build that names no commit has nothing a head can be compared against.
  if [[ -z "$BUILD_COMMIT" ]]; then
    printf 'unknown'
    return 0
  fi
  if ! head=$(current_head); then
    printf 'unknown'
    return 0
  fi
  if [[ "$head" == "$BUILD_COMMIT" ]]; then
    printf 'none'
  elif short=$(short_commit "$head"); then
    printf '%s' "$short"
  else
    printf 'unknown'
  fi
}

# --- pass --------------------------------------------------------------------

# Run one complete pass: run closeout, issue, and PR phases on the worktree
# inventory readiness took, then sweep finished worktrees. Logs pass start, end,
# and summary.
run_pass() {
  log "pass start"
  DISPATCHES=0
  SKIPS=0
  SWEEPS=0
  # Appended after `sweeps` on the pass-end line, so every existing assertion on
  # that line still matches as a substring and no test had to be edited.
  REFUSALS=0
  # Every member of the failure family that did not die, counted by the two
  # entry points and by nothing else (#124). Its own field rather than a share
  # of `skips=`, which mixes the family with waits that are not failures at all
  # — the blocker skip, the budget defer, the sweep's non-failure rows — and so
  # cannot answer *did anything fail to read or write this pass*. After
  # `refusals=`, on that field's own precedent: every assertion on the line's
  # head still matches as a substring.
  FAILURES=0
  WRITE_ESCALATED_OBJECTS=""
  PASS_CLAIMS=''
  PASS_CLAIMS_READ=''
  PASS_HANDED_OVER=''
  PASS_OPEN_PRS=''
  PASS_OPEN_PRS_READ=''
  PASS_OPEN_PRS_FAILED=''
  PASS_NOW=$(date -u +%s)
  # Close-out first: an issue whose pull request has merged must be off the
  # board before the issue phase looks at the backlog again, and the reclaim it
  # carries must run before this pass dispatches anything, so it can never race
  # a dispatch of its own pass.
  closeout_phase
  # Counted off the snapshot the readiness check before this pass took, so the
  # budget has no unreadable branch to fail open or closed through: the pass
  # never starts on an inventory readiness could not read (#124). After
  # close-out, whose claim read releases a worker whose claim is gone, and
  # before the issue phase, so a released slot is dispatched into this pass
  # (#122).
  load_worker_facts
  ACTIVE_WORKERS=$(count_active_workers)
  issue_phase
  pr_phase
  # The snapshot is the one the pass opened with, so a worker that finished
  # mid-pass is swept by the next pass rather than this one.
  sweep_worktrees
  # `build=` and `drift=` are appended rather than led, and both are emitted
  # every pass even when they agree. A field that appeared only under drift
  # would leave a bare pass line ambiguous between *current* and *a build too
  # old to emit the field*; emitting it unconditionally makes its absence
  # positive evidence of a pre-stamp build.
  local drift
  drift=$(current_drift)
  LAST_DRIFT="$drift"
  log "pass end dispatches=$DISPATCHES skips=$SKIPS sweeps=$SWEEPS refusals=$REFUSALS failures=$FAILURES build=$BUILD drift=$drift"
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

STARTED_AT=$(date -u +%s)
require_tools
load_config

# A report is a read: it must answer while the daemon is running, so it never
# takes the lock — and it never writes the daemon's log either, or a report run
# by hand could rotate that log out from under the daemon.
if [[ -n "$BRANCH_REPORT" ]]; then
  LOG_PATH=""
  # Readiness took the inventory the report reads.
  ensure_runtime
  load_repos
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
# Measure before the first pass: a pass can outlive this checkout state, while
# BUILD must name the bytes this process actually loaded. Nothing runs close-out
# or the reclaim ahead of the passes any more: the first pass covers what
# startup did (#136).
measure_build

# The began-passing flag, set immediately before the pass loop: from here on
# nobody is at the keyboard, so a non-zero exit files a death record (#129).
# Not under `--once`, which is a run a human started and is watching.
$ONCE || BEGAN_PASSING=true
while true; do
  ensure_runtime
  run_pass
  PASSES=$((PASSES + 1))
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
