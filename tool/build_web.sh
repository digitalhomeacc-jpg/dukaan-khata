#!/usr/bin/env bash
# Builds the web app (real + demo) into $1 (default build/site) for GitHub Pages.
# Every file name the browser loads gets ?v=<build> so a refresh always
# fetches the new version instead of an old cached copy.
set -euo pipefail
OUT=${1:-build/site}
BUILD=$(date -u +%Y%m%d%H%M)
LABEL=$(TZ=Asia/Kolkata date +"%d/%m/%y %H:%M")
rm -rf "$OUT"
flutter build web --release --no-web-resources-cdn --base-href /dukaan-khata/ \
  --dart-define=BUILD="$LABEL" -o "$OUT"
flutter build web --release --no-web-resources-cdn --base-href /dukaan-khata/demo/ \
  --dart-define=DEMO=true --dart-define=CLOUD=false --dart-define=BUILD="$LABEL" -o "$OUT/demo"
for d in "$OUT" "$OUT/demo"; do
  find "$d" -name '*.symbols' -delete
  rm -rf "$d/canvaskit/skwasm"* "$d/canvaskit/wimp"* "$d/canvaskit/webparagraph"
  sed -i "s#\"mainJsPath\":\"main.dart.js\"#\"mainJsPath\":\"main.dart.js?v=$BUILD\"#" "$d/flutter_bootstrap.js"
  sed -i "s#src=\"flutter_bootstrap.js\"#src=\"flutter_bootstrap.js?v=$BUILD\"#; s#src=\"pdf_text.js\"#src=\"pdf_text.js?v=$BUILD\"#; s#__BUILD__#$BUILD#g" "$d/index.html"
  rm -f "$d/flutter_service_worker.js" "$d/.last_build_id"
  # list every file of this build for the offline service worker
  python3 - "$d" "$BUILD" <<'PY'
import json, os, sys
d, build = sys.argv[1], sys.argv[2]
versioned = {'main.dart.js', 'flutter_bootstrap.js', 'pdf_text.js'}
files = ['./']
for root, dirs, names in os.walk(d):
    dirs[:] = [x for x in dirs if not (root == d and x == 'demo')]
    for n in names:
        rel = os.path.relpath(os.path.join(root, n), d).replace(os.sep, '/')
        if rel in ('app_sw.js', 'version.json') or rel.endswith('.map') or rel.startswith('.'):
            continue
        files.append(f'{rel}?v={build}' if rel in versioned else rel)
p = os.path.join(d, 'app_sw.js')
s = open(p).read().replace('__FILES__', json.dumps(sorted(files))).replace('__BUILD__', build)
open(p, 'w').write(s)
print(len(files), 'files listed for offline use in', d)
PY
done
sed -i 's#<title>दुकान खाता</title>#<title>दुकान खाता (Demo)</title>#' "$OUT/demo/index.html"
python3 - "$OUT/demo/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m['name'] = 'दुकान खाता (Demo)'
json.dump(m, open(p, 'w'), ensure_ascii=False, indent=2)
PY
touch "$OUT/.nojekyll"
echo "built $BUILD ($LABEL) → $OUT"
