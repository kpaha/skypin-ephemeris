#!/usr/bin/env bash
# Downloads today's and yesterday's broadcast ephemeris and writes the verified files plus
# manifest.json to the output directory.
#
# Main chain (the files brdc-today.rnx.gz / brdc-yesterday.rnx.gz, RINEX 3 multi-GNSS): the
# sources below in order, first valid file wins; NASA CDDIS comes last. The run fails (exit 1)
# only when no source of the main chain delivered anything for today or yesterday AND the release
# holds no multi-GNSS file whose newest data is under MAX_HELD_AGE_HOURS old (default 6).
# NOAA CORS (noaa-{gps,glo}-{today,yesterday}.rnx.gz, RINEX 2.11 GPS / GLONASS): fetched on
# every run in addition; its failures are logged and never change the exit status.
#
# Usage: ./mirror.sh [out-dir]
# Environment (all optional):
#   PREV_DIR             directory with what the release held before this run: manifest.json
#                        (the previous manifest) and assets.json (`gh release view --json assets`).
#                        Used to describe in the manifest the assets this run did not replace.
#   EARTHDATA_USERNAME   NASA Earthdata login, for the CDDIS HTTPS route. That route is used only
#   EARTHDATA_PASSWORD   when the anonymous FTP-SSL route to CDDIS fails.
#   CDDIS_FTP_PASSWORD   password sent with the anonymous CDDIS FTP-SSL login (CDDIS asks for an
#                        e-mail address there); default "anonymous".
#   MIRROR_TEST_MAIN_DOWN=1, MIRROR_TEST_NOAA_DOWN=1
#                        tests only: point the main chain / the NOAA downloads at an unreachable host.
#
# Runs on Linux (GitHub runner) and macOS (bash 3.2, BSD date/stat). Needs curl, gzip, awk, jq.
set -euo pipefail
OUT="${1:-out}"
MAX_HELD_AGE_HOURS="${MAX_HELD_AGE_HOURS:-6}"
mkdir -p "$OUT"
command -v jq >/dev/null || { echo "jq is required"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CDDIS_FTP_HOST="gdc.cddis.eosdis.nasa.gov"
CDDIS_FTP_PASSWORD="${CDDIS_FTP_PASSWORD:-anonymous}"
CURL_OPTS=(-fsSL --connect-timeout 15 --max-time 120)

# Credentials go to a netrc file readable only by this user, never to command lines or the log.
NETRC="$WORK/netrc"
COOKIES="$WORK/cookies"
(
  umask 077
  q() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
  printf 'machine %s login anonymous password %s\n' "$CDDIS_FTP_HOST" "$(q "$CDDIS_FTP_PASSWORD")" > "$NETRC"
  if [ -n "${EARTHDATA_USERNAME:-}" ] && [ -n "${EARTHDATA_PASSWORD:-}" ]; then
    printf 'machine urs.earthdata.nasa.gov login %s password %s\n' "$(q "$EARTHDATA_USERNAME")" "$(q "$EARTHDATA_PASSWORD")" >> "$NETRC"
  fi
  : > "$COOKIES"
)
HAVE_EDL=0
[ -n "${EARTHDATA_USERNAME:-}" ] && [ -n "${EARTHDATA_PASSWORD:-}" ] && HAVE_EDL=1
EDL_NOTED=0

DOWN_HOSTS=" "              # hosts that failed to connect earlier in this run
host_of() { local h=${1#*://}; echo "${h%%/*}"; }
fsize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

# "version satellites newestEpoch" of a gzip RINEX 2/3 navigation file; empty when unreadable.
# newestEpoch is the latest record epoch as written in the file (GPS time for GPS, UTC for GLONASS).
rinex_info() {
  gzip -dc "$1" 2>/dev/null | awk '
    NR == 1 { ver = substr($0, 1, 9) + 0; type = substr($0, 21, 1) }
    !body { if (index($0, "END OF HEADER")) body = 1; next }
    ver >= 3 {
      s = substr($0, 1, 1)
      if (s ~ /[GRECJIS]/ && substr($0, 2, 2) ~ /^[ 0-9][0-9]$/ && substr($0, 5, 4) ~ /^[0-9][0-9][0-9][0-9]$/) {
        sat = s sprintf("%02d", substr($0, 2, 2) + 0)
        ep = sprintf("%04d-%02d-%02dT%02d:%02d:%02d", substr($0, 5, 4), substr($0, 10, 2), substr($0, 13, 2),
                     substr($0, 16, 2), substr($0, 19, 2), substr($0, 22, 2))
        seen[sat] = 1; if (ep > newest) newest = ep
      }
      next
    }
    substr($0, 1, 2) ~ /^ ?[0-9]+$/ && substr($0, 4, 2) ~ /^[ 0-9][0-9]$/ {
      yy = substr($0, 4, 2) + 0
      sat = (type == "G" ? "R" : "G") sprintf("%02d", substr($0, 1, 2) + 0)
      ep = sprintf("%04d-%02d-%02dT%02d:%02d:%02d", (yy < 80 ? 2000 : 1900) + yy, substr($0, 7, 2), substr($0, 10, 2),
                   substr($0, 13, 2), substr($0, 16, 2), int(substr($0, 18, 5)))
      seen[sat] = 1; if (ep > newest) newest = ep
    }
    END { n = 0; for (k in seen) n++; if (ver > 0) printf "%s %d %s\n", ver, n, newest }' || true
}

# 0 when $1 is an intact gzip RINEX 2.x/3.x navigation file with at least one satellite.
valid_rinex() {
  local f=$1 header info
  gzip -t "$f" 2>/dev/null || { echo "      not a valid gzip file"; return 1; }
  # head closes the pipe early; the "|| true" keeps pipefail from failing the test.
  header=$(gzip -dc "$f" 2>/dev/null | head -1 || true)
  [[ "$header" == *"RINEX VERSION"* ]] || { echo "      no RINEX header"; return 1; }
  case "${header:20:1}" in N|G) ;; *) echo "      not a navigation file"; return 1 ;; esac
  info=$(rinex_info "$f")
  set -- $info
  [ $# -ge 3 ] || { echo "      unreadable records"; return 1; }
  case "$1" in 2*|3*) ;; *) echo "      RINEX $1 not accepted (2.x/3.x only)"; return 1 ;; esac
  [ "$2" -gt 0 ] || { echo "      no satellites"; return 1; }
}

