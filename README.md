# Bootstraps

A cross-compatible Claude Code, OpenAI Codex, and Pi collection of reusable skills, hooks, and project scaffolds.

This repo began as a fork of [benjamcalvin/bootstraps](https://github.com/benjamcalvin/bootstraps).

## Install in Claude Code

Add the marketplace to Claude Code:

```
/plugin marketplace add nbramia/bootstraps
```

## Browse Plugins

List available plugins:

```
/plugin marketplace list
```

Or open the interactive plugin manager:

```
/plugin
```

Navigate to the **Discover** tab to browse plugins from this marketplace.

## Install in Codex

Add the marketplace to Codex CLI:

```sh
codex plugin marketplace add nbramia/bootstraps
```

Open the plugin browser with `/plugins`, install a plugin from the **Bootstraps** marketplace, and start a new session so Codex loads its skills.

The Codex marketplace currently includes `bootstrap-docs`, `implement-lifecycle`, and `issue-management`. The other plugins depend on Claude Code-specific hooks, worktree behavior, agent teams, or the Claude Agent SDK and remain available only through Claude Code.

## Install implement-lifecycle in Pi

Pi can install the plugin directory as a local package. From a checkout of this repository, run:

```sh
pi install ./plugins/implement-lifecycle
```

This package exposes its `skills/` directory through `package.json`; restart Pi, then use `/skill:implement #42`. The skill delegates to subagents, so also install [`pi-subagents`](https://github.com/nicobailon/pi-subagents). It is a user-managed prerequisite, not a bundled dependency.

## Install a Plugin in Claude Code

```
/plugin install bootstrap-docs@bootstraps
/plugin install implement-lifecycle@bootstraps
/plugin install issue-management@bootstraps
/plugin install bootstrap-worktrees@bootstraps
/plugin install stop-guard@bootstraps
/plugin install second-opinion@bootstraps

# Session report
/plugin install sitrep@bootstraps
```


Choose a scope when prompted:
- **user** (default) — available in all your projects
- **project** — available to anyone working on the current project
- **local** — only for you in the current project

## Use a Plugin

### Claude Code

Invoke a plugin's skill as a slash command:

```
/bootstrap-docs
/implement #42
```

Some skills accept arguments:

```
/bootstrap-docs adr
/implement #42
/implement fix the login bug
/bootstrap-worktrees
/draft-issue add user avatar support
/cleanup-issue #42
/refine-issue #42
/second-opinion staged
```

### Codex

Invoke the currently published Codex plugins' skills with their plugin-qualified names:

```
$bootstrap-docs:bootstrap-docs
$implement-lifecycle:implement #42
$issue-management:draft-issue add user avatar support
$issue-management:cleanup-issue #42
$issue-management:refine-issue #42
```

## Update Claude Code Plugins

```
/plugin marketplace update bootstraps
```

## Uninstall a Claude Code Plugin

```
/plugin uninstall bootstrap-docs@bootstraps
/plugin uninstall implement-lifecycle@bootstraps
/plugin uninstall issue-management@bootstraps
/plugin uninstall bootstrap-worktrees@bootstraps
/plugin uninstall stop-guard@bootstraps
/plugin uninstall second-opinion@bootstraps
/plugin uninstall sitrep@bootstraps
```

## Available Plugins

| Plugin | Claude Code | Codex | Pi | Description |
|--------|-------------|-------|----|-------------|
| **bootstrap-docs** | Yes | Yes | No | Set up a comprehensive, AI-readable documentation strategy in any project. Creates AGENTS.md, specs, ADRs, guides, plans, standards, and research templates. |
| **bootstrap-worktrees** | Yes | No | No | Set up project-agnostic worktree isolation with per-worktree ports, Docker Compose projects, and config files. Discovers services and generates create/remove scripts plus Claude Code hooks. |
| **implement-lifecycle** | Yes | Yes | Yes | Take a code change from request to merged with subagents, adversarial review from another model family, real verification and the `ship` command. Pi delegation requires `pi-subagents`. |
| **issue-management** | Yes | Yes | No | Draft, clean up, and refine GitHub issues — optimized for AI agent consumption. |
| **stop-guard** | Yes | No | No | Stop hook that evaluates task completion via Gemini CLI and blocks premature stops. Opt-in per session via activation marker. |
| **second-opinion** | Yes | No | No | Consult external AI CLIs (Codex, Antigravity) headlessly for an independent, read-only second-opinion code review of your changes. |
| **sitrep** | Yes | No | No | Report what changed in a long-running session and every decision waiting on you, with enough context to answer without reading the transcript. |

### implement-lifecycle

One skill: `/implement` (`$implement-lifecycle:implement` in Codex, `/skill:implement` in Pi). You orchestrate and keep the decisions. A subagent builds the change on its own branch and opens a PR, a different model family tries to break it, you judge the findings and record them in one PR comment, you run the change for real, and `ship <pr>` lands it.

It needs [`ship`](tools/ship/README.md) on your `PATH`. `skills/implement/agents/openai.yaml` is optional Codex metadata for presentation and invocation policy.

### bootstrap-worktrees

Single-skill plugin for project-agnostic worktree isolation.

| Skill | Description |
|-------|-------------|
| `/bootstrap-worktrees` | Discover services in a project, assign per-worktree port offsets, generate `scripts/create-worktree.sh` and `scripts/remove-worktree.sh`, wire up Docker Compose project isolation, and register Claude Code hooks so new sessions land in isolated environments. |

### issue-management

Provides 3 skills for GitHub issue quality:

| Skill | Description |
|-------|-------------|
| `/draft-issue` | Create well-structured GitHub issues with testable acceptance criteria, optimized for `/implement` consumption. |
| `/cleanup-issue` | Fix formatting, fill missing sections, and clarify ambiguity in existing issues. |
| `/refine-issue` | Deepen an issue with codebase research — sharpen acceptance criteria, add implementation hints, decompose into sub-tasks. |

### stop-guard

A Stop hook — no skills to invoke. Once installed, it activates when any session transcript contains `<!-- stop-guard:active -->`.

**Requires:** [Gemini CLI](https://github.com/google-gemini/gemini-cli) (`npm install -g @google/gemini-cli`), [jq](https://jqlang.github.io/jq/)

**How it works:** When Claude tries to stop, the hook calls Gemini to independently evaluate whether the task is complete. If incomplete, it blocks the stop and tells Claude what to finish. If complete (or if human input is needed), it allows the stop.

**Activation:** Include `<!-- stop-guard:active -->` in a skill's output or type it directly in conversation. Optionally provide context:

```
<!-- stop-guard:context {"task": "implement feature X", "criteria": ["tests pass"]} -->
```

**Safety:** Opt-in per session, max 3 continuations (configurable), fail-open on any error, 60s timeout.

**Configuration** (optional): `~/.config/stop-guard/config.json`

```json
{"max_continuations": 3, "model": "gemini-3-flash-preview"}
```

**Testing:** Run the evaluator against any session without triggering the hook:

```
./plugins/stop-guard/hooks/test-stop-guard.sh ~/.claude/projects/<project>/<session>.jsonl
```

See [stop-guard/README.md](plugins/stop-guard/README.md) for full documentation.

### second-opinion

Single-skill plugin that consults external AI CLIs for an independent code review.

| Skill | Description |
|-------|-------------|
| `/second-opinion` | Fan out a review of the current changes to every supported external CLI installed (OpenAI Codex, Google Antigravity), run them read-only in parallel, cross-check findings, and present one consolidated review with per-provider attribution and consensus items first. Accepts an optional scope (`staged`, a PR number, or a git range) and/or a provider name (`codex` / `antigravity`); defaults to branch-vs-main across all available providers. Only reports — never applies fixes. |

See [second-opinion/README.md](plugins/second-opinion/README.md) for full documentation.

### sitrep

| Skill | Description |
|-------|-------------|
| `/sitrep` | Read the session transcript, including anything lost to compaction, and report what changed since your last message and everything waiting on you. Each decision carries enough context to answer from that message alone. It only reports, and running subagents keep running. |

## Tools

### ship

[`tools/ship`](tools/ship/README.md) is a command-line tool, not a plugin. It merges one PR: it pins the head, waits for checks, squash-merges, confirms the merge, and watches the deploy in the background. `/implement` uses it to land changes.

## License

MIT
