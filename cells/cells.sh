#!/usr/bin/env bash
# OpenCelliD -> SkyPin cell files, published as assets of the GitHub release tagged "cells".
#
#   ./cells.sh build   [out-dir]   download the export (key in env OPENCELLID_KEY), convert into out-dir
#   ./cells.sh publish [out-dir]   upload out-dir/*.bin.gz + manifest.json + log.txt to release "cells"
#                                  (replaces assets, removes ones no longer in the manifest); needs gh
#                                  with GH_TOKEN, run inside the repo or with GH_REPO=owner/name
#
# Env: OPENCELLID_KEY (required for build); MCC=250 downloads one country instead of the full export
# (local tests); MIN_CELLS (default 1000000 for the full export, 1000 with MCC) guards against
# publishing a truncated export; BUILD_OK=0 makes publish upload only log.txt.
# The key is never printed: curl reads the URL from stdin, and server replies are scrubbed.
set -euo pipefail
cmd="${1:-}"; OUT="${2:-out}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TAG=cells

build() {
  if [ -z "${OPENCELLID_KEY:-}" ]; then
    echo "ERROR: OPENCELLID_KEY is not set. Add the OpenCelliD API key as the repository secret OPENCELLID_KEY." >&2
    exit 2
  fi
  mkdir -p "$OUT"
  local csv type file min code
  WORK="$(mktemp -d)"
  csv="$WORK/cells.csv.gz"
  trap 'rm -rf "$WORK"' EXIT
  if [ -n "${MCC:-}" ]; then type=mcc; file="$MCC.csv.gz"; min="${MIN_CELLS:-1000}"
  else type=full; file=cell_towers.csv.gz; min="${MIN_CELLS:-1000000}"; fi

  echo "$(date -u +%FT%TZ) download OpenCelliD type=$type file=$file"
  code=$(printf 'url = "https://opencellid.org/ocid/downloads?token=%s&type=%s&file=%s"\n' \
           "$OPENCELLID_KEY" "$type" "$file" |
         curl -sS -L --retry 3 --retry-delay 30 --connect-timeout 30 --max-time 3600 \
              -o "$csv" -w '%{http_code}' -K - || true)
  local size; size=$(stat -c %s "$csv" 2>/dev/null || stat -f %z "$csv" 2>/dev/null || echo 0)
  echo "$(date -u +%FT%TZ) HTTP $code, $size bytes"
  if [ "$code" != "200" ] || [ "$(head -c 2 "$csv" | od -An -tx1 | tr -d ' \n')" != "1f8b" ]; then
    local body; body="$(head -c 400 "$csv" 2>/dev/null | tr -cd '[:print:]\n' || true)"
    body="${body//"$OPENCELLID_KEY"/***}"
    echo "ERROR: download failed (HTTP $code) or the reply is not gzip. Server said: $body" >&2
    exit 1
  fi
  gzip -t "$csv" || { echo "ERROR: gzip archive is corrupt or truncated" >&2; exit 1; }
  echo "$(date -u +%FT%TZ) gzip ok, converting"

  rm -f "$OUT"/*.bin.gz "$OUT/manifest.json"
  python3 "$HERE/convert.py" "$csv" "$OUT" ${MCC:+--mcc "$MCC"}
  rm -f "$csv"                           # free the disk as soon as possible
  local cells
  cells=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cells"])' "$OUT/manifest.json")
  if [ "$cells" -lt "$min" ]; then
    echo "ERROR: only $cells cells (expected at least $min); not publishing" >&2
    rm -f "$OUT/manifest.json"
    exit 1
  fi
  echo "$(date -u +%FT%TZ) done: $cells cells, $(ls "$OUT"/*.bin.gz | wc -l | tr -d ' ') files, $(du -sh "$OUT" | cut -f1)"
}

publish() {
  if ! gh release view "$TAG" >/dev/null 2>&1; then
    gh release create "$TAG" --title "Cell tower positions (OpenCelliD)" --notes \
"Weekly conversion of the OpenCelliD export for SkyPin: one sorted binary file per country (MCC), large countries split into 10x10 degree tiles. Start from manifest.json. Format: cells/FORMAT.md in this repository.

Data: OpenCelliD (https://opencellid.org), licensed CC BY-SA 4.0. These derived files are published under the same licence."
  fi
  if [ "${BUILD_OK:-1}" = "1" ] && [ -s "$OUT/manifest.json" ]; then
    local new old stale
    new=$(python3 -c 'import json,sys; print("\n".join(f["name"] for f in json.load(open(sys.argv[1]))["files"]))' "$OUT/manifest.json")
    echo "uploading $(echo "$new" | wc -l | tr -d ' ') files"
    # Data files first, manifest last, so a reader never sees a manifest that points at missing files.
    echo "$new" | sed "s|^|$OUT/|" | xargs -n 50 gh release upload "$TAG" --clobber
    gh release upload "$TAG" "$OUT/manifest.json" --clobber
    old=$(gh release view "$TAG" --json assets -q '.assets[].name')
    stale=$(comm -23 <(echo "$old" | grep '\.bin\.gz$' | sort) <(echo "$new" | sort) || true)
    for f in $stale; do echo "delete stale $f"; gh release delete-asset "$TAG" "$f" --yes; done
  else
    echo "build failed or no manifest: keeping the previous cell files"
  fi
  if [ -s "$OUT/log.txt" ]; then gh release upload "$TAG" "$OUT/log.txt" --clobber; fi
  echo "published"
}

case "$cmd" in
  build) build ;;
  publish) publish ;;
  *) echo "usage: $0 build|publish [out-dir]" >&2; exit 2 ;;
esac
