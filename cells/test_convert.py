#!/usr/bin/env python3
"""Tests for convert.py and read_cells.py: python3 -m unittest test_convert"""
import datetime
import gzip
import hashlib
import json
import os
import random
import shutil
import tempfile
import unittest

import convert
from read_cells import CellFile, HEADER, RECORD

COLS = "radio,mcc,net,area,cell,unit,lon,lat,range,samples,changeable,created,updated,averageSignal"
DATE = datetime.date(2026, 11, 12)


def row(radio, mcc, mnc, area, cell, lon, lat, rng=1000, samples=5):
    return "%s,%d,%d,%d,%d,0,%.6f,%.6f,%d,%d,1,1459681780,1789680443,0" % (
        radio, mcc, mnc, area, cell, lon, lat, rng, samples)


class ConvertTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.out = os.path.join(self.dir, "out")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def write_csv(self, rows, header=True, gz=True):
        path = os.path.join(self.dir, "in.csv.gz" if gz else "in.csv")
        text = "\n".join(([COLS] if header else []) + rows) + "\n"
        if gz:
            with gzip.open(path, "wt") as f:
                f.write(text)
        else:
            with open(path, "w") as f:
                f.write(text)
        return path

    def run_convert(self, rows, **kw):
        kw.setdefault("date", DATE)
        header = kw.pop("header", True)
        return convert.convert(self.write_csv(rows, header=header), self.out, log=lambda *a: None, **kw)

    def test_filters_and_round_trip(self):
        rows = [
            row("LTE", 262, 1, 100, 123456, 13.4, 52.5, 1234, 7),
            row("GSM", 262, 2, 7, 42, 13.41, 52.51, 50, 3),         # range clamped to 100
            row("UMTS", 262, 3, 65535, 268435455, 13.42, 52.52, 50000, 2),
            row("NR", 262, 1, 100, (5 << 32) | 99, 13.43, 52.53, 800, 100),  # NCI > 32 bits
            row("CDMA", 262, 1, 1, 1, 13.4, 52.5),                  # radio
            row("LTE", 262, 1, 1, 2, 13.4, 52.5, 1000, 1),          # one sample
            row("LTE", 262, 1, 1, 3, 13.4, 52.5, 50001, 5),         # range too big
            row("LTE", 262, 1, 1, 4, 0, 0),                         # null island
            row("LTE", 262, 1, 1, 5, 13.4, 95),                     # bad lat
            row("LTE", 262, 1, 70000, 6, 13.4, 52.5),               # area > u16
            "garbage,line",
        ]
        m = self.run_convert(rows)
        self.assertEqual(m["stats"]["accepted"], 4)
        for k in ("radio", "samples", "range", "key", "bad_row"):
            self.assertEqual(m["stats"][k], 1, k)
        self.assertEqual(m["stats"]["position"], 2)
        self.assertEqual([f["name"] for f in m["files"]], ["262.bin.gz"])
        cf = CellFile(os.path.join(self.out, "262.bin.gz"))
        self.assertEqual((cf.mcc, cf.count, cf.created, cf.flags), (262, 4, 20261112, 0))
        r = cf.lookup(1, 100, 123456)
        self.assertEqual(len(r), 1)
        r = r[0]
        self.assertEqual((r["radio"], r["range_m"], r["samples"]), ("LTE", 1250, 7))
        self.assertAlmostEqual(r["lat"], 52.5, places=5)
        self.assertAlmostEqual(r["lon"], 13.4, places=5)
        g = cf.lookup(2, 7, 42)[0]
        self.assertEqual((g["radio"], g["range_m"], g["samples"]), ("GSM", 100, 3))
        u = cf.lookup(3, 65535, 268435455)[0]
        self.assertEqual((u["radio"], u["range_m"]), ("UMTS", 12750))   # clamped to 255 steps
        n = cf.lookup(1, 100, 99, radio="NR")[0]
        self.assertEqual((n["cell"], n["samples"]), (99, 63))
        self.assertEqual(cf.lookup(1, 100, 99, radio="LTE"), [])
        self.assertEqual(cf.lookup(9, 9, 9), [])
        self.assertEqual(cf.info()["bounds"], [52, 13, 53, 14])

    def test_sorting_and_lookup_random(self):
        rnd = random.Random(1)
        keys = set()
        while len(keys) < 3000:
            keys.add((rnd.randint(0, 99), rnd.randint(0, 65535), rnd.randint(0, 2**32 - 1)))
        keys = list(keys)
        rows = [row("LTE", 208, mnc, area, cell, 2 + rnd.random(), 48 + rnd.random()) for mnc, area, cell in keys]
        m = self.run_convert(rows, header=False)
        cf = CellFile(os.path.join(self.out, "208.bin.gz"))
        self.assertEqual(cf.count, 3000)
        ks = [cf.key(i) for i in range(cf.count)]
        self.assertEqual(ks, sorted(keys))
        for k in rnd.sample(keys, 200):
            self.assertEqual(len(cf.lookup(*k)), 1)
        self.assertEqual(m["files"][0]["count"], 3000)

    def test_duplicates_keep_most_samples(self):
        rows = [row("LTE", 208, 1, 2, 3, 2.0, 48.0, 1000, 4),
                row("LTE", 208, 1, 2, 3, 2.5, 48.5, 1000, 40),
                row("GSM", 208, 1, 2, 3, 3.0, 49.0, 1000, 4)]   # same key, other radio: kept
        m = self.run_convert(rows)
        cf = CellFile(os.path.join(self.out, "208.bin.gz"))
        found = cf.lookup(1, 2, 3)
        self.assertEqual(sorted(r["radio"] for r in found), ["GSM", "LTE"])
        lte = [r for r in found if r["radio"] == "LTE"][0]
        self.assertEqual(lte["samples"], 40)
        self.assertAlmostEqual(lte["lat"], 48.5)
        self.assertEqual(m["stats"]["duplicates"], 1)

    def test_tile_split_big_mcc(self):
        rows = [row("LTE", 250, 1, 1, 1, 37.6, 55.7),      # Moscow    N50E030
                row("LTE", 250, 1, 1, 2, 30.3, 59.9),      # St Pete   N50E030
                row("LTE", 250, 1, 2, 1, 82.9, 55.0),      # Novosib.  N50E080
                row("LTE", 250, 1, 3, 1, -179.5, 65.0),    # Chukotka  N60W180
                row("LTE", 250, 1, 4, 1, 179.9, 90.0),     # edge clamped into N80E170
                row("LTE", 208, 1, 1, 1, 2.3, 48.8)]       # France: one file
        m = self.run_convert(rows)
        names = sorted(f["name"] for f in m["files"])
        self.assertEqual(names, ["208.bin.gz", "250-N50E030.bin.gz", "250-N50E080.bin.gz",
                                 "250-N60W180.bin.gz", "250-N80E170.bin.gz"])
        f = {x["name"]: x for x in m["files"]}
        self.assertEqual(f["250-N50E030.bin.gz"]["tile"], {"latMin": 50, "lonMin": 30, "latMax": 60, "lonMax": 40})
        self.assertEqual(f["250-N50E030.bin.gz"]["count"], 2)
        self.assertIsNone(f["208.bin.gz"]["tile"])
        cf = CellFile(os.path.join(self.out, "250-N60W180.bin.gz"))
        self.assertEqual((cf.flags, cf.lat_min, cf.lon_min, cf.lat_max, cf.lon_max), (1, 60, -180, 70, -170))
        self.assertEqual(convert.tile_name(310, (-10, -80)), "310-S10W080.bin.gz")

    def test_split_when_too_big(self):
        rows = [row("LTE", 208, 1, i, i, 2.0 + (i % 2) * 20, 48.0) for i in range(1, 200)]
        m = self.run_convert(rows, max_bytes=200)
        self.assertEqual(sorted(f["name"] for f in m["files"]), ["208-N40E000.bin.gz", "208-N40E020.bin.gz"])
        self.assertFalse(os.path.exists(os.path.join(self.out, "208.bin.gz")))
        self.assertEqual(sum(f["count"] for f in m["files"]), 199)

    def test_mcc_and_limit(self):
        rows = [row("LTE", 208, 1, 1, i, 2.0, 48.0) for i in range(10)] + \
               [row("LTE", 262, 1, 1, i, 13.0, 52.0) for i in range(10)]
        m = self.run_convert(rows, only_mcc=262)
        self.assertEqual([f["name"] for f in m["files"]], ["262.bin.gz"])
        self.assertEqual(m["stats"]["other_mcc"], 10)
        shutil.rmtree(self.out)
        m = self.run_convert(rows, limit=5)
        self.assertEqual(m["stats"]["rows"], 5)
        self.assertEqual(m["cells"], 5)

    def test_manifest(self):
        rows = [row("LTE", 208, 1, 1, 1, 2.3, 48.8), row("GSM", 262, 1, 1, 1, 13.4, 52.5)]
        self.run_convert(rows)
        with open(os.path.join(self.out, "manifest.json")) as f:
            m = json.load(f)
        self.assertEqual(m["generated"], "2026-11-12")
        self.assertEqual(m["licence"], "OpenCelliD, CC BY-SA 4.0")
        self.assertEqual(m["format"], 1)
        self.assertEqual(len(m["files"]), 2)
        for e in m["files"]:
            p = os.path.join(self.out, e["name"])
            with open(p, "rb") as f:
                data = f.read()
            self.assertEqual(e["bytes"], len(data))
            self.assertEqual(e["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(len(gzip.decompress(data)), HEADER.size + e["count"] * RECORD.size)
        self.assertEqual(sorted(os.listdir(self.out)), ["208.bin.gz", "262.bin.gz", "manifest.json"])

    def test_deterministic_output(self):
        rows = [row("LTE", 208, 1, 1, i, 2.0, 48.0) for i in range(50)]
        a = self.run_convert(rows)["files"][0]["sha256"]
        shutil.rmtree(self.out)
        b = self.run_convert(rows)["files"][0]["sha256"]
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main()
