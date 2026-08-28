#!/bin/bash
#
# gh.sh
#
# The GitHub seam. Sourced, never run.
#
# One definition of every call this project makes against GitHub through the
# API, plus the rule that decides whether a failed one is worth trying again. It
# lived twice before — once in `agent-loop.sh` and once in `pr-writeback.sh` —
# and the copies drifted: the writeback copy posted to the wrong GraphQL path,
# so its two mutations arrived with null variables and never once succeeded
# against real GitHub. One copy was fixed long after the other was written and
# the stub suite could not see the difference. Hence one definition.
#
# `agent-loop.sh` is the only caller today. `pr-writeback.sh` had one when it
# spoke GraphQL; those mutations are deleted, and it now reaches GitHub through
# gh-axi's own subcommands, which need nothing from here.
#
# Deliberately absent: `die`, `log`, `say`. Their prefixes and log-file
# behaviour differ per script, and nothing here may call them — every function
# returns non-zero and leaves the posture to the caller. That is what keeps
# this a seam rather than a junk drawer.
#
# Requires: jq, gh-axi (authenticated against github.com)

# gh-axi's `error:` and `code:` lines from the last failed `gh_json`, verbatim.
# Cleared at the top of every call, so a stale error can never be read back
# after a success.
#
# **Only in a caller that does not substitute.** `out=$(gh_json ...)` runs the
# function in a subshell, where both the assignment and the clear die with it —
# the parent keeps whatever it last saw, indefinitely, and a merge classifying
# that would report a refusal that never happened. So the failure text goes out
# on stdout as well, which is the channel that survives the substitution, and a
# caller reads whichever one its call shape gives it:
#
#   gh_json PUT ... ; then read $GH_ERROR        # no subshell, global is live
#   out=$(gh_json PUT ...) ; then read $out      # subshell, text is in $out
#
# Both carry the same bytes. Neither costs the other anything: on success there
# is no failure text to confuse with the body, and on failure there is no body.
#
# gh-axi puts a refusal on *stdout* as TOON, not on stderr, so this is the
# captured response — the thing `gh_json` used to throw away at `|| return 1`.
#
# It stays empty when the failure is the seam's own rather than GitHub's — a
# truncated or undecodable response, a page that would not base64 back. There is
# no `error:` line to carry in those cases, and inventing one would be a lie
# about what GitHub said. Empty text classifies transient, which is the right
# posture: a torn response tells the caller nothing about the pull request, so
# the only honest answer is to ask again.
GH_ERROR=""

# gh-axi renders every answer as TOON and has no JSON output mode, so a script
# cannot read what it prints the way it would read `gh`'s. What it will do is
# run a jq expression against the response before rendering it, and
# `tojson | @base64` is the one shape TOON has nothing left to restructure: a
# single opaque token. Decoding it hands the response back byte for byte, so
# every read is an ordinary jq over ordinary JSON again.
#
# When --paginate is used, gh-axi produces multiple TOON documents, one per
# page. Each must be decoded separately and then combined into a single JSON
# array before the caller consumes it.
#
# `--full` is not optional: gh-axi truncates a long response by default, and a
# truncated base64 token decodes to a torn JSON document. A single repository
# read is already past the cap, so without this every project fails to resolve.
gh_json() {
  local response bodies page_count decoded_pages decoded ok=true
  GH_ERROR=""
  response=$(gh-axi api "$@" --full --jq 'tojson|@base64' 2>/dev/null) || ok=false
  # A refusal is TOON as well and carries no body at all, so the shape of the
  # answer is checked rather than the exit status trusted on its own.
  [[ "$response" == error:* ]] && ok=false
  if ! $ok; then
    GH_ERROR="$response"
    if [[ -n "$response" ]]; then printf '%s\n' "$response"; fi
    return 1
  fi
  [[ "$response" == *"truncated: true"* ]] && return 1

  # Extract all body fields (one per page if --paginate was used).
  bodies=$(sed -n 's/^  body: //p' <<< "$response")
  [[ -n "$bodies" ]] || return 1

  # Decode each page, one base64 body per line.
  decoded_pages=""
  while IFS= read -r page_body; do
    [[ -n "$page_body" ]] || continue
    decoded=$(base64 -d <<< "$page_body" 2>/dev/null) || return 1
    decoded_pages+="$decoded"$'\n'
  done <<< "$bodies"

  # Count how many pages we got (number of non-empty lines). `grep -c` exits 1
  # on no match, so the failure is caught by assignment rather than by `|| echo
  # 0`, which would append a second line and leave a value no arithmetic
  # comparison can read.
  page_count=$(grep -c . <<< "$decoded_pages") || page_count=0

  # Single page: return as-is (most common case, no jq needed).
  if [[ "$page_count" -eq 1 ]]; then
    printf '%s' "${decoded_pages%$'\n'}"
    return 0
  fi

  # Multiple pages: combine into a single JSON array.
  [[ "$page_count" -gt 0 ]] || return 1
  printf '%s' "$decoded_pages" | jq -s 'add'
}

