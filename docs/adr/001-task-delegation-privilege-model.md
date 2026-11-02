# ADR-001: Task-delegation substrate, privilege tiers, and exposure model

**Status:** Accepted
**Last Updated:** 2026-11-02
**Decision:** Accepted

**Issue:** [#77 — feat: generalize second-opinion into a privilege-tiered task-delegation tool](https://github.com/benjamcalvin/bootstraps/issues/77)
**Related:** [#75](https://github.com/benjamcalvin/bootstraps/issues/75) (second-opinion), [#44](https://github.com/benjamcalvin/bootstraps/issues/44)/[#45](https://github.com/benjamcalvin/bootstraps/issues/45) (implement-cli), [#69](https://github.com/benjamcalvin/bootstraps/issues/69) (implement-team)

## Context

`second-opinion` (`plugins/second-opinion/`) delegates work to external AI CLIs
in exactly one shape: read-only, review-only. Its core —
`scripts/consult.sh`, one `run_<provider>()` per CLI, prompt-file in / text
out — is a task-delegation primitive deliberately constrained to consultation.
We want to generalize it from *consult* to *delegate*: hand an external agent a
real task, including tasks that write code or run commands, and integrate the
result.

The moment delegation crosses from read-only to read-write, three problems the
current design sidesteps become load-bearing:

1. **Privilege delegation** — what capabilities a delegate gets, by what
   mechanism, and how escalation stays explicit rather than silent.
2. **Outbound exposure** — a delegate can read the filesystem (secrets,
   credentials, unrelated repos) and transmit contents to its provider.
   Sandboxes restrict writes and terminal access; they do **not** stop reads.
3. **Inbound exposure** — delegate output is untrusted and
   attacker-influenceable. Task inputs and repo contents are prompt-injection
   vectors that can steer a delegate into embedding malicious instructions in
   its output.

A sibling plugin, `implement-cli` (paused at the time, since removed; [last version](https://github.com/nbramia/bootstraps/blob/d8a20e965b9e68cabe419eb2ff6ed8fc48e3f8fe/plugins/implement-cli)),
already solved "delegate a read-write task to Claude via the Python Agent SDK,"
with cost/depth tracking (`tracking.py`) and
`permission_mode="bypassPermissions"` (`sdk.py`). So the generalization
overlaps two existing substrates, and "which substrate" must be resolved before
building capability.

This ADR records that resolution plus the privilege and exposure model. Several
decisions were settled by the maintainer during scoping (issue #77 comments);
they are recorded below as **decided**, not open questions. One decision —
allowlist ownership — is settled by this ADR itself.

## Decision

We will extend `second-opinion` into a privilege-tiered `delegate` primitive
(Option A) with a three-tier ladder — `consult` (default, read-only) /
`act-sandboxed` (opt-in, worktree-scoped writes) / `act-full` (per-invocation
gated) — every delegate subprocess enclosed by a pinned Anthropic
`sandbox-runtime` wrapper, fail-closed. The numbered Decision sections below
record each constituent decision and its rationale.

## Decision 1: Substrate — extend `second-opinion` into a `delegate` primitive (Option A)

The candidates from issue #77:

- **A — Extend `second-opinion` (external CLIs).** Generalize `consult.sh`
  into a privilege-parameterized delegate launcher over Codex / Antigravity.
- **B — Revive + extend `implement-cli` (Claude Agent SDK).** Build delegation
  on the paused Python SDK foundation.
- **C — New unifying `delegate` plugin over both.** One interface over
  external CLIs *and* the Claude SDK from day one.

**Chosen: A**, with headless Claude (`claude -p`) planned as *just another
provider* behind the same launcher interface rather than a separate SDK
orchestration stack. Rationale, on the three axes that matter:

| Axis | A — extend second-opinion | B — revive implement-cli | C — new unifying plugin |
|---|---|---|---|
| **Billing** | External providers bill their own accounts; no draw on the user's Claude quota. Adding `claude -p` as a provider is subscription-billed and cappable per-invocation (`--max-budget-usd`). | Entirely on the user's Claude subscription bucket; parallel delegates compete with interactive use. Was paused over a billing split that is resolved-for-now but could return (see [Quota and billing](#quota-and-billing-exhaustion)). | Both models at once — most flexible, but forces solving both billing stories before shipping anything. |
| **Privilege mechanisms** | Every target is a subprocess launched from a shell script, so one external OS-level wrapper (Decision 5) uniformly encloses all of them; per-CLI sandbox flags map directly to tier flags. Matches the decided three-boundary architecture, which puts real enforcement *outside* the harness. | `permission_mode` / `allowed_tools` are harness-native (boundary 1 only) — exactly the layer the maintainer decided to inherit, not rely on. The SDK subprocess would still need the same external wrapper, gaining nothing over launching `claude -p` from the shell substrate. | Same enforcement as A, at the cost of maintaining two invocation stacks (shell + Python SDK) with tier semantics kept in lockstep. |
| **Maintenance surface** | ~140 lines of bash with established exit-code discipline (`0/1/2/3`), plus a SKILL.md — no language-runtime dependency chain, but **not dependency-free once Decision 5 is counted**: A owns a pinned native dependency (`srt`, riding on Seatbelt / bubblewrap+socat) as a hard prerequisite. Adding a tier parameter and providers extends an existing, tested pattern. | A Python package (SDK dependency chain, pytest suite, async orchestrator) that is currently paused; reviving it couples delegation to `claude-agent-sdk` release cadence — **and** it would still need the same `srt` wrapper on top (see privilege row), so B's surface is a superset, not an alternative to, A's. | Largest surface: a new plugin plus continued upkeep of both existing ones. |

Option C's *goal* — one interface over external CLIs and Claude — is still
reached, but through A's provider abstraction (`run_<provider>()` +
`binary_for()`) instead of a new plugin: `claude` becomes a provider entry
whose binary is `claude` and whose headless mode is `claude -p`. Option B's
valuable machinery (budget caps, depth limits in `tracking.py`) informs the
budget-cap flags of the Claude provider but is not revived as the substrate.
`implement-cli` was not revived, and has since been removed.

Consequence: the `second-opinion` plugin grows a generalized `delegate.sh`
(shape finalized in PR 2); `consult` remains the name of the default read-only
tier and the existing skill's **review semantics** are unchanged (same
prompt-in / findings-out contract, same exit codes, same cleanup rules). Its
**runtime prerequisites** do change: per Decisions 5–6, once PR 2 lands the
pinned `srt` wrapper is a hard, fail-closed prerequisite for `consult` too —
a deliberate breaking change for existing installs without `srt` (see
[Consequences](#consequences)).

## Decision 2 (decided, maintainer): the three-boundary model

Privilege and exposure enforcement decomposes into three orthogonal
boundaries. Each must hold independently, because each has known gaps the
others cover.

1. **Permissions boundary — harness-native; inherit, don't build.** Codex
   `--sandbox` modes, Claude `permission_mode` + `allowed_tools`, `agy
   --sandbox`. Known gap: Bash/terminal access can bypass harness permission
   models, which is why boundaries 2–3 must hold on their own.
2. **Filesystem boundary — two layers.** A dedicated **git worktree** scopes
   what the delegate is *supposed* to touch, verified post-hoc by the
   write-scope tripwire (Decision 8); the **OS-level sandbox jail**
   (Seatbelt on macOS, bubblewrap/Landlock on Linux — provided by the wrapper
   in Decision 5) is the actual enforcement.
3. **Network boundary — default-deny egress with a domain allowlist**
   (provider API endpoints + explicitly named registries only). This kills
   prompt-injection callbacks and casual exfiltration even when boundaries
   1–2 leak.

## Decision 3: the three-tier privilege ladder

Three tiers, ordered by capability. The tier is an explicit parameter of every
delegation; the mechanisms listed are for the chosen substrate (A).

| Tier | Capability | Codex (`codex exec`) | Antigravity (`agy`) | Claude provider (`claude -p`) | Wrapper (Decision 5) | Worktree |
|---|---|---|---|---|---|---|
| **`consult`** (default) | Read-only. No writes, no terminal side effects, no network beyond the provider API. | `--sandbox read-only` | `--sandbox` (binary toggle: sandbox with terminal restrictions) | `permission_mode` default + read-only `allowed_tools` (`Read`, `Glob`, `Grep`) | **On**; FS jail read-only outside temp (write restriction) + credential-path `denyRead` list (Decision 5); egress allowlist = provider endpoints | Optional (current-tree behavior preserved) |
| **`act-sandboxed`** (opt-in) | Write, but only inside an isolated scope. | `--sandbox workspace-write`, CWD = worktree | `--sandbox` (no native write-scoped mode — the wrapper's FS write-allowlist *is* the enforcement; see note) | `permission_mode acceptEdits` + restricted `allowed_tools` (`Read`, `Write`, `Edit`, `Glob`, `Grep`, scoped `Bash`) | **On**; FS jail write-allowlist = the worktree + run temp dir only, same credential-path `denyRead` list; same egress allowlist | **Required** — dedicated git worktree is the allowed write scope, verified by the tripwire |
| **`act-full`** (gated) | Unrestricted write / terminal / network. | `--sandbox danger-full-access` | unsandboxed (see forbidden-flags note) | `permission_mode bypassPermissions` | **Off or widened** — only reachable via explicit per-invocation approval | **Default: launcher creates a dedicated worktree** — running in the primary tree requires a second explicit opt-out flag (see Decision 8) |

Notes:

- **Antigravity has only a binary sandbox toggle** — no graduated
  write-scoped mode. For `act-sandboxed` it therefore leans entirely on the
  external wrapper's filesystem write-allowlist; the native `--sandbox` flag
  stays on as defense-in-depth for terminal restrictions.
- **Forbidden flag combo:** `agy --sandbox --dangerously-skip-permissions`
  auto-approves the sandbox-bypass prompt
  ([google-antigravity/antigravity-cli#36](https://github.com/google-antigravity/antigravity-cli/issues/36)).
  The delegate launcher must never pass `--dangerously-skip-permissions`
  together with `--sandbox`, at any tier.
- The per-CLI sandbox flags are **boundary 1** (harness-native, inherited).
  They are kept on at every tier where they apply, but the load-bearing
  filesystem and network enforcement at `consult` and `act-sandboxed` is the
  wrapper (boundaries 2–3).

## Decision 4: `consult` is the default; escalation is never silent

- A delegation invoked with **no explicit tier runs at `consult`** —
  read-only, wrapper on, verified by the tripwire showing zero out-of-scope
  writes.
- **No code path silently escalates.** A caller requests a higher tier
  explicitly per invocation. `act-sandboxed` is opt-in via the tier
  parameter. `act-full` additionally requires an **explicit per-invocation
  approval** — a distinct affirmative signal beyond selecting the tier.
  **Finalized in PR 4:** the approval is the `--i-approve-full-access` flag,
  which must be passed on the **same invocation** as `--tier act-full`. Tier
  and flag together — two independent affirmative signals — are what grant
  `act-full`; either alone does not. Requesting `act-full` without the
  approval flag is **refused with an actionable error** (naming the tier, the
  approval flag, and citing this decision), never downgraded silently and
  never granted silently. The approval flag on its own — without
  `--tier act-full` — does not escalate: the run stays at whatever tier was
  selected (`consult` by default). The widened posture is surfaced loudly on
  stderr at invocation and in the result on stdout.
- Tier grants do not persist: approval for one invocation confers nothing on
  the next. The `--i-approve-full-access` flag is per-invocation only; there
  is no configuration, environment variable, or state file that makes
  `act-full` a default.

## Decision 5 (decided, maintainer): pin-and-adopt Anthropic `sandbox-runtime` as the single external wrapper

Adopt [Anthropic `sandbox-runtime`](https://github.com/anthropic-experimental/sandbox-runtime)
(`srt`) as the **single external wrapper around all delegate subprocesses**
(`codex`, `agy`, `claude -p`): one boundary, one config, no per-provider
drift. `srt` provides the OS-level filesystem jail (boundary 2) and
default-deny egress through a localhost allowlisting proxy (boundary 3) —
native Seatbelt on macOS without root, bubblewrap/socat on Linux with the same
config.

- **Invocation shape:** `srt` is a CLI wrapper, invoked as
  `srt --settings <config>.json <command…>`. That is what makes one wrapper
  uniform across every subprocess provider from a bash launcher — no library
  binding or extra runtime involved.
- **Pinned to an exact version.** `srt` is a pre-1.0 research preview: no
  floating ranges; version bumps are deliberate, reviewed changes.
- **Explicit read-deny policy required.** `srt`'s filesystem semantics are
  asymmetric: **writes are default-deny** (allow-only), but **reads are
  default-allow** with a deny-then-allow pattern (`filesystem.denyRead` /
  `allowRead`). A jail with no read policy therefore bounds writes but leaves
  the readable surface as open as running unsandboxed. The shipped `srt`
  settings **must** include an explicit `denyRead` list covering known
  credential and secret paths at every tier where the wrapper is on — at
  minimum `~/.ssh`, `~/.aws`, `~/.config/gh`, shell history files, and OS
  keychain stores (the same paths Decision 8 names as tripwire blind spots).
  Under this policy `allowRead`'s role is narrow: re-permitting a specific
  subpath *inside* a denied directory when a task genuinely needs it (e.g. a
  single config file under a denied dotdir). Such carve-outs into credential
  paths should be rare and surfaced loudly via the same mechanism as
  Decision 7's allowlist extensions: any `allowRead` carve-out into a denied
  credential path is reported to the user at invocation time, before or
  alongside the run. This blocks known credential
  paths; it does not make reads scope-bounded in general (see [Outbound](#outbound-the-delegate-can-read-and-reads-reach-the-provider)).
- **No DIY Squid/Seatbelt/nftables glue.** That is security-critical code we
  do not want to own.
- **Native CLI allowlists enabled underneath as defense-in-depth:** Codex
  `[features.network_proxy].domains` (default-deny, wildcards, HTTP-method
  restriction), Claude Code `sandbox.network.allowedDomains`. Antigravity has
  only a binary sandbox toggle and no domain allowlist, so it leans entirely
  on the wrapper.
- **Tier ↔ wrapper mapping:** `consult` and `act-sandboxed` both run inside
  the wrapper, differing only in the filesystem write scope; `act-full` means
  the wrapper is off or widened, reachable only through the Decision 4 gate.
- **NVIDIA [OpenShell](https://github.com/NVIDIA/OpenShell)** (MicroVM
  isolation + credential-stripping privacy router) is positioned as the
  future `act-full` isolation candidate — the strongest available model, but
  currently alpha, Linux-MicroVM-only, and too heavy for a macOS dev machine.
  Revisit on maturity.

## Decision 6 (decided, maintainer): fail-closed

If the pinned `srt` — or its platform dependencies (Seatbelt on macOS,
bubblewrap/socat on Linux) — is unavailable, or the wrapper fails to start,
the delegation is **refused with an actionable error**. There is no silent
degradation to harness-native sandboxing alone. This mirrors the existing
`consult.sh` exit-code discipline: `2` = required component not installed,
`3` = component failed. The error must say what is missing and how to install
it, matching how the skill already surfaces missing provider CLIs.

Fail-closed governs `consult` and `act-sandboxed` — the tiers whose
enforcement depends on the wrapper. An approved `act-full` invocation running
with the wrapper intentionally off or widened is not a fail-closed violation;
it is the explicit outcome of the Decision 4 approval gate, and that gate
itself (not the wrapper) is what fail-closed protects at `act-full`.

## Decision 7 (settled by this ADR): allowlist ownership

The remaining open question was who owns the egress domain allowlist. Decision:

- **The plugin ships tight per-provider allowlist files** containing provider
  API endpoints only (e.g. the Codex, Antigravity, and Anthropic API domains
  needed for the respective CLI to function). No registries, no `github.com`,
  no shared CDNs in the shipped defaults — broad entries reopen
  exfiltration paths.
- **A documented user-extension mechanism** lets users add domains (e.g. a
  package registry a delegated task genuinely needs). Extensions live in
  user-owned config, never by editing the shipped files.
- **Extensions are surfaced loudly at invocation time:** every delegation
  that runs with a non-default allowlist reports the extra domains to the
  user before/alongside the run, so a widened egress surface is never
  invisible.

Rationale: shipped-tight defaults keep the common case safe with zero user
configuration; the loud-extension rule keeps the trade-off visible when users
opt into more.

## Exposure model

### Outbound: the delegate can read, and reads reach the provider

Sandboxes restrict **writes and terminal access, not reads**. At every tier,
a delegate can read files its jail exposes and transmit their contents to its
provider (OpenAI, Google, or Anthropic) as part of doing its task. This is
already documented for the read-only case in `second-opinion`'s README; it
sharpens once delegates act, because acting tasks legitimately need broader
context.

Mitigations, not eliminations:

- The wrapper's jail does **not** bound reads by default — `srt` reads are
  default-allow; only writes are default-deny. What it does provide is the
  explicit `denyRead` list required by Decision 5, which blocks known
  credential and secret paths. Reads of anything else the OS lets the process
  see can still reach the provider. Worktree isolation (at `act-sandboxed`)
  points the delegate at a dedicated checkout — a scoping convention, not a
  read barrier.
- Default-deny egress limits *where* data can go to the provider API — but
  the provider itself necessarily receives what the model reads.
- Guidance stands: do not delegate from trees holding secrets or credentials
  you would not hand to that provider directly.

### Inbound: delegate output is untrusted and attacker-influenceable

Task inputs, diffs, and repo contents are prompt-injection vectors. A hostile
diff or poisoned file can steer a delegate into producing output that embeds
instructions ("now run …", "add this token to …") aimed at the orchestrator.
Therefore:

- **Delegate output is data, never instructions.** The orchestrator reads it,
  attributes it (`[codex]`, `[antigravity]`, `[claude]`), sanity-checks
  claims against the actual code, and decides what to do — it never executes
  commands, applies edits, or changes its own plan *because the output said
  so*. This generalizes the `second-opinion` Step 5 synthesis discipline.
- At acting tiers, the delegate's *writes* are also untrusted output: the
  orchestrator reviews the worktree diff as it would an external PR before
  integrating anything.

### Least-privilege pass-down

The orchestrator passes a delegate the **minimum** it needs, and nothing else:

- **Credentials:** a delegate runs under its own provider login (Codex:
  `codex login`; Antigravity: `agy` login or `ANTIGRAVITY_API_KEY`); the
  orchestrator never forwards unrelated credentials into the delegate's
  environment. For the Claude provider, prefer a scoped
  `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`; subscription-billed,
  revocable) over `ANTHROPIC_API_KEY` for routine delegation; pass exactly
  one, explicitly, and only when delegating to Claude.
- **Environment scrubbing is a launcher requirement, not a wrapper
  guarantee.** Upstream `srt` documents environment stripping only as a
  Windows side effect (separate `srt-sandbox` account); on macOS (Seatbelt)
  and Linux (bubblewrap) — this design's target platforms — the sandboxed
  subprocess **inherits the launcher's ambient environment**, including any
  exported `AWS_*`, `GITHUB_TOKEN`, or CI secrets. The delegate launcher
  (PR 2) must therefore construct a scrubbed environment itself before
  invoking `srt` — e.g. `env -i` plus an explicit allowlist containing only
  the one provider credential and a minimal `PATH`/`HOME` — so nothing
  ambient leaks into the subprocess.
- **Scope:** prompt files contain the task and the needed context, not the
  orchestrator's own instructions, tokens, or unrelated user data. The run
  directory holding prompt files and diffs is cleaned up on **every** exit
  path (the existing SKILL.md Step 3/5 mandatory-cleanup rule carries over
  unchanged).

## Decision 8: the write-scope tripwire

`second-opinion` SKILL.md Step 4 defines a git-status/HEAD tripwire that
detects *some* violations of the read-only contract. It generalizes as
follows: for an `act-sandboxed` delegate, the tripwire's question changes from
"did anything change?" to **"did anything change *outside the allowed
scope*?"** — where the allowed scope is the delegate's dedicated worktree
(plus its run temp dir).

- **Before** launching: snapshot `git status --porcelain --ignored` and
  `git rev-parse HEAD` in the **primary** working tree (and any other
  worktrees of the repo), plus a listing of the shared git dir's `hooks/`
  and `config` — i.e. everywhere the delegate is *not* allowed to write. The
  shared `.git` `hooks/`/`config` are covered explicitly because a
  `.git/hooks` plant or a `core.hooksPath` / `credential.helper` / `url.insteadOf`
  rewrite in `config` is a code-exec vector on the user's next git operation
  in the **primary** tree, yet is invisible to a working-tree `git status`.
- **The tripwire's own before/after snapshot state must live OUTSIDE the
  delegate's writable scope** — not under any `allowWrite` path, and kept in
  `denyWrite`. Otherwise an adversarial or prompt-injected delegate could
  regenerate the before-snapshots to match its tampering and erase the
  evidence, defeating detection with no jail bypass required. The store is a
  dedicated temp dir kept out of the delegate's write scope — in `denyWrite`,
  never `allowWrite` — so the delegate cannot overwrite the before-snapshots to
  erase evidence. Reads remain default-allow like everywhere else; the store
  holds only git-status/HEAD snapshots the delegate could already read at the
  source, so read-protection would buy nothing.
- **After** completion: re-snapshot and diff. Changes inside the delegate's
  worktree are the expected work product; **any delta outside it is a
  violation** and is surfaced loudly at the top of the result, with the same
  honesty rules as today: the tripwire brackets the whole run, cannot
  attribute a change to a specific delegate when several ran concurrently,
  and can be tripped by unrelated activity in the window.
- The known blind spots carry over and must be restated wherever the tripwire
  is described: it cannot see appends to existing ignored files, new files
  inside already-ignored directories, writes outside any git worktree
  (`~/.ssh`, `~/.aws/credentials`, …), or writes to the shared `.git`
  internals **other than `hooks/` and `config`** (the object/ref store,
  `index`, …) — those two are covered per the bullet above, but `objects/`,
  `refs/`, and the rest are not. For those, the enforcement is the
  wrapper's filesystem jail (boundary 2); the tripwire is a cheap post-hoc
  check that the jail and the delegate's harness behaved, nothing more.
- At `consult`, the tripwire degenerates to exactly today's behavior: the
  allowed write scope is empty, so *any* detected write is a violation.
- At `act-full`, the launcher **defaults into a dedicated worktree too**
  (Decision 3). This is not a capability restriction — the tier remains
  unrestricted write/terminal/network — but it keeps the tripwire's
  before/after scope clean at the highest-blast-radius tier: expected work
  lands in the delegate's worktree, and any primary-tree delta is still a
  loud signal. The caller can opt out into the primary tree only with a
  distinct explicit flag — **finalized in PR 4 as `--primary-tree`** (separate
  from the `--i-approve-full-access` approval flag, so leaving the worktree is
  its own deliberate third signal); doing so forfeits that attribution and the
  opt-out is surfaced loudly in the result (a `ACT-FULL-PRIMARY-TREE` marker on
  stdout and a banner on stderr). When `act-full` runs in the default worktree,
  the write-scope tripwire runs exactly as it does at `act-sandboxed`, even
  though the `srt` wrapper is off — the tripwire is post-hoc detection and does
  not depend on the jail. **The tripwire's tamper-resistance, however, DOES
  depend on the jail, and must not be oversold at `act-full`.** The
  before/after snapshot store is tamper-resistant only while the wrapper is on
  (`consult`, `act-sandboxed`): the jail keeps it in `denyWrite` and outside the
  delegate's writable scope, so erasing evidence would require a jail escape. At
  `act-full` the wrapper is off by design, no `denyWrite` is generated, and the
  delegate holds unrestricted write, so it can discover and overwrite the
  snapshots with no jail escape needed — genuine tamper-resistance is impossible
  at this tier (same-user, no jail). At `act-full` the tripwire is therefore
  **best-effort detection only, not tamper-proof** — a courtesy signal, surfaced
  as such in the loud `act-full` banner so `--primary-tree`/worktree-default
  users do not over-trust a silent tripwire as proof nothing escaped.

## Quota and billing exhaustion

For the Claude provider, parallel delegates draw from the **same Pro/Max
subscription bucket** as interactive use and can starve it. Mitigations:

- Per-invocation budget caps: `claude -p --max-budget-usd` for headless
  delegates; the pattern mirrors `implement-cli`'s `--max-cost` /
  `RunContext.max_cost_usd` enforcement.
- Document the shared-bucket behavior in the skill; prefer external-CLI
  providers or API-key billing for heavy fan-out.
- Billing-split status (per issue #77 references): Anthropic announced, then
  same-day paused indefinitely, a June 15 2026 change moving Agent SDK /
  `claude -p` usage to a separate API-rate credit pool, promising advance
  notice before any future change. Headless `claude -p` currently draws from
  subscription quota. This ADR does not re-litigate the billing model; if the
  split is redeployed, only the Claude provider's billing story changes — the
  external-CLI providers are unaffected.

## Honest limits / risk register

Things this design mitigates but does not eliminate. These must not be
oversold anywhere the feature is documented.

| # | Risk | Status / residual |
|---|---|---|
| 1 | **Hostname-based allowlisting is not a hard boundary.** Egress filtering keys on client-supplied hostname (SNI / CONNECT) with no TLS inspection; domain-fronting and DNS-tunneling remain open to a determined adversary. | Accepted. It defeats prompt-injection callbacks and casual exfiltration — that is its job. |
| 2 | **Broad allowlist entries reopen exfiltration** (`github.com`, shared CDNs are effectively write-endpoints for an attacker). | Mitigated by Decision 7: tight shipped defaults, loud user extensions. |
| 3 | **Published sandbox-egress bypasses exist for these stacks** (e.g. Claude Code sandbox bypass research). | Mitigated by layering: wrapper + native CLI allowlist; pinned `srt` bumps pick up fixes deliberately. |
| 4 | **macOS Seatbelt (`sandbox-exec`) is deprecated-but-functional.** `srt` absorbs that platform risk, but if Apple removes it, the macOS jail story breaks. | On the register; fail-closed posture (Decision 6) means breakage refuses delegation rather than degrading silently. |
| 5 | **Env-var proxying (`HTTPS_PROXY`) is advisory only.** A process can ignore it. Never load-bearing: the OS-level egress block is what makes the proxy mandatory. | Enforced by design — the jail blocks direct egress; the proxy is the only door. |
| 6 | **Antigravity sandbox bypass via flag combo:** `--sandbox` + `--dangerously-skip-permissions` auto-approves the bypass prompt ([antigravity-cli#36](https://github.com/google-antigravity/antigravity-cli/issues/36)). | Forbidden: the delegate launcher must never emit that combination (Decision 3 note). |
| 7 | **Reads reach the provider at every tier.** No sandbox stops the model from transmitting what it can read. | Accepted and documented (outbound exposure). Known credential paths are blocked by the required `denyRead` list (Decision 5); everything else readable in-jail reaches the provider — bounded only by user guidance. |
| 8 | **The tripwire is detection, not prevention**, with known blind spots (ignored-file appends, nested ignored paths, out-of-worktree writes, and shared `.git` internals *other than* `hooks/`/`config` — objects, refs, index, … — which stay uncovered now that `hooks/` and `config` are checked). Its **tamper-resistance is also tier-dependent**: at `act-full` the wrapper is off, so a full-access delegate can overwrite the before/after snapshots with no jail escape. | Accepted; prevention is the wrapper jail — the tripwire only verifies after the fact. Its own before/after snapshot state is kept in `denyWrite`, outside the delegate's writable scope, so it cannot be regenerated to erase evidence **while the jail is on** (`consult`, `act-sandboxed`). At `act-full` (wrapper off) this tamper-resistance does not hold — the tripwire is **best-effort detection only** there, surfaced as such in the loud `act-full` banner, never sold as proof of containment. |
| 9 | **`srt` is pre-1.0.** API/config churn and its own bugs are possible. | Mitigated: exact-version pin, deliberate reviewed bumps, fail-closed on absence. |
| 10 | **Subscription-quota exhaustion by parallel Claude delegates.** | Mitigated: budget caps, shared-bucket documentation, external-CLI providers for fan-out. |

## Roadmap (complete; PR 2–4 per issue #77 all landed)

1. **PR 2 — tier plumbing + `consult` default.** Generalize the launcher to
   accept a privilege tier, defaulting to `consult`; wire only the read-only
   tier. Review semantics stay identical, but PR 2 is a **breaking change
   for environments without `srt`**: the pinned wrapper becomes a hard,
   fail-closed prerequisite for `consult` (Decisions 5–6), so installs that
   previously worked with only the provider CLIs will be refused until `srt`
   is installed. The refusal message is the migration path — it must name the
   pinned `srt` version and how to install it. PR 2 also builds the
   environment-scrubbing launcher requirement (least-privilege pass-down).
2. **PR 3 — `act-sandboxed` + write-scope tripwire.** Worktree isolation,
   wrapper write-allowlist, generalized tripwire (Decision 8).
3. **PR 4 — `act-full` gate + trust handling (landed).** Per-invocation
   approval gate (Decision 4) via `--i-approve-full-access`, the refusal path,
   the wrapper-off posture for the shipped providers (codex
   `--sandbox danger-full-access`, agy unsandboxed — the Claude provider and its
   `bypassPermissions` posture remain future/design work per Decision 1, not
   delivered here), worktree-by-default with the
   `--primary-tree` opt-out (Decision 8), the write-scope tripwire running at
   `act-full`, loud surfacing of the widened posture, and the codified
   output-as-data / least-privilege pass-down rules in the orchestrating skill.

Strictly sequential: each PR's security posture depends on the boundary the
prior one established.

## Consequences

- The `second-opinion` plugin becomes the home of a general delegation
  primitive; its existing read-only review flow is the `consult` tier —
  review semantics unchanged, but runtime prerequisites change (next
  bullet).
- `implement-cli` was not revived; its budget/depth patterns are inherited as
  design, not as code.
- A new pinned dependency (`srt`) becomes a hard prerequisite for `consult`
  delegation once PR 2 lands, extending to `act-sandboxed` when PR 3 lands —
  a **breaking change for existing installs** that today need only the
  provider CLIs. With the fail-closed posture, machines without it get an
  actionable refusal (naming the pinned version and install steps), not a
  quiet fallback.
- Every claim of safety in user-facing docs must link back to the risk
  register above rather than overstating what sandboxes and tripwires
  guarantee.

## Related Documents

### Design Context

- [Issue #77 — feat: generalize second-opinion into a privilege-tiered task-delegation tool](https://github.com/benjamcalvin/bootstraps/issues/77) — The scoping issue this ADR resolves; maintainer comments there settled Decisions 2, 5, and 6.
- [`plugins/second-opinion/README.md`](../../plugins/second-opinion/README.md) — Security model section documents the outbound-exposure reality this ADR builds on; roadmap note cross-links back to this ADR.

### Code References

- [`plugins/second-opinion/scripts/consult.sh`](../../plugins/second-opinion/scripts/consult.sh) — The delegation primitive Decision 1 generalizes; its exit-code discipline (`0/1/2/3`) is the model for Decision 6's fail-closed errors.
- [`plugins/second-opinion/skills/second-opinion/SKILL.md`](../../plugins/second-opinion/skills/second-opinion/SKILL.md) — Step 4 tripwire generalized by Decision 8; Step 3/5 mandatory-cleanup rule carried over in least-privilege pass-down; Step 5 synthesis discipline generalized by the inbound-exposure rules.
- [`implement_cli/tracking.py`, last version](https://github.com/nbramia/bootstraps/blob/d8a20e965b9e68cabe419eb2ff6ed8fc48e3f8fe/plugins/implement-cli/scripts/src/implement_cli/tracking.py) — Budget/depth-cap patterns inherited as design (not code) for the Claude provider's quota mitigations.
