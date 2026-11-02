#!/usr/bin/env bash
# Copy ship, ship-notice and their tests to a directory. Usage: install.sh [target-dir]
# Default target: ~/Code/Sync/bin. Never touches an existing ship.conf.
set -eu

src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
default_target=$HOME/Code/Sync/bin
target=${1:-$default_target}

mkdir -p "$target/tests/stub"
target=$(cd "$target" && pwd -P)
if [ "$target" = "$src" ]; then
  echo "install.sh: target is the source directory: $target" >&2
  exit 2
fi

for f in ship ship-notice tests/lib.sh tests/ship.test.sh tests/live.test.sh tests/stub/gh; do
  # Rename into place: a running ship keeps reading the file it started from.
  cp "$src/$f" "$target/$f.new"
  chmod +x "$target/$f.new"
  mv -f "$target/$f.new" "$target/$f"
  echo "installed $target/$f"
done

if [ -e "$target/ship.conf" ]; then
  echo "left $target/ship.conf as it was"
else
  echo "no ship.conf in $target; see $src/ship.conf.example if a repo needs overrides"
fi

# ship reads this path unless SHIP_CONF says otherwise.
default_conf=$HOME/Code/Sync/bin/ship.conf
if [ "$target/ship.conf" != "$default_conf" ]; then
  echo "ship reads $default_conf by default; set SHIP_CONF=$target/ship.conf to use this directory's file"
fi
