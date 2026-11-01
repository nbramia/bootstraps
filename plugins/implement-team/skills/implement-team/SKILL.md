---
name: implement-team
description: >-
  DEPRECATED — use implement-lifecycle (/implement) instead.
  Implementation lifecycle re-architected around Claude Code agent-teams —
  long-lived implementer and reviewer teammates with shared task list and
  mailbox messaging. Higher token cost than /implement in exchange for
  fewer speculative findings and better cross-reviewer dedupe.
  Triggers: /implement-team, implement with a team
argument-hint: <#issue | PR-number | freeform task> [instructions]
license: MIT
metadata:
  version: "0.5.1"
  tags: ["implement", "lifecycle", "review", "agent-teams", "experimental", "deprecated"]
  author: benjamcalvin
---

# Implement (team mode)

> **⚠️ DEPRECATED.** This plugin is no longer maintained. Use
> [`implement-lifecycle`](../../../implement-lifecycle) (`/implement`) instead — it
> covers the same lifecycle, is supported on both Claude Code and Codex, and does
> not depend on the experimental agent-teams runtime.
>
> `implement-team` remains installable so existing users are not broken, but it
> receives no fixes and will be removed in a future release. Known open defects
> are not being addressed.
>
> **If you invoke this skill, say so before proceeding** and offer `/implement`
> as the alternative.

Orchestrate the full implementation lifecycle for: $ARGUMENTS

This skill is **experimental** and depends on Claude Code's agent-teams feature. It must pass two preflight checks before doing any work.

## Preflight

Run these checks in order. If any check fails, print the failure message exactly as written and **exit without spawning a team**. Do not proceed to the stub body, do not attempt partial work.

### Check 1 — Claude Code version >= 2.1.32

Run:

```bash
claude --version
```

Parse the version number from the output (format is usually `<major>.<minor>.<patch>` possibly followed by a suffix such as `-beta` or a build identifier). Compare against the minimum `2.1.32`.

- If `claude --version` fails to run, treat it as a failed check.
- If the reported version is **less than 2.1.32**, print this message and exit:

```
/implement-team preflight failed: Claude Code version is too old.

This plugin depends on the experimental agent-teams feature, which requires Claude Code 2.1.32 or later.

Detected version: <observed version, or "unknown" if parsing failed>
Required version: >= 2.1.32

To upgrade, follow the official instructions at:
  https://code.claude.com/docs/en/setup#update-claude-code

After upgrading, re-run /implement-team.
```

- If the version is **>= 2.1.32**, continue to Check 2.

### Check 2 — CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

Agent-teams is gated behind an environment variable. The feature will not initialize teammates unless it is set to `1` at Claude Code startup.

Check whether the variable is set:

```bash
printenv CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
```

- If the value is exactly `1`, continue to the stub body.
- Otherwise (unset, empty, or any other value), print this message and exit:

```
/implement-team preflight failed: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS is not enabled.

This plugin depends on the experimental agent-teams feature, which is opt-in and must be enabled at Claude Code startup.

To enable it, add the following to your Claude Code settings.json (either the user-level file at ~/.claude/settings.json or the project-level file at .claude/settings.json):

  {
    "env": {
      "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
    }
  }

Alternatively, export it in the shell from which you launch Claude Code:

  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

Minimum Claude Code version: 2.1.32

After enabling it, fully restart Claude Code (not just /resume) and re-run /implement-team.

For more details, see: https://code.claude.com/docs/en/agent-teams
```

## Instructions

Both preflight checks passed. You are the **team lead** for this implementation lifecycle. You orchestrate long-lived teammates — you do not implement, review, verify, or merge yourself. There are specific team related tools that are separate from the Task/Agent tool. You may need to use tool search to find the right tool for spawning teammates, sending messages, and managing the shared task list.

**Drive forward autonomously.** Execute all selected phases without pausing for approval between them. Only stop to ask the user on genuine ambiguity, blocking decisions outside scope, or the escalation conditions listed at the bottom of this skill.

### Sole GitHub publisher (critical invariant)

