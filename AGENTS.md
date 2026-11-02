# Bootstraps

A plugin marketplace of reusable skills, hooks, and project scaffolds for AI coding agents.

## Structure

```
bootstraps/
├── .agents/
│   └── plugins/
│       └── marketplace.json   # Native Codex marketplace manifest
├── .claude-plugin/
│   └── marketplace.json   # Claude Code marketplace manifest
├── docs/
│   └── adr/
│       └── NNN-short-title.md  # Architecture decision records
├── plugins/               # All distributable plugins
│   └── <plugin>/
│       ├── .codex-plugin/
│       │   └── plugin.json  # Codex metadata (when compatible)
│       ├── .claude-plugin/
│       │   └── plugin.json  # Plugin metadata
│       ├── skills/
│       │   └── <skill-name>/
│       │       ├── SKILL.md   # Skill definition (Agent Skills open standard)
│       │       └── assets/    # Templates, schemas, data files
│       ├── agents/          # Subagent definitions (Markdown with YAML frontmatter)
│       ├── hooks/           # Hook configurations (if any)
│       │   └── hooks.json
│       └── references/      # On-demand documentation
├── tools/                 # Command-line tools that are not plugins
│   └── ship/              # Merge one PR and watch its deploy
├── validate-all.sh        # Plugin validation script
└── README.md
```

## Autonomy

Run as autonomously as possible by default. Do not ask for confirmation on routine actions — just do them. This includes file edits, running tests, creating branches, committing, and pushing. Only pause to ask when something is genuinely ambiguous or destructive beyond recovery. If the user wants more oversight, they'll say so.

## Versioning

Every change to a plugin **must** include a version bump in that plugin's `.claude-plugin/plugin.json`. Follow semver: patch for fixes, minor for new features or non-breaking changes, major for breaking changes. When a plugin also has `.codex-plugin/plugin.json`, keep its version synchronized.

## Conventions

- Each plugin is self-contained under `plugins/`
- Skills follow the [Agent Skills open standard](https://agentskills.io/specification) — `SKILL.md` with YAML frontmatter
- Add a plugin to the Codex marketplace only when its complete workflow works in Codex; Claude-specific agents, hooks, and SDKs are not portable merely because the skill format is shared
- One plugin does one thing well
- Plugins can bundle skills, hooks, agents, and assets
- Self-containment forces some guidance to be duplicated across plugins. For PR scope, `bootstrap-docs`' `standards-pr-template.md` holds the authoritative wording; `draft-issue` and `refine-issue` paraphrase it. Change it there first, then re-sync the paraphrases
- Deprecating a plugin, or marking one work-in-progress, means declaring that status on every surface a user can reach it from: the plugin manifest description and keywords, the marketplace entry description and tags, the skill's frontmatter description and tags, a banner at the top of the skill body, and the README's plugin table, detail section, and install/usage examples. Keep the deprecated plugin installable and bump its version — that is how existing users receive the notice; removing the marketplace entry only strands them on a copy that never shows it. Nothing validates these copies against each other, so re-sync them by hand on every edit
- See existing plugins for schema examples

## Development

1. Create directory under `plugins/`
2. Add `.claude-plugin/plugin.json` (name, description, version, author, license)
3. Add `skills/<skill-name>/SKILL.md` and/or hook configurations
4. Add entry to `.claude-plugin/marketplace.json`
5. For Codex-compatible plugins, add `.codex-plugin/plugin.json` and an entry to `.agents/plugins/marketplace.json`
6. Validate: `./validate-all.sh`

## ship

`tools/ship/` is the source for `ship` and `ship-notice`. After merging a change there, run `tools/ship/install.sh` so the installed copy matches.
