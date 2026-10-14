#!/usr/bin/env bash
#
# mayhem/test.sh — BEHAVIORAL oracle for proton-bridge. Runs the dynamically-linked
# KAT probe (/mayhem/parser_kat, built by build.sh) that parses a fixed RFC822
# message through the real pkg/message/parser decode path, and asserts the EXACT
# parsed header/body field values.
#
# Why not `go test` alone (netnew §4): a Go test binary is statically linked, so the
# gate's LD_PRELOAD sabotage shim cannot neuter it — the suite would survive sabotage
# while proving nothing (the cosign/notary false-green). The KAT probe is cgo-linked
# (dynamic), so when the program is neutered to _exit(0) it prints nothing, every
# assertion below misses, and test.sh FAILS — which is the point (§6.3).
#
# Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PROBE=/mayhem/parser_kat
passed=0; failed=0

# Unconditional: a missing probe is a build.sh bug — FAIL loudly, never skip.
if [ ! -x "$PROBE" ]; then
  echo "FAIL: KAT probe $PROBE missing or not executable (build.sh should have produced it)" >&2
  emit_ctrf "proton-bridge-kat" 0 1
  exit 1
fi

OUT="$("$PROBE" 2>/dev/null)"
echo "--- KAT probe output ---"; printf '%s\n' "$OUT"; echo "------------------------"

# Fixed input: a well-formed RFC822 text/plain message parsed via parser.New.
# Assert every decoded field against the known answer.
assert() { # <desc> <expected-line>
  if printf '%s\n' "$OUT" | grep -qxF "$2"; then
    echo "PASS: $1"; passed=$((passed+1))
  else
    echo "FAIL: $1 (expected exact line: $2)"; failed=$((failed+1))
  fi
}

assert "root media type is text/plain"       "KAT_CTYPE=text/plain"
assert "root charset param is utf-8"          "KAT_CHARSET=utf-8"
assert "decoded Subject header"               "KAT_SUBJECT=KAT Subject"
assert "decoded body round-trips"             "KAT_BODY=Hello KAT body"

emit_ctrf "proton-bridge-kat" "$passed" "$failed"