# Downloads $1 to $2. Returns curl's exit code; remembers hosts that cannot be reached.
download() {
  local url=$1 dest=$2 host rc=0
  shift 2
  host=$(host_of "$url")
  case "$DOWN_HOSTS" in *" $host "*) echo "    skip (host $host unreachable earlier in this run)"; return 7 ;; esac
  curl "${CURL_OPTS[@]}" "$@" -o "$dest" "$url" 2>"$WORK/curl.err" || rc=$?
  if [ $rc -ne 0 ]; then
    echo "    failed: $(tail -1 "$WORK/curl.err" | cut -c1-200)"
    case $rc in 6|7|28|35) DOWN_HOSTS="$DOWN_HOSTS$host " ;; esac
  fi
  return $rc
}

# Tries the candidate lines on stdin ("http URL" or "cddis PATH") in order; the first valid file
# is moved to $1 and its source written to $1.source.
fetch_first() {
  local target=$1 test_down=$2 kind loc url tmp rc ok
  tmp="$WORK/dl.tmp"
  while read -r kind loc; do
    [ -z "$kind" ] && continue
    rm -f "$tmp"
    if [ "$kind" = cddis ]; then
      url="ftp://$CDDIS_FTP_HOST/$loc"
      [ "$test_down" = 1 ] && url="https://test-unreachable.invalid/${url#*://}"
      echo "  try $url"
      rc=0; download "$url" "$tmp" --ssl-reqd --netrc-file "$NETRC" || rc=$?
      if [ $rc -eq 0 ] && valid_rinex "$tmp"; then
        ok=1
      elif [ $rc -eq 78 ] || [ $rc -eq 9 ]; then
        ok=0       # file (or directory) not on the server: the HTTPS route would not have it either
      elif [ $HAVE_EDL = 1 ]; then
        url="https://cddis.nasa.gov/archive/$loc"
        [ "$test_down" = 1 ] && url="https://test-unreachable.invalid/${url#*://}"
        echo "  try $url (Earthdata login)"
        rm -f "$tmp"
        ok=0; download "$url" "$tmp" --netrc-file "$NETRC" -c "$COOKIES" -b "$COOKIES" && valid_rinex "$tmp" && ok=1
      else
        ok=0
        if [ $EDL_NOTED = 0 ]; then
          echo "    CDDIS HTTPS route skipped: EARTHDATA_USERNAME / EARTHDATA_PASSWORD not set"
          EDL_NOTED=1
        fi
      fi
    else
      url=$loc
      [ "$test_down" = 1 ] && url="https://test-unreachable.invalid/${url#*://}"
      echo "  try $url"
      ok=0; download "$url" "$tmp" && valid_rinex "$tmp" && ok=1
    fi
    if [ $ok = 1 ]; then
      mv "$tmp" "$target"
      echo "  ok  $(fsize "$target") bytes, RINEX/satellites/newest epoch: $(rinex_info "$target") <- $url"
      echo "$url" > "$target.source"
      return 0
    fi
  done
  rm -f "$tmp"
  return 1
}