**Only the lead posts to the PR timeline.** Reviewer teammates, the implementer, and the verifier write findings, status, and evidence to the **shared task list** (and optionally the mailbox). The lead reads the task list, synthesizes, and publishes the single authoritative comment per round. A teammate that attempts `gh pr comment`, `gh pr review`, or `gh issue comment` is violating the contract — surface that in the task list and do not rely on its output. This rule is restated in each phase below that posts to GitHub.

### Cleanup is mandatory on every exit path

Team cleanup (despawn all teammates, free resources, drop shared task list locks) **must run on every exit path**: clean exit, escalation exit, error exit, user abort, unexpected failure. Structure the orchestration so cleanup cannot be skipped — treat the entire run as wrapped in a trap-like guarantee:

```
on any exit (success | escalation | error | abort):
    invoke team-cleanup (despawn all spawned teammates)
    clear shared task list ownership if held
    then return control to the user
```

Before you spawn a team, commit to running cleanup before you return. Before you return on any code path below, re-verify cleanup has run.

### Task tracking

Use the **Task tools** (`TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`) throughout. Bootstrap a task per phase before starting. One `in_progress` at a time. Teammates share this task list — they read your dispatches from it and post their findings, evidence, and status back to it. Keep it truthful: delete irrelevant tasks, update descriptions if scope changes.

---

### Entry Point: Parse Arguments

Parse `$ARGUMENTS` using the same shapes as `/implement` (see `plugins/implement-lifecycle/skills/implement/SKILL.md` for the canonical reference — do not diverge without reason).

**Step 1 — Identify the target** from the leading token:

1. **`#N` (issue number):** Fetch via `gh issue view N --comments`. Extract task description and acceptance criteria.
2. **Bare number:** Run `gh pr view <number> --json number,title,state --jq '.'`. If it's an open PR, record the PR number (skip Phases 1–3).
3. **Freeform text:** Treat the entire `$ARGUMENTS` as the task description.

**Step 2 — Determine scope** from any trailing instructions:

| Instructions | Effect |
|-------------|--------|
| *(none)* | Default lifecycle: issue/freeform → Phases 1–6; PR number → Phases 4–6 |
| "just review" / "review only" | Run reviewer teammates only. Synthesize and post findings. Stop. |
| "address the review feedback" | Dispatch the implementer against existing findings only. |
| "review and address" | Run review/address loop but do not merge. |
| "skip planning" / "just implement" | Pass `skip planning` to the implementer dispatch. |
| Any other direction | Use judgment — execute the matching phases, skip the rest. |

The table is illustrative, not exhaustive. When in doubt, prefer the full lifecycle — it is always safe.

---

### Phase 0: Team Spawn

Spawn the long-lived teammates via Claude Code's experimental agent-teams mechanism. Communicate with teammates via the **shared task list** and **`SendMessage`** for directed messages. The agents live under `plugins/implement-team/agents/`.

**Spawn discipline — only spawn teammates you will invoke:**

| Scope | Teammates to spawn |
|-------|--------------------|
| Default (issue/freeform) | `team-implementer`, `team-reviewer-correctness` + any other reviewers Phase 4 will select, `team-reviewer-docs`, `team-verifier` |
| PR-review-only / "just review" | Selected Phase 4 reviewers + `team-reviewer-docs`. **Do not spawn the implementer or the verifier.** |
| "review and address" | Selected Phase 4 reviewers + `team-reviewer-docs` + `team-implementer`. No verifier. |
| "address the review feedback" | `team-implementer` only. No reviewers, no verifier. |

If you are uncertain which reviewers will be selected, spawn the set you are confident about up front and spawn the rest lazily before Phase 4 Step A. Every spawned teammate is a cleanup obligation — keep the set tight.

Record the spawned set. Phase-end cleanup despawns exactly this set.

---

### Phase 1–3: Plan, Implement, Open PR

Skip this phase if the target was a bare PR number or the instructions scope the run to review-only / address-only.