# One GraphQL document, with any variables it declares as trailing `--field`
# arguments. GitHub answers a bad query with a 200 and an `errors` block, which
# would otherwise reach the caller looking like a response, so it is turned back
# into a failure here — once, rather than at every call site.
#
# The path is `graphql`, not `/graphql`. gh hoists `--field` arguments into
# GraphQL variables only when the path matches that literal; spelled with the
# leading slash they are posted as ordinary body keys instead, every declared
# variable arrives null, and GitHub refuses the document. The callers that pass
# no variables never noticed, which is exactly how the writeback copy stayed
# broken.
#
# Variables are read from "$@" rather than from fixed positional parameters:
# the copy this one is taken from read `$3` unconditionally, and under `set -u`
# that aborted the run before the mutation was sent whenever a two-argument
# caller reached it.
gh_graphql() {
  local query="$1" response
  shift
  # Cleared here as well as in gh_json, and not only for tidiness: the call
  # below is a substitution, so gh_json's clear happens in a subshell and dies
  # there. Without this line a caller that read a real refusal from an earlier
  # direct call would still be holding it after this one succeeded — which is
  # the stale-error case the header rules out.
  GH_ERROR=""
  # Same subshell, the other direction: gh_json's capture dies there too, so the
  # only copy of the failure text is the one sitting in $response. Forwarded on
  # both channels, or a caller classifying a GraphQL failure would read empty
  # text, get the rule-4 default, and retry a refusal on every pass.
  if ! response=$(gh_json POST graphql --field query="$query" "$@"); then
    GH_ERROR="$response"
    if [[ -n "$response" ]]; then printf '%s\n' "$response"; fi
    return 1
  fi
  # A 200 carrying an `errors` block is a different failure: GitHub refused the
  # document and gh-axi succeeded, so there are no `error:`/`code:` lines to
  # forward and inventing some would put a status in GH_ERROR that nothing
  # returned. It stays empty, which classifies transient — correct here, since
  # a document GitHub would not run says nothing about what it decided.
  jq -e 'has("errors") | not' <<< "$response" >/dev/null 2>&1 || return 1
  printf '%s' "$response"
}

# Which failures are worth trying again. Prints `transient` or `refused` and
# nothing else; reads $GH_ERROR when given no argument.
#
# gh-axi's `code:` field is not a taxonomy — "Branch not protected (HTTP 404)",
# a permanent refusal, and "error connecting to host", a transport blip, both
# arrive as `code: UNKNOWN` with exit 1. What is recoverable is the `(HTTP nnn)`
# suffix, which is gh's own format passed through untouched for everything
# gh-axi's pattern table does not match. Exactly two statuses are rewritten and
# lose their suffix — 403 to FORBIDDEN and 422 to VALIDATION_ERROR — and both
# are ones where the code alone is enough.
#
# The rules, in order:
#
#   1. code RATE_LIMITED                            -> transient
#   2. an (HTTP nnn) suffix: 5xx or 429              -> transient
#                            any other status        -> refused
#   3. no suffix, code FORBIDDEN or VALIDATION_ERROR -> refused
#   4. anything else                                 -> transient
#
# Rule 1 sits ahead of rule 2 because a rate limit is a 403 by status and a
# retry by meaning.
#
# The cut is on the status *range*, not on the presence of a status. "GitHub
# answered, therefore it refused" is wrong for 5xx: a 502 would park a
# perfectly mergeable pull request until a human noticed.
#
# The default is transient, deliberately, and it points the opposite way to the
# loop's other tripwires. By the time this is consulted the write has already
# been attempted; the only question left is whether to attempt it again next
# pass. Retrying a merge is idempotent — an already-merged pull request answers
# 200 — while defaulting to refused parks a good pull request on a network blip
# and needs a human gesture to get it back.
gh_error_class() {
  # `${1-...}`, not `${1:-...}`: a caller that deliberately passes empty text is
  # asking about *that*, and must not be silently answered from a global it did
  # not mention. Only an absent argument falls back to $GH_ERROR.
  local text="${1-${GH_ERROR:-}}" code="" http_status=""

  [[ "$text" =~ code:[[:space:]]*([A-Za-z_]+) ]] && code="${BASH_REMATCH[1]}"
  [[ "$text" =~ \(HTTP[[:space:]]+([0-9]+)\) ]] && http_status="${BASH_REMATCH[1]}"

  if [[ "$code" == "RATE_LIMITED" ]]; then
    printf 'transient\n'
  elif [[ -n "$http_status" ]]; then
    if (( http_status >= 500 && http_status <= 599 )) || (( http_status == 429 )); then
      printf 'transient\n'
    else
      printf 'refused\n'
    fi
  elif [[ "$code" == "FORBIDDEN" || "$code" == "VALIDATION_ERROR" ]]; then
    printf 'refused\n'
  else
    printf 'transient\n'
  fi
}
