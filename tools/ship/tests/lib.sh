# Shared test helpers. Run tests under bash 3.2 and any newer bash.
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
PASS=0 FAIL=0 FAILED_NAMES=""
export PATH="$BIN/tests/stub:$PATH"
# Stub tests must never reach GitHub. Refuse to start if gh is not the stub.
[ "$(command -v gh)" = "$BIN/tests/stub/gh" ] || { echo "abort: gh is not the stub"; exit 99; }
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/shiptest.XXXXXX"); ROOT=$(cd "$ROOT" && pwd -P)
# Nothing a test starts can see real run records.
export SHIP_STATE_DIR=$ROOT/state
trap 'rm -rf "$ROOT"' EXIT
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $1"; echo "not ok: $1: $2"; [ -n "${OUT:-}" ] && sed 's/^/    /' <<<"$OUT"; }
has() { case "$OUT" in *"$2"*) ok ;; *) bad "$1" "output lacks [$2]" ;; esac; }
hasnt() { case "$OUT" in *"$2"*) bad "$1" "output has [$2]" ;; *) ok ;; esac; }
report() { echo "pass=$PASS fail=$FAIL${FAILED_NAMES:+ failed:$FAILED_NAMES}"; [ "$FAIL" -eq 0 ]; }
