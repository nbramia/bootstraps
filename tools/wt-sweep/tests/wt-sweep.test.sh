#!/usr/bin/env bash
# Tests for wt-sweep against throwaway repos and a stubbed gh. No network.
# Bash 3.2 compatible. WT_SWEEP_BIN points the suite at another copy of the script.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SWEEP=${WT_SWEEP_BIN:-$HERE/../wt-sweep}
PASS=0 FAIL=0 FAILED_NAMES="" OUT="" RC=0
US=$'\037'

export PATH="$HERE/wt-sweep-stub:$PATH"
# Nothing here may reach GitHub: refuse to run unless gh is the stub.
[ "$(command -v gh)" = "$HERE/wt-sweep-stub/gh" ] || { echo "abort: gh is not the stub"; exit 99; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wtsweeptest.XXXXXX"); ROOT=$(cd "$ROOT" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
# A private HOME keeps the real Orca and git config out of the picture.
export HOME=$ROOT/home; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
# Inherited repo-selecting variables (a git hook, a caller with GIT_DIR set) must not reach a real repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export WT_SWEEP_RECENT_MIN=0 WT_SWEEP_ORCA_BIN=$ROOT/no-such-orca

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $1"; echo "not ok: $1: $2"; [ -z "$OUT" ] || sed 's/^/    /' <<<"$OUT"; }
has() { case "$OUT" in *"$2"*) ok ;; *) bad "$1" "output lacks [$2]" ;; esac; }
hasnt() { case "$OUT" in *"$2"*) bad "$1" "output has [$2]" ;; *) ok ;; esac; }
rc_is() { if [ "$2" -eq "$3" ]; then ok; else bad "$1" "exit $2, wanted $3"; fi; }
dir_exists() { if [ -d "$2" ]; then ok; else bad "$1" "missing directory $2"; fi; }
dir_gone() { if [ -d "$2" ]; then bad "$1" "directory still there: $2"; else ok; fi; }
branch_exists() { if git -C "$W/repo" show-ref --verify --quiet "refs/heads/$2"; then ok; else bad "$1" "branch $2 is gone"; fi; }
branch_gone() { if git -C "$W/repo" show-ref --verify --quiet "refs/heads/$2"; then bad "$1" "branch $2 still exists"; else ok; fi; }

run() { # args...: run wt-sweep from a neutral directory against $W/repo
  OUT=$(cd "$W" && "$SWEEP" --repo-path "$W/repo" "$@" 2>&1); RC=$?
}
commit() { # dir file
  echo "$2 $RANDOM" >"$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q -m "add $2"
}
pr() { # branch state oid number base: append one PR row to the stub
  printf '%s%s%s%s%s%s%s%s%s\n' "$1" "$US" "$2" "$US" "$3" "$US" "$4" "$US" "$5" >>"$STUB/prs"
}

# world NAME: bare origin, a clone with main pushed, an empty stub state.
world() {
  W=$ROOT/$1; STUB=$W/stub; export STUB
  mkdir -p "$STUB"; : >"$STUB/prs"
  printf 'owner/proj%smain\n' "$US" >"$STUB/repo"
  git init -q --bare -b main "$W/origin"
  git init -q -b main "$W/seed"; commit "$W/seed" base.txt
  git -C "$W/seed" remote add origin "$W/origin"; git -C "$W/seed" push -q origin main
  git clone -q "$W/origin" "$W/repo"
  mkdir -p "$W/wts"
}
# branch NAME [worktree]: new branch off main with one pushed commit; prints its tip.
mkbranch() {
  git -C "$W/repo" branch -q "$1" main
  if [ "${2:-}" = wt ]; then git -C "$W/repo" worktree add -q "$W/wts/$1" "$1"; commit "$W/wts/$1" "$1.txt"
  else git -C "$W/repo" checkout -q "$1"; commit "$W/repo" "$1.txt"; git -C "$W/repo" checkout -q main; fi
  git -C "$W/repo" push -q origin "$1"
}
tip() { git -C "$W/repo" rev-parse "refs/heads/$1"; }

