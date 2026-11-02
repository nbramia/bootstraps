#!/usr/bin/env bash
# Tests for ship with a stubbed gh. Usage: bash ship.test.sh
. "$(dirname "$0")/lib.sh"
PIN=aaaaaaaaaa11111111112222222222333333333a
OTHER=bbbbbbbbbb11111111112222222222333333333b
MERGE=cccccccccc11111111112222222222333333333c

pr_json() { # state draft mergeable mss head [base] [cross] [review]
  cat <<J
{"data":{"repository":{"id":"R_1","defaultBranchRef":{"name":"main"},
"pullRequest":{"state":"$1","isDraft":$2,"mergeable":"$3","mergeStateStatus":"$4","headRefOid":"$5","headRefName":"feat/x","baseRefName":"${6:-main}","isCrossRepository":${7:-false},"url":"https://gh/pr/7","reviewDecision":"${8:-}","mergeCommit":$( [ "$1" = MERGED ] && echo "{\"oid\":\"$MERGE\"}" || echo null ),"commits":{"nodes":[]}}}}}
J
}
cr() { # name status conclusion required
  local c=null; [ -z "${3:-}" ] || c="\"$3\""
  echo "{\"__typename\":\"CheckRun\",\"name\":\"$1\",\"status\":\"$2\",\"conclusion\":$c,\"detailsUrl\":\"https://gh/log/$1\",\"isRequired\":${4:-true}}"
}
crt() { # name status conclusion startedAt required
  local c=null st=null; [ -z "$3" ] || c="\"$3\""; [ -z "$4" ] || st="\"$4\""
  echo "{\"__typename\":\"CheckRun\",\"name\":\"$1\",\"status\":\"$2\",\"conclusion\":$c,\"detailsUrl\":\"https://gh/log/$1\",\"startedAt\":$st,\"isRequired\":${5:-true}}"
}
checks() { # one CheckRun JSON per arg
  local IFS=,; echo "{\"data\":{\"repository\":{\"pullRequest\":{\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":{\"contexts\":{\"nodes\":[$*]}}}}]}}}}}"
}
run() { # wfid name status conclusion
  echo "{\"workflowDatabaseId\":$1,\"workflowName\":\"$2\",\"status\":\"$3\",\"conclusion\":\"$4\",\"url\":\"https://gh/run/$2\"}"
}
scenario() {
  S=$ROOT/$1; rm -rf "$S"; mkdir -p "$S"; export STUB=$S
  export SHIP_CONF=$S/ship.conf SHIP_POLL=0.05 SHIP_GH_CALL_TIMEOUT=20
  export SHIP_CHECK_GRACE=0 SHIP_BLOCKED_SETTLE=0 SHIP_MISSING_GRACE=0 SHIP_DEPLOY_START_TIMEOUT=0 SHIP_MERGE_CONFIRM_TIMEOUT=0
  # Short ceilings, so a bug shows as a wrong exit code and never as a hung suite.
  export SHIP_STATE_DIR=$S/state
  echo '[]' >"$S/runs_wf.json"
  : >"$S/ship.conf"
  export SHIP_DEPLOY_PROBE=0
  echo '[]' >"$S/deploy_sha.1"; echo '[]' >"$S/deploy_recent.json"; echo '{"statuses":[]}' >"$S/cstatus.1"; echo '{"check_runs":[]}' >"$S/cruns.1"
  export SHIP_CHECK_TIMEOUT=10 SHIP_DEPLOY_TIMEOUT=10
  [ -z "${TEST_TRACE:-}" ] || echo "$(date +%T) $1" >>"$TEST_TRACE"
  echo '{"nameWithOwner":"o/r","defaultBranchRef":{"name":"main"}}' >"$S/repo_view.json"
  echo '[{"id":1,"name":"CI","path":".github/workflows/ci.yml","state":"active"},{"id":2,"name":"Deploy Prod","path":".github/workflows/prod.yml","state":"active"}]' >"$S/workflows.json"
  pr_json OPEN false MERGEABLE CLEAN "$PIN" >"$S/pr.1"
  checks "$(cr test COMPLETED SUCCESS)" >"$S/checks.1"
  echo '{"data":{"repository":{"pullRequest":{"baseRef":{"refUpdateRule":{"requiredStatusCheckContexts":[]}}}}}}' >"$S/ref_rule.json"
  echo "[$(run 2 'Deploy Prod' completed success)]" >"$S/runs_commit.1"
  echo "{\"merged\":false,\"merge_commit_sha\":null,\"head\":{\"sha\":\"$PIN\"},\"state\":\"open\"}" >"$S/pull_open.json"
  echo "{\"merged\":true,\"merge_commit_sha\":\"$MERGE\",\"head\":{\"sha\":\"$PIN\"},\"state\":\"closed\",\"commits\":1}" >"$S/pull_merged.json"
  echo "{\"object\":{\"sha\":\"$PIN\"}}" >"$S/ref.json"
  echo '[]' >"$S/prs_base.json"; echo '[]' >"$S/prs_head.json"
}
ship() { # expected_exit name args...
  local want=$1 name=$2; shift 2
  OUT=$("$BASH" "$BIN/ship" 7 --repo o/r --wait-deploy "$@" 2>&1); RC=$?
  if [ "$RC" = "$want" ]; then ok; else bad "$name" "exit $RC, wanted $want"; fi
}
called() { if grep -q -- "$2" "$STUB/calls.log"; then ok; else bad "$1" "gh never called with [$2]"; fi; }
not_called() { if grep -q -- "$2" "$STUB/calls.log"; then bad "$1" "gh called with [$2]"; else ok; fi; }
order() { # name first second
  local a b; a=$(grep -n -- "$2" "$STUB/calls.log" | head -1 | cut -d: -f1); b=$(grep -n -- "$3" "$STUB/calls.log" | head -1 | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok; else bad "$1" "[$2] not before [$3]"; fi
}
DEL='updateRefs'; MRG='pr merge'
wait_for() { # file seconds
  local n=0; while [ ! -e "$1" ] && [ "$n" -lt $(($2 * 10)) ]; do sleep 0.1; n=$((n + 1)); done; [ -e "$1" ]
}
run_of() { ls -1 "$S/state/runs" 2>/dev/null | sort -r | sed -n 1p; }
recf() { printf '%s' "$S/state/runs/$(run_of)"; }
start_bg() { # args: start ship in the background, set P, wait for its record
  "$BASH" "$BIN/ship" 7 --repo o/r "$@" >"$S/out" 2>&1 </dev/null & P=$!
  wait_for "$S/state/runs" 5; local n=0; until [ -s "$(recf)" ] || [ "$n" -gt 50 ]; do sleep 0.1; n=$((n + 1)); done
}
status() { OUT=$("$BASH" "$BIN/ship" --status "${1:-$(run_of)}" 2>&1); RC=$?; }
arm() { export SHIP_TEST_HOOK=$S/hook; mkdir -p "$S/hook"; : >"$S/hook/$1"; }
# --- happy path: pending, then green, merge, delete, deploy
scenario happy
checks "$(cr test IN_PROGRESS)" >"$S/checks.1"; checks "$(cr test COMPLETED SUCCESS)" >"$S/checks.2"
echo "[$(run 2 'Deploy Prod' in_progress '')]" >"$S/runs_commit.1"; echo "[$(run 2 'Deploy Prod' completed success)]" >"$S/runs_commit.2"
ship 0 happy
called happy "--squash --match-head-commit $PIN"; order happy "$MRG" "repos/o/r/pulls/7"; order happy "repos/o/r/pulls/7" "$DEL"
called happy "name=refs/heads/feat/x"; called happy "before=$PIN"; called happy "id=R_1"; not_called happy "delete-branch"; has happy "deployed"; has happy "https://gh/run/Deploy Prod"; grep -q ' merged ' "$(recf)" && ok || bad happy "no merged line in the record"
has happy "pinned head aaaaaaaaa"; has happy "[ship 00:0"

# --- refusals
scenario closed; pr_json CLOSED false UNKNOWN UNKNOWN "$PIN" >"$S/pr.1"; ship 3 closed; has closed "closed"; not_called closed "$MRG"
scenario merged; pr_json MERGED false UNKNOWN UNKNOWN "$PIN" >"$S/pr.1"; ship 3 merged; has merged "already merged"; not_called merged "$DEL"
scenario draft; pr_json OPEN true MERGEABLE DRAFT "$PIN" >"$S/pr.1"; ship 3 draft; has draft "draft"
scenario usage; OUT=$("$BASH" "$BIN/ship" 2>&1); [ $? = 2 ] && ok || bad usage "no-arg exit"
OUT=$("$BASH" "$BIN/ship" 7 --dry-run 2>&1); [ $? = 2 ] && ok || bad usage "cut flag accepted"
OUT=$("$BASH" "$BIN/ship" --help 2>&1); [ $? = 0 ] && ok || bad usage "help"; has usage "Exit codes"

# --- head moves during the wait
scenario moved
checks "$(cr test IN_PROGRESS)" >"$S/checks.1"
pr_json OPEN false MERGEABLE BLOCKED "$PIN" >"$S/pr.1"; pr_json OPEN false MERGEABLE BLOCKED "$PIN" >"$S/pr.2"; pr_json OPEN false MERGEABLE BLOCKED "$PIN" >"$S/pr.3"; pr_json OPEN false MERGEABLE BLOCKED "$OTHER" >"$S/pr.4"
ship 5 moved; has moved "head moved"; not_called moved "$MRG"; not_called moved "$DEL"

# --- closed during the wait
scenario closedmid; checks "$(cr test IN_PROGRESS)" >"$S/checks.1"
for i in 1 2 3; do pr_json OPEN false MERGEABLE BLOCKED "$PIN" >"$S/pr.$i"; done; pr_json CLOSED false UNKNOWN UNKNOWN "$PIN" >"$S/pr.4"
ship 3 closedmid; not_called closedmid "$MRG"

# --- check states
scenario failed; checks "$(cr test COMPLETED FAILURE)" "$(cr other IN_PROGRESS)" >"$S/checks.1"
ship 10 failed; has failed "FAILED: test  https://gh/log/test"; not_called failed "$MRG"; not_called failed "$DEL"; not_called failed "rerun"; has failed "Not rerunning"
scenario cancelled; checks "$(cr test COMPLETED CANCELLED)" >"$S/checks.1"; ship 11 cancelled; has cancelled "CANCELLED: test"; not_called cancelled "$MRG"
scenario timedout; checks "$(cr test COMPLETED TIMED_OUT)" >"$S/checks.1"; ship 10 timedout
scenario status_ctx
echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"StatusContext","context":"ci/ext","state":"ERROR","targetUrl":"https://ext/1","isRequired":true}]}}}}]}}}}}' >"$S/checks.1"
ship 10 status_ctx; has status_ctx "FAILED: ci/ext  https://ext/1"
scenario conflict; pr_json OPEN false CONFLICTING DIRTY "$PIN" >"$S/pr.1"; ship 12 conflict; has conflict "conflicts"; not_called conflict "$MRG"
scenario behind; pr_json OPEN false MERGEABLE BEHIND "$PIN" >"$S/pr.1"; ship 13 behind; has behind "behind main"; not_called behind "$MRG"
scenario blocked; pr_json OPEN false MERGEABLE BLOCKED "$PIN" main false REVIEW_REQUIRED >"$S/pr.1"; ship 15 blocked; has blocked "REVIEW_REQUIRED"; not_called blocked "$MRG"

