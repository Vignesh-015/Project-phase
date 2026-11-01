"""
Offline MTC Transit Graph Compiler
Parses GTFS-like data in mtc/ (stops.txt, stop_times.txt) and compiles an indexed,
pruned transit network graph to backend/data/mtc_network_graph.json.
"""

import os
import json
import math
import time
import pandas as pd

EARTH_RADIUS_M = 6371000.0
BUS_SPEED_MPS = 18.0 / 3.6  # 18 km/h = 5.0 m/s
STOP_DWELL_SEC = 30.0
MAX_LINK_DIST_M = 3500.0    # 3.5 km teleportation filter
MIN_FREQUENCY = 3           # Edge frequency >= 3 trips/day


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2.0) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dl / 2.0) ** 2
    return 2.0 * EARTH_RADIUS_M * math.asin(math.sqrt(max(0.0, min(1.0, a))))


def compile_mtc_graph():
    start_time = time.time()
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    stops_file = os.path.join(base_dir, "mtc", "stops.txt")
    stop_times_file = os.path.join(base_dir, "mtc", "stop_times.txt")
    output_dir = os.path.join(base_dir, "backend", "data")
    output_file = os.path.join(output_dir, "mtc_network_graph.json")

    os.makedirs(output_dir, exist_ok=True)

    print(f"Loading stops from {stops_file}...")
    stops_df = pd.read_csv(stops_file)
    raw_stops = {}
    for _, row in stops_df.iterrows():
        sid_str = str(int(row["stop_id"]))
        node_id = f"MTC_{sid_str}"
        raw_stops[node_id] = {
            "name": str(row["stop_name"]).strip(),
            "lat": round(float(row["stop_lat"]), 6),
            "lon": round(float(row["stop_lon"]), 6)
        }
    print(f"Loaded {len(raw_stops)} stops.")

    print(f"Reading stop_times from {stop_times_file}...")
    st_df = pd.read_csv(stop_times_file, usecols=["trip_id", "stop_id", "stop_sequence"])
    print(f"Loaded {len(st_df)} stop_times records. Sorting by trip_id, stop_sequence...")

    st_df.sort_values(by=["trip_id", "stop_sequence"], inplace=True)

    # Shift by 1 to get consecutive directed stop pairs (u, v) per trip
    st_df["next_trip"] = st_df["trip_id"].shift(-1)
    st_df["next_stop"] = st_df["stop_id"].shift(-1)

    consecutive = st_df[st_df["trip_id"] == st_df["next_trip"]]
    print(f"Extracted {len(consecutive)} consecutive segment records. Aggregating edge frequencies...")

    edge_counts = consecutive.groupby(["stop_id", "next_stop"]).size().reset_index(name="frequency")
    print(f"Found {len(edge_counts)} unique directed edges.")

    compiled_edges = []
    active_stop_ids = set()

    for _, row in edge_counts.iterrows():
        freq = int(row["frequency"])
        if freq < MIN_FREQUENCY:
            continue

        u_id = f"MTC_{int(row['stop_id'])}"
        v_id = f"MTC_{int(row['next_stop'])}"

        if u_id not in raw_stops or v_id not in raw_stops:
            continue

        u_data = raw_stops[u_id]
        v_data = raw_stops[v_id]

        dist_m = haversine_m(u_data["lat"], u_data["lon"], v_data["lat"], v_data["lon"])

        # Filter teleportation / bad coordinates or self-loops
        if dist_m > MAX_LINK_DIST_M or dist_m < 5.0:
            continue

        time_sec = round((dist_m / BUS_SPEED_MPS) + STOP_DWELL_SEC, 1)

        compiled_edges.append({
            "from": u_id,
            "to": v_id,
            "dist_m": round(dist_m, 1),
            "time_sec": time_sec,
            "frequency": freq,
            "mode": "MTC_BUS"
        })
        active_stop_ids.add(u_id)
        active_stop_ids.add(v_id)

    # Filter stops dictionary to include only active stops connected in the graph
    active_stops = {sid: raw_stops[sid] for sid in active_stop_ids}

    compiled_graph = {
        "stops": active_stops,
        "edges": compiled_edges
    }

    print(f"Compiled graph contains {len(active_stops)} active stops and {len(compiled_edges)} edges.")
    print(f"Writing to {output_file}...")

    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(compiled_graph, f, separators=(",", ":"))

    file_size_mb = os.path.getsize(output_file) / (1024 * 1024)
    elapsed = time.time() - start_time
    print(f"Compilation finished successfully in {elapsed:.2f}s!")
    print(f"Output file size: {file_size_mb:.2f} MB")


if __name__ == "__main__":
    compile_mtc_graph()
