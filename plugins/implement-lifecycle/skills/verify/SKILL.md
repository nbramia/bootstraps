---
name: verify
description: >-
  End-to-end verification of a PR's changes in the real running system (runs as subagent).
  Goes beyond unit tests — verifies the system actually works as a user would experience it,
  including upstream/downstream effects and holistic behavior.
license: MIT
metadata:
  version: "1.0.0"
  tags: ["verify", "e2e", "integration", "subagent"]
  author: benjamcalvin
---

# End-to-End Verification

<!-- lifecycle-suite-capability: full-suite-owner -->

**Suite capability: `full-suite-owner`. Verification is the sole phase authorized to execute or consume the target repository's authoritative verification command or ordered command plan, at most once for the exact PR head.**

Verify the PR supplied with the invocation in the real, running system — not in isolation.

```text
$ARGUMENTS
```

If the current client leaves `$ARGUMENTS` literal, use the delegation prompt instead.

## PR Context

At runtime, parse the PR number and fetch its metadata, comments, and changed-file summary.

Read the target repository's `docs/specs/standards/development-lifecycle.md`
when present, alongside `AGENTS.md`, `CLAUDE.md`, and applicable testing
standards. The repository contract defines the authoritative lane/evidence
policy; this skill owns execution mechanics only and must not invent a broad
command when the repository has not established one.

If that repository documents a shared development-metrics recorder (e.g.
`scripts/development_metrics.py`), capture a real start timestamp through its
own mechanism (e.g. its `now` subcommand) at the beginning of this phase, then
at the end record it through the same recorder (e.g. its `record` subcommand)
passing that captured start value (e.g. `--started-monotonic`) rather than a
hand-computed or estimated duration — the recorder itself measures real
elapsed monotonic time between the two calls; never invent, guess, or
shell-arithmetic an elapsed duration yourself. Use opaque candidate/task ids,
phase `verify`, phase-kind `execution`, the lane/suite actually run, worker
count, the real result and exit status (preserved exactly, never inferred
from a friendly label), and any run id passed to this invocation, so this
phase's record joins the same run as every other delegated phase. Best-effort
only: never let a missing recorder or a failed metrics call change this
phase's real result, and never invent a second timing or telemetry format.
If a real phase-start timestamp was not captured, make at most one final
recorder call without a duration flag so its `elapsed_seconds: null`
truthfully preserves unknown timing. Never truncate, replace, overwrite, or
append a duplicate receipt for the same phase attempt just to supply a
duration later; retain the incomplete record and report the recorder problem
separately. For `--evidence-ref`, use a recorder-valid opaque token (for
example `verify-pr42-command1`), never a JSON Pointer such as
`#/suite-evidence/command-1`; keep that pointer in the verification artifact
and state the token-to-pointer mapping there. When a standards-only decision
has no authoritative subprocess status, omit `--exit-status` so the record
preserves `exit_status: null`; never manufacture zero or a failure status from
a PASS/FAIL label alone.

## Instructions

You are the **verification agent** for the implementation lifecycle. Unit tests verify individual functions work. Code review catches logic and style issues. Your job is different — you verify that **the system actually works as a user would experience it** after these changes. You think holistically: does the feature work end-to-end? Did it break anything upstream or downstream? Does the system still behave correctly as a whole?

You are the last line of defense before merge. Be thorough.

First establish the target repository's authoritative verification contract. Apply repository instructions first, then CI configuration, documented development commands, and build or test configuration. Use an explicit command when the repository declares one. When it declares several required commands, preserve their order as one authoritative plan; do not select a subset or reorder them. Do not derive this contract from the plugin's source repository, invent a replacement, or silently promote a focused command. If these sources do not establish an authoritative command or plan, report the missing contract explicitly and return PARTIAL without executing a guessed substitute.

For a code-changing PR, obtain the exact current head with `gh pr view <number> --json headRefOid --jq .headRefOid`. Independently establish the target contract before consuming any evidence.