# --- missing required check, from rulesets and from branch protection
scenario missing; echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"e2e"}]}}]' >"$S/rules.json"
ship 14 missing; has missing "never reported"; has missing "e2e"; not_called missing "$MRG"
scenario missingmask; echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"e2e"}]}}]' >"$S/rules.json"; checks "$(cr lint IN_PROGRESS false)" >"$S/checks.1"; export SHIP_CHECK_TIMEOUT=0; ship 14 missingmask; has missingmask "e2e"
scenario missing2; echo '{"data":{"repository":{"pullRequest":{"baseRef":{"refUpdateRule":{"requiredStatusCheckContexts":["e2e"]}}}}}}' >"$S/ref_rule.json"
ship 14 missing2
# A required job with needs: is absent while its dependency runs. That must not trip the missing timer.
scenario needs; echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"e2e"},{"context":"build"}]}}]' >"$S/rules.json"
checks "$(cr build IN_PROGRESS)" >"$S/checks.1"; checks "$(cr build COMPLETED SUCCESS)" "$(cr e2e QUEUED)" >"$S/checks.2"; checks "$(cr build COMPLETED SUCCESS)" "$(cr e2e COMPLETED SUCCESS)" >"$S/checks.3"
ship 0 needs; called needs "$MRG"
# Never merge on red: a reported failure stops the run, required or not. Skipped and neutral are not red.
scenario advisory; checks "$(cr test COMPLETED SUCCESS)" "$(cr lint COMPLETED FAILURE false)" >"$S/checks.1"; ship 10 advisory; has advisory "FAILED: lint"; not_called advisory "$MRG"
scenario advcancel; checks "$(cr test COMPLETED SUCCESS)" "$(cr lint COMPLETED CANCELLED false)" >"$S/checks.1"; ship 11 advcancel; not_called advcancel "$MRG"
scenario advskip; checks "$(cr test COMPLETED SUCCESS)" "$(cr lint COMPLETED SKIPPED false)" "$(cr e2e COMPLETED NEUTRAL false)" >"$S/checks.1"; ship 0 advskip; called advskip "$MRG"
scenario advrerun; checks "$(cr test COMPLETED SUCCESS)" "$(crt lint COMPLETED FAILURE 2026-01-01T10:00:00Z false)" "$(crt lint COMPLETED SUCCESS 2026-01-01T10:05:00Z false)" >"$S/checks.1"; ship 0 advrerun; called advrerun "$MRG"
# No required set: every reported check gates.
scenario allmode; checks "$(cr lint COMPLETED FAILURE false)" >"$S/checks.1"; ship 10 allmode; has allmode "FAILED: lint"
# Zero checks: a repo with no PR workflows merges after a short wait, counted from ship's start.
PRWF=$'name: ci\non: [pull_request]\njobs: {}\n'
scenario nochecks; checks >"$S/checks.1"; printf 'on: workflow_dispatch\n' >"$S/wf.yml"; t0=$(date +%s); export SHIP_CHECK_GRACE=2; ship 0 nochecks; has nochecks "to register"; [ $(( $(date +%s) - t0 )) -ge 2 ] && ok || bad nochecks "skipped the wait"; called nochecks "$MRG"
scenario nullroll; export SHIP_CHECK_GRACE=2; printf 'on: workflow_dispatch\n' >"$S/wf.yml"; echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}}}}' >"$S/checks.1"; ship 0 nullroll; has nullroll "to register"
# The reproduced defect: an old commit, just pushed, PR workflows not yet reported. Never clear.
scenario zeroci; export SHIP_MISSING_GRACE=2; checks >"$S/checks.1"; printf '%s' "$PRWF" >"$S/wf.yml"; ship 14 zeroci; has zeroci "allow-no-checks"; not_called zeroci "$MRG"
# They appear: wait, and gate on them.
scenario zerolate; export SHIP_MISSING_GRACE=30 SHIP_CHECK_GRACE=0; checks >"$S/checks.1"; checks >"$S/checks.2"; checks "$(cr test IN_PROGRESS false)" >"$S/checks.3"; checks "$(cr test COMPLETED FAILURE false)" >"$S/checks.4"; printf '%s' "$PRWF" >"$S/wf.yml"; ship 10 zerolate; has zerolate "waiting for them"; not_called zerolate "$MRG"
scenario zeroapi; export SHIP_MISSING_GRACE=1; checks >"$S/checks.1"; touch "$S/contents.fail"; ship 14 zeroapi; not_called zeroapi "$MRG"
# PR checks use the same matcher: when no workflow's filters match this PR, none are expected.
prf() { # name exit filters-yaml base file...
  local n=$1 want=$2 y=$3 b=$4; shift 4; scenario "$n"; export SHIP_MISSING_GRACE=1 SHIP_CHECK_GRACE=1; checks >"$S/checks.1"; printf '%b' "$y" >"$S/wf.ci.yml"; printf 'on: workflow_dispatch\n' >"$S/wf.prod.yml"; printf '%s\n' "$@" >"$S/prfiles"; pr_json OPEN false MERGEABLE CLEAN "$PIN" "$b" >"$S/pr.1"; ship "$want" "$n" --no-deploy-watch
}
PP='on:\n  pull_request:\n    paths:\n      - src/**\n'
prf pcdocs 4 "$PP" main docs/a.md; has pcdocs "to register"; called pcdocs "$MRG"
prf pcmatch 14 "$PP" main docs/a.md src/b.py; not_called pcmatch "$MRG"
prf pcign 4 'on:\n  pull_request:\n    paths-ignore:\n      - docs/**\n' main docs/a.md
prf pcign2 14 'on:\n  pull_request:\n    paths-ignore:\n      - docs/**\n' main docs/a.md x.py
prf pcbr 4 'on:\n  pull_request:\n    branches: [main]\n' integration src/a.py; called pcbr "$MRG"
prf pcbr2 14 'on:\n  pull_request:\n    branches: [main]\n' main src/a.py
prf pcbrglob 14 'on:\n  pull_request:\n    branches:\n      - release/**\n' release/1/x a.py
prf pcbrig 4 'on:\n  pull_request:\n    branches-ignore:\n      - integration\n' integration a.py
prf pcbrig2 14 'on:\n  pull_request:\n    branches-ignore:\n      - integration\n' main a.py
prf pcbrneg 4 'on:\n  pull_request:\n    branches:\n      - "**"\n      - "!integration"\n' integration a.py
prf pcbrpath 4 'on:\n  pull_request:\n    branches: [main]\n    paths: [src/**]\n' main docs/a.md
prf pcbrpath2 4 'on:\n  pull_request:\n    branches: [main]\n    paths: [src/**]\n' other src/a.py
prf pctarget 14 'on:\n  pull_request_target:\n    branches: [main]\n' main a.py
prf pclist 14 'on:\n  - push\n  - pull_request\n' main a.py
prf pcglob 14 'on:\n  pull_request:\n    paths: [src/[ab]/**]\n' main docs/a.md
prf pcflow 14 'on: {pull_request: {paths: [src/**]}}\n' main docs/a.md
# Push CI on the PR's branch reports on this head too.
prf pcpush 14 'on:\n  push:\n    paths: [src/**]\n' main src/a.py
prf pcpush2 4 'on:\n  push:\n    paths: [src/**]\n' main docs/a.md
prf pcpush3 14 'on: [push]\n' main docs/a.md
prf pcpush4 4 'on:\n  push:\n    branches: [main]\n' main src/a.py
# A PR that changes workflows is judged by files it does not run: cannot tell.
prf pcwf 14 "$PP" main docs/a.md .github/workflows/x.yml
prf pcwf2 14 "$PP" main .github/workflows/x.yml
# Forms the reader does not fully follow can never answer "does not match".
prf pccrlf 4 'on:\r\n  pull_request:\r\n    paths:\r\n      - src/**\r\n' main docs/a.md
prf pccrlf2 14 'on:\r\n  pull_request:\r\n    paths:\r\n      - src/**\r\n' main src/a.py
prf pczero 14 'on:\n- pull_request\n' main a.py
prf pczero2 4 'on:\n- workflow_dispatch\n' main a.py
prf pcmulti 14 'on: [pull_request,\n  push]\n' main a.py
prf pcanchor 14 'on: &x\n  pull_request:\n    paths: [src/**]\n' main docs/a.md
prf pcmerge 14 'on:\n  pull_request:\n    <<: *f\n' main docs/a.md
prf pcmflow 14 'on:\n  pull_request:\n    paths: [src/**,\n      lib/**]\n' main docs/a.md
prf pcbslash 14 'on:\n  pull_request:\n    paths: ["src\\\\/a"]\n' main docs/a.md
prf pcslash 14 'on:\n  pull_request:\n    paths: [src/]\n' main docs/a.md
prf pcalias 14 'on:\n  pull_request:\n    paths:\n      - *x\n' main docs/a.md
prf pchash 14 'on:\n  pull_request:\n    paths:\n      - "a #b"\n' main docs/a.md
prf pctab 14 'on:\n\tpull_request:\n' main a.py
prf pcignneg 14 'on:\n  pull_request:\n    paths-ignore:\n      - "!src/**"\n' main docs/a.md
# Only the on: block has to be understood: odd text in a job says nothing about the trigger.
prf pcjhash 4 'on:\n  pull_request:\n    paths: [src/**]\njobs:\n  a:\n    steps:\n      - run: echo "see #4"\n' main docs/a.md
prf pcjtab 4 'on:\n  pull_request:\n    paths: [src/**]\njobs:\n  a:\n    steps:\n      - run: |\n          x\n\t\ty\n' main docs/a.md
prf pcjmerge 4 'on:\n  pull_request:\n    paths: [src/**]\nx: &a\n  b: 1\ny:\n  <<: *a\n' main docs/a.md
prf pcjfirst 4 'name: "see #4"\njobs:\n  a:\n    steps:\n      - run: echo "see #4"\n\t\ty\non:\n  pull_request:\n    paths: [src/**]\n' main docs/a.md
prf pcjstill 14 'on:\n  pull_request:\n    paths: [src/**]\njobs:\n  a:\n    steps:\n      - run: echo "see #4"\n' main src/a.py
prf pconhash 14 'on: "workflow_dispatch #x\n' main a.py
# Filters come from the PR's base branch, not the default branch.
prb() { # name exit yaml-at-dev yaml-at-main
  scenario "$1"; export SHIP_MISSING_GRACE=1 SHIP_CHECK_GRACE=1; checks >"$S/checks.1"; printf '%b' "$3" >"$S/wf.ci.yml@dev"; printf '%b' "$4" >"$S/wf.ci.yml@main"; printf 'on: workflow_dispatch\n' >"$S/wf.prod.yml"; echo a.py >"$S/prfiles"; pr_json OPEN false MERGEABLE CLEAN "$PIN" dev >"$S/pr.1"; ship "$2" "$1" --no-deploy-watch
}
prb pcbase 14 'on: pull_request\n' 'on: workflow_dispatch\n'
prb pcbase2 4 'on: workflow_dispatch\n' 'on: pull_request\n'
# A bad ref is not "no workflows". A path that is not there is.
scenario pcbadref; export SHIP_MISSING_GRACE=1 SHIP_CHECK_GRACE=1; checks >"$S/checks.1"; touch "$S/contents.badref"; echo a.py >"$S/prfiles"; ship 14 pcbadref --no-deploy-watch; not_called pcbadref "$MRG"
scenario pcnodir; export SHIP_MISSING_GRACE=1 SHIP_CHECK_GRACE=1; checks >"$S/checks.1"; touch "$S/contents.404"; echo a.py >"$S/prfiles"; ship 4 pcnodir --no-deploy-watch
# A disabled workflow is not expected. If the list cannot be read, it might be.
scenario pcdis; export SHIP_MISSING_GRACE=1 SHIP_CHECK_GRACE=1; checks >"$S/checks.1"; echo '[{"id":1,"name":"CI","path":".github/workflows/ci.yml","state":"disabled_manually"}]' >"$S/workflows.json"; printf 'on: pull_request\n' >"$S/wf.ci.yml"; echo a.py >"$S/prfiles"; ship 4 pcdis --no-deploy-watch
scenario pcact; export SHIP_MISSING_GRACE=1 SHIP_CHECK_GRACE=1; checks >"$S/checks.1"; echo '[{"id":1,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]' >"$S/workflows.json"; printf 'on: pull_request\n' >"$S/wf.ci.yml"; echo a.py >"$S/prfiles"; ship 14 pcact --no-deploy-watch
scenario pcwfl; export SHIP_MISSING_GRACE=1 SHIP_CHECK_GRACE=1; checks >"$S/checks.1"; echo '[{"id":1,"name":"CI","path":".github/workflows/ci.yml","state":"disabled_manually"}]' >"$S/workflows.json"; printf 'on: pull_request\n' >"$S/wf.ci.yml"; echo a.py >"$S/prfiles"; echo 99 >"$S/fail.wflist"; ship 14 pcwfl --no-deploy-watch
# A workflow filename with a space is read, not split into a 404.
scenario pcspace; export SHIP_MISSING_GRACE=1; checks >"$S/checks.1"; echo '[{"id":1,"name":"CI","path":".github/workflows/my ci.yml","state":"active"}]' >"$S/workflows.json"; printf 'on: pull_request\n' >"$S/wf.my ci.yml"; printf 'on: workflow_dispatch\n' >"$S/wf.yml"; echo a.py >"$S/prfiles"; ship 14 pcspace; not_called pcspace "$MRG"
prf pcnofiles 14 "$PP" main ""
scenario pcnoread; export SHIP_MISSING_GRACE=1; checks >"$S/checks.1"; printf '%b' "$PP" >"$S/wf.yml"; echo docs/a.md >"$S/prfiles"; touch "$S/contents.fail"; ship 14 pcnoread; not_called pcnoread "$MRG"
# A workflow that matches beats one that does not.
scenario pctwo; export SHIP_MISSING_GRACE=1; checks >"$S/checks.1"; printf '%b' "$PP" >"$S/wf.ci.yml"; printf 'on:\n  pull_request:\n' >"$S/wf.prod.yml"; echo docs/a.md >"$S/prfiles"; ship 14 pctwo; not_called pctwo "$MRG"
scenario zerogone; checks >"$S/checks.1"; touch "$S/contents.404"; ship 0 zerogone; called zerogone "$MRG"; hasnt zerogone "waiting for them"
scenario zeroflag; export SHIP_CHECK_GRACE=2; checks >"$S/checks.1"; printf '%s' "$PRWF" >"$S/wf.yml"; t0=$(date +%s); ship 0 zeroflag --allow-no-checks; called zeroflag "$MRG"; [ $(( $(date +%s) - t0 )) -ge 2 ] && ok || bad zeroflag "merged before the short wait"; has zeroflag "to register"
# Protection that does not bind admins: refUpdateRule is empty for an admin, the rule lists the check.
scenario adminbp; echo '{"data":{"repository":{"pullRequest":{"baseRef":{"refUpdateRule":{"requiredStatusCheckContexts":[]},"branchProtectionRule":{"requiredStatusCheckContexts":["tests"]}}}}}}' >"$S/ref_rule.json"; checks "$(cr diff COMPLETED SUCCESS false)" >"$S/checks.1"; ship 14 adminbp; has adminbp "tests"; not_called adminbp "$MRG"
scenario adminbp2; echo '{"data":{"repository":{"pullRequest":{"baseRef":{"refUpdateRule":{"requiredStatusCheckContexts":[]},"branchProtectionRule":{"requiredStatusCheckContexts":["tests"]}}}}}}' >"$S/ref_rule.json"; checks "$(cr diff COMPLETED SUCCESS false)" >"$S/checks.1"; checks "$(cr diff COMPLETED SUCCESS false)" "$(cr tests IN_PROGRESS)" >"$S/checks.2"; checks "$(cr diff COMPLETED SUCCESS false)" "$(cr tests COMPLETED FAILURE)" >"$S/checks.3"; export SHIP_MISSING_GRACE=30; ship 10 adminbp2; has adminbp2 "FAILED: tests"; not_called adminbp2 "$MRG"
scenario nobpr; echo '{"data":{"repository":{"pullRequest":{"baseRef":{"refUpdateRule":{"requiredStatusCheckContexts":["tests"]},"branchProtectionRule":null}}}}}' >"$S/ref_rule.json"; checks "$(cr diff COMPLETED SUCCESS false)" >"$S/checks.1"; ship 14 nobpr
scenario comment; export SHIP_CHECK_GRACE=0; checks >"$S/checks.1"; printf '# pull_request is not used here\non: workflow_dispatch\n' >"$S/wf.yml"; ship 0 comment
# Nothing required and a run still going, as between a job and its needs: wait, within the timeout.
RUNNING='[{"status":"in_progress"}]'
scenario rhead; export SHIP_POLL=0.2; checks "$(cr a COMPLETED SUCCESS false)" >"$S/checks.1"; printf '%s\n' "$RUNNING" >"$S/runs_head.1"; echo '[]' >"$S/runs_head.2"; ship 4 rhead --no-deploy-watch; has rhead "not finished: 1"; called rhead "$MRG"
scenario rhead2; export SHIP_POLL=0.2; printf '%s\n' "$RUNNING" >"$S/runs_head.1"; printf '%s\n' "$RUNNING" >"$S/runs_head.2"; echo '[]' >"$S/runs_head.3"; checks "$(cr a COMPLETED SUCCESS false)" >"$S/checks.1"; checks "$(cr a COMPLETED SUCCESS false)" >"$S/checks.2"; checks "$(cr a COMPLETED SUCCESS false)" "$(cr b COMPLETED FAILURE false)" >"$S/checks.3"; ship 10 rhead2; not_called rhead2 "$MRG"
scenario rhead3; export SHIP_POLL=0.2 SHIP_CHECK_TIMEOUT=2; checks "$(cr a COMPLETED SUCCESS false)" >"$S/checks.1"; printf '%s\n' "$RUNNING" >"$S/runs_head.1"; ship 30 rhead3; not_called rhead3 "$MRG"; unset SHIP_CHECK_TIMEOUT
scenario rhead4; export SHIP_POLL=0.2; checks "$(cr a COMPLETED SUCCESS false)" >"$S/checks.1"; echo 1 >"$S/fail.runhead"; ship 4 rhead4 --no-deploy-watch; has rhead4 "not finished: unknown"
# Nothing required: an old pass does not settle it, more checks can still come. Wait from ship's start.
scenario settledold; export SHIP_CHECK_GRACE=2; checks "$(crt a COMPLETED SUCCESS 2020-01-01T00:00:00Z false)" >"$S/checks.1"; t0=$(date +%s); ship 0 settledold; has settledold "to register"; [ $(( $(date +%s) - t0 )) -ge 2 ] && ok || bad settledold "an old pass skipped the wait"
scenario settledlate; export SHIP_CHECK_GRACE=2; checks "$(crt a COMPLETED SUCCESS 2020-01-01T00:00:00Z false)" >"$S/checks.1"; checks "$(crt a COMPLETED SUCCESS 2020-01-01T00:00:00Z false)" >"$S/checks.2"; checks "$(crt a COMPLETED SUCCESS 2020-01-01T00:00:00Z false)" "$(crt b COMPLETED FAILURE "" false)" >"$S/checks.3"; export SHIP_POLL=0.3; ship 10 settledlate; not_called settledlate "$MRG"
scenario settledreq; export SHIP_CHECK_GRACE=60; t0=$(date +%s); ship 0 settledreq; [ $(( $(date +%s) - t0 )) -lt 8 ] && ok || bad settledreq "a required set should not wait"
# Rulesets: only "none to read" means none. A rate limit is an API error, retried.
scenario rules403; touch "$S/rules.403"; echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"tests"}]}}]' >"$S/rules.json"; checks "$(cr other COMPLETED SUCCESS false)" >"$S/checks.1"; ship 14 rules403; has rules403 "API error"; has rules403 "tests"; not_called rules403 "$MRG"
# UNSTABLE is what a non-required red looks like, and it stops the run too.
scenario unstableok; checks "$(cr test COMPLETED SUCCESS)" "$(cr lint COMPLETED FAILURE false)" >"$S/checks.1"; pr_json OPEN false MERGEABLE UNSTABLE "$PIN" >"$S/pr.1"; ship 10 unstableok; not_called unstableok "$MRG"
# Advisory: ship.conf names checks whose red does not stop the run. The RESULT line says so.
scenario adv1; echo 'o/r advisory=lint|e2e' >"$S/ship.conf"; checks "$(cr test COMPLETED SUCCESS)" "$(cr lint COMPLETED FAILURE false)" >"$S/checks.1"; ship 0 adv1; called adv1 "$MRG"; grep -q 'RESULT exit=0.*lint failed' <<<"$OUT" && ok || bad adv1 "not in RESULT"
scenario adv2; echo 'o/r advisory=lint|e2e' >"$S/ship.conf"; checks "$(cr test COMPLETED SUCCESS)" "$(cr e2e COMPLETED CANCELLED false)" >"$S/checks.1"; ship 0 adv2; grep -q 'RESULT exit=0.*e2e cancelled' <<<"$OUT" && ok || bad adv2 "not in RESULT"
# Nothing required, and the only check is advisory: it counts as reported, and still names itself.
scenario adv3; echo 'o/r advisory=lint' >"$S/ship.conf"; checks "$(cr lint COMPLETED FAILURE false)" >"$S/checks.1"; ship 0 adv3; called adv3 "$MRG"; grep -q 'RESULT exit=0.*lint failed' <<<"$OUT" && ok || bad adv3 "not in RESULT"
# Required beats advisory, by rollup flag or by rules.
scenario adv4; echo 'o/r advisory=test' >"$S/ship.conf"; checks "$(cr test COMPLETED FAILURE)" >"$S/checks.1"; ship 10 adv4; not_called adv4 "$MRG"
scenario adv5; echo 'o/r advisory=test' >"$S/ship.conf"; echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"test"}]}}]' >"$S/rules.json"; checks "$(cr test COMPLETED FAILURE false)" >"$S/checks.1"; ship 10 adv5; not_called adv5 "$MRG"
# A name not listed, another repo's line, a green advisory: nothing changes.
scenario adv6; echo 'o/r advisory=e2e' >"$S/ship.conf"; checks "$(cr test COMPLETED SUCCESS)" "$(cr lint COMPLETED FAILURE false)" >"$S/checks.1"; ship 10 adv6; not_called adv6 "$MRG"
scenario adv7; echo 'x/y advisory=lint' >"$S/ship.conf"; checks "$(cr test COMPLETED SUCCESS)" "$(cr lint COMPLETED FAILURE false)" >"$S/checks.1"; ship 10 adv7; not_called adv7 "$MRG"
scenario adv8; echo 'o/r advisory=lint' >"$S/ship.conf"; checks "$(cr test COMPLETED SUCCESS)" "$(cr lint COMPLETED SUCCESS false)" >"$S/checks.1"; ship 0 adv8; hasnt adv8 "Advisory"
# Reruns: the newest run of a name decides, whichever way it went.
T1=2026-01-01T10:00:00Z; T2=2026-01-01T10:05:00Z
scenario rrcs; checks "$(crt doc COMPLETED CANCELLED $T1)" "$(crt doc COMPLETED SUCCESS $T2)" >"$S/checks.1"; ship 0 rrcs; called rrcs "$MRG"
scenario rrcs2; checks "$(crt doc COMPLETED SUCCESS $T2)" "$(crt doc COMPLETED CANCELLED $T1)" >"$S/checks.1"; ship 0 rrcs2; called rrcs2 "$MRG"
scenario rrfs; checks "$(crt doc COMPLETED FAILURE $T1)" "$(crt doc COMPLETED SUCCESS $T2)" >"$S/checks.1"; ship 0 rrfs; called rrfs "$MRG"
scenario rrsf; checks "$(crt doc COMPLETED SUCCESS $T1)" "$(crt doc COMPLETED FAILURE $T2)" >"$S/checks.1"; ship 10 rrsf; not_called rrsf "$MRG"
scenario rrsc; checks "$(crt doc COMPLETED SUCCESS $T1)" "$(crt doc COMPLETED CANCELLED $T2)" >"$S/checks.1"; ship 11 rrsc; not_called rrsc "$MRG"
scenario rrsp; export SHIP_CHECK_TIMEOUT=0; checks "$(crt doc COMPLETED SUCCESS $T1)" "$(crt doc QUEUED "" "")" >"$S/checks.1"; ship 30 rrsp; not_called rrsp "$MRG"
scenario rrredns; checks "$(crt doc COMPLETED FAILURE "")" "$(crt doc COMPLETED SUCCESS $T2)" >"$S/checks.1"; ship 10 rrredns; not_called rrredns "$MRG"
scenario rrnostart; checks "$(crt doc COMPLETED CANCELLED "")" "$(crt doc COMPLETED SUCCESS $T2)" >"$S/checks.1"; ship 0 rrnostart; called rrnostart "$MRG"
scenario rrtie; checks "$(crt doc COMPLETED SUCCESS $T2)" "$(crt doc COMPLETED FAILURE $T2)" >"$S/checks.1"; ship 10 rrtie; not_called rrtie "$MRG"

