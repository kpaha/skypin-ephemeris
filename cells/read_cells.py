#!/usr/bin/env python3
"""Reference reader for SkyPin cell files (FORMAT.md). Python 3 standard library only.

Usage:
  read_cells.py FILE.bin.gz --info
  read_cells.py FILE.bin.gz --index N            # print record N
  read_cells.py FILE.bin.gz MNC AREA CELL [--radio GSM|UMTS|LTE|NR]
"""
import argparse
import gzip
import struct
import sys

HEADER = struct.Struct(">4sHHHHhhhhIII")
RECORD = struct.Struct(">HHIiiBB")
RADIO_NAMES = ["GSM", "UMTS", "LTE", "NR"]


class CellFile:
    def __init__(self, path):
        with gzip.open(path, "rb") as f:
            self.data = f.read()
        (magic, self.version, self.record_bytes, self.mcc, self.flags, self.lat_min, self.lon_min,
         self.lat_max, self.lon_max, self.count, self.created, _) = HEADER.unpack_from(self.data)
        if magic != b"SKYC":
            raise ValueError("not a SkyPin cell file")
        if self.version != 1 or self.record_bytes != RECORD.size:
            raise ValueError("unsupported version %d / record size %d" % (self.version, self.record_bytes))
        if len(self.data) != HEADER.size + self.count * RECORD.size:
            raise ValueError("size does not match count")

    def key(self, i):
        return struct.unpack_from(">HHI", self.data, HEADER.size + i * RECORD.size)

    def record(self, i):
        mnc, area, cell, lat, lon, r8, meta = RECORD.unpack_from(self.data, HEADER.size + i * RECORD.size)
        return {"mcc": self.mcc, "mnc": mnc, "area": area, "cell": cell,
                "radio": RADIO_NAMES[meta >> 6], "lat": lat / 1e5, "lon": lon / 1e5,
                "range_m": r8 * 50, "samples": meta & 63}

    def lookup(self, mnc, area, cell, radio=None):
        """All records with this key (lower-bound binary search), optionally of one radio."""
        target = (mnc, area, cell & 0xFFFFFFFF)
        lo, hi = 0, self.count
        while lo < hi:
            mid = (lo + hi) // 2
            if self.key(mid) < target:
                lo = mid + 1
            else:
                hi = mid
        out = []
        while lo < self.count and self.key(lo) == target:
            r = self.record(lo)
            if radio is None or r["radio"] == radio:
                out.append(r)
            lo += 1
        return out

    def info(self):
        return {"mcc": self.mcc, "version": self.version, "tiled": bool(self.flags & 1),
                "bounds": [self.lat_min, self.lon_min, self.lat_max, self.lon_max],
                "count": self.count, "created": self.created}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("key", nargs="*", type=int, help="MNC AREA CELL")
    ap.add_argument("--info", action="store_true")
    ap.add_argument("--index", type=int)
    ap.add_argument("--radio", choices=RADIO_NAMES)
    a = ap.parse_args(argv)
    cf = CellFile(a.file)
    if a.info or (a.index is None and not a.key):
        print(cf.info())
    if a.index is not None:
        print(cf.record(a.index))
    if a.key:
        if len(a.key) != 3:
            ap.error("key is MNC AREA CELL")
        found = cf.lookup(*a.key, radio=a.radio)
        for r in found:
            print(r)
        if not found:
            print("not found")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
