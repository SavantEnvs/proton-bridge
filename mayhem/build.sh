#!/usr/bin/env bash
#
# mayhem/build.sh — build proton-bridge's message/MIME/RFC822 PARSER
# (pkg/message/parser) as a sanitized libFuzzer binary (OSS-Fuzz Go path:
# go-118-fuzz-build -libfuzzer archive + clang++ ASan link), plus a
# dynamically-linked KAT oracle probe for mayhem/test.sh to run.
#
# Runs inside the commit image (GO mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV under /opt/toolchains
# (absolute, $HOME-independent — so the offline PATCH re-run finds the cache).
#
# TOOLCHAIN NOTE: proton-bridge's go.mod declares `go 1.26.1` and its parser
# transitively requires github.com/ProtonMail/gluon (also go 1.26.1), so the
# fleet-default Go 1.23.4 CANNOT build this tree — the Dockerfile pins Go 1.26.5
# (matching go.mod's `toolchain go1.26.5`) instead. No go.mod edits are needed:
# 1.26.5 satisfies the floor, keeping the integration fully additive.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) fills $GOMODCACHE (go get shim + build deps).
#   - GOPROXY points at the in-image module cache's file proxy FIRST, network
#     LAST, so the offline re-run resolves entirely from the cache; GOFLAGS=-mod=mod
#     + GOSUMDB=off keep go.sum verification local (no sum.golang.org round trip).
#
# HARNESS STAGING (netnew §6 Go): copy pkg/message/parser's NON-test sources +
# the harness + the KAT export into a fresh single-package dir under a leading-
# underscore path (skipped by `go build/test ./...` wildcards, still loadable by
# an explicit path) and point the builder there — the upstream package dir's
# *_test.go files pull os/filepath fixtures + testify that the builder does not
# need, and staging keeps everything additive.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

# Sanitizers (§6.1): the OSS-Fuzz Go path is ASan-only for the libFuzzer link.
# Honor the knob — an explicit empty SANITIZER_FLAGS yields an un-sanitized build.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export SANITIZER_FLAGS
GO_SAN="-fsanitize=address"
[ -n "${SANITIZER_FLAGS}" ] || GO_SAN=""

# Debug-info contract (§6.2 item 10): gc always emits DWARF4 with no knob, so we
# force the clang-compiled cgo C shims to DWARF3 (CGO_CFLAGS/CGO_CXXFLAGS) AND
# prepend a DWARF3 anchor.o at the final clang++ link so the FIRST .debug_info CU
# (what the gate reads) is DWARF < 4. $GO_DEBUG_FLAGS threads any base pins.
export GO_DEBUG_FLAGS="${GO_DEBUG_FLAGS:--gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:-} ${GO_DEBUG_FLAGS}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} ${GO_DEBUG_FLAGS}"

# Resolve modules offline-first from the in-image cache; network only as fallback.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOSUMDB="${GOSUMDB:-off}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

cd "$SRC"
go version

TARGET="fuzz_parser"
STAGE="$SRC/_mayhem_harness/parser"

# ── Stage a clean single-package copy of the parser (non-test sources) + KAT ──
rm -rf "$STAGE"
mkdir -p "$STAGE"
for f in "$SRC"/pkg/message/parser/*.go; do
  case "$f" in
    *_test.go) continue ;;   # drop test files (fixtures + testify, not needed)
  esac
  cp "$f" "$STAGE/"
done
cp "$SRC/mayhem/harness_parser.go.src" "$STAGE/harness_parser.go"
cp "$SRC/mayhem/kat_export.go.src"     "$STAGE/kat_export.go"

# ── Add the go-118-fuzz-build /testing shim to the module graph ────────────────
# Reference the shim by the PSEUDO-VERSION the Dockerfile's `go install ...@<commit>`
# already resolved + cached (commit a70c2aa677fa43583571959478decabe02a96cd6). A raw
# commit hash forces a proxy.golang.org round trip — fatal on the air-gapped PATCH
# re-run; the pseudo-version resolves straight from the file cache. No `go mod tidy`
# is needed: the staged package's imports are already required by the root module.
GO118_SHIM_VERSION="v0.0.0-20250520111509-a70c2aa677fa"
go get "github.com/AdamKorcz/go-118-fuzz-build/testing@${GO118_SHIM_VERSION}"

# ── Build the libFuzzer archive from the staged single-package dir ─────────────
mkdir -p "$SRC/mayhem-build"
echo "=== go-118-fuzz-build $TARGET (func FuzzNewParser) ==="
go-118-fuzz-build -func FuzzNewParser -o "$SRC/mayhem-build/$TARGET.a" ./_mayhem_harness/parser

# ── DWARF3 anchor FIRST, then clang++ ASan+fuzzer link ─────────────────────────
printf 'int __mayhem_dwarf3_anchor;\n' > "$SRC/mayhem-build/anchor.c"
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem-build/anchor.c" -o "$SRC/mayhem-build/anchor.o"
$CXX $GO_SAN $LIB_FUZZING_ENGINE \
     "$SRC/mayhem-build/anchor.o" "$SRC/mayhem-build/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# ── KAT oracle probe: dynamically-linked (cgo) so the sabotage shim can neuter it ─
export CGO_ENABLED=1
go build -o /mayhem/parser_kat ./mayhem/kat
file /mayhem/parser_kat | grep -q 'dynamically linked' \
  || { echo "FATAL: /mayhem/parser_kat is not dynamically linked — oracle would be reward-hackable"; exit 1; }
echo "built /mayhem/parser_kat (dynamically linked)"

echo "build.sh complete"
