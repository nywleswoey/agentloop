# What merge and check-run surface `gh-axi` reaches, and at what fidelity

Research for [#5](https://github.com/nywleswoey/agentloop/issues/5), under the map in
[#3](https://github.com/nywleswoey/agentloop/issues/3).

Question: the loop reads GitHub through exactly one seam — `gh_json`
(`agent-loop.sh:99`, `gh-axi api … --full --jq 'tojson|@base64'`) and `gh_graphql`
(`agent-loop.sh:136`) — and writes through exactly one, `pr-writeback.sh`. For every
capability the new merge phase needs: is it **reachable today** through that seam,
**reachable with a new seam**, or **not reachable**?

Sources are GitHub's own REST/GraphQL reference and public GraphQL schema, `gh-axi`'s
own help output, and read-only empirical probes against `nywleswoey/agentloop` on
2026-08-22 with `gh-axi` over `gh` 2.85.0. Probes are marked **[probed]**; anything
inferred from docs but not exercised on this machine is marked **[docs only]**.

Nothing was merged, no branch was pushed to `main`, and no PR or issue was modified.
Two idempotent `PUT …/pulls/2/merge` calls were made against an **already-merged** PR
purely to observe the response shape; `main` was verified unchanged
(`e74f467bdb19feceda909466b590be56a81fcce5`) before and after.

---

## 0. Ground truth about the seam itself

Two facts had to be established before anything else, because they change what
"reachable" even means.

### 0.1 `gh-axi api` collapses HTTP status into a message string, and its `code:` field is not a taxonomy **[probed]**

`gh_json` currently decides failure by `[[ "$response" == error:* ]] && return 1`. That
is correct as far as it goes, but it throws away *why*. What `gh-axi` actually emits:

| Situation | stdout | exit |
|---|---|---|
| `GET` a nonexistent PR (HTTP 404) | `error: "gh: Not Found (HTTP 404)"` / `code: NOT_FOUND` | 1 |
| `GET .../branches/main/protection`, unprotected (HTTP 404) | `error: "gh: Branch not protected (HTTP 404)"` / `code: UNKNOWN` | 1 |
| `GET .../actions/secrets` on a repo without admin (HTTP 403) | `error: Insufficient permissions for this action` / `code: FORBIDDEN` | 1 |
| `POST /issues` with no title (HTTP 422) | `error: Validation error` / `code: VALIDATION_ERROR` | 2 |
| `gh-axi pr merge` with no PR number (client-side, no request sent) | `error: Missing PR number` / `code: VALIDATION_ERROR` | 2 |
| non-JSON response body (`POST /markdown`) | `error: invalid character '<' looking for beginning of value` / `code: UNKNOWN` | 1 |
| DNS failure (`--hostname nonexistent.invalid`) | `error: error connecting to nonexistent.invalid` / `code: UNKNOWN` | 1 |

Three consequences that matter for an unattended merge bot:

1. **`code:` cannot separate refusal from transport.** "Branch not protected (HTTP
   404)" — a definitive, permanent *GitHub said no* — and "error connecting to host"
   — a retry-me-later transport blip — are both `code: UNKNOWN`, both exit 1. Any
   retry posture keyed on `code:` will retry permanent refusals forever and treat
   real outages as verdicts.
2. **The HTTP status is only recoverable by regex on the message string**, and only
   when `gh-axi` chose to pass GitHub's message through (the 404 and 403 cases keep
   `(HTTP nnn)` in the 404 case but *not* the 403 case, where `gh-axi` substitutes
   its own prose).
3. **HTTP 422 loses GitHub's response body entirely**, and is rendered identically to
   `gh-axi`'s own client-side argument validation. The `errors[]` array that names the
   offending field never reaches the caller.