# --- transient API errors are tolerated, then fatal
scenario blip; echo 2 >"$S/fail.checks"; ship 0 blip; has blip "API error"
scenario apidead; echo 99 >"$S/fail.checks"; ship 1 apidead; has apidead "5 straight"; not_called apidead "$MRG"

# --- merge outcomes
scenario mergefail; echo "GraphQL: Pull Request is not mergeable" >"$S/merge.fail"; ship 15 mergefail; has mergefail "not mergeable"; has mergefail "Nothing deleted"; not_called mergefail "$DEL"
scenario mergemoved; echo "Head branch was modified" >"$S/merge.fail"; pr_json OPEN false MERGEABLE CLEAN "$PIN" >"$S/pr.1"; pr_json OPEN false MERGEABLE CLEAN "$PIN" >"$S/pr.2"; pr_json OPEN false MERGEABLE CLEAN "$OTHER" >"$S/pr.3"
ship 5 mergemoved; not_called mergemoved "$DEL"
scenario landed; echo "network error" >"$S/merge.fail"; touch "$S/merge.lands_anyway"; ship 0 landed; called landed "$DEL"
scenario unconfirmed; touch "$S/merge.silent"; ship 16 unconfirmed; has unconfirmed "MERGE STATE UNKNOWN"; not_called unconfirmed "$DEL"
scenario extmerge; for i in 1 2 3; do pr_json OPEN false MERGEABLE BLOCKED "$PIN" >"$S/pr.$i"; done; pr_json MERGED false UNKNOWN UNKNOWN "$PIN" >"$S/pr.4"; checks "$(cr test IN_PROGRESS)" >"$S/checks.1"
ship 0 extmerge; has extmerge "while ship waited"; not_called extmerge "$MRG"; called extmerge "$DEL"
scenario extother; for i in 1 2 3; do pr_json OPEN false MERGEABLE BLOCKED "$PIN" >"$S/pr.$i"; done; pr_json MERGED false UNKNOWN UNKNOWN "$OTHER" >"$S/pr.4"; checks "$(cr test IN_PROGRESS)" >"$S/checks.1"
ship 5 extother; not_called extother "$DEL"

