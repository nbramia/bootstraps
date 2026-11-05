#!/usr/bin/env python3
"""Digest a Claude Code session transcript for /sitrep.

Writes what the agent told the user since their last message to a temp file, plus
the pointers needed to trace an open question back to where it was first asked.
Output goes to a file because it can run past the Bash tool's output limit, and
a truncated digest would silently lose decisions. It prints the path and size.

Usage:
  digest.py                      current session, drops the /sitrep turn itself
  digest.py --file PATH          any transcript, last human message is the cutoff
  digest.py --file PATH --upto N pretend the transcript ends at line N
  digest.py [--file PATH] --show N[-M]    print records N..M in full, to stdout
  digest.py [--file PATH] --grep REGEX    search the whole session, to stdout
"""
import argparse
from contextlib import redirect_stdout
import glob
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

NOT_HUMAN = (
    "Another Claude session sent", "<teammate-message", "<task-notification",
    "<agent-message", "<local-command-", "<system-reminder", "Base directory",
    "<bash-", "Caveat:", "[Request interrupted", "<user-prompt-submit-hook",
)
ASK = re.compile(
    r"\b(your (call|decision|input|approval|answer|go-ahead)|waiting (on|for) you"
    r"|need(s)? (you|your|from you)|only you can|up to you|do you want|would you like"
    r"|should (I|we)\b|want me to|let me know|blocked on you|decisions? for you"
    r"|decisions? need|for you to|your ok(ay)?|if you want|feel free|ask me|tell me"
    r"|say (so|if)|please (open|run|check|confirm|review|delete|tell|reply|approve|look|try|merge)"
    r"|you('ll| will)? (need to|have to|can|could|should|may want))\b|\?(\s|$)",
    re.I,
)
TURN_END_GAP_SECS = 1800


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            b.get("text", "") for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def find_transcript(session_id):
    roots = [os.environ.get("CLAUDE_CONFIG_DIR"), os.path.expanduser("~/.claude")]
    for root in filter(None, roots):
        hits = glob.glob(os.path.join(glob.escape(root), "projects", "*", session_id + ".jsonl"))
        if hits:
            return hits[0]
    return None


def human_record(n, d):
    """Return an event if this record is something the user typed, else None."""
    if d.get("type") == "attachment":
        a = d.get("attachment") or {}
        if a.get("type") != "queued_command" or a.get("commandMode") not in (None, "prompt"):
            return None
        if (a.get("origin") or {}).get("kind") not in (None, "human") or a.get("isMeta"):
            return None
        text = text_of(a.get("prompt"))
    elif d.get("type") == "user":
        if d.get("isMeta") or d.get("isCompactSummary") or d.get("isSidechain"):
            return None
        if (d.get("origin") or {}).get("kind") not in (None, "human"):
            return None
        content = (d.get("message") or {}).get("content")
        if isinstance(content, list) and any(
            isinstance(b, dict) and b.get("type") == "tool_result" for b in content
        ):
            return None
        text = text_of(content)
    else:
        return None
    stripped = text.lstrip()
    if not stripped or stripped.startswith(NOT_HUMAN):
        return None
    return {"n": n, "ts": d.get("timestamp", ""), "kind": "human", "text": stripped}


def agent_events(n, d):
    """Events from a main-thread assistant record: text, questions, pushes."""
    if d.get("type") != "assistant" or d.get("isSidechain"):
        return
    content = (d.get("message") or {}).get("content") or []
    if isinstance(content, str):
        content = [{"type": "text", "text": content}]
    ts = d.get("timestamp", "")
    for b in content if isinstance(content, list) else []:
        if b.get("type") == "text" and b.get("text", "").strip():
            kind = "error" if d.get("isApiErrorMessage") else "said"
            yield {"n": n, "ts": ts, "kind": kind, "text": b["text"].strip()}
        elif b.get("type") == "tool_use":
            name, inp = b.get("name", ""), b.get("input") or {}
            if name == "AskUserQuestion":
                yield {"n": n, "ts": ts, "kind": "asked", "id": b.get("id"),
                       "text": format_questions(inp)}
            elif name == "PushNotification":
                yield {"n": n, "ts": ts, "kind": "pinged",
                       "text": str(inp.get("message") or inp.get("command"))[:600]}


def format_questions(inp):
    out = []
    for q in inp.get("questions") or []:
        opts = "; ".join(
            f"{o.get('label')} ({o.get('description')})" for o in q.get("options") or []
        )
        out.append(f"{q.get('question')} Options: {opts}")
    return "\n".join(out)


