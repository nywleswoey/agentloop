# agent-loop

A bash daemon that polls GitLab and dispatches [Orca](https://orca.computer) agent workers at anything workable — issues labelled ready, and merge requests carrying unresolved review threads.

Started by hand, runs until Ctrl-C. Every decision it makes is one log line, so silence means nothing happened rather than something was swallowed.

---

## What it does

Each pass, in order:

1. **Close-out** — an issue whose merge request has merged gets its checklist ticked, its description updated, its claim label removed, and the issue closed.
2. **Issues** — queries each project for open issues labelled `ready-for-agent`, skips ones with an open blocker, swaps the label to `agent-in-progress`, and dispatches an Orca worker into a fresh worktree.
3. **Merge requests** — finds open MRs with unresolved threads that the loop has not already triaged, and dispatches a thread-triage worker at them.
4. **Sweep** — removes the loop's own finished worktrees.

Between passes it sleeps for `pollIntervalSeconds`.

### Guard rails

- **Worker budget** — never more than `maxWorkers` live workers. Checked before *every* dispatch, not once per pass, so a candidate arriving at a full budget waits for a later pass rather than being dropped.
- **Fail closed** — if the worktree inventory can't be read, the budget is treated as full and the sweep is skipped. A budget that failed open would dispatch a fresh `maxWorkers` on top of the workers it couldn't see.
- **PID lock** — one loop per machine.
- **Startup reclaim** — an issue left claimed with no live worker (crash, failed dispatch) is handed back to `ready-for-agent` when the loop next starts.
- **Seen list** — a review thread the loop deliberately left silent is recorded with its newest note id, so the next pass can tell "already triaged, nothing new" from "never looked at".
- **Log rotation** — one generation, capped at 5 MiB. A loop left running for weeks must not fill the disk.

### Nothing is written to GitLab without confirmation

An MR worker triages threads, prepares a local commit per fix, writes a plan, and stops. Nothing reaches GitLab until the operator marks entries `confirmed` and runs `mr-writeback.sh` against that plan.

`mr-writeback.sh` is the **only** thing that pushes a worker's fixes or writes to a review thread. Keeping every write in one script is what makes "nothing before confirmation" checkable rather than a promise.

---

## Requirements

- `bash`, `jq`, `git`
- [`orca`](https://orca.computer) — the agent runtime, running and reachable
- `glab-axi` — GitLab CLI wrapper, authenticated against your GitLab host

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
  "seenListPath": "~/.agent-loop/seen.jsonl",
  "logPath": "~/.agent-loop/agent-loop.log",
  "labels": {
    "ready": "ready-for-agent",
    "claimed": "agent-in-progress"
  },
  "projects": [
    {
      "gitlab": "your-group/your-project",
      "orcaRepoId": "00000000-0000-0000-0000-000000000000"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `pollIntervalSeconds` | Sleep between passes. |
| `maxWorkers` | Hard cap on live workers across all projects. |
| `seenListPath` | Where triaged-and-silent threads are recorded. |
| `logPath` | Append-only log. Rotated at 5 MiB, one generation kept. |
| `labels.ready` | Label the loop picks issues up by. |
| `labels.claimed` | Label the loop swaps in once it claims an issue. |
| `projects[].gitlab` | GitLab project path. |
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
| `AGENT_LOOP_TUI_WAIT_MS` | `60000` | How long a reused terminal gets to boot its agent before the prompt is typed. |

---

## Writing back to a merge request

The MR worker leaves a plan behind. Review it, set `"confirmed": true` on the entries you accept, then:

```bash
./mr-writeback.sh --plan plan.json --repo /path/to/worktree --seen-list ~/.agent-loop/seen.jsonl
```

Plan shape:

```json
{
  "project": "your-group/your-project",
  "projectId": 57981,
  "mrIid": 517,
  "sourceBranch": "my-branch",
  "baseSha": "<branch tip before the worker committed anything>",
  "threads": [
    { "discussion": "<id>", "verdict": "FIX", "lastNoteId": 900001,
      "commit": "<local sha>", "summary": "<one sentence>",
      "confirmed": true },
    { "discussion": "<id>", "verdict": "REFUSE", "lastNoteId": 900002,
      "reply": "**Disagree** — ...", "confirmed": false },
    { "discussion": "<id>", "verdict": "ANSWER", "lastNoteId": 900003 }
  ]
}
```

| Option | Meaning |
|---|---|
| `--plan <path>` | The triage plan the worker wrote and the operator confirmed. |
| `--repo <path>` | Worktree holding the MR's source branch. Defaults to cwd. |
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
./tests/test-mr-writeback.sh
```

Both suites run the real scripts against stub CLIs in `tests/bin` (`git`, `glab-axi`, `orca`) and assert on the log lines emitted and the argv handed to those stubs. The stub directory is the only seam — no function inside the scripts is reached into directly.

---

## Layout

```
agent-loop.sh                     the daemon
mr-writeback.sh                   the only writer to GitLab review threads
agent-loop.config.example.json    copy this to agent-loop.config.json
tests/
  lib.sh                          shared assertions
  test-agent-loop.sh              daemon suite
  test-mr-writeback.sh            writeback suite
  bin/                            stub git, glab-axi, orca
  fixtures/                       canned CLI responses
```

---

## Licence

MIT — see [LICENSE](LICENSE).
