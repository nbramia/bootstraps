#!/usr/bin/env bash
# Live tests for ship, against a throwaway repo this run creates and deletes.
#   bash live.test.sh [--self-check] [--only name,name]
# Set SHIP_LIVE_OWNER to the GitHub account that owns the throwaway repo and SHIP_LIVE_HOST
# to the ssh alias of the second machine. Bounded by LIVE_LIMIT seconds overall.
# Isolation: the only repo it can touch is the one it made, named with this run's token
# and listed in $W/created. The delete helper refuses anything else.
set -u
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SHIP=${LIVE_SHIP:-$BIN/ship}
TOKEN=$(date +%H%M%S)-$$
OWNER=${SHIP_LIVE_OWNER:-example-owner}
LIVE_HOST=${SHIP_LIVE_HOST:-second-machine}
R=$OWNER/ship-live-$TOKEN
W=$(mktemp -d "${TMPDIR:-/tmp}/shiplive.XXXXXX"); W=$(cd "$W" && pwd -P)
: >"$W/created"
PASS=0 FAIL=0 FAILED=""
say() { echo "[$(date +%H:%M:%S)] $*"; }
ok() { PASS=$((PASS + 1)); say "  ok: $*"; }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED|$1"; say "  NOT OK: $*"; }

live_delete_repo() { # only the repo this run made, and only if it carries this run's token
  case "$1" in "$R") ;; *) echo "refused: $1 was not created by this run"; return 1 ;; esac
  grep -Fxq "$1" "$W/created" || { echo "refused: $1 was not created by this run"; return 1; }
  case "$(gh repo view "$1" --json description --jq .description 2>/dev/null)" in
    *"ship live test $TOKEN"*) ;;
    *) echo "refused: $1 does not carry this run's token"; return 1 ;;
  esac
  gh repo delete "$1" --yes
}
if [ "${1:-}" = "--self-check" ]; then
  fails=0
  check() { if "$@" >/dev/null 2>&1; then echo "guard let through: $*"; fails=$((fails + 1)); fi; }
  gh() { echo "gh must not run in a self-check"; return 0; }
  check live_delete_repo "$OWNER/some-other-repo"
  check live_delete_repo "example-org/other-repo"
  check live_delete_repo "$R"     # right name, but not recorded as created
  rm -rf "$W"
  [ "$fails" = 0 ] || exit 1
  echo "self-check ok"
  exit 0
fi
ONLY=""; [ "${1:-}" = "--only" ] && ONLY=",$2,"
want() { [ -z "$ONLY" ] && return 0; case "$ONLY" in *",$1,"*) return 0 ;; esac; return 1; }

LIVE_LIMIT=${LIVE_LIMIT:-900}
SELF=$$
( sleep "$LIVE_LIMIT"; kill -TERM "$SELF" ) >/dev/null 2>&1 &
WATCHDOG=$!
LX=/tmp/shiplive-$TOKEN
linux() { ssh -o BatchMode=yes "$LIVE_HOST" "$@" 2>&1 </dev/null | grep -v 'Pseudo-terminal'; }
cleanup_all() {
  kill "$WATCHDOG" 2>/dev/null
  # Only processes from this run: their command lines carry this run's unique repo name.
  # A stopped process holds a TERM until it runs again, so wake it first or it leaks.
  pkill -CONT -f "ship-live-$TOKEN" 2>/dev/null
  pkill -f "ship-live-$TOKEN" 2>/dev/null
  linux "pkill -f ship-live-$TOKEN; rm -rf $LX" >/dev/null 2>&1
  live_delete_repo "$R"
  rm -rf "$W"
}
trap cleanup_all EXIT
trap 'say "interrupted or over the ${LIVE_LIMIT}s limit"; exit 3' TERM INT

export GH_PROMPT_DISABLED=1
gh repo create "$R" --private --add-readme --description "ship live test $TOKEN; safe to delete" >/dev/null || { echo "create failed"; exit 9; }
echo "$R" >>"$W/created"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
put_wf() { gh api -X PUT "repos/$R/contents/.github/workflows/$1" -f message="$1" -f content="$(b64 "$2")" >/dev/null; }
rm_wf() { gh api -X DELETE "repos/$R/contents/.github/workflows/$1" -f message=rm -f sha="$(gh api "repos/$R/contents/.github/workflows/$1" --jq .sha)" >/dev/null; }
put_wf deploy.yml 'name: Deploy
on:
  push:
    branches: [main]
