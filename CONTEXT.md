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