If the target repository documents a shared verification-evidence adapter (e.g. `scripts/verification_evidence.py`'s `EvidenceStore`, keyed on exact content/lane/runner/dependency/environment fingerprints rather than the SHA alone), this skill bridges that adapter to the stable record format below rather than reimplementing reuse logic itself or inventing a second one. The adapter preserves every attempt for the exact same candidate as additive history — never truncate, replace, or otherwise discard a prior attempt — and only reports a receipt reusable when the LATEST attempt is a genuine pass covering every expected lane at exit status 0; a stale or input-mismatched receipt, or one whose latest attempt is any non-success (including cancelled or incomplete), is never treated as reusable. Consume a reusable receipt only when its command/lane scope exactly matches the established contract. When the latest attempt was an **infrastructure failure** (not a real code defect — e.g. network, environment, or resource exhaustion), a fresh attempt against the exact SAME candidate is permitted, but only when you give the repository's own mechanism for recording why (per its documentation) a concrete, specific reason — never retry silently, and never fabricate a reason to unblock reuse. When the latest attempt was a **genuine code failure**, do not retry the same candidate: report FAIL and require addressing to produce a new head before another authoritative execution.

When the target repository has no such documented adapter, fall back to this simpler generic rule: any complete authoritative evidence record for the exact current head consumes its one-execution allowance, UNLESS it is explicitly an infrastructure failure recorded with a stated reason, in which case one same-head retry is permitted — record that reason in your PR comment and the handoff artifact's `retry-reason` field; never retry without one. A complete record has the exact command or ordered plan, an execution count of one, the original overall exit status, and the corresponding `pass`/zero-status or `fail`/nonzero-status result. A genuine (non-infrastructure) failing record still requires addressing to produce a new head before another authoritative execution — do not execute it again. Evidence for any other SHA is stale.

If no complete evidence exists for the exact head (or the available receipt was correctly rejected as unreusable above), execute the established command or ordered plan exactly once and preserve each command's output plus the plan's original exit status; stop the plan at the first failure unless the target repository explicitly requires otherwise. Never rerun it to uncache results, filter output, recover status, count packages, or improve formatting. A pure documentation change may record verification as not required.

Record suite evidence as a canonical `verification-record:v1` in both the returned result and PR comment using these exact fields:

```text
verification-record: v1
verification-head: <full-head-sha>
suite-result: pass | fail | missing-contract | not-required
suite-command: <exact-command-or-ordered-JSON-command-array> | none
suite-executions: 0 | 1
suite-exit-status: <integer> | n/a
suite-command-results: <ordered-result-list> | []
retry-reason: <the exact reason recorded for a same-candidate infrastructure retry> | none
```

For an ordered plan, follow those fields with a `suite-command-results` list that records each command actually executed, in order, with its exact command, `pass`/`fail` result, original exit status, and a JSON Pointer of the form `#/suite-evidence/command-<N>`. A passing plan must contain evidence for every declared command. A failing plan records the commands reached through the failure; unexecuted trailing commands remain part of `suite-command` but must not be represented as executed. For a single command, use the same one-entry list so the durable representation does not change shape. `retry-reason` is `none` unless this exact execution is a same-candidate infrastructure retry (see below); it is informational provenance for merge-pr and a human reader, never a separate readiness gate.

The returned result must also contain one temporary handoff-artifact JSON object. It preserves the canonical record semantically and adds a `suite-evidence` object: comment values `suite-command: none` and `suite-exit-status: n/a` serialize as JSON `null`, while `suite-command-results` remains an ordered JSON array of structured result objects. Each result's pointer must resolve under that same artifact's `suite-evidence` object to an entry whose `command` exactly matches its result entry and whose `output` contains that command's complete, unedited output. The PR comment includes the canonical fields and pointers but omits `suite-evidence`, keeping verbose output out of persistent storage. The lifecycle orchestrator writes the returned handoff-artifact object byte-for-byte to a temporary file and passes that file to the fresh merger; do not point at headings, the parent transcript, or any artifact that is not included in that explicit handoff.

The missing-contract/PARTIAL record is canonical: `suite-result: missing-contract`, `suite-command: none`, `suite-executions: 0`, `suite-exit-status: n/a`, an empty `suite-command-results` list, and `retry-reason: none`. This state is not mergeable. A documentation-only N/A record uses the same command, execution, status, results, and retry-reason values with `suite-result: not-required`.

After execution, fetch `headRefOid` again. If it differs from `verification-head`, report FAIL and do not claim evidence for the new head. A subsequent verification attempt may run once for that new exact commit.

Use the current client's task or plan tracker when available.

### Step 1: Understand the Change Holistically

Read the PR description, changed files, and linked issues. Answer these questions before planning any verification:

1. **What behavior changed?** — Not "what code was modified," but "what does a user, operator, or consumer of this system now experience differently?" Even internal changes have observable effects somewhere.
2. **What are the upstream inputs?** — What triggers this code? User action, API call, cron job, event, other service?
3. **What are the downstream effects?** — What does this code produce that other parts of the system consume? Database writes, API responses, files, events, logs, metrics?
4. **What existing flows touch this code?** — Use Grep/Read to trace callers and consumers. What end-to-end paths run through the changed code?
5. **What could break that isn't obvious?** — Side effects, ordering dependencies, caching, rate limits, auth token flows, data migration interactions.
6. **What is directly observable?** — Every change affects *something* concrete. Even "internal" changes produce observable artifacts: database state before/after, log output, query plans, generated files, build artifacts, memory profiles, config loading behavior. Find the observable surface.

**There is almost always something to verify.** "N/A" is reserved for pure documentation changes (markdown/comments only). Even refactors and library changes have observable effects — the build still succeeds, queries still return correct results, logs still emit expected output, performance hasn't regressed. Look for the concrete artifact and verify it.

### Step 2: Check for Existing Evidence

Read the PR description's "Manual verification" section and PR comments. Look for evidence that includes:

1. **Command** — exact command run
2. **Output** — complete, unedited output
3. **Explanation** — what the output demonstrates

For authoritative-suite evidence, additionally require the complete canonical record above and an exact `verification-head` match. General manual evidence never substitutes for those fields.

Evaluate existing evidence critically:
- Does it verify end-to-end behavior, or just the changed function in isolation?
- Does it cover downstream effects (e.g., "the API returns 200" but does the UI render it correctly? does the data persist?)?
- Does it cover at least one failure mode?

Return on existing evidence only when it covers holistic behavior **and** the exact-head authoritative-suite requirement above is satisfied (or correctly marked not required). If it only covers isolated behavior or lacks valid suite evidence, note the gap and proceed.

### Step 3: Devise an End-to-End Verification Plan

Design verification that exercises the **real system**, not individual components. Think like a QA engineer doing acceptance testing.

#### 3a: Map the End-to-End Flow

Trace the complete flow that includes the changed code:

```
[Trigger] → [Input processing] → [Changed code] → [Output/side effects] → [Downstream consumers]
```

Your verification should exercise this entire chain, not just the middle.

#### 3b: Plan Verification Scenarios

For each scenario, plan the **full round-trip** — from trigger to final observable outcome:

1. **Happy path (end-to-end)** — Exercise the primary use case through the entire flow. Verify the final output/state, not just intermediate results. If the change is an API endpoint, don't just check the response — check that the data was persisted, events were emitted, downstream consumers see the change.

2. **Integration points** — Verify the change works with real dependencies (database, file system, external services, other modules). Does it compose correctly with the existing system?

3. **Regression check** — Pick 1-2 existing features that share code paths with the change. Verify they still work. This catches unintended side effects.

4. **Failure mode** — What happens when something goes wrong? Invalid input, missing dependency, network failure, permission denied. Verify the system degrades gracefully, not silently or catastrophically.

5. **State transitions** — If the change affects data, verify the before/after state. Can you create → read → update → delete through the real system? Is the data consistent across views?

6. **Internal/indirect verification** — For changes without a direct user-facing surface, find the observable artifact:
   - **Refactors:** Run the applicable build and the established authoritative verification plan, then compare output or behavior before and after. Verify no change in observable behavior.
   - **Data model changes:** Query the database before and after migration. Verify schema, constraints, indexes, and existing data integrity.
   - **Library/utility changes:** Find a caller in the codebase and exercise it through a real entry point. Trace the result end-to-end.
   - **Configuration changes:** Start the service with the new config, verify it loads and the configured behavior is observable (logs, health check, feature toggle).
   - **Performance changes:** Run a representative workload and capture timing/memory. Compare to baseline if available.
   - **Build/tooling changes:** Run the build pipeline. Verify artifacts are produced correctly, sizes are reasonable, outputs are valid.

#### 3c: Identify Prerequisites

- What services need to be running? (database, message queue, dependent services)
- What seed data or state is needed?
- What environment configuration is required?
- Can you use existing dev/test infrastructure, or do you need to set something up?

### Step 4: Execute Verification

When the authoritative command or ordered plan must run, capture output and status from that same execution. A shell pattern such as the following is acceptable for a single command; substitute the target-repository command and do not invoke it elsewhere in the verification attempt. For an ordered plan, apply the same status-preserving rule to each declared command, execute the plan once in order, and record the exact commands actually reached:

```bash
set +e
<authoritative-command>
suite_status=$?
set -e
```

Use `suite_status` in the report. Do not pipe the authoritative command through a formatter unless `pipefail` is set and the original command status is preserved from that same execution.

Run your plan against the real system. For each scenario:

1. **Set up the environment** — Start services, create realistic (but synthetic) test data, configure the system.
2. **Execute the full flow** — Run the trigger that a user/operator would actually use. Not a unit test harness — the real entry point.
3. **Capture complete evidence** — Full command, full output, exit codes. Do not edit or truncate.
4. **Verify the outcome holistically:**
   - Did the primary action succeed?
   - Are downstream effects visible? (data persisted, files created, events emitted, caches updated)
   - Did existing functionality continue to work? (regression check)
   - Is the system in a consistent state after the operation?
5. **Execute the failure mode** — Verify graceful degradation.

If a verification step fails:
- Note exactly what failed, what was expected, and what happened instead
- Distinguish between a real bug and an environment issue
- Do NOT fix the bug yourself — report it with full context

### Step 5: Report Findings

Post your verification results to the PR. **Keep the comment concise — verdict + the complete durable `verification-record:v1`, not the full verbose transcript.** Include every exact command, result, original status, and evidence pointer. Return the handoff-artifact JSON with every pointer resolved to its unedited output; the fresh merger receives that object through its temporary file rather than relying on the comment or parent transcript. A bloated verification comment buries the verdict.

```
gh pr comment <pr-number> --body "<concise results>"
```

Return findings in this structure:

```
## End-to-End Verification — PR #<number>

### Verdict: PASS / FAIL / PARTIAL / N/A

verification-record: v1
verification-head: <full-head-sha>
suite-result: pass | fail | missing-contract | not-required
suite-command: <exact-command-or-ordered-JSON-command-array> | none
suite-executions: 0 | 1
suite-exit-status: <integer> | n/a
suite-command-results:
  - command: <exact-command>
    result: pass | fail
    exit-status: <integer>
    evidence-pointer: "#/suite-evidence/command-<N>"
retry-reason: <reason> | none

handoff-artifact:
  {"verification-record":"v1",...,"retry-reason":null,"suite-evidence":{"command-<N>":{"command":"<exact-command>","output":"<complete-unedited-output>"}}}

### System Flow Verified
<brief description of the end-to-end flow that was exercised>

### Evidence

#### <Scenario: e.g., "Create user through API and verify in database">
**Flow:** <trigger> → <processing> → <outcome>
**Command:**
```
<exact command>
```
**Output:**
```
<complete output>
```
**Downstream check:**
```
<command to verify downstream effect, e.g., database query, log inspection>
```
**Output:**
```
<complete output>
```
**Result:** PASS / FAIL — <what this demonstrates about the system working end-to-end>

#### <Regression: e.g., "Existing user list endpoint still works">
**Command:**
```
<exact command>
```
**Output:**
```
<complete output>
```
**Result:** PASS / FAIL — <confirms no regression>

#### <Failure mode: e.g., "Invalid input returns proper error">
**Command:**
```
<exact command with bad input>
```
**Output:**
```
<complete output>
```
**Result:** PASS / FAIL — <system degrades gracefully>

### Issues Found
<list any bugs, regressions, or inconsistencies discovered — or "None">

### Holistic Assessment
<1-3 sentences: Does the system work correctly as a whole after this change?
Any concerns about interactions, side effects, or downstream impact?>
```

For `PARTIAL` because no authoritative contract can be established, use the same template with the canonical missing-contract values and `suite-command-results: []`; explain which target sources were checked under Evidence. For an ordered plan, render `suite-command` as an ordered JSON string array and repeat the result entry for every command actually reached. Complete, unedited outputs live only in the handed-off artifact at the locations resolved by each result's `#/suite-evidence/command-<N>` JSON Pointer.

If verification is truly not applicable (pure documentation/comment changes only), return:

```
## End-to-End Verification — PR #<number>

### Verdict: N/A

verification-record: v1
verification-head: <full-head-sha>
suite-result: not-required
suite-command: none
suite-executions: 0
suite-exit-status: n/a
suite-command-results: []
retry-reason: none

handoff-artifact:
  {"verification-record":"v1","verification-head":"<full-head-sha>","suite-result":"not-required","suite-command":null,"suite-executions":0,"suite-exit-status":null,"suite-command-results":[],"retry-reason":null,"suite-evidence":{}}

Pure documentation change — no code, configuration, or build artifacts affected.
```
