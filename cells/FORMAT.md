# SkyPin cell file format, version 1

One file holds the cell towers of one country code (MCC), or of one 10°×10° tile of a large
country. Files are gzip-compressed; after decompression a file is a 32-byte header followed by
`count` fixed-size records of 18 bytes. All integers are **big-endian** (Java `ByteBuffer`
default). Decompressed size is always `32 + 18 * count`.

## Header (32 bytes)

| Offset | Type   | Field        | Meaning |
|-------:|--------|--------------|---------|
| 0      | 4 B    | magic        | ASCII `SKYC` |
| 4      | u16    | version      | `1` |
| 6      | u16    | recordBytes  | `18` |
| 8      | u16    | mcc          | Mobile country code of every record in the file |
| 10     | u16    | flags        | bit 0: file is a tile (bounds are the tile); other bits 0 |
| 12     | i16    | latMin       | Bounds in whole degrees. Tile: south-west corner and corner + 10. |
| 14     | i16    | lonMin       | Whole-country file: bounding box of its cells, rounded outwards. |
| 16     | i16    | latMax       | |
| 18     | i16    | lonMax       | |
| 20     | u32    | count        | Number of records |
| 24     | u32    | created      | Conversion date as the number `YYYYMMDD` (e.g. 20261112) |
| 28     | u32    | reserved     | 0 |

A reader rejects files whose magic, version or record size differ.

## Record (18 bytes)

| Offset | Type | Field   | Meaning |
|-------:|------|---------|---------|
| 0      | u16  | mnc     | Mobile network code |
| 2      | u16  | area    | LAC (GSM/UMTS) or TAC (LTE/NR) |
| 4      | u32  | cell    | GSM CID, UMTS CID (RNC·65536 + CID, 28 bit), LTE ECI (28 bit); NR: **low 32 bits** of the 36-bit NCI |
| 8      | i32  | lat     | Latitude, units of 1e-5° (`lat / 100000.0`) |
| 12     | i32  | lon     | Longitude, units of 1e-5° |
| 16     | u8   | range   | OpenCelliD range estimate in 50 m steps: metres = `range * 50`. 255 means ≥ 12.75 km. Minimum 2 (100 m). |
| 17     | u8   | meta    | bits 7–6: radio (0 GSM, 1 UMTS, 2 LTE, 3 NR); bits 5–0: number of measurements, clamped to 63 |

The radio and the sample count share one byte so that the record stays at 18 bytes.

## Order and lookup

Records are sorted by the unsigned tuple `(mnc, area, cell)` and, for equal keys, by radio.
Because the key is stored big-endian at the start of the record, this is also the byte order of
the first 8 bytes (`mnc`, `area`, `cell` compared as unsigned numbers).

Lookup of a serving cell `(mnc, area, cell)`: binary search for the lower bound of the key, then
walk forward while the key matches. More than one record can match:

- the same `(mnc, area, cell)` reported as different radio types (e.g. an LTE and an NR cell in one
  TAC whose NR NCI shares its low 32 bits); filter by the radio the phone reports;
- two NR cells whose NCIs differ only in the top 4 bits (rare; treat as ambiguous or take the one
  nearer the previous position).

For a given radio, there is at most one record per key: duplicates in the source are reduced to
the entry with the most measurements.

Keys that the phone reports and the file cannot hold: `area` above 65535 (NR TACs are 24 bit) are
not in the files; look them up as missing.

## Filters applied at conversion

From the OpenCelliD CSV (`radio,mcc,net,area,cell,unit,lon,lat,range,samples,...`):
radio ∈ {GSM, UMTS, LTE, NR} (CDMA dropped); `samples ≥ 2`; `range ≤ 50 000 m`, ranges below
100 m raised to 100 m; latitude −90…90, longitude −180…180, not (0, 0); `mnc` and `area` ≤ 65535;
non-NR `cell` ≤ 2³²−1.

## File names and tiles

- Whole country: `<mcc>.bin.gz`, e.g. `208.bin.gz`.
- Tile: `<mcc>-<N|S><lat:2><E|W><lon:3>.bin.gz`, named after the south-west corner, e.g.
  `250-N50E030.bin.gz` covers 50–60° N, 30–40° E; `310-S10W080.bin.gz` covers 10–0° S, 80–70° W.
  A cell belongs to the tile `floor(lat/10)*10, floor(lon/10)*10` (latitude 90 and longitude 180
  fall into the last tile).

Tiled countries: 250 (RU), 310–316 (US), 460 (CN), 724 (BR), 404/405 (IN), 302 (CA), 505 (AU), and
any other MCC whose whole-country file would exceed 10 MB compressed. A cell near a tile edge or a
country border can be heard from the neighbouring tile or country: load the tiles around the
current position, and for border areas the neighbouring countries' files.

## manifest.json

```json
{
 "format": 1,
 "generated": "2026-11-12",
 "licence": "OpenCelliD, CC BY-SA 4.0",
 "source": "https://opencellid.org",
 "recordBytes": 18,
 "tileDegrees": 10,
 "cells": 99514,
 "bytes": 1019749,
 "stats": {"rows": 111970, "accepted": 99514, "samples": 12456, "...": 0},
 "files": [
  {"name": "250-N50E030.bin.gz", "mcc": 250,
   "tile": {"latMin": 50, "lonMin": 30, "latMax": 60, "lonMax": 40},
   "bbox": {"latMin": 50, "lonMin": 30, "latMax": 60, "lonMax": 40},
   "count": 54753, "bytes": 560686, "sha256": "…"}
 ]
}
```

`tile` is `null` for a whole-country file; `bbox` is always present (same as the header bounds).
`bytes` and `sha256` describe the gzip file as downloaded. `stats` counts rows read, accepted and
rejected by reason, for diagnostics only.

Reference implementation: `read_cells.py` (reader), `convert.py` (writer).
