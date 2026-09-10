---
name: implement
description: >-
  Implementation, review, and merge — full lifecycle or any subset.
  Lean orchestrator that delegates all heavy work to isolated subagents.
  Triggers: /implement, $implement-lifecycle:implement, implement this, build this feature
license: MIT
metadata:
  version: "3.1.0"
  tags: ["implement", "lifecycle", "review", "tdd"]
  author: benjamcalvin
---

# Implement

<!-- lifecycle-suite-capability: focused-only -->

**Suite capability: `focused-only`. Run focused tests, lint, builds, and acceptance commands only. Do not execute or consume the target repository's authoritative verification command or ordered command plan. Final verification owns that evidence.**

Orchestrate the full implementation lifecycle using the task supplied with the skill invocation.

The active harness expands the payload below. If it leaves the payload literal, use the user's invoking prompt instead.

```text
$ARGUMENTS
```

At runtime, inspect the current branch and recent commits. Fetch any referenced issue and its comments before delegating.

## Target repository contract

When the target repository contains `docs/specs/standards/development-lifecycle.md`,
read it together with `AGENTS.md`, `CLAUDE.md`, and applicable standards before
choosing phases or delegating work. Treat that repository document as the
authoritative project policy; this plugin supplies harness-neutral mechanics
and must not duplicate or override repository-specific lifecycle rules.

Explicit user instructions given at invocation precede both this plugin's
default mechanics and the target repository's default process policy where
the two conflict (e.g. a user requesting full delegated review on a routine
change, or a narrower scope than default policy would otherwise run) — never
silently substitute a repository or plugin default for an instruction the
user actually gave. This does not extend to a repository's enforced technical
or compliance constraints (required checks, branch protection, required
approvals): an ordinary task cannot use a user instruction to waive, weaken,
or falsely report a real, still-enforced gate, per Phase 6's own precedence
rule. The one exception is a task whose own explicit, authorized scope IS to
change that policy or configuration itself (e.g. a task to edit branch
protection, required-check bindings, or this repository's own lifecycle
contract) — that authorization comes from the task's stated scope, never
from a same-task attempt to route around its own gate.

If that repository documents a shared development-metrics recorder, mint one
opaque run id for this task (or reuse an inherited one) and include it in the
context bundle below so every delegated phase's metrics record joins the same
run instead of each minting its own.

### Routine inline path

This orchestrator implements and reviews inline **by default**: make the edit
yourself, run only the focused check that policy calls for (or note none is
observable), open the PR, and apply the one proportionate review that policy
calls for — instead of delegating to `implement-code`. This path always folds
any docs relevance into that same single review rather than running a
separate delegated documentation-compliance gate, regardless of whether the
change has an observable or documented surface.

Escalate to the full delegated lifecycle below instead of taking this default
when the target repository's risk policy classifies the task as requiring
independent adversarial review (per its own risk table), or — absent a
documented repository risk policy — when the task touches any of: behavior
only observable in the running application, concurrency or resource
ownership, schema or public API compatibility, authentication or privacy
boundaries, money movement, or irreversible data loss. Also escalate when the
user has requested the full delegated lifecycle. Never invent a narrower or
broader notion of these triggers than the repository's own risk table (when
one exists) would recognize. Explicit user instructions override this
default in either direction: a user asking for full review on a task that
would otherwise stay inline gets it; a user explicitly authorizing this
inline path for a task that would otherwise escalate gets that instead of
forced delegation. The mandatory delegation and no-self-edit rules below
govern the full delegated lifecycle; they do not apply while this routine
inline path is in effect.

## Instructions

<!-- stop-guard:active -->

You are a **lean orchestrator** — a supervisor who delegates, not an implementer, for any task outside the routine inline path above. Every heavy phase in the full delegated lifecycle runs in an isolated delegated agent; worker skills define the work but do not create that isolation themselves. **Outside the routine inline path, you MUST NOT use file-editing tools to modify source code, tests, or documentation.** You may use the shell for git/gh commands and tests, and the current client's read/search capabilities for refereeing, but never edit the codebase under review yourself except as that path explicitly permits.

