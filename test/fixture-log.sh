#!/usr/bin/env bash
# Regression test for the shared-/tmp/ep.log ready-race in start_ep().
#
# Bug (fixed): start_ep launched `env ... /entrypoint.sh >"$log" 2>&1 &`. The
# O_TRUNC on the shared log path was performed by the ASYNC child during its
# redirect setup, so the parent's first readiness probe
# (`wait_for grep 'ready:'`) could read a STALE `ready:` left by the PREVIOUS
# fixture before the new child was scheduled -> false FAIL / wrong readiness.
#
# Fix: `: >"$log"` synchronously in the PARENT before `env ... &`, so the log
# is already empty when start_ep returns and no child timing can expose the
# previous fixture's bytes.
#
# Determinism note: bash applies the async child's `>"$log"` redirect when it
# spawns the child (before the program runs), so no in-child stub can delay it.
# The bug is therefore tested at the only deterministic point: the SYNCHRONOUS
# body of start_ep must itself truncate the log. We extract the real function's
# lines up to (excluding) the async `env ... &` launch, wrap them in a function
# with the same `local log="$1"; shift` contract, and assert the log is empty.
#
#   NEW (current) : prefix contains `: >"$log"` -> log cleared -> PASS.
#   OLD (buggy)   : prefix without the truncate -> stale bytes remain -> FAIL.
#
# The buggy variant is synthesized by extracting the REAL prefix and deleting
# only the `: >"$log"` line - everything else identical to the source.
#
# Self-contained: isolated mktemp dir, cleans only what it makes, no net/caps.
set -u

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/fixture-log.XXXXXX")" || exit 1
trap 'rm -rf "$WORKDIR"' EXIT

# --------------------------------------------------------------------------
# extract_start_ep_body <file> : print the REAL start_ep() body's INNER lines
# (between `start_ep() {` and its closing `}`), up to but NOT including the
# async `env ... &` launch. These are the statements the parent runs
# synchronously - the only part whose effect on the log is deterministic.
# Output excludes `local log="$1"; shift` and `EP=""; EP_FORCEKILLED=0` - the
# wrapper re-adds the arg contract so the snippet is callable on any log path.
# --------------------------------------------------------------------------
extract_start_ep_body() {
    awk '
        /^start_ep\(\)[[:space:]]*\{/ { infn=1; next }
        infn {
            if ($0 ~ /env[[:space:]].*entrypoint.*&/) exit
            if ($0 ~ /^}/) exit
            print
        }
    ' "$1" | grep -vE 'local log=|EP=""|EP_FORCEKILLED=0'
}

# --------------------------------------------------------------------------
# run_body_as_fn <body-text> <log> :
#   define se_prefix() { local log="$1"; shift; <body lines> }
#   seed <log> with a stale `ready:` line, call se_prefix, report byte count.
# Returns 0 when the log is empty afterwards.
# --------------------------------------------------------------------------
prefix_leaves_log_empty() {
    local body="$1" log="$2" bytes
    printf 'ready: PREVIOUS fixture leftovers\n' >"$log"
    eval "se_prefix() { local log=\"\$1\"; shift
$body
}"
    se_prefix "$log" IGNOREDENV=1
    bytes="$(wc -c <"$log" 2>/dev/null || echo -1)"
    [ "$bytes" = "0" ]
}

# ==========================================================================
echo "== fixture-log ready-race regression =="

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"
for base in /t "$SELF_DIR" .; do
    [ -f "$base/smoke.sh" ] && SMOKE="$base/smoke.sh" && break
done
[ -n "${SMOKE:-}" ] || { echo "cannot locate smoke.sh"; exit 2; }
echo "  helper source: $SMOKE"
echo "  synchronous body under test:"
extract_start_ep_body "$SMOKE" | sed 's/^/    /'

# The extracted body must never include the async launch.
if extract_start_ep_body "$SMOKE" | grep -q 'entrypoint.*&'; then
    echo "  ERROR: extraction leaked the async line"; exit 2
fi

NEWBODY="$(extract_start_ep_body "$SMOKE")"

# ---- Case 1 (must PASS): current helper clears the log in the parent.
if prefix_leaves_log_empty "$NEWBODY" "$WORKDIR/new.log"; then
    ok "current start_ep clears the shared log synchronously"
else
    bad "current start_ep left stale bytes before the async child"
fi

# ---- Case 2 (must FAIL): same body minus the `: >"$log"` line = the OLD bug.
OLDBODY="$(printf '%s\n' "$NEWBODY" | sed '/^[[:space:]]*:[[:space:]]*>"\$log"/d')"
if [ "$OLDBODY" = "$NEWBODY" ]; then
    bad "could not strip the synchronous truncate for the buggy variant"
elif printf '%s\n' "$OLDBODY" | grep -q ': >"$log"'; then
    bad "truncate still present after strip"
elif prefix_leaves_log_empty "$OLDBODY" "$WORKDIR/old.log"; then
    bad "OLD buggy shape unexpectedly cleared the log"
else
    ok "OLD buggy shape left stale 'ready:' bytes -> race window reproduced"
fi

# ---- Case 3 (must PASS): the SAME fix is present in runtime-security.sh's
# start_ep too - extract its synchronous body and assert it also clears the
# shared log before the async child.
SEC=""
for base in /t "$SELF_DIR" .; do
    [ -f "$base/runtime-security.sh" ] && SEC="$base/runtime-security.sh" && break
done
if [ -z "$SEC" ]; then
    echo "cannot locate runtime-security.sh"; exit 2
else
    SECBODY="$(extract_start_ep_body "$SEC")"
    if prefix_leaves_log_empty "$SECBODY" "$WORKDIR/sec.log"; then
        ok "runtime-security start_ep also clears the log synchronously"
    else
        bad "runtime-security start_ep left stale bytes"
    fi
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