concurrency:
  group: d
  cancel-in-progress: false
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: sleep 20
'
linux "mkdir -p $LX" >/dev/null
scp -q -o BatchMode=yes "$SHIP" "$LIVE_HOST:$LX/ship" || { echo "scp failed"; exit 9; }
echo "$R deploy=none" >"$W/none.conf"; scp -q -o BatchMode=yes "$W/none.conf" "$LIVE_HOST:$LX/none.conf"
: >"$W/auto.conf"
export SHIP_POLL=2 SHIP_CHECK_GRACE=0 SHIP_BLOCKED_SETTLE=5 SHIP_STATE_DIR=$W/state SHIP_CONF=$W/none.conf
export SHIP_CHECK_TIMEOUT=120 SHIP_DEPLOY_TIMEOUT=150
export SHIP_TEST_HOOK=$W/hook
mkdir -p "$W/hook"

mkpr() { # prints a PR number; each PR adds its own file unless given one. $2: commit message
  local sha pr n f
  n=$(( $(cat "$W/n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$W/n"; f=${1:-f$n.txt}
  sha=$(gh api "repos/$R/git/ref/heads/main" --jq .object.sha) || return 1
  gh api -X POST "repos/$R/git/refs" -f ref="refs/heads/b$n" -f sha="$sha" >/dev/null || return 1
  gh api -X PUT "repos/$R/contents/$f" -f message="${2:-b$n}" -f content="$(b64 "$n")" -f branch="b$n" >/dev/null || return 1
  pr=$(gh pr create --repo "$R" --base main --head "b$n" --title "b$n" --body test 2>/dev/null | sed 's#.*/##')
  [ -n "$pr" ] || return 1
  printf '%s' "$pr"
}
pr_state() { gh pr view "$1" --repo "$R" --json state --jq .state 2>/dev/null; }
wait_cond() { # seconds command...: bounded wait
  local s=$1 t0; shift; t0=$(date +%s)
  until "$@"; do [ $(( $(date +%s) - t0 )) -lt "$s" ] || return 1; sleep 0.5; done
}
P=""
start() { : >"$W/out"; "$SHIP" "$@" --repo "$R" >"$W/out" 2>&1 </dev/null & P=$!; }
arm() { : >"$W/hook/$1"; }
reached() { wait_cond "${2:-60}" test -f "$W/hook/$1.reached"; rm -f "$W/hook/$1.reached"; }
wait_pid() { # seconds pid: wait for it to exit, then collect its code
  local s=$1 p=$2 t0; t0=$(date +%s)
  while kill -0 "$p" 2>/dev/null; do
    if [ $(( $(date +%s) - t0 )) -ge "$s" ]; then kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; fi
    sleep 0.2
  done
  wait "$p"
}
run_for() { for r in $(ls -1 "$W/state/runs" | sort -r); do [ "$(sed -n 's/^[0-9]* pr //p' "$W/state/runs/$r" | tail -1)" = "$1" ] && { echo "$r"; return; }; done; }
status() { "$SHIP" --status "$(run_for "$1")" >"$W/st" 2>&1; echo $?; }
expect() { # label got want
  if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1" "got $2, wanted $3"; [ -f "$W/out" ] && tail -4 "$W/out" | cut -c1-200; fi
}
section() { say "=== $*"; }
kill9() { kill -CONT "$P" 2>/dev/null; kill -9 "$P" 2>/dev/null; wait "$P" 2>/dev/null; }

### kill -9 at each stage ###################################################
for st in stage-waiting before-merge stage-merging after-merge-call after-confirm stage-watching_deploy; do
if want "k9-$st"; then
section "kill -9 at $st"
pr=$(mkpr); arm "$st"; if [ "$st" = stage-watching_deploy ]; then SHIP_CONF=$W/auto.conf start "$pr" --wait-deploy; else start "$pr" --no-deploy-watch; fi; reached "$st"; kill9
c=$(status "$pr"); if [ "$st" = stage-merging ]; then expect "status exit" "$c" 16; else expect "status exit" "$c" 42; fi
case "$st" in
  stage-waiting|before-merge) grep -q 'sent no merge request' "$W/st" && ok "status: no merge request sent" || bad "k9-$st" "status wrong: $(cat "$W/st")"; expect "PR" "$(pr_state "$pr")" OPEN ;;
  stage-merging) grep -q 'may still land' "$W/st" && ok "status: may still land" || bad "k9-$st" "status wrong: $(cat "$W/st")"; expect "PR" "$(pr_state "$pr")" OPEN ;;
  *) grep -qi 'merged as' "$W/st" && ok "status: merged" || bad "k9-$st" "status wrong: $(cat "$W/st")"; expect "PR" "$(pr_state "$pr")" MERGED ;;
