#!/bin/sh
# Renders tools/meadow.html to web/meadow.jpg with an invisible browser.
set -eu
cd "$(dirname "$0")/.."
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
"$HOME/.local/bin/chrome-headless-shell" --user-data-dir="$t/p" --hide-scrollbars --window-size=2400,1600 --virtual-time-budget=60000 --screenshot="$t/m.png" "file://$PWD/tools/meadow.html" >/dev/null 2>&1
sips -s format jpeg -s formatOptions 82 "$t/m.png" --out web/meadow.jpg >/dev/null
ls -la web/meadow.jpg
