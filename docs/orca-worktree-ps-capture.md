# What `orca worktree ps` actually returns

Captured 2026-09-14 against Orca **1.4.200**, for
[issue #156](https://github.com/nywleswoey/agentloop/issues/156). The version is
`orca status --json`'s `.result.runtime.appVersion`: the CLI has no `--version`
flag (see [the removal capture](orca-worktree-rm-capture.md)).

[#130](https://github.com/nywleswoey/agentloop/issues/130) found that the
`orca-ps-*` stub fixtures carried `worktreeId`, `path`, `agents[].state` and
`agents[].agentType` and nothing else, and read that as the payload having no
timestamp. The fixtures were hand-cut; the payload is not that small. Every
projection is now tested against the shape below.

Both captures were run the way `load_worktree_inventory` runs it:

```
orca worktree ps --json
```

1. **The live inventory**, as it stood: one non-main worktree carrying a
   `working` Claude agent, and four main worktrees with no agents.
2. **A worktree created the way `dispatch_issue` creates one** —
   `orca worktree create --repo id:<orcaRepoId> --name agent-loop-capture-156 --no-parent --json`,
   without `--agent`, so no agent was spent on it — read back with `ps`, then
   removed with `orca worktree rm --worktree path:<path> --json`. It held no
   commits, so the removal deleted its branch too, and nothing was left behind.

## The envelope

```json
{
  "id": "<uuid>",
  "ok": true,
  "result": {
    "worktrees": [ … ],
    "hostScope": { "hostIds": ["local"], "omittedHostIds": [] },
    "totalCount": 5,
    "truncated": false
  },
  "_meta": { "runtimeId": "<uuid>" }
}
```

## A worktree row

The CLI-created worktree, with the identifying values replaced by
placeholders. Every key is as captured; types are unchanged.

```json
{
  "workspaceKind": "git",
  "worktreeId": "<orcaRepoId>::<path>",
  "repoId": "<orcaRepoId>",
  "hostId": "local",
  "terminalPlatform": "darwin",
  "repo": "agentloop",
  "path": "<path>",
  "branch": "refs/heads/<user>/agent-loop-capture-156",
  "isArchived": false,
  "isMainWorktree": false,
  "hasHostSidebarActivity": true,
  "worktreeInstanceId": "<uuid>",
  "parentWorktreeId": null,
  "childWorktreeIds": [],
  "displayName": "agent-loop-capture-156",
  "workspaceStatus": "in-progress",
  "sortOrder": 1789399614542,
  "lastActivityAt": 1789399615507,
  "createdAt": 1789399615507,
  "creatorProvenance": { "kind": "host" },
  "linkedIssue": null,
  "linkedPR": null,
  "linkedLinearIssue": null,
  "linkedGitLabMR": null,
  "linkedGitLabIssue": null,
  "comment": "",
  "isPinned": false,
  "isActive": false,
  "unread": false,
  "liveTerminalCount": 1,
  "hasAttachedPty": true,
  "lastOutputAt": null,
  "preview": "",
  "status": "active",
  "agents": []
}
```

And the one agent the live inventory carried, with its prompt, tool input and
pane ids replaced:

```json
{
  "paneKey": "<uuid>:<uuid>",
  "parentPaneKey": null,
  "state": "working",
  "agentType": "claude",
  "prompt": "<the dispatch prompt>",
  "taskTitle": null,
  "displayName": null,
  "lastAssistantMessage": null,
  "toolName": "Bash",
  "toolInput": "<the running command>",
  "interrupted": false,
  "stateStartedAt": 1789399455703,
  "updatedAt": 1789399480837
}
```

## What the loop reads from it

- **`createdAt`** is the worktree's creation, in epoch-ms: on the CLI-created
  worktree, read back within a second of `orca worktree create`, it was that
  instant. It is the origin #136 declares for the sweep and the reclaim.
- **`createdAt` is absent exactly on the main worktree.** All four
  `isMainWorktree: true` rows lacked both it and `creatorProvenance`; both
  non-main rows carried both. Ownership already excludes a main worktree, so
  no loop consumer should meet the absence — and if one does, the inventory
  projects it as `-`.
- **`agents[].stateStartedAt` is not a worktree origin.** It marks entry into
  the agent's current `state`, and resets on every transition.
- **`worktreeId` is `<repoId>::<path>`**, and `repoId` is the `orcaRepoId`
  config maps to `github`, so a worktree names its repository with no new read.
- **`lastActivityAt` is not an origin either**: it moved on the live worktree
  between two reads while its agent ran.

## How the fixtures are derived

A worktree inventory the suite can assert on needs stub paths, stub repo ids
and chosen agent states, which no live capture can supply. So each
`tests/fixtures/orca-ps-*.json` row is a captured row with those substituted,
and nothing else about it invented:

- a non-main row is the CLI-created row, a main row is a captured main row, and
  an agent is the captured agent — every key present, every type kept;
- substituted: `worktreeId`, `repoId`, `repo`, `path`, `branch`,
  `displayName`, the instance and pane ids, the timestamps (fixed epoch-ms
  values: each row's `createdAt` ten minutes after the last, its agent's
  `stateStartedAt` and `updatedAt` 30 and 60 seconds after that),
  `agents[].state`, and the free text (`preview`,
  `prompt`, `toolInput`);
- `createdAt` and `creatorProvenance` are dropped from main rows, as Orca drops
  them.

Each regenerated fixture projects the same `state` and `path` for every row as
the hand-cut one it replaces, so no existing case changed. One hand-cut row is
gone: `orca-ps-idle.json` carried `{"worktreeId": "repo-bbb::", "path": null}`,
which no capture produces. The inventory still skips a null path, and
`orca-ps-origins.json` keeps one such row, so a pass is still shown to survive
it.

Two fixtures are not captures, on purpose:

- **`orca-ps-malformed.json`** is a failure shape — `worktrees` an object — for
  the readiness cases.
- **`orca-ps-origins.json`** is captured rows with `createdAt` broken four ways:
  absent, a string, `null`, and negative, plus one empty `worktreeId` and one
  null `path`. It pins that none of them costs a consumer a row.
