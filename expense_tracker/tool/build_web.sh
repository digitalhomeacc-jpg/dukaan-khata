#!/usr/bin/env bash
# Builds the web app for https://digitalhomeacc-jpg.github.io/expense-tracker/ into $1
# (default build/site). Every file the browser loads gets ?v=<build> so phones fetch the
# new version instead of a cached old one.
#   tool/build_web.sh /path/to/expense-tracker-repo-checkout
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-build/site}
BUILD=$(date -u +%Y%m%d%H%M)
LABEL=$(TZ=Asia/Kolkata date +"%-d %b %H:%M")
TMP=$(mktemp -d)
flutter build web --release --no-web-resources-cdn --base-href /expense-tracker/ \
  --dart-define-from-file=env.json --dart-define=BUILD="$LABEL" -o "$TMP"
find "$TMP" -name '*.symbols' -delete
rm -rf "$TMP"/canvaskit/skwasm* "$TMP"/canvaskit/wimp* "$TMP"/canvaskit/webparagraph* "$TMP"/flutter.js.map
sed -i "s#\"mainJsPath\":\"main.dart.js\"#\"mainJsPath\":\"main.dart.js?v=$BUILD\"#" "$TMP/flutter_bootstrap.js"
sed -i "s#src=\"flutter_bootstrap.js\"#src=\"flutter_bootstrap.js?v=$BUILD\"#" "$TMP/index.html"
grep -q "main.dart.js?v=$BUILD" "$TMP/flutter_bootstrap.js" || { echo "cache-busting failed: mainJsPath not found"; exit 1; }
sed -i "s#var BUILD = '__BUILD__';#var BUILD = '$BUILD';#" "$TMP/index.html"
echo "$BUILD" > "$TMP/version.txt"
touch "$TMP/.nojekyll"
mkdir -p "$OUT"
find "$OUT" -mindepth 1 -maxdepth 1 ! -name .git ! -name README.md -exec rm -rf {} +
cp -r "$TMP"/. "$OUT"/
rm -rf "$TMP"
echo "Built $LABEL into $OUT"
