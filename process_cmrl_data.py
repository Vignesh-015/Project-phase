"""
CMRL GTFS Data Pre-Processor for FlexiTransit-AI
================================================
Reads the raw GTFS files from the cmrl/ folder and generates compact
JSON assets for the Flutter app:

  flexi_transit/assets/data/cmrl_stops.json   – CMRL Metro stations with lines, coords, interchange flag
  flexi_transit/assets/data/cmrl_shapes.json  – Blue & Green line polylines

Usage:
  python process_cmrl_data.py
"""

import csv
import json
import os
import sys

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CMRL_DIR = os.path.join(BASE_DIR, "cmrl")
OUT_DIR  = os.path.join(BASE_DIR, "flexi_transit", "assets", "data")

STOPS_FILE  = os.path.join(CMRL_DIR, "stops.txt")
SHAPES_FILE = os.path.join(CMRL_DIR, "shapes.txt")
ROUTES_FILE = os.path.join(CMRL_DIR, "routes.txt")

os.makedirs(OUT_DIR, exist_ok=True)

print("Loading CMRL GTFS data...")

# ─── 1. Process Stops ─────────────────────────────────────────────────────────
raw_stops = []
with open(STOPS_FILE, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        sid = row["stop_id"].strip()
        name = row["stop_name"].strip()
        try:
            lat = float(row["stop_lat"])
            lon = float(row["stop_lon"])
        except ValueError:
            continue

        # Determine line
        if sid.startswith("CMRL_G"):
            line_name = "Green Line"
            color_hex = "#00E676"  # Emerald Green
        elif sid.startswith("CMRL_"):
            line_name = "Blue Line"
            color_hex = "#00B0FF"  # Cyan / Blue
        else:
            line_name = "CMRL Metro"
            color_hex = "#2563EB"

        raw_stops.append({
            "id": sid,
            "name": name,
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "line": line_name,
            "color": color_hex,
        })

# Group stops by name to detect interchange stations (like Alandur or Central)
name_counts = {}
for s in raw_stops:
    norm_name = s["name"].lower()
    name_counts[norm_name] = name_counts.get(norm_name, 0) + 1

cmrl_stops = []
seen_ids = set()

for s in raw_stops:
    if s["id"] in seen_ids:
        continue
    seen_ids.add(s["id"])

    norm_name = s["name"].lower()
    is_interchange = name_counts[norm_name] > 1 or "central" in norm_name or "alandur" in norm_name

    cmrl_stops.append({
        "id": s["id"],
        "name": s["name"],
        "lat": s["lat"],
        "lon": s["lon"],
        "line": s["line"],
        "color": "#FFD700" if is_interchange else s["color"],
        "interchange": is_interchange,
        "peak_freq_min": 6,
        "first_train": "05:00",
        "last_train": "23:00",
    })

print(f"  Loaded {len(cmrl_stops)} CMRL Metro stations.")

# ─── 2. Process Shapes (Line Polylines) ────────────────────────────────────────
shapes_dict = {}
with open(SHAPES_FILE, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        shape_id = row["shape_id"].strip()
        seq = int(row["shape_pt_sequence"])
        lat = float(row["shape_pt_lat"])
        lon = float(row["shape_pt_lon"])

        if shape_id not in shapes_dict:
            shapes_dict[shape_id] = []
        shapes_dict[shape_id].append((seq, round(lat, 6), round(lon, 6)))

cmrl_shapes = []

# Map shape_id to human readable line names
line_metadata = {
    "CMRL_1_0": {"name": "Blue Line (Depot → Airport)", "color": "#00B0FF"},
    "CMRL_1_1": {"name": "Blue Line (Airport → Depot)", "color": "#00B0FF"},
    "CMRL_2_0": {"name": "Green Line (Central → St. Thomas Mount)", "color": "#00E676"},
    "CMRL_2_1": {"name": "Green Line (St. Thomas Mount → Central)", "color": "#00E676"},
}

for shape_id, pts in shapes_dict.items():
    pts.sort(key=lambda p: p[0])
    coords = [[p[1], p[2]] for p in pts]
    meta = line_metadata.get(shape_id, {"name": shape_id, "color": "#00B0FF"})
    cmrl_shapes.append({
        "shape_id": shape_id,
        "name": meta["name"],
        "color": meta["color"],
        "polyline": coords
    })

print(f"  Loaded {len(cmrl_shapes)} CMRL Metro line shapes.")

# ─── 3. Save JSON Assets ──────────────────────────────────────────────────────
stops_path = os.path.join(OUT_DIR, "cmrl_stops.json")
with open(stops_path, "w", encoding="utf-8") as f:
    json.dump(cmrl_stops, f, ensure_ascii=False, indent=2)

shapes_path = os.path.join(OUT_DIR, "cmrl_shapes.json")
with open(shapes_path, "w", encoding="utf-8") as f:
    json.dump(cmrl_shapes, f, ensure_ascii=False, indent=2)

print(f"[OK] CMRL data saved to {OUT_DIR}")
