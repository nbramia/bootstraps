---
name: implement
description: Take a code change from request to merged with subagents, adversarial review from another model family, real verification and the ship command. Use for /implement, "implement this", "build this", "fix this and merge it", or when working from a /draft-issue issue.
---

# Implement

You orchestrate. Delegate the work, keep the decisions.

1. **Build.** Give a subagent the goal and context, on its own branch in its own worktree: Sonnet for routine work, Opus for hard or risky work. It may spawn its own subagents. It opens a PR.
2. **Refute.** Have another model family try to break the change. Use Codex when available (`codex exec --sandbox read-only --skip-git-repo-check -C <worktree> "<brief>" </dev/null`, in the background; without closing stdin it hangs), otherwise a different-model subagent. Ask for real defects, not style: wrong behavior, missed cases, tests that would pass on broken code, data loss, security. For auth or secrets, also run `/security-review`.
3. **Decide.** You judge each finding against the code, because reviewers are often wrong. Send real defects back to the builder. Stop after two rounds that aren't converging, and tell the user what remains. Scale to the change: a one-line fix needs one quick read, not rounds.
4. **Record.** Post one PR comment saying who reviewed it, what was found, and what you decided. Unrecorded review looks the same as no review.
5. **Verify.** Run the change for real, the way a user would meet it, including what it affects up and down the line. This step catches the most bugs, so don't skip it. Green tests alone don't count. If docs describe the behavior, make sure they still match.
6. **Land.** `ship <pr>`. It waits for checks, merges, deletes the branch and returns with the merge SHA while a detached watcher records the deploy. Never merge on red, on any branch, including integration branches. If it stops on a failure, find out why before trying again.
   - Run it in the background only from the main thread. A subagent's background commands die when it ends, so a subagent waits for the result. If `ship` dies while waiting nothing has happened, and rerunning is safe.
   - The subagent passes back the verbatim `RESULT` line. The parent runs `ship --status <run-id>` (the id is in that line), which also reports the deploy, and does not trust a summary.

Run long waits in the background and report status in the thread without being asked.