**Permitted carve-out — orchestration scratch files:** Writing non-source orchestration files for findings handoff is expected and allowed. Resolve a writable scratch location through the harness when it provides one; otherwise ask the operating system to create a temporary file or directory. Record each resolved path and pass it explicitly to the receiving worker. The prohibition targets modifying the codebase under review — source, tests, and docs — not writing orchestration scratch files.

**You are the sole publisher to the PR timeline.** Reviewers return their findings to you and post nothing themselves; you publish exactly **one consolidated comment per review round** carrying every reviewer's findings alongside your referee decisions. If a reviewer reports having posted to GitHub, it violated its contract — note it and continue; do not mirror the duplicate.

**Drive forward autonomously.** When you have a plan (from the user or an issue), execute all phases without pausing for approval between them. Do not ask "shall I proceed to the next phase?" — just proceed. Only stop to ask the user when you hit a genuine ambiguity, a blocking decision outside the task's scope, or an escalation condition listed below.

Use the current client's task or plan tracker throughout when available.

**Task tracking rules:**
1. **Bootstrap immediately.** Create a task for each phase before starting, using the fields the current client supports.
2. **One in_progress at a time.** Mark `in_progress` before starting, `completed` the moment it finishes.
3. **Break down dynamically.** Add sub-tasks when entering a phase or when unexpected work surfaces.
4. **Keep the list truthful.** Delete irrelevant tasks, update descriptions if scope changes.

### Harness-neutral delegation

The lifecycle maps each heavy phase to one canonical worker skill:

| Phase | Canonical skill |
|-------|-----------------|
| Implement | `implement-code` |
| Address | `implement-address` |
| Review general | `review-general` |
| Review correctness | `review-correctness` |
| Review security | `review-security` |
| Review architecture | `review-architecture` |
| Review testing | `review-testing` |
| Review docs | `review-docs` |
| Verify | `verify` |

For every delegation, use the adapter for the active harness to create a fresh isolated child, explicitly select the mapped canonical skill, pass the complete payload and context bundle, and return the child's result to the orchestrator. Choose the closest balanced model available in that harness for each delegation; use stronger or lighter models only when the task warrants it. Do not assign one model choice to the whole lifecycle.

**Claude Code adapter.** Spawn a generic isolated subagent whose prompt begins `Use the implement-lifecycle:<skill> plugin skill`, followed by the complete payload and fresh context bundle.

**Codex adapter.** Spawn a generic isolated subagent whose prompt begins `Use $implement-lifecycle:<skill>`, followed by the complete payload and fresh context bundle.

**Pi adapter.** With the user-installed `pi-subagents` prerequisite available, launch a generic `delegate` child with `skill: <skill>`, `context: "fresh"`, and the complete payload and fresh context bundle. Never rely on the delegate default for context freshness. Do not use or distribute custom Pi agent definitions.

**Generic adapter.** A compatible harness must create a fresh isolated child, load the mapped Agent Skill explicitly, pass the complete payload and fresh context bundle, and return the child result. A harness that cannot provide isolated delegation or load the required skill must report the failed phase and must not execute it inline **as a substitute for that delegation** — this does not apply to the routine inline path above, which is an intentional non-delegated path chosen by policy, not a fallback for a harness's missing capability.

When specialists are selected, every adapter launches the selected reviewers in parallel and waits for all their results before refereeing.

Selected Pi reviewers remain parallel, read-only children. Each delegation explicitly names its canonical `skill`, sets `context: "fresh"`, and captures the child's final result. A reviewer result is complete only when it is non-empty and contains all four canonical headings: `### Defects`, `### Missing Tests`, `### Status`, and `### Summary`. Do not referee an empty, missing, or structurally incomplete result.

The reviewer-result recovery contract is this exact state graph:

<!-- lifecycle-reviewer-recovery:v1
delegated + nonempty-canonical-result -> complete
delegated + empty-or-incomplete-result -> incomplete
incomplete + transcript-recovery-complete -> complete
incomplete + transcript-recovery-incomplete -> fresh-retry
incomplete + transcript-recovery-unavailable -> fresh-retry
fresh-retry + nonempty-canonical-result -> complete
fresh-retry + empty-or-incomplete-result -> stop
complete + referee -> refereeing
-->

On an incomplete result, first recover the final captured result from the harness transcript when available. If recovery is unavailable or still incomplete, retry once in a new child with the same canonical skill and `context: "fresh"`. If that retry is incomplete, stop the phase and report the failed delegation. Only the `complete` state may enter refereeing.

**Isolate delegated context.** Each delegated agent (implementer, addresser, reviewer, verifier) should be launched with MINIMAL, FRESH context: the PR/issue being worked, the governing contract (issue body, ADR, or spec), the current diff, and any prior accepted/rejected findings — NOT the orchestrator's accumulated cross-PR history. Long-lived or reused sessions (e.g., a docs gate or verifier kept alive across multiple PRs) accumulate unrelated context and degrade review quality; reset or bound them per PR. Assemble a single shared **context bundle** (issue, contract, diff, prior findings, referee decisions, and the run id described above when the target repository has a metrics recorder) and pass the same bundle to every child for that PR, so each starts from the same ground truth instead of re-deriving it.

### Entry Point

Parse the invocation input to determine **what to work on** and **what to do**.

**Step 1 — Identify the target** from the leading token:

1. **`#N` (issue number):** Fetch its body and comments, then extract the task description and acceptance criteria.
2. **Bare number:** Run `gh pr view <number> --json number,title,state --jq '.'`. If it matches an open PR, record the PR number.
3. **Freeform text:** Treat the entire invocation input as the task description.

**Step 2 — Determine scope** from any trailing instructions:

Any text after the leading token is **instructions that control what you do**. These can narrow or redirect the default lifecycle:

| Instructions | Effect |
|-------------|--------|
| *(none)* | Default lifecycle: issue/freeform → Phases 1–6; PR number → Phases 4–6 |
| "just review" / "review only" | Run the general reviewer plus any warranted specialists, then post the consolidated review yourself (Phase 4 Step C). Stop. |
| "address the review feedback" | Run the addresser only against existing review findings. |
| "review and address" | Run review/address loop but don't merge. |
| "skip planning" / "just implement" | Pass "skip planning" to implement-code so it skips codebase exploration and plan formulation. |
| Any other specific direction | Use judgment — execute the phases that match the intent, skip the rest. |

The table above is illustrative, not exhaustive. Interpret the user's intent and execute accordingly. When in doubt, do more rather than less — the default full lifecycle is always safe.

### Phase 1–3: Plan, Implement & Create PR

**CRITICAL: You MUST NOT write code or edit files yourself.** Delegate all implementation through the client adapter above.

Planning is handled internally by `implement-code`. Do **not** invoke a separate planning step — this eliminates the seam where the orchestrator might pause for approval between planning and coding.

Decide whether the task needs planning and pass appropriate instructions:
- **Needs planning** (ambiguous, touches multiple modules, unclear acceptance criteria): pass the task description without "skip planning"
- **Skip planning** (clear, scoped tasks like "fix the typo in config.go"): include "skip planning" in the instructions

**Delegate to the implementer** through the client adapter:

```
Payload: <issue-number-or-0> <task description, acceptance criteria, and optional instructions>
```

Pass the full context: task description, acceptance criteria from the issue (if any), and any optional user instructions. If there's a linked issue, pass the issue number as the first arg; otherwise pass `0`.

Wait for the skill to return. The implementer will plan internally (if needed), write code, write tests, and return the **PR number** and a summary. Record the PR number for Phase 4.

**Update linked issues.** If the original task was a GitHub issue, post a progress comment:
```
gh issue comment <N> --body "$(cat <<'EOF'
## In Progress

Implementation PR created: #<pr-number> — <PR title>
Entering adversarial review phase.
EOF
)"
```

