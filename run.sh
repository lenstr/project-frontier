#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ ! -x build/frontier ]; then ./tools/build.sh; fi
exec ./build/frontier "$@"
