# What CodeRabbit's reply to a command carries, and what the free-OSS review meter is

Research note for [#87](https://github.com/nywleswoey/agentloop/issues/87), part of the wayfinder
map [#86](https://github.com/nywleswoey/agentloop/issues/86). Written 2026-08-30.

The question this answers: when the loop posts `@coderabbitai review`, what does CodeRabbit tell it —
in prose and out of prose — and what is the pool the command draws on.

**The short version.** The first critical question comes back **yes, established**. The second comes
back **no** — and taking it apart broke a premise the map is built on.

1. **A non-prose discriminator exists.** CodeRabbit sets a **commit status** on the pull request head
   with `context: "CodeRabbit"` and a short enumerated `description` — `Review queued`,
   `Review in progress`, `Review completed`, `Review rate limited`,
   `Review skipped: manual review required for this OSS repository`, `Review skipped: draft pull request`.
   CodeRabbit **documents** this check and its title. The `state` field is *not* the discriminator —
   a rate-limited review reports `state: success` **by design** — so the signal is the `description`
   string, which is a closed vocabulary in a structured API field, not prose in a comment body.
   It has one hole: the *already-reviewed* refusal sets **no status at all**.
2. **The scope is two ceilings, and the live evidence cannot say which one bound.** CodeRabbit's own
   words are *"enforced **per developer** over rolling time windows. OSS PR review limits are
   additionally scoped per repository."* So a shared account-level pool is **documented** to exist —
   but going back through every rate-limit refusal since 2026-08-22, **every one but a single
   anomaly is fully explained by that repository's own last review**, so the specimens do not prove
   the account-level ceiling was ever the binding one. **The map's account-wide claim, and the pair
   of timestamps it rests on, do not survive.** See
   [What this changes for the map](#what-this-changes-for-the-map).
   **Autofix does not draw on the review meter** — CodeRabbit's list of what consumes a review omits
   autofix, and a specimen has autofix running to completion inside a window where review was refused.

Three premises in the map need correcting, and are flagged in
[What this changes for the map](#what-this-changes-for-the-map).

---

## How to read the source column

Every claim carries a tag. Claims tagged `[!]` are **not stated by CodeRabbit anywhere**; they are
inference from the texts and specimens below and must not be treated as established.

| Tag | Source |
|---|---|
| `[P]` | [Plans and pricing — Rate limits](https://docs.coderabbit.ai/management/plans#rate-limits). Retrieved 2026-08-30. |
| `[F]` | [Plans and pricing — Fair Usage Limits Policy](https://docs.coderabbit.ai/management/plans#fair-usage-limits-policy). Retrieved 2026-08-30. |
| `[W]` | [Plans and pricing — When a review is rate-limited](https://docs.coderabbit.ai/management/plans#when-a-review-is-rate-limited). Retrieved 2026-08-30. |
| `[C]` | [Command reference](https://docs.coderabbit.ai/reference/review-commands). Retrieved 2026-08-30. |
| `[E]` | Empirical, from `gh api` against `nywleswoey/{agentloop,kids-collection,finance-manager,todo-togo}` on 2026-08-30. Every `[E]` claim names its specimen. |
| `[!]` | **Undocumented and inferred.** |

All timestamps are UTC, as GitHub returns them.

---

# Half one — the reply's shape

## The reply comment is written twice

Every `@coderabbitai review` gets exactly one reply comment, and **that comment is created in a
provisional state and edited in place to its outcome**. At creation, an accepted and a refused
command are byte-for-byte indistinguishable apart from the invocation id. `[E]`

finance-manager#162, comment `5466860250`, GraphQL `userContentEdits`:

| At | Body |
|---|---|
| `2026-08-30T05:12:20Z` (created) | `<summary>Action performed</summary>` … `Review triggered.` |
| `2026-08-30T05:12:28Z` (edit) | `<summary>⚠️ Action not completed</summary>` … `Review rate limited.` |

finance-manager#162, comment `5467677040` — the one command of the four that landed:

| At | Body |
|---|---|
| `2026-08-30T08:38:15Z` (created) | `<summary>Action performed</summary>` … `Review triggered.` |
| `2026-08-30T08:45:13Z` (edit) | `<summary>✅ Action performed</summary>` … `Review finished.` |

Reproduce with:

```
gh api graphql -f query='{node(id:"IC_kwDOQ3j6M88AAAABRdmq2g"){... on IssueComment{
  userContentEdits(first:20){nodes{editedAt diff}}}}}'
```

Two consequences the loop has to live with. First, **the outcome is only in the edit** — a reader
that fetches the reply within a few seconds of the command sees `Action performed / Review triggered.`
regardless of what actually happens. Second, the accepted comment's edit lands at *review completion*
(`08:45:13`, 7 minutes after the command), while the refused comment's edit lands at *refusal*
(`05:12:28`, 8 seconds). So a reply still reading `Action performed / Review triggered.` after a minute
is evidence of acceptance, not of nothing having happened — but only weak evidence. `[!]`

## The full set of reply shapes observed

Scan of every `coderabbitai[bot]` issue comment on the 15 most recently updated pull requests in each
of the four repos (107 comments). `[E]`

Command acknowledgements — identified by the **two-line preamble**, which is the same on all of them:

```
<!-- This is an auto-generated reply by CodeRabbit -->
<!-- CodeRabbit review command invocation: v2:<64 hex> -->
```

| `<summary>` | First line | Count | Specimen |
|---|---|---|---|
| `Action performed` (no glyph) | `Review triggered.` | every reply, at creation | fm#162 `5466860250` @ `05:12:20` |
| `✅ Action performed` | `Review finished.` | 13 | agentloop#74 `5467677801` @ `2026-08-30T08:38:25Z` |
| `⚠️ Action not completed` | `Review rate limited.` | 13 | agentloop#74 `5467744700` @ `2026-08-30T08:54:43Z` |
| `⚠️ Action not completed` | ``Already reviewed the last commit. Use `@coderabbitai full review` to rerun a review of the entire changeset.`` | 1 | agentloop#61 `5462864049` @ `2026-08-29T14:07:58Z` |

That last row is the answer to the ticket's question 4: **the hard no-op at an already-walkthroughed
head established in [#59](https://github.com/nywleswoey/agentloop/issues/59) is not an acceptance.**
CodeRabbit refuses it, under the same `⚠️ Action not completed` summary as a rate limit. Trigger
comment `nywleswoey` @ `2026-08-29T14:07:52Z`, reply 6 seconds later.

**Chat replies are a different shape** and must not be confused with a command acknowledgement. They
carry the first preamble line but **not** the `command invocation` line, and have no
`<details>/<summary>` wrapper. Specimen: agentloop#61 `2026-08-29T14:18:04Z`, and the `rate limit`
answer below. So *`<!-- CodeRabbit review command invocation:` present* is itself a clean, non-prose
test for "this comment is an answer to a command". `[E]`

The `v2:<hex>` is confirmed an **identity, not an outcome**: it is byte-identical across the created
and the edited body of the same reply (see the edit tables above), and the `v2:` prefix is constant
across all 27 acknowledgements. `[E]`

## Non-prose discriminators: what exists

| Candidate | Verdict |
|---|---|
| **Commit status `context: "CodeRabbit"`** | **Works.** See below. Documented. |
| HTML marker inside the reply comment | No. Identical preamble on accept and refuse. `[E]` |
| Reactions on the reply comment | No. `/reactions` is `[]` on both the accepted `5467677040` and the refused `5466860250`. `[E]` |
| GraphQL comment fields | No. `author_association`, `performed_via_github_app` (app id `347564`, slug `coderabbitai`) are identical on accepted and refused. `[E]` |
| Check runs | No. `/check-runs` on both heads of fm#162 lists only `vercel` and `github-actions` apps — CodeRabbit publishes **no check run**. `[E]` |
| `v2:<hex>` invocation id | No — identity only, as above. |
| A distinct comment *type* | No. Both are plain issue comments on the pull request. `[E]` |

### The commit status is the discriminator

`GET /repos/{o}/{r}/commits/{sha}/statuses`, filtered to `context == "CodeRabbit"`. finance-manager#162,
head `94c048a61f21a04ff40666454476520faf3219a6`: `[E]`

```
2026-08-30T08:45:12Z  state=success  desc="Review completed"
2026-08-30T08:38:17Z  state=pending  desc="Review in progress"
2026-08-30T05:18:00Z  state=success  desc="Review rate limited"
2026-08-30T05:17:53Z  state=pending  desc="Review in progress"
2026-08-30T05:15:05Z  state=success  desc="Review skipped: manual review required for this OSS repository"
2026-08-30T05:14:59Z  state=pending  desc="Review queued"
```

Each command produces a `pending / Review in progress` followed by a terminal `success / <outcome>`,
within seconds of the reply comment. The `05:17:41` nudge → reply `05:17:50` → status pair
`05:17:53` / `05:18:00`. The `08:38:09` nudge → reply `08:38:15` → status pair `08:38:17` / `08:45:12`.

CodeRabbit documents it: *"CodeRabbit posts a rate-limit comment on the pull request and a passing
check titled **“Review rate limited”** — the check passes by design so it never blocks merging on
protected branches."* `[W]`

Note the two traps that sentence sets.

- **`state` is useless.** `success` covers `Review completed`, `Review rate limited`,
  `Review skipped: …`. Only `description` separates them, and the docs say the pass is deliberate.
  `[W]` `[E]`
- **The docs say the comment is authoritative, not the check** — *"The comment is the authoritative
  signal that no review ran."* `[W]` CodeRabbit is describing the check as a UI convenience. It is
  nevertheless a stable, structured, enumerated field, and it is the only non-prose outcome signal
  that exists.

Full observed `description` vocabulary across 08-29/08-30 in all four repos: `[E]`

| `description` | `state` | Meaning |
|---|---|---|
| `Review queued` | `pending` | An event was accepted for consideration |
| `Review in progress` | `pending` | A review run started |
| `Review completed` | `success` | Terminal, accepted |
| `Review rate limited` | `success` | Terminal, refused for meter |
| `Review skipped: manual review required for this OSS repository` | `success` | Terminal, the <10-stars rule |
| `Review skipped: draft pull request` | `success` | Terminal, draft. agentloop#61 `2026-08-29T11:25:58Z` |

### Where the status signal fails

Three holes, all `[E]`:

1. **The already-reviewed refusal sets no status.** agentloop#61's `⚠️ Action not completed /
   Already reviewed the last commit.` at `2026-08-29T14:07:58Z` produced nothing — the last CodeRabbit
   status on any commit of that pull request is `2026-08-29T11:44:07Z`. That refusal is
   **reply-comment-only**.
2. **A force-push orphans the evidence.** The `05:12:20` refusal on fm#162 has no status on either
   commit currently in the pull request; `94c048a6` was committed at `05:14:48`, after the refusal.
   The status was written to a sha that is no longer reachable from the head.
3. **`Review completed` also covers a no-op.** fm#162 `230308f8` reads `08:54:36 queued` →
   `08:54:38 completed`, two seconds apart, on a push whose commits were already reviewed. Duration is
   the only separator, and duration is not a field. `[!]`

## Is the glyph stable, and is any of it documented as an interface

The `⚠️` / `✅` glyphs are stable across all 26 terminal acknowledgements in the sample, and they
survive nothing else: CodeRabbit documents **none** of the reply shapes — not the summary strings, not
the reason lines, not the HTML markers. The command reference documents only what you type, never what
comes back. `[C]` The single documented piece of the response surface is the rate-limit check title,
in `[W]`. So the glyph is *observed*-stable and *undocumented*, which is exactly the standing reason
not to parse CodeRabbit prose. The status `description` is in the same position on documentation —
except that one of its six values is quoted verbatim in CodeRabbit's docs, and it lives in a GitHub
API field rather than a rendered comment body.

---

# Half two — the meter

## What it counts

> *"Each PR review run uses one PR review from this allowance, including automatic incremental
> reviews after new pushes, manual `@coderabbitai review`, and manual `@coderabbitai full review`."*
> `[P]`

So the unit is a **review run**, not a command, not a commit, not a file, not a token. `[P]`

Two things follow, both stated:

- **A refused command costs nothing.** *"A blocked push does not consume a review or delay when your
  next review becomes available. Capacity is limited by earlier reviews in the rolling window, not by
  the current push."* `[W]` This is directly relevant to the map's open *repeat nudge at one head*
  item: the three refused nudges on fm#162 did not deplete anything.
- **`Files/review` is a cap, not a meter.** *"The `Files/review` column is the maximum number of
  files CodeRabbit reviews in a single review, not an hourly limit."* `[P]`

## Its rate and reset

Published table `[P]`, reviews **per developer per hour**:

| Plan | PR | IDE | CLI | Files/review | Chat |
|---|---|---|---|---|---|
| Free | 1 | 3 | 3 | 150 | N/A |
| OSS | **1–10** | 1 | 3 | 100–300 | 25 |
| Pro | 5 | 5 | 5 | 150 | 50 |
| Pro+ | 10 | 10 | 10 | 300 | 100 |
| Enterprise | 12 | 12 | 12 | 300 | 100 |

The OSS row is a range because *"OSS PR review rate limits vary by repository star count"* `[P]`.
All four watched repos have **0 stars**, which puts them at the bottom of the range. CodeRabbit
publishes no star-count-to-rate mapping. `[!]` The observed rate is **one review per hour**, which is
what a 0-star repo at the floor of `1–10` would be.

**It is a rolling window, not a fixed cadence and not a queue position.** `[P]`:

> *"Each limit is a rolling allowance rather than a one-time quota: additional reviews become
> available as earlier reviews age out of the window instead of resetting all at once at the top of
> the hour."*

The specimens confirm the window is **60 minutes measured from the start of the consuming review**.
Each rate-limit banner states `Next included review available in N minutes`; adding N to the banner's
own timestamp gives the reset instant. `[E]`

| Banner written at | Says | Implied reset | Preceding accepted review start | +60 min |
|---|---|---|---|---|
| kids-collection#138 `04:01:05` | 4 minutes | `04:05:05` | kc#137 `03:05:27` | `04:05:27` |
| finance-manager#162 `05:12:25` | 11 minutes | `05:23:25` | fm#161 `04:23:41` | `05:23:41` |
| finance-manager#162 `05:17:57` | 5 minutes | `05:22:57` | fm#161 `04:23:41` | `05:23:41` |
| agentloop#74 `08:54:51` | 43 minutes | `09:37:51` | al#74 `08:38:25` | `09:38:25` |
| finance-manager#162 `08:55:11` | 43 minutes | `09:38:11` | fm#162 `08:38:17` | `09:38:17` |

Every row lands within ~40 seconds of `start + 60 min`, and each row's preceding review is in the
same repository as the banner — which is why these support the *window* but say nothing about the
*scope*. Banner bodies recovered from
`userContentEdits` on the walkthrough comment — e.g. node `IC_kwDOQ3j6M88AAAABRdlbcw` (fm#162
`5466839923`), node `IC_kwDOTU6NQs8AAAABRdWd6A` (kc#138 `5466594792`).

**The rate is not constant — it degrades with the account's own recent volume.** `[F]`:

> *"When one developer identity reaches the 95th percentile or higher of recent CodeRabbit PR review
> usage, CodeRabbit uses that developer's recent PR review activity in a rolling window to gradually
> space out additional reviews. Depending on the activity, the applicable window can be the past 24
> hours or the past 7 days."*

The published refill tables bottom out at *"1 review/hour, one review at a time"* — at 60+ reviews in
7 days on Pro, 90+ on Pro+. `[F]` **CodeRabbit publishes no such table for OSS.** `[!]`

The specimens show the degradation happening. On 2026-08-29 the account got three accepted reviews
inside 33 minutes (`11:06:38`, `11:26:03`, `11:39:58`) with no refusal. By 2026-08-30 every attempt
outside a 60-minute spacing was refused. `[E]` The practical consequence for the map: **the loop
cannot compute a fixed budget.** The refill rate is a function of the loop's own past week.

## Its scope — two ceilings, and the specimens cannot separate them

CodeRabbit's own sentence `[P]`:

> *"The following review and chat limits are enforced **per developer** over rolling time windows.
> OSS PR review limits are additionally scoped per repository."*

That is one sentence describing **two ceilings**. `additionally` reads as an extra per-repository cap
stacked on the per-developer one, not as a replacement — so an account-level pool shared across
repositories is documented to exist. Its OSS size is the `1–10/hour` row, varying by star count `[P]`.
The per-repository cap's size is published nowhere. `[!]`

**Neither is per-organisation and neither is global**: CodeRabbit says *"per developer"* and the Fair
Usage text speaks of *"one developer identity"* `[P]` `[F]`. All four repos have one owner and one
committer, so the specimens cannot distinguish per-developer from per-owner. `[!]`

**The live evidence cannot say which ceiling bound any observed refusal.** Every `Review rate limited`
status across the four repos since 2026-08-22 — ten of them — was cross-checked against the set of
accepted reviews (`Review in progress` followed by `Review completed`) in the preceding 60 minutes:
`[E]`

| Refusal | Same repo, prior hour | Other repo, prior hour |
|---|---|---|
| `2026-08-29 16:55:20` agentloop#71 | agentloop#72 `16:55:16` | kids-collection#136 `16:55:10` |
| `2026-08-29 23:45:12` agentloop#71 | **none** | **none** |
| `2026-08-30 03:49:49` kids-collection#137 | kids-collection#137 `03:05:27` | none |
| `2026-08-30 03:55:29` kids-collection#135 | kids-collection#137 `03:05:27` | none |
| `2026-08-30 04:01:06` kids-collection#138 | kids-collection#137 `03:05:27` | none |
| `2026-08-30 04:36:14` finance-manager#161 | finance-manager#161 `04:23:41` | agentloop#73 `04:23:45` |
| `2026-08-30 05:18:00` finance-manager#162 | finance-manager#161 `04:23:41` | agentloop#73 `04:23:45` |
| `2026-08-30 08:55:01` agentloop#74 | agentloop#74 `08:38:25` † | finance-manager#162 `08:38:17` |
| `2026-08-30 08:55:23` finance-manager#162 | finance-manager#162 `08:38:17` | none |
| `2026-08-30 09:22:09` finance-manager#163 | finance-manager#162 `08:38:17` | none |

† agentloop#74's `08:38` review is invisible in the status API — its statuses were written to a sha
that was force-pushed away before `77ba40a`. It is attested by reply comment `5467677801`
(`08:38:25Z` created, edited `08:47:56Z` to `✅ Action performed / Review finished.`) and by the
walkthrough comment's own edit history (`review in progress` at `08:38:38`, walkthrough at `08:47:42`).

**Nine of the ten refusals have a same-repository explanation**, so a purely per-repository meter of
one review per hour fits the whole dataset as well as an account-wide one does. Worse, the three
occasions on which two repos were accepted almost simultaneously — finance-manager `04:23:41` with
agentloop `04:23:45`; finance-manager `08:38:17` with agentloop `08:38:25`; kids-collection `16:55:10`
with agentloop `16:55:16` — are the *normal* case under a per-repository meter and would each have to
be a separate admission race under an account-wide one-per-hour meter. The per-repository reading is
the more parsimonious fit to the specimens.

The tenth refusal fits neither: agentloop#71 at `2026-08-29T23:45:12Z`, banner reading `59 minutes`,
with no accepted review anywhere in the four repos since `17:02:28`. Either a review ran outside the
four repos, or the `59 minutes` is a floor rather than a computed countdown. Not established. `[E]`

**So the honest position is:** the account-level pool is real because CodeRabbit says so `[P]`; the
per-repository cap is real because CodeRabbit says so `[P]`; and at 0 stars, in the throttled regime
these repos are in, the observations are consistent with the per-repository cap being the binding one.
The map's inference — *"kids-collection#137 was refused at 03:49:38 and finance-manager#162 at
05:12:20 — two repos, one pool"* — does not hold: kids-collection#137's refusal is explained by
kids-collection#137's own `03:05:27` review, and finance-manager#162's by finance-manager#161's
`04:23:41` review in the same repository.

**Consequence for the spec.** *A refusal seen anywhere applies everywhere* cannot be justified from
this evidence, and adopting it would suppress nudges the meter would in fact have honoured — an
under-fire, which the map itself names as the worse failure. Firing and reading the outcome costs
nothing against the meter `[W]`, so the conservative design is to keep firing per repository and read
the refusal, not to propagate it. A refusal seen in repo A is at most a *hint* about repo B.

## Autofix draws on a different meter

**Documented, by omission and by feature list.** The list of what consumes a PR review names
automatic incremental reviews, `@coderabbitai review`, and `@coderabbitai full review` — and stops.
`[P]` Autofix appears on the plans page only as a Pro feature, never in the rate-limit table, which
has rows for PR, IDE, CLI and Chat and none for autofix. `[P]`

**Confirmed live**, and the specimen is scope-neutral because it stays inside one pull request. On
2026-08-30 agentloop#74's review was accepted at `08:38:25` and finished by `08:47:56`, locking that
pull request's review capacity until ~`09:38` under either the per-developer or the per-repository
reading. Inside that lock: `[E]`

- agentloop#74 autofix status comment `5467722009` created `08:49:18`, reporting
  *"Coding task complete and ready for review"* by `08:53:25`.
- agentloop#74's `@coderabbitai review` at `08:54:46` → **`Review rate limited`** at `08:55:01`.
- Same pattern on finance-manager#162: review accepted `08:38:15`, autofix comment `5467721850`
  created `08:49:16` and complete by `08:54:33`, review refused `08:55:04`.

Autofix ran to completion on the same pull request whose review was refused six minutes later. And in
the entire 107-comment sample, **no autofix status comment ever reports a rate limit** — its failure
modes are `Cannot run autofix: This PR has merge conflicts.` (fm#118 `5383133289`),
`The agent ran but didn't make any changes.` (fm#118 `5384249310`), and
`An unexpected error occurred while generating fixes: Not Found` (agentloop#73 `5466811941`).

**This prices [#55](https://github.com/nywleswoey/agentloop/issues/55)'s `other-head` remedy
asymmetrically**: the autofix half is free against this meter; the review that follows it is not, and
is exactly the spend that fm#162's `08:54:34` post-autofix nudge lost to a refusal.

Autofix has its own markers and identifiers: `<!-- This is an auto-generated comment: autofix status
by CodeRabbit -->`, plus `<!-- autofix-run-id: <uuid> -->` and, for coding-agent runs,
`<!-- coding-agent-task-id: <uuid> -->`. `[E]` What limits autofix is not established. `[!]`

## The `<10 stars` rule is a different policy from the meter

They are two policies that happen to be printed on the same documentation page, and they are keyed on
the same variable (star count) for different purposes.

**The rule** `[P]`:

> *"For public repositories with less than 10 stars, CodeRabbit requires reviews to be triggered
> manually. Select `Trigger review` in the CodeRabbit status comment, or comment
> `@coderabbitai review` for the latest changes or `@coderabbitai full review` for a full review."*

That is a statement about **who pulls the trigger**. The meter is a statement about **how many runs
fit in an hour**. Distinct: a 0-star repo with allowance left gets a review the moment you ask; a
100-star repo out of allowance does not.

Both are exposed structurally, and differently. `[E]`

| Policy | HTML marker in the walkthrough comment | Commit status `description` |
|---|---|---|
| `<10 stars`, no auto-review | `<!-- This is an auto-generated comment: skip review by coderabbit.ai -->` … `<!-- end of auto-generated comment: skip review by coderabbit.ai -->` | `Review skipped: manual review required for this OSS repository` |
| Meter exhausted | `<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->` … `<!-- end of auto-generated comment: rate limited by coderabbit.ai -->` | `Review rate limited` |

The `skip review` block's prose is *"This repository does not receive automatic reviews because it has
fewer than 10 stars."* and it carries the checkbox the map notes:
`- [ ] <!-- {"checkboxId":"e9bb8d72-00e8-4f67-9cb2-caf3b22574fe"} --> 🔍 Trigger review`. Specimen:
agentloop#70 comment `5463662485` @ `2026-08-29T16:53:21Z`.

On the checkbox: CodeRabbit lists `Trigger review` and `@coderabbitai review` as two ways to do the
same thing `[P]`, and what the allowance charges for is a *review run* `[P]` — so ticking it is
almost certainly the same spend. CodeRabbit does not say so. `[!]`

## The walkthrough comment's banner is a state slot, not a log

This matters more than it looks, because `RATE_LIMIT_MARKER` (`agent-loop.sh:94`) is tested against
this comment.

The `summarize by coderabbit.ai` comment holds **one** state block at a time, and CodeRabbit
overwrites it on every transition. Recovered edit history of fm#162 comment `5466839923`
(node `IC_kwDOQ3j6M88AAAABRdlbcw`): `[E]`

| Edit | State block present | Banner |
|---|---|---|
| `05:06:56` (created) | `skip review` | |
| `05:12:25` | `rate limited` | 11 minutes |
| `05:13:09` | `skip review` | |
| `05:15:02` | `skip review` | |
| `05:17:57` | `rate limited` | 5 minutes |
| `08:38:24` | `review in progress` | |
| `08:38:59` | `review in progress` | |
| `08:45:07` | *(none — walkthrough)* | |
| `08:55:11` | `rate limited` | 43 minutes |

The `rate limited` block written at `05:12:25` was gone by `05:13:09` — a window of **44 seconds**.
The same pattern on agentloop#74: `rate limited` at `08:54:51`, gone by `08:55:13`, a window of **22
seconds**. `[E]` It is not always transient — kids-collection#138's block, written `04:01:05`, is
still the current body — but it survives only until the next state event.

So the loop's existing test is sound in what it looks for and structurally unable to catch it: a
poll that does not land inside a sub-minute window sees a walkthrough comment with no marker on it.
That is the mechanism behind the map's *"the loop could not tell an accepted command from a refused
one"*. The refusal was in the walkthrough comment, briefly, and in a separate reply comment,
durably — and the loop was reading the first at the wrong moment.

## The balance is readable before spending

**Yes, by command.** `[C]`:

> `@coderabbitai rate limit` — *"Displays your remaining PR review allowance and when the next review
> becomes available **without consuming a review**"*

Aliases `rate-limit`, `limits`, `quota`, and natural-language forms such as
`@coderabbitai reviews remaining?`. `[C]` `[P]`

**Live specimen**, taken for this note: `@coderabbitai rate limit` posted to the *merged* pull request
agentloop#73 (comment `5468095661`, `2026-08-30T10:18:00Z`). Reply `5468096092` at `10:18:06Z`, six
seconds later: `[E]`

```
<!-- This is an auto-generated reply by CodeRabbit -->
Your [plan](…#fair-usage-limits-policy) includes PR reviews subject to [rate limits](…#rate-limits).
Reviews are available now.
```

What that specimen establishes and what it does not:

- It **works on a merged pull request**, so a balance read need not touch a live one. `[E]`
- It is a **chat reply**, not a command acknowledgement — no `command invocation` marker, no
  `<details>`, no commit status. `[E]`
- The answer is **prose with no count**. CodeRabbit says richer output is possible — *"When adaptive
  limits apply, CodeRabbit can show the number of reviews currently available and the applied hourly
  refill rate"* `[W]` — but the observed reply carries none of it, and the exhausted-state wording was
  not captured. `[E]`

**There is no free read.** `@coderabbitai rate limit` is a comment write plus a comment read — it
does not spend a review, but it does spend a write against `pr-writeback.sh`'s one-write-per-invocation
seam and a poll to collect the answer. Against the map's **no new read cost** constraint it is a new
cost, and against **degrades toward spending** it is strictly worse than simply firing the review:
firing costs nothing when refused `[W]`, and a refusal is legible in the commit status the loop
already fetches.

**There is no header, endpoint, or unauthenticated marker for the balance.** Nothing in GitHub's API
surfaces it; the commit status appears only after an attempt. `[E]` `[!]`

---

## Autofix ran while the same repository's review meter was locked

Worth separating out, because it is the one cross-cutting claim that holds under either scope reading.
agentloop#74's own review was accepted at `08:38:25` and its own meter was therefore locked until
~`09:38` — and agentloop#74's autofix status comment `5467722009` was created at `08:49:18` and
reported *"Coding task complete and ready for review"* by `08:53:25`, inside that lock. The same
pull request's `@coderabbitai review` at `08:54:46` was refused at `08:55:01`. `[E]`

---

# What this changes for the map

Three premises in [#86](https://github.com/nywleswoey/agentloop/issues/86) need adjusting.

1. **"The nudge path deliberately parses no CodeRabbit prose" is no longer the binding constraint on
   reading a refusal.** The commit status `description` is a structured field with six observed
   values, one of which CodeRabbit quotes verbatim in its own docs, and the map's standing constraints
   already name *"the status rollup"* as a signal the loop fetches. Reading `Review rate limited` off
   it is not prose-parsing in the sense the rule was written to forbid. The rule does still bind for
   the **already-reviewed** refusal, which sets no status and lives only in the reply comment.
2. **The destination's point 2 — *"a refusal seen anywhere applies everywhere — the free-OSS pool is
   account-wide"* — is not established, and the two timestamps cited for it do not carry it.**
   kids-collection#137 `03:49:38` and finance-manager#162 `05:12:20` each have a same-repository
   review inside the preceding hour (kids-collection#137's own `03:05:27`; finance-manager#161's
   `04:23:41`). Across every refusal since 2026-08-22, nine of ten are same-repo-explained and the
   tenth is explained by nothing. CodeRabbit documents *both* a per-developer pool and an additional
   per-repository OSS cap `[P]`, and at 0 stars the per-repository cap is the more parsimonious fit.
   Building account-wide backpressure on this evidence would under-fire, which the map's own standing
   constraints rank as the worse failure. **The item needs a decisive experiment before it can be
   specified** — see the suggested one below.

3. **"A wasted command costs seconds" understates the case in the loop's favour.** A refused command
   costs *nothing* against the meter and does not push the reset out `[W]`, which strengthens
   *degrades toward spending* to near-free — and removes most of the motive for conservation
   machinery in the first place. What the loop loses to a refusal is *latency*, not budget.

And one correction of fact: the map records the three refusals on finance-manager#162 as carrying
*"no such marker"*. They did carry one — a `rate limited` block briefly present in the walkthrough
comment, and a `Review rate limited` commit status on the head. The loop missed the first because the
block is overwritten within a minute, and never looked for the second.

## The experiment that would settle the scope

Cheap, and it spends at most one review. When a repository has just had a review accepted and is
therefore locked, post `@coderabbitai rate limit` on a pull request in **that** repository and on one
in a **different** repository within the same minute. `@coderabbitai rate limit` consumes no review
`[C]`, works on merged pull requests `[E]`, and answers in under ten seconds `[E]`. If the two
answers disagree, the cap is per repository; if they agree and both say unavailable, the pool is
shared. The specimen taken for this note (`Reviews are available now.`) was recorded outside a lock
and so decides nothing.

# Could not be established

Every question below was left open, and why.

| Question | Why not established |
|---|---|
| **The exact OSS refill rate for a 0-star repo** | CodeRabbit publishes `1–10 reviews/hour` for OSS and says it *"varies by repository star count"* `[P]`, but no star-to-rate table anywhere. Observed behaviour is one per 60 minutes. Inference, not a stated number. |
| **The OSS Fair-Usage refill table** | The adaptive tables in `[F]` are published for Pro and Pro+ only. Whether the OSS tier degrades on the same 24h/7d curve is not stated, though the observed drop from three-in-33-minutes on 08-29 to one-per-hour on 08-30 is consistent with it. |
| **Whether more than one review can be in flight per repository** | Never observed. Every accepted pair in the sample is in two different repositories (fm#161 `04:23:41` with agentloop#73 `04:23:45`; fm#162 `08:38:17` with agentloop#74 `08:38:25`; kc#136 `16:55:10` with agentloop#72 `16:55:16`). Whether that reflects a per-repository cap of one, or a shared bucket of two, or an admission race, cannot be told apart from the outside. |
| **The `59 minutes` at `2026-08-29T23:45:11Z`** | agentloop#71 refused with no accepted review anywhere in the four repos since `17:02:28`. Either an unobserved review (a fifth repo, or an IDE/CLI run under a different limit) or a default figure. No source settles it. |
| **Whether the meter is per developer or per account owner** | CodeRabbit says *"per developer"* and *"one developer identity"* `[P]` `[F]`. All four repos have one owner and one committer, so the specimens cannot separate the two. |
| **Which ceiling — per-developer or per-repository — actually bound any observed refusal** | **The headline gap.** Nine of ten refusals since 2026-08-22 have a same-repository explanation; the tenth has none at all. The two ceilings are documented `[P]` but their OSS sizes are not, and no natural experiment in the sample separates them. The [suggested experiment](#the-experiment-that-would-settle-the-scope) would. |
| **The size of the per-repository OSS cap** | CodeRabbit states OSS limits are *"additionally scoped per repository"* `[P]` and publishes no number for that scoping — only the `1–10/hour` per-developer OSS row. |
| **Whether `🔍 Trigger review` is metered like `@coderabbitai review`** | Both are listed as manual triggers for the same repo class `[P]` and the allowance charges per *review run* `[P]`, so it almost certainly is. Never stated, and not exercised — the loop has never ticked the box. |
| **Whether the loop can tick the checkbox at all** | Not investigated. It would require editing CodeRabbit's own comment body, which is a write to another app's comment. |
| **What limits autofix** | Established that it is *not* the PR review allowance. Its own meter, if any, is documented nowhere on the plans page and no autofix run in the sample was ever refused for capacity. |
| **The exhausted-state wording of `@coderabbitai rate limit`** | The one live specimen was taken while capacity was available and returned *"Reviews are available now."* `[W]` describes richer exhausted-state output but does not quote it, and forcing exhaustion to capture it would have cost real reviews. |
| **Whether any reply shape is a supported interface** | CodeRabbit documents no reply body, summary string, glyph, or HTML marker `[C]`. The rate-limit check title is the sole documented element of the response surface `[W]`. Everything else here is observation of an undocumented surface and can change without notice. |
| **Refusal shapes not seen** | The ticket asks about *not installed*, *no seats*, *unsupported base*. None occurred in the sample; CodeRabbit documents none of them. Only *rate limited*, *already reviewed*, *draft*, and *manual-trigger-required* are attested. |

---

## Reproducing the specimens

```sh
# reply shapes, all four repos
gh api "repos/nywleswoey/finance-manager/issues/162/comments" --paginate \
  --jq '.[] | select(.user.login=="coderabbitai[bot]") | {id, created_at, updated_at, body}'

# the outcome is in the edit, not the creation
gh api graphql -f query='{node(id:"IC_kwDOQ3j6M88AAAABRdmq2g"){... on IssueComment{
  userContentEdits(first:20){nodes{editedAt diff}}}}}'

# the non-prose discriminator
gh api "repos/nywleswoey/finance-manager/commits/94c048a61f21a04ff40666454476520faf3219a6/statuses" \
  --jq '.[] | select(.context=="CodeRabbit") | "\(.created_at) \(.state) \(.description)"'

# the banner is a state slot, not a log
gh api graphql -f query='{node(id:"IC_kwDOQ3j6M88AAAABRdlbcw"){... on IssueComment{
  userContentEdits(first:50){nodes{editedAt diff}}}}}'

# the pre-spend read
gh api repos/nywleswoey/agentloop/issues/73/comments -f body='@coderabbitai rate limit'
```
