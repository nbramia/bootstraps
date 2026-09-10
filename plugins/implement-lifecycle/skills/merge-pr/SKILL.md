---
name: merge-pr
description: >-
  Lifecycle-internal merge step requiring a PR number and the temporary handoff
  artifact produced by verification; validates readiness, follows repository
  merge policy, and posts issue updates.
argument-hint: <pr-number> <handoff-artifact-path>
license: MIT
metadata:
  version: "1.0.0"
  tags: ["merge", "pr", "issues"]
  author: benjamcalvin
---

# Merge PR and Update Issues

<!-- lifecycle-suite-capability: focused-only -->

**Suite capability: `focused-only`. Run focused tests, lint, builds, and acceptance commands only. Do not execute or consume the target repository's authoritative verification command or ordered command plan. Final verification owns that evidence.**

This is a lifecycle-internal merge step. Invoke it with the PR number and the temporary handoff artifact produced by lifecycle verification. For a repository without a repository-declared merge-publication adapter (see Step 2), it fails closed when that artifact is absent or invalid; for one that has adopted such an adapter, verification is intrinsic to that adapter's own invocation in Step 2 — it constructs and verifies a candidate commit distinct from the PR head, which does not exist before that invocation — so readiness cannot require, and does not require, a pre-existing check as a condition of the handoff (see Step 1 item 6).

```text
/merge-pr <pr-number> <handoff-artifact-path>
$implement-lifecycle:merge-pr <pr-number> <handoff-artifact-path>
```

Treat the active invocation's arguments as `<pr-number> <handoff-artifact-path>`. If the current client exposes `$ARGUMENTS`, parse the same two values from it; otherwise use the user's invoking prompt.

## PR Context

At runtime, parse the PR number, fetch the PR metadata, comments, and checks, and determine whether the target repository has adopted a repository-declared merge-publication adapter (Step 2) — this changes what verification evidence Step 1 item 6 requires below. When it has NOT, also read the explicitly passed temporary handoff-artifact path; if that path is absent, unreadable, or does not contain a complete `verification-record:v1` plus its referenced `suite-evidence`, stop rather than reconstructing evidence from an inaccessible parent transcript. When it HAS adopted such an adapter, a supplied handoff artifact is supplementary local evidence only, never a separate blocking gate — its absence does not itself stop the merge.

Before readiness evaluation, read the target repository's
`docs/specs/standards/development-lifecycle.md` when present, together with
`AGENTS.md`, `CLAUDE.md`, and applicable standards. Apply repository-owned
review, evidence-reuse, convergence, privacy, and restart policy; this plugin
must not infer those policies from its own source repository.

If that repository documents a shared development-metrics recorder (e.g.
`scripts/development_metrics.py`), capture a real start timestamp through its
own mechanism (e.g. its `now` subcommand) at the beginning of this phase, then
once merge concludes (or is refused) record it through the same recorder
(e.g. its `record` subcommand) passing that captured start value (e.g.
`--started-monotonic`) rather than a hand-computed or estimated duration —
the recorder itself measures real elapsed monotonic time between the two
calls; never invent, guess, or shell-arithmetic an elapsed duration yourself.
Use opaque candidate/task ids, phase `merge`, phase-kind `execution`, the
actual result and exit status of the merge/publication attempt (never
`success` for a refused or failed merge), and any run id passed to this
invocation, so this phase's record joins the same run as every other
delegated phase. Best-effort only: never let a missing recorder or a failed
metrics call change the real merge outcome, and never invent a second timing
or telemetry format. If a real phase-start timestamp was not captured, make
at most one final recorder call without a duration flag so its
`elapsed_seconds: null` truthfully preserves unknown timing. Never truncate,
replace, overwrite, or append a duplicate receipt for the same phase attempt
just to supply a duration later; retain the incomplete record and report the
recorder problem separately. When a standards-only readiness refusal has no
authoritative subprocess status, omit `--exit-status` so the record preserves
`exit_status: null`; never manufacture zero or a failure status from a
PASS/FAIL label alone.

## Instructions

### Step 1: Validate Readiness

