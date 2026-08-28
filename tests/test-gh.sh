#!/bin/bash
#
# test-gh.sh
#
# The classification table in gh.sh, exercised exhaustively by sourcing the
# library and calling `gh_error_class` directly.
#
# This is the second seam in the project and the only other one: everywhere
# else, a suite runs the real script against the stub CLIs in tests/bin and
# asserts on the argv it produced. `gh_error_class` cannot be reached that way.
# It is a pure table over text, its whole value is that every row is right, and
# the rows that matter most — a 405 from a draft merge, a 409 from a race — are
# ones no stub run will ever produce as a side effect. Reaching into the
# function is what makes the table checkable rather than sampled.
#
# `gh_json` and `gh_graphql` are deliberately *not* tested here. They have no
# behaviour independent of the two scripts that call them and are covered
# through both suites, which is also what keeps them from drifting back into
# two copies. The one exception is the hand-off between them and the
# classifier — that GH_ERROR carries the text the table reads — which has no
# other home and is asserted at the end.
#
# Usage:
#   ./tests/test-gh.sh

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FIXTURES="$ROOT/tests/fixtures"
PATH="$ROOT/tests/bin:$PATH"
export PATH STUB_FIXTURES="$FIXTURES"

# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"

# shellcheck source=gh.sh
source "$ROOT/gh.sh"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gh-tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# The stubs record their argv and keep their state under here. Nothing in this
# suite asserts on either, but the stub refuses to run without them.
STUB_STATE="$SCRATCH/state"
STUB_CALLS="$SCRATCH/calls.log"
export STUB_STATE STUB_CALLS
mkdir -p "$STUB_STATE"
: > "$STUB_CALLS"

