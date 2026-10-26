#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
compiler="$(./tools/bootstrap.sh | tail -1)"
mkdir -p build artifacts
for name in entities world gameplay persistence; do
  "$compiler" build "tests/${name}_test.goose" -o "build/${name}_test" --debug
  "build/${name}_test"
done
if [ "${1:-}" = --graphics ]; then
  "$compiler" build tests/gpu_stress.goose -o build/gpu_stress
  build/gpu_stress
fi