Before evaluating readiness, read explicit user direction and the target repository's governing instructions, branch-protection/ruleset configuration when accessible, and documented contribution policy. Enforced repository constraints are binding. Explicit user direction may select only among choices those constraints permit; it cannot waive or contradict them. If repository policy and user direction cannot be reconciled, stop the merge and report the conflict. Apply this precedence consistently to required checks, approvals, billing exceptions, merge method, and branch retention. Bundled fallbacks apply only when both sources are silent. Do not infer policy from this plugin's source repository.

Check that the PR is safe to merge. For each check, determine pass/fail:

1. **State** — PR must be `OPEN`. If already merged or closed, report and stop.
2. **Merge conflicts** — `mergeable` must not be `CONFLICTING`. If conflicts exist, report and stop.
3. **CI status** — Enforce the checks required by binding target-repository policy; user direction may request additional checks but may not waive required ones. Report every blocking failure and stop. A billing or account-status failure remains blocking unless repository policy permits that exception, or policy is silent and explicit user direction permits it; an exception is never global. Even when permitted, classify the failure as billing-only only when the run or job carries an explicit billing/payment signal. Never infer billing from timing, and record every applied exception.
4. **PR standards** — Before invoking a fresh check, look for a `pr-check` result already recorded for this exact PR (e.g. a prior `pr-check` PR comment, or a result the orchestrator already captured earlier in this same lifecycle). Reuse it when it matches the current `headRefOid` exactly and nothing relevant has changed since (no new commits, no changed title/description/branch) — a reused result is not a new attempt and does not justify invoking `pr-check` again. Otherwise, invoke the canonical `pr-check` skill with a fresh isolated context using the active harness adapter:
   - **Claude Code:** use the Task/subagent facility, explicitly load the canonical `pr-check` skill, and provide the PR plus freshly read repository-policy context.
   - **Codex:** spawn a fresh subagent, instruct it to load the canonical `pr-check` skill, and provide the PR plus freshly read repository-policy context.
   - **Pi:** use `pi-subagents` with `context: "fresh"`, explicitly select the canonical `pr-check` skill, and provide the PR plus freshly read repository-policy context.
   - **Generic:** use the client's isolated delegation mechanism with a fresh context and explicit canonical `pr-check` skill selection; do not emulate a subagent inline.

   Capture and evaluate the reused or freshly returned `pr-check` result. If isolated dispatch, fresh context, explicit skill loading, or result capture is unavailable, fail closed and report the readiness step instead of running an improvised substitute. Apply the target repository's blocking standards. Bundled checks are fallbacks only when repository policy is silent. The bundled scope note remains advisory unless target policy makes scope a gate.
5. **Review decision** — Check `reviewDecision` and the approval rule established from repository policy and explicit user direction:
   - If `CHANGES_REQUESTED`, stop and report.
   - If repository policy requires approvals, require the declared number and kind; user direction may require additional approvals but may not reduce or waive the repository minimum. Otherwise stop and report the missing approval.
   - If the established policy does not require approval, do not invent a requirement from the base branch name. Proceed autonomously when the other gates pass.