# Concurrent merges: another merge moved the base. Go back to waiting; that is not a failure.
for e in "Base branch was modified. Review and try the merge again." "Pull Request is not mergeable"; do
  scenario mbase; echo "$e" >"$S/merge.failonce"; ship 0 mbase; has mbase "going back to waiting"; [ "$(grep -c "$MRG" "$S/calls.log")" = 2 ] && ok || bad mbase "merge calls: $(grep -c "$MRG" "$S/calls.log")"; [ ! -e "$S/state/active/$(run_of)" ] && ok || bad mbase "flag left"
done
# After that the gates decide: a conflict is a conflict, and it never loops forever.
scenario mbasec; echo "Pull Request is not mergeable" >"$S/merge.failonce"; pr_json OPEN false MERGEABLE CLEAN "$PIN" >"$S/pr.1"; pr_json OPEN false MERGEABLE CLEAN "$PIN" >"$S/pr.2"; pr_json OPEN false CONFLICTING DIRTY "$PIN" >"$S/pr.3"; ship 12 mbasec
scenario mconf; echo "GraphQL: Pull Request has merge conflicts (mergePullRequest)" >"$S/merge.failonce"; pr_json OPEN false MERGEABLE CLEAN "$PIN" >"$S/pr.1"; pr_json OPEN false MERGEABLE CLEAN "$PIN" >"$S/pr.2"; pr_json OPEN false CONFLICTING DIRTY "$PIN" >"$S/pr.3"; ship 12 mconf; has mconf "conflicts with"; not_called mconf "$DEL"
# GitHub's own "something went wrong" says nothing about the merge, GraphQL or not.
scenario mwrong; echo "GraphQL: Something went wrong while executing your query (mergePullRequest)" >"$S/merge.fail"; ship 16 mwrong; [ "$(grep -c "$MRG" "$S/calls.log")" = 1 ] && ok || bad mwrong "retried an unknown merge"
scenario mbasel; echo "Base branch was modified" >"$S/merge.fail"; ship 15 mbasel; [ "$(grep -c "$MRG" "$S/calls.log")" = 5 ] && ok || bad mbasel "merge calls: $(grep -c "$MRG" "$S/calls.log")"; has mbasel "kept failing"; not_called mbasel "$DEL"

# --- branch deletion rules
scenario stacked; echo '[{"number":9}]' >"$S/prs_base.json"; ship 0 stacked; has stacked "open PR #9 uses it as a base"; not_called stacked "$DEL"
scenario headpr; echo '[{"number":8,"isCrossRepository":false}]' >"$S/prs_head.json"; ship 0 headpr; has headpr "uses it as a head"; not_called headpr "$DEL"
scenario forkpr; echo '[{"number":8,"isCrossRepository":true}]' >"$S/prs_head.json"; ship 0 forkpr; called forkpr "$DEL"
scenario movedref; echo "{\"object\":{\"sha\":\"$OTHER\"}}" >"$S/ref.json"; ship 0 movedref; has movedref "holds unmerged commits"; not_called movedref "$DEL"
scenario gone; rm "$S/ref.json"; ship 0 gone; has gone "already gone"; not_called gone "$DEL"
scenario fork; pr_json OPEN false MERGEABLE CLEAN "$PIN" main true >"$S/pr.1"; ship 0 fork; has fork "on a fork"; not_called fork "$DEL"
# A failed delete is not a failed merge: retry, report GitHub's own words, note it in the record.
scenario delfail; touch "$S/delete.fail"; ship 0 delfail; has delfail "delete failed 3 times: gh: Something went wrong"; hasnt delfail "may have moved"; has delfail "left behind"; grep -q ' result 0 .*left behind' "$(recf)" && ok || bad delfail "not in the record"
scenario delflaky; echo 2 >"$S/delete.flaky"; ship 0 delflaky; has delflaky "deleted remote branch feat/x"; hasnt delflaky "left behind"; [ "$(grep -c updateRefs "$S/calls.log")" = 3 ] && ok || bad delflaky "tries: $(grep -c updateRefs "$S/calls.log")"

# --- deploy watch outcomes
scenario dfail; echo "[$(run 2 'Deploy Prod' completed failure)]" >"$S/runs_commit.1"; ship 20 dfail; has dfail "DEPLOY FAILED"; has dfail "https://gh/run/Deploy Prod"; called dfail "$DEL"
scenario dcancel; echo "[$(run 2 'Deploy Prod' completed cancelled)]" >"$S/runs_commit.1"; echo "[{\"headSha\":\"$MERGE\",\"status\":\"completed\",\"url\":\"https://gh/same\"}]" >"$S/runs_wf.json"; ship 20 dcancel
# A pending deploy replaced by a newer one is not a failure: the newer one carries this commit.
scenario dsuper; echo "[$(run 2 'Deploy Prod' completed cancelled)]" >"$S/runs_commit.1"; echo "[{\"headSha\":\"$OTHER\",\"status\":\"completed\",\"conclusion\":\"success\",\"url\":\"https://gh/newer\"}]" >"$S/runs_wf.json"; ship 0 dsuper; has dsuper "superseded by https://gh/newer"
# The newer deploy's result decides: a failed one is this commit's failure too, a running one is still running.
scenario dsuperf; echo "[$(run 2 'Deploy Prod' completed cancelled)]" >"$S/runs_commit.1"; echo "[{\"headSha\":\"$OTHER\",\"status\":\"completed\",\"conclusion\":\"failure\",\"url\":\"https://gh/newer\"}]" >"$S/runs_wf.json"; ship 20 dsuperf; has dsuperf "https://gh/newer"
scenario dsuperr; export SHIP_DEPLOY_TIMEOUT=1; echo "[$(run 2 'Deploy Prod' completed cancelled)]" >"$S/runs_commit.1"; echo "[{\"headSha\":\"$OTHER\",\"status\":\"in_progress\",\"url\":\"https://gh/newer\"}]" >"$S/runs_wf.json"; ship 22 dsuperr; has dsuperr "still running"
scenario dnone; echo '[]' >"$S/runs_commit.1"; ship 21 dnone; has dnone "NO DEPLOY STARTED"
scenario dskip; echo "[$(run 2 'Deploy Prod' completed skipped)]" >"$S/runs_commit.1"; ship 21 dskip; has dskip "SKIPPED"
scenario dwait; echo "[$(run 2 'Deploy Prod' in_progress '')]" >"$S/runs_commit.1"; export SHIP_DEPLOY_TIMEOUT=0; ship 22 dwait; has dwait "still running"
# A CI run still going keeps the start window open, for a deploy chained off it.
scenario chained; echo "[$(run 1 CI in_progress '')]" >"$S/runs_commit.1"; echo "[$(run 1 CI completed success),$(run 2 'Deploy Prod' completed success)]" >"$S/runs_commit.2"; ship 0 chained
scenario nowatch; ship 4 nowatch --no-deploy-watch; has nowatch "NOT verified"; not_called nowatch "--commit"
scenario noflow; echo '[{"id":1,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]' >"$S/workflows.json"; ship 4 noflow; has noflow "NOT verified"
scenario disabled; echo '[{"id":2,"name":"Deploy","path":"d.yml","state":"disabled_manually"}]' >"$S/workflows.json"; ship 4 disabled; has disabled "no deploy source found"
scenario basewatch; pr_json OPEN false MERGEABLE CLEAN "$PIN" develop >"$S/pr.1"; ship 4 basewatch; has basewatch "into develop"
scenario byfile; echo '[{"id":2,"name":"Ship it","path":".github/workflows/deploy-prod.yml","state":"active"}]' >"$S/workflows.json"; echo "[$(run 2 'Ship it' completed success)]" >"$S/runs_commit.1"; ship 0 byfile

