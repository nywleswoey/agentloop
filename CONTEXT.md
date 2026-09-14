# agent-loop

An unattended loop that dispatches coding agents at GitHub issues and drives the resulting pull requests through CodeRabbit review to a merge or a handover.

## Language

### The review chain

**Nudge**:
The loop's own `@coderabbitai review` command on a pull request, asking CodeRabbit to review the current head.
_Avoid_: ping, trigger (a trigger is the autofix command)

**Answer**:
Any CodeRabbit output — a status or a comment — newer than the nudge it follows. Whether an answer exists is read from its presence; what it means is read from the status alone.

**Refusal**:
An answer whose status says no review ran.

**Silence**:
No answer of any kind after a nudge. Silence carries no meaning of its own; it inherits whatever answer stands in its refusal run.
_Avoid_: silent refusal

**Refusal run**:
The span of nudges at one head, from the first, during which the standing answer is a refusal. Silence after a refusal belongs to the run: the refusal still stands.
_Avoid_: retry loop, rate-limited state

**Stall**:
A nudge past its bound with no refusal standing — either silence with nothing before it at this head, or an answer that neither refused nor produced a review.
_Avoid_: timeout

### The sweep and the reclaim

**Worker**:
An agent the loop dispatched into a worktree, for as long as it is working or waiting there — or, once it is neither, for as long as its worktree holds uncommitted changes, up to the worker bound. A claim is never handed back while a worker holds it.
_Avoid_: live agent (a worker between states is not live, and is still a worker)

### Issues and their pull requests

**Delivered**:
An issue whose work a pull request carries, for as long as that pull request is open or merged. A pull request closed without merging undoes it: the issue is undelivered again, and goes back to the loop.
_Avoid_: done, handled

**Landed**:
A delivered issue whose pull request has merged. Unlike delivery, landing is never undone.
_Avoid_: delivered (when a merge is meant)

### Failures

**Transient**:
A failed read or write that says nothing durable about its object — a 5xx, a rate limit, a torn response, any git or Orca failure. Skipped, and asked again next pass. One Orca read is not: an unreadable worker inventory is part of readiness, not a transient.

**Ready** (of the runtime):
Orca is reachable **and** its worker inventory (`orca worktree ps`) reads. A runtime that is not ready is re-read with a one-second sleep between reads, for `RUNTIME_WAIT_SECONDS` sleeps, then the loop dies; only an unreachable one is started with `orca open`.
_Avoid_: ready (unqualified, which is the `ready-for-agent` label)

**Refused**:
A failed read or write GitHub answered with a durable no, as `gh_error_class` classifies it. A refused read ends the loop; a refused write flags its object.
_Avoid_: refusal (that is CodeRabbit's answer to a nudge), and *refused issue* (that is the issue gate's `agent-refused`, counted in `refusals=`)
