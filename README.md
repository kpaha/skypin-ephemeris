# SkyPin ephemeris mirror

GitHub Actions job that downloads broadcast ephemerides (RINEX navigation files) and republishes
them as assets of the GitHub release tagged `current`. Needed because the IGS servers are
unreachable from some networks while GitHub is.

Download URLs (stable, no auth), all under
`https://github.com/kpaha/skypin-ephemeris/releases/download/current/`:

| Asset | Content |
|---|---|
| `brdc-today.rnx.gz`, `brdc-yesterday.rnx.gz` | RINEX 3 multi-GNSS daily broadcast file (main chain) |
| `noaa-gps-today.rnx.gz`, `noaa-gps-yesterday.rnx.gz` | NOAA CORS daily GPS broadcast file, RINEX 2.11 |
| `noaa-glo-today.rnx.gz`, `noaa-glo-yesterday.rnx.gz` | NOAA CORS daily GLONASS broadcast file, RINEX 2.11 |
| `manifest.json` | what the release holds (below) |
| `log.txt` | log of the last run |

## Sources

**Main chain** (`brdc-*`), tried in this order, the first valid file wins:

1. BKG `igs.bkg.bund.de` (IGS BRDC `_R_`, `_S_`, MGEX `_S_`)
2. Wuhan `igs.gnsswhu.cn` (`BRDC00IGS_R`)
3. IGN `igs.ign.fr` (`BRDC00IGN_R`)
4. NASA CDDIS (`BRDC00IGS_R`, then `BRDM00DLR_S`), over anonymous FTP-SSL
   (`ftp://gdc.cddis.eosdis.nasa.gov/gnss/data/daily/YYYY/brdc/`); when that route fails and the
   Earthdata secrets are set, over HTTPS with an Earthdata login
   (`https://cddis.nasa.gov/archive/gnss/data/daily/YYYY/brdc/`). CDDIS publishes these merged
   multi-GNSS files only for finished days, so in practice it backs up "yesterday".

The run fails only when no source of the main chain delivered a file, for today or for yesterday.
A host that cannot be reached is not tried again within the same run.

**NOAA** (`noaa-*`), fetched on every run in addition, from the public bucket
`https://noaa-cors-pds.s3.amazonaws.com/rinex/YYYY/DDD/brdcDDD0.YYn.gz` (GPS) and `.YYg.gz`
(GLONASS), refreshed about hourly during the day. Its failures are logged and never change the
result of the run.

Every file is checked (gzip intact, RINEX 2.x/3.x navigation header, at least one satellite)
before it can be uploaded; an asset that was not refreshed keeps its previous version.

## manifest.json

```json
{
  "updatedUtc": "2026-11-17T05:41:10Z",
  "runUtc": "2026-11-18T04:59:50Z",
  "mainChainOk": false,
  "today": {"asset": "brdc-today.rnx.gz", "available": true, "refreshed": false,
            "year": 2026, "doy": 321, "source": "https://igs.bkg.bund.de/...",
            "fetchedUtc": "2026-11-17T05:41:10Z", "bytes": 401234,
            "rinexVersion": "3.04", "satellites": 120, "newestEpoch": "2026-11-17T06:00:00"},
  "yesterday": {"...": "same fields"},
  "noaa": {
    "gpsToday":     {"asset": "noaa-gps-today.rnx.gz", "available": true, "refreshed": true,
                     "year": 2026, "doy": 322, "source": "https://noaa-cors-pds.s3.amazonaws.com/rinex/2026/322/brdc3220.26n.gz",
                     "fetchedUtc": "2026-11-18T04:59:50Z", "bytes": 18829,
                     "rinexVersion": "2.11", "satellites": 32, "newestEpoch": "2026-11-18T04:59:44"},
    "gpsYesterday": {"...": "same fields"},
    "gloToday":     {"...": "same fields"},
    "gloYesterday": {"...": "same fields"}
  }
}
```

- Every entry describes the asset as the release holds it **after** the run: `available` (the
  release has it), `refreshed` (replaced by this run), `year`/`doy` (the day the file covers, which
  can be an earlier day than the name says when a refresh failed), `source`, `fetchedUtc`,
  `bytes`, `satellites`, `newestEpoch` (latest record epoch as written in the file: GPS time for
  GPS, UTC for GLONASS). Fields that cannot be known (an asset published by an older version of
  the mirror) are `null`. A missing asset is `{"asset": ..., "available": false, "refreshed": false}`.
