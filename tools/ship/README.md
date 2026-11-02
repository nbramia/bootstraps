# ship

`ship <pr>` merges one GitHub PR. It pins the head SHA, waits for required checks, stops on any red check, squash-merges with `--match-head-commit`, confirms the merge through the API and deletes the remote branch. It then returns the merge SHA while a detached process watches the deploy and records the result. Rerunning is safe if it dies before the merge.

It needs bash (3.2 or newer) and an authenticated [`gh`](https://cli.github.com/).

`ship --help` documents the options, environment variables and exit codes. Callers should branch on the exit code and on the `RESULT` line. `ship --status <run-id>` reports a run, including its deploy.

`ship-notice` is a Claude Code hook. It tells a session about a failed deploy or a dead ship run, once per session, until someone runs `ship --status <run-id>`. It prints nothing when there is nothing to report.

## Install

```sh
tools/ship/install.sh             # installs to ~/Code/Sync/bin
tools/ship/install.sh ~/.local/bin
```

The script copies `ship`, `ship-notice` and `tests/`, makes them executable and prints each step. Put the target directory on your `PATH`. It leaves other files in the target alone, including `ship.conf`.

## Per-repo config

`ship` reads `~/Code/Sync/bin/ship.conf`, or the file named by `SHIP_CONF`. Copy [`ship.conf.example`](ship.conf.example) to set which deploys to watch and which checks are advisory for a repo. Without a config, `ship` discovers deploys itself.

## Enable the hook

Add this to `~/.claude/settings.json`, using your install path:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "$HOME/Code/Sync/bin/ship-notice session" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "$HOME/Code/Sync/bin/ship-notice prompt" }] }
    ],
    "PostToolUse": [
      { "matcher": "Agent|Task", "hooks": [{ "type": "command", "command": "$HOME/Code/Sync/bin/ship-notice agent" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "$HOME/Code/Sync/bin/ship-notice stop" }] }
    ]
  }
}
```

## Tests

`tests/ship.test.sh` runs against a stubbed `gh` and never reaches GitHub:

```sh
bash tools/ship/tests/ship.test.sh
```

`tests/live.test.sh` creates and deletes a real private GitHub repo and needs a second machine over ssh. Set `SHIP_LIVE_OWNER` and `SHIP_LIVE_HOST` before running it.
