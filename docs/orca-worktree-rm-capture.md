# What `orca worktree rm` does to a branch it cannot prove is merged

Captured 2026-09-12 against the installed Orca CLI, for
[issue #135](https://github.com/nywleswoey/agentloop/issues/135).

`agent-loop.sh:1958` leans its whole safety argument on one sentence of
`orca worktree rm --help`, and
[#125](https://github.com/nywleswoey/agentloop/issues/125) now removes worktrees
carrying unpushed commits on the strength of it:

> For Git worktrees, removal also attempts to delete the checked-out local
> branch, with or without `--force`. Orca retains branches it knows predated the
> worktree and any branch whose changes it cannot prove are already merged.

Nothing about this CLI is documented — there is no `--version` flag, and
`orca --version` prints the usage banner — so the sentence was the only evidence
that committed work survives a sweep. This is the demonstration it owed.

Every removal below was run the way `agent-loop.sh:1964` runs it, with no
`--force`:

```
orca worktree rm --worktree "path:$path" --json
```

## What happened

| # | worktree state | HEAD vs `main` | on `origin`? | delivered? | `preservedBranch` | local branch after |
|---|---|---|---|---|---|---|
| A | one commit, never pushed | ahead 1 | no | no | **present** | **survived** |
| B | one commit, pull request **squash**-merged, head branch deleted by GitHub | ahead 1 | no longer | yes | **present** | **survived** |
| C | one commit, branch pushed, no pull request | ahead 1 | yes | no | **present** | **survived** |
| D | one commit, a true ancestor of another `origin` branch | ahead 1 | via that branch | — | **present** | **survived** |
| E | no commits at all | equal | n/a | n/a | absent | deleted |

Every one of the five: exit status `0`, `"removed": true`, empty stderr, the
directory gone, and the `git worktree` registration gone with it.

## The three answers the ticket asked for

**The branch survives, and the response names it.** Case A is the one the
sentence promised and the one `#125` Row A leans on. The response is
`tests/fixtures/orca-worktree-rm-preserved.json`:

```json
{
  "ok": true,
  "result": {
    "removed": true,
    "preservedBranch": {
      "branchName": "nywleswoey/wf135-capture-unpushed",
      "head": "04e4351f4b2f13b7f364c1566b5634dd4803c844"
    }
  }
}
```

The commit was still readable from the loop's own checkout afterwards, by
branch name and by sha, with its file content intact. **Removal and retention
are not a fork**: the worktree goes *and* the branch stays, in one call that
exits `0`. A retained branch does not fail the removal, so the sweep's
`sweep failed for $path, leaving it in place` arm is not the arm this case
takes.

**The removal goes to a trash directory that does not keep anything.**
`agent-loop.sh:1960` says *"What it removes goes to a trash directory, not to
nothing."* There is such a directory —
`<workspaces>/<repo>/.orca-worktree-trash`, created 2026-08-29 and touched at
the instant of each removal — and it is **empty at rest**, before and after
every removal captured here, including hidden entries. It is a staging area that
is emptied, not a recycle bin. Nothing in a removed worktree is recoverable from
it; what survives a removal survives as a git branch, in the repository's object
store, or not at all. The working tree itself is gone — which is what the
sweep's own `uncommitted changes` skip already exists to protect.

**Orca's merge proof does not see a squash merge — and it does not need to.**
Case B is the case `#125` Row A actually meets in the field, since the running
config's `mergeMethod` is `squash`: the pull request merged, GitHub deleted the
head branch (`delete_branch_on_merge` is `true` on this repository), and the
branch's own commit is on no `origin` branch. Orca still returned
`preservedBranch`. So does case C, a pushed branch. So does case D, whose commit
is a genuine ancestor of an `origin` branch. The only branch Orca deleted was
case E, which was level with its base.

One model fits all five: **Orca preserves the local branch whenever HEAD is
ahead of the base branch the worktree was created from**, and deletes it only
when there is nothing ahead. Pushed, unpushed, squash-merged, merge-merged: it
retains. The sentence is true, and it is *more* conservative than it reads —
"cannot prove are already merged" turns out to mean "is not an ancestor of the
base", which no squash merge ever satisfies.

## What that costs, and what it buys

It buys `#125` Row A outright: **no capture here destroyed a commit**, and the
one case that matters most — delivered work whose commits are on no remote —
came back with the branch named in the response. The removal does not need
Orca's word to be narrow; it is broad.

The cost is residue. Because Orca retains in *every* delivered case under a
squash merge, each swept worktree that ever held a commit leaves **one dead
local branch in the loop's checkout, forever**. This is not hypothetical:
the loop's own checkout carries 11 local branches that neither an `origin`
branch nor a live worktree accounts for, three of them Orca-named
(`worktree-agent-<hex>`). Nothing collects them, and the sweep's removal is what
creates them.

## A second finding the sweep should know about

The pin the whole of `#125` is about — `N commits not on the remote` — **forms
only after something prunes**. `agent-loop.sh`, `gh.sh` and `pr-writeback.sh`
contain no `git fetch` and no `--prune` at all, and the sweep's count reads local
remote-tracking refs:

```
git -C "$path" rev-list --count HEAD --not --remotes=origin
```

Measured on case B, across the prune and nothing else:

| moment | `refs/remotes/origin/<branch>` | count |
|---|---|---|
| immediately after the squash merge | still present, stale | **0** |
| after `git fetch --prune origin` | gone | **1** |

So between a squash merge and the next prune, the worktree sweeps as an ordinary
`swept`, with no pin and no log line. The pin's 12 occurrences in 513 passes are
therefore a count of *pruned* checkouts, not of delivered worktrees, and the
pruner is never the loop.

## Provenance

The squash-merge case used a throwaway pull request against a throwaway base
branch, so `main` was never touched:
[#139](https://github.com/nywleswoey/agentloop/pull/139), base `wf135-base`,
squash-merged and its head branch deleted. All five worktrees, both throwaway
remote branches and every local branch created for the capture have been
removed; `PR #139` is left in place as the record.
