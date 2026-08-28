# agent-loop

A bash daemon that polls GitHub, dispatches [Orca](https://orca.computer) agent workers at issues labelled ready, and drives CodeRabbit's own autofix at the findings on open pull requests.

Started by hand, runs until Ctrl-C. Every decision it makes is one log line, so silence means nothing happened rather than something was swallowed.

---

## What it does

Each pass, in order:

1. **Close-out** — an issue whose pull request has merged gets its checklist ticked, its description updated, its claim label removed, and the issue closed.
2. **Issues** — queries each project for open issues labelled `ready-for-agent`, skips ones with an open blocker, swaps the label to `agent-in-progress`, and dispatches an Orca worker into a fresh worktree.
3. **Pull requests** — enumerates every open pull request in each project except drafts and fork heads, derives its state from GitHub alone, logs one line per pull request, comments `@coderabbitai autofix` at the ones carrying unresolved findings, runs the risk gate over the ones that are ready to judge, merges at most one of them per repository, and hands over the ones it will not act on. It spends no worker and no worktree, and it keeps no local state: every pass re-derives from a fresh read.
4. **Sweep** — removes the loop's own finished worktrees.

Between passes it sleeps for `pollIntervalSeconds`.

### Guard rails

- **Worker budget** — never more than `maxWorkers` live workers. Checked before *every* issue dispatch, not once per pass, so a candidate arriving at a full budget waits for a later pass rather than being dropped. It governs **issue dispatch only**: the PR phase spends no worktree, no checkout and no agent, so a long-running issue does not stall the pull requests behind it.
- **Fail closed** — if the worktree inventory can't be read, the budget is treated as full and the sweep is skipped. A budget that failed open would dispatch a fresh `maxWorkers` on top of the workers it couldn't see.
- **PID lock** — one loop per machine.
- **Startup reclaim** — an issue left claimed with no live worker (crash, failed dispatch) is handed back to `ready-for-agent` when the loop next starts.
- **Once per head commit** — the autofix trigger records its input head, and the matching autofix-status comment spends that head. Reviews are metered, and a poll loop that re-fired every pass would burn that budget; generated output commits and failure prose are never used as the input identity.
- **The risk gate** — a pull request that is ready to judge goes through four independent vetoes over its head commit, and there are three outcomes. **CodeRabbit's verdict is a necessary input, not the verdict**: the reviewer judges the code, the loop judges blast radius and merge mechanics, and each holds a veto.
  - **V1 — CodeRabbit's verdict.** Its merge-risk block must name a commit abbreviation that is a prefix of the head, and put the level at exactly *minimal*. An unrecognised level, an unparseable line or a stale commit all escalate — the tripwire for CodeRabbit changing shape.
  - **V2 — checks.** *Every* rollup context green, not just the required ones: with no branch protection, required-ness is always false, so a required-only rule would leave no check able to block a merge. A check that has not reported yet defers rather than blocking; one that ran and declined to judge — skipped or neutral — counts as green, which is what GitHub itself says about the same commit.
  - **V3 — mergeability.** GitHub must report the pull request both mergeable *and* clean; `mergeable` alone is true of the unstable and blocked states too. A branch that is **behind is never updated** — that write would move the head, void the verdict just validated, and spend metered review budget re-reviewing it.
  - **V4 — blast radius.** Any change under `.github/workflows/`, or to `agent-loop.sh`, `pr-writeback.sh` or `gh.sh`, escalates. The principle is *never minimal if merging it changes what runs unattended*. There is **no diff-size ceiling** — a big change is not a risky one. A pull request touching more than 100 files escalates all the same, on the different ground that the read carries one page and merging on a file list known to be partial would let exactly the change this veto looks for slip past the page boundary.
  - **V5 — the clock.** `defer` is the third outcome and is not a failure: a check still running, or a mergeability GitHub has not finished computing, is re-derived next pass in silence. `mergeGateTimeoutSeconds` from the head commit's date is what stops that being forever. A pull request whose review is merely rate-limited defers too — ahead of every veto, and exempt from that clock, because the rate limit self-clears on its own.

  All four vetoes evaluate — nothing short-circuits — and **escalate beats defer**, so one handover carries every reason, the ones that passed included. The gate **never reads the pull request's reviews** and **never parses CodeRabbit's pre-merge checks**.
- **The merge names the commit the gate assessed** — never the head as GitHub reports it at the moment of the write. The seam sends it as an assertion GitHub compares against the head, so a push that raced the gate loses with a 409 and escalates instead of being merged unreviewed. Branch deletion needs no key and no call: the repository's delete-on-merge setting is honoured by GitHub on the merge itself.
- **At most one merge per repository per pass.** A merge changes the base under every other open pull request in that repository, invalidating mergeability, check results and the commit each verdict was scoped to — so the loop merges once and lets the next pass re-derive. The candidates it held are logged as deferred. Other repositories are unaffected, and non-merge actions stay unbounded. A merge GitHub **refuses** escalates as its own kind, `refused`, carrying GitHub's answer verbatim: *I said yes and reality disagreed* is evidence the rubric is wrong. A merge that fails **transiently** is neither escalated nor retried within the pass — the poll interval is the whole of the backoff.
- **Escalation is a handover, not a notification** — the loop acts as the operator's own account, and GitHub never notifies you of your own actions, so no arrangement of writes can push one. A pull request the loop will not act on gets a comment carrying every reason and the raw values behind it, then the `agent-escalated` label, in that order — the record first, so a missing flag is re-added on a later pass without the record being posted twice. Once escalated at a head commit the loop takes **no further action on that pull request at that commit**. The three ways back in are the ones GitHub already gives you: merge it by hand, push a commit, or convert it to draft. There is no override label; a push is both the fix and the re-engagement.
- **Log rotation** — one generation, capped at 5 MiB. A loop left running for weeks must not fill the disk.

### Pull-request writes use one seam

The PR phase triages GitHub state without a worker or worktree and sends each selected action through `pr-writeback.sh`. It creates no local fix commits, worker plans, or plan-confirmation step.

`pr-writeback.sh` is the **only** thing that writes to a pull request: it posts CodeRabbit commands, comments and labels, and performs guarded merges. Its merge verb is the loop's one irreversible unattended write, and `--no-merge` is what holds it.

---

## Requirements

- `bash`, `jq`, `git`, `base64`
- [`orca`](https://orca.computer) — the agent runtime, running and reachable
- [`gh-axi`](https://github.com/kunchenguid/axi) — `npm install -g gh-axi`, over a `gh` that is authenticated against github.com

gh-axi renders every answer as TOON and has no JSON output mode, so the scripts
read it through one seam: `--jq 'tojson|@base64' --full`, which is the single
shape TOON has nothing left to restructure. `gh.sh` holds that seam — `gh_json`
decodes it and everything downstream is ordinary jq over ordinary JSON — and
both scripts source it rather than carrying their own copy. Labels are written
as deltas (`issue edit --add-label/--remove-label`) rather than as a whole set,
which is what keeps the claim a single atomic call.

The loop creates its three labels — the two in the config, and the constant
`agent-escalated` — in each configured repository at startup if they are not
already there.

---

## Setup

```bash
git clone https://github.com/nywleswoey/agentloop.git
cd agentloop
cp agent-loop.config.example.json agent-loop.config.json
```

Then edit `agent-loop.config.json`:

```json
{
  "pollIntervalSeconds": 300,
  "maxWorkers": 3,
  "autofixTimeoutSeconds": 5400,
  "mergeGateTimeoutSeconds": 3600,
  "logPath": "~/.agent-loop/agent-loop.log",
  "labels": {
    "ready": "ready-for-agent",
    "claimed": "agent-in-progress"
  },
  "projects": [
    {
      "github": "your-owner/your-repo",
      "orcaRepoId": "00000000-0000-0000-0000-000000000000",
      "mergeMethod": "squash"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `pollIntervalSeconds` | Sleep between passes. |
| `maxWorkers` | Hard cap on live workers across all projects. Governs **issue dispatch only** — the PR phase spends no worker. |
| `autofixTimeoutSeconds` | How long a triggered autofix has to report before the loop calls it stalled. **Required; nothing defaults it.** An admitted guess: the only measurement behind it is a single 17m 35s run, which the research explicitly declined to derive a timeout from. |
| `mergeGateTimeoutSeconds` | How long the risk gate will keep deferring a pull request whose signals are not computed yet, measured from the head commit's date. **Required; nothing defaults it.** An admitted guess with **no sample at all** behind this use of it — the only measurements anywhere near it are a four-second and a hundred-and-five-second review window, which is a different wait. |
| `logPath` | Append-only log. Rotated at 5 MiB, one generation kept. |
| `labels.ready` | Label the loop picks issues up by. |
| `labels.claimed` | Label the loop swaps in once it claims an issue. |
| `projects[].github` | GitHub repository, as `<owner>/<name>`. |
| `projects[].orcaRepoId` | Orca repo UUID that project maps to. |
| `projects[].mergeMethod` | `merge`, `squash` or `rebase` — how the loop merges in that repository. **Required, per repository, and validated at startup** against the repository's own permission booleans, because GitHub exposes no default-merge-method field to read one from. A method the repository forbids fails at second zero rather than coming back as a refusal at the merge, where it would be indistinguishable from the gate having been wrong. |

`agent-loop.config.json` is gitignored — it holds your own project paths and repo IDs.

---

## Usage

```bash
# Run until Ctrl-C
./agent-loop.sh

# One pass, then exit
./agent-loop.sh --once

# Everything except the merge. A dry run when paired with --once: the gate still
# judges and logs the verdict it would have acted on, and every reversible write
# still happens. There is deliberately no config key for this — a persistent
# switch would be the confirmation gate this replaced coming back as a boolean,
# and a `false` left in a file is a forgettable bypass.
./agent-loop.sh --once --no-merge

# Who holds this branch, in each configured project?
# Reports and exits — takes no lock, runs no pass.
./agent-loop.sh --branch-report my-branch

# Different config file
./agent-loop.sh --config /path/to/other.json
```

### Environment overrides

For tests and troubleshooting:

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_LOOP_CONFIG` | `agent-loop.config.json` beside the script | Config path. |
| `AGENT_LOOP_LOG_MAX_BYTES` | `5242880` | Log size cap before rotation. |
| `AGENT_LOOP_RUNTIME_WAIT_SECONDS` | `60` | How long to wait for the Orca runtime. |

---

## Writing back to a pull request

The PR worker leaves a plan behind. Review it, set `"confirmed": true` on the entries you accept, then:

```bash
./pr-writeback.sh --plan plan.json --repo /path/to/worktree --seen-list ~/.agent-loop/seen.jsonl
```

Plan shape:

```json
{
  "repo": "your-owner/your-repo",
  "prNumber": 517,
  "sourceBranch": "my-branch",
  "baseSha": "<branch tip before the worker committed anything>",
  "threads": [
    { "thread": "<node id>", "verdict": "FIX", "lastCommentId": 900001,
      "commit": "<local sha>", "summary": "<one sentence>",
      "confirmed": true },
    { "thread": "<node id>", "verdict": "REFUSE", "lastCommentId": 900002,
      "reply": "**Disagree** — ...", "confirmed": false },
    { "thread": "<node id>", "verdict": "ANSWER", "lastCommentId": 900003 }
  ]
}
```

| Option | Meaning |
|---|---|
| `--plan <path>` | The triage plan the worker wrote and the operator confirmed. |
| `--repo <path>` | Worktree holding the PR's head branch. Defaults to cwd. |
| `--seen-list <path>` | Append one line per thread this run leaves silent, so the loop stops re-dispatching at it until a reply lands. Nothing is recorded if omitted. |

| Verdict | Confirmed | What happens |
|---|---|---|
| `FIX` | yes | Commit is pushed, a reply cites it, the thread is resolved. |
| `REFUSE` | yes | Reply is posted, thread left unresolved — the reviewer keeps the last word. |
| `ANSWER` / `ESCALATE` | — | Reported only. Nothing written; the thread goes on the seen list. |
| any | no | Nothing written. The seen list is the only record. |

A malformed confirmed entry aborts the whole run rather than half-writing a thread — a `FIX` with no commit would push nothing and still say "Fixed in".

---

## Tests

```bash
./tests/test-agent-loop.sh
./tests/test-pr-writeback.sh
./tests/test-gh.sh
```

The first two run the real scripts against stub CLIs in `tests/bin` (`git`, `gh-axi`, `orca`, `date`) and assert on the log lines emitted and the argv handed to those stubs. No function inside either script is reached into directly.

Time is one of those stubs. `date` is a CLI, so `$STUB_NOW` freezes what "now" is for a case without the scripts gaining a single line of test-only surface — they keep calling `date` as they always have. The binding that buys: **time comes from `date(1)`, never from a shell built-in.** `printf '%(%s)T'`, `$SECONDS` and `$EPOCHSECONDS` bypass `PATH` silently, and a timeout test that quietly runs against wall time is green for the wrong reason forever. The suite pins that rule with a check over the scripts' own source — the one assertion in the project that reads code rather than behaviour, because this is the one property no behaviour can reveal.

`test-gh.sh` is the one exception, and the only one: it sources `gh.sh` and calls `gh_error_class` directly. The classifier is a pure table over error text whose value is that every row is right, and the rows that matter most — a 405 refusing a draft merge, a 409 losing a race with a push — are ones no stub run produces as a side effect. `gh_json` and `gh_graphql` are reached here for one thing alone — that the failure text they capture survives to the caller, on each of the two channels a caller can read it from. Everything else about them is tested only through the two scripts that call them, which is what keeps them from drifting back into two copies.

---

## Layout

```
agent-loop.sh                     the daemon
pr-writeback.sh                   the only writer to GitHub review threads
gh.sh                             the GitHub seam, sourced by both
agent-loop.config.example.json    copy this to agent-loop.config.json
tests/
  lib.sh                          shared assertions
  test-agent-loop.sh              daemon suite
  test-pr-writeback.sh            writeback suite
  test-gh.sh                      the seam's error classifier
  bin/                            stub git, gh-axi, orca, date
  fixtures/                       canned CLI responses
    worlds/                       whole-world snapshots, one per replayed pass
```

---

## Licence

MIT — see [LICENSE](LICENSE).
