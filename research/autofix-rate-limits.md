# Autofix rate limits: what an unattended poller can rely on

Research for the `@coderabbitai autofix` path in `agent-loop.sh`, which posts autofix commands on
open PRs unattended, on a ~5 minute cadence.
Date of investigation: 2026-08-25.

## How to read this file

Every claim is tagged:

- **[DOC]** — stated by CodeRabbit's own documentation. URL given.
- **[OBS]** — observed against live GitHub data. The exact command is given; re-run it to check.
- **[UNKNOWN]** — could not be determined from any primary source. Treated as a finding in its own
  right, not a gap to guess across.

Where **[DOC]** and **[OBS]** disagree, both are shown and the disagreement is called out.

Sources are CodeRabbit's own docs (fetched as raw Markdown — Mintlify serves every page at
`<url>.md`, and the full page list is at <https://docs.coderabbit.ai/llms.txt>), CodeRabbit's
changelog, and live CodeRabbit-authored comments on public GitHub PRs read through the GitHub API.
No blog posts or third-party summaries were used.

**Method note.** The whole documentation corpus was pulled and grepped, not spot-checked:

```
curl -sL https://docs.coderabbit.ai/llms.txt \
  | grep -oE 'https://docs\.coderabbit\.ai/[^)]+\.md' | sort -u   # → 228 pages, all fetched
grep -rniE "rate.?limit" docs/
```

That matters for the negative results below: when this note says a thing is undocumented, it means
it appears on **none** of the 228 pages, not that one likely page was checked.

---

## The short answer

1. **Autofix is not listed as a consumer of the "included reviews per hour" pool, but its own limit
   is unnamed and unnumbered.** The docs enumerate what spends the PR review pool and autofix is not
   in that list; a separate per-plan **Chat** pool exists but is never defined. Which pool an
   `@coderabbitai autofix` trigger draws from is **[UNKNOWN]**. See §1.
2. **What the account observes when an autofix is rate-limited is [UNKNOWN].** Docs promise "a wait
   time before retrying", but across 112 real autofix-status comments harvested from public repos,
   nine distinct shapes appear and **none of them is a rate-limit or wait-time variant**. The
   *review* rate-limit path, by contrast, is fully documented and fully observed. See §2.
3. **Yes, the review limits are documented per plan**, with a full table and a second table of
   fair-usage degradation tiers. See §3.
4. **No machine-readable autofix budget signal exists anywhere.** See §4.
5. **The single most dangerous finding for this loop is not a rate limit at all** — it is that the
   rate-limit notice is written *into an existing comment by editing it*, leaving `created_at`
   untouched and up to 7 days stale. A poller that keys on "comments newer than head SHA" will never
   see it. See §5.1.

---

# 1. Does autofix draw from the "included reviews per hour" pool?

## 1a. What the docs say *does* spend the review pool — an enumeration autofix is absent from

**[DOC]** <https://docs.coderabbit.ai/management/plans#rate-limits>

> Each PR review run uses one PR review from this allowance, including automatic incremental reviews
> after new pushes, manual `@coderabbitai review`, and manual `@coderabbitai full review`.

Three consumers are named. `@coderabbitai autofix` is not among them, and no other page adds it.

