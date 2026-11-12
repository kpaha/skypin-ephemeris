#!/usr/bin/env python3
"""Convert an OpenCelliD CSV export into sorted binary cell files for SkyPin.

Streaming and memory-bounded: the CSV is read row by row; accepted rows are packed and spilled
to one temporary file per (MCC, 10x10 degree tile). Memory peaks at the largest single output
group while it is sorted. Python 3 standard library only. Format: see FORMAT.md.

Usage:
  convert.py INPUT.csv.gz OUTDIR [--mcc 250] [--limit N] [--date YYYY-MM-DD] [--max-bytes N]
"""
import argparse
import csv
import datetime
import gzip
import hashlib
import json
import math
import os
import shutil
import struct
import sys
import tempfile

MAGIC = b"SKYC"
VERSION = 1
HEADER = struct.Struct(">4sHHHHhhhhIII")   # 32 bytes, see FORMAT.md
RECORD = struct.Struct(">HHIiiBB")         # 18 bytes
SPILL = struct.Struct(">HHIBiiBI")         # 22 bytes: key + radio first, so raw-byte sort = key sort
assert HEADER.size == 32 and RECORD.size == 18 and SPILL.size == 22

RADIOS = {"GSM": 0, "UMTS": 1, "LTE": 2, "NR": 3}
BIG_MCCS = {250, 310, 311, 312, 313, 314, 315, 316, 460, 724, 404, 405, 302, 505}
TILE = 10                       # degrees
MAX_FILE_BYTES = 10_000_000     # gzip output above this -> split the MCC into tiles
MIN_SAMPLES = 2
MIN_RANGE, MAX_RANGE = 100, 50_000
LICENCE = "OpenCelliD, CC BY-SA 4.0"
FLAG_TILED = 1
SPILL_FLUSH_BYTES = 64 << 20


def tile_of(lat, lon):
    """South-west corner of the 10x10 degree tile containing the point (integer degrees)."""
    tlat = min(int(math.floor(lat / TILE)) * TILE, 90 - TILE)
    tlon = min(int(math.floor(lon / TILE)) * TILE, 180 - TILE)
    return tlat, tlon


def tile_name(mcc, tile):
    if tile is None:
        return "%d.bin.gz" % mcc
    tlat, tlon = tile
    return "%d-%s%02d%s%03d.bin.gz" % (mcc, "N" if tlat >= 0 else "S", abs(tlat),
                                       "E" if tlon >= 0 else "W", abs(tlon))


def parse_row(row, stats):
    """Returns (mcc, spill_bytes, lat, lon) or None. Counts rejections in stats."""
    if len(row) < 10:
        stats["bad_row"] += 1
        return None
    radio = RADIOS.get(row[0].strip().upper())
    if radio is None:
        stats["radio"] += 1
        return None
    try:
        mcc = int(row[1]); mnc = int(row[2]); area = int(row[3]); cell = int(row[4])
        lon = float(row[6]); lat = float(row[7])
        rng = float(row[8]); samples = int(row[9])
    except ValueError:
        stats["bad_row"] += 1
        return None
    if samples < MIN_SAMPLES:
        stats["samples"] += 1
        return None
    if not (rng <= MAX_RANGE):          # also rejects NaN
        stats["range"] += 1
        return None
    rng = max(rng, MIN_RANGE)
    if not (math.isfinite(lat) and math.isfinite(lon) and -90 <= lat <= 90 and -180 <= lon <= 180) \
            or (lat == 0 and lon == 0):
        stats["position"] += 1
        return None
    if not (0 <= mcc <= 999 and 0 <= mnc <= 0xFFFF and 0 <= area <= 0xFFFF and cell >= 0):
        stats["key"] += 1
        return None
    if radio != RADIOS["NR"] and cell > 0xFFFFFFFF:
        stats["key"] += 1
        return None
    cell &= 0xFFFFFFFF                   # NR: low 32 bits of the 36-bit NCI
    ilat = int(round(lat * 1e5)); ilon = int(round(lon * 1e5))
    r8 = min(255, int(round(rng / 50.0)))
    rec = SPILL.pack(mnc, area, cell, radio, ilat, ilon, r8, min(samples, 0xFFFFFFFF))
    return mcc, rec, lat, lon