Dispatch the initial implementation to `team-implementer` via the shared task list. Pass:

- The issue number (or `0`) and task description
- Acceptance criteria if available
- `skip planning` only if the user requested it **and** the task is narrowly scoped — otherwise let the implementer plan. Note: the implementer's "Understand the Task and Its Context" step runs either way; `skip planning` only suppresses the separate plan-formulation step.

The implementer plans internally (if not skipped), writes tests first, writes production code, runs the suite, commits, pushes, and opens the PR. It hands you back:

```
PR_NUMBER: <number>
PR_TITLE: <title>
SUMMARY: <1-2 sentence summary>
```

Record the PR number. If the task had an issue number, post a progress comment to the issue — **the lead is the sole GitHub publisher**:

```
gh issue comment <N> --body "$(cat <<'EOF'
## In Progress

Implementation PR created: #<pr-number> — <PR title>
Entering adversarial review phase.
EOF
)"
```

---

### Phase 4: Review/Address Loop {#review-loop}

Mandatory loop. Each round: Step A → B → C → D → E. Exits:

1. **Clean exit (Step B):** zero findings survive referee filtering → proceed to Phase 4.5.
2. **Escalation exit (Step E):** round 10+ reached without convergence → escalate and stop (cleanup still runs).

#### Before Round 1

Rebase the PR branch on its current base:

```bash
BASE_BRANCH=$(gh pr view --json baseRefName --jq '.baseRefName')
git fetch origin "$BASE_BRANCH"
git rebase "origin/$BASE_BRANCH"
```

Resolve conflicts if any; re-run the full test suite; `git push --force-with-lease`. Fetch a lightweight PR summary for your own reference — do **not** fetch the full diff:

```bash
gh pr view <number>
gh pr view <number> --json files --jq '.files[] | "\(.path) (+\(.additions)/-\(.deletions))"'
gh pr view <number> --comments
```

Read specific files directly when refereeing.

#### Step A: Select and Dispatch Reviewers

Select **judiciously** — use the smallest sufficient reviewer set, not the full pool. Never invoke reviewers just for ritual coverage.

- `team-reviewer-correctness` — **Always** include when production logic changed.
- `team-reviewer-security` — auth/authz, user input, secrets, external integrations, PII, permission boundaries, spec conformance.
- `team-reviewer-architecture` — multi-module changes, new abstractions, dependency shifts, public APIs, structural refactors.
- `team-reviewer-testing` — tests changed, new behavior added, or existing behavior changed without obvious regression coverage.
- `team-reviewer-docs` — **Not in this pool.** Runs in Phase 4.5 only.

Dispatch the selected reviewers via the shared task list:

```
TaskCreate → subject: "[lead dispatch] review PR #<N> round <M>",
             body: "<selected reviewers> — fetch PR, dedupe with siblings, post findings to the task list. Do NOT post to GitHub."
```

Also `SendMessage` each selected reviewer with `"Review PR #<pr-number>, round <round-number>"` so they begin work immediately. Wait for all selected reviewers to post their findings (or a `[<specialty>] no findings — round <N>` summary task) to the shared task list before proceeding.

#### Step B: Referee Evaluation

Independently evaluate every finding. Read the relevant code yourself. Do not rubber-stamp; do not dismiss without checking.

| Decision | When to use | Effect |
|----------|-------------|--------|
| **Accept** (default) | Finding has merit — verified by reading the code | Include in the filtered dispatch at the reviewer's original severity |
| **Reject** | Finding is incorrect, irrelevant, or ill-considered | Exclude; record reasoning for the referee-decisions comment |

**Default postures** (same as `/implement`):

- Default to accept unless you can demonstrate the finding is wrong.
- **Security findings:** accept by default; reject only with concrete evidence the concern does not apply.
- **Convention findings:** accept if the code violates a documented standard; reject if purely stylistic preference with no backing standard.
- **Vague "consider"/"might":** accept if you independently agree; otherwise reject.

**Referee mindset:** principal-engineer bar. "Recommended" means "the code would be better for it," not "optional." Accept legitimate improvements that are in scope and incur no technical debt.