# --- dry run and --apply over a mixed repo ----------------------------------
build_mixed() {
  world "$1"
  # Squash-merged on GitHub: the PR head is the branch tip, but main lacks the commit.
  mkbranch merged wt;   pr merged MERGED "$(tip merged)" 1 main
  # Merged and pushed, but a branch with no worktree.
  mkbranch merged-nowt; pr merged-nowt MERGED "$(tip merged-nowt)" 2 main
  # Fully merged by ancestry, no PR record at all.
  git -C "$W/repo" branch -q anc main
  # Merged PR but the worktree has an untracked file.
  mkbranch dirty wt;    pr dirty MERGED "$(tip dirty)" 3 main; echo scratch >"$W/wts/dirty/notes.txt"
  # Local commit never pushed, no PR.
  mkbranch unpushed wt; commit "$W/wts/unpushed" extra.txt
  # Pushed but unmerged, with an open PR.
  mkbranch openpr wt;   pr openpr OPEN "$(tip openpr)" 4 main
  # Pushed but unmerged, no PR.
  mkbranch wip wt
  # Pushed commit after a merged PR: the extra commit would be lost.
  mkbranch after wt;    pr after MERGED "$(tip after)" 5 main; commit "$W/wts/after" more.txt; git -C "$W/wts/after" push -q origin after
}
snapshot() { # prints every worktree dir and local branch, for before/after comparison
  ls "$W/wts" | sort; git -C "$W/repo" for-each-ref refs/heads --format='%(refname:short) %(objectname)' | sort
}

build_mixed dry
BEFORE=$(snapshot)
run
rc_is dry/rc "$RC" 0
OUT_DRY=$OUT
has dry/header "dry run"
has dry/lists-merged-worktree "REMOVE $W/wts/merged [merged]: merged via PR#1"
has dry/lists-merged-branch "REMOVE merged-nowt: merged via PR#2"
has dry/lists-ancestor-branch "REMOVE anc: merged via ancestor"
has dry/summary-would "would remove 1"
[ "$(snapshot)" = "$BEFORE" ] && ok || bad dry/changes-nothing "worktrees or branches changed in a dry run"
dir_exists dry/merged-still-there "$W/wts/merged"
branch_exists dry/merged-branch-still-there merged

build_mixed apply
run --apply
rc_is apply/rc "$RC" 0
has apply/header "APPLY"
dir_gone apply/removes-merged-worktree "$W/wts/merged"
branch_gone apply/removes-merged-branch merged
branch_gone apply/removes-nowt-branch merged-nowt
branch_gone apply/removes-ancestor-branch anc
dir_exists apply/keeps-dirty "$W/wts/dirty"
branch_exists apply/keeps-dirty-branch dirty
has apply/dirty-reason "dirty"
dir_exists apply/keeps-unpushed "$W/wts/unpushed"
branch_exists apply/keeps-unpushed-branch unpushed
has apply/unpushed-reason "unpushed (1 commits)"
dir_exists apply/keeps-openpr "$W/wts/openpr"
branch_exists apply/keeps-openpr-branch openpr
has apply/openpr-reason "open-pr (#4)"
dir_exists apply/keeps-unmerged "$W/wts/wip"
branch_exists apply/keeps-unmerged-branch wip
has apply/unmerged-reason "not-merged"
dir_exists apply/keeps-after-merge "$W/wts/after"
branch_exists apply/keeps-after-merge-branch after
has apply/after-merge-reason "commits after merged PR#5"
dir_exists apply/keeps-main-worktree "$W/repo"
branch_exists apply/keeps-default-branch main
has apply/main-reason "main worktree"
has apply/default-reason "default branch"
# The kept branches keep their commits.
[ -f "$W/wts/unpushed/extra.txt" ] && ok || bad apply/unpushed-commit-survives "extra.txt lost"
git -C "$W/repo" worktree list --porcelain | grep -Fq "$W/wts/merged" && bad apply/worktree-unregistered "merged worktree still registered" || ok

# --- the current worktree is never removed, even when merged ----------------
world current
mkbranch cur wt; pr cur MERGED "$(tip cur)" 1 main
OUT=$(cd "$W/wts/cur" && "$SWEEP" --repo-path "$W/repo" --apply 2>&1); RC=$?
rc_is current/rc "$RC" 0
dir_exists current/keeps-caller-worktree "$W/wts/cur"
branch_exists current/keeps-caller-branch cur
has current/reason "current worktree"

# --- a process inside a worktree keeps it ----------------------------------
world busy
mkbranch busy wt; pr busy MERGED "$(tip busy)" 1 main
( cd "$W/wts/busy" && exec sleep 30 ) &
SLEEPER=$!
sleep 1
run --apply
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
dir_exists busy/keeps-in-use "$W/wts/busy"
branch_exists busy/keeps-in-use-branch busy
has busy/reason "in-use (process cwd inside)"

