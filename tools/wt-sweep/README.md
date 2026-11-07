# wt-sweep

`wt-sweep` lists a repo's git worktrees and local branches and says which are safe to remove. It does nothing destructive unless you pass `--apply`.

It needs bash (3.2 or newer), git, and an authenticated [`gh`](https://cli.github.com/) for PR state. `wt-sweep --help` documents the options and exit codes.

## Dry run and `--apply`

```sh
wt-sweep                      # report only, for the repo in the current directory
wt-sweep --repo-path ~/Code/x # report for another repo
wt-sweep --apply              # remove what is safe
```

A dry run does not fetch, so it reflects the last fetch and can under-report what is merged. `--apply` fetches first (and refuses to continue if the fetch fails), removes each safe worktree and its branch, deletes safe branches that have no worktree, then runs `git worktree prune`. Every candidate is rechecked just before it is removed. The report ends with a summary of what was removed or would be, and why the rest were kept.

## Safety rules

`--apply` removes a worktree or branch only when all of these hold:

- It is merged: the PR is merged into the default branch (from `gh`), or the tip is an ancestor of the default branch.
- It is clean: no uncommitted changes, and no ignored files other than build output such as `node_modules` or `dist`.
- It is unlocked and not in use: no process has its working directory inside, and no file changed within `WT_SWEEP_RECENT_MIN` minutes (default 60, `0` turns that check off).
- It has no unpushed commits, no open PR, and no commits made after its merged PR.

It never touches the main or current worktree, the default branch, or Orca-managed workspaces unless `--include-orca` is given. `--older-than N` additionally requires no commit and no file change in the last N days. Directories under `.claude/worktrees` that git does not know about are reported and left alone. If `gh` is unavailable, only ancestry counts as merged, so squash merges are kept.

Exit codes: 0 ok, 1 a removal failed or the repo is unreadable, 2 usage.

## Install

```sh
tools/wt-sweep/install.sh             # installs to ~/Code/Sync/bin
tools/wt-sweep/install.sh ~/.local/bin
```

The script copies `wt-sweep` and its tests, makes them executable and prints each step. Put the target directory on your `PATH`. It leaves other files in the target alone, including ship's.

## Tests

The tests build throwaway repos and use a stub `gh`, so they never reach GitHub or touch your worktrees:

```sh
bash tools/wt-sweep/tests/wt-sweep.test.sh
```

The last line reports pass and fail counts; the exit status is non-zero on any failure.