**If zero findings survive filtering,** post this brief comment to GitHub (**sole publisher**) and skip to Phase 4.5:

```
gh pr comment <number> --body "Review Round <N>: no actionable findings — review loop complete."
```

#### Step C: Post Referee Decisions (sole publisher) and Write Dispatch

Post the single authoritative round-N review to GitHub. This comment replaces what four reviewer comments would have been in `/implement` — **the lead publishes, the teammates do not**:

```
gh pr comment <number> --body "$(cat <<'EOF'
## Review Round <N> — Reviewer Findings

<Synthesized summary of reviewer findings, grouped by specialty. Use the task-list bodies — reviewer teammates wrote them complete enough that you do not need to re-derive them from the code.>

## Review Round <N> — Referee Decisions

| # | Finding | Reviewer | Severity | Decision | Reasoning |
|---|---------|----------|----------|----------|-----------|
| 1 | <brief description> | correctness / security / architecture / testing | Action Required / Recommended / Minor | Accept / Reject | <why> |
| ... | ... | ... | ... | ... | ... |

**Findings forwarded to implementer:** <count>
EOF
)"
```

Then write the filtered accepted findings to the shared task list as the implementer dispatch. **Do not pass reviewer chatter directly** — only the filtered, accepted set:

```
TaskCreate → subject: "[lead dispatch] address review round <N> for PR #<N>",
             body: "| # | Finding | Severity | Details |
                    |---|---------|----------|---------|
                    | 1 | <description> | <severity> | <file:line + what to fix> |
                    | ... | ... | ... | ... |"
```

#### Step D: Dispatch Implementer

`SendMessage` `team-implementer` pointing at the dispatch task: `"Address review round <N> — see shared task list dispatch <task-id>."` The implementer addresses only the dispatched set, runs the full suite, commits, pushes, and hands a structured summary back via the shared task list. **The implementer does not post to the PR timeline** — you do.

Wait for the implementer's hand-back task before proceeding.

#### Step E: Next Round

1. **Escalation check.** If this was round 10 or higher, post escalation to GitHub (**sole publisher**) and stop — cleanup still runs:

```
gh pr comment <number> --body "$(cat <<'EOF'
## Escalation — Review Loop Limit

<N> review rounds completed without convergence.

### Unresolved items
<list each unresolved item with context on what was attempted>

Requesting human review.
EOF
)"
```

2. **Continue.** Re-fetch the changed-files summary, increment the round counter, return to Step A unconditionally. Do not pause, do not ask the user. The loop exits only via Step B (clean) or the escalation above.

---

### Phase 4.5: Docs Compliance Gate

Runs **only after** the code review loop converges cleanly (not on escalation). **Mandatory even if the PR has no `.md` changes** — the docs reviewer is a curator, not a diff checker.

Spawn `team-reviewer-docs` now if you have not already. It is **not** in the Phase 4 pool.

Same structure as Phase 4, independent round counter, same 10-round escalation.

#### Step A: Dispatch Docs Reviewer

```
TaskCreate → subject: "[lead dispatch] docs review PR #<N> round <M>"
SendMessage → team-reviewer-docs: "Review PR #<pr-number> for documentation compliance, round <round-number>"
```

Wait for the reviewer's task-list entries.

#### Step B: Referee Evaluation

Apply the same accept/reject posture (read docs and code yourself).

**If zero findings survive filtering,** post this to GitHub (**sole publisher**) and skip to Phase 5:

```
gh pr comment <number> --body "Docs Compliance Gate: no actionable findings — proceeding to verification."
```

#### Step C: Post Referee Decisions and Dispatch Implementer (sole publisher)

```
gh pr comment <number> --body "$(cat <<'EOF'
## Docs Compliance Gate Round <N> — Reviewer Findings

<Synthesized docs findings.>

## Docs Compliance Gate Round <N> — Referee Decisions

| # | Finding | Severity | Decision | Reasoning |
|---|---------|----------|----------|-----------|
| 1 | <brief description> | Action Required / Recommended / Minor | Accept / Reject | <why> |
| ... | ... | ... | ... | ... |

**Findings forwarded to implementer:** <count>
EOF
)"
```

