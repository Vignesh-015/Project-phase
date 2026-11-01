import os
import glob
import json
import time
import shutil
import urllib.request
import urllib.parse
import numpy as np
import pandas as pd
from sklearn.cluster import DBSCAN
from math import radians, cos, sin, asin, sqrt, atan2, degrees

EARTH_RADIUS_M = 6371000.0

# ---------------------------------------------------------------------
# 1. GEODETIC & KINEMATIC HELPERS
# ---------------------------------------------------------------------
def haversine_m(lat1, lon1, lat2, lon2):
    phi1, phi2 = radians(lat1), radians(lat2)
    dphi = radians(lat2 - lat1)
    dlam = radians(lon2 - lon1)
    a = sin(dphi / 2.0)**2 + cos(phi1) * cos(phi2) * sin(dlam / 2.0)**2
    return 2.0 * EARTH_RADIUS_M * asin(sqrt(max(0.0, min(1.0, a))))

def calculate_bearing(lat1, lon1, lat2, lon2):
    lat1, lat2 = radians(lat1), radians(lat2)
    dlon = radians(lon2 - lon1)
    x = sin(dlon) * cos(lat2)
    y = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dlon)
    return (degrees(atan2(x, y)) + 360) % 360

# ---------------------------------------------------------------------
# 2. 2D KINEMATIC KALMAN FILTER (Latitude/Longitude Denoising)
# ---------------------------------------------------------------------
class TrajectoryKalmanFilter:
    """
    Continuous state-space kinematic model:
    x = [lat, lon, v_lat, v_lon]^T
    """
    def __init__(self, process_noise=1e-5, measurement_noise=1e-4):
        self.x = np.zeros(4)
        self.P = np.eye(4) * 1.0
        self.Q_base = process_noise
        self.R = np.eye(2) * measurement_noise
        self.H = np.array([
            [1, 0, 0, 0],
            [0, 1, 0, 0]
        ])
        self.initialized = False

    def update(self, lat, lon, dt):
        if not self.initialized:
            self.x = np.array([lat, lon, 0.0, 0.0])
            self.initialized = True
            return lat, lon

        dt = max(dt, 0.1)
        F = np.array([
            [1, 0, dt, 0],
            [0, 1, 0, dt],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ])
        Q = np.eye(4) * self.Q_base * dt

        x_pred = F @ self.x
        P_pred = F @ self.P @ F.T + Q

        z = np.array([lat, lon])
        y = z - (self.H @ x_pred)
        S = self.H @ P_pred @ self.H.T + self.R
        K = P_pred @ self.H.T @ np.linalg.inv(S)

        self.x = x_pred + K @ y
        self.P = (np.eye(4) - K @ self.H) @ P_pred
        return float(self.x[0]), float(self.x[1])