### Phase 4: Review/Address Loop {#review-loop}

**One round-based convergence bound covers this loop.** Track a running round count for this task's Phase 4 review/address cycle. This bound cannot be reset, hidden, or bypassed by rewriting history: a revise-and-reset or restart-clean recovery (Step E below) may change the branch, scope, or approach, but it never zeroes the count already spent — if the bound is already exhausted when a stall or scope guard fires again, escalate to the user rather than starting another revised or clean attempt.

**This is a mandatory loop, and it converges on silence.** One round runs by default; a further round runs only when the immediately preceding round forwarded an accepted finding to the addresser. It repeats Steps A → B → C → D → E for each round until one of exactly two exit conditions is met:

1. **Clean exit (Step B):** Zero findings survive referee filtering — including a round whose findings were all rejected — → skip to Phase 5. Terminate without invoking an addresser or another reviewer. If the rejections were close calls (the underlying concern was valid but the remedy was out of scope), consider escalating for human direction instead of silently proceeding.
2. **Escalation exit (Step E):** A scope/convergence guard fires, OR convergence stalls (two consecutive rounds forward no fewer accepted findings than the prior round), OR round 5 is reached → stop the loop and run the **convergence-recovery decision** in Step E. Recovery is not a single path: revise-and-reset, restart-clean, or escalate to the user.

There is no other way to exit this loop. Each round: General review plus any targeted specialist reviews → Referee (you) → Addresser → next round. **The loop continues while it is converging; it escalates when convergence stalls.** Convergence = each round forwards **strictly fewer** accepted findings than the prior round, with no open production defect and no review-introduced churn. Stalled = two consecutive rounds forward no fewer accepted findings than the prior round. Escalation is driven by stalled convergence or a scope guard, not by a fixed round count. Do not continue past 5 rounds without explicit user authorization even when converging, but you are NOT required to hit 5 — on a stall, first consider recovering the run (revise-and-reset or restart-clean, below) before escalating to a human.

#### Before Round 1

**Rebase on the PR's current base branch** to ensure the review runs against current code:

```bash
BASE_BRANCH=$(gh pr view --json baseRefName --jq '.baseRefName')
git fetch origin "$BASE_BRANCH"
git rebase "origin/$BASE_BRANCH"
```

If conflicts arise, resolving them is a **permitted git-mechanical carve-out** to the no-edit contract. Keep it strictly mechanical, then run focused tests for the affected packages and force-push the rebased branch:

```bash
git push --force-with-lease
```

The orchestrator does not execute verification's authoritative suite. It hands the exact current PR head and any durable evidence for that same head to `verify`; all earlier phases remain focused-only.

**Pin the toolchain once.** Discover the target repository's pinned runtime, compiler, package manager, and toolchain from its governing instructions and project configuration, then use those exact selections consistently across every phase. Do not let implementer, addresser, and verify resolve different toolchain versions; version drift creates failures that are not real regressions.

Then fetch a lightweight PR summary for your own reference:
```bash
gh pr view <number>
gh pr view <number> --json files --jq '.files[] | "\(.path) (+\(.additions)/-\(.deletions))"'
gh pr view <number> --comments
```

Do **NOT** fetch the full diff — it fills the context window. Read specific files when you need to spot-check during refereeing.

#### Step A: Invoke Reviewers

Invoke **`review-general` in every round**. It owns a complete, proportionate baseline review: correctness, issue and PR requirements, project conventions and standards, established local patterns, scope, maintainability, integration fit, and basic test adequacy.

Then decide whether the PR has a concrete high-risk area that needs deeper specialist attention. Specialists are optional and supplement the general review; they do not repeat it:

- `review-correctness` — Logic bugs, edge cases, error handling, race conditions
- `review-security` — Trust boundaries, authZ, sensitive data, security requirements, injection risks
- `review-architecture` — Pattern consistency, module boundaries, coupling, forward-looking design
- `review-testing` — Test coverage, assertion quality, edge cases, test anti-patterns
- `review-docs` — Missing, stale, or contradicted documentation; undocumented new public-facing surfaces