def iter_rows(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8", errors="replace", newline="") as f:
        for i, row in enumerate(csv.reader(f)):
            if i == 0 and row and row[0].strip().lower() == "radio":
                continue                 # header line (full export has one, per-MCC files do not)
            yield row


class Spiller:
    """Buffers packed records per (mcc, tile) and appends them to temp files."""

    def __init__(self, tmpdir):
        self.tmpdir = tmpdir
        self.buf = {}
        self.buffered = 0
        self.counts = {}

    def path(self, mcc, tile):
        return os.path.join(self.tmpdir, "%d_%d_%d.spill" % (mcc, tile[0], tile[1]))

    def add(self, mcc, tile, rec):
        key = (mcc, tile)
        b = self.buf.get(key)
        if b is None:
            b = self.buf[key] = bytearray()
        b += rec
        self.buffered += len(rec)
        self.counts[key] = self.counts.get(key, 0) + 1
        if self.buffered >= SPILL_FLUSH_BYTES:
            self.flush()

    def flush(self):
        for (mcc, tile), b in self.buf.items():
            with open(self.path(mcc, tile), "ab") as f:
                f.write(b)
        self.buf.clear()
        self.buffered = 0

    def read(self, mcc, tile):
        with open(self.path(mcc, tile), "rb") as f:
            return f.read()


def dedup_sorted(spill_blobs):
    """Sorts spill records and keeps, per (mnc, area, cell, radio), the one with most samples.
    Returns a list of final 18-byte records in key order and the number of duplicates dropped."""
    recs = []
    for blob in spill_blobs:
        recs.extend(blob[i:i + SPILL.size] for i in range(0, len(blob), SPILL.size))
    recs.sort()
    out = []
    dups = 0
    prev_key = None
    best = None
    for r in recs:
        k = r[:9]
        if k == prev_key:
            dups += 1
            if SPILL.unpack(r)[7] > SPILL.unpack(best)[7]:
                best = r
            continue
        if best is not None:
            out.append(final_record(best))
        prev_key, best = k, r
    if best is not None:
        out.append(final_record(best))
    return out, dups


def final_record(spill):
    mnc, area, cell, radio, ilat, ilon, r8, samples = SPILL.unpack(spill)
    return RECORD.pack(mnc, area, cell, ilat, ilon, r8, (radio << 6) | min(samples, 63))


def bounds_of(records):
    lats = [RECORD.unpack_from(r)[3] for r in records]
    lons = [RECORD.unpack_from(r)[4] for r in records]
    return (int(math.floor(min(lats) / 1e5)), int(math.floor(min(lons) / 1e5)),
            int(math.ceil(max(lats) / 1e5)), int(math.ceil(max(lons) / 1e5)))


def write_file(outdir, mcc, tile, records, created):
    """Writes one gzip file; returns its manifest entry."""
    name = tile_name(mcc, tile)
    if tile is None:
        flags = 0
        lat0, lon0, lat1, lon1 = bounds_of(records)
    else:
        flags = FLAG_TILED
        lat0, lon0 = tile
        lat1, lon1 = lat0 + TILE, lon0 + TILE
    header = HEADER.pack(MAGIC, VERSION, RECORD.size, mcc, flags, lat0, lon0, lat1, lon1,
                         len(records), created, 0)
    path = os.path.join(outdir, name)
    with open(path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as gz:
            gz.write(header)
            for i in range(0, len(records), 65536):
                gz.write(b"".join(records[i:i + 65536]))
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return {
        "name": name,
        "mcc": mcc,
        "tile": None if tile is None else {"latMin": lat0, "lonMin": lon0, "latMax": lat1, "lonMax": lon1},
        "bbox": {"latMin": lat0, "lonMin": lon0, "latMax": lat1, "lonMax": lon1},
        "count": len(records),
        "bytes": os.path.getsize(path),
        "sha256": h.hexdigest(),
    }


def convert(input_path, outdir, only_mcc=None, limit=None, date=None, max_bytes=MAX_FILE_BYTES,
            log=print):
    os.makedirs(outdir, exist_ok=True)
    date = date or datetime.datetime.now(datetime.timezone.utc).date()
    created = date.year * 10000 + date.month * 100 + date.day
    stats = {"rows": 0, "accepted": 0, "radio": 0, "samples": 0, "range": 0, "position": 0,
             "key": 0, "bad_row": 0, "other_mcc": 0, "duplicates": 0}
    tmpdir = tempfile.mkdtemp(prefix="cells-spill-", dir=outdir)
    try:
        sp = Spiller(tmpdir)
        for row in iter_rows(input_path):
            if limit is not None and stats["rows"] >= limit:
                break
            stats["rows"] += 1
            p = parse_row(row, stats)
            if p is None:
                continue
            mcc, rec, lat, lon = p
            if only_mcc is not None and mcc != only_mcc:
                stats["other_mcc"] += 1
                continue
            stats["accepted"] += 1
            sp.add(mcc, tile_of(lat, lon), rec)
            if stats["rows"] % 5_000_000 == 0:
                log("  read %d rows, accepted %d" % (stats["rows"], stats["accepted"]))
        sp.flush()
        log("read %d rows, accepted %d" % (stats["rows"], stats["accepted"]))

        files = []
        by_mcc = {}
        for (mcc, tile) in sp.counts:
            by_mcc.setdefault(mcc, []).append(tile)
        for mcc in sorted(by_mcc):
            tiles = sorted(by_mcc[mcc])
            entries = None
            if mcc not in BIG_MCCS:
                recs, dups = dedup_sorted(sp.read(mcc, t) for t in tiles)
                entry = write_file(outdir, mcc, None, recs, created)
                del recs
                if entry["bytes"] <= max_bytes:
                    entries = [entry]
                    stats["duplicates"] += dups
                else:
                    log("  MCC %d: %d bytes > %d, splitting into tiles" % (mcc, entry["bytes"], max_bytes))
                    os.remove(os.path.join(outdir, entry["name"]))
            if entries is None:
                entries = []
                for t in tiles:
                    recs, dups = dedup_sorted([sp.read(mcc, t)])
                    stats["duplicates"] += dups
                    entries.append(write_file(outdir, mcc, t, recs, created))
            for e in entries:
                log("  %-22s %9d cells %11d bytes" % (e["name"], e["count"], e["bytes"]))
                if e["bytes"] > max_bytes:
                    log("  warning: %s is above %d bytes" % (e["name"], max_bytes))
            files.extend(entries)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    manifest = {
        "format": VERSION,
        "generated": date.isoformat(),
        "licence": LICENCE,
        "source": "https://opencellid.org",
        "recordBytes": RECORD.size,
        "tileDegrees": TILE,
        "cells": sum(f["count"] for f in files),
        "bytes": sum(f["bytes"] for f in files),
        "stats": stats,
        "files": files,
    }
    with open(os.path.join(outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")
    log("wrote %d files, %d cells, %d bytes; rejected: %s" % (
        len(files), manifest["cells"], manifest["bytes"],
        ", ".join("%s %d" % (k, v) for k, v in stats.items() if k not in ("rows", "accepted"))))
    return manifest


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="OpenCelliD CSV, .csv or .csv.gz")
    ap.add_argument("outdir")
    ap.add_argument("--mcc", type=int, help="keep only this MCC (for a per-MCC download)")
    ap.add_argument("--limit", type=int, help="read at most N rows (tests)")
    ap.add_argument("--date", type=datetime.date.fromisoformat, help="created date, default today UTC")
    ap.add_argument("--max-bytes", type=int, default=MAX_FILE_BYTES,
                    help="split an MCC into tiles when its file is larger (default 10 MB)")
    a = ap.parse_args(argv)
    m = convert(a.input, a.outdir, a.mcc, a.limit, a.date, a.max_bytes)
    if not m["files"]:
        print("no cells accepted", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
