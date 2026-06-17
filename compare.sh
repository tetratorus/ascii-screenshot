#!/bin/zsh
# Compare JS (apple vision) vs Python (rapidocr) vs Python (apple vision)
# Usage: ./compare.sh <image> [width] [height]
#        ./compare.sh 1        # use tt-style index into ~/Documents/screenshots
#        ./compare.sh foo.png 80 30

set -eu
DIR="${0:A:h}"

img="$1"
width="${2:-160}"
height="${3:-60}"

if [[ "$img" =~ '^[0-9]+$' ]]; then
  setopt local_options null_glob
  local dir=~/Documents/screenshots
  local file=$(ls -t "$dir"/*.png "$dir"/*.jpg "$dir"/*.jpeg 2>/dev/null | awk "NR==$1{print;exit}")
  [ -z "$file" ] && { echo "No screenshot at position $1" >&2; exit 1; }
  img="$file"
fi

# HEIC conversion
actual_type=$(file -b --mime-type "$img")
if [[ "$actual_type" == image/heic || "$actual_type" == image/heif ]]; then
  tmp="/tmp/compare_converted_$$.png"
  sips -s format png "$img" --out "$tmp" > /dev/null 2>&1
  echo "(converted HEIC → $tmp)"
  img="$tmp"
fi

echo "=== Image: ${img:t} (${width}x${height}) ==="
echo ""

echo "--- JS + Apple Vision (original) ---"
node "$DIR/index.js" "$img" --width "$width" --height "$height" 2>&1 || echo "[FAILED]"
echo ""

echo "--- Python + RapidOCR ---"
python3 "$DIR/index.py" "$img" --width "$width" --height "$height" --ocr rapidocr 2>&1 || echo "[FAILED]"
echo ""

echo "--- Python + Apple Vision ---"
python3 "$DIR/index.py" "$img" --width "$width" --height "$height" --ocr apple 2>&1 || echo "[FAILED]"
echo ""
