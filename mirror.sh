#!/usr/bin/env bash
# Downloads today's and yesterday's IGS broadcast ephemeris (RINEX 3 mixed nav)
# from the first source that answers, verifies the files and writes them to ./out.
# Usage: ./mirror.sh [out-dir]
set -euo pipefail
OUT="${1:-out}"
mkdir -p "$OUT"

sources_for() {            # $1=yyyy $2=ddd  -> candidate URLs, best first
  local y=$1 d=$2
  cat <<URLS
https://igs.bkg.bund.de/root_ftp/IGS/BRDC/$y/$d/BRDC00WRD_R_${y}${d}0000_01D_MN.rnx.gz
https://igs.bkg.bund.de/root_ftp/IGS/BRDC/$y/$d/BRDC00WRD_S_${y}${d}0000_01D_MN.rnx.gz
https://igs.bkg.bund.de/root_ftp/MGEX/BRDC/$y/$d/BRDC00WRD_S_${y}${d}0000_01D_MN.rnx.gz
https://igs.gnsswhu.cn/pub/gps/data/daily/$y/brdc/BRDC00IGS_R_${y}${d}0000_01D_MN.rnx.gz
https://igs.ign.fr/pub/igs/data/$y/$d/BRDC00IGN_R_${y}${d}0000_01D_MN.rnx.gz
URLS
}

fetch_day() {              # $1=yyyy $2=ddd $3=target file; returns 0 on success
  local y=$1 d=$2 target=$3 url tmp
  tmp="$(mktemp)"
  while read -r url; do
    [ -z "$url" ] && continue
    echo "  try $url"
    if curl -fsSL --connect-timeout 15 --max-time 180 -o "$tmp" "$url" \
       && gzip -t "$tmp" 2>/dev/null \
       && gzip -dc "$tmp" | head -1 | grep -q "RINEX VERSION"; then
      mv "$tmp" "$target"
      echo "  ok  $(stat -c %s "$target" 2>/dev/null || stat -f %z "$target") bytes <- $url"
      echo "$url" > "$target.source"
      return 0
    fi
  done < <(sources_for "$y" "$d")
  rm -f "$tmp"
  return 1
}

today_y=$(date -u +%Y); today_d=$(date -u +%j)
yest_y=$(date -u -d yesterday +%Y 2>/dev/null || date -u -v-1d +%Y); yest_d=$(date -u -d yesterday +%j 2>/dev/null || date -u -v-1d +%j)

echo "today $today_y/$today_d"
fetch_day "$today_y" "$today_d" "$OUT/brdc-today.rnx.gz" || echo "  today not available yet"
echo "yesterday $yest_y/$yest_d"
fetch_day "$yest_y" "$yest_d" "$OUT/brdc-yesterday.rnx.gz" || echo "  yesterday not available"

[ -s "$OUT/brdc-today.rnx.gz" ] || [ -s "$OUT/brdc-yesterday.rnx.gz" ] || { echo "nothing downloaded"; exit 1; }

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "{"
  echo "  \"updatedUtc\": \"$now\","
  echo "  \"today\": {\"year\": $today_y, \"doy\": $today_d, \"available\": $([ -s "$OUT/brdc-today.rnx.gz" ] && echo true || echo false), \"source\": \"$(cat "$OUT/brdc-today.rnx.gz.source" 2>/dev/null || true)\"},"
  echo "  \"yesterday\": {\"year\": $yest_y, \"doy\": $yest_d, \"available\": $([ -s "$OUT/brdc-yesterday.rnx.gz" ] && echo true || echo false), \"source\": \"$(cat "$OUT/brdc-yesterday.rnx.gz.source" 2>/dev/null || true)\"}"
  echo "}"
} > "$OUT/manifest.json"
rm -f "$OUT"/*.source
cat "$OUT/manifest.json"