For the merge endpoint specifically, GitHub documents 405 ("Method Not Allowed if
merge cannot be performed"), 409 ("Conflict if sha was provided and pull request head
did not match"), 403, 404 and 422
([REST · merge a pull request](https://docs.github.com/en/rest/pulls/pulls?apiVersion=2022-11-28#merge-a-pull-request)).
**[docs only]** — I could not provoke a 405 without creating a throwaway PR, which the
brief forbids. So how `gh-axi` renders a 405 is *unverified*. Given the table above,
the safe assumption is that it renders as `error: "gh: … (HTTP 405)"` with an
unhelpful `code:`, and the loop must parse the string.

> **Recommendation.** The refusal/transport distinction is a `gh_json` responsibility,
> not a call-site one. `gh_json` should grow a way to hand the caller the HTTP status
> (e.g. return it on fd 3, or set a global `GH_LAST_HTTP`), parsed out of `(HTTP nnn)`
> and defaulting to "unknown/transport" when absent. This is a **seam change**, and
> everything in §1 depends on it.

### 0.2 `pr-writeback.sh`'s GraphQL variables do not work — the write seam is already broken **[probed]**

`pr-writeback.sh:240` calls:

```sh
gh-axi api POST /graphql --field query="$query" --field thread="$thread" --field body="$body"
```

expecting `gh`'s behaviour where non-`query` fields become GraphQL variables. **That
behaviour is keyed on the literal path `graphql`, not `/graphql`.** Probed side by
side:

```
$ gh api graphql -f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){nameWithOwner}}' \
      -f owner=nywleswoey -f name=agentloop
{"data":{"repository":{"nameWithOwner":"nywleswoey/agentloop"}}}

$ gh api -X POST /graphql -f query='…same…' -f owner=nywleswoey -f name=agentloop
{"errors":[{… "message":"Variable $owner of type String! was provided invalid value"} …]}
```

The same split reproduces through `gh-axi`: `gh-axi api POST /graphql --field owner=…`
sends the variable as null; `gh-axi api POST graphql --field owner=…` (no leading
slash) works.

So `post_comment` and `resolve_thread` in `pr-writeback.sh` send `$thread: ID!` as
null on every real invocation. `gh_graphql`'s `jq -e 'has("errors")|not'` correctly
turns that into a failure — the script does not lie about having written — but the
writes have never succeeded against real GitHub. The stub-CLI suite cannot catch this,
because the stub never round-trips a GraphQL document.

Two working fixes, both **probed**:

- drop the leading slash: `gh-axi api POST graphql --field query=… --field thread=…`
- or keep `/graphql` and pass a single JSON-encoded `variables` field:
  `--field variables='{"thread":"…","body":"…"}'` — GitHub accepts `variables` as a
  JSON string.

`agent-loop.sh`'s own `gh_graphql` is *not* affected: it takes only a query document
with values already interpolated, and never uses variables.

> This is a pre-existing bug that the merge work will trip over the moment it wants to
> write anything through GraphQL. It should be fixed before, or as part of, the merge
> phase.

---

## 1. Merging

### 1.1 `gh-axi pr merge` — the porcelain

**Verdict: reachable today for the act, not reachable for the verdict.**

Real help output (`gh-axi pr --help`), not guessed:

```
subcommands: list, view, create, edit, close, merge <number>, review, checks,
             diff, checkout, ready, reopen, comment, update-branch, revert
flags{merge}:
  --method <merge|squash|rebase>, --merge, --squash, --rebase, --auto,
  --delete-branch, --body <text> or --body-file <path>, --subject
```

So: all three merge methods, branch deletion, commit subject (`--subject`) and body
(`--body`/`--body-file`), and GitHub auto-merge (`--auto`). That covers everything the
ticket asked about — **except**:

- **No `--jq`.** `--jq` is a flag on `gh-axi api` only. Every `pr` subcommand prints
  TOON prose. The `tojson|@base64` trick that makes `gh_json` work is therefore
  *unavailable* to `gh-axi pr merge`. Its output would have to be scraped.
- **No head-SHA guard.** There is no `--sha`/`--expected-head-oid` flag, so
  `gh-axi pr merge` cannot do optimistic concurrency. An unattended bot that decided
  "this PR is safe" against SHA *X* and then merges cannot assert it is still merging
  *X*. This is the single most important gap in the porcelain.

Probed on the already-merged PR #2 (`gh-axi pr merge 2 --squash`): exit 0, output

```
pull_request:
  number: 2
  state: merged
  merged_by: nywleswoey
  merged_at: "2026-08-22T13:16:25Z"
```

i.e. it reports state rather than erroring on an already-merged PR. Fine as an
observation; useless as a machine-readable success/refusal signal.

### 1.2 REST `PUT /pulls/{n}/merge` through `gh_json` — the plumbing

**Verdict: reachable today.** Probed end to end:

```sh
gh_json PUT "/repos/$owner/$repo/pulls/$n/merge" \
  --field merge_method=squash \
  --field sha="$head_sha" \
  --field commit_title="$title" \
  --field commit_message="$body"
```

Against PR #2 this returned, through the existing seam, decoded byte for byte:

```json
{"merged":true,"message":"Pull Request successfully merged","sha":"e74f467bdb19feceda909466b590be56a81fcce5"}
```

`gh-axi api` accepts `PUT` (methods: GET, POST, PUT, PATCH, DELETE, HEAD) and repeated
`--field key=value`, including multi-line values. Request-body fields are exactly
`commit_title`, `commit_message`, `sha`, `merge_method`
([REST · merge a pull request](https://docs.github.com/en/rest/pulls/pulls?apiVersion=2022-11-28#merge-a-pull-request)).

This is strictly better than the porcelain for a bot: it supports `sha` (the
optimistic-concurrency guard the porcelain lacks) and its response arrives as JSON
through the seam the loop already has.

Two things it does *not* do, both trivially reachable with the same seam:
- **Delete the branch**: `gh_json DELETE "/repos/$o/$r/git/refs/heads/$branch"`
  ([REST · git refs](https://docs.github.com/en/rest/git/refs)). **[docs only]**
- **Enable auto-merge**: REST has no auto-merge endpoint; it is the GraphQL mutation
  `enablePullRequestAutoMerge` (§1.4).

### 1.3 Idempotency of the merge call **[probed]**

Merging an already-merged PR returns **HTTP 200** with
`{"merged":true,"message":"Pull Request successfully merged"}` and the *original*
merge commit SHA — it does not return 405, and it does not create a second merge.
Passing a deliberately wrong `sha=0000…` to an already-merged PR also returns 200
(the guard is not evaluated once the PR is closed). So a duplicated merge attempt
after a lost response is safe and self-reporting, which removes one class of retry
hazard.

### 1.4 GraphQL `mergePullRequest` / `enablePullRequestAutoMerge`

**Verdict: reachable with a small seam change** (the `/graphql` → `graphql` fix in
§0.2, or the `variables` JSON-string form).

`MergePullRequestInput`: `pullRequestId: ID!`, `mergeMethod: PullRequestMergeMethod`,
`commitHeadline`, `commitBody`, `expectedHeadOid: GitObjectID` ("OID that the pull
request head ref must match to allow merge; if omitted, no check is performed"),
`authorEmail`, `clientMutationId`.
`enablePullRequestAutoMerge` takes the same input shape;
`disablePullRequestAutoMerge` takes only `pullRequestId`.
([GraphQL · pulls](https://docs.github.com/en/graphql/reference/pulls))

GraphQL's `expectedHeadOid` is the same guard as REST's `sha`. Either is fine; REST is
less work given the seam that already exists.

Auto-merge prerequisites: the repository must have "Allow auto-merge" on
(`allow_auto_merge`), and auto-merge is only *meaningful* when the PR cannot merge
immediately — it exists to wait out branch-protection gates
([managing auto-merge](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-auto-merge-for-pull-requests-in-your-repository)).
**[probed]** `nywleswoey/agentloop` has `allow_auto_merge: true`, all three merge
methods enabled, and `delete_branch_on_merge: true` — but **no branch protection and
no rulesets**, so nothing would ever gate a merge, and auto-merge has nothing to wait
for. On this repo, auto-merge is a null option.

### 1.5 Refusal vs. transport, for merging specifically

**Verdict: reachable with a new seam** — see §0.1. Today `gh_json` returns 1 for both
and the caller cannot tell them apart. With the HTTP-status escape hatch:

| status | meaning | loop posture |
|---|---|---|
| 200 | merged (or already merged — §1.3) | done |
| 405 | "merge cannot be performed" — not mergeable, draft, blocked | **refusal**; do not retry blind, re-evaluate risk |
| 409 | `sha` mismatch — head moved under us | **refusal**; re-evaluate against the new head |
| 403 | permission | **refusal**; escalate, never retry |
| 404 | gone / no access | **refusal**; escalate |
| 422 | validation / spam-flagged | **refusal**; escalate (body is lost — §0.1) |
| no status parsed | transport | **retry** with backoff |

**[docs only]** for 405/409/403/422 rendering under `gh-axi`. GitHub's docs give no
example body for any of the non-200 responses, so **the merge refusal does not tell
you which required check failed** — only that the merge could not be performed. The
"why" must come from §2 and §3, read separately, before the attempt.

---

## 2. Mergeability

### 2.1 REST **[probed]**

**Verdict: reachable today.**

```sh
gh_json "/repos/$o/$r/pulls/$n"   # → .mergeable, .mergeable_state, .merge_commit_sha
```

GitHub's documented lazy-computation note, verbatim
([REST · get a pull request](https://docs.github.com/en/rest/pulls/pulls?apiVersion=2022-11-28#get-a-pull-request)):

> "The value of the `mergeable` attribute can be `true`, `false`, or `null`. If the
> value is `null`, then GitHub has started a background job to compute the
> mergeability. After giving the job time to complete, resubmit the request. When the
> job finishes, you will see a non-null value for the `mergeable` attribute in the
> response."

**GitHub documents no wait duration, no backoff, and no maximum retry count.** That is
the whole documented retry story. Anything more specific is folklore.

Two further REST facts:

- **`mergeable`/`mergeable_state` are absent from `GET /repos/{o}/{r}/pulls`** (the
  list endpoint's schema does not carry them). A loop that lists open PRs *must* do
  one extra single-PR GET per PR to learn mergeability. **[verified against the list
  endpoint schema]**
- **`mergeable_state`'s value set is undocumented.** The field appears in the response
  schema as a bare `string` with no prose and no enumeration anywhere in the REST
  reference. GitHub's own community answer to a user confused by an undocumented
  `blocked` value points them at the GraphQL `MergeStateStatus` enum instead
  ([community discussion 24504](https://github.com/orgs/community/discussions/24504)).
  Treat any REST `mergeable_state` value list as community knowledge, not as contract.

Probed on merged PR #2: `mergeable: null`, `mergeable_state: "unknown"` — i.e. a
closed PR looks exactly like a PR whose background job has not finished. The loop must
check `state`/`merged` *before* interpreting mergeability.

### 2.2 GraphQL **[probed]**

**Verdict: reachable today** (query-document form, no variables needed).

```sh
gh_graphql 'query{repository(owner:"…",name:"…"){pullRequest(number:N){
  mergeable mergeStateStatus }}}'
```

returned `{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}` for PR #2, through the
existing `gh_json`-based `gh_graphql`, with **no Accept header**.

The `application/vnd.github.merge-info-preview+json` preview that `mergeStateStatus`
once required is gone: the current GraphQL reference documents the field with no
preview note, and `docs.github.com/en/graphql/overview/schema-previews` now 301s away
(the header is still listed on the frozen
[GHES 3.12 schema-previews page](https://docs.github.com/en/enterprise-server@3.12/graphql/overview/schema-previews)).
`gh-axi api` does support `--header 'k: v'` **[probed]** if a future preview ever
needs one.

`MergeableState` — the *conflict* axis, and the one that is computed lazily
([GraphQL · pulls](https://docs.github.com/en/graphql/reference/pulls)):

| value | GitHub's description |
|---|---|
| `MERGEABLE` | "The pull request can be merged." |
| `CONFLICTING` | "The pull request cannot be merged due to merge conflicts." |
| `UNKNOWN` | "The mergeability of the pull request is still being calculated." |

`MergeStateStatus` — the *everything else* axis, and the closest thing to a documented
version of REST's `mergeable_state`:

| value | GitHub's description | risk-gate reading |
|---|---|---|
| `CLEAN` | "Mergeable and passing commit status." | the only unambiguous green |
| `UNSTABLE` | "Mergeable with non-passing commit status." | mergeable, but a check is failing or pending — **not** green |
| `HAS_HOOKS` | "Mergeable with passing commit status and pre-receive hooks." | green, Enterprise-only concern |
| `BEHIND` | "The head ref is out of date." | needs `update-branch` first |
| `BLOCKED` | "The merge is blocked." | protection/review gate unmet — no reason given |
| `DIRTY` | "The merge commit cannot be cleanly created." | conflicts |
| `DRAFT` | "The merge is blocked due to the pull request being a draft." | skip |
| `UNKNOWN` | "The state cannot currently be determined." | **retry, do not act** |

Note `UNSTABLE` and `BLOCKED` are the two that a naive "is it mergeable?" gate gets
wrong: `mergeable: MERGEABLE` is true in both, and both are things a risk gate should
stop on.

**GraphQL's lazy story is worse-documented than REST's.** `UNKNOWN`'s description
confirms the same background computation, but there is **no documented retry
instruction anywhere on the GraphQL side** — no "resubmit", no timing. Silence, not a
contract.

### 2.3 What the lazy problem forces

Both axes can be `UNKNOWN` on first read, and GitHub never promises when they stop
being. The loop today has no wait/retry posture at all: each phase reads once per
pass, acts or does not, and moves on. That is *survivable* here only because the poll
loop itself is a retry — an `UNKNOWN` this pass becomes a verdict next pass.

The real hazard is not the waiting; it is **conflating `UNKNOWN` with a verdict**. A
risk gate that scores "no conflicts detected" from `mergeable: UNKNOWN` will merge
conflicted PRs. `UNKNOWN` must be a distinct third outcome — *undecided* — that
produces neither a merge nor an escalation, just a deferral to the next pass. Whether
that is enough, or whether the phase needs a bounded in-pass poll, depends on how long
the poll interval is relative to the background job; GitHub gives no number, so the
in-pass poll would be guesswork and the next-pass deferral is the honest design.

---

## 3. Checks

### 3.1 Reading check state for a head SHA

**Verdict: reachable today, but only one of the three routes tells the truth.**

All three probed against PR #2's head `918c39fed5cb1d6f1d4e155b1cb1428f52a00dfb`:

| route | result |
|---|---|
| `gh_json "/repos/$o/$r/commits/$sha/check-runs"` | `{"total_count":0,"check_runs":[]}` |
| `gh_json "/repos/$o/$r/commits/$sha/status"` | `state: success`, `total_count: 1`, `statuses: [{context: CodeRabbit, state: success}]` |
| GraphQL `statusCheckRollup` | `state: SUCCESS`, `contexts.totalCount: 1`, one `StatusContext` `CodeRabbit`/`SUCCESS` |

**This is the finding that matters most for the risk gate: CodeRabbit reports through
the legacy commit-status API, not the Checks API.** A gate that reads
`/commits/{sha}/check-runs` — the modern, obvious choice — sees *zero checks* on a
repository where CodeRabbit is the only signal there is. It would score "no CI
configured" on a PR that CodeRabbit had just passed or failed.

The GraphQL `StatusCheckRollupContext` union is documented as `CheckRun | StatusContext`
([GraphQL · commits](https://docs.github.com/en/graphql/reference/commits#union-statuscheckrollupcontext)) —
it is the only API that merges both families in one read. REST needs two calls to see
the same thing.

Enum values, for the record:
- REST check-run `status`: `queued`, `in_progress`, `completed`, `waiting`,
  `requested`, `pending` ("waiting, requested, and pending are reserved for GitHub
  Actions check runs"). `conclusion`: `success`, `failure`, `neutral`, `cancelled`,
  `skipped`, `timed_out`, `action_required`, `null` — plus `stale`, which the list
  endpoint's schema omits but which GitHub can set
  ([REST · checks/runs](https://docs.github.com/en/rest/checks/runs?apiVersion=2022-11-28#list-check-runs-for-a-git-reference)).
- GraphQL `CheckStatusState`: `QUEUED`, `IN_PROGRESS`, `COMPLETED`, `WAITING`,
  `REQUESTED`, `PENDING`. `CheckConclusionState`: `ACTION_REQUIRED`, `CANCELLED`,
  `FAILURE`, `NEUTRAL`, `SKIPPED`, `STALE`, `STARTUP_FAILURE`, `SUCCESS`, `TIMED_OUT`
  ([GraphQL · checks](https://docs.github.com/en/graphql/reference/checks)).
- Legacy commit status `state`: `error`, `failure`, `pending`, `success`.

### 3.2 "In progress" vs. "nothing configured" — the two states the gate must not merge

**Verdict: reachable today via GraphQL; a trap in REST.**

GitHub documents the combined-status endpoint's rollup as
([REST · commits/statuses](https://docs.github.com/en/rest/commits/statuses?apiVersion=2022-11-28#get-the-combined-status-for-a-specific-reference)):

> "**failure** if any of the contexts report as `error` or `failure`; **pending** if
> there are no statuses or a context is `pending`; **success** if the latest status
> for all contexts is `success`"

So `state: "pending"` means *either* "a check is running" *or* "no checks exist at
all". **[probed]** — on `e74f467` (no statuses) the endpoint returns
`state: pending, total_count: 0, statuses: []`. The two states are separable only by
looking at `total_count`, never by `state`.

GraphQL is cleaner. **[probed]** — `statusCheckRollup` on the same check-free commit
returns **`null`**, where on a commit with checks it returns an object with a `state`:

```
{"data":{"repository":{"object":{"oid":"e74f467…","statusCheckRollup":null}}}}
```

GitHub's docs are *silent* on this — the field is schema-nullable but no page states
what the empty case returns — so this is an empirical result, not a contract. It is
consistent and it is the right shape (`null` = nothing to roll up; `PENDING` = running),
but a risk gate should not depend on it alone. **Check `contexts.totalCount` as well**,
and treat "rollup null or totalCount 0" as *no checks configured* — a distinct verdict
from *pending*, and one that on this repo means "CodeRabbit has not reported yet",
which is emphatically not a green light.

### 3.3 Required vs. merely present

**Verdict: reachable today, and better than expected.**

The obvious route — read branch protection, intersect with observed contexts — has two
problems on a personal repo. **[probed]**:

- `gh_json "/repos/nywleswoey/agentloop/branches/main/protection"` →
  `error: "gh: Branch not protected (HTTP 404)"`, `code: UNKNOWN`. So the *absence* of
  protection is indistinguishable from a transport failure at the current seam (§0.1).
  It also needs `Administration: read`
  ([REST · branch protection](https://docs.github.com/en/rest/branches/branch-protection?apiVersion=2022-11-28)).
- `gh_json "/repos/nywleswoey/agentloop/rulesets"` → `[]` and
  `gh_json "/repos/nywleswoey/agentloop/rules/branches/main"` → `[]`, both exit 0.
  Rulesets need only `Metadata: read` and are publicly readable
  ([REST · repos/rules](https://docs.github.com/en/rest/repos/rules?apiVersion=2022-11-28)) —
  strictly the better route, and it returns an empty array rather than a 404 when
  nothing is configured, which is a much friendlier signal.

On plan availability, GitHub's own wording: protected branches are "available in
public repositories with GitHub Free … and in public and private repositories with
GitHub Pro, GitHub Team, GitHub Enterprise Cloud, and GitHub Enterprise Server";
rulesets are "available in public repositories with GitHub Free … and in public and
private repositories with GitHub Pro, GitHub Team, and GitHub Enterprise Cloud"
([about protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches),
[about rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)).
Both are therefore available on a *user-owned* repo — free for public ones, Pro or
better for private ones. `nywleswoey/agentloop` is public, so both are readable; it
simply has neither configured.

**But the join is not necessary.** GitHub's GraphQL schema has an interface
`RequirableByPullRequest`, implemented by both `CheckRun` and `StatusContext`:

```graphql
interface RequirableByPullRequest {
  """Whether this is required to pass before merging for a specific pull request."""
  isRequired(pullRequestId: ID, pullRequestNumber: Int): Boolean!
}
```

(verified in the published schema at
`https://docs.github.com/public/fpt/schema.docs.graphql`;
`type CheckRun implements Node & RequirableByPullRequest & UniformResourceLocatable`,
`type StatusContext implements Node & RequirableByPullRequest`).

**[probed]** through the existing seam, this works and answers the question directly:

```sh
gh_graphql 'query{repository(owner:"nywleswoey",name:"agentloop"){
  pullRequest(number:2){ commits(last:1){ nodes{ commit{ statusCheckRollup{
    state
    contexts(first:100){ totalCount nodes{
      __typename
      ... on StatusContext { context state isRequired(pullRequestNumber:2) }
      ... on CheckRun     { name status conclusion isRequired(pullRequestNumber:2) }
    }}
  }}}}}}}'
```

returned `{"context":"CodeRabbit","isRequired":false,"state":"SUCCESS"}` — required-ness
per check, on the PR, in one call, without reading branch protection at all, and with
no extra permission.

One thing this does **not** give: no API cross-references "here are the required
checks *and* their state" from the *policy* side. `PullRequest.baseRef.branchProtectionRule.requiredStatusChecks`
gives names of required checks with no state; the rollup gives state with
`isRequired` per observed context. **A check that is required but has never reported
at all will not appear in the rollup**, and therefore will not appear as
`isRequired: true` either — it is simply missing. To catch "required check never ran",
the policy list still has to be read and diffed against the rollup. On a repo with no
protection and no rulesets that case is vacuous; on a repo with them it is not.

### 3.4 `gh-axi pr checks`

**Verdict: not usable for a risk gate.** **[probed]** `gh-axi pr checks 2` prints:

```
summary: "1 passed, 0 failed, 1 total"
checks[1]{name,conclusion}:
  CodeRabbit,pass
```

Name and a coarse `conclusion` only. No `status` (so no in-progress/queued/completed
distinction), no required flag, no timestamps, no URL, no `--jq`. It also normalises
`success` to `pass`, losing the underlying enum. Similarly `gh-axi pr view` exposes no
`mergeable`/`mergeStateStatus` at all — its `checks:` line is the same summary string.
Use `gh_json`/`gh_graphql` for everything.

---

## 4. Applying suggestions

### 4.1 There is no apply endpoint. This is the load-bearing answer.

**Verdict: not reachable — the mechanism does not exist in GitHub's API at all,
through `gh-axi` or otherwise.**

- **REST.** The complete review-comment surface is: list (repo-wide and per-PR), get,
  create, update, delete, create-a-reply, and reactions. There is no apply, no commit,
  no batch. Verified against
  [REST · pulls/comments](https://docs.github.com/en/rest/pulls/comments?apiVersion=2022-11-28).
- **GraphQL.** The full published schema
  (`https://docs.github.com/public/fpt/schema.docs.graphql`) was grepped
  case-insensitively for `suggest` across the whole `type Mutation` block. The only
  hits are `acceptTopicSuggestion`/`declineTopicSuggestion` (repository *topics*) and
  `applyPendingIssueSuggestions`/`rejectPendingIssueSuggestions` (issue field edits).
  No mutation applies a review-comment suggestion.
- **The near-miss that proves the point.** `PullRequest.viewerCanApplySuggestion:
  Boolean!` exists in the schema — "Whether or not the viewer can apply suggestion."
  **[probed]** it returns `true` on PR #1. GitHub models the *permission* to apply a
  suggestion and exposes it for reading, and exposes no way to exercise it. It is the
  enabled-ness of a web-UI button, surfaced without the button.
- **GitHub has been asked and has not answered.** In
  [community discussion 24848](https://github.com/orgs/community/discussions/24848)
  ("Suggested change API", Dec 2018) a GitHub staff member replied with a link to the
  UI blog post; the asker pointed out that it contains no API information; no staff
  member has since confirmed an apply endpoint exists. The docs page that describes
  "Commit suggestion" / "Commit suggestions" describes them purely as web-UI buttons
  ([incorporating feedback](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/incorporating-feedback-in-your-pull-request)).

**"Commit suggestion" is a web-UI-only affordance. An API caller must emulate it.**

### 4.2 What a suggestion actually is, and how to recover it

A suggestion is not an object. It is a fenced <code>```suggestion</code> block inside
the ordinary `body` of an ordinary review comment; GitHub's frontend parses the
markdown and renders the button. Nothing structured carries the replacement text.

**Verdict: reading the raw material is reachable today.** **[probed]**:

```sh
gh_json "/repos/$o/$r/pulls/$n/comments"          # list
gh_json "/repos/$o/$r/pulls/comments/$comment_id" # one (note: /pulls/comments/, not /pulls/N/comments/)
```

The fields that carry the target, with GitHub's own descriptions
([REST · pulls/comments](https://docs.github.com/en/rest/pulls/comments?apiVersion=2022-11-28)):

| field | frame of reference |
|---|---|
| `path` | file, current diff |
| `line` / `start_line` | last / first line of the range, **current head diff** |
| `original_line` / `original_start_line` | same, against `original_commit_id` |
| `side` / `start_side` | `LEFT`/`RIGHT` of the split diff |
| `commit_id` / `original_commit_id` | the commit the comment currently applies to / was made on |
| `diff_hunk` | surrounding context as of comment creation |
| `position` / `original_position` | diff indices — **GitHub marks both "closing down; use `line`/`original_line`"** |
| `subject_type` | `line` or `file` |
| `body` | where the suggestion fence lives |

So the recovery recipe is: parse the fence out of `body`, and replace
`start_line`..`line` (or just `line`) of `path` on `side`, at `commit_id`.

**[probed]** against PR #1's real CodeRabbit comments, and two things bite:

1. **Outdated comments null out the current-frame fields.** One comment came back as
   `{"line":null,"start_line":null,"original_line":679,"path":"tests/test-agent-loop.sh",
   "commit_id":"b811631…"}` while its siblings had live `line`/`start_line` and a later
   `commit_id`. GitHub's reference does **not** document this nulling — the only
   related prose is a warning on the *create* parameters that "Not using the latest
   commit SHA may render your comment outdated". So this is an empirical result:
   **`line == null` is the outdated marker, and such a suggestion cannot be applied
   without re-anchoring it.** The loop must skip or re-anchor those, not guess.
2. **The body contains more than one fence.** A real CodeRabbit comment
   (`3835746710` on PR #1) carries a <code>```diff</code> "Proposed fix" block, then the
   committable <code>```suggestion</code> block wrapped in `<details>`, then a
   <code>```</code>-fenced "Prompt for AI Agents" block, all in one `body`, delimited by
   `<!-- suggestion_start -->` / `<!-- suggestion_end -->` HTML comments. Taking "the
   first fenced block" gets the wrong text. The correct extraction is the
   <code>```suggestion</code> fence — ideally bounded by those markers. (CodeRabbit's
   side of this is #4's territory; recorded here because it changes what "parse the
   body" costs.)

### 4.3 Committing the emulated result

**Verdict: reachable — REST route today, GraphQL route with the §0.2 seam fix.**

Three documented primitives, in ascending order of fitness:

1. **`PUT /repos/{o}/{r}/contents/{path}`** — one file, one commit, needs the current
   blob `sha`. Unsigned commit.
   ([REST · repos/contents](https://docs.github.com/en/rest/repos/contents?apiVersion=2022-11-28))
2. **Git Data API** — `POST /git/blobs` → `POST /git/trees` → `POST /git/commits` →
   `PATCH /git/refs/heads/{branch}`. Multi-file, one commit, full control of author and
   committer, and `PATCH /git/refs` takes `force` (leave it false: "Leaving this out or
   setting it to false will make sure you're not overwriting work" — that is the
   optimistic-concurrency guard for the push).
   ([REST · git/refs](https://docs.github.com/en/rest/git/refs)) Unsigned.
3. **GraphQL `createCommitOnBranch`** — the schema's own words: "Commits made using
   this mutation are automatically signed by GitHub if supported and will be marked as
   verified in the user interface." Input:

   ```graphql
   input CreateCommitOnBranchInput {
     branch: CommittableBranch!
     expectedHeadOid: GitObjectID!            # required, not optional
     message: CommitMessage!
     fileChanges: FileChanges                 # { additions: [{path, contents: Base64String}], deletions: [{path}] }
   }
   ```

   It cannot set author or committer — the schema says so explicitly and points at the
   Git Database REST API for that. Its `expectedHeadOid` is **required**, which makes
   it the only one of the three that cannot race by accident.

For an unattended bot committing text it parsed out of a bot's comment,
`createCommitOnBranch` is the right choice: signed, atomic across files, and
race-proof by construction. Reaching it needs GraphQL variables to work — the
`fileChanges` object cannot be passed as a `--field` (only scalars are), but it can be
composed in the document from scalar variables:

```graphql
mutation($branch: CommittableBranch!, $oid: GitObjectID!, $msg: String!,
         $path: String!, $contents: Base64String!) {
  createCommitOnBranch(input: {
    branch: $branch, expectedHeadOid: $oid,
    message: {headline: $msg},
    fileChanges: {additions: [{path: $path, contents: $contents}]}
  }) { commit { oid } }
}
```

which is exactly the shape `pr-writeback.sh` already tries to use, and exactly the
shape that is currently broken (§0.2).

There is also a fourth route the loop already owns: **`git` itself**. `pr-writeback.sh`
already has `rebuild_branch`/`push_branch` and a real checkout. Applying a suggestion
locally with `git` and pushing is strictly simpler than the Git Data API, at the cost
of an unsigned commit and a non-atomic push. The choice between "commit via git" and
"commit via `createCommitOnBranch`" is a spec decision, not an availability one — both
are reachable.

---

## 5. Verdict table

| Capability | Verdict | How |
|---|---|---|
| Merge: methods merge/squash/rebase | **reachable today** | `gh_json PUT /repos/{o}/{r}/pulls/{n}/merge --field merge_method=…` |
| Merge: commit title/body | **reachable today** | same call, `--field commit_title=` / `--field commit_message=` |
| Merge: head-SHA guard | **reachable today** (REST only) | same call, `--field sha=$head` — **not available** on `gh-axi pr merge` |
| Merge: delete branch after | **reachable today** | `gh_json DELETE /repos/{o}/{r}/git/refs/heads/{branch}` — or repo's `delete_branch_on_merge` |
| Merge: enable GitHub auto-merge | **reachable with a new seam** | GraphQL `enablePullRequestAutoMerge`; needs the §0.2 fix. Moot on a repo with no protection. |
| Merge: refusal ≠ transport failure | **reachable with a new seam** | `gh_json` must surface the HTTP status parsed from `(HTTP nnn)`; `code:` is not a taxonomy |
| Merge: which required check blocked it | **not reachable** from the merge response | must be read separately, before the attempt (§3.3) |
| Mergeability: REST `mergeable`/`mergeable_state` | **reachable today** | `gh_json /repos/{o}/{r}/pulls/{n}` — one extra call per PR; absent from the list endpoint |
| Mergeability: GraphQL `mergeable`/`mergeStateStatus` | **reachable today** | `gh_graphql` query document, no preview header needed |
| Mergeability: lazy `UNKNOWN` handling | **reachable today**, but needs a *design* change | `UNKNOWN` must be a third outcome, not a false verdict (§2.3) |
| Checks: check runs for a SHA | **reachable today** | `gh_json /repos/{o}/{r}/commits/{sha}/check-runs` — **misses CodeRabbit** |
| Checks: commit statuses for a SHA | **reachable today** | `gh_json /repos/{o}/{r}/commits/{sha}/status` — where CodeRabbit actually reports |
| Checks: both families in one read | **reachable today** | GraphQL `statusCheckRollup.contexts` (union `CheckRun \| StatusContext`) |
| Checks: in-progress vs. none configured | **reachable today** via GraphQL | rollup `null`/`totalCount 0` = none; `PENDING` = running. REST `state` conflates them |
| Checks: required vs. merely present | **reachable today** | GraphQL `isRequired(pullRequestNumber:)` on each rollup context |
| Checks: required check that never reported | **reachable with a new seam** | needs the policy side too: `gh_json /repos/{o}/{r}/rules/branches/{branch}` (Metadata:read, returns `[]` not 404) |
| Branch protection read on a personal repo | **reachable today**, but prefer rulesets | protection needs `Administration: read` and 404s when unset; rulesets need `Metadata: read` and return `[]` |
| Applying a suggestion: a GitHub apply API | **not reachable** | does not exist — verified against the REST reference and the full published GraphQL schema |
| Applying a suggestion: reading the suggestion | **reachable today** | `gh_json /repos/{o}/{r}/pulls/{n}/comments`; parse the fence; `line == null` means outdated |
| Applying a suggestion: committing the result | **reachable today** (REST/git) / **with a new seam** (GraphQL) | Contents API, Git Data API, local `git`, or `createCommitOnBranch` (signed, `expectedHeadOid` required) |

---

## 6. What this means for the map

### 6.1 The single-writer seam in `pr-writeback.sh` has to change — three times over

1. **It is broken today and must be fixed regardless.** `gh_graphql` in
   `pr-writeback.sh` passes GraphQL variables to `POST /graphql`, which silently
   discards them. Every `addPullRequestReviewThreadReply` and `resolveReviewThread`
   the script has ever attempted against real GitHub failed. The stub suite cannot see
   it. Fix: drop the leading slash (`POST graphql`) or send one JSON `variables` field.
   This is not merge work, but the merge work cannot proceed over a seam that does not
   transmit its arguments.

2. **It has to grow a merge verb, and that verb needs a response body.** `gh-axi pr
   merge` is the wrong tool despite existing: it has no `--jq`, so its answer is TOON
   prose, and it has no head-SHA guard, so a bot cannot assert it is merging the commit
   it assessed. The merge must go through `gh_json PUT …/pulls/{n}/merge` with `sha=`.
   That means the writer needs the *reader's* decode path — `pr-writeback.sh` already
   has its own copy of the base64 trick, so this is a small extension, not a new shape.

3. **It has to grow a commit verb.** Applying suggestions has no GitHub endpoint, so
   the loop is committing files itself. Whether that is `createCommitOnBranch` or local
   `git` + push, it is a genuinely new kind of write — the first one that changes code
   rather than conversation. `pr-writeback.sh` already owns `rebuild_branch` and
   `push_branch`, so the machinery is half there; what is new is that the content comes
   from parsing a bot's comment rather than from a worker's worktree.

### 6.2 The read seam needs one thing it does not have: the HTTP status

`gh_json` returning a bare 1 was adequate when every failure meant "skip this project
this pass". It is not adequate for a merge bot, where 405 ("GitHub says this cannot be
merged") and a DNS failure both surface as `code: UNKNOWN`, exit 1. Adding a status
escape hatch to `gh_json` is the smallest change that makes a retry posture expressible
at all, and it is a prerequisite for the "failure and retry posture" item the map lists
as unspecified.

### 6.3 Lazy mergeability forces a posture the loop does not have — but a small one

The loop is stateless per pass: read, decide, act, forget. Lazy mergeability breaks
that only in one specific way — `UNKNOWN` is not an answer, and treating it as one
merges conflicted PRs. GitHub documents no wait time, so an in-pass poll would be
invented timing. The honest design is a **third verdict — *undecided* — that defers to
the next poll pass**, which the loop's existing rhythm already provides for free.

What that does require is a way to not re-decide the same thing forever: a PR stuck at
`UNKNOWN`, or one whose merge was refused with a 405, must not be re-attempted every
pass with no record. That is the same "avoid re-attempting the same failure every pass"
problem the map already lists, and `seen.jsonl` is the obvious place for it — but the
existing entries key on thread and last-comment id, which is the wrong key for a
PR-level merge attempt. Expect a new record shape.

### 6.4 Two facts that should change the risk rubric before it is written

- **CodeRabbit reports as a commit *status*, not a check run.** A risk gate built on
  `/commits/{sha}/check-runs` reads zero checks on this repository and would score
  every PR as "no CI to worry about". Read the rollup, or read both REST families.
- **`isRequired` makes the branch-protection join optional.** GraphQL answers
  required-vs-present per context with no extra permission and no protection read.
  That removes what looked like the hardest part of the checks signal — with the one
  residual gap that a required check which never reported is invisible to the rollup
  and still needs the ruleset read to notice.

### 6.5 One thing that is settled and one that is not

Settled: **there is no "Commit suggestion" API.** #4 may find that CodeRabbit offers
its own path (a slash command, a bot-side apply), but on GitHub's side the answer is
final — the loop patches the file and commits, or nothing happens. The risk gate's
"apply the autofixes" step is a text-manipulation problem, not an API-call problem, and
should be specified as one.

Not settled: **how a 405 renders through `gh-axi`.** Provoking one needs a genuinely
unmergeable PR, which this research was not allowed to create. Before the merge phase
ships, someone should open a throwaway conflicting PR on a scratch repository and
record the exact `error:`/`code:` lines for 405 and 409. The retry posture in §6.2
depends on that string, and a guess there becomes a bug in an unattended merge bot.
