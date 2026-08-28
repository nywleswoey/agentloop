# agent-loop

A bash daemon that polls GitHub, dispatches [Orca](https://orca.computer) agent workers at issues labelled ready, and drives CodeRabbit's own autofix at the findings on open pull requests.

Started by hand, runs until Ctrl-C. Every decision it makes is one log line, so silence means nothing happened rather than something was swallowed.

---

## What it does

Each pass, in order:

1. **Close-out** — an issue whose pull request has merged gets its checklist ticked, its description updated, its claim label removed, and the issue closed.
2. **Issues** — queries each project for open issues labelled `ready-for-agent`, skips ones with an open blocker, swaps the label to `agent-in-progress`, and dispatches an Orca worker into a fresh worktree.
3. **Pull requests** — enumerates every open pull request in each project except drafts and fork heads, derives its state from GitHub alone, logs one line per pull request, and comments `@coderabbitai autofix` at the ones carrying unresolved findings. It spends no worker and no worktree, and it keeps no local state: every pass re-derives from a fresh read.
4. **Sweep** — removes the loop's own finished worktrees.

Between passes it sleeps for `pollIntervalSeconds`.

### Guard rails

- **Worker budget** — never more than `maxWorkers` live workers. Checked before *every* issue dispatch, not once per pass, so a candidate arriving at a full budget waits for a later pass rather than being dropped. It governs **issue dispatch only**: the PR phase spends no worktree, no checkout and no agent, so a long-running issue does not stall the pull requests behind it.
- **Fail closed** — if the worktree inventory can't be read, the budget is treated as full and the sweep is skipped. A budget that failed open would dispatch a fresh `maxWorkers` on top of the workers it couldn't see.
- **PID lock** — one loop per machine.
- **Startup reclaim** — an issue left claimed with no live worker (crash, failed dispatch) is handed back to `ready-for-agent` when the loop next starts.
- **Once per head commit** — the autofix trigger fires at most once per head, derived from an autofix-status comment landing newer than the head commit. Reviews are metered, and a poll loop that re-fired every pass would burn that budget; a failed or declined autofix falls through on the same term, with none of CodeRabbit's prose parsed.
- **Log rotation** — one generation, capped at 5 MiB. A loop left running for weeks must not fill the disk.

### Nothing is written to GitHub without confirmation

A PR worker triages threads, prepares a local commit per fix, writes a plan, and stops. Nothing reaches GitHub until the operator marks entries `confirmed` and runs `pr-writeback.sh` against that plan.

`pr-writeback.sh` is the **only** thing that pushes a worker's fixes or writes to a review thread. Keeping every write in one script is what makes "nothing before confirmation" checkable rather than a promise.

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

The loop creates its two labels in each configured repository at startup if they
are not already there.

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
  "logPath": "~/.agent-loop/agent-loop.log",
  "labels": {
    "ready": "ready-for-agent",
    "claimed": "agent-in-progress"
  },
  "projects": [
    {
      "github": "your-owner/your-repo",
      "orcaRepoId": "00000000-0000-0000-0000-000000000000"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `pollIntervalSeconds` | Sleep between passes. |
| `maxWorkers` | Hard cap on live workers across all projects. Governs **issue dispatch only** — the PR phase spends no worker. |
| `autofixTimeoutSeconds` | How long a triggered autofix has to report before the loop calls it stalled. **Required; nothing defaults it.** An admitted guess: the only measurement behind it is a single 17m 35s run, which the research explicitly declined to derive a timeout from. |
| `logPath` | Append-only log. Rotated at 5 MiB, one generation kept. |
| `labels.ready` | Label the loop picks issues up by. |
| `labels.claimed` | Label the loop swaps in once it claims an issue. |
| `projects[].github` | GitHub repository, as `<owner>/<name>`. |
| `projects[].orcaRepoId` | Orca repo UUID that project maps to. |

`agent-loop.config.json` is gitignored — it holds your own project paths and repo IDs.

---

## Usage

```bash
# Run until Ctrl-C
./agent-loop.sh

# One pass, then exit
./agent-loop.sh --once

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
