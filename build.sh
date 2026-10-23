#!/usr/bin/env bash
set -euo pipefail

# Build The Oracle from the repository root.
# Extra arguments are passed through to Odin, for example:
#   ./build.sh -debug
#   ./build.sh -define:ODIN_TEST_THREADS=4
#
# -show-timings prints the compiler's stage timings.

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

odin build . -out:oracle -o:speed -show-timings "$@"
