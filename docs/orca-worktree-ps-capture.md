# What `orca worktree ps --json` returns, and where the `orca-ps-*` worlds come from

Captured 2026-09-14 against **Orca 1.4.200**, for
[issue #156](https://github.com/nywleswoey/agentloop/issues/156), step 5 of
[#149](https://github.com/nywleswoey/agentloop/issues/149)'s build order.

[#130](https://github.com/nywleswoey/agentloop/issues/130) found that
`tests/fixtures/orca-ps-sweep.json` was a hand-cut stub: four keys of a record
Orca sends with 34, and none of its timestamps. This is the capture that
replaces it, and the rule every world is cut from it by.

## Version stamp

| source | value |
|---|---|
| `orca --version` | `1.4.200` |
| `orca status --json` → `.result.runtime.appVersion` | `1.4.200` |
| `/Applications/Orca.app/Contents/Info.plist` `CFBundleShortVersionString` | `1.4.200` |

#130 recorded that the CLI had no `--version` flag at 1.4.193. At 1.4.200 it
has one, and it agrees with the bundle.

The read is the one `load_worktree_inventory` takes:

```
orca worktree ps --json
```

## What came back

Five worktrees: one Orca created (this ticket's own worktree, its agent
`working`) and four main worktrees of repositories imported by path.

| | worktree keys | `createdAt` | `creatorProvenance` |
|---|---|---|---|
| non-main (`isMainWorktree: false`) | 35 | epoch-ms integer | present |
| main (`isMainWorktree: true`) | 33 | **absent** | absent |

That is #130's finding again, one version later: `createdAt` is absent exactly on
the main worktree, which `is_loop_worktree` already excludes, and present on
the worktree Orca created. #130 wrote "34 worktree-level keys", but its own
census lists 33 on every worktree plus `createdAt` and `creatorProvenance` on
the Orca-created one, which is these same 35.

Every agent record carried the same 13 keys: `agentType`, `displayName`,
`interrupted`, `lastAssistantMessage`, `paneKey`, `parentPaneKey`, `prompt`,
`state`, `stateStartedAt`, `taskTitle`, `toolInput`, `toolName`, `updatedAt`.
#130's `workingMode`, seen on one agent of three, did not appear.

Still undocumented: no bundled guide and no `--help` names a response field, so
everything here is observed, not promised.

## `tests/fixtures/orca-ps-capture.json`

The capture itself. Scrubbed of what identifies this host and nothing else:

- `path` rewritten under `/tmp/stub/`, and `worktreeId` rebuilt from it as
  `<repoId>::<path>`, which is the shape Orca sent;
- the main worktrees' `repo` names replaced with `repo-<n>`;
- free text an agent or terminal wrote — `preview`, `agents[].prompt`,
  `agents[].lastAssistantMessage`, `agents[].toolInput` — replaced with stub
  strings.

Every key, type, `null` and number is as Orca sent it, including the top-level
`id` and `_meta`. It is also a world: `STUB_ORCA_PS=capture` feeds it to the
loop unaltered, and `the captured payload reads as one live loop worker` holds
the loop to reading its one Orca-created, `working` worktree as a live worker.

## How the worlds are cut

Each `orca-ps-*` world keeps the worktrees, paths and agent states it always had,
and every record in it is a record from the capture: the non-main one for an
Orca-created worktree, a main one for `…/main`. The envelope is the capture's,
with its top-level `id` set to `stub-worktree-ps`. Only these fields are
substituted:

- `worktreeId`, `repoId`, `path`, `repo`, `displayName`, `branch` and
  `worktreeInstanceId` — identity;
- `createdAt`, and `sortOrder` and `lastActivityAt` with it — a distinct
  epoch-ms per worktree, whole hours before the captured `createdAt`;
- `agents[].state` — each agent is the captured agent record with its state
  set, and its free text scrubbed as above.

Everything else — `status`, `workspaceStatus`, `liveTerminalCount`,
`hasAttachedPty`, `stateStartedAt` and the rest — is carried from the captured
record verbatim, and **was not re-observed for the substituted state**. The
loop reads none of them; a consumer that starts to should capture the state it
reads first.

The suite holds every world to this: `the orca-ps worlds are cut from a capture
that records its Orca version` checks that each carries exactly the capture's
key sets, dates every non-main worktree in epoch-ms and no main one, and names
each worktree `<orcaRepoId>::<path>`.

Three records are deliberately not what Orca sends, and each world says why:

| world | record | why |
|---|---|---|
| `orca-ps-malformed` | the whole payload: `worktrees` is an object | readiness must refuse a truthy non-array |
| `orca-ps-idle` | `repo-bbb::`, a main record with `path: null` | the projection drops a worktree with no path |
| `orca-ps-created-unknown` | the sweep world with `createdAt` removed on `agent-loop-issue-31`, a date string on `-32`, `null` on `-33` and fractional on `-pr-35` | a missing or unparseable origin must not crash the inventory |

## What the inventory projects

`orca_worktrees` prints one line per worktree with a path:

```
<live|idle>	<path>	<createdAt>	<worktreeId>
```

What `unknown` covers, and why never agent `stateStartedAt`, is argued once, at
`orca_worktrees` in `agent-loop.sh`.
