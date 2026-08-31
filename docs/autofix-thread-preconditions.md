# What CodeRabbit documents about the threads autofix declines to process

Research note for [#107](https://github.com/nywleswoey/agentloop/issues/107), part of the wayfinder
map [#62](https://github.com/nywleswoey/agentloop/issues/62). Written 2026-08-31. Companion to
[`research/coderabbit-surface.md`](https://github.com/nywleswoey/agentloop/blob/research/coderabbit-surface/research/coderabbit-surface.md),
which established that autofix pushes its own commit and covers findings that carry no committable
suggestion, and to
[`research/autofix-rate-limits.md`](https://github.com/nywleswoey/agentloop/blob/research/autofix-rate-limits/research/autofix-rate-limits.md),
which did the same job for autofix's *metering*. This note is about its *input set*.

The question this answers: **does CodeRabbit document a precondition on which pull-request review
threads `@coderabbitai autofix` will and will not process?** Four sub-questions — outdated threads,
resolved threads, threads autofix already acted on, and any cap or ordering that would make a live
observation ambiguous to read.

**The short version.**

- **Belief 2 — resolved threads: DOCUMENTED, and the loop's alignment claim
  (`agent-loop.sh:1546-1549`) is CONFIRMED verbatim.** It is not folklore. CodeRabbit's own
  reference page states it as a limitation: *"Autofix only processes unresolved CodeRabbit review
  threads with valid fix instructions."* `[A]` The claim is stated three more times, in the
  command reference `[C]`, the changelog `[N]`, and the blog `[B]`.
- **Belief 2b — a SECOND documented precondition the loop does not model.** The same sentence
  carries *"with valid fix instructions"*, and CodeRabbit defines those as the
  **🤖 Prompt for AI Agents** block `[A]` — which is **configurable off** via
  `reviews.enable_prompt_for_ai_agents`, default `true` `[R]`. `threads > 0` counts unresolved
  CodeRabbit threads; the bot's precondition is unresolved CodeRabbit threads *carrying an
  instruction block*. The alignment claim is therefore true but **not tight**: the loop can fire on
  a thread set the bot will decline.
- **Belief 1 — outdated / stale threads: NOT DOCUMENTED for the hosted bot.** The string
  *"outdated"* appears **nowhere** in CodeRabbit's 233-page documentation corpus in connection with
  autofix `[L]`, nor anywhere in the changelog `[N]`. **But CodeRabbit's own published autofix skill
  filters on it explicitly** — *"`isOutdated == false`"*, *"Ignore resolved and outdated CodeRabbit
  threads"* `[K]` — and so does the Cursor plugin's copy `[U]`. That is a **different
  implementation** (a client-side agent skill driving `gh`, not the hosted `@coderabbitai autofix`
  service), so it does not settle the hosted bot's behaviour. It is the strongest available hint,
  and it is a hint, not a rule.
- **Belief 3 — threads autofix already acted on: NOT DOCUMENTED, and the docs describe no such
  tracking.** No page mentions prior-run state, idempotency, or de-duplication for autofix `[L]`.
  The documented set is defined purely by *resolve state + instruction block + author*, all of which
  are unchanged by a previous autofix run — because autofix does not resolve what it fixes `[F]`.
- **Belief 4 — no per-run thread cap and no ordering are documented for the hosted bot.** The rate
  limits page caps *reviews* and *chat*, not threads per autofix run `[P]`; the autofix page says
  only *"Autofix may be rate-limited"* with no number `[A]`. Ordering is documented **only** for the
  client-side skill `[K]`. So an observation of "did it skip this one" is **not** made ambiguous by
  a documented cap — but nothing rules out an undocumented one either `[!]`.

**Verdict for [#108](https://github.com/nywleswoey/agentloop/issues/108): the observation is still
needed.** The one question the map's route hangs on — does the hosted bot decline an *outdated*
thread — is the one question the vendor's reference documentation does not answer. Same shape as the
[#59](https://github.com/nywleswoey/agentloop/issues/59) precedent. What #107 *does* retire is the
resolved-thread question, and it adds a precondition nobody had asked about.

---

## How to read the source column

Every claim below carries a tag. Claims tagged `[!]` are **not documented** by CodeRabbit and are
marked as inference; do not treat them as established. Claims tagged `[K]`, `[U]` or `[B]` are
first-party CodeRabbit artefacts but are **not the hosted bot's reference documentation** — see the
caveat on each.

| Tag | Source |
|---|---|
| `[A]` | [Autofix: apply CodeRabbit code fixes to pull requests](https://docs.coderabbit.ai/finishing-touches/autofix) — the feature's own reference page, and the only page that states a precondition. Retrieved 2026-08-31. |
| `[C]` | [Code review commands](https://docs.coderabbit.ai/reference/review-commands), the `@coderabbitai autofix` accordion. |
| `[R]` | [Configuration reference](https://docs.coderabbit.ai/reference/configuration) — `reviews.finishing_touches.autofix.enabled`, `reviews.enable_prompt_for_ai_agents`. |
| `[P]` | [Plans and pricing / Rate limits](https://docs.coderabbit.ai/management/plans#rate-limits), including the Fair Usage Limits Policy. |
| `[N]` | [Changelog](https://docs.coderabbit.ai/changelog) — full text via <https://docs.coderabbit.ai/changelog.md>, retrieved 2026-08-31. All four autofix entries read. |
| `[L]` | **The whole documentation corpus** — <https://docs.coderabbit.ai/llms-full.txt>, retrieved 2026-08-31. 233 `Source:` markers against 233 `<loc>` entries in <https://docs.coderabbit.ai/sitemap.xml>, so this is the complete site, and a `grep` miss here is a site-wide miss. |
| `[K]` | **CodeRabbit's published `autofix` agent skill** — [`coderabbitai/skills`](https://github.com/coderabbitai/skills), files [`skills/autofix/SKILL.md`](https://github.com/coderabbitai/skills/blob/main/skills/autofix/SKILL.md) and [`skills/autofix/github.md`](https://github.com/coderabbitai/skills/blob/main/skills/autofix/github.md) at `aa49953`. **Caveat: this is the client-side skill** the CodeRabbit CLI / Claude Code plugin installs, which drives `gh` from the user's machine. It is **not** the hosted `@coderabbitai autofix` service. Documented as a distinct thing at [CodeRabbit Skills](https://docs.coderabbit.ai/cli/skills). |
| `[U]` | [`coderabbitai/cursor-plugin`](https://github.com/coderabbitai/cursor-plugin) at `0066dea` — `skills/autofix/SKILL.md`, `commands/coderabbit-autofix.md`. Same caveat as `[K]`; an independent copy of the same rule. |
| `[B]` | **CodeRabbit's blog**, [*"You don't need to implement that. Autofix will."*](https://www.coderabbit.ai/blog/you-don-t-need-to-implement-that-autofix-will). First-party but **marketing prose, not reference documentation** — cited only where it agrees with `[A]`, and marked weak where it stands alone. |
| `[F]` | This repository — `agent-loop.sh`, and the notes on branches `research/coderabbit-surface` and `research/autofix-rate-limits`. |
| `[!]` | **Undocumented and inferred.** CodeRabbit does not state this. |

---

## Belief 1 — outdated / stale threads: does autofix skip them?

**Belief under test:** a thread whose diff anchor no longer exists at the head (GitHub's
`isOutdated`) is one the bot declines to process, and CodeRabbit says so.

### Verdict: **NOT DOCUMENTED.** The hosted bot's behaviour on an outdated thread is unstated.

The autofix page has a *Scope and limitations* section — CodeRabbit's own list of exactly this kind
of precondition. It has six bullets. Here they are in full `[A]`:

> - *"Autofix runs only on pull request events."*
> - *"Autofix scope depends on command location. An inline command scopes to the current review
>   thread only. A pull-request-conversation command scopes to all unresolved CodeRabbit review
>   threads. The review checkbox keeps a review-scoped selection."*
> - *"Autofix only processes unresolved CodeRabbit review threads with valid fix instructions."*
> - *"When the pull request has merge conflicts, Autofix exits without making changes."*
> - *"If no valid unresolved instructions are found, Autofix skips execution and reports that no
>   fixes were applied."*
> - *"Autofix may be rate-limited. If limits are exceeded, CodeRabbit responds with a wait time
>   before retrying."*

**Outdated is not among them.** Nor is anything anchor-shaped — no `isOutdated`, no "stale", no "the
line no longer exists", no "the diff has moved". The Troubleshooting accordion names the three
causes of a no-op run and outdating is not one of them: *"Resolve state, missing instruction blocks,
or non-CodeRabbit threads can lead to no-op runs."* `[A]`

Site-wide, the word **"outdated"** occurs eight times in the 233-page corpus and **not once near
autofix** `[L]`. The nearest hit is the dashboard's thread viewer — *"Each thread includes replies
and resolved or outdated indicators"* — which is a rendering fact about the review inbox, not a
statement about what autofix consumes. **"stale"** occurs sixteen times, all of them about learnings,
CLI skill records, PR inactivity (the 168-hour marker), Security Blast Radius snapshots, or Triage
summaries — none about autofix `[L]`. The changelog's four autofix entries (Feb 26, Apr 24, Jun 11,
Aug 25 2026) say nothing about it either `[N]`.

### But CodeRabbit's own skill filters on it, in so many words

This is the finding that makes the null result worth reading. CodeRabbit publishes an `autofix`
**agent skill**, and its source states the actionable set as a three-clause predicate:

> *"Treat only these threads as actionable:*
> - *root comment author is `coderabbitai`, `coderabbit[bot]`, or `coderabbitai[bot]`*
> - *`isResolved == false`*
> - *`isOutdated == false`"* `[K]`

and again in its Key Notes:

> *"**Preserve thread state** - Ignore resolved and outdated CodeRabbit threads"* `[K]`

The Cursor plugin carries an independent copy — *"Keep only unresolved, not-outdated root threads
authored by CodeRabbit"* `[U]`. The GraphQL query in both selects `isOutdated` alongside
`isResolved`, i.e. the field is fetched *in order to filter on it* `[K]` `[U]`.

**Why this does not close the question.** The skill is a **client-side** artefact: an agent
instruction file that runs `gh api graphql` from the developer's machine and commits locally
(`git commit -m "fix: apply CodeRabbit auto-fixes"`) `[K]`. The hosted `@coderabbitai autofix`
command is a service-side pipeline that clones the repository and pushes its own commit `[A]` `[F]`.
CodeRabbit documents them as separate products, on separate pages. **`[!]` Inferring the hosted
bot's predicate from the skill's predicate is inference** — the most informed inference available,
from the vendor's own hand, but inference.

Two readings, and the note takes neither:

- **`[!]`** The skill encodes CodeRabbit's house notion of an actionable thread, and the service
  applies the same one. Then `isOutdated` is exactly the predicate #62 is hunting.
- **`[!]`** The skill filters `isOutdated` because a *local* agent must apply a patch at a live line
  anchor, and an outdated anchor makes that mechanically unsafe. The service re-derives its own
  context from a fresh clone and may not need the guard at all.

Only [#108](https://github.com/nywleswoey/agentloop/issues/108) separates them.

---

## Belief 2 — resolved threads: is "unresolved only" documented or folklore?

**Belief under test:** `agent-loop.sh:1546-1549` claims *"That is also the bot's own precondition —
autofix processes unresolved CodeRabbit threads — so the loop's trigger condition and the bot's are
the same predicate."* Is that sourced?

### Verdict: **DOCUMENTED, four times over. Confirmed.**

| Where | What it says | Tag |
|---|---|---|
| Autofix page, *Scope and limitations* | *"Autofix only processes **unresolved** CodeRabbit review threads with valid fix instructions."* | `[A]` |
| Autofix page, *How it works*, step 2 | *"CodeRabbit scans **unresolved** review threads started by CodeRabbit and gathers fix instructions from the **Prompt for AI Agents** blocks."* | `[A]` |
| Command reference | *"An inline reply within a CodeRabbit review thread limits the fix to that thread's unresolved finding. A comment in the pull request conversation processes **all unresolved CodeRabbit review threads**."* | `[C]` |
| Changelog, 25 Aug 2026 | *"An inline `@coderabbitai autofix` command now fixes only the current review thread's unresolved finding. Running the command in the pull request conversation still processes all unresolved CodeRabbit review threads."* | `[N]` |

The **author** half of the loop's predicate is documented in the same sentences — *"review threads
**started by** CodeRabbit"* `[A]`, and the Troubleshooting note that *"non-CodeRabbit threads"* cause
no-op runs `[A]`. That matches `agent-loop.sh:1619` exactly: the filter is
`.comments.nodes[0].author.login | is_coderabbit`, the **first** comment's author `[F]`.

The blog states the *consequence* the loop depends on, which is the useful form:

> *"Autofix processes all unresolved CodeRabbit review comments. If there's a specific comment you
> don't want it to touch … just resolve that comment manually before running Autofix. Hit the
> 'Resolve conversation' button on GitHub, then trigger the command. **Autofix will skip it.**"*
> `[B]`

> *"Autofix is **aggressive about applying what's open**, but it respects what you've explicitly
> closed."* `[B]`

`[B]` is marketing prose and is cited here only because it restates `[A]`. **`[!]` The second
sentence — that "what's open" is the *whole* set, with no further exclusion — is the reading #62
would most like to be true, and it is exactly the reading a blog post's rhetoric cannot establish.**
Do not let it stand in for #108.

### Belief 2b — the precondition nobody asked about

The documented rule is not *unresolved*. It is **unresolved AND carrying a fix instruction**:

> *"Autofix only processes unresolved CodeRabbit review threads **with valid fix instructions**."*
> `[A]`

> *"Autofix only acts on unresolved CodeRabbit review comments that include **structured fix
> instructions**. … **missing instruction blocks** … can lead to no-op runs."* `[A]`

> *"If **no valid unresolved instructions** are found, Autofix skips execution and reports that no
> fixes were applied."* `[A]`

The instruction is the **🤖 Prompt for AI Agents** block `[A]` `[B]`, and it is a configuration
switch:

> `enable_prompt_for_ai_agents` (boolean) — *"Include the '🤖 Prompt for AI Agents' section in
> inline review comments to provide codegen instructions for AI agents."* Defaults to `true`. `[R]`

**Consequences for the map.**

- The loop's alignment claim is **true but loose**. `threads` (`agent-loop.sh:1618-1619`) counts
  unresolved CodeRabbit-opened threads; the bot's set is a **subset** of that. A metered run that
  does nothing *is* reachable today, on a thread with no instruction block — independently of
  anything to do with outdating.
- **`[!]` How often that bites is unmeasured.** Nothing says which findings get a block; the config
  default is on, and this repo has never turned it off `[F]`. Whether a repository at
  `enable_prompt_for_ai_agents: false` gets *zero* autofix-eligible threads while `threads > 0`
  stays permanently true is undocumented and would be a cheap thing to reason about before shipping
  any filter.
- The signal is **not free**, unlike `isOutdated`. Detecting an instruction block means reading
  comment **bodies**; `query_pr_state` fetches thread comments' `databaseId`, `createdAt` and
  `author` only (`agent-loop.sh:1468`) `[F]`.

---

## Belief 3 — does autofix track its own prior work?

**Belief under test:** the bot remembers threads it has already fixed and declines them on a second
run.

### Verdict: **NOT DOCUMENTED, and the documented model leaves no room for it.**

Nothing in the corpus mentions prior-run state, de-duplication, or idempotency for autofix. The word
*"idempotent"* occurs six times, all about the Learnings API and one Cursor demo transcript `[L]`.
No page describes autofix reading its own commits, its own summary comments, or a run ledger `[L]`
`[N]`.

What CodeRabbit *does* document is a set defined by three properties of the thread as it stands —
resolve state, author, presence of an instruction block `[A]` — **none of which a previous autofix
run changes**, because autofix does not resolve what it fixes (confirmed live on
[#56](https://github.com/nywleswoey/agentloop/pull/56), still `isResolved: false`) `[F]`. Read literally, the documented predicate says a second `@coderabbitai autofix` **re-processes
every thread the first one fixed.** `[!]` That is a reading of the docs, not a statement in them.

Worth noting what CodeRabbit *does* provide instead of tracking: a separate command,
`@coderabbitai resolve` — *"Marks all CodeRabbit review comments as resolved"* `[C]`. **`[!]` That it
is the intended way to retire a fixed thread is inference.** It is a blunt instrument — *all*
comments, not the fixed ones — and this loop has no seam for issuing it (`pr-writeback.sh` is one
write per invocation) `[F]`.

---

## Belief 4 — is there a cap, or an ordering, that would blur a live observation?

**Belief under test:** a documented per-run thread cap or a documented processing order could make
"autofix skipped this thread" unreadable off a single observation — the thread might merely have
fallen off the end of a batch.

### Verdict: **NO documented cap and NO documented ordering for the hosted bot.** #108 is readable.

| Question | Answer | Tag |
|---|---|---|
| Cap on threads per autofix run? | **None documented.** The autofix page's only limit sentence is *"Autofix may be rate-limited. If limits are exceeded, CodeRabbit responds with a wait time before retrying."* — a throttle, not a batch size. | `[A]` |
| Any numeric cap anywhere that could apply? | The rate-limits table caps **PR/IDE/CLI reviews per developer per hour** and **chat messages per hour**, plus **files per review** (*"the maximum number of files CodeRabbit reviews in a single review"*, 300 on Pro+). None is a thread count, and none is attributed to autofix. | `[P]` |
| Does an autofix run consume a PR review? | Not a #107 question, and already settled elsewhere: autofix is **absent** from the enumeration of what spends the PR review pool, and which pool it *does* draw from is undocumented. See branch `research/autofix-rate-limits`, §1. | `[P]` `[F]` |
| Processing order? | **Undocumented for the hosted bot.** Documented only for the client-side skill: *"**Preserve ordering** - Keep display order aligned with unresolved current threads; process fixes by severity only after display"*, and *"review 'Fix' issues in severity order (CRITICAL first)"*. | `[A]` `[L]` `[K]` |
| Partial delivery? | Autofix delivers **even on verification failure** — *"Even if verification fails, the generated changes are still delivered so you can continue iterating."* So a partial diff is expected and is **not** evidence of a skipped thread. Design #108 to read the *thread*, not the diff's completeness. | `[A]` |
| Hard stops that would abort the run entirely? | **Two, both documented and both detectable before the fact.** Merge conflicts: *"When the pull request has merge conflicts, Autofix exits without making changes"* / *"Autofix stops before cloning or generating changes when the platform reports that the pull request is not mergeable."* And the config/plan gate: with `reviews.finishing_touches.autofix.enabled: false` or below Pro, *"CodeRabbit declines any `@coderabbitai autofix` request and points to this setting."* | `[A]` `[R]` |

**What #108 must control for**, then: run it on a **mergeable** pull request (`mergeable: MERGEABLE`
is already in `query_pr_state` `[F]`), on Pro or higher with autofix enabled, and put **one** live
non-outdated thread alongside the outdated one so a no-op run is distinguishable from a declined
thread. The absence of a documented cap means a two-thread specimen is enough.

---

## Pages checked

So the next reader does not re-walk them. The corpus grep `[L]` covers **every** page in the
sitemap; these are the ones read in full because they were the plausible homes for the answer.

**Where a precondition would live, and does (partly):**

- <https://docs.coderabbit.ai/finishing-touches/autofix> — the *Scope and limitations* and
  *Troubleshooting* sections are the whole documented answer. Read in full.
- <https://docs.coderabbit.ai/reference/review-commands> — `@coderabbitai autofix` accordion.
- <https://docs.coderabbit.ai/reference/configuration> — `reviews.finishing_touches.autofix.enabled`,
  `reviews.enable_prompt_for_ai_agents`.

**Where it plausibly could have lived, and does not:**

- <https://docs.coderabbit.ai/finishing-touches> — overview; links only.
- <https://docs.coderabbit.ai/guides/commands> — command index; one row for autofix, no preconditions.
- <https://docs.coderabbit.ai/changelog> (full text: `/changelog.md`) — four autofix entries, none
  about thread eligibility beyond resolve state.
- <https://docs.coderabbit.ai/management/plans> — rate limits and Fair Usage; reviews and chat only.
- <https://docs.coderabbit.ai/pr-reviews/walkthroughs>, `/reference/glossary`, `/faq`,
  `/overview/architecture` — no autofix precondition (via `[L]`).
- <https://docs.coderabbit.ai/cli/skills> and `/agent/skills` — describe the client-side skill in
  prose (*"Fetch unresolved review threads authored by CodeRabbit"*) and, notably, **omit the
  outdated filter that the skill's own source carries**. The docs are a lossy rendering of `[K]`.

**Whole-corpus greps that came back empty** (against `llms-full.txt`, 233/233 pages `[L]`):
`outdated` near autofix · `stale` near autofix · `isOutdated` · `idempot` near autofix ·
`already fixed` / `already applied` / `previously fixed` · any thread-count cap for autofix ·
any ordering statement for the hosted bot.

**First-party, non-documentation sources that did answer:**

- <https://github.com/coderabbitai/skills> `skills/autofix/SKILL.md`, `skills/autofix/github.md`
  (`aa49953`) — `isOutdated == false`. **Client-side skill, not the hosted bot.**
- <https://github.com/coderabbitai/cursor-plugin> `skills/autofix/SKILL.md`,
  `commands/coderabbit-autofix.md` (`0066dea`) — same rule, independent copy.
- <https://www.coderabbit.ai/blog/you-don-t-need-to-implement-that-autofix-will> — **weak.**
  Restates `[A]` on resolve state; says nothing about outdating.

Also enumerated and rejected: `coderabbitai/coderabbit-pr-review` (README only),
`coderabbitai/awesome-coderabbit`, `coderabbitai/vscode-extension` (issues only) — no autofix
predicate.

---

## Incidental, not asked for

Two things surfaced that belong to neighbouring tickets rather than this one.

- **The loop does not paginate `reviewThreads`.** `query_pr_state` reads `reviewThreads(first: 100)`
  with no `pageInfo` (`agent-loop.sh:1468`) `[F]`. CodeRabbit's own skill paginates with a cursor
  loop over the same connection `[K]`. At 100+ threads on one pull request the loop's `threads`
  count silently truncates. Out of scope for #62; someone should know.
- **The rate-limits page is unchanged on the point that matters to
  [#60](https://github.com/nywleswoey/agentloop/issues/60).** `@coderabbitai autofix` is still absent
  from the enumeration of what spends a PR review `[P]`, six days after
  `research/autofix-rate-limits` recorded the same absence. **`[!]` Absence from a list is not a
  statement that it is free.**