- `updatedUtc` is when the published `brdc-today.rnx.gz` (else `brdc-yesterday.rnx.gz`) was last
  refreshed — not the time of the run, which is `runUtc`. Released app versions read only this key
  as the age of the mirror's data (older than 3 hours sends them to the upstream servers), so it
  must not claim fresh data the run did not get. It is omitted when unknown. No other key may be
  named `updatedUtc` (the app takes the first match).

## Setup

Create a public GitHub repository, push this folder as its root, then run the workflow once by
hand (Actions → Mirror broadcast ephemeris → Run workflow). The schedule runs on its own after that.

### Optional: NASA Earthdata login for CDDIS

Not needed while CDDIS's anonymous FTP-SSL route works from GitHub's runners (see `log.txt`).
For the HTTPS fallback:

1. Register at https://urs.earthdata.nasa.gov/users/new (free).
2. Log in once in a browser at https://cddis.nasa.gov/archive/gnss/data/daily/ and accept what
   Earthdata asks (CDDIS's documentation notes that a 403 means the application has not been
   authorised for the account).
3. In the mirror repository: Settings → Secrets and variables → Actions → New repository secret:
   `EARTHDATA_USERNAME` and `EARTHDATA_PASSWORD`.

The script writes them to a netrc file readable only by the runner user in a temporary directory
(removed on exit); they never appear on a command line, in the log, the manifest or an asset.
`CDDIS_FTP_PASSWORD` (environment, default `anonymous`) is the password of the anonymous FTP-SSL
login, where CDDIS asks for an e-mail address.

## Second trigger: the owner's server

GitHub runs scheduled workflows late or not at all under load ("high load times include the start
of every hour ... some queued jobs may be dropped"), and disables the schedule of a public
repository after 60 days without repository activity. `server/trigger-mirror.sh` starts the
workflow through the API (`workflow_dispatch`) from cron on any Linux server with curl.

1. GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens →
   Generate new token. Resource owner: the account owning the mirror; Repository access: **Only
   select repositories** → the mirror repository; Repository permissions: **Actions: Read and
   write** (Metadata: read-only is added automatically). Pick an expiry and note it — the trigger
   stops working (HTTP 401) when the token expires.
2. On the server, as root:

   ```sh
   install -d -m 700 /etc/ephemeris-mirror
   (umask 077; printf '%s\n' 'github_pat_...' > /etc/ephemeris-mirror/github-token)
   install -m 755 trigger-mirror.sh /usr/local/bin/trigger-mirror.sh
   /usr/local/bin/trigger-mirror.sh     # expect: "dispatched mirror.yml on ..."
   ```

   (or type the token into the file with an editor, to keep it out of the shell history). The
   script refuses a token file that group or others can read.
3. Root's crontab (`crontab -e` as root), twice an hour at minutes the GitHub schedule does not use:

   ```
   11,44 * * * * /usr/local/bin/trigger-mirror.sh >> /var/log/trigger-mirror.log 2>&1
   ```

`REPO`, `WORKFLOW` and `REF` at the top of the script name the target; `TOKEN_FILE` can be set in
the environment to use another path. Overlapping starts are harmless: the workflow's concurrency
group lets one run at a time, with at most one more waiting (a newer start replaces the waiting one).

## Local test

`./mirror.sh out` (needs bash, curl, gzip, awk, jq). `MIRROR_TEST_MAIN_DOWN=1` or
`MIRROR_TEST_NOAA_DOWN=1` point the main chain or the NOAA downloads at an unreachable host to
exercise the failure paths; `PREV_DIR=dir` with `manifest.json` and `assets.json`
(`gh release view current --json assets`) simulates what the release held before.

Data: IGS broadcast ephemeris, free to use, see https://igs.org/ for the data policy; NASA CDDIS
(https://www.earthdata.nasa.gov/centers/cddis-daac); NOAA CORS Network
(https://geodesy.noaa.gov/CORS/).

## Cell towers

`cells/` holds a second, weekly job (`.github/workflows/cells.yml`) that converts the OpenCelliD
export into per-country cell files for offline positioning and publishes them under the release
tag `cells`: https://github.com/kpaha/skypin-ephemeris/releases/download/cells/manifest.json.
Needs the repository secret `OPENCELLID_KEY`. Details in `cells/README.md`; data OpenCelliD,
CC BY-SA 4.0.