main_sources() {           # $1=yyyy $2=ddd -> candidates, best first
  local y=$1 d=$2
  cat <<URLS
http https://igs.bkg.bund.de/root_ftp/IGS/BRDC/$y/$d/BRDC00WRD_R_${y}${d}0000_01D_MN.rnx.gz
http https://igs.bkg.bund.de/root_ftp/IGS/BRDC/$y/$d/BRDC00WRD_S_${y}${d}0000_01D_MN.rnx.gz
http https://igs.bkg.bund.de/root_ftp/MGEX/BRDC/$y/$d/BRDC00WRD_S_${y}${d}0000_01D_MN.rnx.gz
http https://igs.gnsswhu.cn/pub/gps/data/daily/$y/brdc/BRDC00IGS_R_${y}${d}0000_01D_MN.rnx.gz
http https://igs.ign.fr/pub/igs/data/$y/$d/BRDC00IGN_R_${y}${d}0000_01D_MN.rnx.gz
cddis gnss/data/daily/$y/brdc/BRDC00IGS_R_${y}${d}0000_01D_MN.rnx.gz
cddis gnss/data/daily/$y/brdc/BRDM00DLR_S_${y}${d}0000_01D_MN.rnx.gz
URLS
}

noaa_source() {            # $1=yyyy $2=ddd $3=yy $4=n|g
  echo "http https://noaa-cors-pds.s3.amazonaws.com/rinex/$1/$2/brdc${2}0.${3}${4}.gz"
}

ymd() {                    # $1=strftime format, $2=today|yesterday
  if [ "$2" = today ]; then date -u "+$1"; else date -u -d yesterday "+$1" 2>/dev/null || date -u -v-1d "+$1"; fi
}

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "run $now"
main_ok=false
DAYS="today yesterday"
for day in $DAYS; do
  y=$(ymd %Y "$day"); d=$(ymd %j "$day")
  echo "$day $y/$d (main chain)"
  # Process substitution keeps fetch_first in this shell, so unreachable hosts are remembered.
  if fetch_first "$OUT/brdc-$day.rnx.gz" "${MIRROR_TEST_MAIN_DOWN:-0}" < <(main_sources "$y" "$d"); then
    main_ok=true
  else
    echo "  $day: no source of the main chain delivered a valid file"
  fi
done

for day in $DAYS; do
  y=$(ymd %Y "$day"); d=$(ymd %j "$day"); yy=$(ymd %y "$day")
  for sys in gps glo; do
    [ $sys = gps ] && ext=n || ext=g
    echo "$day $y/$d (NOAA $sys)"
    fetch_first "$OUT/noaa-$sys-$day.rnx.gz" "${MIRROR_TEST_NOAA_DOWN:-0}" < <(noaa_source "$y" "$d" "$yy" "$ext") \
      || echo "  NOAA $sys $day not available (does not affect the run's result)"
  done
done

# ---- manifest.json: what the release holds after this run ----
# Released app versions read only "updatedUtc" (first match of a regex, as the age of the brdc data;
# older than 3 h makes them try the upstreams directly). It is therefore the time the published
# brdc-today asset (else brdc-yesterday) was last refreshed, not the time of this run, and no other
# key may be named "updatedUtc". It is left out when that time is unknown.
PREV_MANIFEST="$WORK/prev-manifest.json"; PREV_ASSETS="$WORK/prev-assets.json"
echo null > "$PREV_MANIFEST"; echo null > "$PREV_ASSETS"
if [ -n "${PREV_DIR:-}" ]; then
  jq -e 'type == "object"' "$PREV_DIR/manifest.json" >/dev/null 2>&1 && cp "$PREV_DIR/manifest.json" "$PREV_MANIFEST"
  jq -e '.assets | type == "array"' "$PREV_DIR/assets.json" >/dev/null 2>&1 && cp "$PREV_DIR/assets.json" "$PREV_ASSETS"
fi

