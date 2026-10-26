#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
compiler="$(./tools/bootstrap.sh | tail -1)"
mkdir -p build artifacts
mode="${1:-}"
case "$mode" in
  ""|--graphics|--stress-graphics) ;;
  --help|-h)
    printf '%s\n' 'Usage: ./tools/test.sh [--graphics|--stress-graphics]'
    printf '%s\n' 'Default: deterministic headless gameplay, storage, telemetry and showcase tests.'
    printf '%s\n' '--graphics: also run bounded developer panel, horizon and renderer smoke tests.'
    printf '%s\n' '--stress-graphics: also run the explicit long GPU lifecycle stress test.'
    exit 0
    ;;
  *)
    printf '%s\n' "Unknown test mode: $mode" >&2
    exit 2
    ;;
esac
"$compiler" format --check frontier.goose src tests
for name in entities world gameplay persistence telemetry showcase free_flight memory vegetation; do
  "$compiler" build "tests/${name}_test.goose" -o "build/${name}_test" --debug
  "build/${name}_test"
done
if [ "$mode" = --graphics ]; then
  for name in dev_panel horizon horizon_motion shadow_boundary render_cache; do
    "$compiler" build "tests/${name}_test.goose" -o "build/${name}_test" --debug
    "build/${name}_test"
  done
  "$compiler" build tests/render_smoke.goose -o build/render_smoke --debug
  build/render_smoke --frames 3
  "$compiler" build frontier.goose -o build/frontier_qa
  mkdir -p build/qa/inputs/artifacts build/qa/inputs/build
  (
    cd build/qa/inputs
    ../../frontier_qa --flight-test --mute --screenshot flight.png
    ../../frontier_qa --playtest --mute --screenshot input.png
    for load in 32 2000; do
      ../../frontier_qa --showcase --load "$load" --offscreen --frames 16 --benchmark --mute --screenshot load.png
      case "$(cat artifacts/benchmark.json)" in
        *"\"showcase_load\": $load,"*) ;;
        *)
          printf '%s\n' "Requested colony load $load was not retained" >&2
          exit 1
          ;;
      esac
    done
  )
fi
if [ "$mode" = --stress-graphics ]; then
  "$compiler" build tests/gpu_stress.goose -o build/gpu_stress
  build/gpu_stress
fi
