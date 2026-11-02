@AGENTS.md

## Claude Code Specifics

### Install

```bash
/plugin marketplace add nbramia/bootstraps
/plugin install bootstrap-docs@bootstraps
```

### Validate and test

```bash
./validate-all.sh                          # Validate all plugins
claude plugin validate plugins/<name>      # Validate one plugin
claude --plugin-dir plugins/<name>         # Test locally
claude --debug                             # Debug hook matching
```

### Hooks

Hooks use Claude Code JSON format in `hooks/hooks.json` (handler types: command, http, prompt, agent).