# --- ship.conf
scenario confnames
echo '[{"id":1,"name":"CI","path":"ci.yml","state":"active"},{"id":2,"name":"Deploy Prod","path":"prod.yml","state":"active"},{"id":3,"name":"Release","path":"rel.yml","state":"active"}]' >"$S/workflows.json"
printf '# comment\n\nO/R deploy=release|other\nx/y deploy=none\n' >"$S/ship.conf"
echo "[$(run 3 Release completed success)]" >"$S/runs_commit.1"; ship 0 confnames; has confnames "workflows [Release]"
scenario confnone; printf 'o/r deploy=none\n' >"$S/ship.conf"; ship 4 confnone; not_called confnone "workflow list"
scenario confbad; printf 'o/r deploy=NoSuch\n' >"$S/ship.conf"; ship 21 confbad; has confbad "NO DEPLOY STARTED"; has confbad "NoSuch"

# --- non-Actions deploys
noflows() { echo '[{"id":1,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]' >"$S/workflows.json"; }
dep() { echo "[{\"id\":$1,\"environment\":\"$2\",\"created_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]"; }
dst() { echo "[{\"state\":\"$1\",\"log_url\":\"https://vercel/log\"}]"; }
scenario vercel; noflows; dep 5 Production >"$S/deploy_sha.1"; dep 5 Production >"$S/deploy_recent.json"
dst pending >"$S/dstatus_5.1"; dst in_progress >"$S/dstatus_5.2"; dst in_progress >"$S/dstatus_5.3"; dst success >"$S/dstatus_5.4"
ship 0 vercel; has vercel "deployment Production https://vercel/log"; has vercel "external [Production]"
scenario vfail; noflows; dep 5 Production >"$S/deploy_sha.1"; dst failure >"$S/dstatus_5.1"; ship 20 vfail; has vfail "DEPLOY FAILED"; has vfail "https://vercel/log"
scenario verror; noflows; dep 5 Production >"$S/deploy_sha.1"; dst error >"$S/dstatus_5.1"; ship 20 verror
scenario vinactive; noflows; dep 5 Production >"$S/deploy_sha.1"; echo '[{"state":"inactive","log_url":"https://v/l"},{"state":"success"}]' >"$S/dstatus_5.1"; ship 0 vinactive
scenario vinactive2; noflows; dep 5 Production >"$S/deploy_sha.1"; dst inactive >"$S/dstatus_5.1"; ship 20 vinactive2
# History says it deploys here, and the merge commit got nothing: that is the alarm.
scenario vmissing; noflows; dep 5 Production >"$S/deploy_recent.json"; dst success >"$S/dstatus_5.1"; ship 21 vmissing; has vmissing "NO DEPLOY STARTED"; has vmissing "external [Production]"
# A preview deployment is not a deploy.
scenario vpreview; noflows; dep 5 Preview >"$S/deploy_sha.1"; dst success >"$S/dstatus_5.1"; dep 5 Preview >"$S/deploy_recent.json"; ship 4 vpreview; has vpreview "no deploy source found"
scenario vprevstat; noflows; dep 5 Preview >"$S/deploy_sha.1"; dst success >"$S/dstatus_5.1"; echo '{"statuses":[{"context":"Vercel","state":"success","target_url":"https://v/p"}]}' >"$S/cstatus.1"; echo '{"check_runs":[]}' >"$S/cruns.1"; ship 21 vprevstat; hasnt vprevstat "and deployed"
scenario vpreconf; noflows; dep 5 Preview >"$S/deploy_sha.1"; dst success >"$S/dstatus_5.1"; printf 'o/r deploy=Preview\n' >"$S/ship.conf"; ship 0 vpreconf
# Commit status only, the way some hosts report. Pending, then success; failure too.
cst() { echo "{\"statuses\":[{\"context\":\"$1\",\"state\":\"$2\",\"target_url\":\"https://host/d\"}]}"; }
scenario cstat; noflows; cst netlify/site pending >"$S/cstatus.1"; cst netlify/site pending >"$S/cstatus.2"; cst netlify/site success >"$S/cstatus.3"; ship 0 cstat; has cstat "status netlify/site https://host/d"
scenario cstatf; noflows; cst Vercel failure >"$S/cstatus.1"; ship 20 cstatf
scenario cstatother; noflows; cst codecov/project success >"$S/cstatus.1"; ship 4 cstatother
# A status name only ship.conf knows about.
scenario cstatconf; noflows; cst acme-ship success >"$S/cstatus.1"; printf 'o/r deploy=acme-ship\n' >"$S/ship.conf"; ship 0 cstatconf
# Check run from an outside app.
crn() { echo "{\"check_runs\":[{\"name\":\"$1\",\"app\":{\"slug\":\"$2\"},\"status\":\"$3\",\"conclusion\":\"$4\",\"details_url\":\"https://host/c\"}]}"; }
scenario crok; noflows; crn "Cloudflare Pages" cloudflare-pages completed success >"$S/cruns.1"; ship 0 crok; has crok "check Cloudflare Pages"
scenario crfail; noflows; crn "Cloudflare Pages" cloudflare-pages completed failure >"$S/cruns.1"; ship 20 crfail
scenario cractions; noflows; crn "deploy" github-actions completed success >"$S/cruns.1"; ship 4 cractions
# A workflow and an outside deploy together: both must pass.
scenario both; dep 5 Production >"$S/deploy_sha.1"; dst failure >"$S/dstatus_5.1"; ship 20 both; has both "DEPLOY FAILED: deployment Production"
scenario vapi; noflows; dep 5 Production >"$S/deploy_sha.1"; dst success >"$S/dstatus_5.1"; ship 0 vapi; not_called vapi "repos/o/r/deployments -X"

# --- --watch-sha
scenario wsha; noflows; dep 5 Production >"$S/deploy_sha.1"; dst success >"$S/dstatus_5.1"; OUT=$("$BASH" "$BIN/ship" --watch-sha "$MERGE" --repo o/r 2>&1); [ $? = 0 ] && ok || bad wsha "exit"; has wsha "commit ccccccccc and deployed"; not_called wsha "$MRG"; not_called wsha "pr view"

# --- default: return at the merge, deploy watched in the background
scenario bgok; echo "[$(run 2 'Deploy Prod' in_progress '')]" >"$S/runs_commit.1"; t0=$(date +%s); OUT=$("$BASH" "$BIN/ship" 7 --repo o/r 2>&1); RC=$?; [ "$RC" = 0 ] && ok || bad bgok "exit $RC"; has bgok "RESULT exit=0"; has bgok "deploy watch running"; has bgok "$MERGE"; [ $(( $(date +%s) - t0 )) -lt 5 ] && ok || bad bgok "did not return at once"
id=$(run_of); status "$id"; [ "$RC" = 50 ] && ok || bad bgok "status while watching: $RC"; has bgok "still running"; [ -e "$S/state/active/$id" ] && ok || bad bgok "not flagged while watching"
echo "[$(run 2 'Deploy Prod' completed success)]" >"$S/runs_commit.1"; rm -f "$S/runs_commit.counter"; n=0; until grep -q '^[0-9]* deploy ' "$S/state/runs/$id" || [ "$n" -gt 100 ]; do sleep 0.1; n=$((n+1)); done; status "$id"; [ "$RC" = 0 ] && ok || bad bgok "status after: $RC"; has bgok "deploy: RESULT exit=0"; [ ! -e "$S/state/active/$id" ] && ok || bad bgok "flag left after success"
# Failed deploy in the background: status reports it and the flag stays until someone looks.
scenario bgfail; echo "[$(run 2 'Deploy Prod' completed failure)]" >"$S/runs_commit.1"; OUT=$("$BASH" "$BIN/ship" 7 --repo o/r 2>&1); RC=$?; [ "$RC" = 0 ] && ok || bad bgfail "exit $RC"; id=$(run_of); n=0; until grep -q '^[0-9]* deploy ' "$S/state/runs/$id" || [ "$n" -gt 100 ]; do sleep 0.1; n=$((n+1)); done; [ -e "$S/state/active/$id" ] && ok || bad bgfail "not flagged"; status; [ "$RC" = 20 ] && ok || bad bgfail "status: $RC"; has bgfail "DEPLOY FAILED"; [ ! -e "$S/state/active/$id" ] && ok || bad bgfail "status did not clear the flag"
# The watch survives its caller's whole process group going away, and its death is reported.
scenario bgdead; echo "[$(run 2 'Deploy Prod' in_progress '')]" >"$S/runs_commit.1"; OUT=$("$BASH" "$BIN/ship" 7 --repo o/r 2>&1); id=$(run_of); w=$(sed -n 's/^[0-9]* proc //p' "$S/state/runs/$id" | tail -1 | cut -d' ' -f1); [ "$(ps -o pgid= -p "$w" | tr -d ' ')" = "$w" ] && ok || bad bgdead "watch is not in its own session"; kill -9 "$w"; sleep 0.2; status "$id"; [ "$RC" = 42 ] && ok || bad bgdead "status: $RC"; has bgdead "DEPLOY WATCH DIED"; has bgdead "ship --watch-sha $MERGE"
# Flags that keep or skip the watch.
scenario bgnone; OUT=$("$BASH" "$BIN/ship" 7 --repo o/r --no-deploy-watch 2>&1); RC=$?; [ "$RC" = 4 ] && ok || bad bgnone "exit $RC"; hasnt bgnone "deploy watch running"
scenario bgbase; pr_json OPEN false MERGEABLE CLEAN "$PIN" develop >"$S/pr.1"; OUT=$("$BASH" "$BIN/ship" 7 --repo o/r 2>&1); RC=$?; [ "$RC" = 4 ] && ok || bad bgbase "exit $RC"

# --- kill -9 at each stage
for st in stage-waiting before-merge stage-merging after-merge-call after-confirm; do
  scenario "k9$st"; arm "$st"; start_bg --no-deploy-watch
  wait_for "$S/hook/$st.reached" 10 && ok || bad "k9$st" "never got there"
  kill -CONT "$P"; kill -9 "$P"; wait "$P" 2>/dev/null; unset SHIP_TEST_HOOK
  status; if [ "$st" = stage-merging ]; then [ "$RC" = 16 ] && ok || bad "k9$st" "status exit $RC"; else [ "$RC" = 42 ] && ok || bad "k9$st" "status exit $RC"; fi; has "k9$st" "DIED at stage"
  case "$st" in
    stage-waiting|before-merge) has "k9$st" "sent no merge request"; hasnt "k9$st" "Safe to rerun"; not_called "k9$st" "$MRG" ;;
    stage-merging) has "k9$st" "may still land"; hasnt "k9$st" "Safe to rerun" ;;
    *) has "k9$st" "IS MERGED"; has "k9$st" "ship --watch-sha" ;;
  esac
  # Nothing is left behind to stop the next run.
  rm -f "$S/merged"; t0=$(date +%s); OUT=$("$BASH" "$BIN/ship" 7 --repo o/r --no-deploy-watch 2>&1); RC=$?; [ "$RC" = 4 ] && ok || bad "k9$st" "next run exit $RC"; [ $(( $(date +%s) - t0 )) -lt 8 ] && ok || bad "k9$st" "next run was slow"
done

