#!/usr/bin/env bash
# Push se pehle chalao: CSS/JS links ko naya ?v= number deta hai,
# taaki phone/browser purani cached files na chalaye.
# Usage: tools/bump-version.sh
set -euo pipefail
cd "$(dirname "$0")/.."
v=$(date +%s)
for f in *.html; do
  sed -i.bak -E "s/(style\.css|data\.js|config\.js)(\?v=[0-9]+)?\"/\1?v=$v\"/g" "$f"
  rm -f "$f.bak"
done
echo "Assets version: $v"