6. **Exact-head verification evidence** — When the target repository has adopted a repository-declared merge-publication adapter (Step 2), that adapter constructs its own normalized candidate commit from the current base and the PR head only when it is actually invoked, and dispatches isolated trusted verification against that exact constructed candidate — a commit that is distinct from the PR head and does not exist before that invocation. Readiness therefore cannot require, and must never claim, a pre-existing check for that candidate: there is nothing to check yet, no matter how long the PR has been open. Never treat any check already posted against the PR's own head SHA as proof the not-yet-built candidate would pass — the adapter's required check is filed against the candidate's own SHA, never the PR head, so a check on the head proves nothing about the candidate, and a repository whose branch protection requires that check on `main` is validating whatever exact SHA is being pushed there (the candidate, once the adapter constructs and pushes it), not the PR. Store the current `headRefOid` here only as the value this item hands to the adapter as its expected-head precondition in Step 2 — never as verification evidence. A repository-declared check that genuinely runs against the PR head directly (e.g. lint or typecheck triggered by `pull_request`, independent of the adapter's own candidate-level check) is enforced separately, unchanged, by item 3 above; never conflate that with, or substitute it for, the adapter's own candidate verification. When the repository has NOT adopted such an adapter, read the explicitly handed-off temporary JSON object and require its canonical `verification-record:v1` fields to match the complete record in the latest verification PR comment semantically, not by comparing raw serialized text. In both `not-required` and `missing-contract` records, PR-comment `suite-command: none` corresponds to handoff JSON `"suite-command": null`, and PR-comment `suite-exit-status: n/a` corresponds to handoff JSON `"suite-exit-status": null`; these pairs match semantically. Compare other scalar fields by their typed values and structured fields as JSON, preserving array order. Require `verification-record: v1`, `verification-head`, `suite-result`, `suite-command`, `suite-executions`, `suite-exit-status`, `suite-command-results`, and `retry-reason`. `retry-reason` is provenance only, never a separate readiness gate: a populated reason on an otherwise-passing record reflects a legitimate reason-recorded same-candidate infrastructure retry (see `verify`) and must not be rejected merely for being present; reject only when the record otherwise fails the criteria below. Independently establish the target repository's authoritative command or ordered command plan from the same target sources used by verification. Fetch the current `headRefOid` and require it to equal `verification-head`. Accept `pass` only when `suite-command` exactly matches that established command or ordered JSON command array, with the same command boundaries and order, exactly one plan execution, original overall exit status 0, and ordered per-command results whose exact commands match every command in the plan and whose results/statuses are `pass`/zero. For every result, require its `#/suite-evidence/command-<N>` pointer to resolve inside the handed-off object's `suite-evidence`; require the resolved entry's exact command to match and its output to be a nonempty string. Reject pointers outside the handed-off object, dangling or mismatched entries, different commands, reordered plans, missing command results, wrappers, arguments, prefixes, suffixes, stale or mismatched handoff/comment records, `missing-contract`, or evidence when no target contract can be established. Accept `not-required` only after independently inspecting the changed files and confirming that every change is documentation or comments only, with handoff JSON `"suite-command": null`, zero executions, handoff JSON `"suite-exit-status": null`, an empty results list, and empty `suite-evidence` (corresponding to comment sentinels `none` and `n/a`). Reject every other combination. Store the matching head as `VERIFIED_SHA`. Do not execute the authoritative command or plan during merge readiness checks; validation reads verification's handed-off record and output only.

**If validation fails**, stop and report exactly what needs to be fixed. Do not merge.

**If validation requires human judgment** (e.g., a check is flaky, unresolved conversations), stop and consult the user with the evidence.

### Step 2: Merge

When the target repository provides its own canonical merge-publication adapter (e.g. a `candidate_publisher`-style script implementing atomic two-parent-candidate construction, isolated trusted verification, and lease-gated publication), invoke that adapter instead of `gh pr merge`. Do not use `gh pr merge` — including `--match-head-commit` — against a repository that has adopted this adapter: a plain merge commit and a same-repo compare-and-swap are not equivalent to the adapter's construct-then-verify-then-publish sequencing, and running both risks a double-merge race. Discover the adapter from repository-owned documentation (e.g. `docs/guides/candidate-verification-ci.md`) rather than assuming a path or invocation shape; this plugin does not hardcode a specific target repository's script location.

Pass the adapter `$VERIFIED_SHA` (the `headRefOid` observed in Step 1, item 6) as its expected-head precondition (e.g. `--expected-head-sha`), so it refuses to publish if the PR head advanced past that observation, rather than silently building and publishing a fresher, unverified commit. Select the merge method, branch-retention, and required-check identity the adapter exposes according to the same precedence as above: repository-required or repository-prohibited settings are binding; user direction selects only among what repository policy permits.

```
<repository-declared publisher adapter> --pr <pr-number> --expected-head-sha "$VERIFIED_SHA" \
    <adapter's own merge-method / branch-retention / required-check flags per repository docs>
```

The adapter's own outcome — not anything computed in Step 1 — is the sole source of truth for whether this candidate verified and merged. It constructs the candidate, dispatches its verification, and only then publishes; report exactly which of its own distinct refusal reasons applies when it does not succeed (a stale head that moved past `$VERIFIED_SHA`, a candidate that does not merge cleanly, a candidate's required check that failed, went missing, or reported from an untrusted issuer, or another open PR sharing the same source branch) and stop — never reinterpret one refusal as another, never fall back to a different merge path, and never report success because a check happened to exist against the PR head rather than the candidate the adapter actually verified.

