#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
compiler="$(./tools/bootstrap.sh | tail -1)"
mkdir -p build artifacts
"$compiler" build frontier.goose -o build/frontier --stacks "$@"