def teammate_events(n, d):
    """One line per subagent report that reached the main agent."""
    if d.get("type") == "attachment":
        a = d.get("attachment") or {}
        text = text_of(a.get("prompt")) if a.get("type") == "queued_command" else ""
    elif d.get("type") == "user" and not d.get("isSidechain"):
        text = text_of((d.get("message") or {}).get("content"))
    else:
        return
    ts = d.get("timestamp", "")
    for m in re.finditer(r'<teammate-message teammate_id="([^"]+)"([^>]*)>(.*?)</teammate-message>', text, re.S):
        who, attrs, body = m.group(1), m.group(2), m.group(3).strip()
        if '"idle_notification"' in body[:80] or '"shutdown' in body[:80]:
            continue
        s = re.search(r'summary="([^"]*)"', attrs)
        yield {"n": n, "ts": ts, "kind": "agent", "who": who,
               "text": s.group(1) if s else " ".join(body.split())[:200]}
    for m in re.finditer(r'<agent-message from="([^"]+)">(.*?)</agent-message>', text, re.S):
        yield {"n": n, "ts": ts, "kind": "agent", "who": m.group(1),
               "text": " ".join(m.group(2).split())[:200]}
    if "<task-notification" in text:
        s = re.search(r"<summary>(.*?)</summary>", text, re.S)
        st = re.search(r"<status>(.*?)</status>", text, re.S)
        if s:
            yield {"n": n, "ts": ts, "kind": "agent", "who": "task",
                   "text": f"[{st.group(1) if st else '?'}] " + " ".join(s.group(1).split())[:200]}


