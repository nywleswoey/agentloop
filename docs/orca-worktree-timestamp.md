# What timestamps `orca worktree ps` carries, and what each one measures

Research note for [#130](https://github.com/nywleswoey/agentloop/issues/130), part of the wayfinder
map [#116](https://github.com/nywleswoey/agentloop/issues/116). Written 2026-09-01. Consumed by
[#122](https://github.com/nywleswoey/agentloop/issues/122) (`its agent is still going`) and
[#125](https://github.com/nywleswoey/agentloop/issues/125) (`N commits not on the remote`).

**Version stamp. Orca 1.4.193** — `/Applications/Orca.app/Contents/Info.plist`,
`CFBundleShortVersionString` = `CFBundleVersion` = `1.4.193`; the CLI at `/opt/homebrew/bin/orca` is
a symlink into that bundle. **The CLI has no `--version` flag** (`orca --version` prints the usage
banner; `orca -v` errors `Unknown command: -v`), so the bundle is the only stamp available. Command
schema version, from `orca agent-context`: **`schema v1`, 232 commands**. Runtime `eb037bd2-f473-
4382-ae48-019772b33615`, host `local`, `darwin`.

## The short version

**Yes — the payload carries timestamps, and the ticket's premise that it carries none is wrong for
Orca 1.4.193.** The fixture `tests/fixtures/orca-ps-sweep.json` is a hand-cut stub, not a captured
response; the real `orca worktree ps --json` emits **34 worktree-level keys and 13–14 agent-level
keys**, five of them epoch-millisecond integers. `orca_worktrees()` (`agent-loop.sh:719`) projects
two of the 34 and throws the rest away.

Four timestamps are relevant, and **they measure four different things**:

| Field | Level | Measures | Origin-grade? |
|---|---|---|---|
| `createdAt` | worktree | **Worktree creation.** Set by `orca worktree create`; equals the checkout directory's birth time to the second. Durable and never moves. | **Yes — a true origin.** |
| `stateStartedAt` | agent | **Entry into the agent's *current* state.** Resets on every transition. | Yes, but for *this state*, not the agent. |
| `updatedAt` | agent | Last mutation of the agent record — moves every few seconds while working. | No. Recency. |
| `lastActivityAt` / `lastOutputAt` | worktree | Last worktree activity / last PTY output. | No. Recency. |

**There is no agent-dispatch timestamp anywhere in the payload.** `stateStartedAt` is the closest
thing and it is not it: it resets on `working` → `done` and again on `done` → `working`, observed
three times (§3).

**Recommended origins.**

- **#122 (`its agent is still going`)** — the honest origin is **worktree `createdAt`**, not
  `stateStartedAt`. `stateStartedAt` cannot bound *the agent* because the sweep's `live` predicate
  spans `working` **or** `waiting` (`agent-loop.sh:721-722`), and a clock that resets on every
  transition inside that predicate resets mid-wait: an agent flipping `working` ↔ `waiting` every
  ten minutes never accumulates a bound, no matter how long it has been going. `createdAt` is
  immune to that — it is set once, at create, and the loop's worker worktrees are single-purpose
  (`dispatch_issue` creates a worktree and puts the agent in its first terminal in the same call,
  `agent-loop.sh:1648-1655`), so **worktree age is agent age plus a few seconds**. Measured on two
  probes: 2.9s and 5.4s between `createdAt` and the first agent state (§3). Against a bound in
  hours, that gap is noise. What `createdAt` **cannot** distinguish is a stuck agent from a
  legitimately long one; nothing in the payload can.
- **#125 (`N commits not on the remote`)** — also **worktree `createdAt`**, and here it is the only
  candidate that survives, because *every* agent-level field is gone. This wait is entered when the
  worktree is `idle`: `.agents[]` is either empty or holds only `done` agents, so `stateStartedAt`
  answers "how long since the agent finished", which is a different question from "how long has
  this worktree been pinned", and it disappears entirely once Orca drops the agent record.
  `createdAt` measures the **worktree's total lifetime**, which for a loop worker is the task's
  total age — dispatch to now. That is a superset of the wait, not the wait itself, and #125 should
  say so in its bound rather than pretend otherwise.

**And there is a durable per-worktree annotation, if `createdAt` is judged the wrong shape**:
`orca worktree set --comment <text>` writes a free-text string that `orca worktree ps --json`
returns in the same read, at no extra cost (§4). Round-trip verified. It has one sharp edge: it
cannot be cleared (§4.1).

**The decisive caveat, and it is the one the map has been bitten by before: none of these fields is
documented.** Orca's version-matched bundled skill guides document *commands and flags* and never
name a single response field. `grep -ci 'createdAt|stateStartedAt|lastActivityAt|updatedAt|timestamp'`
returns **0** against `orca skills get orca-cli --full` (27,034 bytes) and **0** against
`orca skills get orchestration --full` (41,245 bytes). `orca agent-context --json` (168 KB, the
machine-readable command schema) carries exactly `aliases`, `argumentMode`, `command`, `examples`,
`flags`, `notes`, `path`, `positionalArgs`, `summary`, `usage` per command — **no response schema at
all**; the sole occurrence of any of those field names in the whole file is a `--order-by
createdAt|updatedAt` flag on an unrelated Linear command. So every field below is **observed, not
promised**. A bound built on `createdAt` is a bound built on an undocumented field of a desktop app
that auto-updates — §6 says what to do about that.

## How to read the source column

| Tag | Source |
|---|---|
| `[CLI]` | Observed by running the real `orca` CLI on this machine against Orca 1.4.193, 2026-09-01. Live inventory of 5 worktrees plus two disposable probe worktrees created and removed for this note. |
| `[DOC]` | Orca's own version-matched documentation: `orca skills get orca-cli --full` and `orca skills get orchestration --full`, plus `orca <cmd> --help` and `orca agent-context --json`. |
| `[FS]` | Observed from the filesystem or git, on a real Orca-created worktree. |
| `[!]` | **Inference.** Not observed and not documented. Do not treat as established. |

---

## 1. The actual payload shape

`orca worktree ps --json` `[CLI]`. Key census across the 5 worktrees Orca knows on this host:

**Worktree level — present on all 5:**
`workspaceKind`, `worktreeId`, `repoId`, `hostId`, `terminalPlatform`, `repo`, `path`, `branch`,
`isArchived`, `isMainWorktree`, `hasHostSidebarActivity`, `worktreeInstanceId`, `parentWorktreeId`,
`childWorktreeIds`, `displayName`, `workspaceStatus`, `sortOrder`, **`lastActivityAt`**,
`linkedIssue`, `linkedPR`, `linkedLinearIssue`, `linkedGitLabMR`, `linkedGitLabIssue`, `comment`,
`isPinned`, `isActive`, `unread`, `liveTerminalCount`, `hasAttachedPty`, **`lastOutputAt`**,
`preview`, `status`, `agents`.

**Worktree level — present on 1 of 5:** **`createdAt`**, `creatorProvenance`.

**Agent level — present on all 3 live agents:**
`paneKey`, `parentPaneKey`, `state`, `agentType`, `prompt`, `taskTitle`, `displayName`,
`lastAssistantMessage`, `toolName`, `toolInput`, `interrupted`, **`stateStartedAt`**, **`updatedAt`**.
Present on 1 of 3: `workingMode`.

Contrast with the stub the tests assume, which carries `worktreeId`, `path`, `agents[].state`,
`agents[].agentType` and nothing else. **The stub is a subset, not a snapshot.** Note also that the
sibling reads are *thinner*, not richer: `orca worktree list --json` carries `lastActivityAt` and
`createdAt` but **no `agents[]` at all**, and `orca terminal list --json` carries only `lastOutputAt`
`[CLI]`. `worktree ps` is the widest read available, and the loop already takes it.

## 2. `createdAt`: what it marks, and who has it

**It marks worktree creation, to the second.** `[CLI]` `[FS]` On the one pre-existing Orca-created
worktree in the inventory:

```
createdAt          1788174606944  → 2026-08-31T19:10:06.944
stat -f %SB (birth) → 2026-08-31T19:10:06
```

Identical. And `orca worktree create --json` returns `createdAt` in its own response, stamped at
create time: probe 1 created at wall-clock ≈`1788258732xxx`, `createdAt` = `1788258736715`
(2026-09-01T18:32:16.715) `[CLI]`.

**It is absent on main worktrees and present on Orca-created ones.** The 4 worktrees missing
`createdAt` are exactly the 4 with `isMainWorktree: true` — repos imported into Orca by path, whose
checkout Orca did not create and whose creation instant it therefore does not know. The single
worktree carrying `createdAt` is the only one with `isMainWorktree: false`. `orca worktree show
--json` on it also returns `creatorProvenance: {kind: "host"}`, `createdWithAgent: "claude"` and
`baseRef` — the same create-time trio, absent on main worktrees `[CLI]`.

**This is the right side of the line for the sweep.** `sweep_worktrees()` filters on
`is_loop_worktree()` first (`agent-loop.sh:1881`), i.e. a directory basename of `agent-loop-*`, and
the loop mints those with `orca worktree create` (`agent-loop.sh:1648`). Verified directly: a probe
worktree created through the loop's own call shape —
`orca worktree create --repo id:<orcaRepoId> --name <n> --no-parent --agent claude --prompt <p>` —
came back with `createdAt`, `creatorProvenance`, `createdWithAgent: "claude"` and
`isMainWorktree: false`, and its `createdAt` was visible in the subsequent `worktree ps --json`
`[CLI]`. **Every worktree the sweep can act on carries `createdAt`; the ones that do not are the
ones ownership already excluded.**

`[!]` Not verified: that `createdAt` survives an Orca app restart. It is served from Orca's
persisted graph rather than from process memory — the 23h-old value above was read back long after
any single app session — but no restart was performed during this reading.

## 3. `stateStartedAt`: current-state entry, and it resets

**Within a state it is frozen; across a transition it moves.** Three transitions observed `[CLI]`:

| Probe | Event | `state` | `stateStartedAt` | Wall clock |
|---|---|---|---|---|
| 1 | worktree created | — | (`createdAt` `1788258736715`) | 18:32:16.715 |
| 1 | first observation | `done` | `1788258742069` | 18:32:22.069 |
| 1 | new prompt sent | `working` | `1788259048110` | 18:37:28.110 |
| 1 | finished | `done` | `1788259050005` | 18:37:30.005 |
| 2 | worktree created | — | (`createdAt` `1788259196986`) | 18:39:56.986 |
| 2 | first observation | `working` | `1788259199917` | 18:39:59.917 |
| 2 | finished | `done` | `1788259204971` | 18:40:04.971 |
| 2 | new prompt sent | `working` | `1788259347055` | 18:42:27.055 |
| 2 | finished | `done` | `1788259356745` | 18:42:36.745 |

**`stateStartedAt` takes a new value at every one of those transitions.** Meanwhile a separate
4-minute poll at 10s intervals over the pre-existing live agents showed `stateStartedAt` **constant**
across 24 samples while `updatedAt` advanced continuously — e.g. one `working` agent held
`stateStartedAt = 1788249084634` for the whole window while `updatedAt` walked
`…258456490 → …258695839` `[CLI]`. And on a `done` agent, `stateStartedAt` held at `1788258375098`
while `updatedAt` moved to `1788258558123` — so **the two are not the same field with different
names**; `stateStartedAt` is a transition stamp and `updatedAt` is a heartbeat.

**Two consequences for #122.**

1. `stateStartedAt` **is not dispatch.** On probe 2 the worktree was created at 18:39:56.986 and the
   first `working` stamp is 18:39:59.917 — close, but that is the *first* state's entry, and by the
   third transition the field reads 18:42:27, two and a half minutes adrift of a 2.5-minute-old
   agent. On a real worker the drift is unbounded.
2. It **resets inside the sweep's own predicate.** `orca_worktrees()` calls a worktree `live` if
   *any* agent is `working` **or** `waiting`. Both are non-terminal, so a transition between them is
   an event that resets the clock without ending the wait. `[!]` Not directly observed: a
   `working` → `waiting` transition. The probe agents ran under bypassed permissions and never
   entered `waiting`; both reproduced transitions were `working` ↔ `done`. The reset is a property
   of the field demonstrated three times across two different transition directions, so the
   inference that `waiting` behaves the same is strong — but it is an inference, and #122 should
   not lean on `stateStartedAt` in any case.

**`stateStartedAt` disappears when the agent does.** It lives in `agents[]`; a worktree with
`agents: []` has no timestamp of any kind except the worktree-level three. This is what rules it out
for #125 entirely, not merely makes it awkward.

## 4. The durable annotation: `orca worktree set --comment`

`orca worktree set --worktree <selector> --comment <text> --json` writes a free-text string into
Orca metadata, and `comment` is already one of the 34 keys `orca worktree ps --json` returns
`[CLI]` `[DOC]`. Round-trip verified end to end: wrote `sweep-origin=1788259000000`, read the exact
string back out of the next `worktree ps --json` `[CLI]`.

This is the durable per-worktree annotation the ticket asks after in question 3, and it is unusually
cheap: **the write is one extra call at dispatch, and the read costs nothing** — the sweep's
existing `$ORCA_PS` snapshot already carries the field. Selectors accept `path:<absolutePath>`,
which is what the sweep holds `[DOC]`.

Two things count against reaching for it:

- **It is a shared surface, not the loop's.** Orca's own guide instructs coding agents to keep it
  current: *"Coding agents should update the active worktree comment at meaningful checkpoints"*,
  *"Keep comments short/current"* `[DOC]`. The agent the loop dispatches is a Claude that may follow
  that instruction and overwrite whatever the loop wrote. A loop-owned origin stored there can be
  destroyed by the worker it is timing.
- **`createdAt` already answers the question for free.** Writing an origin the payload already
  carries is the "costly remedy needing its own argument" the ticket names, and it does not need
  making.

Its real use is for an origin `createdAt` genuinely cannot express — e.g. #125 wanting the instant
the *agent finished* rather than the instant the worktree was born, which no field survives to
record. That is a real gap, and `--comment` is the only place to close it without loop-held state.

### 4.1 One sharp edge, found the hard way

**A comment cannot be cleared.** `[CLI]` All of `--comment ''`, `--comment=` and `--comment "$v"`
with `v=""` return `ok: true` and leave the previous value **unchanged** — an empty string is
treated as "no change", not as "clear". `--comment null` sets the four-character literal string
`null` (unlike `--linear-issue null`, which the guide documents as a clear `[DOC]`). The only way to
make a comment visually empty is `--comment " "`, a single space.

*Side effect of this reading, disclosed:* the `agentloop` main worktree's comment was `""` before
this note and is now `" "` (one space). It renders as empty in Orca's card, and no CLI path restores
the exact empty string.

## 5. The filesystem fallbacks, and what each actually measures

Not needed — `createdAt` exists — but the ticket asks, and the measurements are worth having on
record because they show how badly the two obvious candidates would have gone. Both taken on the one
real long-lived Orca worktree `[FS]`:

| Candidate | Value | What it actually measures |
|---|---|---|
| `createdAt` (Orca) | 2026-08-31T19:10:06.944 | Worktree creation. |
| directory **birth** (`stat -f %SB`) | 2026-08-31T19:10:06 | Same instant. A faithful `createdAt` substitute — **on macOS/APFS only**; ext4 exposes `btime` inconsistently and `stat -f` is BSD-only, so it is not portable. |
| directory **mtime** (`stat -f %Sm`) | 2026-09-01T08:35:57 | **Neither creation nor last activity.** 13.4h after creation, and — the damning part — **10h *before* the newest commit**. It stamps the last change to the top-level directory *entry*; a file written in a subdirectory does not touch it. As a clock it is monotone-ish and meaningless: it moves for reasons unrelated to the wait and stands still for reasons unrelated to the wait. |
| `git log -1 --format=%cI` | 2026-09-01T18:21:39+08:00 | **The work's age, not the wait's** — exactly as the ticket says. Here it is *20h 51m later* than worktree creation, so it would report a day-old worker as three hours old. Worse for #125 specifically: the pinning commits are the newest ones, so the commit date is the age of *the last thing the agent did*, and an agent that committed and then hung reports as freshly active. |
| `git reflog show refs/heads/<branch>` | `branch: Created from HEAD` at 2026-09-01 15:51:09 | Branch creation, which here is **not** worktree creation (the branch was re-cut inside a 20h-old worktree). Also local-only and expires — `gc.reflogExpire` defaults to 90 days. |

**All four are strictly worse than the field the payload already carries.** Record them as rejected.

## 6. What this owes the map

- **The version stamp is load-bearing, not decorative.** Every field in §1 is undocumented (§ short
  version). Orca is a desktop app that auto-updates — the agentloop worktree's own terminal was
  showing `✔ Update installed · Restart to update` during this reading `[CLI]`. A silently-dropped
  `createdAt` would turn a bound into an unbounded wait with no log line saying so.
- **So whoever consumes this should read the field defensively**: absent-or-unparseable `createdAt`
  must fall through to the current unbounded behaviour and **say which branch it took**, the way
  `load_worktree_inventory` already distinguishes "I could not look" from "nothing is running"
  (`agent-loop.sh:687-689`). A bound that silently vanishes is worse than no bound, because the log
  stops distinguishing them.
- **`tests/fixtures/orca-ps-sweep.json` needs `createdAt` before either bound can be tested.** It is
  currently a 4-key hand-cut stub; a bound reading a fifth key is untestable against it.
- **Not a clock, but adjacent and free:** `worktree ps` also returns `linkedIssue` and `linkedPR`
  per worktree, and `orca worktree set --issue <number>` writes the link `[CLI]` `[DOC]`. The map
  already noted the sweep can name a GitHub object via `worktreeId`; this is a second, more direct
  route, and it costs the same one call at dispatch that a `--comment` origin would.

## Reproducing this

```sh
defaults read /Applications/Orca.app/Contents/Info.plist CFBundleShortVersionString  # 1.4.193
orca worktree ps --json | jq -r '.result.worktrees[] | keys[]' | sort -u
orca worktree ps --json | jq -r '.result.worktrees[].agents[]? | keys[]' | sort -u
orca worktree ps --json | jq -r '.result.worktrees[]
  | [.path, (.createdAt//"ABSENT"), .isMainWorktree] | @tsv'
orca skills get orca-cli --full | grep -ci 'createdAt\|stateStartedAt\|timestamp'   # 0
```

Reproducing the `stateStartedAt` reset (§3) costs two disposable worktrees; both were created with
the loop's own `worktree create` call shape and removed with `orca worktree rm`, which also deleted
their branches — verified clean afterwards.