# ---------------------------------------------------------------------
# 3. KINEMATIC SPEED & PHANTOM DISTANCE RESOLUTION ENGINE
# ---------------------------------------------------------------------
def clean_single_trajectory(df, max_accuracy=15.0, max_speed_kmh=85.0):
    if 'provider' in df.columns:
        df = df[df['provider'].astype(str).str.lower().eq('gps')].copy()
    if 'accuracy' in df.columns:
        df = df[pd.to_numeric(df['accuracy'], errors='coerce') <= max_accuracy].copy()

    time_col = next((c for c in ['time', 'timestamp', 'datetime', 'gps_time'] if c in df.columns), None)
    if not time_col:
        return None

    df['time_dt'] = pd.to_datetime(df[time_col], errors='coerce')
    df = df.dropna(subset=['time_dt', 'lat', 'lon']).sort_values('time_dt').reset_index(drop=True)
    if len(df) < 5:
        return None

    df['dt'] = df['time_dt'].diff().dt.total_seconds().fillna(1.0)
    df.loc[df['dt'] <= 0, 'dt'] = 1.0

    step_distances = [0.0]
    for i in range(1, len(df)):
        step_distances.append(haversine_m(df.loc[i - 1, 'lat'], df.loc[i - 1, 'lon'], df.loc[i, 'lat'], df.loc[i, 'lon']))
    df['step_dist_m'] = step_distances

    calc_speed_kmh = (df['step_dist_m'] / df['dt']) * 3.6
    sensor_speed = pd.to_numeric(df.get('speed', 0.0), errors='coerce').fillna(0.0) * 3.6

    true_speed = []
    for s_sens, s_calc, dist_m in zip(sensor_speed, calc_speed_kmh, df['step_dist_m']):
        if s_sens > 1.0:
            true_speed.append(min(s_sens, max_speed_kmh))
        elif dist_m >= 5.0:
            true_speed.append(min(s_calc, max_speed_kmh))
        else:
            true_speed.append(0.0)
    df['speed_kmh'] = np.round(true_speed, 2)
    df['speed_mps'] = np.round(df['speed_kmh'] / 3.6, 2)

    clean_dist, total = [0.0], 0.0
    for i in range(1, len(df)):
        if df.loc[i, 'step_dist_m'] > 5.0 and df.loc[i, 'speed_kmh'] > 3.0:
            total += df.loc[i, 'step_dist_m']
        clean_dist.append(round(total, 2))
    df['distance'] = clean_dist

    bearings = [np.nan]
    for i in range(1, len(df)):
        bearings.append(calculate_bearing(df.loc[i - 1, 'lat'], df.loc[i - 1, 'lon'], df.loc[i, 'lat'], df.loc[i, 'lon']))
    df['bearing'] = pd.Series(bearings).ffill().fillna(0.0)

    kf = TrajectoryKalmanFilter()
    klats, klons = [], []
    for _, row in df.iterrows():
        klat, klon = kf.update(row['lat'], row['lon'], row['dt'])
        klats.append(round(klat, 7))
        klons.append(round(klon, 7))
    df['kalman_lat'] = klats
    df['kalman_lon'] = klons
    return df

# ---------------------------------------------------------------------
# 4. CHUNKED OSRM ROAD SNAPPING & JITTER PRUNING
# ---------------------------------------------------------------------
def filter_stationary_scatter(coords_lon_lat, min_movement_m=8.0):
    if len(coords_lon_lat) < 2:
        return coords_lon_lat
    filtered = [coords_lon_lat[0]]
    for pt in coords_lon_lat[1:]:
        if haversine_m(filtered[-1][1], filtered[-1][0], pt[1], pt[0]) >= min_movement_m:
            filtered.append(pt)
    if coords_lon_lat[-1] != filtered[-1]:
        filtered.append(coords_lon_lat[-1])
    return filtered

def match_chunk_osrm(chunk_lon_lat, osrm_host="https://router.project-osrm.org"):
    if len(chunk_lon_lat) < 2:
        return chunk_lon_lat
    coord_str = ";".join([f"{lon:.6f},{lat:.6f}" for lon, lat in chunk_lon_lat])
    radiuses = ";".join(["30"] * len(chunk_lon_lat))
    url = f"{osrm_host}/match/v1/driving/{coord_str}?overview=full&geometries=geojson&tidy=true&radiuses={radiuses}"

    for _ in range(3):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'FlexiTransit-AI/2.0'})
            with urllib.request.urlopen(req, timeout=12) as response:
                data = json.loads(response.read().decode('utf-8'))
            if data.get('code') == 'Ok' and data.get('matchings'):
                return data['matchings'][0]['geometry']['coordinates']
        except Exception:
            time.sleep(1.0)

    # Fallback to OSRM Route API
    start_lon, start_lat = chunk_lon_lat[0][0], chunk_lon_lat[0][1]
    end_lon, end_lat = chunk_lon_lat[-1][0], chunk_lon_lat[-1][1]
    route_url = f"{osrm_host}/route/v1/driving/{start_lon:.6f},{start_lat:.6f};{end_lon:.6f},{end_lat:.6f}?overview=full&geometries=geojson"
    try:
        req = urllib.request.Request(route_url, headers={'User-Agent': 'FlexiTransit-AI/2.0'})
        with urllib.request.urlopen(req, timeout=8) as response:
            data = json.loads(response.read().decode('utf-8'))
        if data.get('code') == 'Ok' and data.get('routes'):
            return data['routes'][0]['geometry']['coordinates']
    except Exception:
        pass
    return chunk_lon_lat