# --- recently changed files keep a worktree unless the check is off ---------
world recent
mkbranch recent wt; pr recent MERGED "$(tip recent)" 1 main
OUT=$(cd "$W" && WT_SWEEP_RECENT_MIN=60 "$SWEEP" --repo-path "$W/repo" --apply 2>&1); RC=$?
dir_exists recent/keeps-fresh "$W/wts/recent"
has recent/reason "in-use (file changed within 60m)"

# --- ignored files beyond build output keep a worktree ----------------------
world ign
mkbranch ign wt; pr ign MERGED "$(tip ign)" 1 main
echo '.env' >"$W/repo/.git/info/exclude"; echo secret >"$W/wts/ign/.env"
run --apply
dir_exists ign/keeps-ignored-env "$W/wts/ign"
has ign/reason "ignored-files"

# --- the default branch survives even with no worktree holding it ---------
world defbr
mkbranch side
git -C "$W/repo" checkout -q side
run --apply
rc_is defbr/rc "$RC" 0
branch_exists defbr/keeps-default-branch main
has defbr/reason "KEEP   main: default branch"

# --- locked worktrees stay ---------------------------------------------------
world lock
mkbranch lock wt; pr lock MERGED "$(tip lock)" 1 main
git -C "$W/repo" worktree lock "$W/wts/lock"
run --apply
dir_exists lock/keeps-locked "$W/wts/lock"
has lock/reason "locked"

# --- --older-than keeps recent work -----------------------------------------
world older
mkbranch older wt; pr older MERGED "$(tip older)" 1 main
run --apply --older-than 30
dir_exists older/keeps-recent-commit "$W/wts/older"
has older/reason "newer-than-30d"

# --- gh unavailable: ancestry only, squash merges look unmerged -------------
world nogh
mkbranch squashed wt; pr squashed MERGED "$(tip squashed)" 1 main
git -C "$W/repo" branch -q anc2 main
: >"$STUB/gh.fail"
git -C "$W/repo" remote set-head origin main >/dev/null
run --apply
rc_is nogh/rc "$RC" 0
has nogh/warns "PR state unavailable from gh"
dir_exists nogh/keeps-squash-merged "$W/wts/squashed"
branch_gone nogh/still-removes-ancestor anc2

# --- default branch unknown: refuses ---------------------------------------
world nodefault
: >"$STUB/gh.fail"
git -C "$W/repo" remote set-head origin -d >/dev/null
run --apply
rc_is nodefault/rc "$RC" 1
has nodefault/message "cannot tell the default branch"

# --- idempotent: a second --apply has nothing left to remove ----------------
build_mixed twice
run --apply; run --apply
rc_is twice/rc "$RC" 0
has twice/nothing-left "removed 0"
dir_exists twice/dirty-survives-both "$W/wts/dirty"

# --- usage and exit codes ---------------------------------------------------
world usage
run --bogus
rc_is usage/bad-flag-rc "$RC" 2
has usage/bad-flag-msg "unknown argument --bogus"
has usage/bad-flag-usage "wt-sweep [--repo-path p]"
run --older-than
rc_is usage/missing-value-rc "$RC" 2
run --older-than soon
rc_is usage/bad-days-rc "$RC" 2
run --repo-path
rc_is usage/repo-path-missing-rc "$RC" 2
run --help
rc_is usage/help-rc "$RC" 0
has usage/help-text "Dry run by default"
OUT=$(cd "$W" && "$SWEEP" --repo-path "$ROOT/nope" 2>&1); RC=$?
rc_is usage/no-dir-rc "$RC" 1
mkdir "$ROOT/plain"
OUT=$(cd "$W" && "$SWEEP" --repo-path "$ROOT/plain" 2>&1); RC=$?
rc_is usage/not-repo-rc "$RC" 1
has usage/not-repo-msg "is not a git repo"

# --- stub sanity: the suite really goes through the stub --------------------
if grep -q 'repo view' "$ROOT/dry/stub/calls.log" 2>/dev/null && grep -q 'pr list' "$ROOT/dry/stub/calls.log"; then ok; else bad stub/used "gh stub was not asked for repo and PR state"; fi

echo "pass=$PASS fail=$FAIL${FAILED_NAMES:+ failed:$FAILED_NAMES}"
[ "$FAIL" -eq 0 ]