Write the filtered dispatch to the shared task list tagged `docs-round-<N>`, then `SendMessage` `team-implementer`: `"Address docs review round <N> — see shared task list dispatch <task-id>."`

#### Step D: Evaluate Continuation

Re-dispatch the docs reviewer to verify fixes. Independent round counter starting at 1. Loop until clean. **Same 10-round escalation** — if docs review does not converge, post escalation in the same format and stop; cleanup still runs.

---

### Phase 5: Verification Gate

Spawn `team-verifier` now if you have not already. It runs **only on lead invocation**; it does not interact with reviewer teammates.

Dispatch via the shared task list and `SendMessage`:

```
TaskCreate → subject: "[lead dispatch] verify PR #<N>"
SendMessage → team-verifier: "Verify PR #<pr-number>"
```

The verifier classifies the change, plans end-to-end verification, exercises the real system, and hands you a structured evidence report (PASS / FAIL / PARTIAL / N/A) via the shared task list. **The verifier does not post to GitHub** — you do.

Post the verifier's evidence to the PR (**sole publisher**):

```
gh pr comment <number> --body "$(cat <<'EOF'
## Verification — PR #<number>

<Verdict and evidence copied from the verifier's task-list entry>
EOF
)"
```

Route by verdict:

| Verdict | Action |
|---------|--------|
| **PASS** or **N/A** | Proceed to Phase 6 |
| **PARTIAL** | Decide: if the gaps are in-scope, route through the implementer; if out-of-scope, record as a follow-up and proceed to Phase 6 |
| **FAIL** | Filter the issues, write an implementer dispatch to the shared task list, `SendMessage` `team-implementer`, then re-invoke the verifier. Re-verify until PASS or escalation |

The verifier-fix loop uses the same 10-round cap as Phase 4 (reuse the code-review counter's spirit, not its value — track independently). On cap, escalate and stop; cleanup still runs.

---

### Phase 6: Merge and Finalize

Prefer delegating to the `merge-pr` skill from `implement-lifecycle`:

```
Skill tool → skill: "implement-lifecycle:merge-pr", args: "<pr-number>"
```

`merge-pr` validates readiness, squash-merges, deletes the branch, and posts linked-issue updates. It runs as the lead, so the sole-GitHub-publisher invariant holds.

If delegating is not available in the current agent-teams execution context, inline the equivalent: validate the PR is ready (CI green, approvals satisfied, no blocking reviews), squash-merge via `gh pr merge <number> --squash --delete-branch`, then post the progress comment to each linked issue (**sole publisher**):

```
gh issue comment <N> --body "$(cat <<'EOF'
## Done

PR #<pr-number> merged — <PR title>

<1-2 sentence summary of what was delivered>
EOF
)"
```

Report the result to the user.

---

### Phase 7: Team Cleanup (always runs)

Before returning control to the user on **any** exit path — clean, escalation, error, abort — run team cleanup:

1. Despawn every teammate you spawned in Phase 0 (and any spawned lazily later).
2. Release any shared task list locks or ownership the lead holds.
3. Mark all dispatch tasks as completed or cancelled so they do not leak into a future run.
4. Confirm no teammate subagent is still resident.

If cleanup itself fails, surface the failure directly to the user with the list of teammates that may still be resident. Do not silently return.

---

## Escalation

Stop and flag the user directly (not as a PR comment) when encountering:

- Ambiguous requirements you cannot proceed without clarifying
- Architectural decisions that exceed the task's scope
- A new third-party dependency is needed
- Changes touch auth, crypto, or PII handling beyond existing patterns
- Tests fail in ways unrelated to the changes
- Round-10 limit reached in Phase 4, Phase 4.5, or Phase 5

In every case, **run Phase 7 cleanup before returning.** Provide: what you tried, evidence for/against options, and your recommended path.