entry() {                  # $1=asset file name  $2=manifest path as JSON array  $3=day  -> entry JSON
  local asset=$1 path=$2 day=$3 f="$OUT/$1" info
  if [ -s "$f" ]; then
    info=$(rinex_info "$f")
    set -- $info
    jq -n --arg asset "$asset" --argjson year "$(ymd %Y "$day")" --argjson doy "$((10#$(ymd %j "$day")))" \
      --arg source "$(cat "$f.source")" --arg now "$now" --argjson bytes "$(fsize "$f")" \
      --arg ver "$1" --argjson sats "$2" --arg epoch "$3" \
      '{asset: $asset, available: true, refreshed: true, year: $year, doy: $doy, source: $source,
        fetchedUtc: $now, bytes: $bytes, rinexVersion: $ver, satellites: $sats, newestEpoch: $epoch}'
  else
    # Not replaced this run: describe what the release still holds, from the previous manifest
    # (old-format entries only for the day they claim) and the release's asset list.
    jq -n --slurpfile m "$PREV_MANIFEST" --slurpfile a "$PREV_ASSETS" --arg asset "$asset" --argjson p "$path" '
      ($m[0]) as $m | ($a[0]) as $a
      | (if $m == null then null else ($m | getpath($p)) end) as $e
      | (if ($e | type) == "object" and $e.available == true then $e else {} end) as $e
      | (if $a == null then null else ([$a.assets[] | select(.name == $asset)] | first) end) as $h
      | if $h == null and ($a != null or $e == {}) then
          {asset: $asset, available: false, refreshed: false}
        else
          {asset: $asset, available: true, refreshed: false,
           year: ($e.year // null), doy: ($e.doy // null), source: ($e.source // null),
           fetchedUtc: ($e.fetchedUtc // $h.updatedAt // null), bytes: ($h.size // $e.bytes // null),
           rinexVersion: ($e.rinexVersion // null), satellites: ($e.satellites // null),
           newestEpoch: ($e.newestEpoch // null)}
        end'
  fi
}

entry brdc-today.rnx.gz '["today"]' today > "$WORK/e-today.json"
entry brdc-yesterday.rnx.gz '["yesterday"]' yesterday > "$WORK/e-yesterday.json"
for day in $DAYS; do
  for sys in gps glo; do
    key="$sys$(echo "${day:0:1}" | tr a-z A-Z)${day:1}"      # gpsToday, gloYesterday, ...
    entry "noaa-$sys-$day.rnx.gz" "[\"noaa\",\"$key\"]" "$day" > "$WORK/e-noaa-$key.json"
  done
done

jq -n --arg now "$now" --argjson ok "$main_ok" \
  --slurpfile t "$WORK/e-today.json" --slurpfile y "$WORK/e-yesterday.json" \
  --slurpfile gt "$WORK/e-noaa-gpsToday.json" --slurpfile gy "$WORK/e-noaa-gpsYesterday.json" \
  --slurpfile rt "$WORK/e-noaa-gloToday.json" --slurpfile ry "$WORK/e-noaa-gloYesterday.json" '
  ([$t[0], $y[0]] | map(select(.available and .fetchedUtc != null)) | first | .fetchedUtc) as $upd
  | (if $upd then {updatedUtc: $upd} else {} end)
    + {runUtc: $now, mainChainOk: $ok, today: $t[0], yesterday: $y[0],
       noaa: {gpsToday: $gt[0], gpsYesterday: $gy[0], gloToday: $rt[0], gloYesterday: $ry[0]}}' \
  > "$OUT/manifest.json"
rm -f "$OUT"/*.source
cat "$OUT/manifest.json"

if [ "$main_ok" != true ]; then
  echo "nothing downloaded by the main chain (published brdc assets, if any, stay as they were)"
  # Not a failure while the release still holds a recent multi-GNSS file: in the first hours of a UTC day no
  # source has today's merged file yet and CDDIS has not published yesterday's, which is normal. Age = now minus
  # the newest epoch in the held file (else the time it was fetched).
  held_age_h=$(jq -r --arg now "$now" '
    [.today, .yesterday] | map(select(.available == true))
    | map(if .newestEpoch then (.newestEpoch | sub("Z$"; "") | . + "Z" | fromdateiso8601)
          elif .fetchedUtc then (.fetchedUtc | fromdateiso8601) else empty end)
    | if length == 0 then "none" else ((($now | fromdateiso8601) - max) / 3600 | floor) end' "$OUT/manifest.json" 2>/dev/null || echo none)
  if [ "$held_age_h" != none ] && [ "$held_age_h" -lt "$MAX_HELD_AGE_HOURS" ]; then
    echo "the release still holds a multi-GNSS file with data ${held_age_h} h old (limit ${MAX_HELD_AGE_HOURS} h): not an error"
    exit 0
  fi
  echo "held multi-GNSS data: ${held_age_h} h old (limit ${MAX_HELD_AGE_HOURS} h)"
  exit 1
fi
