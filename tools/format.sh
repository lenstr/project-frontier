#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
compiler="$(./tools/bootstrap.sh | tail -1)"
"$compiler" format "$@" frontier.goose src tests