If the target repository has not adopted such an adapter, fall back to the prior mechanism: select the merge method and branch behavior established before readiness, using the corresponding supported GitHub CLI method flag (`--merge`, `--squash`, or `--rebase`), adding `--delete-branch` only when the resolved policy calls for deletion (omit it when the branch must be retained), and gate the merge itself on `--match-head-commit "$VERIFIED_SHA"` so a PR head that changed after readiness validation fails the merge rather than merging an unverified commit:

```
gh pr merge <pr-number> <merge-method-flag> <optional-delete-branch-flag> --match-head-commit "$VERIFIED_SHA"
```

If the merge (via either path) fails, report the error and stop.

### Adapter contract scenarios

For a repository with a merge-publication adapter, these are the cases
readiness and merge must each get right — not just conceptually, but as
directly observable behavior of the actual adapter:

| Scenario | What happens | What this skill must do |
|---|---|---|
| Absent preconstruction check | The candidate does not exist until Step 2 invokes the adapter, so no check for it can exist at readiness time, regardless of how long the PR has been open. | Item 6 never requires or waits for one; it stores `$VERIFIED_SHA` for Step 2 and proceeds. |
| Candidate verification failure | The adapter's dispatched check concludes failure for the candidate it built. | Report the adapter's own failure reason and stop; do not retry with a different merge path. |
| Stale head at publish time | The PR head advanced past `$VERIFIED_SHA` between Step 1 and Step 2. | The adapter itself refuses (its expected-head precondition); report that refusal and stop — do not silently publish a newer, unverified commit. |
| Untrusted/wrong-issuer check | A check with the right name but the wrong reporting identity exists for the candidate (e.g. a candidate-authored workflow tried to forge it). | The adapter never accepts a name-only match; treat this exactly like a missing check (refusal), never as success. |
| Success, candidate distinct from head | The adapter publishes a constructed commit whose SHA differs from the PR's original head SHA — this is expected, not an error. | Report the merge as complete using the adapter's own reported result; do not treat "published SHA != observed head" as a discrepancy to investigate. |
| Repository without the adapter (legacy fallback) | No repository-declared adapter exists. | Item 6's existing `verification-record:v1`/`suite-evidence` matching and the `gh pr merge --match-head-commit` fallback in Step 2 apply exactly as documented above, unchanged. |

### Step 3: Update Linked Issues

1. **Extract issue references** from the PR title and description. Look for:
   - **Closing references:** `Closes #N`, `Fixes #N`, `Resolves #N` (case-insensitive) — the PR fully addresses the issue
   - **Partial references:** `Relates to #N`, `Part of #N` — the PR partially addresses or relates to the issue

2. **For each referenced issue**, fetch with `gh issue view <N> --json state,title` and post an update:

   **For closing references** (issue should be auto-closed by GitHub):
   ```
   gh issue comment <N> --body "$(cat <<'EOF'
   ## Delivered

   **PR:** #<pr-number> — <PR title>

   ### Changes delivered
   - <bullet summary extracted from PR description and diff>

   This PR fully addresses this issue.
   EOF
   )"
   ```

   **For partial references:**
   ```
   gh issue comment <N> --body "$(cat <<'EOF'
   ## Progress Update

   **PR:** #<pr-number> — <PR title>

   ### Changes delivered
   - <bullet summary extracted from PR description>

   ### Remaining work
   <What this issue still needs. If unclear, state "See issue description for remaining scope.">
   EOF
   )"
   ```

3. **If no issues are referenced**, skip this step.

### Step 4: Report

Output a summary:

```
## Merge Complete

**PR:** #<number> — <title>
**Merged to:** <base branch>
**Issues updated:** <list of issue numbers, or "none">

### Changes
- <bullet summary>
```

## Escalation

Stop and consult the user when:

- PR has failing CI checks that may be flaky (unclear if real failure)
- PR has unresolved review conversations
- Merge fails for an unexpected reason
- An issue referenced by the PR is already closed and the update seems redundant
- Any situation requiring human judgment about whether to proceed
