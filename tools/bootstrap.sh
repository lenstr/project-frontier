#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# An explicit override permits comparisons with a previous compiler.
if [ -n "${FRONTIER_GOOSE:-}" ]; then
  if [ ! -x "$FRONTIER_GOOSE" ]; then
    printf '%s\n' "Compiler is not executable: $FRONTIER_GOOSE" >&2
    exit 1
  fi
  printf '%s\n' "$FRONTIER_GOOSE"
  exit 0
fi

. ./tools/goose-toolchain.env
source_dir=".tools/goose-$GOOSE_REVISION"
compiler="$source_dir/build/goose"

if [ ! -x "$compiler" ]; then
  for dependency in cmake curl tar git; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
      printf '%s\n' "Install $dependency before building the pinned Goose snapshot." >&2
      exit 1
    fi
  done
  mkdir -p .tools
  archive=".tools/goose-$GOOSE_REVISION.tar.gz"
  if [ ! -f "$archive" ]; then
    download="$(mktemp .tools/goose-download.XXXXXX)"
    trap 'test ! -f "$download" || unlink "$download"' EXIT HUP INT TERM
    curl -fL "https://codeload.github.com/aardappel/goose/tar.gz/$GOOSE_REVISION" -o "$download" >&2
    mv "$download" "$archive"
    trap - EXIT HUP INT TERM
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$GOOSE_SOURCE_SHA256" "$archive" | sha256sum -c - >&2
  else
    printf '%s  %s\n' "$GOOSE_SOURCE_SHA256" "$archive" | shasum -a 256 -c - >&2
  fi
  if [ ! -d "$source_dir" ]; then
    tar -xzf "$archive" -C .tools
  fi
  cmake -S "$source_dir" -B "$source_dir/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGOOSE_BUILTIN_LIBS=all \
    "-DGOOSE_VERSION=$GOOSE_VERSION" >&2
  cmake --build "$source_dir/build" --config Release \
    --parallel "${FRONTIER_BUILD_JOBS:-4}" >&2
fi

printf '%s\n' "$compiler"
