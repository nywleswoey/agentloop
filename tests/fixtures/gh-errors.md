The renderings the stub gh-axi injects, one per file, named
gh-error-<status>[-<reason>].txt and selected by $STUB_GH_ERROR.

Each is gh-axi's real two-line answer to a failed call: the verbatim first
stderr line from `gh`, quoted into an `error:` field, and the `code:` its
pattern table mapped that line to. They are files rather than strings in the
stub because three of them are *measured* — recorded against real GitHub in
T13 (issue #17) — and a measurement is worth keeping where it can be read and
compared byte for byte:

  gh-error-405-draft.txt      PUT .../merge on a draft pull request
  gh-error-405-conflict.txt   PUT .../merge on one with merge conflicts
  gh-error-409-race.txt       PUT .../merge naming a commit that is not the head

All three keep the `(HTTP nnn)` suffix and arrive as `code: UNKNOWN`, because
gh-axi's `mapGhError` table keys on repo/auth/rate-limit prose and on exactly
two statuses, 403 and 422 — no pattern in it can match anything the merge
endpoint says. That suffix is the only thing gh.sh's classifier can cut on, and
these three are why it cuts there. tests/test-gh.sh asserts each one classifies
`refused`.

The other two are unmeasured but of the same shape, and are only ever used
where the class rather than the prose is the point:

  gh-error-404.txt            the default for a refused comment or label write
  gh-error-500.txt            the default everywhere else, and the one
                              transient rendering
