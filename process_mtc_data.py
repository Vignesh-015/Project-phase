"""
MTC GTFS Data Pre-Processor for FlexiTransit-AI
================================================
Reads the raw GTFS files from the mtc/ folder and generates compact
JSON assets for the Flutter app:

  flexi_transit/assets/data/mtc_stops.json        – All stops with lat/lon
  flexi_transit/assets/data/mtc_routes.json       – Route metadata
  flexi_transit/assets/data/mtc_stop_routes.json  – stop_id -> route short names

Usage:
  python process_mtc_data.py
"""

import csv
import json
import os
import sys
from collections import defaultdict

# ─── Paths ────────────────────────────────────────────────────────────────────
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MTC_DIR  = os.path.join(BASE_DIR, "mtc")
OUT_DIR  = os.path.join(BASE_DIR, "flexi_transit", "assets", "data")

ROUTES_FILE    = os.path.join(MTC_DIR, "routes.txt")
STOPS_FILE     = os.path.join(MTC_DIR, "stops.txt")
STOP_TIMES_FILE = os.path.join(MTC_DIR, "stop_times.txt")

os.makedirs(OUT_DIR, exist_ok=True)

# ─── 1. Load Routes ────────────────────────────────────────────────────────────
print("Loading routes.txt ...")
routes = {}          # route_id -> {short_name, long_name}
trip_to_route = {}   # trip_id -> route_id  (built from stop_times trip_ids via routes)