# --- the last moments before the merge
# Every merge follows two clear reads in a row, the second right before the merge.
scenario tworeads; ship 4 tworeads --no-deploy-watch; [ "$(sed -n "/$MRG/q;p" "$S/calls.log" | grep -c statusCheckRollup)" -ge 2 ] && ok || bad tworeads "one read before the merge"
scenario flip2; checks "$(cr test COMPLETED SUCCESS)" >"$S/checks.1"; checks "$(cr test COMPLETED FAILURE)" >"$S/checks.2"; ship 10 flip2 --no-deploy-watch; not_called flip2 "$MRG"
# A pending read between clear ones starts the count again.
scenario flip3; checks "$(cr test COMPLETED SUCCESS)" >"$S/checks.1"; checks "$(cr test IN_PROGRESS "")" >"$S/checks.2"; checks "$(cr test COMPLETED SUCCESS)" >"$S/checks.3"; checks "$(cr test COMPLETED FAILURE)" >"$S/checks.4"; ship 10 flip3 --no-deploy-watch; not_called flip3 "$MRG"
# An 8s freeze between the reads with a flip to red: no merge. With no flip: the merge goes out.
scenario freeze8; arm between-reads; start_bg --no-deploy-watch; wait_for "$S/hook/between-reads.reached" 10 && ok || bad freeze8 "no stop"; checks "$(cr test COMPLETED FAILURE)" >"$S/checks.1"; rm -f "$S/checks.counter"; sleep 8; kill -CONT "$P"; wait "$P"; RC=$?; [ "$RC" = 10 ] && ok || bad freeze8 "exit $RC"; not_called freeze8 "$MRG"; unset SHIP_TEST_HOOK
scenario freeze8ok; arm between-reads; start_bg --no-deploy-watch; wait_for "$S/hook/between-reads.reached" 10; sleep 2; kill -CONT "$P"; wait "$P"; RC=$?; [ "$RC" = 4 ] && ok || bad freeze8ok "exit $RC"; called freeze8ok "$MRG"; unset SHIP_TEST_HOOK
# Caller killed alone, ship not signalled: it must not merge with nobody to tell.
scenario callerdead; arm before-merge; "$BASH" -c '"$0" "$1" 7 --repo o/r --no-deploy-watch >"$2" 2>&1 </dev/null & echo $! >"$3"; wait' "$BASH" "$BIN/ship" "$S/out" "$S/fpid" & CL=$!; wait_for "$S/hook/before-merge.reached" 10 && ok || bad callerdead "no stop"; F=$(cat "$S/fpid"); kill -9 "$CL"; wait "$CL" 2>/dev/null; kill -CONT "$F"; n=0; while kill -0 "$F" 2>/dev/null && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n+1)); done; unset SHIP_TEST_HOOK; status; [ "$RC" = 41 ] && ok || bad callerdead "status $RC"; not_called callerdead "$MRG"
# An agent crashes under a surviving shell wrapper: wrapper alive, its parent changed.
scenario gpdead; arm before-merge; "$BASH" -c '"$0" -c '"'"'"$0" "$1" 7 --repo o/r --no-deploy-watch >"$2" 2>&1 </dev/null & echo $! >"$3"; wait'"'"' "$0" "$1" "$2" "$3" & wait' "$BASH" "$BIN/ship" "$S/out" "$S/fpid" & GP=$!; wait_for "$S/hook/before-merge.reached" 10 && ok || bad gpdead "no stop"; F=$(cat "$S/fpid"); W=$(ps -o ppid= -p "$F" | tr -d ' '); kill -9 "$GP"; wait "$GP" 2>/dev/null; sleep 0.3; kill -0 "$W" 2>/dev/null && ok || bad gpdead "wrapper died too"; kill -CONT "$F"; n=0; while kill -0 "$F" 2>/dev/null && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n+1)); done; unset SHIP_TEST_HOOK; kill "$W" 2>/dev/null; status; [ "$RC" = 41 ] && ok || bad gpdead "status $RC"; not_called gpdead "$MRG"
# A merge with no confirmation: the record must not outlive GitHub's answer.
scenario mcut; touch "$S/merge.silent"; ship 16 mcut; has mcut "MERGE STATE UNKNOWN"; not_called mcut "$DEL"; id=$(run_of)
status "$id"; [ "$RC" = 16 ] && ok || bad mcut "status, open: $RC"; has mcut "may still land"; hasnt mcut "Safe to rerun"; [ -e "$S/state/active/$id" ] && ok || bad mcut "flag cleared on no answer"
touch "$S/merged"; status "$id"; [ "$RC" = 4 ] && ok || bad mcut "status, merged: $RC"; has mcut "IS MERGED"; has mcut "ship --watch-sha"; [ ! -e "$S/state/active/$id" ] && ok || bad mcut "flag kept after a final answer"
# Old enough, GitHub says open: now it is safe to say so.
scenario mcut2; touch "$S/merge.silent"; ship 16 mcut2; export SHIP_INFLIGHT_WINDOW=0; status; [ "$RC" = 15 ] && ok || bad mcut2 "status $RC"; has mcut2 "Safe to rerun"; unset SHIP_INFLIGHT_WINDOW
# GitHub unreachable from --status: unknown, flag stays.
scenario munreach; touch "$S/merge.silent"; ship 16 munreach; id=$(run_of); mv "$S/pull_open.json" "$S/x"; touch "$S/pulls.fail"; status "$id"; [ "$RC" = 16 ] && ok || bad munreach "status $RC"; has munreach "could not be reached"; [ -e "$S/state/active/$id" ] && ok || bad munreach "flag cleared"
# A 502 from the merge call that lands seconds later: not a refusal, and the watch still starts.
scenario m502; export SHIP_MERGE_CONFIRM_TIMEOUT=20; echo 'HTTP 502: Bad Gateway' >"$S/merge.fail"; ( n=0; until grep -q "$MRG" "$S/calls.log" 2>/dev/null || [ "$n" -gt 300 ]; do sleep 0.1; n=$((n + 1)); done; sleep 3; touch "$S/merged" ) & OUT=$("$BASH" "$BIN/ship" 7 --repo o/r 2>&1); RC=$?; wait; [ "$RC" = 0 ] && ok || bad m502 "exit $RC"; has m502 "deploy watch running"; has m502 "HTTP 502"; called m502 "$DEL"
# A 502 that never lands: unknown, flagged, not "failed".
scenario m502b; echo 'HTTP 502: Bad Gateway' >"$S/merge.fail"; ship 16 m502b; [ -e "$S/state/active/$(run_of)" ] && ok || bad m502b "not flagged"
# SIGTERM after the merge request went out, before an answer.
scenario msig; echo 2 >"$S/merge.delay"; start_bg --no-deploy-watch; n=0; until grep -q "$MRG" "$S/calls.log" 2>/dev/null || [ "$n" -gt 80 ]; do sleep 0.1; n=$((n+1)); done; kill -TERM "$P"; wait "$P"; RC=$?; OUT=$(cat "$S/out"); [ "$RC" = 40 ] && ok || bad msig "exit $RC"; id=$(run_of); [ -e "$S/state/active/$id" ] || grep -q ' watch ' "$S/state/runs/$id" && ok || bad msig "neither flagged nor watched"
# SIGTERM after a confirmed merge: the watch still starts, with --wait-deploy too.
for fl in "" --wait-deploy; do
  scenario "sigw$fl"; arm after-confirm; start_bg $fl; wait_for "$S/hook/after-confirm.reached" 10 && ok || bad "sigw$fl" "no stop"; kill -TERM "$P"; kill -CONT "$P"; wait "$P"; unset SHIP_TEST_HOOK; grep -q '^[0-9]* watch ' "$(recf)" && ok || bad "sigw$fl" "no watch started"
  n=0; until grep -q '^[0-9]* deploy ' "$(recf)" || [ "$n" -gt 80 ]; do sleep 0.1; n=$((n+1)); done; status; [ "$RC" = 0 ] && ok || bad "sigw$fl" "status $RC"