Use judgment from the PR summary, changed-file list, and issue/spec context:
- **Routine, well-bounded PRs:** run only `review-general`.
- Add **`review-correctness`** only for unusually subtle algorithms, concurrency, state transitions, resource lifecycles, or error-path-heavy logic.
- Add **`review-security`** for auth/authz, untrusted input, secrets, external integrations, sensitive data, or permission boundaries.
- Add **`review-architecture`** for consequential new abstractions, dependency shifts, public APIs, structural refactors, or changes spanning architectural boundaries.
- Add **`review-testing`** when test strategy itself is risky: complex fixtures, weak or missing regression coverage, multiple test layers, nondeterminism, or substantial test-harness changes.
- Add **`review-docs`** for a change to public-facing behavior (new CLI command, changed default, public API, plugin surface, config option), a change that restructures internals with observable effects, or any change to documentation files.
- Prefer zero specialists for routine work and one specialist for a focused risk. Use multiple specialists only when the PR genuinely contains multiple independent high-risk surfaces, and record why each was selected.
- Do not select a specialist merely because files in its domain changed. The general reviewer already covers ordinary correctness, patterns, requirements, and test adequacy, including whether the change leaves accurate documentation behind.

Invoke the general reviewer and any selected specialists in parallel through the client adapter:

```
Payload: Review PR #<pr-number>, round <round-number>
```

Each reviewer fetches PR context and returns its findings to you. Reviewers do **not** post to GitHub — you publish their findings in the consolidated comment in Step C, so keep each reviewer's returned text until then. In round 2 and later, tell reviewers to focus on unresolved accepted findings, the latest fix delta, and regressions introduced by accepted fixes. They must not reopen rejected findings or speculatively harden unrelated surfaces.

**Reviewers should execute the PR's own focused acceptance commands when feasible** — focused tests, linters, or commands the PR claims to satisfy — rather than only reasoning about them. They must follow their `focused-only` capability. Reasoning alone misses mechanical acceptance failures (self-referential scans, off-by-one anchors, unbuilt code). If a reviewer cannot execute (no environment or a sandbox limitation), it records that under its own Status heading rather than asserting correctness it did not verify. A reviewer's execution or sandbox failure is a status on its review, not a finding — it never appears under Defects or Missing Tests, and it never consumes a referee decision or a round.

**Reassess specialists each round.** Always keep `review-general`. Re-invoke a specialist only when the latest fix delta or an unresolved accepted finding still touches its high-risk area. Drop specialists whose concern is resolved and whose area was not changed; do not spend another review merely to preserve the prior round's roster.

#### Step B: Referee Evaluation

When reviewers return, **independently evaluate every finding**. Read the relevant code yourself. Do not rubber-stamp and do not dismiss without checking. A reviewer reports at most two kinds of finding — a defect reachable on a path a caller or user actually takes, and a missing test for behavior the change itself claims to deliver — and drops everything else at the source rather than sending it to you at a lower tier; treat any finding that arrives outside those two kinds as out of contract and reject it without spending further attention on it. A reviewer's own execution or sandbox failure arrives under its Status heading, never as a finding, and consumes no referee decision.

**Deduplicate across reviewers first.** Two specialists often return the same underlying gap (e.g. architecture and security both flag the same catalog conflict, or three reviewers all flag the same orphan-demanded field). Before evaluating, collapse duplicate findings into one entry, note the cross-reviewer duplication, and evaluate that single concern once. Do not count a duplicate as multiple independent findings or forward it to the addresser multiple times.

Evaluate two questions separately:

1. **Concern validity:** Does the finding demonstrate a concrete failure scenario and identify the acceptance criterion, documented invariant, or existing behavior it violates?
2. **Remedy proportionality:** What is the smallest in-scope change that resolves that demonstrated failure? A valid concern does not make the reviewer's proposed remedy appropriate.

For each finding, decide:

| Decision | When to use | Effect |
|----------|-------------|--------|
| **Accept** (default) | The concern is concrete and a smallest in-scope correction is available | Include only that proportional correction in the addresser action plan |
| **Reject** | The concern is unproven, already resolved, out of scope, or disproportionate for this PR | Exclude it; record whether the concern itself was valid and optionally open a follow-up issue |

**Default postures** (err on the side of accepting):
- Default to **accept** only after verifying the concrete failure and its violated criterion or invariant.
- **Security findings:** Treat a concrete, applicable security failure as high priority; reject theoretical attacks whose preconditions the changed code cannot meet.
- **Convention findings:** Accept only when the code violates a documented standard in a way that is reachable on a normal path. Reject a purely stylistic preference with no backing standard, and reject a finding about the wording of a comment, docstring, or PR description — no reviewer's contract permits reporting prose wording as a finding, so treat one that arrives anyway as out of contract.
- **Missing-test findings:** Accept only when the change claims behavior that no existing test pins, and the smallest addition would pin it.
- **Vague "consider" / "might" language:** Reject unless it is backed by a reproducible failure or violated criterion.

Produce a **filtered action plan** containing only accepted findings.

**Referee mindset:** Think like a principal engineer. Preserve adversarial pressure on the selected design while keeping the remedy tied to the original task. Prefer changing or removing the smallest amount of code. When repeated findings target architecture introduced during addressing, prefer simplifying or removing that architecture over hardening it again.

**Scope controls:** Before forwarding a remedy, compare it with the original issue and current PR. Escalate to the user or create a follow-up instead of forwarding a remedy that adds a dependency, executable subsystem, public interface, persistence mechanism, or new architectural layer not named by the issue. If a remedy would push the PR beyond the one logical change it set out to make — adding a concern a reviewer would have to evaluate separately — perform a scope audit first: identify which changes trace to original acceptance criteria and which were introduced only by review. Out-of-scope or disproportionate is valid **Reject** reasoning even when the underlying concern is real.

Use these calibration cases:

- Concrete bug with a bounded fix: **Accept** the smallest fix.
- Valid concern paired with an architectural remedy: accept a smaller in-scope correction if one exists; otherwise **Reject** it for this PR and escalate or file a follow-up.
- Speculative hardening with no demonstrated failure: **Reject**.
- Second non-clean round dominated by review-introduced complexity: run the convergence audit, stop before round 3, and request human direction. Recommend bounded simplification or removal of the review-introduced architecture.

**If zero findings survive filtering**, still post the consolidated comment from Step C so the reviewers' raw findings and your rejection reasoning stay on the record, ending it with `**Result:** no actionable findings — review loop complete.` Then skip to Phase 5.

#### Step C: Post the Consolidated Review & Write Findings File

Publish **one** comment per round covering every reviewer plus your referee decisions. Reviewers posted nothing, so this comment is the entire audit trail for the round — reproduce each reviewer's findings faithfully rather than summarizing them away. Record every reviewer that ran and its verdict (PASS or findings). Never let a review that ran go unrecorded.

```
gh pr comment <number> --body "$(cat <<'EOF'
## Review Round <N> — Consolidated Review & Referee Decisions

**Reviewers run:** general<comma-separated targeted specialists, if any>

**Specialist rationale:** <why each specialist was needed, or "none — general review was sufficient">

### Reviewer Findings

#### General
<that reviewer's returned findings, verbatim under its Defects / Missing Tests / Status headings>

#### <Specialty, only when invoked>
<...>

<one section per reviewer invoked; note "no findings" where a reviewer returned clean>

### Referee Decisions

| # | Finding | Reviewer | Kind | Concern | Decision | Reasoning / smallest remedy |
|---|---------|----------|------|---------|----------|-----------------------------|
| 1 | <brief description> | correctness | Defect / Missing Test | Valid / Unproven | Accept / Reject | <why and, if accepted, the bounded correction> |
| ... | ... | ... | ... | ... | ... | ... |

**Findings forwarded to addresser:** <count>
EOF
)"
```