**[DOC]** The same coupling is restated for incremental reviews, again without mentioning autofix
(<https://docs.coderabbit.ai/configuration/auto-review#auto_pause_after_reviewed_commits>):

> Automatic incremental reviews count toward the same per-developer PR review rate limit as manual
> PR reviews.

**Caveat, stated plainly:** the word is "including", not "only". The enumeration is not formally
closed, so its silence on autofix is suggestive, not dispositive.

## 1b. There is a second pool — "Chat" — which is never defined

**[DOC]** The rate-limits table (<https://docs.coderabbit.ai/management/plans#rate-limits>) has a
`Chat` column distinct from the PR / IDE / CLI review columns:

| Plan | PR reviews/hr | IDE | CLI | Files/review | Chat |
| --- | --- | --- | --- | --- | --- |
| Free | 1 (summary only) | 3 | 3 | 150 | N/A |
| OSS | 1–10 (varies by star count) | 1 | 3 | 100–300 | 25 |
| Pro | 5 | 5 | 5 | 150 | 50 |
| Pro+ | 10 | 10 | 10 | 300 | 100 |
| Enterprise | 12 | 12 | 12 | 300 | 100 |

**[DOC]** The header reads "The following review **and chat** limits are enforced **per developer**
over rolling time windows."

**[UNKNOWN] — what counts as a "chat message".** Grepping all 228 doc pages for a definition returns
nothing. No page says whether an `@coderabbitai <command>` comment is a chat message, whether only
free-form questions are, or whether commands are exempt. The `Chat` column has numbers but no
referent.

## 1c. Autofix's own limit — asserted, never quantified

**[DOC]** <https://docs.coderabbit.ai/finishing-touches/autofix> — under "Scope and limitations",
this is the **entire** text on the subject, and the only autofix rate-limit sentence in the corpus:

> Autofix may be rate-limited. If limits are exceeded, CodeRabbit responds with a wait time before
> retrying.

Note this is one sentence longer than the brief quoted — the second clause promises an observable
response, which §2 tests.

**[OBS]** Verified as the sole occurrence:

```
grep -rniE "rate.?limit" docs/ | grep -i autofix
→ ./finishing-touches__autofix.md:216:* Autofix may be rate-limited. If limits are exceeded,
  CodeRabbit responds with a wait time before retrying.
```

**[DOC]** The "Feature limits" section of the plans page — which does give per-plan numbers for
linked repositories, MCP servers, custom finishing-touch recipes and custom pre-merge checks — has
**no autofix entry**. So autofix has no documented per-plan feature cap either.

## 1d. Verdict on question 1

**[UNKNOWN].** Autofix has *a* limit, by CodeRabbit's own assertion. Which pool it draws from is not
established:

- It is **not named** among the three documented consumers of the PR review pool (§1a) — weak
  evidence it is separate.
- A separate Chat pool exists with real per-plan numbers, but nothing ties commands to it (§1b).
- No third pool is ever named, and no number is ever attached to autofix specifically (§1c).

The honest reading is that autofix is governed by an **unnamed, unnumbered limit** that CodeRabbit
declines to specify. Do not assume the walkthrough's "6 remain after this review" meter describes
autofix budget — that line is explicitly about *included reviews* (§4).

---

# 2. What does the account actually observe when the limit is hit?

## 2a. For a *review*, this is fully specified and fully observable

**[DOC]** <https://docs.coderabbit.ai/management/plans#when-a-review-is-rate-limited>

> When a push is rate-limited, CodeRabbit posts a rate-limit comment on the pull request and a
> passing check titled **"Review rate limited"** — the check passes by design so it never blocks
> merging on protected branches. The comment is the authoritative signal that no review ran. A
> previously approved PR keeps its approval.

and:

> A blocked push does not consume a review or delay when your next review becomes available.
> Capacity is limited by earlier reviews in the rolling window, not by the current push.

**[OBS]** The comment is real and its marker HTML is stable. Found by searching GitHub for the
marker and reading bodies through the API:

```
gh api -X GET /search/issues \
  --field q='"auto-generated comment: rate limited by coderabbit.ai" in:comments is:pr'
gh api /repos/junidmoh-code/marathon-store-app/issues/421/comments \
  --jq '.[] | select(.user.login=="coderabbitai[bot]") | .body'
```

Body (abridged; a `> ` blockquote throughout):

```
<!-- This is an auto-generated comment: summarize by coderabbit.ai -->
<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->

> [!WARNING]
> ## Review limit reached
>
> You've reached a temporary PR review limit under our [Fair Usage Limits Policy](...).
> Your current included review allowance is based on your included PR review attempts over the past 7 days.
>
> **Next review available in:** **43 minutes**
>
> **Limit details:** You've used the included review currently available. Your 91 included PR review
> attempts over the past 7 days set your current allowance at 1 review per hour.
>
> Your organization has reached its usage spending cap. ...
```

Three things are machine-readable here: the marker `<!-- This is an auto-generated comment: rate
limited by coderabbit.ai -->`, the `**Next review available in:** **43 minutes**` line, and the
attempt count. A closing `<!-- end of auto-generated comment: rate limited by coderabbit.ai -->`
marker also exists.

**[OBS]** This example independently confirms the fair-usage table in §3: 91 attempts in 7 days →
1 review/hour, exactly the Pro+ "90+" tier. The degradation is real, not theoretical.

**[OBS] — a discrepancy worth flagging.** The docs say a blocked push "does not consume a review",
but the comment counts "included PR review **attempts** over the past 7 days" as the input that sets
the allowance. Attempts, not completed reviews. If rate-limited attempts count as attempts, a poller
that retries into a limit could hold its own allowance down. Not resolvable from either source; the
two statements are in tension and neither is elaborated.

## 2b. For *autofix*, the answer is not established

Docs promise a response (§1c: "responds with a wait time before retrying"). To find its shape, all
autofix-status comments reachable through GitHub search were harvested and classified:

```
gh api -X GET /search/issues \
  --field q='"auto-generated comment: autofix status by CodeRabbit" in:comments is:pr' \
  --field per_page=40
# then, per PR, select coderabbitai[bot] comments matching "autofix status by CodeRabbit"
```

**[OBS]** 112 autofix-status comments across 40 public PRs. Splitting on the marker and bucketing by
first meaningful line gives **nine** distinct shapes:

| Count | First line of body |
| --- | --- |
| 38 | `Autofix skipped. No unresolved CodeRabbit review comments with fix instructions found.` |
| 23 | `> [!NOTE]` (beta banner, then one of the other shapes) |
| 19 | `## Fixes Applied Successfully` |
| 17 | `❌ Failed to start the Coding Agent task. Please try again.` |
| 5 | `❌ **Cannot run autofix: This PR has merge conflicts.**` |
| 3 | `An unexpected error occurred while generating fixes: Not Found - <github docs url>` |
| 3 | `Coding Agent is not enabled for this organization.` |
| 2 | `❌ Failed to clone repository into sandbox. Please try again.` |
| 1 | `⚠️ **Branch updated during autofix.**` |
| 1 | `The agent ran but didn't make any changes. ...` |

**None is a rate-limit or wait-time variant.** Greping the harvested bodies for
`rate|limit|wait|retry|queue` matches only the beta banner's "Expect some **limit**ations" and the
"Please try again" strings above.

**[UNKNOWN] — the autofix rate-limit response.** What could not be established:

- Whether the response is an autofix-status comment, a chat-reply comment, or an edit.
- What marker HTML it carries.
- Whether the command is queued and answered later, and with what ceiling. **No page in the corpus
  mentions queueing or deferral of autofix.** The one doc sentence says "responds with a wait time
  **before retrying**", which reads as *you* retry, not *it* retries — i.e. not queued — but this is
  inference from one preposition, not a documented statement, and is not claimed here as fact.
- Whether, on a plan/permission failure, nothing is posted at all.

**What was tried:** the full 228-page doc corpus grep; the changelog; GitHub comment search on the
autofix-status marker (112 comments); and targeted GitHub searches for
`autofix "rate limited" "try again in"`, `autofix "please wait" coderabbitai`, and
`"Autofix rate limit"` — GitHub's comment search is word-based rather than phrase-exact, so those
returned large fuzzy counts with no true positives on inspection. A rate-limited autofix was not
deliberately provoked on this account, since doing so would spend real budget and, per §2a's
attempt-counting discrepancy, might depress the allowance.

## 2c. The comment kind a command reply uses

Useful for §2b even though the rate-limited autofix case was not found: CodeRabbit's replies to
*commands* are a distinct comment kind from both walkthroughs and autofix-status comments.

**[OBS]** `gh api /repos/HadesArchitect/ExpoPlusCodeRabbit/issues/29/comments`:

```
<!-- This is an auto-generated reply by CodeRabbit -->
<!-- CodeRabbit review command invocation: 004805e6-c5b8-4232-86b6-4026c5a7ecbf -->
<details>
<summary>✅ Action performed</summary>

Full review finished.

---

You're currently rate limited under our [Fair Usage Limits Policy](...). Your next review will be
available in 55 minutes.

</details>
```

So there are **three** distinct CodeRabbit comment kinds a loop must tell apart, each with its own
marker:

| Kind | Marker |
| --- | --- |
| Walkthrough / summary | `<!-- This is an auto-generated comment: summarize by coderabbit.ai -->` |
| Rate-limit notice | `<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->` (inside the summarize comment) |
| Autofix status | `<!-- This is an auto-generated comment: autofix status by CodeRabbit -->` |
| Command reply | `<!-- This is an auto-generated reply by CodeRabbit -->` + `<!-- CodeRabbit review command invocation: <uuid> -->` |

**[OBS]** Every autofix-status shape carries a trailing `<!-- autofix-run-id: <uuid> -->` **except**
`Coding Agent is not enabled for this organization.`, which has no run-id. A parser keyed on the
run-id marker will silently miss that failure mode.

---

# 3. Are the rate limits documented per plan?

**Yes, for reviews — in unusual detail.** **[DOC]**
<https://docs.coderabbit.ai/management/plans#rate-limits> — the table is reproduced in §1b.

Also documented:

**[DOC]** Limits are **per developer**, not per repo or per org (OSS additionally scoped per
repository). They are **rolling windows**, not hourly resets:

> Each limit is a rolling allowance rather than a one-time quota: additional reviews become
> available as earlier reviews age out of the window instead of resetting all at once at the top of
> the hour.

**[DOC] Fair Usage Limits Policy** — a second, sharper limit layered on top, keyed to a **7-day**
window. This is the one that bites an unattended loop:

Pro+ tiers (<https://docs.coderabbit.ai/management/plans#fair-usage-limits-policy>):

| Recent PR review activity | Review availability |
| --- | --- |
| 0–29 reviews in the last 7 days | 10 reviews/hour |
| 30–39 | 8/hour |
| 40–49 | 6/hour |
| 50–59 | 5/hour |
| 60–69 | 4/hour |
| 70–79 | 3/hour |
| 80–89 | 2/hour |
| 90+ | **1 review/hour, one review at a time** |

Pro degrades on the same shape from 5/hour to 1/hour at 60+ reviews in 7 days.

**[DOC]** Free plan is "PR summarization only" — code review is not available on PRs at all. OSS PR
limits "vary by repository star count" (1–10), and **[DOC]** "For public repositories with less than
10 stars, CodeRabbit requires reviews to be triggered manually."

**[DOC]** Autofix requires "a **Pro plan or higher**" — so on a Free or OSS repo the autofix command
is unavailable regardless of budget. **[UNKNOWN]** what a Free/OSS repo returns when sent
`@coderabbitai autofix`; when autofix is disabled *by config* the docs say "CodeRabbit declines any
`@coderabbitai autofix` request and points to this setting", but the plan-ineligible case is not
described. The observed `Coding Agent is not enabled for this organization.` shape (§2b) may be the
nearest analogue, but that is an org-capability message, not a plan message, so it is not claimed as
the answer.

**Machine-readable plan string.** **[OBS]** The walkthrough's run-configuration block prints
`**Plan**: Pro Plus` on this repo, and the same field reads `**Plan**: Pro Plus` in the third-party
rate-limited example in §2a — so the string is stable across accounts and worth parsing if the loop
spans repos on different plans. **[UNKNOWN]** the exact strings for Free, OSS, Pro and Enterprise;
only `Pro Plus` was observed.

---

# 4. Is there a machine-readable signal of remaining autofix budget?

**No. [UNKNOWN] — and this is a firm negative across all 228 doc pages plus the observed comment
corpus.**

What exists is all **review** budget, never autofix:

**[OBS]** The walkthrough meter line, inside the `ℹ️ Recent review info` details block
(`gh api /repos/nywleswoey/agentloop/issues/2/comments`):

```
**Included review availability:** Your plan provides up to 10 included reviews per hour; 6 remain after this review.
```

**[DOC]** Its origin is a changelog entry, "Rate limit visibility", 28 April 2026
(<https://docs.coderabbit.ai/changelog>):

> CodeRabbit now shows remaining PR review quota in review walkthroughs, including when the bucket
> refills. You can also comment `@coderabbitai rate limit` or ask a clear question like
> `@coderabbitai reviews remaining?` to get the same status without starting a new review.

**[DOC]** The `@coderabbitai rate limit` command
(<https://docs.coderabbit.ai/reference/review-commands>) — "Displays your remaining **PR review**
allowance and when the next review becomes available without consuming a review". Aliases
`rate-limit`, `limits`, `quota`. It is explicitly free to call: it does not consume a review. But it
reports **PR review** allowance only; nothing in its description or in any observed reply mentions
autofix.

**[DOC]** The public REST API surface is administrative, not budget-facing. `X-RateLimit-Limit` /
`-Remaining` / `-Reset` headers exist on CodeRabbit's own API endpoints (metrics, users, org
listings — e.g. "Max 10 requests per 60 seconds per organization"), but those govern **calls to
CodeRabbit's management API**, not review or autofix allowance. There is no endpoint that reports
review or autofix budget.

So: the meter line answers "how many reviews remain". Nothing anywhere answers "how many autofixes
remain".

---

# 5. Other things an every-5-minutes poller should know

## 5.1. The rate-limit notice is delivered by *editing* an old comment — the biggest trap here

This is the finding most likely to break a loop that keys on comment recency.

**[OBS]** The rate-limit block lives **inside the walkthrough/summarize comment**, not in a new
comment — its body begins with the `summarize by coderabbit.ai` marker and only then the
`rate limited by coderabbit.ai` marker (§2a). Scanning creation vs. update timestamps across the
matched PRs shows **both** delivery paths occur:

```
gh api /repos/<owner>/<repo>/issues/<n>/comments --jq '.[]
  | select(.user.login=="coderabbitai[bot]")
  | "id=\(.id) created=\(.created_at) updated=\(.updated_at)
     summarize=\(.body|test("summarize by coderabbit"))
     ratelimited=\(.body|test("rate limited by coderabbit"))"'
```

Created **with** the block (fresh PR, no prior walkthrough):

```
thefabulous/grunt-inline #2   created=2026-08-19T22:13:08Z updated=2026-08-19T22:13:08Z
kustomer/multer-s3 #24        created=2026-08-20T18:16:12Z updated=2026-08-20T18:16:12Z
api7/ngx_multi_upstream_module #22  created=2026-08-21T09:58:52Z updated=2026-08-21T09:58:52Z
```

Block added later by **editing** a long-lived walkthrough comment:

```
OmniNode-ai/omnibase_infra #2764  created=2026-08-17T03:58:18Z updated=2026-08-24T05:03:22Z   (7 days)
Comfy-Org/ComfyUI_frontend #15467 created=2026-08-20T04:34:04Z updated=2026-08-25T01:33:15Z   (5 days)
stranske/Workflows #3205          created=2026-08-23T14:33:39Z updated=2026-08-23T19:07:05Z
TaoSama/vibe-screen #290          created=2026-08-22T17:49:49Z updated=2026-08-23T17:25:21Z
```

**Consequence for this loop.** On any PR that already has a walkthrough — which is every PR the loop
will act on — the rate-limit notice arrives as an **edit**. `created_at` does not move; it stays at
the original walkthrough time, observed here up to **7 days stale**. Any state machine that filters
CodeRabbit comments to "newer than the head SHA" or "created since last poll" **will never see the
rate-limit notice**, and will read a stale walkthrough as a fresh successful review.

Mitigations, in order of robustness: compare `updated_at` rather than `created_at`; test the
walkthrough body for the `rate limited by coderabbit.ai` marker on every poll regardless of
timestamp; and treat the "Review rate limited" commit status as a corroborating signal — **[DOC]**
noting it is a **passing** check by design, so a green checks summary does *not* mean a review ran.

## 5.2. Every push spends review budget, and the default makes that worse than it looks

**[DOC]** `reviews.auto_review.auto_pause_after_reviewed_commits` defaults to **5**
(<https://docs.coderabbit.ai/configuration/auto-review#auto_pause_after_reviewed_commits>) —
CodeRabbit auto-pauses incremental reviews after 5 reviewed commits since the last pause. With no
`.coderabbit.yaml` committed (this repo's situation), that default is in force. Combined with
**[DOC]** `auto_incremental_review` defaulting to `true`, each of the first 5 pushes to an open PR
spends one included review.

Note the interaction with autofix: an autofix run **pushes a commit** (observed in
`research/coderabbit-surface.md` — commit `1859566` authored by `coderabbitai[bot]`). That push is
itself an eligible event for an automatic incremental review. So an autofix, whatever it costs from
its own pool, plausibly also costs **one PR review** for the review its own commit triggers.
**[UNKNOWN]** whether CodeRabbit suppresses the incremental review for its own autofix commit — not
stated anywhere in the corpus, and not observable on this repo, where the autofix commit landed on
PR #1 and the subsequent review history is confounded by a merge.

## 5.3. Fair usage punishes exactly this access pattern

The §3 table is keyed to a **7-day rolling window** of review attempts, per developer identity. A
loop firing every 5 minutes across several repos is a single developer identity generating
sustained volume. At 90+ attempts in 7 days a Pro+ account is throttled to **1 review/hour, one at
a time** — a 10x reduction that persists until the earlier attempts age out. **[DOC]** "Reducing or
pausing review activity lets recent usage come down over time." There is no way to reset it faster.

90 attempts is not a high bar for an unattended loop: it is ~13/day, or one every ~110 minutes
sustained. A 5-minute poll that triggers work on even a small fraction of ticks will reach it.

## 5.4. Autofix preconditions that produce a no-op rather than an error

Worth handling distinctly from rate limiting, since all of these consume a trigger and return a
comment that is *not* a success:

**[DOC]** <https://docs.coderabbit.ai/finishing-touches/autofix>, "Scope and limitations" — autofix
runs only on PR events; only processes unresolved CodeRabbit review threads with valid fix
instructions; exits without changes when the PR has merge conflicts; skips when no valid unresolved
instructions are found. **[DOC]** "Even if verification fails, the generated changes are still
delivered" — so a failed build does not mean no commit was pushed.

**[OBS]** These map onto the observed shapes in §2b: `Autofix skipped. No unresolved CodeRabbit
review comments with fix instructions found.` is the single **most common** outcome in the wild
(38 of 112). A loop that fires autofix on every open PR every 5 minutes will mostly generate these.
**[UNKNOWN]** whether a no-op autofix consumes budget from whatever pool governs it.

**[OBS]** `❌ Failed to start the Coding Agent task. Please try again.` is the second most common
failure (17 of 112) and is transient-by-wording, which makes it dangerously easy for a retry loop to
hammer. It carries a `autofix-run-id`, so it is distinguishable.

## 5.5. Over-limit continuation exists but must be bought and enabled

**[DOC]** Pro/Pro+/Enterprise orgs can enable the **usage-based add-on** to continue eligible
over-limit reviews (<https://docs.coderabbit.ai/management/usage-based-addon>), billed per file
(the third-party example in §2a shows `$0.25/file`). **[DOC]** There is also an org **spending cap**;
the observed comment shows the cap being hit as a separate condition layered on the fair-usage
message ("Your organization has reached its usage spending cap"). **[UNKNOWN]** whether the
usage-based add-on covers autofix at all — every reference is to *reviews*.

## 5.6. Cheap probe available

**[DOC]** `@coderabbitai rate limit` "does not consume a review". It is therefore safe for a poller
to call as a pre-flight check before spending a review — but per §4 it reports review allowance
only, so it cannot pre-flight an autofix.

---

# Summary table

| Question | Answer | Confidence |
| --- | --- | --- |
| Autofix draws the included-review pool? | Not listed among the 3 documented consumers; own limit unnamed/unnumbered | **[UNKNOWN]** |
| Separate autofix pool named/numbered? | No — "Autofix may be rate-limited" is the entire corpus | **[DOC]** negative |
| Observed behaviour when autofix limit hit | Docs promise "a wait time"; 0 of 112 real autofix comments show it | **[UNKNOWN]** |
| Observed behaviour when *review* limit hit | Rate-limit block in the summarize comment + passing "Review rate limited" check | **[DOC]** + **[OBS]** |
| Review limits documented per plan? | Yes — full table + 7-day fair-usage degradation tiers | **[DOC]** |
| Machine-readable autofix budget? | None anywhere | **[UNKNOWN]** / **[DOC]** negative |
| Biggest operational trap | Rate-limit notice arrives as an **edit**; `created_at` up to 7 days stale | **[OBS]** |

## Recommended posture for the loop, given the unknowns

Because questions 1 and 2 resolve to **[UNKNOWN]**, the loop cannot predict autofix exhaustion and
cannot recognise it from a known comment shape. It should therefore **fail closed on unrecognised
autofix-status shapes** rather than treating them as success, using the taxonomy in §2b as an
allow-list of the nine known shapes and treating anything else — including any future rate-limit
variant — as "unknown, do not retry immediately".

Concretely: match on `<!-- autofix-run-id: ... -->` presence plus a known first line; on a miss, back
off rather than re-firing. Poll `updated_at`, not `created_at` (§5.1). Rate-limit the loop's own
autofix triggers well below the fair-usage 7-day thresholds (§5.3), since the budget that governs
them is invisible (§4).
