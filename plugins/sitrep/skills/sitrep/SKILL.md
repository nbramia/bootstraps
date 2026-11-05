---
name: sitrep
description: >
  Report on the current long-running session: what changed since the user's last message, and
  every decision, question or task waiting on them, each with enough context to answer from
  that message alone, without scrolling the transcript. Use for "/sitrep", "what's waiting on
  me", "what do you need from me", "what did I miss", "where are we", "remind me what the
  question was", "I have no idea what you're asking me", or when the user returns to a session
  after hours away. Only reports on this session.
---

# Sitrep

The user comes back to a session that has run for hours. The agent's latest message is often a terse reminder ("waiting on your decision on the architecture question") of something explained far up the transcript. This skill replaces that with a report they can act on without scrolling.

The skill only reports. Don't start, stop or redirect work, don't message subagents, and don't act on a pending decision. Running subagents keep running.

## 1. Build the digest

Run this, then read the whole file it names. If it's long, read in pieces until you reach the `END OF DIGEST` line. Don't summarize from a partial read, and don't work from memory: the session may have compacted, so what you recall can be missing or wrong.

```bash
python3 "${CLAUDE_SKILL_DIR}/digest.py"
```

The digest holds:

- The user's last message, and what they were replying to. Your `/sitrep` turn itself is already excluded.
- `EARLIER ASKS`: snippets from before that cutoff, each with the next message the user sent. These are candidates: every message that ended a turn, plus any that read like an ask. Many are noise. That next message may be unrelated, so judge whether it answers the ask.
- Every agent message since the cutoff, complete, including question-tool prompts and pings.
- One line per subagent report since the cutoff. Numbers in brackets are transcript record numbers.

To pull more from anywhere in the session, including before a compaction:

```bash
python3 "${CLAUDE_SKILL_DIR}/digest.py" --show 1064        # one record in full (or 1064-1070)
python3 "${CLAUDE_SKILL_DIR}/digest.py" --grep 'cache policy' # search agent, user and subagent text
```

## 2. Work out what is still open

Go through the window and `EARLIER ASKS`. List everything that needs the user: a decision, a question, an approval, or a task only they can do (a command to run, a login, a credit refill).

Then settle each one:

- **Answered?** An item is closed only if the user's reply addressed it, or a later agent message records it as decided, done or moot. "Please continue" or "what else needs to happen?" answers nothing, so the item stays open. Partial answers close only the parts answered ("5. yes 4. not going to" leaves any others open).
- **Superseded?** A later message can restate or change the ask. Report the latest version.
- **Is it theirs?** "Still waiting on" usually means CI, a reviewer or a builder. That goes in the running list, not the waiting-on-you list.
- **Moved to an issue?** If they asked for something to be filed as an issue, it's closed here. An issue assigned to them that they haven't been told about is still open.
- **Past its deadline?** Keep it if the work is still undone, say the deadline passed, and restate what's left to decide. Don't repeat a recommendation that depended on that date.
- **Still true?** If a read-only check would settle whether it's open (does that stray directory still exist, has that PR merged), run it. Keep it to a few quick checks. If one can't run, for example on an expired login, say it's unverified.

Sort what remains. If the work can't move or a choice is theirs to make, it's a numbered item. If the agent already went ahead on a default ("say if you want otherwise"), or only offered something optional ("I can pull that tomorrow", "feel free to delete it"), it goes under `Your call, no rush`.

**Look for work that went quiet.** An agent that dies or gets dropped leaves no message. Compare the first and last status lists in the window: anything that fell off with no report of finishing goes under `Running without you`, marked as possibly stalled.

**Trace every shorthand reference to its source.** When a message says "the architecture question" or "the two decisions above", find the original with `--grep` or `--show` before writing the item. The options, tradeoffs and recommendation live there. If you can't find them, say what's missing. Don't reconstruct options from guesswork.

Agents' subagent reports are often where the detail sits. Use `--show` on them when an item needs it.

## 3. Write the report

Write for someone who remembers nothing of this session. Define every PR number, issue, agent name or coined term in plain words, or leave it out ("the billing webhook fix, PR #140"; not "#140", and never an agent's name like "build-60").

```markdown
**N things waiting on you.** [Then one sentence on state: "Work continues on X" or "Everything is stopped until you answer 1."]

## Waiting on you

**1. [The question, in plain words]**
[1-3 sentences: what this is and why it came up.]
- **A: [option]**: what happens if they pick it.
- **B: [option]**: what happens if they pick it.

Recommendation: [the agent's, as stated in the transcript; if you are adding your own, say so.]
Until you answer: [what's blocked]. Asked [day, time].

**2. [Task only they can do]**
[Why it needs them, and the exact command or steps.]
Until it's done: [what's blocked]. Asked [day, time].

## Your call, no rush
3. [One or two sentences: what the agent did or offered, and how to change or take it.]

## Since your last message ([time], [N] hours ago)
- [What got done, what changed, what failed: 3-8 bullets, by outcome, not chronology.]

## Running without you
- [In-flight work and what it's waiting on, one line each. Possibly stalled work, marked. If nothing is running, say so.]
```

- Put items that block the most work first. Keep numbering continuous so they can reply "1. A, 2. done".
- The user should be able to decide on item 1 from item 1. Length goes to the decisions; keep the progress section short. Give numbers where they matter (test counts rarely do, data volumes and costs often do).
- Cut narration of process: agents repeating themselves, leftover notices, routine rebases, and the back-and-forth of review rounds. Report what came out of them.
- If nothing is waiting on them, open with "Nothing is waiting on you" and skip that section. Skip `Your call, no rush` when it's empty.
- Report failures and stalls plainly: an agent that died, an API error that ended the last turn, work stuck for hours. If work stopped before it finished, make restarting it item 1. A session that finished its work has nothing to restart, so just say it's done.
- Don't include the digest path, record numbers or how you built this.

End your turn after the report. The next move is theirs.