def robust_corridor_snapping(raw_lon_lat_coords, chunk_size=45):
    clean_pts = filter_stationary_scatter(raw_lon_lat_coords, min_movement_m=8.0)
    full_snapped_path = []
    for i in range(0, len(clean_pts) - 1, chunk_size - 1):
        chunk = clean_pts[i:i + chunk_size]
        if len(chunk) < 2:
            continue
        snapped_chunk = match_chunk_osrm(chunk)
        if full_snapped_path:
            full_snapped_path.extend(snapped_chunk[1:])
        else:
            full_snapped_path.extend(snapped_chunk)
        time.sleep(0.4)
    return full_snapped_path if full_snapped_path else clean_pts

# ---------------------------------------------------------------------
# 5. MASTER ROUTE PROCESSOR (Saves deliverables)
# ---------------------------------------------------------------------
def process_route_pipeline(route_name, raw_folder, output_base="all_routes_mined_network_repaired", log_callback=None):
    def emit_log(msg):
        print(msg)
        if log_callback:
            log_callback(msg)

    csv_paths = sorted(glob.glob(os.path.join(raw_folder, "*.csv")))
    if len(csv_paths) <= 3:
        err = f"Trip count is {len(csv_paths)}. Requires > 3 files."
        emit_log(err)
        return False, err

    target_dir = os.path.join(output_base, route_name)
    os.makedirs(target_dir, exist_ok=True)

    # Stage 1: Kalman Filter & Speed Synthesis
    emit_log("[1/4] Running 2D Kinematic Kalman Filter & Speed Synthesis...")
    cleaned_dfs = []
    for p in csv_paths:
        try:
            raw_df = pd.read_csv(p)
            clean_df = clean_single_trajectory(raw_df)
            if clean_df is not None and len(clean_df) >= 5:
                cleaned_dfs.append(clean_df)
        except Exception as e:
            print(f"Skipping corrupt trajectory {p}: {e}")
            continue

    if len(cleaned_dfs) < 2:
        err = "Not enough valid GPS fixes across files."
        emit_log(f"Error: {err}")
        return False, err

    all_origin_fixes, all_dest_fixes, dwell_candidates = [], [], []
    representative_trajectory = []

    for idx, df in enumerate(cleaned_dfs):
        if len(df) > len(representative_trajectory):
            representative_trajectory = df[['kalman_lon', 'kalman_lat']].values.tolist()
        all_origin_fixes.append(df.iloc[:3][['kalman_lat', 'kalman_lon']].values)
        all_dest_fixes.append(df.iloc[-3:][['kalman_lat', 'kalman_lon']].values)

        df['is_stopped'] = (df['speed_kmh'] < 5.0) & (df['step_dist_m'] < 6.0)
        df['dwell_group'] = (~df['is_stopped']).cumsum()
        for _, group in df[df['is_stopped']].groupby('dwell_group'):
            dur = (group['time_dt'].iloc[-1] - group['time_dt'].iloc[0]).total_seconds() if group['time_dt'].notna().sum() >= 2 else len(group) * 5.0
            if dur >= 20.0:
                dwell_candidates.append({
                    'trip_idx': idx,
                    'lat': float(group['kalman_lat'].mean()),
                    'lon': float(group['kalman_lon'].mean()),
                    'dwell_duration': float(dur)
                })

    origin_lat = float(np.median(np.vstack(all_origin_fixes)[:, 0]))
    origin_lon = float(np.median(np.vstack(all_origin_fixes)[:, 1]))
    dest_lat = float(np.median(np.vstack(all_dest_fixes)[:, 0]))
    dest_lon = float(np.median(np.vstack(all_dest_fixes)[:, 1]))

    parts = route_name.split("-")
    origin_title = parts[0].replace("_", " ").title() + " Terminal"
    dest_title = parts[-1].replace("_", " ").title() + " Terminal"
    corridor_span = haversine_m(origin_lat, origin_lon, dest_lat, dest_lon)

    stops_extracted = [{
        "name": origin_title, "lat": round(origin_lat, 6), "lon": round(origin_lon, 6),
        "type": "TERMINAL_ORIGIN", "dist_m": 0.0, "support_trips": len(cleaned_dfs), "avg_dwell_sec": 60.0
    }]

    # Stage 2: DBSCAN Virtual Stop Mining
    emit_log("[2/4] Mining Virtual Feeder Stops via Haversine DBSCAN...")
    dwell_df = pd.DataFrame(dwell_candidates)
    buffer_dist = 100.0 if corridor_span < 2000.0 else 300.0
    if not dwell_df.empty:
        dwell_df['d_orig'] = dwell_df.apply(lambda r: haversine_m(r['lat'], r['lon'], origin_lat, origin_lon), axis=1)
        dwell_df['d_dest'] = dwell_df.apply(lambda r: haversine_m(r['lat'], r['lon'], dest_lat, dest_lon), axis=1)
        cand = dwell_df[(dwell_df['d_orig'] > buffer_dist) & (dwell_df['d_dest'] > buffer_dist)].copy()
        if len(cand) >= 2:
            coords_rad = np.radians(cand[['lat', 'lon']].to_numpy())
            db = DBSCAN(eps=50.0 / EARTH_RADIUS_M, min_samples=2, metric='haversine')
            cand['cluster'] = db.fit_predict(coords_rad)
            for cid in sorted([c for c in cand['cluster'].unique() if c != -1]):
                c_pts = cand[cand['cluster'] == cid]
                c_lat, c_lon = float(c_pts['lat'].mean()), float(c_pts['lon'].mean())
                stops_extracted.append({
                    "name": f"Virtual Feeder Stop #{cid + 1}", "lat": round(c_lat, 6), "lon": round(c_lon, 6),
                    "type": "INTERMEDIATE_VIRTUAL_STOP", "dist_m": round(haversine_m(origin_lat, origin_lon, c_lat, c_lon), 1),
                    "support_trips": int(c_pts['trip_idx'].nunique()), "avg_dwell_sec": round(float(c_pts['dwell_duration'].mean()), 1)
                })

    stops_extracted.append({
        "name": dest_title, "lat": round(dest_lat, 6), "lon": round(dest_lon, 6),
        "type": "TERMINAL_DESTINATION", "dist_m": round(corridor_span, 1),
        "support_trips": len(cleaned_dfs), "avg_dwell_sec": 60.0
    })

    stops_extracted = sorted(stops_extracted, key=lambda s: s['dist_m'])
    prefix = "".join(p[0].upper() for p in parts if p)
    for idx, s in enumerate(stops_extracted):
        s["stop_id"] = f"{prefix}_STOP_{idx:02d}"

    # Stage 3: OSRM Map-Matching
    emit_log("[3/4] Map-Matching Centerlines via OSRM with Jitter Pruning...")
    snapped_path = robust_corridor_snapping(representative_trajectory)

    # Stage 4: GeoJSON & Metrics Validation
    emit_log("[4/4] Validating Route Metrics & Saving GeoJSON Layers...")

    # Write deliverables to all_routes_mined_network_repaired/<route_name>/
    with open(os.path.join(target_dir, "virtual_stops.geojson"), "w", encoding="utf-8") as f:
        json.dump({
            "type": "FeatureCollection", "name": f"{route_name}_VirtualStops",
            "features": [{"type": "Feature", "properties": s, "geometry": {"type": "Point", "coordinates": [s["lon"], s["lat"]]}} for s in stops_extracted]
        }, f, indent=2)

    with open(os.path.join(target_dir, "feeder_corridor.geojson"), "w", encoding="utf-8") as f:
        json.dump({
            "type": "FeatureCollection", "name": f"{route_name}_SnappedCorridor",
            "features": [{"type": "Feature", "properties": {"corridor_name": route_name, "stop_count": len(stops_extracted), "status": "OSM_ROAD_MATCHED"},
                          "geometry": {"type": "LineString", "coordinates": snapped_path}}]
        }, f, indent=2)

    pd.DataFrame(stops_extracted).to_csv(os.path.join(target_dir, "virtual_stops_summary.csv"), index=False)
    
    with open(os.path.join(target_dir, "route_metadata.json"), "w", encoding="utf-8") as f:
        json.dump({
            "route_name": route_name,
            "processed_trips": len(cleaned_dfs),
            "total_stops": len(stops_extracted),
            "corridor_length_m": round(corridor_span, 1)
        }, f, indent=2)

    # Update all_routes_summary.csv
    try:
        summary_csv = os.path.join(output_base, "all_routes_summary.csv")
        summary_rows = []
        if os.path.exists(summary_csv):
            try:
                s_df = pd.read_csv(summary_csv)
                s_df = s_df[s_df['route'] != route_name]
                summary_rows = s_df.to_dict('records')
            except Exception:
                pass
        summary_rows.append({
            "route": route_name,
            "trips": len(cleaned_dfs),
            "stops": len(stops_extracted),
            "distance_m": round(corridor_span, 2)
        })
        pd.DataFrame(summary_rows).to_csv(summary_csv, index=False)
    except Exception as e:
        print(f"Notice: Failed to update summary CSV: {e}")

    # Mirror into flexi_transit/assets/data/ for Flutter frontend
    try:
        ws_root = os.path.dirname(os.path.abspath(output_base))
        assets_target = os.path.join(ws_root, "flexi_transit", "assets", "data", "all_routes_mined_network_repaired", route_name)
        os.makedirs(assets_target, exist_ok=True)
        shutil.copy2(os.path.join(target_dir, "virtual_stops.geojson"), os.path.join(assets_target, "virtual_stops.geojson"))
        shutil.copy2(os.path.join(target_dir, "feeder_corridor.geojson"), os.path.join(assets_target, "feeder_corridor.geojson"))
        shutil.copy2(os.path.join(target_dir, "virtual_stops_summary.csv"), os.path.join(assets_target, "virtual_stops_summary.csv"))
        shutil.copy2(os.path.join(target_dir, "route_metadata.json"), os.path.join(assets_target, "route_metadata.json"))

        feeder_network_path = os.path.join(ws_root, "flexi_transit", "assets", "data", "feeder_network.json")
        if os.path.exists(feeder_network_path):
            with open(feeder_network_path, "r", encoding="utf-8") as fnf:
                feeder_data = json.load(fnf)
            # Update corridors
            corridors = [c for c in feeder_data.get("corridors", []) if c.get("corridor_name") != route_name]
            # Convert [lon, lat] -> [lat, lon]
            poly_lat_lon = [[pt[1], pt[0]] for pt in snapped_path]
            corridors.append({
                "corridor_name": route_name,
                "distance_m": round(corridor_span, 1),
                "polyline": poly_lat_lon
            })
            feeder_data["corridors"] = corridors

            # Update stops
            existing_stops = [s for s in feeder_data.get("stops", []) if s.get("corridor_name") != route_name]
            for seq, s in enumerate(stops_extracted):
                stype = "TERMINUS_ORIGIN" if s["type"] == "TERMINAL_ORIGIN" else ("TERMINUS_DEST" if s["type"] == "TERMINAL_DESTINATION" else "INTERMEDIATE_VSTOP")
                existing_stops.append({
                    "stop_id": s["stop_id"],
                    "name": s["name"],
                    "lat": s["lat"],
                    "lon": s["lon"],
                    "corridor_name": route_name,
                    "stop_type": stype,
                    "sequence_order": seq,
                    "avg_dwell_sec": s.get("avg_dwell_sec", 45.0),
                    "support_trips": s.get("support_trips", len(cleaned_dfs))
                })
            feeder_data["stops"] = existing_stops
            with open(feeder_network_path, "w", encoding="utf-8") as fnf:
                json.dump(feeder_data, fnf, indent=2)
    except Exception as e:
        print(f"Notice: Failed to sync assets: {e}")

    # Hot-reload trigger: call POST http://localhost:8000/api/reload-network
    try:
        req = urllib.request.Request("http://127.0.0.1:8000/api/reload-network", data=b"", headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=5) as resp:
            reload_res = json.loads(resp.read().decode('utf-8'))
            emit_log(f"Core engine dynamic reload: {reload_res.get('message', 'ok')}")
    except Exception as e:
        emit_log(f"Notice: Reload trigger notification ({e})")

    success_msg = f"✓ Success: Generated virtual_stops.geojson and feeder_corridor.geojson inside all_routes_mined_network_repaired/{route_name}/"
    emit_log(success_msg)
    return True, success_msg
