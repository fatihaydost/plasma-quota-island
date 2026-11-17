#!/usr/bin/env bash
# Çeviri şablonunu (template.pot) QML kaynaklarından üretir, *.po dosyalarını günceller ve
# derlenmiş .mo dosyalarını package/contents/locale altına yazar (Plasma uygulamacık paketi düzeni).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DOMAIN="plasma_applet_io.github.fatihaydost.island"

cd "$ROOT"
find package/contents -name '*.qml' | sort > "$HERE/.files"
xgettext --from-code=UTF-8 --language=JavaScript --kde \
    -ci18n -ki18n:1 -ki18nc:1c,2 -ki18np:1,2 -ki18ncp:1c,2,3 \
    --package-name="$DOMAIN" --msgid-bugs-address="https://github.com/fatihaydost/plasma-quota-island/issues" \
    --files-from="$HERE/.files" -o "$HERE/template.pot"
rm -f "$HERE/.files"

for po in "$HERE"/*.po; do
    [ -e "$po" ] || continue
    lang="$(basename "$po" .po)"
    msgmerge --quiet --update --backup=none --no-fuzzy-matching "$po" "$HERE/template.pot"
    out="package/contents/locale/$lang/LC_MESSAGES"
    mkdir -p "$out"
    msgfmt --check -o "$out/$DOMAIN.mo" "$po"
    echo "$lang: $(msgfmt --statistics -o /dev/null "$po" 2>&1)"
done
