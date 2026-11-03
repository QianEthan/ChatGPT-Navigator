#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CONVERTER="${1:-$(command -v pandoc || true)}"
DESTINATION="$PROJECT_DIR/AppResources/Tools/pandoc"

if [[ -z "$CONVERTER" || ! -x "$CONVERTER" ]]; then
  print -u2 'Install Pandoc 3.13 for arm64 macOS from https://github.com/jgm/pandoc/releases/tag/3.13'
  print -u2 'Then run: ./Scripts/setup_pandoc.sh /path/to/pandoc'
  exit 1
fi
CONVERTER="${CONVERTER:A}"
VERSION_OUTPUT="$("$CONVERTER" --version)"
if [[ "${VERSION_OUTPUT%%$'\n'*}" != 'pandoc 3.13' ]]; then
  print -u2 'This build expects Pandoc 3.13. Use the matching official release.'
  exit 1
fi
/usr/bin/lipo "$CONVERTER" -verify_arch arm64
if [[ "$CONVERTER" == "$DESTINATION" ]]; then
  print 'Pandoc 3.13 is already prepared.'
  exit 0
fi
mkdir -p "${DESTINATION:h}"
TEMPORARY="$(mktemp "${DESTINATION}.XXXXXX")"
trap 'rm -f "$TEMPORARY"' EXIT
cp "$CONVERTER" "$TEMPORARY"
chmod 755 "$TEMPORARY"
mv -f "$TEMPORARY" "$DESTINATION"
print 'Prepared Pandoc 3.13 locally. The converter is excluded by .gitignore.'
