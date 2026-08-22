# What CodeRabbit exposes to an automated caller on an open PR

Research for [#4](https://github.com/nywleswoey/agentloop/issues/4), under the map in
[#3](https://github.com/nywleswoey/agentloop/issues/3).
Date of investigation: 2026-08-22.

## How to read this file

Every claim is tagged:

- **[DOC]** — stated by CodeRabbit's or GitHub's own documentation. URL given.
- **[OBS]** — observed on this repository's PRs #1 and #2. The exact command is given; re-run it to check.
- **[UNKNOWN]** — could not be determined. Treated as a finding in its own right, not a gap to guess across.

Where **[DOC]** and **[OBS]** disagree, the observation is reported as authoritative for *this
account, this plan, this repo*, and the disagreement is called out explicitly.

## The account this was measured on

**[OBS]** Both reviews self-report their own run configuration inside the walkthrough comment
(`gh api /repos/nywleswoey/agentloop/issues/2/comments`, `⚙️ Run configuration` block):

```
Configuration used: defaults
Review profile: CHILL
Plan: Pro Plus
Run ID: 836d402c-e6cd-4e3b-bea9-dd7e5a5d6b48
```

So: **no `.coderabbit.yaml` in the repo** (confirmed — `ls -a` at the repo root shows none), every
documented default in force, and the plan is **Pro Plus**, not free. Anything below marked "requires
Pro" is therefore already available here, but would not be on a free/OSS-plan repo. The reported
plan string is machine-readable and worth parsing if the loop ever runs across repos on different
plans.

**[OBS]** Reviews are metered. PR #2's walkthrough carries:

```
Included review availability: Your plan provides up to 10 included reviews per hour; 6 remain after this review.
```

A loop that pushes commits to open PRs will consume this budget, because `auto_incremental_review`
defaults to `true` — **[DOC]** "Re-run the review on each push."
(<https://docs.coderabbit.ai/reference/configuration>)

---

# 1. Autofixes — what one actually is

## 1a. There are two distinct mechanisms, and they are not the same thing

### Mechanism A — GitHub committable `suggestion` blocks

**[OBS]** Some CodeRabbit inline review comments embed a standard GitHub suggestion fence. From
`gh api /repos/nywleswoey/agentloop/pulls/1/comments`, comment `3835746710`:

````
<!-- suggestion_start -->

<details>
<summary>📝 Committable suggestion</summary>

> ‼️ **IMPORTANT**
> Carefully review the code before committing. ...

```suggestion
setup "the budget counts loop workers across phases and spends the last slot once"
# Two live loop workers, one of them a PR worker: the budget is one pool, so
# only one of the two workable issues gets the remaining slot.
```

</details>

<!-- suggestion_end -->
````

**[OBS] Coverage is partial, and skewed to trivia.** Of the 5 inline comments CodeRabbit posted on
PR #1, **only 2 carried a `suggestion` fence** — and both were the `🟡 Minor` typo/comment-wording
findings. All three `🟠 Major` findings (pagination handling, GraphQL endpoint, blocked-by response
shape) had **no committable suggestion at all**, only a prose `✏️ Proposed fix` diff inside a
`<details>` block that is not a `suggestion` fence and is not committable. Verified with:

```
python3 -c "import json;d=json.load(open(...pr1_comments.json));[print(c['id'], '\`\`\`suggestion' in c['body']) for c in d]"
```

So a loop that only applies suggestion blocks would have fixed two comment typos and left every real
defect in place.

**[OBS] Suggestions go stale.** After the autofix commit landed, comment `3835746719` — one of the
two that *had* a suggestion — came back with `line: null`, `start_line: null`, `position: 1`, while
`original_line: 679`. GitHub marks a review comment outdated when the line it anchors to has moved;
an outdated suggestion cannot be committed. Any apply step must therefore run against a head SHA the
suggestions were computed for, and must re-check `line != null` immediately before applying.

### Mechanism B — CodeRabbit Autofix (the bot pushes the commit itself)

**[DOC]** <https://docs.coderabbit.ai/finishing-touches/autofix>

- Triggered by `@coderabbitai autofix` (commit to the current branch) or
  `@coderabbitai autofix stacked pr` (open a stacked PR). Aliases `auto-fix` / `auto fix` accepted.
- Also triggerable from the "🪄 Autofix" checkbox rendered under the review comment.
- **"Autofix also requires a Pro plan or higher."**
- "Autofix only processes unresolved CodeRabbit review threads with valid fix instructions."
- Exits without changes if merge conflicts exist; skips if no valid unresolved instructions exist.
- "Autofix may be rate-limited."
- The coding agent applies fixes and then runs a repository setup + build verification step. "Even
  if verification fails, the generated changes are still delivered."

**[DOC]** Config key: `finishing_touches.autofix.enabled`, default `true` — "Enable the autofix
finishing touch (trigger via the 🪄 Autofix checkboxes under review comments or the
`@coderabbitai autofix` command)." (<https://docs.coderabbit.ai/reference/configuration>)

**[OBS] This is what commit `1859566` in this repo is.** `git log -1 1859566425ce854a7c995d94bdd0958a4c5f4b07`:

```
Author: coderabbitai[bot] <136622811+coderabbitai[bot]@users.noreply.github.com>
Committer: GitHub <noreply@github.com>
Date:   Sat Aug 22 10:14:02 2026 +0000

    fix: apply CodeRabbit auto-fixes

    Fixed 4 file(s) based on 5 unresolved review comments.

    Co-authored-by: CodeRabbit <noreply@coderabbit.ai>
```

The commit was **authored and pushed by the bot**, not produced by applying suggestion blocks. Note
"based on **5** unresolved review comments" — it acted on all five findings, including the three that
had no committable suggestion. Autofix is strictly more capable than suggestion-application.

**[OBS]** It reports itself in a dedicated issue comment
(`gh api /repos/nywleswoey/agentloop/issues/1/comments`, comment `5379650071`):

```
<!-- This is an auto-generated comment: autofix status by CodeRabbit -->
## Fixes Applied Successfully

Fixed 4 file(s) based on 5 unresolved review comments.

**Files modified:**
- `agent-loop.sh`
- `pr-writeback.sh`
- `tests/test-agent-loop.sh`
- `tests/test-pr-writeback.sh`

**Commit:** `1859566425ce854a7c995d94bdd0958a4c5f4b07`

The changes have been pushed to the `port-to-github` branch.

**Time taken:** `17m 35s`
<!-- autofix-run-id: fc0ea1b8-8ae7-499b-b44e-15f1531dedb4 -->
```

`## Fixes Applied Successfully`, the modified-file list, the commit SHA and the
`<!-- autofix-run-id: ... -->` marker are all machine-parseable. **[UNKNOWN]** what the *failure*
variant of this comment looks like — no failed autofix run exists on this repo to observe.

**[OBS] How the PR #1 autofix was actually triggered.** Not by a comment — the issue timeline
(`gh api /repos/nywleswoey/agentloop/issues/1/timeline`) shows no `@coderabbitai autofix` comment.
The review body's edit history does:

```
gh api graphql -f query='{repository(owner:"nywleswoey",name:"agentloop"){pullRequest(number:1){reviews(first:5){nodes{userContentEdits(first:20){nodes{editedAt editor{login}}}}}}}}'
→ 2026-08-22T09:56:07Z  nywleswoey    (checkbox ticked)
  2026-08-22T09:56:12Z  coderabbitai  (acknowledges, run starts)
  2026-08-22T10:14:06Z  coderabbitai  (review body now shows "🪄 Autofix / ✅ Autofix completed")
```

A human with write access edited the **bot's own review body** to tick the checkbox. That the edit
was accepted at all is notable, but see the caveat under "cost" below.

## 1b. The decisive fact: GitHub has no API for applying a suggestion

**[OBS]** Live introspection of GitHub's GraphQL schema on 2026-08-22:

```
gh api graphql -f query='{ __schema { mutationType { fields { name } } } }' | grep -iE 'sugg|apply'
→ acceptTopicSuggestion, applyPendingIssueSuggestions, declineTopicSuggestion,
  rejectPendingIssueSuggestions
```

None of these touch code suggestions — they are repository-topic suggestions and Copilot-style
pending issue-field suggestions. Likewise:

```
gh api graphql -f query='{ __type(name:"PullRequestReviewComment") { fields { name } } }'
→ ... body bodyHTML bodyText diffHunk line originalLine outdated path startLine state ...
```

There is **no `suggestion` field and no `applySuggestion` / `commitSuggestion` mutation**. The
suggestion exists only as fenced markdown inside `body`.

**[DOC]** GitHub's own page on the feature describes it purely as UI:
<https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/incorporating-feedback-in-your-pull-request>
— "Click **Commit suggestion**" / "Add suggestion to batch", "you can also apply suggested changes as
a batch", and it makes **no mention of any API** for doing so.

**Conclusion: "Commit suggestion" and "Apply suggestions" are web-UI-only. An automated caller cannot
invoke them.** To apply a suggestion programmatically the loop would have to parse the
`suggestion` fence out of the comment body itself and splice it into the file at
`start_line..line` — reimplementing GitHub's applier, including its indentation and
outdated-anchor rules, with no API help.

## 1c. Enumeration, as the ticket asked

| # | Mechanism | Programmatic trigger | Plan | Latency (observed) | API cost |
|---|---|---|---|---|---|
| A1 | Commit a GitHub suggestion via GitHub's own machinery | **Not possible.** No REST or GraphQL endpoint exists (§1b) | n/a | n/a | n/a |
| A2 | Parse the suggestion fence yourself and write the file | `GET /repos/{o}/{r}/pulls/{n}/comments` + local edit + `git push` | any | seconds | 1 paginated GET; then a push |
| B1 | CodeRabbit Autofix → commit on branch | `POST /repos/{o}/{r}/issues/{n}/comments` with body `@coderabbitai autofix` **[DOC]** | **Pro or higher [DOC]**; this repo is Pro Plus | **17m 35s** on a 5-finding / 4-file run **[OBS]** | 1 POST to trigger; then poll `GET /issues/{n}/comments` for the autofix-status marker |
| B2 | CodeRabbit Autofix → stacked PR | same, body `@coderabbitai autofix stacked pr` **[DOC]** | Pro or higher | **[UNKNOWN]** | as B1, plus discovering the new PR |
| B3 | Tick the 🪄 Autofix checkbox in the bot's review body | Would require editing another actor's review body. A *human* with write access did this via the UI on PR #1 **[OBS]**; whether `PATCH /repos/{o}/{r}/pulls/{n}/reviews/{id}` permits editing a review you did not author is **[UNKNOWN]** — untested, and I declined to mutate a merged PR to find out | Pro or higher | as B1 | fragile; B1 achieves the same thing with a plain comment |

**A2 vs B1 is the real choice.** A2 is fast, free of plan gating, and covers only the subset of
findings that carry a fence — on the one sample available, the two most trivial of five. B1 covers
everything CodeRabbit found, is plan-gated, and takes on the order of **twenty minutes**, which is
far longer than any sane poll interval — it must be treated as an asynchronous job with its own
completion signal, never as a synchronous step.

**[OBS] Autofix does not close the loop by itself.** After `1859566` landed, CodeRabbit posted a
"Review completed" status on the new SHA four seconds later (10:14:12 queued → 10:14:16 success) and
did **not** refresh the walkthrough (the summary comment's `updated_at` stayed at `09:48:43`). The
Merge Risk verdict on PR #1 still reads `up to b8116` — the *pre-autofix* SHA. See §3c; this is the
single nastiest trap in the whole surface.

---

# 2. Completeness — has CodeRabbit finished?

**Yes, there is a reliable signal, and it is a legacy GitHub commit status with context
`CodeRabbit`.**

## 2a. The signal, observed

**[OBS]** `gh api /repos/nywleswoey/agentloop/statuses/918c39fed5cb1d6f1d4e155b1cb1428f52a00dfb`
(PR #2 head), newest first:

| created_at | state | description | context | creator |
|---|---|---|---|---|
| 10:38:40 | `success` | `Review completed` | `CodeRabbit` | `coderabbitai[bot]` |
| 10:36:58 | `pending` | `Review in progress` | `CodeRabbit` | `coderabbitai[bot]` |
| 10:36:55 | `pending` | `Review queued` | `CodeRabbit` | `coderabbitai[bot]` |

Same shape on PR #1's head `b81163…` (`pending`/`Review in progress` 09:42:06 → `success`/
`Review completed` 09:49:02) and on the autofix commit `1859566…` (`Review queued` 10:14:12 →
`Review completed` 10:14:16).

So the state machine is:

```
(no CodeRabbit status at all)  →  not started / not installed / not triggered
pending  "Review queued"       →  accepted, not begun
pending  "Review in progress"  →  running
success  "Review completed"    →  finished
```

**[OBS] The "opened 60 seconds ago" case is directly demonstrated.** PR #1 was created at
`2026-08-22T05:08:13Z`. Its head SHA carried **no CodeRabbit status of any kind** until `09:42:06`,
four and a half hours later, when a human typed `@coderabbitai review`. During that window the PR
was open, unreviewed, and *distinguishable* — the status simply did not exist. Contrast PR #2,
created `10:36:49`, auto-reviewed with no command: `Review queued` at `10:36:55`, six seconds after
open. Absence of the status is a real, load-bearing "not started".

**[OBS] Read it per head SHA, not per PR.** Statuses are keyed by commit. The correct query is
against `pr.head.sha`; a status on a stale SHA tells you nothing about the current one.

Cheapest reads:

```
gh api /repos/{owner}/{repo}/commits/{head_sha}/status      # combined; .statuses[] filtered on .context=="CodeRabbit"
gh api /repos/{owner}/{repo}/statuses/{head_sha}            # full history for that SHA, newest first
```

**[OBS]** `gh-axi pr checks <n>` surfaces it as a check row:

```
$ gh-axi pr checks 2 -R nywleswoey/agentloop
summary: "1 passed, 0 failed, 1 total"
checks[1]{name,conclusion}:
  CodeRabbit,pass
```

**Do not mistake `CodeRabbit,pass` for "no problems found."** PR #1 also reports
`CodeRabbit,pass` — with 5 actionable comments and a Merge Risk of `🟠 High`. `success` means
*the review ran to completion*, nothing more. **[UNKNOWN]** how `gh-axi pr checks` renders the
`pending` states — no open PR existed to observe, and it collapses conclusion to a single word.
Read the raw status API for the gate; use `gh-axi pr checks` only for display.

## 2b. Documented backing, and where it disagrees with observation

**[DOC]** <https://docs.coderabbit.ai/reference/configuration>:

- `commit_status`, default `true` — "Mirror review progress using legacy commit statuses for
  compatibility with required checks and existing automations. **This setting is only used when
  `review_progress` is disabled.**"
- `review_progress`, default `true` — "Publish the canonical user-facing review status and progress
  updates (GitHub progress reports/check runs today; other platform equivalents may follow)."
- `fail_commit_status`, default `false` — "On review errors, fail the active outward review status
  surface."

**[DOC]** The changelog entry *Review Progress Reports* (2026-07-22) says CodeRabbit "now publishes
its canonical, user-facing review status and progress through GitHub progress reports and check runs
by default… the legacy commit status can still be enabled for required checks and existing
automations."

**[OBS] This does not match what this repo emits.** With defaults in force (`review_progress` should
be `true`, and `commit_status` should therefore be inert), the repo produces the commit status and
**zero check runs**:

```
$ gh api /repos/nywleswoey/agentloop/commits/b81163…/check-runs
{"total_count":0,"check_runs":[]}

$ gh api graphql … statusCheckRollup { contexts { nodes { __typename … } } }
{"__typename":"StatusContext","context":"CodeRabbit","state":"SUCCESS","description":"Review completed"}
```

Only a `StatusContext`. No `CheckRun`. **The observation wins:** on this account today, the legacy
commit status is the *only* review-progress surface, and a gate that looks solely at check runs
would see nothing at all.

**Implication for the loop:** read *both*. Treat "a `CodeRabbit` StatusContext on the head SHA in
state `success`" **or** "a CodeRabbit check run on the head SHA with a terminal conclusion" as
completion, and the absence of both as not-started. This costs one extra call and immunises the gate
against CodeRabbit flipping the default out from under it.

## 2c. Corroborating (but weaker) signals

**[OBS]** The walkthrough comment carries stable HTML markers, and is authored by `coderabbitai[bot]`
(user id `136622811`, `type: "Bot"`, node_id `BOT_kgDOCCSy2w`). First line of the comment body is
always:

```
<!-- This is an auto-generated comment: summarize by coderabbit.ai -->
```

Other stable markers observed across #1 and #2:

| Marker | Where | Meaning |
|---|---|---|
| `<!-- This is an auto-generated comment: summarize by coderabbit.ai -->` | issue comment, line 1 | this is the walkthrough |
| `<!-- review_stack_entry_start/end -->` | walkthrough | Change Stack link block |
| `<!-- recent_review_start/end -->` | walkthrough | most-recent-run result |
| `<!-- walkthrough_start/end -->` | walkthrough | the walkthrough proper |
| `<!-- final_review_risk_start/end -->` | inside walkthrough | **the Merge Risk verdict — see §3** |
| `<!-- pre_merge_checks_walkthrough_start/end -->` | walkthrough | pre-merge check table |
| `<!-- finishing_touch_checkbox_start/end -->` | walkthrough | docstring / unit-test checkboxes |
| `<!-- tips_start/end -->` | walkthrough | boilerplate footer |
| `<!-- This is an auto-generated comment: autofix status by CodeRabbit -->` + `<!-- autofix-run-id: … -->` | separate issue comment | autofix result |
| `<!-- This is an auto-generated reply by CodeRabbit -->` + `<!-- CodeRabbit review command invocation: … -->` | separate issue comment | reply to a chat command |
| `<!-- This is an auto-generated comment: release notes by coderabbit.ai -->` … `<!-- end of … -->` | **the PR body** | CodeRabbit writes "Summary by CodeRabbit" into the description |
| `<!-- suggestion_start/end -->` | inline review comment | wraps the committable suggestion |
| `<!-- cr-indicator-types:potential_issue -->` | inline review comment | finding class |
| `<!-- cr-comment:v1:<24-hex> -->` | inline review comment, and each entry in the review body | stable per-finding id |
| `<!-- fingerprinting:phantom:medusa:<word> -->` | inline review comment | dedup fingerprint |

These markers are **undocumented**; they are HTML comments in a product surface and could change
without notice. They are excellent for *parsing* a comment you have already identified, and a poor
primary completeness signal compared to the commit status.

**[OBS] Do not use "a review exists" as the completeness signal.** PR #2 was fully reviewed and
`GET /repos/nywleswoey/agentloop/pulls/2/reviews` returns `[]` — an empty array — as does
`/pulls/2/comments`. When CodeRabbit has nothing actionable to say it posts **no review object at
all**, only the walkthrough comment containing:

```
No actionable comments were generated in the recent review. 🎉
```

A gate keyed on "has CodeRabbit submitted a review?" would classify a clean, finished PR as
unreviewed forever. This is exactly the failure mode the ticket warned about.

## 2d. Verdict on completeness

**A reliable signal exists.** It is the `CodeRabbit` commit status on the PR's head SHA, corroborated
by a check run if CodeRabbit ever switches surfaces. It is well-defined, per-SHA, three-valued, and
absent when nothing has run. The gate should:

1. Read `pr.head.sha`.
2. Read the combined status **and** check runs for that SHA.
3. Require a terminal CodeRabbit result before evaluating risk at all; otherwise wait.
4. Never infer completion from the presence or absence of reviews or review comments.

---

# 3. Verdict — what a risk rubric can read

## 3a. Merge Risk — the headline finding

**[OBS]** The walkthrough comment contains an explicit, delimited, machine-readable merge-risk
verdict. PR #2:

```
<!-- final_review_risk_start -->
**Merge Risk:** _⚪ Minimal_ · up to `918c3`

This localized change preserves complete API responses in both wrappers, preventing valid projects
from being rejected because response bodies are truncated. No actionable merge-blocking risk remains
beyond normal checks and review.
<!-- final_review_risk_end -->
```

PR #1:

```
<!-- final_review_risk_start -->
**Merge Risk:** _🟠 High_ · up to `b8116`

The GitHub migration can currently fail during reads and review-thread updates, while an unchecked
repository mismatch could push changes or mutate threads in the wrong repository. It is not
merge-ready until these correctness and target-validation issues are fixed.
<!-- final_review_risk_end -->
```

This is exactly the shape the risk rubric wants: a **single labelled level**, a **SHA scope**, and a
prose justification, inside stable delimiters.

**[UNKNOWN] The full ladder of levels.** Only `⚪ Minimal` and `🟠 High` were observed. The emoji
progression strongly suggests intermediate levels (the review-comment severities use 🟡 for Minor
and 🟠 for Major, so a 🟡/🔴 pair is plausible), but **I could not find any CodeRabbit documentation
for the Merge Risk feature at all** — not in the configuration reference, not in the glossary, not in
`pr-reviews/pre-merge-checks`, not in the changelog, and not in the "Agentic Change Management" or
"Mergemaxxing" launch posts. Searches across `docs.coderabbit.ai` returned nothing. **A rubric must
therefore fail closed on an unrecognised level rather than assume an ordering.**

**[UNKNOWN]** Whether Merge Risk can be disabled by config, and whether it appears on all plans.

## 3b. Per-comment severity — structured, and it is the first line of every finding

**[OBS]** Every CodeRabbit inline review comment on PR #1 opens with a pipe-delimited triple of
italicised, emoji-prefixed labels, before any prose:

```
_🩺 Stability & Availability_ | _🟠 Major_ | _🏗️ Heavy lift_
_🩺 Stability & Availability_ | _🟠 Major_ | _⚡ Quick win_
_🎯 Functional Correctness_   | _🟠 Major_ | _⚡ Quick win_
_📐 Maintainability & Code Quality_ | _🟡 Minor_ | _⚡ Quick win_
_📐 Maintainability & Code Quality_ | _🟡 Minor_ | _⚡ Quick win_
```

The same triple prefixes each entry in the review-body rollup. The outside-diff finding in PR #1's
review body reads:

```
`217-227`: _🗄️ Data Integrity & Integration_ | _🟠 Major_ | _🏗️ Heavy lift_
```

- **Category** observed: `🩺 Stability & Availability`, `🎯 Functional Correctness`,
  `📐 Maintainability & Code Quality`, `🗄️ Data Integrity & Integration`.
- **Severity** observed: `🟠 Major`, `🟡 Minor`.
- **Effort** observed: `🏗️ Heavy lift`, `⚡ Quick win`.

Parsing `^_[^_]+_ \| _(\S+ \w+)_ \| _[^_]+_` off the first line of each comment body gives a
severity per finding, countable into a histogram.

**[UNKNOWN] The complete vocabularies.** Only these values appeared on two PRs. Marketing copy on
coderabbit.ai mentions "Critical, Major, Minor, or Trivial", but I could not corroborate that against
`docs.coderabbit.ai` and will not treat a marketing page as authoritative for a gate's enum. Same
fail-closed rule as Merge Risk: an unrecognised severity must escalate, not default to low.

## 3c. Actionable-comment count

**[OBS]** When CodeRabbit has findings it submits a review whose body's **first line** is:

```
**Actionable comments posted: 5**
```

(`gh api /repos/nywleswoey/agentloop/pulls/1/reviews` → review `4999883782`.)

**[OBS]** When it has none it submits **no review at all**; the count lives instead as prose in the
walkthrough: `No actionable comments were generated in the recent review. 🎉`.

So the count is available, but from two different places depending on its value — a parser must
handle both, and must treat "no review object" as zero rather than as unknown.

## 3d. Review state — currently useless as a blocking signal

**[OBS]** PR #1's review state is **`COMMENTED`**, not `CHANGES_REQUESTED`, despite five findings and
`Merge Risk: 🟠 High`. PR #2 has no review object at all.

**[DOC]** This is expected. `request_changes_workflow` defaults to **`false`**
(<https://docs.coderabbit.ai/reference/configuration>): "Automatically approve when CodeRabbit's
comments are resolved, the latest commit has been reviewed, and no pre-merge checks are failing."
With it enabled, CodeRabbit submits a `CHANGES_REQUESTED` review when it finds issues and flips to
`APPROVED` once comments are resolved and pre-merge checks pass.

**This is the single highest-leverage configuration change available to the effort.** Turning
`request_changes_workflow: true` on in `.coderabbit.yaml` converts CodeRabbit's opinion from
"prose in a comment I must regex" into GitHub's own native, first-class, already-modelled
`APPROVED` / `CHANGES_REQUESTED` review state — which the loop can read from
`GET /pulls/{n}/reviews`, and which GitHub's branch protection can enforce independently of the
loop. It costs one committed YAML file. **[UNKNOWN]** whether enabling it changes review latency or
consumes extra review budget; also note it means CodeRabbit will *approve* PRs, which changes what
"approved" means in this repo.

## 3e. Pre-merge checks

**[OBS]** A structured, delimited table inside the walkthrough. PR #1:

```
<details>
<summary>🚥 Pre-merge checks | ✅ 4 | ❌ 1</summary>

### ❌ Failed checks (1 warning)
| Check name | Status | Explanation | Resolution |
| Docstring Coverage | ⚠️ Warning | Docstring coverage is 73.21% which is insufficient. The required threshold is 80.00%. … |
```

PR #2: `🚥 Pre-merge checks | ✅ 5`. The `<summary>` line alone yields pass/fail counts.

**[DOC]** <https://docs.coderabbit.ai/pr-reviews/pre-merge-checks> — four built-in checks (Docstring
Coverage, PR Title, PR Description, Issue Assessment) plus custom checks; each has mode
`off` / `warning` (default) / `error`; **"When paired with Request Changes Workflow, block merges
until resolved or manually overridden."** Without `request_changes_workflow`, a failed pre-merge
check is advisory only — as seen on PR #1, which merged with a failing docstring check and no
obstruction.

## 3f. The staleness trap

**[OBS]** This is the most dangerous thing found, and it deserves its own section.

Timeline on PR #1:

| Time | Event |
|---|---|
| 09:48:43 | walkthrough comment last updated — `Merge Risk: 🟠 High · up to b8116` |
| 09:48:54 | review submitted, `Actionable comments posted: 5` |
| 10:14:02 | autofix commit `1859566` pushed by the bot |
| 10:14:12 | `CodeRabbit` status → `pending` / `Review queued` on `1859566` |
| 10:14:16 | `CodeRabbit` status → **`success` / `Review completed`** on `1859566` (4 seconds later) |
| — | walkthrough comment **never updated**; `updated_at` still `09:48:43` |

So at 10:14:16 a naive gate reading "CodeRabbit status is `success` on head" plus "Merge Risk from
the walkthrough" would have combined a *fresh* completion signal with a **stale, pre-autofix `High`**
verdict. The reverse failure is equally possible on a different timeline.

**The `· up to \`<sha7>\`` suffix in the Merge Risk line is the defence.** It names the SHA the
verdict was computed for. A gate must compare that prefix against the current head SHA and treat a
mismatch as *no current verdict* — which means waiting, or escalating, but never merging on the
strength of an old one.

Corollary: a four-second "Review completed" is almost certainly a skipped/no-op incremental review,
not a real one. Completion status alone does not imply a fresh verdict exists.

---

# 4. What I could not determine

Stated plainly, because a gate will be built on this:

1. **The full Merge Risk ladder.** Two levels observed (`⚪ Minimal`, `🟠 High`). Zero documentation
   found anywhere on docs.coderabbit.ai for the feature. Ordering of unobserved levels is a guess and
   I have not made one.
2. **The full severity and category vocabularies** on inline comments. Same reasoning.
3. **What a failed autofix run looks like** — no failure exists on this repo to observe. The success
   comment says `## Fixes Applied Successfully`; the failure string is unknown.
4. **Autofix latency distribution.** One data point: 17m 35s for 5 findings across 4 files. No basis
   for a timeout, other than "much longer than a poll interval".
5. **`@coderabbitai autofix stacked pr` behaviour** — never exercised here.
6. **Whether `PATCH /pulls/{n}/reviews/{id}` lets a non-author tick the 🪄 Autofix checkbox.** A human
   with write access did it through the UI; the REST equivalent is untested and I declined to mutate
   a merged PR to find out. Moot if B1 (the comment command) is used.
7. **How `gh-axi pr checks` renders CodeRabbit's `pending` states**, and whether it distinguishes
   "queued" from "in progress". Not observable without a live open PR.
8. **Whether Merge Risk / severity labels are plan-gated.** Everything here was measured on Pro Plus.
9. **Why the changelog says check runs are the default surface while this repo emits only a legacy
   commit status.** Possibly a staged rollout, possibly account-level. Unresolved; hence the
   read-both recommendation.

---

# What this means for the map

**The loop almost certainly does not need an Orca worker to apply autofixes.** The two candidate
mechanisms both point away from one. Applying GitHub suggestion blocks is not something an Orca
worker would help with — there is no API to call, so it reduces to string-splicing a fence into a
file, which is a dozen lines of bash in `pr-writeback.sh`, not an agent's job; and on the only sample
available it covers just the trivial findings (2 of 5, both comment typos), leaving every `Major`
defect untouched. CodeRabbit's own Autofix covers *all* unresolved findings and produces a real
commit — but it does the work itself, on its own infrastructure, triggered by a single
`gh-axi pr comment <n> --body '@coderabbitai autofix'`. Either way, no worker, no worktree, no
plan file. What the loop needs instead is a **triggered-and-waiting state**: fire the comment, record
that autofix is in flight for this PR, and come back — because 17 minutes is many poll intervals, and
re-firing on every pass would burn the 10-reviews-per-hour budget and stack duplicate runs. That
state, not agent dispatch, is the real design problem `pr_phase`'s replacement has to solve.

**A reliable completeness signal does exist**, and it is cleaner than the ticket feared: the legacy
GitHub commit status with context `CodeRabbit` on the PR's head SHA, moving
`Review queued` → `Review in progress` → `Review completed`, and simply absent when nothing has run.
Absence-means-not-started was demonstrated over a four-and-a-half-hour window on PR #1. Read it per
head SHA, read check runs alongside it (the docs claim those are now the default surface even though
this account emits only the status), and **never** infer completion from the presence of a review —
PR #2 was fully reviewed and has zero reviews and zero review comments, because a clean PR gets no
review object at all.

**The risk verdict has more structure than expected, and one sharp edge.** `Merge Risk: <level> · up
to <sha7>` inside `<!-- final_review_risk_start/end -->`, per-comment
`category | severity | effort` triples, `Actionable comments posted: N`, and a pre-merge check table
with pass/fail counts — all parseable. But the Merge Risk feature is **entirely undocumented**, so
the rubric must fail closed on any level it does not recognise, and it must check the `· up to
<sha7>` scope against the current head, because the walkthrough is not always recomputed when the
head moves (demonstrated on PR #1, where a `High` verdict for the pre-autofix SHA sat next to a
`success` status for the post-autofix one). Note also that `CodeRabbit,pass` in `gh-axi pr checks`
means "the review finished", not "nothing is wrong" — PR #1 shows `pass` alongside five findings and
`Merge Risk: High`.

**One config change would simplify all of this.** Setting `request_changes_workflow: true` in a
`.coderabbit.yaml` makes CodeRabbit submit a native `CHANGES_REQUESTED` review when it finds issues
and flip to `APPROVED` when they are resolved and pre-merge checks pass. That converts the verdict
from undocumented prose the loop must regex into a first-class GitHub review state — readable by the
loop, and enforceable by branch protection independently of it. It also promotes pre-merge checks
from advisory to blocking. It is worth a ticket of its own before the rubric's shape is settled,
because it changes what the rubric has to parse.
