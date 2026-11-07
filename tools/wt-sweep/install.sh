#!/usr/bin/env bash
# Copy wt-sweep and its tests to a directory. Usage: install.sh [target-dir]
# Default target: ~/Code/Sync/bin. Tests go to tests/wt-sweep.test.sh and
# tests/wt-sweep-stub/, which share no names with ship's tests.
set -eu

src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
default_target=$HOME/Code/Sync/bin
target=${1:-$default_target}

mkdir -p "$target/tests/wt-sweep-stub"
target=$(cd "$target" && pwd -P)
if [ "$target" = "$src" ]; then
  echo "install.sh: target is the source directory: $target" >&2
  exit 2
fi

for f in wt-sweep tests/wt-sweep.test.sh tests/wt-sweep-stub/gh; do
  # Rename into place: a running wt-sweep keeps reading the file it started from.
  cp "$src/$f" "$target/$f.new"
  chmod +x "$target/$f.new"
  mv -f "$target/$f.new" "$target/$f"
  echo "installed $target/$f"
done
