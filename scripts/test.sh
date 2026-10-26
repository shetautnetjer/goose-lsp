#!/usr/bin/env bash
# Offline standalone consumer test. Requires Goose, a C compiler and Python 3.
set -euo pipefail
cd "$(dirname "$0")/.."
export GOOSE_HOME=${GOOSE_HOME:-$PWD/build/tests/goose-home}
GOOSE=${GOOSE:-goose}
PYTHON=${PYTHON:-python3}
mkdir -p build/tests
GOOSE="$GOOSE" scripts/build.sh build/tests
"$GOOSE" build tests/client.goose -o build/tests/client --offline
"$PYTHON" tests/check.py build/tests/client