If the body is long enough to be unwieldy on the command line, write it to a temp file and post with `gh pr comment <number> --body-file <path>` — but still post it as a single comment.

Write the filtered findings (accepted only) to a temp file for the addresser:

```bash
cat > <resolved-findings-path> <<'EOF'
# Filtered Findings — Round <N>

| # | Finding | Kind | Details |
|---|---------|------|---------|
| 1 | <description> | Defect / Missing Test | <file:line + what to fix> |
| ... | ... | ... | ... |
EOF
```

#### Step D: Invoke Addresser

```
Payload: <pr-number> <round-number> <resolved-findings-path>
```

The addresser will fix issues, run tests, commit, push, and return a summary.

#### Step E: Next Round

The addresser has pushed fixes. Check convergence and the escalation limit, then continue.

**Do not run a redundant clean-confirmation round.** If the previous round was genuinely clean — exit condition 1: reviewers submitted zero findings (not merely zero ACCEPTED findings, which is the rejected-only case handled below) — and the only changes since were trivial/mechanical (no new logic), do NOT re-invoke reviewers just to confirm cleanliness — that is a wasted round. Proceed to Phase 5. Only re-invoke a reviewer when a substantive change was made after the clean round.

0. **Rejected-only rounds do not advance the loop.** If the referee accepted zero findings in the last round (every finding rejected as unproven / out of scope / already resolved), do NOT invoke the addresser and do NOT count it as a productive round. Post the consolidated comment (Step C already did), then either treat the loop as converged and proceed to Phase 5, or, if the rejections were close calls, escalate for human direction. Never send an empty findings file to the addresser.

1. **Convergence audit after round 2:** After two non-clean rounds, post an audit that maps the remaining findings and review-added changes to the original acceptance criteria. For each distinct sub-problem or code area still under contention, record the finding DENSITY (how many findings have targeted that same sub-problem across rounds). A sub-problem with repeated findings across multiple rounds is a convergence trap — flag it. State whether the loop is converging and whether remaining findings primarily concern the original task or architecture introduced during addressing. If they primarily concern review-introduced architecture, stop before round 3 and request human direction. Recommend bounded simplification or removal of that architecture.

2. **Convergence-recovery decision:** When the escalation exit fires (the bound reached, convergence stalled, or a scope guard), do **not** default to stopping. Diagnose WHY the loop is not converging and choose one of three recovery paths. **None of the three resets the round count from this phase's header above** — a revised or clean attempt still draws down the same bound, never a fresh one, and discarding drifted work is a scope/branch decision, not a history rewrite that makes the bound disappear. If the bound is already exhausted, only the third path (escalate) remains available:

   - **Revise-and-reset — original scope insufficiently specific.** If the reviews kept surfacing ambiguity — underspecified acceptance criteria, conflicting requirements, or findings the original issue never pinned down — the scope was the problem, not the implementation. Take the learnings from this run (what the reviews revealed about the real requirement), reset the branch to a clean head, revise the issue/requirements to be specific and unambiguous, and open a **clean PR** built on the revised issue — only when the bound still has room; otherwise escalate instead.
   - **Restart-clean — gone off track.** If the loop is dominated by review-introduced architecture or scope creep that drifted from the original issue, the run went off track. Start clean — discard the drifted work — and restart with **clearer guidelines** that bind the work back to the original issue scope, only when the bound still has room; otherwise escalate instead. As part of this, update the underlying issue with notes that give clearer instructions — even a partial clarification (an added constraint, a boundary, a worked example, or an explicit "out of scope" note) materially increases the odds the next attempt succeeds and does not require a full revision.
   - **Escalate to the user.** If the stall is a genuinely hard ambiguity that self-revision cannot resolve, the bound is already exhausted, or the user should choose between the paths, escalate. This remains a valid option — self-recovery is not mandatory.

   Do **not** extend the SAME loop, nor start a revised or clean one, past the bound without explicit user authorization; a reset or restart continues counting against that same bound, it does not grant a new one. If you escalate, post the escalation comment and stop:

