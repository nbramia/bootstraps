---
name: pr-check
description: >-
  Validate a PR against PR standards before requesting review.
  Checks branch naming, title, description, commits, references, and scope.
  Triggers: /pr-check, check this PR, validate PR
license: MIT
metadata:
  version: "2.0.0"
  tags: ["pr", "check", "standards", "validation"]
  author: benjamcalvin
---

# PR Standards Check

<!-- lifecycle-suite-capability: focused-only -->

**Suite capability: `focused-only`. Run focused tests, lint, builds, and acceptance commands only. Do not execute or consume the target repository's authoritative verification command or ordered command plan. Final verification owns that evidence.**

Pre-flight validation for PRs.

```text
$ARGUMENTS
```

If the current client leaves `$ARGUMENTS` literal, use the user's invoking prompt. If no PR number is supplied, inspect the PR associated with the current branch when available.

## Context

At runtime, inspect the current branch and fetch available PR metadata and comments. Determine the actual base branch before inspecting commits and diff size. Read explicit user direction and the target repository's governing instructions and contribution documentation before applying standards.

If present, also read the target repository's
`docs/specs/standards/development-lifecycle.md` and apply its current evidence,
review-risk, convergence, privacy, and PR-sizing policy. This contract is
repository-owned; the bundled checks are fallbacks only where repository policy
is silent.

If that repository documents a shared development-metrics recorder (e.g.
`scripts/development_metrics.py`), capture a real start timestamp through its
own mechanism (e.g. its `now` subcommand) at the beginning of this phase, then
at the end record it through the same recorder (e.g. its `record` subcommand)
passing that captured start value (e.g. `--started-monotonic`) rather than a
hand-computed or estimated duration — the recorder itself measures real
elapsed monotonic time between the two calls; never invent, guess, or
shell-arithmetic an elapsed duration yourself. Use opaque candidate/task ids,
phase `pr-check`, phase-kind `execution`, the actual result and exit status
(preserved exactly, never inferred from a friendly label), and any run id
passed to this invocation, so this phase's record joins the same run as every
other delegated phase. Best-effort only: never let a missing recorder or a
failed metrics call change this phase's real result, and never invent a
second timing or telemetry format. If a real phase-start timestamp was not
captured, make at most one final recorder call without a duration flag so its
`elapsed_seconds: null` truthfully preserves unknown timing. Never truncate,
replace, overwrite, or append a duplicate receipt for the same phase attempt
just to supply a duration later; retain the incomplete record and report the
recorder problem separately. When a standards-only decision has no
authoritative subprocess status, omit `--exit-status` so the record preserves
`exit_status: null`; never manufacture zero or a failure status from a
PASS/FAIL label alone.

## Instructions

Validate the current PR against target-repository policy first. Explicit user direction and repository instructions take precedence over the bundled checks below for branch names, commits, PR formatting, required references, and blocking/advisory status. Use a bundled check only as a fallback where target policy is silent, and identify that fallback in the result. If no PR exists, check only what can be validated locally and note that no PR exists yet.

For each check, output one of:
- **PASS** — Meets the standard
- **WARN** — Minor deviation, note what's off
- **FAIL** — Does not meet the standard, explain what needs to change

### Checks

This check validates a title, a summary, and repository-required references. It does not audit the description's prose beyond that — no required evidence section, no verification matrix, no risk table, and no style grading of sentences below the summary.

**1. Branch Naming (bundled fallback)**
Branch must match `<type>/<short-description>` where type is one of: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`. Must be lowercase, hyphen-separated.

**2. PR Title (bundled fallback)**
Must match `<type>: <imperative summary>`. Type prefix should match branch type. Under 72 characters. No period at the end. Imperative mood ("Add", "Fix"), not past tense ("Added", "Fixed").

**3. PR Description — Summary (bundled fallback)**
Must open with a short plain-language summary of what the change does and why (a `## TL;DR` or `## Summary` section). FAIL only if the description has no such opening summary at all.

**4. Commit Messages (bundled fallback)**
Each commit message should follow `<type>: <summary>` format. No "WIP", "fixup", or "wip" commits.

**5. References (bundled fallback)**
If the change relates to a GitHub issue, it should reference it with an appropriate keyword:
- `Closes #N` / `Fixes #N` — only when this single PR fully completes the issue
- `Part of #N` — when the PR is one of several addressing the issue

WARN if no references found (not all PRs need them, but flag for awareness). WARN if `Closes #N` is used but the PR appears to be a sub-task of a larger issue (e.g., the issue has multiple acceptance criteria and the PR only addresses some).

### Scope Note (advisory — not scored)

Assess whether the PR is **one logical change a reviewer can hold in their head in one sitting**, or a small batch of same-kind housekeeping changes. This is a judgment about cohesion, not size: a single ADR, a new module's scaffold, and a mechanical rename are each one logical change however many lines they span, while a small PR that fixes a bug *and* refactors an unrelated module is two.

Report a one-line observation. Say the PR is cohesive, or name the seam it should be split along. Do not assign PASS/WARN/FAIL, do not count lines against a threshold, and do not treat this note as a merge blocker — it exists to inform the author and reviewers, not to gate.

**Size-to-cap advisory (early split signal).** If the PR is over-scoped — far larger than the change it claims to be, or spanning multiple unrelated changes a reviewer cannot hold in one sitting — flag it and recommend splitting the out-of-scope work into child issues BEFORE implementation proceeds. This is a qualitative scope judgment, not a line-count threshold (see the scope note above). A PR that balloons past reviewable size mid-lifecycle forces scope-splitting refine passes and extra review rounds — far cheaper to split up front. This is advisory, not a blocker.

### Output Format

```
## PR Standards Check

| # | Check | Result | Notes |
|---|-------|--------|-------|
| 1 | Branch naming | PASS/WARN/FAIL | ... |
| 2 | PR title | PASS/WARN/FAIL | ... |
| 3 | Summary | PASS/WARN/FAIL | ... |
| 4 | Commit messages | PASS/WARN/FAIL | ... |
| 5 | References | PASS/WARN/FAIL | ... |

**Result: X/5 passing, Y warnings, Z failures**

**Scope (advisory):** <one line — cohesive, or the seam it should be split along>
```

If there are failures, add a brief "Suggested Fixes" section listing what to change.
