# Cell tower mirror (OpenCelliD → SkyPin)

Weekly GitHub Actions job that downloads the full OpenCelliD export (about 40 million cells,
1–2 GB gzip), keeps GSM/UMTS/LTE/NR cells with at least two measurements and a range up to 50 km,
and publishes one small sorted binary file per country (MCC), large countries split into 10°×10°
tiles. The SkyPin app downloads the files it needs and finds a cell by binary search, offline.
Format: [FORMAT.md](FORMAT.md).

Published in the repository `kpaha/skypin-ephemeris` (scripts under `cells/`, workflow in
`.github/workflows/cells.yml`; this directory is the source copy).

## Licence and attribution

Data: [OpenCelliD](https://opencellid.org), licensed
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The converted files are derived
works and are published openly under the same licence. The app shows "Cell data: OpenCelliD,
CC BY-SA 4.0" in About; `manifest.json` carries the same line in `licence`.

## URLs for the app

    https://github.com/kpaha/skypin-ephemeris/releases/download/cells/manifest.json
    https://github.com/kpaha/skypin-ephemeris/releases/download/cells/<name>

Read the manifest first, pick files by `mcc` and `tile`, check `sha256` after download. Names:
`<mcc>.bin.gz` or `<mcc>-N50E030.bin.gz` (tile by south-west corner). `log.txt` in the same
release is the last run's log.

## Files

- `convert.py` — CSV(.gz) → binary files + `manifest.json`. Streaming; memory is bounded by the
  largest single output file during sorting. Options: `--mcc N` (one country, for a per-MCC
  download), `--limit N` (rows, for tests), `--date`, `--max-bytes`.
- `read_cells.py` — reference reader: `--info`, `--index N`, lookup `MNC AREA CELL [--radio LTE]`.
- `test_convert.py` — unit tests: `python3 -m unittest -v test_convert`.
- `cells.sh` — `build [out]` downloads and converts (key from env `OPENCELLID_KEY`, checks HTTP
  status and gzip, deletes the CSV after conversion, refuses to publish fewer than 1 million cells);
  `publish [out]` replaces the assets of release `cells` (data first, manifest last, stale files
  removed) and uploads `log.txt`.

## Running locally

The full export is large and OpenCelliD limits downloads per key per day; for a local check
download one country:

    export OPENCELLID_KEY=...          # never commit it
    MCC=250 ./cells.sh build out       # Russia only
    python3 read_cells.py out/250-N50E030.bin.gz --info --index 0

Or convert a file you already have:

    python3 convert.py 250.csv.gz out --mcc 250

## GitHub Actions

Secret `OPENCELLID_KEY` (repository → Settings → Secrets and variables → Actions). Without it the
workflow fails at the first step with a clear message. Runs weekly (Monday, two cron entries),
on `workflow_dispatch`, and on pushes that change `cells/` or the workflow. Time limit 110 min.
On a failed download or conversion the previous files stay and only `log.txt` is replaced.
