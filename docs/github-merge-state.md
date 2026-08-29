# GitHub's `mergeable` and `mergeStateStatus`: what each value means, and which are decided

Research note for [#45](https://github.com/nywleswoey/agentloop/issues/45), part of the wayfinder
map [#44](https://github.com/nywleswoey/agentloop/issues/44). Written 2026-08-29.

The question this answers: for every value GitHub can return on a pull request's `mergeable` and
`mergeStateStatus`, what causes it, is it derived from check state, can it move with no push, and is
it `ok` / `not yet decided` / `decided and bad`.

**The short version.** `mergeStateStatus` is not a stable property of a pull request. Every one of
its eight values can change without a single byte being pushed. `BLOCKED` in particular is
**confirmed check-derived** — both from GitHub's own troubleshooting docs and from a live specimen
where it flipped to `CLEAN` at an unchanged head, 29 seconds after a required check reported. The
two fields also measure different things: `mergeable` is scoped by GitHub's own field
documentation to *merge conflicts only*, and is not check-derived at all.

---

## How to read the source column

Every claim below carries a tag. Claims tagged `[!]` are **not documented by GitHub** and are marked
as inference; do not treat them as established.

| Tag | Source |
|---|---|
| `[S]` | GitHub's published GraphQL schema — <https://docs.github.com/public/fpt/schema.docs.graphql> (same text renders at [GraphQL reference / Enums](https://docs.github.com/en/graphql/reference/enums)). Retrieved 2026-08-29. |
| `[R]` | [REST API endpoints for pull requests](https://docs.github.com/en/rest/pulls/pulls) |
| `[O]` | GitHub's OpenAPI description, `descriptions/api.github.com/api.github.com.json` in [github/rest-api-description](https://github.com/github/rest-api-description) |
| `[P]` | [About protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches) |
| `[K]` | [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) |
| `[A]` | [About rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets) |
| `[C]` | [About status checks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/about-status-checks) and [Status checks reference](https://docs.github.com/en/pull-requests/reference/status-checks) |
| `[T]` | [Troubleshooting required status checks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks) |
| `[M]` | [Merging a pull request](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-a-pull-request) |
| `[H]` | [About pre-receive hooks](https://docs.github.com/en/enterprise-server@3.17/admin/enforcing-policies/enforcing-policy-with-pre-receive-hooks/about-pre-receive-hooks) (GitHub Enterprise Server docs) |
| `[E]` | Empirical, read-only observation of `nywleswoey/kids-collection` PR #112 and ruleset 20601020 on 2026-08-29. See [Specimen](#the-specimen). |
| `[!]` | **Undocumented and inferred.** GitHub does not state this; it is reasoning from the texts above. |

---

## The two fields are not two views of one thing

GitHub's schema documents them separately, and the difference is load-bearing.

> `mergeable: MergeableState!` — *"Whether or not the pull request can be merged based on the
> existence of merge conflicts."* `[S]`

> `mergeStateStatus: MergeStateStatus!` — *"Detailed information about the current pull request
> merge state status."* `[S]`

`mergeable` is scoped, in GitHub's own words, to **merge conflicts**. `mergeStateStatus` is the
everything-else field. The specimen bears this out: at the same head, `mergeable` read `MERGEABLE`
while `mergeStateStatus` went `BLOCKED` → `CLEAN`. `mergeable` did not move when the check
landed. `[E]`

This matters for `one signal, one veto`: reading `mergeable` and `mergeStateStatus` as a single
"mergeability" signal merges a conflict fact with a check fact.

---

## Table 1 — `mergeable` (GraphQL `MergeableState`)

Schema text quoted verbatim. `[S]`

| Value | GitHub's text | What causes it | Check-derived? | Can change with no push? | Verdict class |
|---|---|---|---|---|---|
| `MERGEABLE` | *"The pull request can be merged."* | GitHub's background job created a test merge commit successfully — no conflicts against the current base tip. `[R]` `[S]` | **No.** Field is scoped to merge conflicts `[S]`; observed unchanged across a required check going pending → success at a fixed head `[E]` | **Yes.** Base branch advancing with a conflicting change flips it to `CONFLICTING` `[!]`. Also arrives from `UNKNOWN` when GitHub's background job finishes `[R]` | **`ok`, about conflicts only.** Says nothing about checks, reviews or rules. |
| `CONFLICTING` | *"The pull request cannot be merged due to merge conflicts."* | The test merge commit cannot be created `[S]` `[R]` | **No** `[S]` | **Yes.** It is a function of the base *tip*: base moving away from the conflicting change, or a revert on base, clears it with no push `[!]` | **`decided and bad` — but only at this base tip**, and only about conflicts. |
| `UNKNOWN` | *"The mergeability of the pull request is still being calculated."* | GitHub has not finished the background job. REST states it plainly: *"If the value is null, then GitHub has started a background job to compute the mergeability. After giving the job time to complete, resubmit the request."* `[R]` | **No** | **Yes — by definition.** Resolves purely by GitHub finishing a background computation `[R]` | **`not yet decided`.** The one value in either field that GitHub explicitly documents as "come back later". |

### Note on how the computation is triggered

> *"When you get, create, or edit a pull request, GitHub creates a merge commit to test whether the
> pull request can be automatically merged into the base branch."* `[R]`

So the act of reading the single-PR endpoint is itself what schedules the recompute. A poller that
reads and re-reads is doing the right thing; a poller that caches will never see the answer change.

---

## Table 2 — `mergeStateStatus` (GraphQL `MergeStateStatus`)

Schema text quoted verbatim `[S]`. **GitHub's documentation of this enum is one sentence per value
and nothing else.** There is no page anywhere on docs.github.com that explains which repository
condition produces which value. Every "what causes it" cell below that goes past the one-sentence
gloss is marked.

| Value | GitHub's text | What causes it | Derived from check state? | Can change with no push? | Verdict class |
|---|---|---|---|---|---|
| `BEHIND` | *"The head ref is out of date."* | The base branch has advanced past the merge base **while a strict "branches must be up to date" requirement is in force**. Documented requirement: *"The topic branch must be up to date with the base branch before merging"* `[K]`; strict vs loose: *"Strict: The branch must be up to date with the base branch before merging" / "Loose: The branch does not have to be up to date"* `[P]`. **`[!]` The link from that requirement to this enum value is inferred** — GitHub never says `BEHIND` is produced only under the strict policy. | **No, but it is coupled to a checks rule** — "up to date" is a parameter of the required-status-checks rule (`strict_required_status_checks_policy`) `[K]` `[E]` | **Yes, two ways with no push: (a) the base branch advancing** `[!]`, **(b) an operator flipping the strict flag on the ruleset** — *"your ruleset will be enforced upon creation"* `[A]`. Leaving `BEHIND` normally does need a push (Update branch writes a commit) `[!]` | **`decided and bad` at a fixed base tip; `not yet decided` at a fixed base *ref*.** This is the value that kills `(head, base-ref)` as a cache key. |
| `BLOCKED` | *"The merge is blocked."* | **A union of causes that GitHub does not enumerate.** Confirmed member: **a required status check that has not reported yet** — *"Associated checks stay in a 'Pending' state and block merging"* and the PR shows *"Waiting for status to be reported"* `[T]`; *"If status checks are required for a protected branch, they must pass before the pull request can be merged"* `[C]`; confirmed live `[E]`. Other rules that block a merge and **plausibly but not documentedly** surface here `[!]`: required reviews `[P]`, required conversation resolution `[P]`, required deployments `[K]`, required code scanning results `[K]`, required signed commits `[K]` `[P]`, required linear history `[K]` `[P]`, restrict updates `[K]`. | **YES — confirmed.** `[T]` `[E]` A required check going pending → success moved `BLOCKED` → `CLEAN` at an unchanged head. | **Yes, at least five ways with no push:** a check landing `[E]`; a check re-run by hand `[!]`; a review being submitted `[P]` `[!]`; a conversation being resolved `[P]` `[!]`; a ruleset or protection change, which is *"enforced upon creation"* `[A]` | **AMBIGUOUS — must not be read as `decided and bad`.** `BLOCKED` collapses "a required check has not reported yet" (`not yet decided`) and "a required review is missing" (`decided and bad`, but still no-push-clearable) into one token. Nothing in the value distinguishes them. **This is the #112 defect.** |
| `CLEAN` | *"Mergeable and passing commit status."* | No conflicts, and the commit status is passing `[S]`; all rules on the base satisfied `[!]` | **YES — definitionally.** "passing commit status" is check state `[S]` | **Yes.** A re-run going red, a new check reporting on the head, the base advancing, or a ruleset gaining a required check `[A]` `[!]` | **`ok` — as of this read.** Not a durable fact. |
| `DIRTY` | *"The merge commit cannot be cleanly created."* | Merge conflicts. Pairs with `mergeable = CONFLICTING` `[S]` `[!]` | **No** `[S]` | **Yes** — base tip moving in either direction `[!]` | **`decided and bad` at this base tip.** |
| `DRAFT` | *"The merge is blocked due to the pull request being a draft."* — carries `@deprecated(reason: "DRAFT state will be removed from this enum and \`isDraft\` should be used instead ... Removal on 2021-01-01 UTC.")` `[S]` | The pull request is a draft. *"You can't merge a draft pull request."* `[M]` | **No** `[S]` | **Yes.** Ready-for-review and convert-to-draft are both no-push gestures `[!]` | **`decided and bad` while it holds** — but see the caveat below: **whether GitHub still emits this value at all is not established.** |
| `HAS_HOOKS` | *"Mergeable with passing commit status and pre-receive hooks."* | The repository has pre-receive hooks configured. Pre-receive hooks are *"scripts that run on the GitHub Enterprise Server appliance"* — **a GitHub Enterprise Server feature** `[H]`. `[!]` That this value therefore cannot occur on github.com is inferred, not stated. | **YES, partly** — "passing commit status" is check state `[S]` | **Yes** — checks landing move a PR into or out of it `[!]`; an admin adding or removing a hook does too `[!]` | **`ok`-ish.** It asserts mergeable-and-passing, but the hook still runs at merge time and **GitHub does not document whether the hook can reject the merge**. Treat as `ok` with a caveat, not as `CLEAN`. |
| `UNKNOWN` | *"The state cannot currently be determined."* | **GitHub gives no cause at all.** `[!]` Almost certainly the same background computation as `mergeable = UNKNOWN` / REST `mergeable: null` `[R]`, but GitHub never connects the two. | **No** `[!]` | **Yes** — GitHub finishing a background computation `[!]` | **`not yet decided`** `[!]` — inferred from the wording *"cannot **currently** be determined"*, not stated. |
| `UNSTABLE` | *"Mergeable with non-passing commit status."* | A status or check on the head is not passing, but it is **not required**, so nothing blocks the merge. `[!]` The required/not-required distinction is inferred from contrasting this text ("Mergeable with...") against `BLOCKED` ("The merge is blocked") plus the required-checks rule `[C]` `[K]`. GitHub never says it. | **YES — definitionally** `[S]` | **Yes** — any check reporting or being re-run `[!]` | **`ok` for merging, but ambiguous about *why* it is unstable.** "Non-passing" covers both *pending* and *failed*; this value cannot tell them apart. The check list can. **A checks signal — belongs to V2, not V3.** |

### Three things about this table that are gaps, not findings

1. **Precedence is undocumented.** When two conditions hold at once — say, a pending required check
   *and* the branch being behind — GitHub does not say which value wins. Do not build ordering logic
   on an assumed precedence.
2. **`BLOCKED`'s cause set is undocumented.** Only the required-check-pending member is established
   (docs + specimen). The rest of the list is inference from "these rules block a merge", not from
   any statement that they produce `BLOCKED`.
3. **`DRAFT` may be dead.** The schema still declares it, still marked deprecated with a removal
   date of 2021-01-01 that has long passed `[S]`. GitHub neither removed it nor documented whether
   it is still returned. No draft PR was available to test. **Unresolved.** Read `isDraft`, which is
   what the deprecation notice tells you to do `[S]`.

---

## Table 3 — REST ↔ GraphQL correspondence

**Headline: GitHub does not document REST's `mergeable_state` at all.** In GitHub's own OpenAPI
description, the `pull-request` schema declares:

```json
"mergeable_state": { "type": "string", "example": "clean" }
```

No `enum`, no `description`. `[O]` Verified 2026-08-29 against
`descriptions/api.github.com/api.github.com.json`; `mergeable_state` occurs 22 times in that file
and is never given a value set. No page on docs.github.com enumerates its values either. The only
enumerated, described source for these values anywhere in GitHub's own material is the **GraphQL
schema**.

| REST field | Type / documentation | GraphQL counterpart | Correspondence | Basis |
|---|---|---|---|---|
| `mergeable` | `boolean, nullable` — no description in OpenAPI `[O]`; prose in `[R]` | `mergeable: MergeableState!` | `true` ↔ `MERGEABLE`, `false` ↔ `CONFLICTING`, `null` ↔ `UNKNOWN` | `null` ↔ `UNKNOWN` is **documented**: REST calls `null` "background job … still computing" `[R]`, GraphQL calls `UNKNOWN` "still being calculated" `[S]`. `true` ↔ `MERGEABLE` **observed** `[E]`. `false` ↔ `CONFLICTING` **inferred** from identical field semantics `[!]` |
| `mergeable_state` | `string`, example `"clean"`, no enum, no description `[O]` | `mergeStateStatus: MergeStateStatus!` | Lowercased enum name: `behind`, `blocked`, `clean`, `dirty`, `draft`, `has_hooks`, `unknown`, `unstable` | `clean` ↔ `CLEAN` **observed at the same head sha in the same minute** `[E]`. The rest, including the `has_hooks` underscore form, is **`[!]` inferred from the naming pattern** — GitHub publishes no mapping. |
| `rebaseable` | `boolean, nullable` `[O]` | `canBeRebased: Boolean!` — *"Whether or not the pull request is rebaseable."* `[S]` | Direct | `[S]` `[O]` |

### Two REST facts a poller needs

- **The list endpoint does not return these fields at all.** `GET /repos/{owner}/{repo}/pulls`
  returns objects with no `mergeable`, `mergeable_state` or `rebaseable` key; `GET
  /repos/{owner}/{repo}/pulls/{number}` returns all three. Verified `[E]`. This follows from *"When
  you **get** … a pull request, GitHub creates a merge commit to test…"* `[R]` — the computation is
  per-PR.
- **`mergeStateStatus` needed no preview Accept header.** The GraphQL query below succeeded with a
  plain token on 2026-08-29 `[E]`. (This field historically sat behind
  `application/vnd.github.merge-info-preview+json`; GitHub does not document the graduation. `[!]`)

---

## The specimen

`nywleswoey/kids-collection` PR #112, head `043b1d81f41d93539287a572d3a7dca13bf0ec83`, base `main`.
Read-only observation, 2026-08-29. This is the case that opened #45.

**Repository ruleset 20601020, "main protection"** — `enforcement: active`, targets
`~DEFAULT_BRANCH`:

```
rules:
  - deletion
  - non_fast_forward
  - required_linear_history
  - pull_request           (required_approving_review_count: 0)
  - required_status_checks (strict_required_status_checks_policy: false)
      required: fast-gate, pg-gate
```

Both `fast-gate` and `pg-gate` are **required**. `strict` is **false**, so this repo cannot produce
`BEHIND` under the inferred rule — and indeed PR #112 is `ahead_by: 1, behind_by: 0`, so the case
was not exercisable here.

**Timeline at one unchanging head sha:**

| Time (UTC) | Event | Observed |
|---|---|---|
| 00:35:12 | `fast-gate` started | — |
| 00:35:13 | `pg-gate` started | — |
| 00:36:27 | `fast-gate` completed `success` | — |
| **00:38:28** | agent-loop wrote its escalation comment | **`mergeable=MERGEABLE state=BLOCKED`**, `pending=1 waiting=pg-gate` |
| **00:38:57** | **`pg-gate` completed `success`** | — |
| 2026-08-29 (now) | re-read, same head sha | **`mergeable=MERGEABLE mergeStateStatus=CLEAN`**, REST `mergeable_state: clean` |

Head sha identical across the whole table. The only thing that changed is that a required check
finished, 29 seconds after the loop declared a permanent veto.

**This is direct confirmation that `BLOCKED` is check-derived and that it clears with no push.** It
also confirms the negative: `mergeable` held at `MERGEABLE` throughout, so `mergeable` is *not*
check-derived.

Queries used (both read-only):

```sh
gh-axi api /repos/nywleswoey/kids-collection/pulls/112 \
  --jq '{head: .head.sha, mergeable, mergeable_state}'

gh-axi api POST /graphql --field query='query {
  repository(owner:"nywleswoey", name:"kids-collection") {
    pullRequest(number:112) { headRefOid mergeable mergeStateStatus isDraft }
  }
}'
```

---

## Is `(head, base)` a sufficient cache key?

**No — and not for any value in either field.**

| Key | What is stable under it | What still moves |
|---|---|---|
| `(head)` | nothing | everything below |
| `(head, base-ref-name)` | nothing | `BEHIND` and `DIRTY`/`CONFLICTING` move when the base *tip* advances, with the ref name unchanged `[!]` |
| `(head, base-tip-sha)` | `mergeable` / `DIRTY`, **once it has left `UNKNOWN`** — the conflict computation is a pure function of two commits `[!]` | `BLOCKED`, `CLEAN`, `UNSTABLE` (check state on the head, and check state moves on its own `[E]`); `BLOCKED`/`BEHIND` again (ruleset changes are *"enforced upon creation"* `[A]`); `DRAFT` (a no-push gesture); `UNKNOWN` (background job) |

The narrowest honest statement: **the only fact in either field that is stable at a fixed
`(head, base-tip)` is the conflict verdict**, and even that is `UNKNOWN` until GitHub finishes
computing it. Everything derived from checks, rules, reviews, or draft state is a snapshot with no
guarantee past the instant of the read.

---

## What this means for the gate

Stated as findings, not as a design. The design belongs to the other tickets under #44.

1. **`BLOCKED` is not a `no`.** It is confirmed check-derived `[T]` `[E]`, and even its
   non-check members (review, conversation resolution, ruleset) all clear with no push. There is no
   reading of `BLOCKED` that supports "the loop takes no further action until the head moves".
2. **`UNSTABLE` is a checks signal.** Under `one signal, one veto` it belongs to whichever veto owns
   checks. And it cannot distinguish pending from failed — the check list can, so the check list is
   the better authority.
3. **`UNKNOWN` on either field is explicitly "ask again later"** — GitHub says so in prose for
   `mergeable` `[R]`. That is a `defer`, never an `escalate`.
4. **The base-relative facts V3 could legitimately own are `BEHIND` and `DIRTY`/`CONFLICTING`** —
   the two that V2's view of the head cannot see. Both are still transient at a fixed base ref, so
   even they cannot latch a record to the head alone.
5. **`DRAFT`: read `isDraft` instead**, per GitHub's own deprecation notice `[S]`.

---

## Rows that could not be established from primary sources

Listed plainly so they are not mistaken for findings.

1. **The full cause set of `BLOCKED`.** Only "a required status check has not reported" is
   established. Every other listed cause is inference from "this rule blocks a merge".
2. **Precedence between `mergeStateStatus` values** when several conditions hold at once. Entirely
   undocumented.
3. **That `BEHIND` requires the strict / up-to-date policy.** The strict policy is documented `[P]`
   `[K]`; that it is what produces `BEHIND` is not. Not testable on the specimen (`strict: false`,
   and the PR is not behind).
4. **The cause of `mergeStateStatus = UNKNOWN`.** GitHub says only "cannot currently be determined".
   The link to the `mergeable` background job is inference.
5. **Whether `DRAFT` is still emitted.** Deprecated with a 2021-01-01 removal date that has passed;
   still in the schema; no draft PR available to test.
6. **`HAS_HOOKS` behaviour**, including whether it can occur on github.com and what happens if the
   pre-receive hook rejects the merge. Pre-receive hooks are documented as a GitHub Enterprise
   Server feature `[H]`; the enum value's interaction with merging is not documented anywhere.
7. **The REST `mergeable_state` value set and its exact spellings.** GitHub publishes no enum and no
   description `[O]`. Only `clean` ↔ `CLEAN` is observed. The `has_hooks` spelling is a guess from
   the naming pattern.
8. **`UNSTABLE` = "non-required check not passing".** The distinction from `BLOCKED` is inferred
   from two enum sentences, not stated.
9. **Whether `mergeStateStatus` still requires a preview Accept header.** It did not on 2026-08-29;
   GitHub does not document the graduation.