# check_class <expected> <what> <text...> — the text is passed verbatim, as
# gh-axi renders it: an `error:` line, a `code:` line, or both.
check_class() {
  local expected="$1" what="$2" text="$3" got
  got="$(gh_error_class "$text")"
  if [[ "$got" == "$expected" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL [$CURRENT] $what: expected $expected, got $got"
    sed 's/^/      | /' <<< "$text"
  fi
}

# gh-axi's two-line rendering, so every case below reads as the thing the
# classifier will actually meet rather than as a fragment of it.
render() { printf 'error: "gh: %s"\ncode: %s\n' "$1" "$2"; }

# --- rule 1: a rate limit is a retry, whatever its status says -----------------

CURRENT="rule 1 — RATE_LIMITED"
echo "== $CURRENT"

check_class transient "a rate limit with no status suffix" \
  "$(render 'API rate limit exceeded' RATE_LIMITED)"
# Ahead of rule 2 deliberately: a rate limit is a 403 by status and a retry by
# meaning, so a surviving suffix must not be allowed to call it refused.
check_class transient "a rate limit still carrying its 403 suffix" \
  "$(render 'API rate limit exceeded (HTTP 403)' RATE_LIMITED)"
check_class transient "a secondary rate limit" \
  "$(render 'You have exceeded a secondary rate limit (HTTP 403)' RATE_LIMITED)"

# --- rule 2: 5xx and 429 are transient -----------------------------------------

CURRENT="rule 2 — a 5xx or 429 suffix"
echo "== $CURRENT"

check_class transient "500" "$(render 'Internal Server Error (HTTP 500)' UNKNOWN)"
check_class transient "502" "$(render 'Bad Gateway (HTTP 502)' UNKNOWN)"
check_class transient "503" "$(render 'Service Unavailable (HTTP 503)' UNKNOWN)"
check_class transient "504" "$(render 'Gateway Timeout (HTTP 504)' UNKNOWN)"
# The range boundaries, both sides. 499 is the last refused status and 500 the
# first transient one; getting this edge wrong is what parks a mergeable pull
# request on a GitHub blip.
check_class refused   "499, the status below the range" "$(render 'Client Closed Request (HTTP 499)' UNKNOWN)"
check_class transient "500, the first of the range" "$(render 'Internal Server Error (HTTP 500)' UNKNOWN)"
check_class transient "599, the last of the range" "$(render 'Network Connect Timeout (HTTP 599)' UNKNOWN)"
check_class refused   "600, above the range" "$(render 'Not a status (HTTP 600)' UNKNOWN)"
check_class transient "429, transient by name rather than by range" \
  "$(render 'Too Many Requests (HTTP 429)' UNKNOWN)"

# --- rule 2: every other status is a durable no --------------------------------

CURRENT="rule 2 — any other status suffix"
echo "== $CURRENT"

check_class refused "400" "$(render 'Bad Request (HTTP 400)' UNKNOWN)"
check_class refused "401" "$(render 'Bad credentials (HTTP 401)' AUTH_REQUIRED)"
check_class refused "403 arriving with its suffix intact" \
  "$(render 'Resource not accessible by integration (HTTP 403)' FORBIDDEN)"
check_class refused "404" "$(render 'Not Found (HTTP 404)' NOT_FOUND)"
check_class refused "405" "$(render 'Pull Request is not mergeable (HTTP 405)' UNKNOWN)"
check_class refused "409" "$(render 'Head branch was modified (HTTP 409)' UNKNOWN)"
check_class refused "410" "$(render 'Gone (HTTP 410)' UNKNOWN)"
check_class refused "422 arriving with its suffix intact" \
  "$(render 'Validation Failed (HTTP 422)' VALIDATION_ERROR)"
check_class refused "451" "$(render 'Repository access blocked (HTTP 451)' UNKNOWN)"
# Not a 4xx, and not in the acceptance list either — but rule 2 cuts on the
# range, so anything outside 5xx and 429 lands here. Pinned so a later reading
# of the rule as "4xx means refused" cannot pass silently.
check_class refused "301, a status that is neither 4xx nor 5xx" \
  "$(render 'Moved Permanently (HTTP 301)' UNKNOWN)"

# --- rule 3: the two statuses gh-axi rewrites and eats the suffix from ---------

CURRENT="rule 3 — a suffix-less FORBIDDEN or VALIDATION_ERROR"
echo "== $CURRENT"

# gh-axi's pattern table rewrites exactly these two, destroying the suffix in
# the 403 case. Without this rule they would fall to rule 4 and be retried
# forever against a token that has permanently lost its scope.
check_class refused "FORBIDDEN with no status suffix" \
  "$(render 'Resource not accessible by personal access token' FORBIDDEN)"
check_class refused "VALIDATION_ERROR with no status suffix" \
  "$(render 'Validation Failed' VALIDATION_ERROR)"

# --- rule 4: no status at all is a blip until proven otherwise -----------------

CURRENT="rule 4 — no status, and the default"
echo "== $CURRENT"

# Transport. The case the default exists for: nothing reached GitHub, so
# nothing about the pull request was decided.
check_class transient "a transport failure carrying no status" \
  "$(render 'error connecting to api.github.com' UNKNOWN)"
check_class transient "a DNS failure carrying no status" \
  "$(render 'dial tcp: lookup api.github.com: no such host' UNKNOWN)"
check_class transient "a bare UNKNOWN with no status" "$(render 'something went wrong' UNKNOWN)"
# Codes that normally arrive with a suffix. Stripped of it they are indistinguishable
# from a blip, and the rule says so rather than guessing.
check_class transient "NOT_FOUND with no status suffix" "$(render 'Not Found' NOT_FOUND)"
check_class transient "AUTH_REQUIRED with no status suffix" "$(render 'gh auth login required' AUTH_REQUIRED)"
check_class transient "REPO_NOT_FOUND with no status suffix" "$(render 'could not resolve repository' REPO_NOT_FOUND)"
check_class transient "a code gh-axi does not have today" "$(render 'something new' FUTURE_CODE)"
# Empty text is the shape a caller reaches when the failure was the seam's own —
# a torn or undecodable response, which says nothing about what GitHub decided.
# It must not be a third answer.
#
# GH_ERROR is loaded with a refusal first, on purpose: text passed explicitly is
# the question being asked, even when it is empty, and must not be answered from
# a global the caller never mentioned. Without this the case passes whenever
# GH_ERROR happens to be empty, which proves nothing.
GH_ERROR="$(render 'Not Found (HTTP 404)' NOT_FOUND)"
check_class transient "no text whatsoever, with a refusal sitting in GH_ERROR" ""
GH_ERROR=""
check_class transient "an error line with no code line" 'error: "gh: something broke"'

# --- the three renderings measured against real GitHub -------------------------

CURRENT="measured against real GitHub (T13)"
echo "== $CURRENT"

# Verbatim from a live probe of PUT /repos/{o}/{r}/pulls/{n}/merge, quoted
# exactly. These are the refusals the merge gate will actually meet, and the
# whole classifier exists so that none of them is retried forever.
check_class refused "a draft pull request" \
  "$(printf 'error: "gh: Pull Request is still a draft (HTTP 405)"\ncode: UNKNOWN\n')"
check_class refused "a pull request with merge conflicts" \
  "$(printf 'error: "gh: Pull Request has merge conflicts (HTTP 405)"\ncode: UNKNOWN\n')"
check_class refused "a merge naming a commit that is no longer head" \
  "$(printf 'error: "gh: Head branch was modified. Review and try the merge again. (HTTP 409)"\ncode: UNKNOWN\n')"

# --- $GH_ERROR is where the text comes from ------------------------------------

CURRENT="the classifier reads GH_ERROR when given no argument"
echo "== $CURRENT"

GH_ERROR="$(render 'Pull Request is still a draft (HTTP 405)' UNKNOWN)"
check "a refusal in GH_ERROR classifies refused" \
  test "$(gh_error_class)" = refused
GH_ERROR="$(render 'Bad Gateway (HTTP 502)' UNKNOWN)"
check "a 5xx in GH_ERROR classifies transient" \
  test "$(gh_error_class)" = transient

# --- gh_json fills GH_ERROR rather than discarding it --------------------------

CURRENT="gh_json captures the failure text"
echo "== $CURRENT"

# The stub 404s any repository not listed in repos.txt, exactly as the real CLI
# does — which makes it the one failure reachable here without inventing a
# second stub. The point is not the status but that the text survives the call
# at all: it used to be thrown away at `|| return 1`.
GH_ERROR="sentinel"
if gh_json /repos/nobody/nothing >/dev/null 2>&1; then
  check "a read of an unknown repository fails" false
else
  check "a read of an unknown repository fails" true
fi
CAPTURED="$GH_ERROR"
printf '%s\n' "$CAPTURED" > "$SCRATCH/gh-error.txt"
check_grep 'error: "gh: Not Found (HTTP 404)"' "$SCRATCH/gh-error.txt"
check_grep 'code: NOT_FOUND' "$SCRATCH/gh-error.txt"
check "the captured text classifies refused" test "$(gh_error_class)" = refused

# A success must not leave the previous failure readable: a caller that
# classified a stale error would report a refusal that never happened.
GH_ERROR="sentinel"
gh_json /user >/dev/null 2>&1
check "GH_ERROR is cleared by a successful call" test -z "$GH_ERROR"

CURRENT="the failure text survives a command substitution"
echo "== $CURRENT"

# The shape every real call site uses. `out=$(gh_json ...)` runs the function in
# a subshell, so the assignment to GH_ERROR dies there and the parent keeps
# whatever it last saw — which is how a merge would come to classify a refusal
# that never happened. The text goes out on stdout for exactly this reason, and
# these are the assertions that would have caught its absence: the two above
# pass whether or not the substituted shape works.
GH_ERROR="sentinel"
SUBSHELL_OUT="$(gh_json /repos/nobody/nothing 2>/dev/null)" || true
printf '%s\n' "$SUBSHELL_OUT" > "$SCRATCH/subshell-out.txt"
check_grep 'error: "gh: Not Found (HTTP 404)"' "$SCRATCH/subshell-out.txt"
check_grep 'code: NOT_FOUND' "$SCRATCH/subshell-out.txt"
check "the substituted text classifies refused" \
  test "$(gh_error_class "$SUBSHELL_OUT")" = refused
# Named rather than discovered: the global did not survive, and no assertion
# above this one would have noticed.
check "GH_ERROR did not survive the subshell" test "$GH_ERROR" = sentinel

# A success puts the body there and nothing else, so a caller cannot mistake one
# for the other by reading the same channel.
SUBSHELL_OUT="$(gh_json /user 2>/dev/null)"
printf '%s\n' "$SUBSHELL_OUT" > "$SCRATCH/subshell-ok.txt"
check_grep '{"login":"nywleswoey"}' "$SCRATCH/subshell-ok.txt"
check_no_grep 'error:' "$SCRATCH/subshell-ok.txt"

report