def load(path, upto=None):
    """Read the transcript into events. Keeps line numbers, drops everything else."""
    events, answered, local_cmd = [], set(), []
    seen = set()
    with open(path, errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            if upto and n > upto:
                break
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            uuid = d.get("uuid")
            if uuid and uuid in seen:
                continue
            if uuid:
                seen.add(uuid)
            h = human_record(n, d)
            if h:
                events.append(h)
                continue
            events.extend(agent_events(n, d))
            events.extend(teammate_events(n, d))
            if d.get("type") == "system" and d.get("subtype") == "local_command":
                local_cmd.append(n)
            if d.get("type") == "user":
                content = (d.get("message") or {}).get("content")
                if isinstance(content, str) and content.lstrip().startswith("<local-command-stdout"):
                    local_cmd.append(n)
                elif isinstance(content, list):
                    for b in content:
                        if isinstance(b, dict) and b.get("type") == "tool_result":
                            answered.add(b.get("tool_use_id"))
    # A <command-name> turn followed by local stdout is a client command like
    # /clear or /usage, which the agent never saw. It isn't a message to the agent.
    def is_local(e):
        return e["kind"] == "human" and e["text"].startswith("<command-name>") and any(
            0 < x - e["n"] <= 3 for x in local_cmd
        )
    events = [e for e in events if not is_local(e)]
    for e in events:
        if e["kind"] == "asked":
            e["answered"] = e.get("id") in answered
    return events


def stamp(ts):
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return ts
    return dt.astimezone().strftime("%a %b %-d %-I:%M %p")


def ago(ts, now):
    try:
        secs = (now - datetime.fromisoformat(ts.replace("Z", "+00:00"))).total_seconds()
    except ValueError:
        return "?"
    h = secs / 3600
    return f"{h:.1f}h ago" if h >= 1 else f"{int(secs / 60)}m ago"


def is_turn_end(events, i):
    """True if the agent went quiet after events[i]: the user spoke next, or nothing came for a while."""
    if i + 1 >= len(events) or events[i + 1]["kind"] == "human":
        return True
    try:
        a, b = (datetime.fromisoformat(events[j]["ts"].replace("Z", "+00:00")) for j in (i, i + 1))
    except ValueError:
        return False
    return (b - a).total_seconds() >= TURN_END_GAP_SECS


def clean_human(text):
    m = re.match(r"<command-name>(.*?)</command-name>.*?(?:<command-args>(.*?)</command-args>)?\s*$", text, re.S)
    return f"{m.group(1)} {m.group(2) or ''}".strip() if m else text


def show(path, spec):
    a, _, b = spec.partition("-")
    a, b = int(a), int(b or a)
    with open(path, errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            if n > b:
                break
            if n < a:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            for e in list(agent_events(n, d)) or []:
                print(f"[{n}] {e['kind']}: {e['text']}")
            content = (d.get("message") or {}).get("content")
            extra = ""
            if d.get("type") == "user":
                extra = text_of(content)
            elif d.get("type") == "attachment":
                extra = text_of((d.get("attachment") or {}).get("prompt"))
            if extra.strip():
                print(f"[{n}] incoming: {extra}")


def grep(events, pattern):
    rx = re.compile(pattern, re.I)
    for e in events:
        if rx.search(e["text"]):
            who = e.get("who", e["kind"])
            print(f"[{e['n']}] {stamp(e['ts'])} {who}: {' '.join(e['text'].split())[:700]}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file")
    ap.add_argument("--upto", type=int)
    ap.add_argument("--show")
    ap.add_argument("--grep")
    args = ap.parse_args()

    live = not args.file
    path = args.file
    if live:
        sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
        path = find_transcript(sid) if sid else None
        if not path:
            sys.exit(f"sitrep: no transcript found for session {sid!r}; pass --file")

    if args.show:
        return show(path, args.show)
    events = load(path, args.upto)
    if args.grep:
        return grep(events, args.grep)

    humans = [i for i, e in enumerate(events) if e["kind"] == "human"]
    if live and humans:
        events = events[:humans.pop()]  # the last human turn is this invocation
    now = datetime.now(timezone.utc)
    name = os.path.basename(path).removesuffix(".jsonl")
    fd, out_path = tempfile.mkstemp(prefix=f"sitrep-{name}-", suffix=".txt")  # private to this user
    with os.fdopen(fd, "w") as out, redirect_stdout(out):
        write_digest(path, events, humans, now)
    with open(out_path) as fh:
        lines = sum(1 for _ in fh)
    print(f"{out_path}\n{os.path.getsize(out_path)} bytes, {lines} lines. Read all of it; the last line is END OF DIGEST.")


def write_digest(path, events, humans, now):
    print(f"TRANSCRIPT {path}")
    print(f"NOW {now.astimezone().strftime('%a %b %-d %-I:%M %p')}")
    if not humans:
        cut = -1
        print("\nUSER'S LAST MESSAGE: none found in this transcript; covering all of it.")
    else:
        cut = humans[-1]
        last = events[cut]
        print(f"\nUSER'S LAST MESSAGE [{last['n']}] {stamp(last['ts'])} ({ago(last['ts'], now)}):")
        print(clean_human(last["text"])[:1500])

        # What they were replying to: often only partly answered ("5. yes 4. not going to").
        # Agents keep talking after asking, so take the last ask in that turn too. Skip
        # back over messages they sent in a row, which leave no agent text between them.
        turn, end = [], cut
        for h in reversed(humans[:-1] + [-1]):
            turn = [e for e in events[h + 1:end] if e["kind"] in ("said", "asked")]
            if turn:
                break
            end = h
        picks = [e for e in turn if e["kind"] == "asked" or ASK.search(e["text"])][-1:] + turn[-1:]
        seen_picks = []
        for e in picks:
            if e not in seen_picks:
                seen_picks.append(e)
                print(f"\nWHAT THE USER WAS REPLYING TO [{e['n']}] {stamp(e['ts'])}:")
                print(e["text"])

        # Anything before the cutoff that may still be open. A later reminder may
        # only name these. Every turn-ending message is included whatever its wording,
        # because asks sit there and no keyword list catches them all.
        asks = []
        for i, e in enumerate(events[:cut]):
            if e["kind"] not in ("said", "asked"):
                continue
            hit = ASK.search(e["text"])
            ended = is_turn_end(events, i)
            if e["kind"] != "asked" and not hit and not ended:
                continue
            if ended or not hit:
                snippet = e["text"][-400:]
            else:
                snippet = e["text"][max(0, hit.start() - 120):hit.start() + 200]
            replied = next((h for h in humans if h > i), None)
            asks.append((e, " ".join(snippet.split()), events[replied] if replied is not None else None))
        print(f"\nEARLIER ASKS ({len(asks)} candidates, snippets only; --show N for the full text):")
        for e, snippet, r in asks:
            reply = " ".join(clean_human(r["text"]).split())[:90] if r else "(none)"
            print(f"[{e['n']}] {stamp(e['ts'])}: ...{snippet}...\n    next reply: {reply}")

    window = events[cut + 1:]
    said = [e for e in window if e["kind"] != "agent"]
    agents = [e for e in window if e["kind"] == "agent"]
    print(f"\nSINCE THEN: {len(said)} agent messages, {len(agents)} subagent reports.")
    print("\n=== AGENT MESSAGES TO THE USER (complete, oldest first) ===")
    for e in said:
        tag = {"said": "", "asked": "QUESTION TOOL ", "pinged": "PINGED ", "error": "API ERROR "}[e["kind"]]
        if e["kind"] == "asked":
            tag += "(answered) " if e.get("answered") else "(UNANSWERED) "
        print(f"\n[{e['n']}] {stamp(e['ts'])} {tag}\n{e['text']}")
    print("\n=== SUBAGENT REPORTS TO THE AGENT (one line each; --show N for the full text) ===")
    for e in agents:
        print(f"[{e['n']}] {stamp(e['ts'])} {e['who']}: {e['text']}")
    print("\nEND OF DIGEST")


if __name__ == "__main__":
    main()
