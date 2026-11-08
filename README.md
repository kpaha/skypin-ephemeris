# SkyPin ephemeris mirror

Hourly GitHub Actions job that downloads the IGS daily broadcast ephemeris
(RINEX 3 mixed navigation file, all constellations) from BKG and other IGS data
centres and republishes it as assets of the GitHub release tagged `latest`.
Needed because the IGS servers are unreachable from some networks while
GitHub is.

Download URLs (stable, no auth):

- https://github.com/kpaha/skypin-ephemeris/releases/download/latest/brdc-today.rnx.gz
- https://github.com/kpaha/skypin-ephemeris/releases/download/latest/brdc-yesterday.rnx.gz
- https://github.com/kpaha/skypin-ephemeris/releases/download/latest/manifest.json

`manifest.json` says when the mirror last ran, which day numbers the files
hold and where they came from.

Setup: create a public GitHub repository, push this folder as its root, then
run the workflow once by hand (Actions → Mirror broadcast ephemeris → Run
workflow). The hourly schedule runs on its own after that.

Local test: `./mirror.sh out` (needs curl and gzip).

Data: IGS broadcast ephemeris, free to use; see https://igs.org/ for the data policy.
