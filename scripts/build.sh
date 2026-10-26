#!/usr/bin/env bash
# Compiles the library to C: <out>/golsp.c and <out>/golsp.h. A host program
# lists <out>/golsp.c, native/proc.c and native/glue.c in its sidecar's
# c_sources, then calls golsp_start / golsp_ask / golsp_stop.
#   scripts/build.sh <out-dir>     (GOOSE: the goose compiler, default `goose`)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?usage: scripts/build.sh <out-dir>}"
mkdir -p "$out"
"${GOOSE:-goose}" --standalone --header "$out/golsp.h" -o "$out/golsp.c" "$here/golsp.goose" >/dev/null
