#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=v2026.3
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=macos-arm64 ;;
  Darwin-x86_64) platform=macos-x64 ;;
  Linux-x86_64) platform=linux-x64 ;;
  *) echo 'Use an official Goose v2026.3 release for this platform.' >&2; exit 1 ;;
esac
compiler=".tools/goose-$version-$platform/goose"
if [ ! -x "$compiler" ]; then
  mkdir -p .tools
  archive="$(mktemp -t frontier-goose.XXXXXX)"
  trap 'rm -f "$archive"' EXIT HUP INT TERM
  curl -fL "https://github.com/aardappel/goose/releases/download/$version/goose-$version-$platform.tar.gz" -o "$archive"
  if [ "$platform" = macos-arm64 ]; then
    echo "2ffaaf46b3edde27aed03fcd9ebe73e9b6639cac30d8a6915f7dc00795b7aedf  $archive" | shasum -a 256 -c -
  fi
  tar -xzf "$archive" -C .tools
fi
printf '%s\n' "$compiler"
