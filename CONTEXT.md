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