done
# SIGTERM to the watcher while it starts must not claim nothing merged.
scenario wsig; "$BASH" "$BIN/ship" --watch-sha "$MERGE" --repo o/r --run rid >"$S/o" 2>&1 & W=$!; mkdir -p "$S/state/runs"; sleep 0.05; kill -TERM "$W"; wait "$W"; OUT=$(cat "$S/o"); hasnt wsig "Nothing merged"
# In flight at kill -9: GitHub says open, the merge lands later. Status must not say safe.
scenario k9fly; echo 3 >"$S/merge.delay"; start_bg --no-deploy-watch; n=0; until grep -q "$MRG" "$S/calls.log" 2>/dev/null || [ "$n" -gt 80 ]; do sleep 0.1; n=$((n+1)); done; kill -9 "$P"; wait "$P" 2>/dev/null; id=$(run_of); status "$id"; [ "$RC" = 16 ] && ok || bad k9fly "status $RC"; hasnt k9fly "Safe to rerun"; [ -e "$S/state/active/$id" ] && ok || bad k9fly "flag cleared"; n=0; until [ -f "$S/merged" ] || [ "$n" -gt 60 ]; do sleep 0.1; n=$((n+1)); done; status "$id"; has k9fly "IS MERGED"; pkill -f "merge.delay" 2>/dev/null
# A refused merge that then turns out to be a conflict: status repeats the conflict, nothing else.
scenario st12; echo "GraphQL: Pull Request has merge conflicts (mergePullRequest)" >"$S/merge.failonce"; pr_json OPEN false MERGEABLE CLEAN "$PIN" >"$S/pr.1"; pr_json OPEN false MERGEABLE CLEAN "$PIN" >"$S/pr.2"; pr_json OPEN false CONFLICTING DIRTY "$PIN" >"$S/pr.3"; ship 12 st12; status; [ "$RC" = 12 ] && ok || bad st12 "status $RC"; hasnt st12 "Safe to rerun"; hasnt st12 "may still land"
# Refused, then sent again and left unanswered: that later request is still open.
scenario st2nd; echo "Base branch was modified" >"$S/merge.failonce"; touch "$S/merge.silent"; ship 16 st2nd; status; [ "$RC" = 16 ] && ok || bad st2nd "status $RC"
# Status takes a run id, not a PR number, so it cannot report or clear the wrong repo's run.
scenario byid; ship 0 byid; OUT=$("$BASH" "$BIN/ship" --status 7 2>&1); [ $? = 2 ] && ok || bad byid "accepted a PR number"; has byid "no run 7"
# Path filters: "no deploy expected" only when every workflow's filters rule the merge out.
pf() { # name exit filters-yaml file...
  local n=$1 want=$2 y=$3; shift 3; scenario "$n"; echo '[{"id":2,"name":"Deploy Prod","path":".github/workflows/prod.yml","state":"active"}]' >"$S/workflows.json"; printf '%b' "$y" >"$S/wf.yml"; printf '%s\n' "$@" >"$S/changed"; echo '[]' >"$S/runs_commit.1"; ship "$want" "$n"
}
P='on:\n  push:\n    branches: [main]\n    paths:\n'; I='on:\n  push:\n    branches: [main]\n    paths-ignore:\n'
pf pfnone 4 "$P      - 'src/**'\n" docs/a.md; has pfnone "no deploy expected"; hasnt pfnone "NO DEPLOY STARTED"
pf pfhit 21 "$P      - 'src/**'\n" docs/a.md src/x/y.py; has pfhit "NO DEPLOY STARTED"
pf igall 4 "$I      - 'docs/**'\n      - '*.md'\n" docs/a.md README.md; has igall "no deploy expected"
pf igsome 21 "$I      - 'docs/**'\n" docs/a.md src/y.py; has igsome "NO DEPLOY STARTED"
pf pfstar 4 "$P      - '*.py'\n" src/a.py
pf pfdeep 21 "$P      - '**/*.py'\n" src/a.py
pf pfroot 21 "$P      - '**/*.py'\n" a.py
pf pfroot2 4 "$P      - '**/*.py'\n" a.md
pf pfmid 21 "$P      - 'a/**/b.py'\n" a/b.py
# An event's block ends at the next event: another event's filters do not apply.
pf pfnext 21 'on:\n  push:\n    branches: [main]\n  pull_request:\n    paths:\n      - src/**\n' docs/a.md
pf pfnext2 4 'on:\n  pull_request:\n    paths:\n      - docs/**\n  push:\n    paths:\n      - src/**\n' docs/a.md
pf pfcomment2 21 "$P      - src/** # code only\n      - docs/**\n" docs/a.md
pf pfcomment3 21 "$P      - src/** # code only\n" src/a.py
pf pfcomment4 21 "$P      - 'src/**' # code only\n" src/a.py
# A deploy with no push trigger is manual: nothing to alarm about, unless chained off CI.
pf pfmanual 4 'on: workflow_dispatch\n' docs/a.md
pf pfdot 4 "$P      - 'a.py'\n" axpy
pf pfneg 4 "$P      - 'src/**'\n      - '!src/docs/**'\n" src/docs/a.md
pf pfneg2 21 "$P      - 'src/**'\n      - '!src/docs/**'\n" src/docs/a.md src/b.py
pf pfinline 4 'on:\n  push:\n    paths: [src/**, "lib/**"]\n' docs/a.md
pf pfinline2 21 'on:\n  push:\n    paths: [src/**, "lib/**"]\n' lib/a.py
pf pfsame 4 'on:\n  push:\n    paths:\n    - src/**\n' docs/a.md
pf pfcomment 4 "$P      - src/** # code only\n" docs/a.md
pf pfquoted 4 '"on":\n  push:\n    paths:\n      - src/**\n' docs/a.md
# Deploy branch filters: one that leaves out the default branch expects no deploy.
pf pfbr 4 'on:\n  push:\n    branches: [release]\n' docs/a.md; has pfbr "no deploy expected"
pf pfbrig 4 'on:\n  push:\n    branches-ignore: [main]\n' docs/a.md
pf pfbrok 21 'on:\n  push:\n    branches: [main, release]\n' docs/a.md
pf pftags 21 'on:\n  push:\n    tags: [v*]\n' docs/a.md
pf pfother 21 'on:\n  pull_request:\n    paths:\n      - src/**\n  push:\n    branches: [main]\n' docs/a.md
pf pfnofilter 21 "on: push\n" docs/a.md
pf pflist 21 "on: [push, workflow_dispatch]\n" docs/a.md
# Anything it cannot read or follow alarms.
pf pfglob 21 "$P      - 'src/[ab]/**'\n" docs/a.md
pf pfnopush 21 'on:\n  workflow_run:\n    workflows: [CI]\n' docs/a.md
pf pfcrlf 4 'on:\r\n  push:\r\n    paths:\r\n      - src/**\r\n' docs/a.md
pf pfflow 21 'on: {push: {paths: [src/**]}}\n' docs/a.md
pf pfnoon 21 'jobs:\n  a:\n    runs-on: x\n' docs/a.md
pf pfanchor 21 'on:\n  push:\n    paths: *x\n' docs/a.md
pf pfempty 21 "$P" docs/a.md
pf pfnofiles 21 "$P      - 'src/**'\n" ""
scenario pfunread; echo '[{"id":2,"name":"Deploy Prod","path":".github/workflows/prod.yml","state":"active"}]' >"$S/workflows.json"; touch "$S/contents.fail"; echo a >"$S/changed"; echo '[]' >"$S/runs_commit.1"; ship 21 pfunread
# One workflow that should have started outweighs one that rightly did not.
scenario pftwo; echo '[{"id":2,"name":"Deploy A","path":".github/workflows/a-deploy.yml","state":"active"},{"id":3,"name":"Deploy B","path":".github/workflows/b-deploy.yml","state":"active"}]' >"$S/workflows.json"; printf 'on:\n  push:\n    paths:\n      - src/**\n' >"$S/wf.a-deploy.yml"; printf 'on:\n  push:\n    branches: [main]\n' >"$S/wf.b-deploy.yml"; echo docs/a.md >"$S/changed"; echo '[]' >"$S/runs_commit.1"; ship 21 pftwo
scenario pftwo2; echo '[{"id":2,"name":"Deploy A","path":".github/workflows/a-deploy.yml","state":"active"},{"id":3,"name":"Deploy B","path":".github/workflows/b-deploy.yml","state":"active"}]' >"$S/workflows.json"; printf 'on:\n  push:\n    paths:\n      - src/**\n' >"$S/wf.a-deploy.yml"; printf 'on:\n  push:\n    paths:\n      - lib/**\n' >"$S/wf.b-deploy.yml"; echo docs/a.md >"$S/changed"; echo '[]' >"$S/runs_commit.1"; ship 4 pftwo2
# An external host deploys regardless of a workflow's filters.
scenario pfext; echo '[{"id":2,"name":"Deploy Prod","path":"p.yml","state":"active"}]' >"$S/workflows.json"; printf "$P      - 'src/**'\n" >"$S/wf.yml"; echo docs/a.md >"$S/changed"; echo '[{"id":9,"environment":"Production","created_at":"2020-01-01T00:00:00Z"}]' >"$S/deploy_recent.json"; echo '[]' >"$S/runs_commit.1"; ship 21 pfext
# A run that starts anyway is watched as usual, and in the background no alarm is left.
scenario pfbg; echo '[{"id":2,"name":"Deploy Prod","path":".github/workflows/prod.yml","state":"active"}]' >"$S/workflows.json"; printf "$P      - 'src/**'\n" >"$S/wf.yml"; echo docs/a.md >"$S/changed"; echo '[]' >"$S/runs_commit.1"; OUT=$("$BASH" "$BIN/ship" 7 --repo o/r 2>&1); id=$(run_of); n=0; until grep -q '^[0-9]* deploy ' "$S/state/runs/$id" || [ "$n" -gt 80 ]; do sleep 0.1; n=$((n+1)); done; [ ! -e "$S/state/active/$id" ] && ok || bad pfbg "flagged"; [ -z "$(printf '{"session_id":"z"}' | CLAUDE_CODE_ENTRYPOINT=cli "$BIN/ship-notice" stop)" ] && ok || bad pfbg "hook spoke"
scenario pfstart; echo '[{"id":2,"name":"Deploy Prod","path":".github/workflows/prod.yml","state":"active"}]' >"$S/workflows.json"; printf "$P      - 'src/**'\n" >"$S/wf.yml"; echo docs/a.md >"$S/changed"; ship 0 pfstart; has pfstart "and deployed"
# A deploy pushed out of the general list by scheduled runs on the same commit is still seen.
scenario crowded; echo "[$(run 1 CI completed success)]" >"$S/runs_commit.1"; echo "[$(run 2 'Deploy Prod' completed success)]" >"$S/runs_direct.json"; ship 0 crowded; has crowded "and deployed"; called crowded "--workflow 2 --commit"
# environment: on a filtered job makes a Deployments record, and that is no outside deploy.
scenario pfenv; echo '[{"id":2,"name":"Deploy Prod","path":".github/workflows/prod.yml","state":"active"}]' >"$S/workflows.json"; printf "$P      - 'src/**'\n" >"$S/wf.yml"; echo docs/a.md >"$S/changed"; echo '[{"id":9,"environment":"production","created_at":"2020-01-01T00:00:00Z","creator":{"login":"github-actions[bot]"}}]' >"$S/deploy_recent.json"; echo '[]' >"$S/runs_commit.1"; ship 4 pfenv; has pfenv "no deploy expected"
# One deploy done, another that this merge should start never ran: not "deployed".
scenario pflate; echo '[{"id":2,"name":"Deploy A","path":".github/workflows/a-deploy.yml","state":"active"},{"id":3,"name":"Deploy B","path":".github/workflows/b-deploy.yml","state":"active"}]' >"$S/workflows.json"; printf 'on: push\n' >"$S/wf.a-deploy.yml"; printf 'on: push\n' >"$S/wf.b-deploy.yml"; echo a.py >"$S/changed"; echo "[$(run 2 'Deploy A' completed success)]" >"$S/runs_commit.1"; ship 21 pflate; has pflate "NO DEPLOY STARTED for: Deploy B"; hasnt pflate "and deployed"
scenario pflate2; echo '[{"id":2,"name":"Deploy A","path":".github/workflows/a-deploy.yml","state":"active"},{"id":3,"name":"Deploy B","path":".github/workflows/b-deploy.yml","state":"active"}]' >"$S/workflows.json"; printf 'on: push\n' >"$S/wf.a-deploy.yml"; printf "$P      - 'src/**'\n" >"$S/wf.b-deploy.yml"; echo a.py >"$S/changed"; echo "[$(run 2 'Deploy A' completed success)]" >"$S/runs_commit.1"; ship 0 pflate2; has pflate2 "and deployed"
# The deploy's filters are read at the merge commit, not at the default branch's tip.
scenario pfatmerge; echo '[{"id":2,"name":"Deploy Prod","path":".github/workflows/prod.yml","state":"active"}]' >"$S/workflows.json"; printf "$P      - 'src/**'\n" >"$S/wf.prod.yml"; printf 'on: push\n' >"$S/wf.prod.yml@$MERGE"; echo docs/a.md >"$S/changed"; echo '[]' >"$S/runs_commit.1"; ship 21 pfatmerge
scenario pfatmerge2; echo '[{"id":2,"name":"Deploy Prod","path":".github/workflows/prod.yml","state":"active"}]' >"$S/workflows.json"; printf 'on: push\n' >"$S/wf.prod.yml"; printf "$P      - 'src/**'\n" >"$S/wf.prod.yml@$MERGE"; echo docs/a.md >"$S/changed"; echo '[]' >"$S/runs_commit.1"; ship 4 pfatmerge2
# A bad ref is not a deleted workflow, so the deploy should still have started.
scenario pfbadref; echo '[{"id":2,"name":"Deploy Prod","path":".github/workflows/prod.yml","state":"active"}]' >"$S/workflows.json"; touch "$S/contents.badref"; echo a.py >"$S/changed"; echo '[]' >"$S/runs_commit.1"; ship 21 pfbadref
# A deleted workflow GitHub still lists as active cannot have started, and does not hold up "deployed".
scenario pfgone; echo '[{"id":2,"name":"Deploy A","path":".github/workflows/a-deploy.yml","state":"active"},{"id":3,"name":"Deploy B","path":".github/workflows/b-deploy.yml","state":"active"}]' >"$S/workflows.json"; printf 'on: push\n' >"$S/wf.a-deploy.yml"; touch "$S/wf.b-deploy.yml.gone"; echo a.py >"$S/changed"; echo "[$(run 2 'Deploy A' completed success)]" >"$S/runs_commit.1"; ship 0 pfgone; has pfgone "and deployed"
# Only a real "not there": an outage still counts as should have started.
scenario pfnogone; echo '[{"id":2,"name":"Deploy A","path":".github/workflows/a-deploy.yml","state":"active"}]' >"$S/workflows.json"; touch "$S/contents.fail"; echo a.py >"$S/changed"; echo '[]' >"$S/runs_commit.1"; ship 21 pfnogone
# Two polls before a verdict: a second result arriving late is not missed.
scenario stable2; echo "[$(run 2 'Deploy Prod' completed success)]" >"$S/runs_commit.1"; echo "[$(run 2 'Deploy Prod' completed success),$(run 2 'Deploy Prod' completed failure)]" >"$S/runs_commit.2"; ship 20 stable2
# One bad answer does not end a watch or make up a failure.
scenario sup502; echo "[$(run 2 'Deploy Prod' completed cancelled)]" >"$S/runs_commit.1"; echo "[{\"headSha\":\"$OTHER\",\"status\":\"completed\",\"conclusion\":\"success\",\"url\":\"https://gh/newer\"}]" >"$S/runs_wf.json"; echo 1 >"$S/fail.wfrun"; ship 0 sup502; has sup502 "superseded by"
scenario w502; echo 2 >"$S/fail.repoview"; echo 1 >"$S/fail.commit"; OUT=$("$BASH" "$BIN/ship" --watch-sha "$MERGE" --repo o/r 2>&1); RC=$?; [ "$RC" = 0 ] && ok || bad w502 "exit $RC"
scenario wdead; echo 99 >"$S/fail.repoview"; export SHIP_POLL=0.05; OUT=$(perl -e 'alarm 25; exec @ARGV' "$BASH" "$BIN/ship" --watch-sha "$MERGE" --repo o/r 2>&1); RC=$?; [ "$RC" = 22 ] && ok || bad wdead "exit $RC"; has wdead "result unknown"
# Alarm in the background reaches the hook.
scenario pfalarm; echo '[{"id":2,"name":"Deploy Prod","path":".github/workflows/prod.yml","state":"active"}]' >"$S/workflows.json"; printf "$P      - 'src/**'\n" >"$S/wf.yml"; echo src/a.py >"$S/changed"; echo '[]' >"$S/runs_commit.1"; OUT=$("$BASH" "$BIN/ship" 7 --repo o/r 2>&1); id=$(run_of); n=0; until grep -q '^[0-9]* deploy ' "$S/state/runs/$id" || [ "$n" -gt 80 ]; do sleep 0.1; n=$((n+1)); done; [ -e "$S/state/active/$id" ] && ok || bad pfalarm "not flagged"


