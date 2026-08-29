# What moves V1, V2 and V4's inputs at a fixed head

Research note for [#54](https://github.com/nywleswoey/agentloop/issues/54), part of the wayfinder
map [#44](https://github.com/nywleswoey/agentloop/issues/44). Written 2026-08-29. Companion to
[`docs/github-merge-state.md`](github-merge-state.md), which did the same job for V3.

The question this answers: three empirical beliefs about the risk gate's **non-V3** inputs —
whether the changed-file list is stable at the head alone (V4), whether CodeRabbit's merge-risk
block can name a commit that is not the head (V1), and whether a hand re-run moves the status-check
rollup (V2).

**The short version.**

- **V4 — belief CONFIRMED.** GitHub documents in its own words that *"Pull requests on GitHub show
  a three-dot diff"*, computed against the merge base `[D]`. A base advance that does not touch the
  head cannot move the merge base, so it cannot move `files`. Confirmed on a specimen where the base
  branch has fully absorbed the head and `files.totalCount` is unchanged `[E]`.
- **V1 — belief HALF-FALSIFIED, and the falsified half is replaced by something worse.** The
  in-flight window the belief describes is **not** how the mismatch happens: on this account
  CodeRabbit edits the walkthrough **three to five seconds before** it posts the terminal status
  `[E]`, and the loop short-circuits to `reviewing` on a non-terminal signal anyway. But the
  mismatch itself is real and **far more common than suspected — five of the nine most recent
  merged pull requests ended at a head whose newest walkthrough named a different commit** `[E]`.
  It is **not a window and it does not self-retract**: it is permanent at that head. See
  [Belief 2](#belief-2--v1-can-the-walkthrough-move-and-does-its-abbreviation-lag).
- **V2 — belief CONFIRMED, and the append/replace question is answered.** Check runs **append** to
  the commit — a re-run mints a *new* `CheckRun` with a new id, and the old one stays retrievable at
  `?filter=all` — but the **rollup surfaces only the latest per name** `[E]`. So a re-run moves
  `contexts.nodes` (state, id, timestamps) and leaves `contexts.totalCount` alone. Legacy statuses
  behave identically: three statuses on one commit, one rollup entry `[E]`.

---

## How to read the source column

Every claim below carries a tag. Claims tagged `[!]` are **not documented** by the vendor in
question and are marked as inference; do not treat them as established.

| Tag | Source |
|---|---|
| `[S]` | GitHub's published GraphQL schema — <https://docs.github.com/public/fpt/schema.docs.graphql>. Retrieved 2026-08-29. Field descriptions cross-checked against live introspection `[E]`. |
| `[R]` | [REST API endpoints for pull requests](https://docs.github.com/en/rest/pulls/pulls) — in particular *List pull requests files*. |
| `[O]` | GitHub's OpenAPI description, `descriptions/api.github.com/api.github.com.json` in [github/rest-api-description](https://github.com/github/rest-api-description). |
| `[D]` | [About comparing branches in pull requests](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/about-comparing-branches-in-pull-requests) |
| `[X]` | REST reference for checks — [Check Runs](https://docs.github.com/en/rest/checks/runs) and [Check Suites](https://docs.github.com/en/rest/checks/suites) |
| `[G]` | [Using the REST API to interact with checks](https://docs.github.com/en/rest/guides/using-the-rest-api-to-interact-with-checks) |
| `[Y]` | [REST API endpoints for commit statuses](https://docs.github.com/en/rest/commits/statuses) |
| `[C]` | [Status checks reference](https://docs.github.com/en/pull-requests/reference/status-checks) |
| `[T]` | [Troubleshooting required status checks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks) |
| `[K]` | [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) |
| `[W]` | CodeRabbit's own documentation — <https://docs.coderabbit.ai>, in particular [Walkthroughs](https://docs.coderabbit.ai/pr-reviews/walkthroughs), [Commands](https://docs.coderabbit.ai/guides/commands), [Configuration reference](https://docs.coderabbit.ai/reference/configuration) and the [Glossary](https://docs.coderabbit.ai/reference/glossary). |
| `[F]` | This repository's own fixtures and the prose in `agent-loop.sh` — `tests/fixtures/worlds/`, `tests/test-agent-loop.sh`, and the constant block at `agent-loop.sh:79-146`. |
| `[E]` | Empirical, read-only observation of `nywleswoey/agentloop` and `nywleswoey/kids-collection`, 2026-08-29. See [Specimens](#specimens). |
| `[!]` | **Undocumented and inferred.** The vendor does not state this; it is reasoning from the texts above. |

---

## Belief 1 — V4: is the changed-file list stable at the head alone?

**Belief:** the `files` connection is a three-dot diff against the merge base, so advancing the base
adds commits the head does not contain, the merge base does not move, and `files.nodes` /
`files.totalCount` are unchanged.

### Verdict: **CONFIRMED.**

GitHub says it outright, on a page that is not the endpoint reference:

> *"Three-dot and two-dot Git diff comparisons. The `git diff` command supports two comparison
> methods. **Pull requests on GitHub show a three-dot diff.**"* — with the table row *"Three-dot |
> `git diff A...B` | The most recent common commit of both branches (**merge base**) and the most
> recent version of the topic branch."* `[D]`

> *"Because the three-dot comparison uses the merge base, it focuses on 'what a pull request
> introduces.' When you use a two-dot comparison, **the diff changes when the base branch is
> updated, even if you haven't made any changes to the topic branch.** … In contrast, a three-dot
> comparison keeps showing the changes introduced by the topic branch since the branches
> diverged."* `[D]`

That second sentence is the belief's whole content, written by GitHub, as the reason they chose
three-dot.

### Table 1 — V4's inputs

`filecount` = `files.totalCount`, `truncated` = `totalCount > (nodes|length)`, `guarded` = the
`.github/workflows/` and unattended-script paths inside `files.nodes` (`agent-loop.sh:1639-1642`).

| Input | What it is | Stable at a fixed head? | What moves it with no push to head | Basis |
|---|---|---|---|---|
| `files.nodes[].path` | *"Lists the files changed within this pull request."* `[S]` | **Yes, at a fixed merge base.** Not literally "at the head alone" — the merge base is a function of two refs. | Only what moves the **merge base**: (a) the base absorbing the head's commits, which walks the merge base forward toward the head `[!]`; (b) a base force-push/rewind past the merge base `[!]`; (c) merging the base *into* the head — but that is a push. GitHub's only statement in this direction: *"When you merge the base branch, the diffs shown by two-dot and three-dot comparisons are the same."* `[D]` | `[S]` `[D]` `[E]` |
| `files.totalCount` | *"Identifies the total count of items in the connection."* `[S]` | Same as `nodes` | Same as `nodes` | `[S]`; that it counts the same set `nodes` pages from is **`[!]` inferred** from standard connection semantics — GitHub documents no relationship, and the pagination guide does not mention `totalCount` at all |
| `truncated` (derived) | `totalCount > (nodes \| length)` at `files(first: 100)` | Same as its two terms | Same as its two terms. Sound **only if** `totalCount` counts the `nodes` set — see the `[!]` above | `[!]` on the soundness; `[E]` for the equality at n=39 |
| `guarded` (derived) | path filter over `nodes` | Same as `nodes` | Same as `nodes` | `[F]` |

### What GitHub does *not* say

- **Neither the endpoint nor the field says "merge base".** REST's description is the whole of it:
  *"Lists the files in a specified pull request."* `[R]` `[O]`. GraphQL's is *"Lists the files
  changed within this pull request."* `[S]`. The three-dot fact lives only on the conceptual page
  `[D]`, which speaks of what *"pull requests on GitHub show"*. **`[!]` Bridging "the PR's diff is
  three-dot" to "the `files` API list is three-dot" is inference**, though the specimen below closes
  it empirically.
- **The caps are documented and they differ per endpoint.** REST: *"Responses include a maximum of
  3000 files. The paginated response returns 30 files per page by default."* `[R]` `[O]` — verbatim
  in both the rendered page and the OpenAPI JSON. The separate compare endpoint caps at *"up to 300
  changed files for the entire comparison"*. GraphQL declares no cap of its own `[S]`; whether the
  3000 ceiling applies there is **`[!]` undocumented**. The gate reads `first: 100`, well under
  either.
- **Whether `baseRefOid` tracks the live base tip on an *open* pull request is undocumented.** The
  schema says only *"Identifies the oid of the base ref associated with the pull request, even if
  the ref has been deleted."* `[S]`. On a merged specimen it is frozen at the pre-merge value `[E]`.
  **`[!]` No open pull request was available to test the live case.** This does not affect the
  verdict — `files` is defined by the merge base, not by `baseRefOid`.

### The V4 specimen

`nywleswoey/agentloop` PR #38 — merged, so its head is now an **ancestor** of `main`. This is the
strongest available form of "the base absorbed the head's commits".

```
headRefOid   312cbdd8c01ce4141b02aec6d201cf2f0976b66e
baseRefName  main
baseRefOid   8f1ec4fd508251262712029b560ba3d4d2db893b
main tip     6a9f0618e90bb1cb1af514f0d49ebdeb40596887   (five merges later)
files.totalCount  39
```

`git merge-base 8f1ec4fd 312cbdd8` = `8f1ec4fd` — the recorded base sha *is* the merge base.
`git diff --name-only 8f1ec4fd...312cbdd8` yields **39 paths, byte-identical to the sorted
`pulls/38/files` list** and equal to `files.totalCount`. Meanwhile a two-dot diff against the live
base tip — `git diff main..312cbdd8` — is **empty**, because the head is an ancestor of `main`.

So the list is not against the base tip, and `totalCount` agrees with the `nodes` set at n=39. `[E]`

---

## Belief 2 — V1: can the walkthrough move, and does its abbreviation lag?

**Belief:** CodeRabbit edits its walkthrough in place; a second review can land at a fixed head; and
while a review is in flight the visible walkthrough still names the previous commit — so there is a
window at a fixed head where the abbreviation is not a prefix of the head.

### Verdict: **the mechanism is FALSIFIED; the mismatch is CONFIRMED and is worse than a window.**

The belief asks about a *transient* window that closes when an in-flight review finishes. That is
not what the specimens show. What they show is a mismatch that **never closes at that head**, in
**five of the nine most recent merged pull requests**.

### Table 2 — V1's inputs

`level` and `abbrev` are captured from `**Merge Risk:** _<level>_ · up to \`<abbrev>\`` inside
CodeRabbit's newest walkthrough by `updatedAt` (`agent-loop.sh:1619-1621`).

| Question | Answer | Basis |
|---|---|---|
| Does a re-review **edit** the walkthrough or post a new one? | **Edits.** Every specimen carries exactly **one** walkthrough comment, with `updatedAt` minutes to hours after `createdAt` `[E]`; the repo records observed gaps of *five and seven days* `[F]`. CodeRabbit documents edit-in-place only for the placeholder: *"While a review is in progress, CodeRabbit posts a fortune message as a placeholder in the walkthrough comment. The placeholder is replaced by the full walkthrough once the review completes."* `[W]` | `[E]` `[F]` `[W]`; **`[!]` that the *body* is edited on every later review is not documented** — only the placeholder transition is |
| Can a second walkthrough comment ever exist? | **Not observed.** The suite models it (`gate/pr-232.json` carries two walkthroughs whose `createdAt` and `updatedAt` orderings disagree) and the loop's `max_by(.updatedAt)` is written for it `[F]`, but no live specimen showed two `[E]` | `[F]` `[E]` `[!]` |
| Can a review land at a **fixed head**? | **Yes.** `@coderabbitai review` is a comment, not a push. But CodeRabbit's docs frame it entirely around new commits — *"`@coderabbitai review` does only incremental review (what changed since last review)"*, *"generates a review of only the new changes"* `[W]` — and **never state what happens with no new commit** | `[W]`; **`[!]` the no-new-commit case is undocumented** |
| What does `up to <sha>` name? | **Undocumented.** The literal string *"merge risk"* appears **nowhere** in CodeRabbit's documentation — not on the Walkthroughs page, not in the configuration reference, not in the glossary, not in the full site index. Neither does any `up to`/`commits reviewed` field `[W]`. Empirically it names the **last commit CodeRabbit actually wrote a walkthrough for**, which is not always the head `[E]` | `[W]` for the absence; `[E]` `[!]` for the meaning |
| **Is there a window at a fixed head where the abbreviation is not a prefix of the head?** | **Yes — but not the window the belief describes.** See below. | `[E]` |
| Can the **level** change between two reviews of the same commit? | **Undocumented and untested.** CodeRabbit says nothing about determinism anywhere `[W]`. No specimen re-reviewed one commit twice `[E]` | `[!]` |

### The load-bearing sub-question, answered in two parts

**(a) The in-flight window: FALSIFIED as a route into the gate.**

On this account CodeRabbit's terminal status arrives **after** the walkthrough edit, not before:

| PR | walkthrough `updatedAt` | `CodeRabbit` status `SUCCESS` | gap |
|---|---|---|---|
| #2 | 2026-08-22T10:38:36Z | 2026-08-22T10:38:40Z | +4s |
| #13 | 2026-08-22T16:26:29Z | 2026-08-22T16:26:32Z | +3s |
| #34 | 2026-08-28T00:03:56Z | 2026-08-28T00:04:00Z | +4s |
| #36 | 2026-08-28T03:43:26Z | 2026-08-28T03:43:29Z | +3s |
| #37 | 2026-08-28T05:07:04Z | 2026-08-28T05:07:06Z | +2s |
| #41 | 2026-08-28T11:57:27Z | 2026-08-28T11:57:30Z | +3s |
| #43 | 2026-08-28T23:46:43Z | 2026-08-28T23:46:48Z | +5s |

Seven for seven, the walkthrough carries the new verdict **before** the review is marked complete
`[E]`. And the gate is not reachable while a review is running at all: the loop short-circuits to
`reviewing` whenever the newest signal on the head is non-terminal (`agent-loop.sh:2079`) `[F]`. So
the ordering leaves no gap, and even a gap would be closed by the short-circuit.

**`[!]` This is seven observations on one account, not a guarantee.** PR #42 is a counter-ordering —
status at 14:38:15Z, walkthrough edit at 14:38:44Z — and is discussed below.

**(b) The real mismatch: CONFIRMED, common, and permanent.**

The mismatch does not come from a review being *in flight*. It comes from a review **finishing
without touching the walkthrough**. Across the nine most recent merged pull requests:

| PR | head | head author | walkthrough `abbrev` | prefix of head? | terminal status on head |
|---|---|---|---|---|---|
| #35 | `05aeda7b` | `coderabbitai[bot]` — *"Fix CodeRabbit issues in PR #35"* | `8a9d5` (the parent) | **no** | `SUCCESS` *Review completed*, **12 s** after the commit |
| #36 | `77b6aef8` | nywleswoey | `77b6a` | yes | `SUCCESS` |
| #37 | `85ad0ce9` | nywleswoey | `85ad0` | yes | `SUCCESS` |
| #38 | `312cbdd8` | `coderabbitai[bot]` — *"Fix CodeRabbit issues in PR #38"* | `1ce75` (the parent) | **no** | `SUCCESS`, **10 s** after the commit |
| #39 | `ce343f53` | `coderabbitai[bot]` — *"fix: apply CodeRabbit auto-fixes"* | `ffc43` (the parent) | **no** | `SUCCESS`, **9 s** after |
| #40 | `2e0f44e3` | `coderabbitai[bot]` — *"fix: apply CodeRabbit auto-fixes"* | `657ba` (the parent) | **no** | `SUCCESS`, **9 s** after |
| #41 | `b8f67a68` | nywleswoey | `b8f67` | yes | `SUCCESS` |
| #42 | `5e7dccb6` | nywleswoey | `9dab2` — an **amended-away** commit, same headline, not an ancestor of the head | **no** | `SUCCESS` |
| #43 | `0b1764f0` | nywleswoey | `0b176` | yes | `SUCCESS` |

**Five of nine.** Two distinct causes, both leaving the walkthrough naming a commit that is not the
head, with a terminal `Review completed` sitting on the head:

1. **The head is CodeRabbit's own autofix output commit** (#35, #38, #39, #40). CodeRabbit reports
   *Review completed* on it within nine to twelve seconds and leaves the walkthrough alone. Its
   docs describe a `review_status` setting — *"Post review status messages (e.g., when a review is
   skipped) in the walkthrough summary comment"* `[W]` — which is consistent with a skip, but
   **`[!]` CodeRabbit does not document that it skips its own autofix commits**, and no skip message
   was present in the bodies read.
2. **The head is a force-push/amend of the reviewed commit** (#42). `9dab2845` carries the same
   headline as the head and is not an ancestor of it.

**None of these retracted.** In every case the walkthrough still named the wrong commit when the
pull request was merged by hand. **This is not self-retracting; it is permanent at that head.** It
clears only by a write — a new commit, or a `@coderabbitai review` / `@coderabbitai full review`
comment. **`[!]` That such a comment would produce a walkthrough naming the current head is
inference: CodeRabbit does not document the no-new-commit case** `[W]`.

### Two corrections to the surface record

- **The block's shape has moved.** The live walkthrough now nests the risk block inside a
  `<!-- walkthrough_start -->` / `<details><summary>📝 Walkthrough</summary>` wrapper the fixtures
  do not have. `<!-- final_review_risk_start -->` and the `**Merge Risk:** _<level>_ · up to
  `<abbrev>`` line survive unchanged inside it, so the gate's capture still matches `[E]`.
- **Levels seen live: `⚪ Minimal`, `🔵 Low`, `🟡 Moderate`, `🟠 High`** `[E]` `[F]`. Still no
  documented ladder `[W]` — the repo's existing note that the feature is *"described nowhere at
  all"* in CodeRabbit's docs is re-confirmed against the full site index `[W]` `[F]`.
- **Abbreviation length is five hex characters on every capture** `[E]` `[F]`, which is why V1's
  test is a prefix test.

---

## Belief 3 — V2: does a hand re-run move the status-check rollup?

**Belief:** yes — re-running a check moves neither head nor base but does change
`statusCheckRollup`.

### Verdict: **CONFIRMED**, and the replace-vs-append question resolves into two different answers
at two different layers.

### Table 3 — V2's inputs

`green` / `pending` / `failed` / `total` and the name lists are all derived from
`statusCheckRollup.contexts.nodes` (`agent-loop.sh:1622-1652`).

| Question | Answer | Basis |
|---|---|---|
| Does a re-run **replace** or **append** the `CheckRun`? | **Both, at different layers.** On the *commit*, check runs **append** — a re-run mints new `CheckRun` records with new ids, and the previous attempt's runs remain retrievable at `?filter=all`. In the *rollup*, only the **latest per name** appears. Specimen: 7 check runs on the commit at `filter=all`, 3 at `filter=latest`, **`contexts.totalCount = 4`** (3 check runs + 1 status context) `[E]` | `[E]`; documented support: *"In a check suite, GitHub limits the number of check runs with the same name to 1000. Once these check runs exceed 1000, GitHub will start to automatically delete older check runs."* `[X]` — a per-name cap with oldest-first deletion only makes sense if same-named runs coexist. GitHub also says of a UI re-run: *"When this occurs, the GitHub App that created the check run will receive the `check_run` webhook **requesting a new check run**."* `[G]`, and of the rerequest endpoint: *"When a check run is rerequested, the status of the check suite it belongs to is reset to `queued` and the conclusion is cleared. **The check run itself is not updated.**"* `[X]` |
| Does `contexts.totalCount` change on a re-run? | **No.** Unchanged across the attempt-1 → attempt-2 transition in the specimen `[E]` | `[E]`; **`[!]` GitHub documents no de-duplication rule for the rollup** — `totalCount` is only *"Identifies the total count of items in the connection"* `[S]` |
| Can a rollup carry **two entries for one check name**? | **Not observed** — the rollup de-duplicated two `fast-gate` runs and three `Vercel Preview Comments` runs down to one each `[E]`. GitHub's docs neither promise nor forbid it `[!]` | `[E]` `[!]` |
| Does a re-run move the rollup **at a fixed head**? | **Yes, confirmed.** `fast-gate` went `failure` → `success` at commit `b1a9277` with no push, and its `databaseId` changed from `94099581164` to `94100420765` `[E]` | `[E]` |
| Legacy `StatusContext` — append or replace? | **Append on the commit, latest-per-context in the rollup.** Specimen: three `CodeRabbit` statuses on one commit (`Review queued` pending, `Review in progress` pending, `Review completed` success); the combined-status endpoint returns `total_count: 1` and the GraphQL rollup one node `[E]` | `[E]`; documented: *"there is a limit of 1000 statuses per sha and context within a repository"* `[Y]`, *"Statuses are returned in reverse chronological order. The first status in the list will be the latest one"* `[Y]`, and the combined state is *"success if the latest status for all contexts is success"* `[Y]`. **`[!]` GitHub never writes the sentence "the rollup returns only the latest status per context"** — it is inference from those three plus the specimen |
| Does a **ruleset change** that adds a required check add a context to the rollup with no push? | **Undocumented — and the docs point weakly against it.** The rules page says a required-check app *"must have recently submitted a check run"* `[K]`, and troubleshooting describes the blocked state in merge-box language — *"Associated checks stay in a 'Pending' state and block merging"*, *"Waiting for status to be reported"* `[T]` — never as a rollup entry. `StatusState` does carry `EXPECTED` (*"Status is expected."*) `[S]`, and `[C]` documents an `expected` check-run status meaning *"The check run is waiting for a status to be reported"*, but `CheckStatusState` has **no** `EXPECTED` member `[S]`. **No specimen available** | **`[!]`** — the whole row. What would settle it: create a ruleset requiring a name no app has reported on this commit, then re-read `contexts.totalCount`. Read-only mandate; not done |

### The two-layer answer, stated once

**The rollup is a projection, not a log.** Underneath it, both surfaces accumulate — check runs per
attempt, statuses per report, each capped at 1000 per name/context `[X]` `[Y]`. The rollup shows one
entry per name. So:

- **`contexts.totalCount` is a count of distinct reporting names, not of events** `[E]` `[!]`. The
  gate's `total` is therefore a stable-ish number that says nothing about how many times a check has
  run.
- **Every value in `contexts.nodes` is a snapshot.** A re-run, a new check run created by an app, or
  a new legacy status all rewrite it at a fixed head with no push `[X]` `[Y]` `[E]`.

### A note the loop should keep

CodeRabbit's own configuration reference says `commit_status` — *"Mirror review progress using
legacy commit statuses for compatibility with required checks and existing automations. **This
setting is only used when `review_progress` is disabled.**"* `[W]` — yet on this account CodeRabbit
emits legacy statuses and **zero** check runs `[E]`, matching the repo's existing measurement `[F]`.
Whatever the documented default is, the observed surface here is the legacy one. Reading both, as
`agent-loop.sh:146` already does, is the right call.

---

## Specimens

All reads read-only, 2026-08-29.

### S1 — V4: the merge base outlives the base tip

`nywleswoey/agentloop` PR #38.

```sh
gh api graphql -f query='query { repository(owner:"nywleswoey", name:"agentloop") {
  pullRequest(number:38) { headRefOid baseRefName baseRefOid merged files(first:1){totalCount} }
  ref(qualifiedName:"refs/heads/main") { target { oid } } } }'
# headRefOid 312cbdd8…  baseRefOid 8f1ec4fd…  main 6a9f0618…  files.totalCount 39

git merge-base 8f1ec4fd 312cbdd8            # -> 8f1ec4fd  (base sha *is* the merge base)
git diff --name-only 8f1ec4fd...312cbdd8 | wc -l   # -> 39, identical set to pulls/38/files
git diff --name-only main..312cbdd8                # -> empty; head is an ancestor of main
```

### S2 — V1: five of nine walkthroughs name a commit that is not the head

`nywleswoey/agentloop` PRs #35–#43. The full table is in Belief 2. The sharpest single case is #35:

```
head            05aeda7ba736737b2dcb6e9642c593b477a1e4ba
  committedDate 2026-08-28T02:28:06Z   author coderabbitai[bot]
  message       "Fix CodeRabbit issues in PR #35"
  parent        8a9d50a48a7374abcf7e1f0804826f2bf3f5e920

walkthrough     comment 5447201406
  createdAt     2026-08-28T01:21:48Z
  updatedAt     2026-08-28T01:24:23Z      <- never touched again
  block         **Merge Risk:** _🔵 Low_ · up to `8a9d5`

statuses on head
  2026-08-28T02:28:16Z  CodeRabbit  pending  "Review queued"
  2026-08-28T02:28:18Z  CodeRabbit  success  "Review completed"     <- 12 s after the commit

merged by hand 2026-08-28T02:44:49Z, walkthrough still naming 8a9d5
```

At that head the gate reads `block=parsed level=low abbrev=8a9d5 head=05aeda7b…`. Even with
`level` clearing, `head == abbrev*` fails. **V1 returns `no` and the loop escalates — and nothing
that happens next retracts it.**

### S3 — V2: a hand re-run at a fixed head

`nywleswoey/kids-collection` commit `b1a9277143159e4173ed13c7f3d12e5649565c40`, workflow run
`31592230455`.

```
attempt 1  run_started_at 2026-08-12T11:31:32Z  conclusion failure
  jobs: fast-gate  check-run 94099581164  failure
        pg-gate    check-run 94099581358  success
attempt 2  run_started_at 2026-08-12T11:35:06Z  conclusion success
  jobs: fast-gate  check-run 94100420765  success     <- NEW id
        pg-gate    check-run 94100421762  success     <- NEW id
  (same check_suite_id 85696569985 for both attempts)

commit check-runs, filter=latest (default)  -> total_count 3
commit check-runs, filter=all               -> total_count 7   (both fast-gate runs present)
GraphQL statusCheckRollup.contexts          -> totalCount 4
                                               checkRunCount 3, statusContextCount 1
                                               fast-gate = 94100420765 only
```

Head unchanged throughout. `fast-gate` moved `failure` → `success`; `totalCount` did not move.

### S4 — V2: legacy statuses append, the rollup shows one

`nywleswoey/agentloop` commit `0b1764f0b155139262a570271b4a9ef070ab0a8d` (PR #43 head, committed
2026-08-28T16:35:41Z — note the review began **seven hours later**):

```
GET /commits/{sha}/statuses   -> 3 records, all context "CodeRabbit"
  23:41:41Z pending  "Review queued"
  23:41:42Z pending  "Review in progress"
  23:46:48Z success  "Review completed"
GET /commits/{sha}/status     -> total_count 1, only the 23:46:48Z success
GraphQL statusCheckRollup     -> contexts.totalCount 1
```

Three rollup movements at one head, no push.

---

## What this changes for #47

The framing comment on [#47](https://github.com/nywleswoey/agentloop/issues/47#issuecomment-5460043717)
settled four things and offered a provisional classification pending this research, saying that
*"none of them changes a row's class"*. **That holds for V2 and V4. It does not hold for V1.**

### One row moves

| #47 row | Provisional class | Provisional "should be" | After this research |
|---|---|---|---|
| **V1 abbrev not a prefix of head** | **self** | `defer` | **operator- and loop-retractable** → `no` is permitted by #47's own rule. **This row moves.** |

The provisional class rested on the hypothesis in the framing comment: *"While a review is in flight
at the current head, the walkthrough plausibly still names the previous commit."* **That hypothesis
is falsified** on two independent grounds `[E]` `[F]`:

1. The walkthrough is edited **before** the terminal status, seven specimens out of seven.
2. The gate is unreachable while a review is in flight — the loop short-circuits to `reviewing` on a
   non-terminal newest signal.

What replaces it is not a smaller version of the same problem. It is a **different** problem with
the opposite class: a terminal review that leaves the walkthrough naming an older commit,
**permanently**, in five of nine recent pull requests. Nobody waiting fixes it. It is retracted only
by a write — a push, or a `@coderabbitai review` comment, which the loop itself is already capable
of making.

**So V1's abbrev branch is not a #112.** It is the opposite: a `no` that is *correct* to latch under
#47's rule, on a cause that is real and frequent. What it is *not* is a cause the handover currently
describes usefully — the operator is told *"CodeRabbit's merge-risk verdict does not clear this
commit"* when the true statement is *"CodeRabbit finished a review of this commit and did not
re-summarise it"*, and the remedy is a nudge the loop already knows how to post. **That belongs to
[Un-latching](https://github.com/nywleswoey/agentloop/issues/50), not to terminality** — which is
exactly where #47's framing comment put the loop-retractable class.

### Rows that hold, now sourced rather than assumed

| #47 row | Class | Confirmed by |
|---|---|---|
| V2 `failed>0` | **operator** ✓ | S3 — a hand re-run retracted a `failure` at a fixed head. The retraction required a click. `[E]` |
| V4 `guarded` non-empty | **operator** ✓ | S1 — the file list is merge-base-relative and does not move on a base advance. `[D]` `[E]` |
| V4 `truncated` | **operator** ✓ | Same. **`[!]` with one caveat**: soundness of `totalCount > (nodes \| length)` rests on undocumented connection semantics. |
| V1 block absent / unparseable | **operator** ✓ | The block's shape *has* changed under the loop (new `<details>` wrapper) and the capture still matched `[E]`. The tripwire is doing its job. |
| V1 level not `minimal` | **operator** ✓ | Still no documented ladder `[W]`; four levels seen live `[E]`. Unchanged. |

### And the two questions #47 asked directly

- **"Whether any input is stable at the head alone."** **No input is stable at the head alone.**
  V4's is the closest — stable at a fixed **merge base**, which is a function of two refs, not one.
  The framing comment already retired the cost argument for caching V1; this retires the stability
  argument too. **V1's walkthrough is the *least* stable of the three**: it can be edited at any
  time, and its abbreviation is routinely *behind* the head rather than at it.
- **"What the gate's actual invalidation condition is."** Nothing here changes the answer the
  framing comment reached. Every input must be re-read every pass; the read is atomic and happens
  regardless. What this research adds is that **V4's two `no`-branches are the only gate inputs
  whose value is a pure function of two commits**, and even they are not head-keyed.

---

## Rows that could not be established from primary sources

Listed plainly so they are not mistaken for findings.

1. **Whether a ruleset change that adds a required check adds a context to the rollup with no
   push.** Entirely undocumented `[!]`. What would settle it: add a required-check rule naming a
   context no app has reported on a test commit, then re-read `contexts.totalCount`. Not done —
   read-only mandate.
2. **Whether the rollup can ever carry two entries for one check name.** De-duplication observed
   `[E]`; GitHub documents no rule either way `[!]`. Note the union is `CheckRun | StatusContext`
   `[S]`, so a `StatusContext` and a `CheckRun` sharing a *name* is a case no specimen covered.
3. **Whether `files.totalCount` counts the same set `nodes` pages from.** Only generic connection
   semantics `[S]`; equal at n=39 `[E]`. V4's `truncated` derivation depends on it `[!]`.
4. **Whether the GraphQL `files` connection inherits REST's 3000-file cap.** Undocumented `[!]`.
   Immaterial at `first: 100`.
5. **Whether CodeRabbit's walkthrough body — not just the fortune placeholder — is edited in place
   on every later review.** Observed on every specimen `[E]`, documented for the placeholder only
   `[W]` `[!]`.
6. **What `@coderabbitai review` does at an unchanged head.** CodeRabbit frames every review command
   around new commits and never addresses the no-new-commit case `[W]` `[!]`. This is the assumed
   remedy for V1's stale abbreviation and it is **unsourced**.
7. **Whether CodeRabbit skips reviewing its own autofix output commits.** Four specimens with a
   nine-to-twelve-second *Review completed* say something is being skipped `[E]`; CodeRabbit
   documents no such rule `[W]` `[!]`.
8. **Whether the merge-risk level can change between two reviews of one commit.** Untested, and
   CodeRabbit documents nothing about determinism `[W]` `[!]`.
9. **Whether `baseRefOid` tracks the live base tip on an open pull request.** No open pull request
   was available `[!]`. Does not affect V4's verdict, which rests on the merge base.
