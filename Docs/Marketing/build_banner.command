#!/bin/zsh
# Renders ePathoPlus_Banner.html to a true-size 8 ft x 4 ft PDF and a 9600 x 4800 PNG.
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
URL="file://$PWD/ePathoPlus_Banner.html"
TMP="$(mktemp -d)"
"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --user-data-dir="$TMP" \
  --print-to-pdf="$PWD/ePathoPlus_Banner_8x4ft.pdf" "$URL"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$TMP" \
  --window-size=2400,1200 --force-device-scale-factor=4 \
  --screenshot="$PWD/ePathoPlus_Banner_8x4ft.png" "$URL"
rm -rf "$TMP"
