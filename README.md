# agent-loop

A bash daemon that polls GitHub, dispatches [Orca](https://orca.computer) agent workers at issues labelled ready, drives CodeRabbit's own autofix at the findings on open pull requests, and — past a gate of four vetoes — merges them unattended.

Started by hand, runs until Ctrl-C. Every decision it makes is one log line, so silence means nothing happened rather than something was swallowed.

---

## What it does

Each pass, in order:

1. **Close-out** — an issue whose pull request has merged gets its checklist ticked, its description updated, its claim label removed, and the issue closed. What decides whether an issue is close-out's is the **claim label, not the state**: a pull request body carrying `Closes #N` has GitHub close the issue itself at merge, a pass before close-out reads it, and such an issue still needs its tick and its unclaim. So a closed issue still wearing the claim gets both, and no second close.
2. **Issues** — queries each project for open issues labelled `ready-for-agent`, skips ones an open pull request already delivers, **refuses** ones whose written blocking claim the dependency graph does not carry, skips ones with an open blocker, swaps the label to `agent-in-progress`, and dispatches an Orca worker into a fresh worktree.
3. **Pull requests** — enumerates every open pull request in each project except drafts and fork heads, derives its state from GitHub alone, logs one line per pull request, comments `@coderabbitai review` at the ones CodeRabbit never reviewed and `@coderabbitai autofix` at the ones carrying unresolved findings, runs the risk gate over the ones that are ready to judge, merges at most one of them per repository, and hands over the ones it will not act on. It spends no worker and no worktree, and it keeps no local state: every pass re-derives from a fresh read.
4. **Sweep** — removes the loop's own finished worktrees.

Between passes it sleeps for `pollIntervalSeconds`.

### Guard rails

- **Worker budget** — never more than `maxWorkers` live workers. Checked before *every* issue dispatch, not once per pass, so a candidate arriving at a full budget waits for a later pass rather than being dropped. It governs **issue dispatch only**: the PR phase spends no worktree, no checkout and no agent, so a long-running issue does not stall the pull requests behind it.
- **Fail closed** — if the worktree inventory can't be read, the budget is treated as full and the sweep is skipped. A budget that failed open would dispatch a fresh `maxWorkers` on top of the workers it couldn't see.
- **PID lock** — one loop per machine.
- **Startup reclaim** — an issue left claimed with no live worker (crash, failed dispatch) is handed back to `ready-for-agent` when the loop next starts. Liveness is not the whole question, though: a worker that **finished** leaves no process behind either, and reading that as "nobody has worked on it" is what once had two workers rebuild the same feature into two branches. So an issue whose branch already carries an **open** pull request stays claimed, and the issue phase asks the same question a second time — a ready label applied by hand never passes through the reclaim at all. **Merged** pull requests deliberately do not count: those are close-out's, and close-out runs first in both orderings. **Closed-unmerged** ones deliberately do not count either — abandoning a pull request should return its issue to the loop. Both callers fail closed: a read that will not answer skips the reclaim, or the issue phase, rather than risking a duplicate.
- **Log rotation** — one generation, capped at 5 MiB. A loop left running for weeks must not fill the disk.

These are the daemon's own rails. What bounds the **unattended merge** is the next section.

### A refusal is not a skip

**A native GitHub dependency edge is the only "blocked" the loop trusts.** Before every dispatch the issue phase compares the issue body's blocking claim against the issue's native blocked-by edges — all of them, whatever state they are in, each normalised to `(repository, number)`. The claim is a `## Blocked by` (or `Blocked on`) heading, scoped to the next heading of any level or the end of the body, with the `#N` and `owner/repo#N` inside it as its referents; a bare `#N` outside a claim anchors nothing, and an empty or absent body passes. No referent's state is resolved — a closed edge verifies its claim without blocking, because resolving would have the graph defer to prose in the acquitting direction and cost a request per unmatched referent. A claim the graph does not carry **refuses**: the issue is not dispatched and not claimed, `agent-refused` goes on and `ready-for-agent` comes off in one atomic write, and one comment names exactly which referents could not be verified, what the loop did, and how to clear it. A skip is a retry and a refusal is terminal, so the refusal is checked **before** the open-blocker skip and before the budget — a full budget must not silence it — and the ticket leaves the ready queue, so there is no repeated skip and no daily re-comment. **Re-labelling ready is your acknowledgement.** The loop does not restore the label and does not write the missing edge itself; writing it would be the loop acting on a claim it could not verify, which is the thing the rule forbids. The flag is live rather than one-way: a pass that finds a flagged issue passing takes the flag off and writes nothing else, because a fixed, re-labelled, dispatched issue must not wear a flag that is now false. The comment is never withdrawn — it records an event that was true when it was written and stays true.

The two invariants below are **scoped to the pull-request phase**, so neither gains a row for this; it is checked against both anyway and passes. Its bounded exit is the operator's re-label — `external`, the same disposition [`rate-limited`](#the-bounded-exit-invariant) already carries and which that table records as correct rather than a hole. Its cycle — refuse, out of the queue, operator acts, back in, pass — can only turn a second time on a human choosing, and that rests on a standing condition worth writing down: **no dispatch of the loop's causes any issue to enter the ready queue.** It holds trivially today, a dispatched worker implementing against an issue that already exists. It is phrased around *what enters the queue* rather than around *what the loop dispatches* on purpose, because the loop is about to dispatch `/to-tickets`, an authoring skill that publishes child issues: under that map the condition still holds, but for a new reason — the children land **without** `ready-for-agent`, and the decomposed spec exits via close-out flagged rather than re-armed. **The residual, recorded with it:** that inertness then rests on a worker instruction rather than on this script, and the loop cannot enforce what a worker labels.

---

## What the loop does unattended

On an open pull request the loop **comments, labels and merges without asking**. What follows is what that means: how a pull request gets judged, the gate that judges it, what the loop hands back when it will not act, and how you take a pull request off it. Every write goes through `pr-writeback.sh`, one write per invocation — see [the writeback seam](#the-writeback-seam) — and `--no-merge` holds the merge and nothing else.

Since there is no local state, the one log line the loop prints per pull request per pass is the **only record a wait leaves**.

If you have read this file before: this section used to promise that *nothing is written to GitHub without confirmation*. That promise is gone, and it is named here rather than quietly deleted, because a reader who remembers it is owed the retraction.

### Getting a pull request judged

- **Once per head commit, and never at the loop's own output.** Autofix is spent on a head for either of two sufficient reasons, and the log line names which: the trigger records its input head and the matching autofix-status comment spends it (`spent:trigger` — generated output commits and failure prose are never used as the input identity), or **the head commit's author is CodeRabbit** (`spent:own-head`). The second is the rule *the loop does not act on its own output*, and it is what stops a fix chain that turns with no human in it: the nudge below runs a full review at an autofix head, that review can mint new findings on the autofix's own diff, and without this the loop would fix them and mint another head. Author rather than committer, knowingly over-broad — GitHub's *Commit suggestion* button attributes the author to the suggester, and the operator recovers by typing `@coderabbitai autofix` by hand, which the loop already reads as an autofix in flight.

  The accepted cost is that new findings on an autofix commit reach the gate unfixed. That is the right backstop: the full review has moved the merge-risk block onto that head, so V1 judges the new review's level, and a bad autofix escalates rather than being silently re-fixed by the thing that produced it.
- **A pull request with no verdict covering its head is nudged, then handed over.** It reaches `needs-review` on any of three clauses, and the log line carries which one fired:

  | Route | What it means |
  |---|---|
  | `no-signal` | CodeRabbit put nothing at all on the head commit |
  | `no-block` | there is no merge-risk block anywhere on the pull request |
  | `other-head` | the block parses, and the abbreviation it names is **not** a prefix of the head |

  The second clause exists because a **green CodeRabbit status does not mean the code was reviewed**: a draft gets one too, with a *review skipped* description, and un-drafting is not a push, so the head never moves. The test is for the block's HTML marker rather than for any prose, and a *clean* review still carries the block, so its absence cannot mean a clean review.

  The third exists because **CodeRabbit will not re-walkthrough its own autofix commit** — in five of nine recently merged pull requests the head's walkthrough named a different commit. Autofix is the loop's primary path, so V1's prefix test alone would veto nearly every pull request the loop itself fixes, permanently, on a cause the loop's own write produced and no operator can clear. Relaxing V1 to accept the parent's verdict was rejected: the nine-second *Review completed* on an autofix head is almost certainly a **skip**, so clearing on it would merge a diff no verdict covers. The mismatch is loop-produced, so it cannot be a `no`; it is permanent at that head, so a `defer` buys nothing; but it is loop-*retractable*, and its remedy is a write. So the gate judges and the chain repairs. It is cause-blind, so a force-pushed head takes the same remedy — and stands on firmer ground there, that head really being new code.

  Every clause is cause-blind, which is also why the second catches the rate-limit path's passing check. The remedy is a write in every case, because the cause does not clear on its own: CodeRabbit auto-pauses incremental reviews after five reviewed commits and the counter resets only when the pause is lifted, which is a command. So the loop posts `@coderabbitai review`, once per head, and gives it **one poll interval** — command replies arrive in seconds. Past that it hands the pull request over as `stalled`, and the reason **branches on the route**: the first two name the two causes an operator can act on — CodeRabbit may not be installed on the repository, or the organisation may be out of seats — while `other-head` says what is actually true there, that CodeRabbit reviewed this head and left its verdict on another commit. A pull request that is merely **rate-limited** waits instead of being nudged. **No CodeRabbit prose is parsed anywhere on this path** — the bot's reply is pasted into the handover verbatim and nothing keys on it.

  `needs-review` sits ahead of `needs-autofix`, so the loop asks for a verdict on a head before firing autofix at it. That is the ordering the chain already asserts, and it costs a pass.
- **A review that started and never finished is bounded too.** A pending CodeRabbit status with nothing after it is `mergeGateTimeoutSeconds` from the **oldest pending status on the head commit** — not from the commit's own date, because a real pull request sat four and a half hours between its head commit and its review starting, and not from the newest, because the progress statuses land three seconds apart and are phase markers rather than heartbeats. A signal that names no instant of its own — a check run GitHub has queued and not yet started — falls back to the head commit, which can only make the clock run early, and the log line names which origin it used. It escalates as `stuck` rather than `stalled`, and it is never nudged: CodeRabbit has already acknowledged the work, and a pending status is not a pause.

### The risk gate

A pull request that is ready to judge goes through four independent vetoes over its head commit, and a clock that bounds the third of its three outcomes — `merge`, `escalate` and `defer`. **CodeRabbit's verdict is a necessary input, not the verdict**: the reviewer judges the code, the loop judges blast radius and merge mechanics, and each holds a veto.

- **V1 — CodeRabbit's verdict.** Its merge-risk block must name a commit abbreviation that is a prefix of the head, and put the level at exactly *minimal*. An unrecognised level or an unparseable line escalates — the tripwire for CodeRabbit changing shape. A block that is missing entirely, or one naming another commit, never reaches here: those are two of the three routes into `needs-review`, which is nudged and bounded first — so what actually arrives is *a terminal review and a block naming this head*. Both unreachable branches are kept anyway, because the chain reads the block across every comment where V1 reads it out of CodeRabbit's newest walkthrough, and the safe direction for that asymmetry is for the stricter reader to escalate. The **parse is shared between them**, so the one thing they cannot disagree about is which commit a verdict names.
- **V2 — checks.** *Every* rollup context green, not just the required ones — reading every context is strictly stricter than reading the required ones, and it does not depend on how any particular repository is configured. A check that has not reported yet defers rather than blocking; one that ran and declined to judge — skipped or neutral — counts as green, which is what GitHub itself says about the same commit. V2 owns *the state of every check on the head*, and it is the only veto that may speak about it.
- **V3 — conflicts and base drift.** V3 owns the facts that are functions of `(head, base tip)` alone: whether head and base tip conflict, and whether base has moved past the merge base. It reads `mergeable` and `mergeStateStatus` and **says nothing about the values it reads but does not own** — a `mergeStateStatus` of `BLOCKED` is mixed or undocumented, with causes V3 does not own, so it defers rather than treating it as a specific check state; `DIRTY` is the conflict fact the other axis already owns, and `UNSTABLE` is a check, so both pass. Only `CONFLICTING` and `BEHIND` are a veto. Anything else defers: `BLOCKED`, `UNKNOWN`, empty, or a value GitHub adds tomorrow defer *that one pull request* rather than escalating the queue, and `DRAFT` and `HAS_HOOKS` defer too but carry the permanence mark below. The handover carries **two rows**, one per axis, and the log line's `mergeability=` key carries the stricter of them. A branch that is **behind is never updated** — that write would move the head, void the verdict just validated, and spend metered review budget re-reviewing it.
- **V4 — blast radius.** Any change under `.github/workflows/`, or to `agent-loop.sh`, `pr-writeback.sh` or `gh.sh`, escalates. The principle is *never minimal if merging it changes what runs unattended*. There is **no diff-size ceiling** — a big change is not a risky one. A pull request touching more than 100 files escalates all the same, on the different ground that the read carries one page and merging on a file list known to be partial would let exactly the change this veto looks for slip past the page boundary.
- **V5 — the clock, which is not a veto.** `defer` is the third outcome and is not a failure: a check still running, or a conflict axis GitHub has not finished computing, is re-derived next pass in silence. `mergeGateTimeoutSeconds` from the head commit's date is what stops that being forever. **An expired defer is not a `no`**: the deferring rows are never reclassified at expiry — they still read `defer` and still name what they are waiting on — and the clock gets its own row, verdict `note`, emitted whenever anything defers and never when nothing does. What changes past the bound is the kind on the handover's first line, not any row's verdict. A pull request whose review is merely rate-limited defers too — ahead of every veto, and exempt from that clock, because the rate limit self-clears on its own.
- **The permanence mark — the gate owns judgement, the clock owns duration.** A deferring reason whose cause set is *fully established from a primary source* and *no member of which can be retracted by elapsed time alone* is marked **permanent**, and escalates as `stuck` on the pass it is derived instead of waiting out a clock that will decide nothing. The verdict stays `defer` and the mark rides on the reason: a `no` would fail the ownership rule above, and a fourth verdict bin has no honest position in `no > defer > ok`. Two values qualify today — `HAS_HOOKS` and `DRAFT` — and both are unreachable in practice, which is the point: **the value is the test, not the members.** The class cannot grow through `BLOCKED` or the unrecognised-value arm, because neither cause set is established. The clock's row says which of its three states it is in, and keeps `age=` and `bound=` on all three, so an early handover cannot be mistaken for a mis-set timeout:

  | Condition | The row reads |
  |---|---|
  | unexpired, nothing marked | the merge-gate clock has not run out yet |
  | expired, nothing marked | the merge-gate clock has run out |
  | a deferring reason is marked permanent (tested first, so it wins over expiry) | the merge-gate clock does not apply — a deferring cause above is permanent; the raw values name it, `permanent=HAS_HOOKS` |

Two rules govern what a veto is allowed to say, and both are checkable against the next one somebody adds:

- **One signal, one veto.** For every underlying *fact* about a pull request, exactly one veto owns it, and only the owner may let that fact move its verdict. A veto reading a value whose causes include a fact it does not own returns a verdict carrying no information about that fact — `ok` when every cause belongs to another veto, `defer` when the causes are mixed, unknown or unowned.
- **Terminality.** A veto may say `no` only on a cause that is **operator-retractable** and **not produced by the loop's own writes**. A cause that retracts itself while nobody does anything makes the record false before it is read; a cause the loop itself created is not the operator's to clear. Unknown counts as self-retracting and defers. `ok`, `defer` and `merge` cannot go stale, because the gate derives and acts on the same pass — a recorded `no` is the only gate output that can rot. This is one of the two sites of the rule **the loop does not act on its own output**; the other is autofix's refusal to spend at a head the loop minted.

All four vetoes evaluate — nothing short-circuits — and **a veto beats the clock**, so one handover carries every reason, the ones that passed included. That precedence costs nothing now that a `no` is only ever a cause an operator can retract: the failing check that reaches it is the most actionable veto in the gate, and holding it behind a clock would buy no information. The gate **never reads the pull request's reviews** and **never parses CodeRabbit's pre-merge checks**.

**Who owns what**, which the classification is derived from. Ownership goes to the veto that reads the fact **most directly** — the input that discriminates most about it:

| Fact | Owner |
|---|---|
| CodeRabbit's merge-risk judgement | V1 |
| the state of every check on the head | V2 |
| whether head and base tip conflict | V3 |
| whether base has moved past the merge base | V3 |
| what the change touches | V4 |
| elapsed time | the clock, which is not a veto |
| draft | the scope filter |
| the walkthrough's commit abbreviation | loop-produced — no owner |
| the repository's non-check merge rules, and the **existence** of required contexts | deliberately unowned |

**Checking a fifth veto** against those two rules, so the property survives the next person to add one. Step 4's *three rules* are the three ways a cause set classifies — `ok`, `no`, `defer` — and the *four* are what a `no` needs all of:

1. Name the fact it exists to judge, positively, as a function of inputs.
2. Claim it. If another veto owns it, resolve by directness; the loser applies rule 1 and returns `ok`.
3. For every value of every field it reads, write the **cause set** — the set of repository conditions, not the value's gloss.
4. Apply the three rules. A `no` needs all four of: cause set fully known, wholly owned, operator-retractable, not loop-produced.
5. Any cause set not establishable from a primary source is `defer`.

**A veto whose `no` arm is an `else` has not done step 3.** V3's is gone. V1's and V4's are still there, and auditing them against this procedure would be well-founded work.

**Two facts stay unestablished and ship that way on purpose:** the full cause set behind `mergeStateStatus = BLOCKED` — which is why it defers, and why it cannot be marked permanent — and whether the check rollup carries an entry for a required context that has never reported. Every classification above is deliberately robust to both.

**The cost, on the record:** a pull request whose checks are green but whose merge GitHub blocks on a required review, an unresolved conversation, a deployment, a signature or a linear-history rule now waits out `mergeGateTimeoutSeconds` before arriving as `stuck`, where it used to be handed over on the first pass. None of those causes is owned by a veto, so none of them can be told apart from a check that has not reported yet. *Silent* means only silent on GitHub — the gate's `key=value` tail is on the per-pass log line for every verdict, including `defer`, so the wait is fully diagnosable without a round-trip.

Two things bound the merge itself:

- **The merge names the commit the gate assessed** — never the head as GitHub reports it at the moment of the write. The seam sends it as an assertion GitHub compares against the head, so a push that raced the gate loses with a 409 and escalates instead of being merged unreviewed. Branch deletion needs no key and no call: the repository's delete-on-merge setting is honoured by GitHub on the merge itself.
- **At most one merge per repository per pass.** A merge changes the base under every other open pull request in that repository, invalidating mergeability, check results and the commit each verdict was scoped to — so the loop merges once and lets the next pass re-derive. The candidates it held are logged as deferred. Other repositories are unaffected, and non-merge actions stay unbounded.

### What it hands back, and how you take it

**Escalation is a handover, not a notification.** The loop acts as your own account, and GitHub never notifies you of your own actions, so no arrangement of writes can push one. A pull request the loop will not act on gets a comment carrying every reason and the raw values behind it, then the `agent-escalated` label, in that order — the record first, so a missing flag is re-added on a later pass without the record being posted twice. While that record stands the loop takes **no further action on that pull request at that commit** — no merge, no autofix trigger, no nudge.

**A handover is re-derived every pass, and the loop withdraws it when it stops being true.** There is no latch: the whole state machine runs from scratch on every pass, at no extra read, and the record standing is consumed at the end of it. If the chain derives the same kind again the record is held and nothing is written. If it derives a different kind, the record is replaced wholesale. If it derives anything else at all — a merge, a defer, a wait, an action — the record is **withdrawn**: the comment is edited to a withdrawal notice, the marker goes with it, and the `agent-escalated` label comes off. The withdrawal carries no live verdict rows; GitHub's own comment history holds what the gate saw.

Retraction spends the pass's one action, so the loop takes the record down on one pass and acts on the next. That is what keeps the record from ever standing while the loop does the thing it promised not to do. A record naming the head is also a **merge spend at that head**, so a `refused` handover holds the merge that produced it — but only while it stands: the retraction that un-latches the pull request takes that spend down with it, so a head whose refusal is permanent is retried every second pass and posts a fresh record each time. That cost is known, pinned by a test, and not yet paid off.

**The label chases the record in both directions**, so *every escalated pull request in one query* stops filling with pull requests the loop let go of hours ago. It is delivery rather than action: a pass that finds the flag disagreeing with the record fixes the flag and says nothing else.

**A record the loop did not write is one it cannot un-write.** If the marker is in someone else's comment — an operator quoting the record back, say — the loop does the label chase, says `handover=foreign` on its log line, and touches nothing. That pull request then holds at that head until you move it; the three exits below all still work. A bot rewriting a human's comment is the worse failure.

The comment's first line names the kind, because the kind is what tells you what to go and look at:

| Kind | Meaning | Where to look |
|---|---|---|
| `escalate` | a veto is present and says no | the diff, and the reasons in the comment |
| `stuck` | signals are undecided and waiting will not decide them — a review that started and never finished, or a deferring cause that is permanent | the checks, or CodeRabbit |
| `stalled` | a CodeRabbit command was triggered and CodeRabbit never reported inside its bound | CodeRabbit's installation and seats — or, on the `other-head` route, the commit its verdict is pinned to |
| `refused` | the gate said merge and GitHub said no | the rubric — *I said yes and reality disagreed* is evidence it is wrong |

A merge that fails **transiently** is neither escalated nor retried within the pass; the poll interval is the whole of the backoff.

**The three ways back in are the ones GitHub already gives you — and none of them is required, since the loop may clear the record itself:**

- **Merge it by hand.** Close-out still ticks the issue the branch names, drops the claim, and closes it if GitHub has not already: it reads merged pull requests from GitHub and cannot tell whose hand pressed the button.
- **Push a commit.** The head moves, the record stops matching it, and the loop re-derives from scratch on the next pass.
- **Convert it to draft.** Draft is the hold gesture, and the loop stops seeing the pull request at all.

There is deliberately **no override label** — an unscoped bypass token for the only gate left standing. A push is both the fix and the re-engagement.

### The bounded-exit invariant

**No derived state in the PR phase may wait without a bound.** This is carried here as a standing invariant rather than left in the tickets that produced it, because two separate defects in this project turned out to be the same defect — a state with no exit — and a table someone has to keep true is the cheapest guard against a third. **Adding a state means adding a row.**

| State | Bound | Origin |
|---|---|---|
| `reviewing` | `mergeGateTimeoutSeconds` | oldest pending signal on the head, or the head commit itself when no signal names an instant |
| `autofix-in-flight` | `autofixTimeoutSeconds` | the trigger comment |
| `nudge-in-flight` | one poll interval | the nudge comment |
| `needs-review`, `needs-autofix` | acts on the pass it is derived; **one poll interval** later when a standing handover must be retracted first | the retraction |
| `assessable` | `mergeGateTimeoutSeconds` (V5); **the pass it is derived** when a deferring reason is marked permanent; **one poll interval** later when a standing handover must be retracted first | the head commit's date, applied outside the gate — and the retraction, when one has to come down first |
| `rate-limited` | **external** | the fair-usage rolling window |

**Every bound in this table expires into a handover**, and **the one-pass cost of retraction is on every row whose action a standing record delays.** Those are the only three writes a standing record holds — the nudge, the autofix trigger and the merge — so they are the only rows that can carry the cost, and a fourth action added to the chain adds a fourth. The tail's own writes are not among them: the handover, the retraction and the label chase are what consumes the record rather than what the record withholds. A record the loop cannot rewrite is not one pass but the operator's move (`bound=operator` on the log line). The cost is written on the rows rather than in a footnote so that nobody adds a fifth handover kind without seeing the bill.

There is no `escalated` row because there is no such state, and the table is checkable one row at a time only because of that: a pull request carrying a handover is in whichever state its signals actually put it, and that row's bound is the row's own.

`rate-limited` is the one state with no clock of the loop's own, and it is recorded as **correct rather than a hole**: unlike the review pause, which resets only when a command lifts it, the rate limit self-clears as usage ages out, and the comment carrying it ships its own estimate. Bounding it with a loop-owned clock would escalate the whole queue whenever the reviewer is merely slow.

**A standing handover has no loop-owned bound either, and that is correct rather than a hole** — the same shape as `rate-limited`, recorded the same way. Its exits are the operator's three — merge it by hand, push a commit, convert it to draft — plus the loop's own **retraction**, when re-derivation stops agreeing with the record.

**`mergeGateTimeoutSeconds` is a floor with a named cost, not a tuned number, and nothing here derives one for you** — the example config carries a number so the file is runnable, not because it is right for your repositories. Its population divides in two. For transient computation — a check still running, a conflict axis GitHub has not finished calculating — it is a **floor**: the clock must outlast the slowest legitimate check run in your repository, or the loop hands you pull requests that were merely slow. For a permanent blocker no veto owns it is **pure latency**: nothing the wait buys can change the answer. One number cannot be right for both, so the number stays yours.

### No cycle turns without an external event

The second stated invariant, and it earns a register for the same reason the table above does. Un-latching restores derivation rather than writes, so the metered writes are untouched; what it makes possible is a pull request that oscillates. Every cycle the PR phase can turn is listed with the event that drives it, and **a cycle with no driver is a defect**.

| Cycle | Driver |
|---|---|
| behind base → withdrawn when mergeability goes unknown → re-escalated | a merge into the base branch |
| a failing check → withdrawn when a re-run goes pending → re-escalated on a second failure | you re-running a check |
| `needs-autofix` → autofix pushes a CodeRabbit-authored head → nudge and review → gate → `needs-autofix` at the next human head | a human push |
| escalated → withdrawn when the rate-limit marker appears → re-escalated when it ages out | CodeRabbit's fair-usage window — a rolling window over the organisation, not a reaction to any write on this pull request |
| `merge` → refused → withdrawn when the gate says `merge` again → merge → refused | **none**, and tracked as [#100](https://github.com/nywleswoey/agentloop/issues/100). Written down as a defect rather than left out — the merge spend is derived from the record and goes down with it |

**A third party's automatic reaction to a loop-authored write is not an external event.** Admitting it would make the invariant unfalsifiable, since every loop write provokes some reaction. The line is the loop's causal closure: a human *choosing* to re-run a check is outside it; a bot firing because the loop pushed is not.

**The last row is the register earning its keep.** Killing that cycle needs a head-keyed fact that survives the withdrawal, and there is none in the read today. It is recorded here, undriven, rather than quietly omitted: a register that lists only the cycles that pass is not a register.

**The rule both invariants lean on is: the loop does not act on its own output.** It has exactly two sites — terminality's ban on a `no` resting on a cause the loop's own writes produced, and autofix's ban on a spend at a head the loop minted.

### Branch protection is yours, not the loop's

Branch protection and rulesets are an **operator's option the loop never assumes and never provisions**. It merges as a repository admin, so protection is either bypassed by default or blocks the loop on the very signals it already reads; and it is per-repository administration, which is exactly the setup step this design removed. Turn it on if you want a second, independent gate — nothing here reads it, and V2 deliberately requires *every* rollup context rather than only the required ones, which is strictly stricter and holds however a given repository happens to be configured. *Out of scope* means the loop does not **provision** protection; it does not mean no repository has any.

---

## Requirements

- `bash`, `jq`, `git`, `base64`
- [`orca`](https://orca.computer) — the agent runtime, running and reachable
- [`gh-axi`](https://github.com/kunchenguid/axi) — `npm install -g gh-axi`, over a `gh` that is authenticated against github.com

gh-axi renders every answer as TOON and has no JSON output mode, so the scripts
read it through one seam: `--jq 'tojson|@base64' --full`, which is the single
shape TOON has nothing left to restructure. `gh.sh` holds that seam — `gh_json`
decodes it and everything downstream is ordinary jq over ordinary JSON — and
both scripts source it rather than carrying their own copy. Labels are written
as deltas (`issue edit --add-label/--remove-label`) rather than as a whole set,
which is what keeps the claim a single atomic call.

The loop creates its four labels — the two in the config, and the constants
`agent-escalated` and `agent-refused` — in each configured repository at startup
if they are not already there. Both flags are constants rather than config keys
so that one query finds every flagged pull request, and a different one every
refused issue, across every repository. Both are asserted at startup because an
`--add-label` naming a label that does not exist is refused: without the
assertion a handover would post its comment and then fail to flag the pull
request, and a refusal — which writes its label first — would never get past the
swap and would leave the issue ready and silent on every pass.

---

## Setup

```bash
git clone https://github.com/nywleswoey/agentloop.git
cd agentloop
cp agent-loop.config.example.json agent-loop.config.json
```

Then edit `agent-loop.config.json`:

```json
{
  "pollIntervalSeconds": 300,
  "maxWorkers": 3,
  "autofixTimeoutSeconds": 5400,
  "mergeGateTimeoutSeconds": 3600,
  "logPath": "~/.agent-loop/agent-loop.log",
  "labels": {
    "ready": "ready-for-agent",
    "claimed": "agent-in-progress"
  },
  "projects": [
    {
      "github": "your-owner/your-repo",
      "orcaRepoId": "00000000-0000-0000-0000-000000000000",
      "mergeMethod": "squash"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `pollIntervalSeconds` | Sleep between passes. |
| `maxWorkers` | Hard cap on live workers across all projects. Governs **issue dispatch only** — the PR phase spends no worker. |
| `autofixTimeoutSeconds` | How long a triggered autofix has to report before the loop calls it stalled. **Required; nothing defaults it.** An admitted guess: the only measurement behind it is a single 17m 35s run, which the research explicitly declined to derive a timeout from. |
| `mergeGateTimeoutSeconds` | **Two consumers, with different origins.** The risk gate's `defer` — a pull request whose signals are not computed yet — measured from the head commit's date; and a CodeRabbit review that started and never finished, measured from the oldest pending signal on the head. That is why this stays its own key rather than folding into the one above: collapsing them would bind three distinct waits to one number across measurements differing by orders of magnitude. **Required; nothing defaults it** — and it is **a floor, not a tuned number**: set it to outlast the slowest legitimate check run in your repositories, and read the cost of going higher in [the bounded-exit invariant](#the-bounded-exit-invariant) before you do. No number here is derived from evidence: the review consumer has a four-second and a hundred-and-five-second pending window behind it, and the gate's own use of the number has **no sample at all**. |
| `logPath` | Append-only log. Rotated at 5 MiB, one generation kept. |
| `labels.ready` | Label the loop picks issues up by. |
| `labels.claimed` | Label the loop swaps in once it claims an issue. |
| `projects[].github` | GitHub repository, as `<owner>/<name>`. |
| `projects[].orcaRepoId` | Orca repo UUID that project maps to. |
| `projects[].mergeMethod` | `merge`, `squash` or `rebase` — how the loop merges in that repository. **Required, per repository, and validated at startup** against the repository's own permission booleans, because GitHub exposes no default-merge-method field to read one from. A method the repository forbids fails at second zero rather than coming back as a refusal at the merge, where it would be indistinguishable from the gate having been wrong. |

**Every key is required and a missing one is fatal.** The numbers in the example are *suggestions* — nothing in the code defaults to them, or to anything else. Two of them are admitted guesses, and the table above says which and on what evidence; a reader meeting a real timeout deserves to know it was a guess rather than a finding.

`agent-loop.config.json` is gitignored — it holds your own project paths and repo IDs.

**Upgrading from a pre-merge-gate config?** `seenListPath` no longer exists and startup refuses a config that still names it, saying so by name. The PR phase keeps no local state: every pass re-derives from GitHub. `autofixTimeoutSeconds`, `mergeGateTimeoutSeconds` and `projects[].mergeMethod` are new and all three are required.

---

## Usage

```bash
# Run until Ctrl-C
./agent-loop.sh

# One pass, then exit
./agent-loop.sh --once

# Everything except the merge. A dry run when paired with --once: the gate still
# judges and logs the verdict it would have acted on, and every reversible write
# still happens. There is deliberately no config key for this — a persistent
# switch would be the confirmation gate this replaced coming back as a boolean,
# and a `false` left in a file is a forgettable bypass.
./agent-loop.sh --once --no-merge

# Who holds this branch, in each configured project?
# Reports and exits — takes no lock, runs no pass.
./agent-loop.sh --branch-report my-branch

# Different config file
./agent-loop.sh --config /path/to/other.json
```

### Environment overrides

For tests and troubleshooting:

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_LOOP_CONFIG` | `agent-loop.config.json` beside the script | Config path. |
| `AGENT_LOOP_LOG_MAX_BYTES` | `5242880` | Log size cap before rotation. |
| `AGENT_LOOP_RUNTIME_WAIT_SECONDS` | `60` | How long to wait for the Orca runtime. |

---

## The writeback seam

`pr-writeback.sh` is the **only** thing that writes to a pull request, and it makes **exactly one write per invocation**. That is the whole of the atomicity story: there is no sequence to be caught halfway through, so there is no half-written state to define.

It exists as a separate executable on one justification — **the merge is the single irreversible unattended write**, and a separate executable is a thing you can also run by hand.

```bash
pr-writeback.sh autofix --repo <owner/name> --pr <n> [--sha <commit>]
pr-writeback.sh review  --repo <owner/name> --pr <n>
pr-writeback.sh comment --repo <owner/name> --pr <n> --body-file <path>
pr-writeback.sh edit    --repo <owner/name> --comment <id> --body-file <path>
pr-writeback.sh label   --repo <owner/name> --pr <n> (--add <name> | --remove <name>)
pr-writeback.sh merge   --repo <owner/name> --pr <n> --sha <commit> --method <merge|squash|rebase>
```

| Verb | Writes | Notes |
|---|---|---|
| `autofix` | the CodeRabbit autofix command | `--sha` records the input head in an HTML marker, which is what spends that head. |
| `review` | the CodeRabbit review command | The nudge. Records no head — *once per head* is decided by the comment being newer than the commit. |
| `comment` | a comment, body read from a file | The escalation record. Free text travels as a **file** because `gh-axi` would reinterpret a `--body` that happened to look like JSON. |
| `edit` | one comment's body, replaced wholesale | The retraction. A **verb, not a flag on `comment`**: that one names a pull request, this one names a comment, and folding them would make two flags conditionally required on one verb. A raw `PATCH`, because no subcommand can carry a comment edit; the body is named to `gh` as `body=@<path>` rather than passed as text, since `--field` would otherwise read `1234` as a number and a leading `@` as a filename. |
| `label` | adds **or removes** one label | Reachable **alone**, which is what lets a handover self-heal in both directions: a later pass re-adds a missing label without re-posting the comment it flags, and takes one off when the record it flagged is withdrawn. Exactly one of `--add`/`--remove` — one write carries one decision. |
| `merge` | the merge, asserting a commit | The one irreversible write. |

The two command verbs are verbs rather than callers of `comment` for the opposite reason to that file: a CodeRabbit command is the seam's **own constant**, spelled once inside it, so a typo is an argument error rather than a silent no-op.

**One guard is not argument shape: `merge` requires the assessed commit,** in full and never abbreviated. It is what makes *assess, then merge that commit* structural rather than a convention the caller is trusted to keep — with no commit there is nothing to merge but whatever happens to be at the head, which is the unreviewed code the assertion exists to refuse. GitHub compares it against the head and answers a mismatch with a 409. Everything else is argument validation: whether the pull request is open, a draft, a fork head, mergeable, or in a configured repository is the loop's call, and re-deriving any of it here would be a second gate that could disagree with the first.

`edit` gets **no guard and no failure class**, unlike `merge`: an edit is reversible and GitHub keeps native comment edit history, so it stays on the plain contract. The wrong-comment hazard is answered upstream at the derivation, which is where it belongs.

**The seam reads no configuration at all.** Everything it needs arrives on argv, the label name and the merge method included.

### Three channels

| Channel | Carries |
|---|---|
| **exit code** | the failure class — and for `merge`, which of the two failures it was |
| **stdout** | the write's response, verbatim. `gh-axi` renders a refusal here too, and those `error:`/`code:` lines are exactly what the loop's escalation comment pastes. |
| **stderr** | this script's own prose — one outcome line prefixed `pr-writeback:`, and the usage text when an argument is wrong — for a human running it by hand |

| Exit | Meaning |
|---|---|
| `0` | the write landed |
| `1` | an argument error, or the write failed |
| `3` | `merge` only: GitHub refused it — a durable no |
| `4` | `merge` only: the merge failed transiently; ask again next pass |

`2` is never used, so it can never collide with `gh-axi`'s own exit codes. `--help` is the one thing that does not follow the table above: it prints the usage text to **stdout** and exits `0`, because a human running `pr-writeback.sh --help | less` is not reading an error.

For the five reversible verbs a failed write and a bad argument share exit `1` deliberately: the loop's posture to both is the same — log it, re-derive next pass — so a distinction here is one nothing would read. `merge` is the exception because it is the one place where *GitHub said no* and *the network hiccuped* decide between handing the pull request to you and saying nothing at all. **The default is transient**, which is the opposite of V1's tripwire and on purpose: the merge has already been attempted, retrying it is idempotent because an already-merged pull request answers 200, and defaulting to refused would park a good pull request on a network blip.

---

## Tests

```bash
./tests/test-agent-loop.sh
./tests/test-pr-writeback.sh
./tests/test-gh.sh
```

The first two run the real scripts against stub CLIs in `tests/bin` (`git`, `gh-axi`, `orca`, `date`) and assert on the log lines emitted and the argv handed to those stubs. No function inside either script is reached into directly.

Time is one of those stubs. `date` is a CLI, so `$STUB_NOW` freezes what "now" is for a case without the scripts gaining a single line of test-only surface — they keep calling `date` as they always have. The binding that buys: **time comes from `date(1)`, never from a shell built-in.** `printf '%(%s)T'`, `$SECONDS` and `$EPOCHSECONDS` bypass `PATH` silently, and a timeout test that quietly runs against wall time is green for the wrong reason forever. The suite pins that rule with a check over the scripts' own source. That is one of exactly **two** places it reads code rather than behaviour, and both are there because behaviour cannot reveal what they assert: a clock read that dodged the stub would look identical to one that never happened, and a **deletion** is a claim no run can make — code that is never reached and code that is not there behave the same. The second is the removal check, a set of identifiers from the deleted PR worker that must not appear in `agent-loop.sh` at all.

Everything else reads only files the suite or the project ships. The example config, for instance, is compared against the config `write_config` writes — which every passing case here starts the loop on — so the shape it is held to is one the loop is *known* to accept rather than a second written-down copy of the rules.

`test-gh.sh` is the one exception, and the only one: it sources `gh.sh` and calls `gh_error_class` directly. The classifier is a pure table over error text whose value is that every row is right, and the rows that matter most — a 405 refusing a draft merge, a 409 losing a race with a push — are ones no stub run produces as a side effect. `gh_json` and `gh_graphql` are reached here for one thing alone — that the failure text they capture survives to the caller, on each of the two channels a caller can read it from. Everything else about them is tested only through the two scripts that call them, which is what keeps them from drifting back into two copies.

---

## Layout

```
agent-loop.sh                     the daemon
pr-writeback.sh                   the only writer to a pull request, one write per run
gh.sh                             the GitHub seam, sourced by both
agent-loop.config.example.json    copy this to agent-loop.config.json
tests/
  lib.sh                          shared assertions
  test-agent-loop.sh              daemon suite
  test-pr-writeback.sh            writeback suite
  test-gh.sh                      the seam's error classifier
  bin/                            stub git, gh-axi, orca, date
  fixtures/                       canned CLI responses
    worlds/                       whole-world snapshots, one per replayed pass
```

---

## Licence

MIT — see [LICENSE](LICENSE).