# Died in the already-merged path: the record knows it merged, so never "no merge request".
scenario k9ext; for i in 1 2 3; do pr_json OPEN false MERGEABLE BLOCKED "$PIN" >"$S/pr.$i"; done; pr_json MERGED false UNKNOWN UNKNOWN "$PIN" >"$S/pr.4"; checks "$(cr test IN_PROGRESS)" >"$S/checks.1"; export SHIP_TEST_HOOK=$S/hook; mkdir -p "$S/hook"; : >"$S/hook/stage-watching_deploy"; start_bg --wait-deploy; wait_for "$S/hook/stage-watching_deploy.reached" 10; kill -CONT "$P"; kill -9 "$P"; wait "$P" 2>/dev/null; unset SHIP_TEST_HOOK; status; [ "$RC" = 42 ] && ok || bad k9ext "status $RC"; has k9ext "merged as $MERGE"; hasnt k9ext "sent no merge request"
# --- status
scenario st1; OUT=$("$BASH" "$BIN/ship" --status 2>&1); RC=$?; [ "$RC" = 0 ] && ok || bad st1 "exit $RC"; OUT=$("$BASH" "$BIN/ship" --status 999 2>&1); [ $? = 2 ] && ok || bad st1 "unknown run"
scenario st2; checks "$(cr test COMPLETED FAILURE)" >"$S/checks.1"; ship 10 st2; status; [ "$RC" = 10 ] && ok || bad st2 "status exit $RC"; has st2 "RESULT exit=10"
scenario st3; checks "$(cr test IN_PROGRESS)" >"$S/checks.1"; start_bg; status; [ "$RC" = 50 ] && ok || bad st3 "status exit $RC"; kill -TERM "$P"; wait "$P"; status; [ "$RC" = 40 ] && ok || bad st3 "after TERM: $RC"
# Records stay small: no logs in them.
scenario st4; ship 0 st4; [ "$(wc -l <"$(recf)")" -lt 16 ] && ok || bad st4 "record has $(wc -l <"$(recf)") lines"

# --- repo resolution
scenario resolve; OUT=$("$BASH" "$BIN/ship" 7 2>&1); [ $? = 0 ] && ok || bad resolve "exit"; called resolve "repo view"; called resolve "--repo o/r"
scenario urlmix; OUT=$("$BASH" "$BIN/ship" https://github.com/o/r/pull/7 --repo other/repo 2>&1); [ $? = 2 ] && ok || bad urlmix "a URL and another repo"; not_called urlmix "$MRG"; OUT=$("$BASH" "$BIN/ship" --repo other/repo https://github.com/o/r/pull/7 2>&1); [ $? = 2 ] && ok || bad urlmix "flag first"
scenario urlcase; OUT=$("$BASH" "$BIN/ship" https://github.com/o/r/pull/7 --repo O/R --wait-deploy 2>&1); [ $? = 0 ] && ok || bad urlcase "case only"
scenario url; OUT=$("$BASH" "$BIN/ship" https://github.com/o/r/pull/7 --wait-deploy 2>&1); [ $? = 0 ] && ok || bad url "exit"; not_called url "repo view"

if [ -d "$S/locks" ]; then bad dry "lock dir made"; else ok; fi

# Temp dir does not leak.
scenario tmpleak; TL=$ROOT/tl; mkdir -p "$TL"; OUT=$(TMPDIR=$TL "$BASH" "$BIN/ship" 7 --repo o/r --wait-deploy 2>&1); [ -z "$(ls -A "$TL")" ] && ok || bad tmpleak "temp left: $(ls "$TL")"

# --- ship-notice
NOTICE=$BIN/ship-notice
notice() { printf '%s' "${2:-{\"session_id\":\"s1\"\}}" | CLAUDE_CODE_ENTRYPOINT=${ENTRY:-cli} "$BIN/ship-notice" "${1:-session}"; }
scenario nquiet; [ -z "$(notice)" ] && ok || bad nquiet "noise with no runs"
ship 0 nquiet; [ -z "$(notice)" ] && ok || bad nquiet "noise after a clean run"
# A check failure reached its caller, which is in the thread already: nothing to add.
scenario nack; checks "$(cr test COMPLETED FAILURE)" >"$S/checks.1"; ship 10 nack; [ -z "$(notice)" ] && ok || bad nack "foreground failure shown"
# Failed background deploy: once per session, the right shape per event, silent for unattended.
scenario nfail; echo "[$(run 2 'Deploy Prod' completed failure)]" >"$S/runs_commit.1"; OUT=$("$BASH" "$BIN/ship" 7 --repo o/r 2>&1); id=$(run_of); n=0; until grep -q '^[0-9]* deploy ' "$S/state/runs/$id" || [ "$n" -gt 100 ]; do sleep 0.1; n=$((n+1)); done
OUT=$(ENTRY=sdk-cli notice); [ -z "$OUT" ] && ok || bad nfail "unattended job got noise"
OUT=$(notice session '{"session_id":"s9","agent_id":"a1"}'); [ -z "$OUT" ] && ok || bad nfail "subagent got noise"
# A nested subagent's own Agent call must not use up the main thread's notice.
OUT=$(notice agent '{"session_id":"s1","agent_id":"a1"}'); [ -z "$OUT" ] && ok || bad nfail "nested Agent call was shown"
OUT=$(notice agent '{"session_id": "s1", "agent_id": "a1"}'); [ -z "$OUT" ] && ok || bad nfail "nested Agent call, spaced JSON"
OUT=$(notice); has nfail "ship run $id"; has nfail "DEPLOY PROBLEM"; has nfail "ship --status $id"
OUT=$(notice); [ -z "$OUT" ] && ok || bad nfail "shown twice in one session"
OUT=$(notice prompt '{"session_id":"s2"}'); has nfail "ship run $id"
OUT=$(notice agent '{"session_id":"s3"}'); has nfail '"additionalContext":"ship run'; printf '%s' "$OUT" | jq -e .hookSpecificOutput.additionalContext >/dev/null && ok || bad nfail "bad JSON: $OUT"
OUT=$(notice stop '{"session_id":"s6"}'); has nfail '"decision":"block"'; printf '%s' "$OUT" | jq -e .reason >/dev/null && ok || bad nfail "bad stop JSON: $OUT"
OUT=$(notice stop '{"session_id":"s6"}'); [ -z "$OUT" ] && ok || bad nfail "stop blocked twice"
OUT=$(notice stop '{"session_id":"s7","stop_hook_active":true}'); [ -z "$OUT" ] && ok || bad nfail "stop ignored stop_hook_active"
status "$id"; OUT=$(notice prompt '{"session_id":"s4"}'); [ -z "$OUT" ] && ok || bad nfail "still shown after --status"
# A run dead right after the merge call, and a dead watch.
scenario ndead; arm after-merge-call; start_bg --no-deploy-watch; wait_for "$S/hook/after-merge-call.reached" 10; kill -CONT "$P"; kill -9 "$P"; wait "$P" 2>/dev/null; unset SHIP_TEST_HOOK; OUT=$(notice); has ndead "DIED at stage merging"
scenario ndeadw; echo "[$(run 2 'Deploy Prod' in_progress '')]" >"$S/runs_commit.1"; OUT=$("$BASH" "$BIN/ship" 7 --repo o/r 2>&1); [ -z "$(notice)" ] && ok || bad ndeadw "noise while the watch runs"; id=$(run_of); kill -9 "$(sed -n 's/^[0-9]* proc //p' "$S/state/runs/$id" | tail -1 | cut -d' ' -f1)"; sleep 0.2; OUT=$(notice session '{"session_id":"s5"}'); has ndeadw "DEPLOY WATCH DIED"
# A run that died while waiting did nothing, so it is not news.
scenario nwait; arm stage-waiting; start_bg; wait_for "$S/hook/stage-waiting.reached" 10; kill -CONT "$P"; kill -9 "$P"; wait "$P" 2>/dev/null; unset SHIP_TEST_HOOK; [ -z "$(notice)" ] && ok || bad nwait "a died-while-waiting run was shown"
# Idle means no work: it must return without waiting on stdin, even if stdin never closes.
scenario nidle; mkfifo "$S/f"; exec 9<>"$S/f"; t0=$(date +%s); CLAUDE_CODE_ENTRYPOINT=cli "$BIN/ship-notice" stop <&9 >"$S/o"; exec 9>&-; [ $(( $(date +%s) - t0 )) -lt 2 ] && ok || bad nidle "read stdin when idle"; [ ! -s "$S/o" ] && ok || bad nidle "output when idle"; [ ! -d "$S/state/seen" ] && ok || bad nidle "did work when idle"

# --- test isolation
scenario iso; OUT=$(env -u SHIP_STATE_DIR SHIP_TEST_HOOK=$S/hook "$BASH" "$BIN/ship" 7 --repo o/r 2>&1); [ $? = 2 ] && ok || bad iso "seam allowed on the real run records"; has iso "not allowed"
OUT=$("$BASH" "$BIN/tests/live.test.sh" --self-check 2>&1); [ $? = 0 ] && ok || bad iso "live self-check failed: $OUT"; has iso "self-check ok"

# --- static guards
if grep -n -- '--delete-branch' "$BIN/ship" | grep -v 'never uses --delete-branch' | grep -q .; then bad static "ship passes --delete-branch"; else ok; fi
if grep -nE '^[[:space:]]*(.*[;&|(][[:space:]]*)?(timeout|gtimeout|gdate|gsed|gawk) +[-"$0-9]' "$BIN/ship" "$BIN/ship-notice" | grep -q .; then bad static "GNU-only tool used"; else ok; fi
report