```
gh pr comment <number> --body "$(cat <<'EOF'
## Escalation — Review Loop Limit

<N> review rounds completed without convergence. Escalating on stalled convergence (or the round-5 ceiling).

### Unresolved items
<list each unresolved item with context on what was attempted>

Requesting human review.
EOF
)"
```

Then stop and inform the user directly.

3. **Continue:** Re-fetch the changed-files summary and the latest address commit's delta, increment the round counter, and return to Step A. Continue autonomously unless the convergence audit requires human direction or another scope guard fires.

### Phase 5: Verification

After the review loop converges, invoke the verification agent to test the PR's changes with real-world execution before merging. This phase owns lane execution and evidence preservation for the exact candidate — it does not run a multi-round findings loop.

```
Payload: <pr-number>
```

The verification agent will classify the change type, devise a verification plan, execute it, and report structured evidence. If **PASS** or **N/A**, proceed to Phase 6. If it is **PARTIAL** because the target repository has no authoritative verification contract, stop and report that missing contract; do not merge or invent a substitute.

Capture the verifier's returned handoff-artifact JSON object: the complete durable `verification-record:v1` (exact command or ordered JSON plan, execution count, overall status, and ordered per-command result/status/evidence-pointer entries) plus its `suite-evidence` object. Confirm every `#/suite-evidence/command-<N>` pointer resolves inside that object to the matching exact command and complete unedited output. Write the whole object byte-for-byte to a harness-provided temporary file, or a uniquely created file under the operating system's temporary directory when the harness provides none, and pass the resolved path explicitly to `merge-pr`. The verifier publishes only the matching concise canonical record in its PR comment; `suite-evidence` remains in the temporary handoff and is never posted as persistent output. If the returned object is absent, malformed, or has a dangling or mismatched pointer, stop rather than reconstructing it from the parent transcript.

If the verdict is **FAIL**, it names a genuine defect reachable in the running system — fix it in the branch under review rather than deferring it to a follow-up PR. Because `implement-address` reads its findings from a file argument (and aborts if that file is missing or empty), write the verification findings to a temp file first; `verify` only posts a PR comment, it does not write this file, so the orchestrator must create it:

```bash
cat > <resolved-verify-findings-path> <<'EOF'
# Verification Findings

| # | Finding | Kind | Details |
|---|---------|------|---------|
| 1 | <what failed> | Defect | <expected vs. actual, file:line if known, how to fix> |
| ... | ... | ... | ... |
EOF
```

Invoke the addresser once with that file path:

```
Payload: <pr-number> verify-1 <resolved-verify-findings-path>
```

After the addresser pushes fixes, re-invoke `verify` exactly once against the new head. If that second verification is **PASS** or **N/A**, proceed to Phase 6. If it is not, stop this phase and escalate to the user directly rather than cycling further — do not fix the code yourself and do not invoke another addressing or verification attempt without explicit user authorization.

### Phase 6: Merge & Finalize

Invoke `merge-pr` through the same harness-neutral adapter contract used for every other lifecycle phase. Select the Claude Code, Codex, Pi, or generic adapter for the active harness, load the canonical `merge-pr` skill explicitly, pass fresh PR context, and capture its returned result:

```
Payload: <pr-number> <resolved-verification-record-path>
```

This validates the PR, applies the target repository's merge and branch-retention policy, and posts updates on linked issues.

Report the result to the user.

## Escalation

Before flagging the human, consider whether a stalled run can be recovered autonomously (see the convergence-recovery decision in Phase 4 Step E): revise-and-reset on an insufficiently-specific scope, or restart-clean when the work has gone off track. Escalation to the human is the fallback when neither self-recovery path applies or the user should decide.

Stop and flag the human directly (not as a PR comment) when encountering:

- Ambiguous requirements where you cannot proceed without clarification
- Architectural decisions that exceed the scope of the task
- A new third-party dependency is needed
- Changes touch auth, crypto, or PII handling beyond existing patterns
- Tests fail in ways unrelated to your changes

Provide: what you tried, evidence for/against options, your recommended path.