# In this GTFS there is no trips.txt; route_id IS the trip_id (or close enough).
# We'll build trip->route mapping from stop_times + routes.
with open(ROUTES_FILE, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        rid = row["route_id"].strip()
        routes[rid] = {
            "route_id":   rid,
            "short_name": row["route_short_name"].strip(),
            "long_name":  row["route_long_name"].strip(),
        }

print(f"  Loaded {len(routes)} routes.")

# ─── 2. Load Stops ────────────────────────────────────────────────────────────
print("Loading stops.txt ...")
stops = {}  # stop_id -> {stop_id, stop_name, lat, lon}
with open(STOPS_FILE, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        sid = row["stop_id"].strip()
        try:
            lat = float(row["stop_lat"])
            lon = float(row["stop_lon"])
        except ValueError:
            continue
        stops[sid] = {
            "stop_id":   sid,
            "stop_name": row["stop_name"].strip(),
            "lat":       round(lat, 6),
            "lon":       round(lon, 6),
        }

print(f"  Loaded {len(stops)} stops.")

# ─── 3. Build stop -> route mapping via stop_times ────────────────────────────
print("Processing stop_times.txt (this may take a moment) ...")

# Since there's no trips.txt mapping trip_id -> route_id in this dataset,
# We treat trip_id as route_id directly (the numeric IDs appear in routes.txt as route_id).
# Actually trip_id from stop_times is a separate sequence, so we need a heuristic:
# Build unique trip_ids from stop_times, then match to routes by order (this dataset 
# uses sequential trip ids that don't directly correspond to route_ids).
#
# Better approach: since trips.txt is absent, we use a simplified mapping:
# Collect all trip_ids from stop_times and all route_ids from routes.
# The stop_times trip_ids are sequential integers that are internal trip keys.
# We DON'T have a trips.txt to map them, so we generate APPROXIMATE data:
# For each stop, we record which *route names* are near it using a stop-name
# fuzzy match against route long_names. This is imperfect but workable for the UI.
#
# ACTUAL APPROACH: Build a trip_id->route_id lookup by checking if trip_id 
# is numerically close to route_ids. The routes.txt route_id values are integers 
# in the 3000–24000 range. The stop_times trip_ids are 2073–2106 etc, which don't 
# match. So instead, we simply collect unique stop_ids from stop_times to confirm 
# they exist, and for each stop record dummy route counts.
#
# THE REAL INTEGRATION: We'll parse stop_times to build a 
# trip_id -> [stop_ids] map, then since we know routes.txt has route_id,
# we build a stop_id -> set(trip_ids) map. In the Flutter app we show stop name
# and the fact that routes pass through.

stop_trip_count = defaultdict(int)   # stop_id -> number of distinct trips
stop_first_arrivals = defaultdict(list)  # stop_id -> first few arrival times

total_lines = 0
SAMPLE_SIZE = 5  # store up to 5 arrival times per stop

with open(STOP_TIMES_FILE, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        total_lines += 1
        sid = row["stop_id"].strip()
        if sid in stops:
            stop_trip_count[sid] += 1
            if len(stop_first_arrivals[sid]) < SAMPLE_SIZE:
                stop_first_arrivals[sid].append(row["arrival_time"].strip())
        if total_lines % 200_000 == 0:
            print(f"  ... processed {total_lines:,} rows")

print(f"  Processed {total_lines:,} stop_time rows.")
print(f"  Stops with service: {len(stop_trip_count)}")

# ─── 4. Also parse stop_times to get trip_id -> stop sequence, 
#        then build route short names per stop.
#
# Since trips.txt is missing, we identify routes per stop differently:
# We scan routes.txt long_name for stop name substrings. This is a heuristic
# that works for Chennai MTC data where long_names contain actual stop names.
print("Building stop->route name mapping (heuristic) ...")

# Build a quick lookup: stop_name (lowercase) -> stop_id
stop_name_to_id = {}
for sid, s in stops.items():
    key = s["stop_name"].lower().strip()
    stop_name_to_id[key] = sid

# For each route, check if any stop name appears in the long_name
stop_routes_map = defaultdict(set)  # stop_id -> set of route short_names

for rid, r in routes.items():
    long_name_lower = r["long_name"].lower()
    for stop_name_lower, sid in stop_name_to_id.items():
        # Only match if the stop name is meaningfully long (>4 chars) to avoid false matches
        if len(stop_name_lower) > 4 and stop_name_lower in long_name_lower:
            stop_routes_map[sid].add(r["short_name"])

# For stops with NO route match, assign a generic "MTC Bus" label if they have service
for sid in stop_trip_count:
    if sid not in stop_routes_map:
        stop_routes_map[sid].add("MTC")

print(f"  Stops with route assignments: {len(stop_routes_map)}")

# ─── 5. Write Output Files ─────────────────────────────────────────────────────

# 5a. mtc_stops.json
print("Writing mtc_stops.json ...")
stops_list = []
for sid, s in stops.items():
    entry = {
        "id":   s["stop_id"],
        "name": s["stop_name"],
        "lat":  s["lat"],
        "lon":  s["lon"],
    }
    # Add service frequency data
    trip_count = stop_trip_count.get(sid, 0)
    entry["trips"] = trip_count
    # Estimate frequency: if > 50 trips per day -> high frequency
    if trip_count > 100:
        entry["freq"] = "high"
    elif trip_count > 20:
        entry["freq"] = "medium"
    else:
        entry["freq"] = "low"
    
    stops_list.append(entry)

# Sort by lat for slightly better spatial access
stops_list.sort(key=lambda x: x["lat"])

stops_path = os.path.join(OUT_DIR, "mtc_stops.json")
with open(stops_path, "w", encoding="utf-8") as f:
    json.dump(stops_list, f, ensure_ascii=False, separators=(",", ":"))
size_kb = os.path.getsize(stops_path) / 1024
print(f"  Written: {stops_path} ({size_kb:.1f} KB, {len(stops_list)} stops)")

# 5b. mtc_routes.json
print("Writing mtc_routes.json ...")
routes_list = list(routes.values())
routes_path = os.path.join(OUT_DIR, "mtc_routes.json")
with open(routes_path, "w", encoding="utf-8") as f:
    json.dump(routes_list, f, ensure_ascii=False, separators=(",", ":"))
size_kb = os.path.getsize(routes_path) / 1024
print(f"  Written: {routes_path} ({size_kb:.1f} KB, {len(routes_list)} routes)")

# 5c. mtc_stop_routes.json  — stop_id -> list of route short_names
print("Writing mtc_stop_routes.json ...")
stop_routes_dict = {
    sid: sorted(list(route_set))
    for sid, route_set in stop_routes_map.items()
}
stop_routes_path = os.path.join(OUT_DIR, "mtc_stop_routes.json")
with open(stop_routes_path, "w", encoding="utf-8") as f:
    json.dump(stop_routes_dict, f, ensure_ascii=False, separators=(",", ":"))
size_kb = os.path.getsize(stop_routes_path) / 1024
print(f"  Written: {stop_routes_path} ({size_kb:.1f} KB)")

print()
print("[OK] MTC data pre-processing complete!")
print(f"   Output directory: {OUT_DIR}")
print()
print("Next steps:")
print("  1. Verify the JSON files look correct")
print("  2. Run `flutter pub get` in the Flutter project")
print("  3. Hot-restart the app to see MTC stops on the map")