esac
pr2=$(mkpr); start "$pr2" --no-deploy-watch; wait_pid 60 "$P"; expect "next run on this machine" "$?" 4
fi
done

### Merge safety against real GitHub ########################################
if want zeroci; then
section "PR workflows with real filters: no checks expected, or wait for them"
put_wf ci.yml 'name: CI
on:
  pull_request:
    branches: [main]
    paths:
      - src/**
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: true
'
base_b=integration; gh api -X POST "repos/$R/git/refs" -f ref="refs/heads/$base_b" -f sha="$(gh api "repos/$R/git/ref/heads/main" --jq .object.sha)" >/dev/null
pr=$(mkpr docs/$$.md); SHIP_CHECK_GRACE=3 start "$pr" --no-deploy-watch; wait_pid 60 "$P"; expect "docs PR outside paths" "$?" 4; expect "PR" "$(pr_state "$pr")" MERGED
pr=$(mkpr src/a$$.txt); start "$pr" --no-deploy-watch; wait_pid 90 "$P"; expect "PR inside paths" "$?" 4; grep -qE 'checks \(all\)|gated on all' "$W/out" && ok "it saw the real check" || bad zeroci "no check seen: $(tail -2 "$W/out" | cut -c1-150)"
pr=$(mkpr src/b$$.txt "[skip ci] no run"); SHIP_MISSING_GRACE=10 start "$pr" --no-deploy-watch; wait_pid 60 "$P"; expect "should have run, none did" "$?" 14; expect "PR" "$(pr_state "$pr")" OPEN; grep -q 'allow-no-checks' "$W/out" && ok "says how to override" || bad zeroci "no hint"
start "$pr" --no-deploy-watch --allow-no-checks; wait_pid 60 "$P"; expect "with --allow-no-checks" "$?" 4
n=$(( $(cat "$W/n") + 1 )); echo "$n" >"$W/n"; gh api -X POST "repos/$R/git/refs" -f ref="refs/heads/b$n" -f sha="$(gh api "repos/$R/git/ref/heads/main" --jq .object.sha)" >/dev/null; gh api -X PUT "repos/$R/contents/src/i$n.txt" -f message="b$n" -f content="$(b64 "$n")" -f branch="b$n" >/dev/null; pr=$(gh pr create --repo "$R" --base "$base_b" --head "b$n" --title "b$n" --body t 2>/dev/null | sed 's#.*/##'); t0=$(date +%s); SHIP_CHECK_GRACE=3 start "$pr" --no-deploy-watch; wait_pid 60 "$P"; expect "PR into a branch the filter leaves out" "$?" 4; ok "took $(( $(date +%s) - t0 ))s"
rm_wf ci.yml
put_wf ci2.yml 'name: CI2
on:
  pull_request:
    paths-ignore:
      - docs/**
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: true
'
pr=$(mkpr docs/ig$$.md); SHIP_CHECK_GRACE=3 start "$pr" --no-deploy-watch; wait_pid 60 "$P"; expect "docs PR, paths-ignore" "$?" 4
pr=$(mkpr ig$$.txt); start "$pr" --no-deploy-watch; wait_pid 90 "$P"; expect "other PR, paths-ignore" "$?" 4; grep -qE 'checks \(all\)|gated on all' "$W/out" && ok "it saw the real check" || bad zeroci "no check seen"
rm_wf ci2.yml
fi
if want red; then
section "a check goes red while ship waits: must not merge"
pr=$(mkpr); sha=$(gh pr view "$pr" --repo "$R" --json headRefOid --jq .headRefOid); gh api -X POST "repos/$R/statuses/$sha" -f state=pending -f context=lint >/dev/null; start "$pr" --no-deploy-watch; sleep 5; gh api -X POST "repos/$R/statuses/$sha" -f state=failure -f context=lint -f target_url=https://example.com/l >/dev/null; wait_pid 60 "$P"; expect "exit" "$?" 10; expect "PR" "$(pr_state "$pr")" OPEN; grep -q 'FAILED: lint' "$W/out" && ok "names the check" || bad red "no name"
fi
if want jump; then
section "frozen before the merge, check goes red meanwhile: re-read on waking, no merge"
pr=$(mkpr); sha=$(gh pr view "$pr" --repo "$R" --json headRefOid --jq .headRefOid); arm between-reads; start "$pr" --no-deploy-watch; reached between-reads; gh api -X POST "repos/$R/statuses/$sha" -f state=failure -f context=lint >/dev/null; sleep 8; kill -CONT "$P"; wait_pid 60 "$P"; expect "exit" "$?" 10; expect "PR" "$(pr_state "$pr")" OPEN
fi
if want headmoved; then
section "head moves while frozen before the merge: --match-head-commit and the gates refuse"
pr=$(mkpr); br=$(gh pr view "$pr" --repo "$R" --json headRefName --jq .headRefName); arm before-merge; start "$pr" --no-deploy-watch; reached before-merge; gh api -X PUT "repos/$R/contents/moved-$pr.txt" -f message=moved -f content="$(b64 x)" -f branch="$br" >/dev/null; sleep 7; kill -CONT "$P"; wait_pid 60 "$P"; expect "exit" "$?" 5; expect "PR" "$(pr_state "$pr")" OPEN
fi
if want inflight; then
section "kill -9 with a real merge request in flight: status never says safe while it may land"
pr=$(mkpr); start "$pr" --no-deploy-watch; inflight() { grep -q 'merging PR' "$W/out"; }; wait_cond 60 inflight; kill -9 "$P"; wait "$P" 2>/dev/null; c=$(status "$pr"); case "$c" in 16) ok "status 16 while unknown" ;; 42) grep -q 'IS MERGED' "$W/st" && ok "already landed; status says so" || bad inflight "42 without merged: $(cat "$W/st")" ;; *) bad inflight "status $c: $(cat "$W/st")" ;; esac; grep -q 'Safe to rerun' "$W/st" && bad inflight "said safe" || ok "did not say safe"; landed() { [ "$(pr_state "$pr")" = MERGED ]; }; if wait_cond 15 landed; then c=$(status "$pr"); grep -q 'IS MERGED' "$W/st" && ok "status then finds it merged" || bad inflight "after landing: $(cat "$W/st")"; else ok "request did not land before the kill"; fi
fi
if want sigterm; then
section "SIGTERM just after a confirmed merge: the deploy watch still starts"
export SHIP_CONF=$W/auto.conf; pr=$(mkpr); arm after-confirm; start "$pr"; reached after-confirm; kill -TERM "$P"; kill -CONT "$P"; wait_pid 30 "$P"; expect "exit" "$?" 40; has_d() { [ "$(status "$pr")" = 0 ]; }; wait_cond 150 has_d && ok "watch finished and recorded" || bad sigterm "status: $(cat "$W/st")"; export SHIP_CONF=$W/none.conf
fi
if want caller; then
section "caller killed alone at the gate, and an agent crash under a surviving wrapper: no merge"
pr=$(mkpr); arm before-merge
bash -c '"$0" "$1" --repo "$2" --no-deploy-watch >"$3" 2>&1 </dev/null & echo $! >"$4"; wait' "$SHIP" "$pr" "$R" "$W/out" "$W/fpid" & CL=$!
reached before-merge; F=$(cat "$W/fpid"); kill -9 "$CL"; wait "$CL" 2>/dev/null; kill -CONT "$F"; gone() { ! kill -0 "$F" 2>/dev/null; }; wait_cond 30 gone; expect "direct caller" "$(status "$pr")" 41; expect "PR" "$(pr_state "$pr")" OPEN
pr=$(mkpr); arm before-merge
bash -c 'bash -c '"'"'"$0" "$1" --repo "$2" --no-deploy-watch >"$3" 2>&1 </dev/null & echo $! >"$4"; wait'"'"' "$0" "$1" "$2" "$3" "$4" & wait' "$SHIP" "$pr" "$R" "$W/out" "$W/fpid" & GP=$!
reached before-merge; F=$(cat "$W/fpid"); WR=$(ps -o ppid= -p "$F" | tr -d ' '); kill -9 "$GP"; wait "$GP" 2>/dev/null; sleep 1; kill -CONT "$F"; wait_cond 30 gone; kill "$WR" 2>/dev/null; expect "wrapper survived" "$(status "$pr")" 41; expect "PR" "$(pr_state "$pr")" OPEN
fi

### Deploys #################################################################
if want bgwatch; then
section "return at the merge; the watch finishes after the caller"
export SHIP_CONF=$W/auto.conf; pr=$(mkpr); t0=$(date +%s); "$SHIP" "$pr" --repo "$R" >"$W/out" 2>&1 </dev/null; expect "exit" "$?" 0; ok "returned in $(( $(date +%s) - t0 ))s"; expect "status while watching" "$(status "$pr")" 50; has_result() { [ "$(status "$pr")" = 0 ]; }; wait_cond 150 has_result && ok "status then reports the deploy" || bad bgwatch "no result: $(cat "$W/st")"; grep -q 'and deployed: Deploy' "$W/st" && ok "with its URL" || bad bgwatch "no URL"
pr=$(mkpr); start "$pr" --wait-deploy; wait_pid 150 "$P"; expect "--wait-deploy" "$?" 0; export SHIP_CONF=$W/none.conf
fi
if want dupcheck; then
section "real rerun of a check: CANCELLED then SUCCESS on one head, and a non-required red"
pr=$(mkpr); sha=$(gh pr view "$pr" --repo "$R" --json headRefOid --jq .headRefOid)
put_wf rr.yml 'name: RR
on:
  workflow_dispatch:
jobs:
  r:
    runs-on: ubuntu-latest
    steps:
      - run: true
'
gh api -X POST "repos/$R/statuses/$sha" -f state=failure -f context=lint >/dev/null; start "$pr" --no-deploy-watch; wait_pid 60 "$P"; expect "reported red" "$?" 10; gh api -X POST "repos/$R/statuses/$sha" -f state=success -f context=lint >/dev/null; start "$pr" --no-deploy-watch; wait_pid 60 "$P"; expect "red replaced by green" "$?" 4; rm_wf rr.yml
fi
if want advisory; then
section "ship.conf advisory: a real red status does not stop the run and shows in the RESULT line"
printf '%s advisory=lint\n' "$R" >"$W/adv.conf"; pr=$(mkpr); sha=$(gh pr view "$pr" --repo "$R" --json headRefOid --jq .headRefOid); gh api -X POST "repos/$R/statuses/$sha" -f state=failure -f context=lint >/dev/null; SHIP_CONF=$W/adv.conf start "$pr" --no-deploy-watch; wait_pid 60 "$P"; expect "advisory red" "$?" 4; expect "PR" "$(pr_state "$pr")" MERGED; grep -q 'RESULT exit=4.*lint failed' "$W/out" && ok "named in RESULT" || bad advisory "$(tail -1 "$W/out" | cut -c1-160)"
fi
if want needsgap; then
section "needs: gap with nothing required: wait for the run, then stop on the job that reports late"
put_wf n.yml 'name: N
on:
  pull_request:
jobs:
  first:
    runs-on: ubuntu-latest
    steps:
      - run: sleep 20
  late:
    needs: first
    runs-on: ubuntu-latest
    steps:
      - run: exit 1
'
pr=$(mkpr); start "$pr" --no-deploy-watch; wait_pid 240 "$P"; expect "late job" "$?" 10; expect "PR" "$(pr_state "$pr")" OPEN; rm_wf n.yml
fi
if want twodeploys; then
section "two deploy workflows, one filtered out by this merge: deployed; both should run and one is skipped: alarm"
put_wf a-deploy.yml 'name: A Deploy
on:
  push:
    branches: [main]
    paths: [src/**]
jobs:
  d:
    runs-on: ubuntu-latest
    steps:
      - run: true
'
put_wf b-deploy.yml 'name: B Deploy
on:
  push:
    branches: [main]
    paths: [never-matches/**]
jobs:
  d:
    runs-on: ubuntu-latest
    steps:
      - run: true
'
printf '%s deploy=A Deploy|B Deploy\n' "$R" >"$W/ab.conf"; pr=$(mkpr src/ab$$.txt); SHIP_CONF=$W/ab.conf SHIP_DEPLOY_START_TIMEOUT=25 start "$pr" --wait-deploy; wait_pid 90 "$P"; expect "one should run, it did" "$?" 0; grep -q 'and deployed' "$W/out" && ok "deployed" || bad twodeploys "$(tail -1 "$W/out" | cut -c1-160)"; rm_wf a-deploy.yml; rm_wf b-deploy.yml
fi
if want pathfilter; then
section "real deploy filters: no deploy expected, or an alarm when one should have started"
put_wf pf.yml 'name: Filtered Deploy
on:
  push:
    branches: [main]
    paths:
      - src/**
jobs:
  d:
    runs-on: ubuntu-latest
    steps:
      - run: true
'
put_wf pfi.yml 'name: Ignoring Deploy
on:
  push:
    branches: [main]
    paths-ignore:
      - docs/**
jobs:
  d:
    runs-on: ubuntu-latest
    steps:
      - run: true
'
echo "$R deploy=Filtered Deploy" >"$W/pf.conf"; echo "$R deploy=Ignoring Deploy" >"$W/pfi.conf"
run_pf() { # conf file title want text
  local pr; pr=$(mkpr "$2" "$3"); SHIP_CONF=$W/$1 SHIP_DEPLOY_PROBE=15 SHIP_DEPLOY_START_TIMEOUT=25 start "$pr" --wait-deploy; wait_pid 90 "$P"; expect "$1 $2 ${3:-plain}" "$?" "$4"; grep -q "$5" "$W/out" && ok "says: $5" || bad pathfilter "no [$5]: $(tail -1 "$W/out" | cut -c1-160)"
}
sk='[skip ci] no run'   # GitHub starts nothing for this commit though the filter matches
run_pf pf.conf other/a.txt "" 4 'no deploy expected'
run_pf pf.conf src/a.txt "" 0 'and deployed'
run_pf pf.conf src/b.txt "$sk" 21 'NO DEPLOY STARTED'
run_pf pfi.conf docs/c.md "" 4 'no deploy expected'
run_pf pfi.conf other/d.txt "" 0 'and deployed'
run_pf pfi.conf other/e.txt "$sk" 21 'NO DEPLOY STARTED'
put_wf pfb.yml 'name: Branch Deploy
on:
  push:
    branches: [release]
jobs:
  d:
    runs-on: ubuntu-latest
    steps:
      - run: true
'
echo "$R deploy=Branch Deploy" >"$W/pfb.conf"; run_pf pfb.conf other/f.txt "" 4 'no deploy expected'; rm_wf pfb.yml
rm_wf pf.yml; rm_wf pfi.yml
fi

### Concurrent merges with no lock ##########################################
linux_ship() { # pr [flags]
  local pr=$1; shift
  linux "export PATH=\$HOME/.local/bin:\$PATH GH_PROMPT_DISABLED=1 SHIP_POLL=2 SHIP_CHECK_GRACE=0 SHIP_STATE_DIR=$LX/state SHIP_CONF=$LX/${LCONF:-none}.conf SHIP_CHECK_TIMEOUT=150; bash $LX/ship $pr --repo $R $*; echo LINUX_EXIT=\$?"
}
retries() { cat "$@" | grep -c 'going back to waiting'; }
if want conc-local; then
for round in 1 2 3; do
section "concurrent, one machine, round $round: 4 PRs started together"
ps=""; for i in 1 2 3 4; do ps="$ps $(mkpr)"; done; pids=""; for p in $ps; do "$SHIP" "$p" --repo "$R" --no-deploy-watch >"$W/c.$p" 2>&1 </dev/null & pids="$pids $!"; done; t0=$(date +%s); for q in $pids; do wait_pid 150 "$q"; expect "run exit" "$?" 4; done; for p in $ps; do expect "PR $p" "$(pr_state "$p")" MERGED; done; ok "all merged in $(( $(date +%s) - t0 ))s, $(for p in $ps; do cat "$W/c.$p"; done | grep -c 'going back to waiting') go-backs"
done
fi
if want conc-two; then
for round in 1 2 3; do
section "concurrent, Mac and Linux, round $round: 2 PRs each, started together"
a=$(mkpr); b=$(mkpr); c=$(mkpr); d=$(mkpr); "$SHIP" "$a" --repo "$R" --no-deploy-watch >"$W/c.a" 2>&1 </dev/null & A=$!; "$SHIP" "$b" --repo "$R" --no-deploy-watch >"$W/c.b" 2>&1 </dev/null & B=$!; linux_ship "$c" --no-deploy-watch >"$W/c.c" & C=$!; linux_ship "$d" --no-deploy-watch >"$W/c.d" & D=$!; t0=$(date +%s); wait_pid 150 "$A"; expect "mac a" "$?" 4; wait_pid 150 "$B"; expect "mac b" "$?" 4; wait_pid 150 "$C"; wait_pid 150 "$D"; grep -q 'LINUX_EXIT=4' "$W/c.c" && ok "linux c" || { bad conc-two "linux c"; tail -3 "$W/c.c" | cut -c1-200; }; grep -q 'LINUX_EXIT=4' "$W/c.d" && ok "linux d" || { bad conc-two "linux d"; tail -3 "$W/c.d" | cut -c1-200; }; for p in "$a" "$b" "$c" "$d"; do expect "PR $p" "$(pr_state "$p")" MERGED; done; ok "all merged in $(( $(date +%s) - t0 ))s, $(cat "$W"/c.[abcd] | grep -c 'going back to waiting') go-backs"
done
fi
if want conc-conflict; then
section "concurrent PRs editing one file: one merges, the other reports the conflict"
a=$(mkpr same.txt); b=$(mkpr same.txt); "$SHIP" "$a" --repo "$R" --no-deploy-watch >"$W/c.a" 2>&1 </dev/null & A=$!; "$SHIP" "$b" --repo "$R" --no-deploy-watch >"$W/c.b" 2>&1 </dev/null & B=$!; wait_pid 150 "$A"; ca=$?; wait_pid 150 "$B"; cb=$?; case "$ca $cb" in "4 12"|"12 4") ok "exits $ca and $cb" ;; *) bad conc-conflict "exits $ca $cb"; tail -3 "$W/c.a" "$W/c.b" | cut -c1-180 ;; esac
fi
if want conc-deploy; then
section "concurrent merges with a queueing deploy: every run's deploy result is truthful"
export SHIP_CONF=$W/auto.conf; ps=""; for i in 1 2 3; do ps="$ps $(mkpr)"; done; pids=""; for p in $ps; do "$SHIP" "$p" --repo "$R" >"$W/c.$p" 2>&1 </dev/null & pids="$pids $!"; done; for q in $pids; do wait_pid 150 "$q"; expect "run exit" "$?" 0; done
for p in $ps; do done_() { c=$(status "$p"); [ "$c" != 50 ]; }; wait_cond 170 done_; c=$(status "$p"); expect "deploy result PR $p" "$c" 0; grep -E '^deploy:' "$W/st" | cut -c1-170; done; export SHIP_CONF=$W/none.conf
fi
if want overhead; then
section "overhead on one PR, no CI"
unset SHIP_TEST_HOOK; export SHIP_CONF=$W/auto.conf; pr=$(mkpr); sleep 3; t0=$(date +%s); "$SHIP" "$pr" --repo "$R" >"$W/o3" 2>&1 </dev/null; ok "one PR: $(( $(date +%s) - t0 ))s"; grep -E '^\[ship' "$W/o3" | cut -c1-90; export SHIP_CONF=$W/none.conf SHIP_TEST_HOOK=$W/hook
fi

say "PASS=$PASS FAIL=$FAIL$( [ -z "$FAILED" ] || echo " FAILED=$FAILED")"
[ "$FAIL" = 0 ]
