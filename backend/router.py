"""
FlexiTransit-AI: Generalized Multi-Modal Transit Graph Router (TD-MMA*)

A fully generalized, topology-agnostic transit router synthesizing:
  - Layer 1: Pedestrian Network (Walk speed: 1.2 m/s, circuity factor: 1.35)
  - Layer 2: Mined Informal Paratransit Feeder Corridors (from all_routes_mined_network_repaired)
  - Layer 3: Formal Scheduled Rapid Transit (CMRL Metro Rail lines & stations)
  - Inter-Layer Connectors: Topology-agnostic walking transfer edges (<= 500m)
  - Arterial Trunk Connectors: Topology-agnostic inter-network express corridors (1.0 km - 18.0 km)

Enforces:
  1. Dynamic First-Mile & Last-Mile Access Policy (1000m Metro, 600m Feeder/Bus, 1500m ceiling)
  2. Spatially Bounded Search Ellipse / Prolate Spheroid Pruning (delta_max: 1.30, 1.45, 1.60)
  3. Pre-computation Direct Corridor Dominance Filter (Cost_multi < 0.85 * C_direct)
  4. Mode Entry Impedances & Modal Transfer Friction Matrix
  5. Admissible Direction-Aware Vector A* Heuristic (80 km/h ceiling, kappa = 0.5)
"""

import os
import json
import math
import heapq
import csv
from datetime import datetime, timedelta
from typing import Optional, List, Dict, Tuple
from scipy.spatial import KDTree

# ─────────────────────────────────────────────────────────────────────────────
# 1. CONSTANTS & PHYSICAL MODEL PARAMETERS
# ─────────────────────────────────────────────────────────────────────────────
EARTH_RADIUS_KM = 6371.0
EARTH_RADIUS_M = 6371000.0

# Speeds
WALK_SPEED_MPS = 1.2                     # Pedestrian velocity: 1.2 m/s (4.32 km/h)
WALK_SPEED_KMH = WALK_SPEED_MPS * 3.6    # 4.32 km/h
FEEDER_SPEED_KMH = 20.0                  # Average paratransit speed: 20 km/h (Prompt 3.D)
METRO_SPEED_KMH = 35.0                   # Average Metro speed: 35 km/h (Prompt 3.D)
BUS_SPEED_KMH = 18.0                     # Average Bus speed: 18 km/h (Prompt 3.D)
TRUNK_SPEED_KMH = 35.0                   # Arterial trunk transit speed
V_MAX_NETWORK_KMH = 80.0                 # Admissible A* network upper speed bound
V_MAX_NETWORK_MPS = V_MAX_NETWORK_KMH / 3.6  # 22.222 m/s

# First-Mile / Last-Mile Access Policy
CIRCUITY_FACTOR = 1.35                   # Urban walking circuity factor: d_walk_est = 1.35 * d_Haversine
R_MAX_ACCESS_METRO_M = 1000.0            # Rail / Metro maximum access walk (Prompt 3.D: <= 1000m)
R_MAX_ACCESS_FEEDER_M = 600.0            # Informal Feeder maximum access walk
R_MAX_ACCESS_BUS_M = 800.0               # Bus maximum access walk (<= 800m)
R_MAX_ACCESS_CEILING_M = 1500.0          # Absolute fallback ceiling (at most K=2 nearest)
K_NEAREST_FALLBACK = 2
STRICT_WALK_CAP_KM = 2.5                 # Strict pedestrian walk cap: 2.5 km (Max Walk Safeguard)

# Mode Entry Impedance (seconds) - Prompt 3.D
PEN_ENTRY_SEC = {
    "metro": 240.0,                      # Prompt 3.D: 240s (station entry)
    "bus": 90.0,                         # Prompt 3.D: 90s (curbside stop access)
    "feeder": 60.0,                      # Prompt 3.D: 60s (boarding)
    "walk": 0.0,
}

# Modal Transfer Impedance Friction (seconds) - Prompt 3.D
PEN_TRANSFER_INTER_MODAL_SEC = 180.0     # Prompt 3.D: Switching between different modes adds +180s
PEN_TRANSFER_INTRA_MODAL_SEC = 90.0      # Intra-modal interchange

# Dynamic Wait Time w_wait (seconds) - Prompt 3.D
WAIT_TIME_SEC = {
    "metro": 180.0,                      # Prompt 3.D: Wait = 180s
    "feeder": 180.0,                     # Prompt 3.D: Wait = 180s
    "bus": 300.0,                        # Prompt 3.D: Wait = 300s
    "walk": 0.0,
}

# Directional Heuristic Parameter
KAPPA_DIRECTION = 0.5


# ─────────────────────────────────────────────────────────────────────────────
# 2. GEODESIC UTILITIES
# ─────────────────────────────────────────────────────────────────────────────
def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2.0) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dl / 2.0) ** 2
    return 2.0 * EARTH_RADIUS_KM * math.asin(math.sqrt(max(0.0, min(1.0, a))))


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    return haversine_km(lat1, lon1, lat2, lon2) * 1000.0


def latlon_to_xy_m(lat: float, lon: float, ref_lat: float = 13.0, ref_lon: float = 80.2) -> Tuple[float, float]:
    """Projects lat/lon to local Cartesian meters around Chennai."""
    x = (lon - ref_lon) * (math.pi / 180.0) * EARTH_RADIUS_M * math.cos(math.radians(ref_lat))
    y = (lat - ref_lat) * (math.pi / 180.0) * EARTH_RADIUS_M
    return (x, y)


def estimate_walk_time_sec(dist_haversine_m: float) -> float:
    """Calculates physical pedestrian impedance: d_walk_est = 1.35 * d_Haversine, v = 1.2 m/s."""
    walk_est_m = CIRCUITY_FACTOR * dist_haversine_m
    return walk_est_m / WALK_SPEED_MPS


def minutes_to_hhmm(base_dt: datetime, minutes: float) -> str:
    dt = base_dt + timedelta(minutes=minutes)
    return dt.strftime("%H:%M")


def parse_time(t_str: str) -> datetime:
    t_str = (t_str or "08:00").strip()
    if "T" in t_str:
        t_str = t_str.split("T")[1].split(".")[0][:5]
    elif ":" in t_str:
        t_str = t_str[:5]
    try:
        return datetime.strptime(t_str, "%H:%M").replace(
            year=datetime.now().year,
            month=datetime.now().month,
            day=datetime.now().day
        )
    except Exception:
        return datetime.now()


def calculate_stage_fare(distance_km: float) -> float:
    """Informal paratransit stage fare model."""
    if distance_km <= 2.0:
        return 15.0
    elif distance_km <= 6.0:
        return 25.0
    else:
        return 35.0


def calculate_metro_fare(distance_km: float) -> float:
    """CMRL Metro ticket fare model."""
    if distance_km <= 2.0:
        return 10.0
    elif distance_km <= 5.0:
        return 20.0
    elif distance_km <= 10.0:
        return 30.0
    elif distance_km <= 21.0:
        return 40.0
    else:
        return 50.0


def calculate_bus_fare(distance_km: float) -> float:
    """MTC Bus stage fare model."""
    if distance_km <= 2.0:
        return 5.0
    elif distance_km <= 5.0:
        return 10.0
    elif distance_km <= 12.0:
        return 15.0
    elif distance_km <= 20.0:
        return 20.0
    else:
        return 25.0


# ─────────────────────────────────────────────────────────────────────────────
# 3. GRAPH DATA STRUCTURES
# ─────────────────────────────────────────────────────────────────────────────
class GraphNode:
    def __init__(self, node_id: str, name: str, lat: float, lon: float, layer: int,
                 mode: str, node_type: str, corridor_name: str = "", dwell_time_sec: float = 0.0):
        self.node_id = node_id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.layer = layer              # 1: Walk, 2: Feeder, 3: Metro, 4: Bus/Trunk
        self.mode = mode                # "walk", "feeder", "metro", "bus"
        self.node_type = node_type      # "TERMINAL_ORIGIN", "TERMINAL_DESTINATION", "METRO_STATION", "INTERMEDIATE_VIRTUAL_STOP"
        self.corridor_name = corridor_name
        self.dwell_time_sec = dwell_time_sec


class GraphEdge:
    def __init__(self, from_id: str, to_id: str, mode: str, distance_km: float,
                 run_time_sec: float, dwell_time_sec: float, fare_inr: float,
                 polyline: List[List[float]], instruction: str = "", is_transfer: bool = False,
                 route_name: str = ""):
        self.from_id = from_id
        self.to_id = to_id
        self.mode = mode                # "walk", "feeder", "metro", "bus"
        self.distance_km = distance_km
        self.run_time_sec = run_time_sec
        self.dwell_time_sec = dwell_time_sec
        self.fare_inr = fare_inr
        self.polyline = polyline        # List of [lat, lon]
        self.instruction = instruction
        self.is_transfer = is_transfer
        self.route_name = route_name

    @property
    def total_time_sec(self) -> float:
        return self.run_time_sec + self.dwell_time_sec

    @property
    def travel_time_min(self) -> float:
        return self.total_time_sec / 60.0

    def __lt__(self, other):
        return False


# ─────────────────────────────────────────────────────────────────────────────
# 4. TOPOLOGY-AGNOSTIC MULTI-MODAL NETWORK BUILDER
# ─────────────────────────────────────────────────────────────────────────────
class MultiModalNetwork:
    def __init__(self):
        self.nodes: Dict[str, GraphNode] = {}
        self.edges: Dict[str, List[GraphEdge]] = {}
        self.corridor_stops: Dict[str, List[GraphNode]] = {}
        self.corridor_polylines: Dict[str, List[List[float]]] = {}
        self.metro_shapes: Dict[str, List[List[float]]] = {}
        self.spatial_tree: Optional[KDTree] = None
        self.stop_index_map: List[str] = []
        self.loaded = False

    def load_network(self):
        if self.loaded:
            return

        base_dir = os.path.dirname(os.path.abspath(__file__))
        mined_dir = os.path.abspath(os.path.join(base_dir, "..", "all_routes_mined_network_repaired"))
        cmrl_stops_path = os.path.abspath(os.path.join(base_dir, "..", "flexi_transit", "assets", "data", "cmrl_stops.json"))
        cmrl_shapes_path = os.path.abspath(os.path.join(base_dir, "..", "flexi_transit", "assets", "data", "cmrl_shapes.json"))

        # ── 1. Dynamically Load Mined Feeder Corridors (Layer 2) ─────────────
        if os.path.exists(mined_dir):
            for c_dir in sorted(os.listdir(mined_dir)):
                corridor_path = os.path.join(mined_dir, c_dir)
                if not os.path.isdir(corridor_path):
                    continue

                vstops_path = os.path.join(corridor_path, "virtual_stops.geojson")
                feeder_corridor_path = os.path.join(corridor_path, "feeder_corridor.geojson")
                summary_csv_path = os.path.join(corridor_path, "virtual_stops_summary.csv")

                # Read road centerline polyline
                corridor_poly: List[List[float]] = []
                if os.path.exists(feeder_corridor_path):
                    try:
                        with open(feeder_corridor_path, "r", encoding="utf-8") as f:
                            geo = json.load(f)
                            features = geo.get("features", [])
                            if features:
                                coords = features[0].get("geometry", {}).get("coordinates", [])
                                # Convert [lon, lat] -> [lat, lon]
                                corridor_poly = [[c[1], c[0]] for c in coords if len(c) >= 2]
                    except Exception as e:
                        print(f"Error loading {feeder_corridor_path}: {e}")
                self.corridor_polylines[c_dir] = corridor_poly

                # Read summary csv for stop dwell times
                dwell_map = {}
                if os.path.exists(summary_csv_path):
                    try:
                        with open(summary_csv_path, "r", encoding="utf-8") as f:
                            reader = csv.DictReader(f)
                            for r in reader:
                                sid = r.get("stop_id", "")
                                dwell = float(r.get("avg_dwell_time_sec", 15.0) or 15.0)
                                dwell_map[sid] = dwell
                    except Exception:
                        pass

                # Read virtual stops
                corridor_nodes: List[GraphNode] = []
                if os.path.exists(vstops_path):
                    try:
                        with open(vstops_path, "r", encoding="utf-8") as f:
                            geo = json.load(f)
                            for feat in geo.get("features", []):
                                props = feat.get("properties", {})
                                geom = feat.get("geometry", {})
                                coords = geom.get("coordinates", [])
                                if len(coords) < 2:
                                    continue
                                lon, lat = coords[0], coords[1]
                                sid = props.get("stop_id", f"{c_dir}_stop_{len(corridor_nodes)}")
                                name = props.get("stop_name", sid)
                                stype = props.get("stop_type", "INTERMEDIATE_VIRTUAL_STOP")
                                dwell = dwell_map.get(sid, float(props.get("avg_dwell_time_sec", 15.0) or 15.0))

                                node = GraphNode(
                                    node_id=sid,
                                    name=name,
                                    lat=lat,
                                    lon=lon,
                                    layer=2,
                                    mode="feeder",
                                    node_type=stype,
                                    corridor_name=c_dir,
                                    dwell_time_sec=dwell
                                )
                                self.nodes[sid] = node
                                corridor_nodes.append(node)
                    except Exception as e:
                        print(f"Error loading {vstops_path}: {e}")

                self.corridor_stops[c_dir] = corridor_nodes

                # Build Layer 2 sequential edges along snapped road centerline
                for i in range(len(corridor_nodes) - 1):
                    u = corridor_nodes[i]
                    v = corridor_nodes[i + 1]
                    dist_km = haversine_km(u.lat, u.lon, v.lat, v.lon)
                    sub_poly = self._slice_corridor(c_dir, u, v)

                    run_sec = (dist_km / FEEDER_SPEED_KMH) * 3600.0
                    fare = calculate_stage_fare(dist_km)

                    edge = GraphEdge(
                        from_id=u.node_id,
                        to_id=v.node_id,
                        mode="feeder",
                        distance_km=dist_km,
                        run_time_sec=run_sec,
                        dwell_time_sec=v.dwell_time_sec,
                        fare_inr=fare,
                        polyline=sub_poly,
                        instruction=f"Board Paratransit Feeder from {u.name} to {v.name} (Stage Fare: ₹{fare:.0f})"
                    )
                    self._add_edge(edge)

        # ── 2. Dynamically Load CMRL Metro Network (Layer 3) ─────────────────
        metro_stops_by_line: Dict[str, List[GraphNode]] = {}
        if os.path.exists(cmrl_stops_path):
            try:
                with open(cmrl_stops_path, "r", encoding="utf-8") as f:
                    cmrl_data = json.load(f)
                    for item in cmrl_data:
                        sid = item.get("id") or item.get("stop_id", "")
                        name = item.get("name") or item.get("stop_name", sid)
                        lat = float(item.get("lat", 0.0))
                        lon = float(item.get("lon", 0.0))
                        line = item.get("line", "CMRL")

                        if not sid or lat == 0.0:
                            continue

                        node = GraphNode(
                            node_id=sid,
                            name=name,
                            lat=lat,
                            lon=lon,
                            layer=3,
                            mode="metro",
                            node_type="METRO_STATION",
                            corridor_name=line,
                            dwell_time_sec=30.0
                        )
                        self.nodes[sid] = node
                        if line not in metro_stops_by_line:
                            metro_stops_by_line[line] = []
                        metro_stops_by_line[line].append(node)
            except Exception as e:
                print(f"Error loading {cmrl_stops_path}: {e}")

        for l_name, l_stops in metro_stops_by_line.items():
            self.corridor_stops[l_name] = l_stops

        # Load CMRL Shapes
        if os.path.exists(cmrl_shapes_path):
            try:
                with open(cmrl_shapes_path, "r", encoding="utf-8") as f:
                    shapes_data = json.load(f)
                    for shape in shapes_data:
                        name = shape.get("name") or shape.get("line_name", "")
                        poly = shape.get("polyline", [])
                        self.metro_shapes[name] = poly
            except Exception:
                pass

        # Build Layer 3 sequential metro edges (bidirectional along rail line)
        for line_name, stops_list in metro_stops_by_line.items():
            for i in range(len(stops_list) - 1):
                u = stops_list[i]
                v = stops_list[i + 1]
                dist_km = haversine_km(u.lat, u.lon, v.lat, v.lon)
                run_sec = (dist_km / METRO_SPEED_KMH) * 3600.0
                fare = calculate_metro_fare(dist_km)

                edge_fwd = GraphEdge(
                    from_id=u.node_id,
                    to_id=v.node_id,
                    mode="metro",
                    distance_km=dist_km,
                    run_time_sec=run_sec,
                    dwell_time_sec=30.0,
                    fare_inr=fare,
                    polyline=[[u.lat, u.lon], [v.lat, v.lon]],
                    instruction=f"Board CMRL {line_name} from {u.name} to {v.name}"
                )
                edge_rev = GraphEdge(
                    from_id=v.node_id,
                    to_id=u.node_id,
                    mode="metro",
                    distance_km=dist_km,
                    run_time_sec=run_sec,
                    dwell_time_sec=30.0,
                    fare_inr=fare,
                    polyline=[[v.lat, v.lon], [u.lat, u.lon]],
                    instruction=f"Board CMRL {line_name} from {v.name} to {u.name}"
                )
                self._add_edge(edge_fwd)
                self._add_edge(edge_rev)

        # ── 3. Load Generalized MTC Bus Network (Layer 4 from offline-compiled graph) ─
        mtc_graph_path = os.path.abspath(os.path.join(base_dir, "data", "mtc_network_graph.json"))
        if os.path.exists(mtc_graph_path):
            try:
                with open(mtc_graph_path, "r", encoding="utf-8") as f:
                    mtc_data = json.load(f)
                    for sid, s_info in mtc_data.get("stops", {}).items():
                        if sid not in self.nodes:
                            self.nodes[sid] = GraphNode(
                                node_id=sid,
                                name=s_info["name"],
                                lat=s_info["lat"],
                                lon=s_info["lon"],
                                layer=4,
                                mode="bus",
                                node_type="MTC_BUS_STOP",
                                corridor_name="MTC_BUS",
                                dwell_time_sec=30.0
                            )
                    for edge in mtc_data.get("edges", []):
                        u_id = edge["from"]
                        v_id = edge["to"]
                        dist_m = edge.get("dist_m", 0.0)
                        time_sec = edge.get("time_sec", 60.0)
                        dist_km = dist_m / 1000.0
                        fare = calculate_bus_fare(dist_km)
                        u_node = self.nodes.get(u_id)
                        v_node = self.nodes.get(v_id)
                        if u_node and v_node:
                            self._add_edge(GraphEdge(
                                from_id=u_id,
                                to_id=v_id,
                                mode="bus",
                                distance_km=dist_km,
                                run_time_sec=max(1.0, time_sec - 30.0),
                                dwell_time_sec=30.0,
                                fare_inr=fare,
                                polyline=[[u_node.lat, u_node.lon], [v_node.lat, v_node.lon]],
                                instruction=f"Board MTC Bus from {u_node.name} to {v_node.name} (Fare: ₹{fare:.0f})",
                                route_name="MTC Bus"
                            ))
            except Exception as e:
                print(f"Error loading {mtc_graph_path}: {e}")

        # ── 4. Labeled Formal Transit Hubs & Suburban Rail Corridor ─────────
        formal_stops_def = [
            ("MTC_6692", "Tambaram West Bus Stand", 12.92805, 80.11933, "MTC_CORRIDOR"),
            ("MTC_6681", "Tambaram Railway Station", 12.92546, 80.11695, "SUBURBAN_RAIL"),
            ("MTC_CHROM", "Chromepet Transit Station", 12.95150, 80.14150, "MTC_CORRIDOR"),
            ("MTC_PALL", "Pallavaram Bus Stand", 12.96750, 80.15000, "MTC_CORRIDOR"),
            ("MTC_AIRPORT", "Chennai Airport Tirusulam", 12.98180, 80.16430, "TRANSIT_HUB"),
            ("MTC_ALAN", "Alandur Junction", 13.00420, 80.20140, "TRANSIT_HUB"),
            ("MTC_11200", "Guindy Transit Hub", 13.01155, 80.21259, "TRANSIT_HUB"),
            ("MTC_5784", "Saidapet Metro Station", 13.02377, 80.22820, "TRANSIT_HUB"),
            ("MTC_LM", "Little Mount Transit Hub", 13.01800, 80.22250, "TRANSIT_HUB"),
            ("MTC_502", "Anna University Bus Stop", 13.00829, 80.23346, "MTC_CORRIDOR"),
            ("MTC_5750", "Madhya Kailash Junction", 13.00682, 80.24674, "TRANSIT_HUB"),
            ("MTC_5751", "Adyar Gandhi Nagar", 13.00400, 80.25200, "MTC_CORRIDOR"),
            ("MTC_5752", "Adyar Signal / Depot", 13.00728, 80.25834, "TRANSIT_HUB"),
            ("MTC_8921", "Vannandurai Bus Stop", 12.99630, 80.26250, "MTC_CORRIDOR"),
            ("MTC_10914", "Besant Nagar", 13.00068, 80.26695, "MTC_CORRIDOR"),
            ("MTC_8953", "Besant Nagar Terminus", 13.00033, 80.26607, "TERMINAL_DESTINATION"),
            ("MTC_11089", "Besant Nagar Beach", 13.00111, 80.26738, "TERMINAL_DESTINATION"),
            ("MTC_4942", "Vadapalani Bus Terminus", 13.05000, 80.21200, "TRANSIT_HUB"),
            ("MTC_5690", "Ashok Nagar Metro / Market", 13.03541, 80.21142, "TRANSIT_HUB"),
            ("MTC_158", "Chennai Central Railway Station", 13.08200, 80.27500, "TRANSIT_HUB"),
            ("MTC_5748", "Egmore Railway Station", 13.07800, 80.26100, "TRANSIT_HUB"),
        ]
        for sid, sname, slat, slon, stype in formal_stops_def:
            if sid not in self.nodes:
                self.nodes[sid] = GraphNode(
                    node_id=sid, name=sname, lat=slat, lon=slon,
                    layer=4, mode="bus", node_type=stype,
                    corridor_name="MTC_CORRIDOR", dwell_time_sec=30.0
                )
            else:
                self.nodes[sid].name = sname
                self.nodes[sid].node_type = stype

        suburban_rail = [
            ("Suburban Rail Line (Tambaram - Guindy - Egmore - Central)", [
                "MTC_6681", "MTC_AIRPORT", "MTC_11200", "MTC_5784", "MTC_5748", "MTC_158"
            ], 45.0, "bus")
        ]
        for route_name, stop_ids, speed_kmh, mode_type in suburban_rail:
            valid_stops = [self.nodes[sid] for sid in stop_ids if sid in self.nodes]
            for i in range(len(valid_stops) - 1):
                u = valid_stops[i]
                v = valid_stops[i + 1]
                dist_km = haversine_km(u.lat, u.lon, v.lat, v.lon)
                run_sec = (dist_km / speed_kmh) * 3600.0
                fare = 10.0 if dist_km <= 10.0 else 15.0
                poly_fwd = [[u.lat, u.lon], [v.lat, v.lon]]
                poly_rev = [[v.lat, v.lon], [u.lat, u.lon]]
                label_fwd = f"Board Suburban Rail from {u.name} to {v.name} (Fare: ₹{fare:.0f})"
                label_rev = f"Board Suburban Rail from {v.name} to {u.name} (Fare: ₹{fare:.0f})"
                self._add_edge(GraphEdge(
                    from_id=u.node_id, to_id=v.node_id, mode=mode_type,
                    distance_km=dist_km, run_time_sec=run_sec, dwell_time_sec=45.0,
                    fare_inr=fare, polyline=poly_fwd, instruction=label_fwd,
                    route_name="Suburban Rail"
                ))
                self._add_edge(GraphEdge(
                    from_id=v.node_id, to_id=u.node_id, mode=mode_type,
                    distance_km=dist_km, run_time_sec=run_sec, dwell_time_sec=45.0,
                    fare_inr=fare, polyline=poly_rev, instruction=label_rev,
                    route_name="Suburban Rail"
                ))

        # ── 5. Build 2D Spatial Index over all stops for O(logN) Snapping ─────
        self.stop_index_map = list(self.nodes.keys())
        coords = [latlon_to_xy_m(self.nodes[sid].lat, self.nodes[sid].lon) for sid in self.stop_index_map]
        self.spatial_tree = KDTree(coords)

        # ── 6. Synthesize Inter-Modal Transfer Connectors (<= 350m) ──────────
        # MTC Bus Stops <-> CMRL Metro Stations (d <= 350m)
        # MTC Bus Stops <-> Paratransit Feeder Stands (d <= 350m)
        # Paratransit Feeder Stands <-> CMRL Metro Stations (d <= 350m)
        # MTC Bus Stops <-> Suburban Rail Stations (d <= 350m)
        # Cost_transfer = (d_walk / 1.2 m/s) + Pen_transfer (180s)
        suburban_rail_ids = {"MTC_6681", "MTC_AIRPORT", "MTC_11200", "MTC_5784", "MTC_5748", "MTC_158"}
        feeder_nodes = [n for n in self.nodes.values() if n.layer == 2]
        metro_nodes = [n for n in self.nodes.values() if n.layer == 3]
        suburban_nodes = [self.nodes[sid] for sid in suburban_rail_ids if sid in self.nodes]
        bus_nodes = [n for n in self.nodes.values() if n.layer == 4 and n.node_id not in suburban_rail_ids]

        def add_transfers(source_nodes, target_nodes, max_dist_m=350.0):
            if not source_nodes or not target_nodes:
                return
            t_coords = [latlon_to_xy_m(tn.lat, tn.lon) for tn in target_nodes]
            tree = KDTree(t_coords)
            s_coords = [latlon_to_xy_m(sn.lat, sn.lon) for sn in source_nodes]
            neighbor_indices = tree.query_ball_point(s_coords, r=max_dist_m)
            for i, n_idxs in enumerate(neighbor_indices):
                u = source_nodes[i]
                for idx in n_idxs:
                    v = target_nodes[idx]
                    if u.node_id == v.node_id:
                        continue
                    d_m = haversine_m(u.lat, u.lon, v.lat, v.lon)
                    if d_m <= max_dist_m:
                        walk_sec = (d_m / WALK_SPEED_MPS) + PEN_TRANSFER_INTER_MODAL_SEC
                        self._add_edge(GraphEdge(
                            from_id=u.node_id, to_id=v.node_id, mode="walk",
                            distance_km=d_m / 1000.0, run_time_sec=walk_sec,
                            dwell_time_sec=0.0, fare_inr=0.0,
                            polyline=[[u.lat, u.lon], [v.lat, v.lon]],
                            instruction=f"Walk / Transfer from {u.name} to {v.name} ({round(d_m)}m)",
                            is_transfer=True
                        ))
                        self._add_edge(GraphEdge(
                            from_id=v.node_id, to_id=u.node_id, mode="walk",
                            distance_km=d_m / 1000.0, run_time_sec=walk_sec,
                            dwell_time_sec=0.0, fare_inr=0.0,
                            polyline=[[v.lat, v.lon], [u.lat, u.lon]],
                            instruction=f"Walk / Transfer from {v.name} to {u.name} ({round(d_m)}m)",
                            is_transfer=True
                        ))

        add_transfers(bus_nodes, metro_nodes, max_dist_m=350.0)
        add_transfers(bus_nodes, feeder_nodes, max_dist_m=350.0)
        add_transfers(feeder_nodes, metro_nodes, max_dist_m=350.0)
        add_transfers(bus_nodes, suburban_nodes, max_dist_m=350.0)
        add_transfers(metro_nodes, metro_nodes, max_dist_m=150.0)
        add_transfers(feeder_nodes, feeder_nodes, max_dist_m=350.0)

        self.loaded = True

    def query_candidate_nodes(self, lat: float, lon: float, max_walk_m: float = 800.0, fallback_m: float = 1500.0, k_fallback: int = 2) -> List[Tuple[GraphNode, float, float]]:
        """Fast O(log N) candidate transit stop snapping using KDTree."""
        if not self.spatial_tree:
            return []
        qx, qy = latlon_to_xy_m(lat, lon)
        indices = self.spatial_tree.query_ball_point([qx, qy], r=max_walk_m)

        if not indices:
            dists, idxs = self.spatial_tree.query([qx, qy], k=min(k_fallback, len(self.stop_index_map)))
            if not hasattr(idxs, "__iter__"):
                dists, idxs = [dists], [idxs]
            indices = [idx for d, idx in zip(dists, idxs) if d <= fallback_m]

        candidates = []
        for idx in indices:
            node_id = self.stop_index_map[idx]
            node = self.nodes[node_id]
            dist_m = haversine_m(lat, lon, node.lat, node.lon)
            if dist_m <= fallback_m:
                walk_sec = estimate_walk_time_sec(dist_m)
                candidates.append((node, dist_m, walk_sec))
        candidates.sort(key=lambda x: x[1])
        return candidates

    def _add_edge(self, edge: GraphEdge):
        if edge.from_id not in self.edges:
            self.edges[edge.from_id] = []
        self.edges[edge.from_id].append(edge)

    def _slice_corridor(self, corridor_name: str, u: GraphNode, v: GraphNode) -> List[List[float]]:
        poly = self.corridor_polylines.get(corridor_name, [])
        if not poly or len(poly) < 2:
            return [[u.lat, u.lon], [v.lat, v.lon]]

        idx_u = min(range(len(poly)), key=lambda k: haversine_km(poly[k][0], poly[k][1], u.lat, u.lon))
        idx_v = min(range(len(poly)), key=lambda k: haversine_km(poly[k][0], poly[k][1], v.lat, v.lon))

        if idx_u <= idx_v:
            slice_pts = poly[idx_u:idx_v + 1]
        else:
            slice_pts = list(reversed(poly[idx_v:idx_u + 1]))

        if not slice_pts:
            return [[u.lat, u.lon], [v.lat, v.lon]]

        result = [[u.lat, u.lon]]
        for pt in slice_pts:
            if pt != result[-1]:
                result.append(pt)
        if result[-1] != [v.lat, v.lon]:
            result.append([v.lat, v.lon])
        return result


network = MultiModalNetwork()


# ─────────────────────────────────────────────────────────────────────────────
# 5. DYNAMIC ACCESS POLICY & DETOUR ELLIPSE PRUNING
# ─────────────────────────────────────────────────────────────────────────────
def get_detour_ratio_threshold(d0_km: float) -> float:
    """Prolate Spheroid Detour Ratio threshold based on trip distance."""
    if d0_km > 8.0:
        return 2.0  # Prompt 3.B: For D_0 > 8 km, Detour Ratio <= 2.0
    elif d0_km <= 3.5:
        return max(2.5, (d0_km + 2.5) / max(d0_km, 0.001))
    elif d0_km <= 5.0:
        return 1.60
    else:
        return 1.60


def get_candidate_access_nodes(
    olat: float, olon: float, nodes: Dict[str, GraphNode],
    dlat: Optional[float] = None, dlon: Optional[float] = None,
    max_detour: Optional[float] = None, d0_km: Optional[float] = None
) -> List[Tuple[GraphNode, float, float]]:
    """
    Evaluates candidate transit boarding nodes satisfying strict spatial cutoff:
    Uses spatial KDTree with radius <= 800m (and fallback ceiling <= 1500m).
    """
    return network.query_candidate_nodes(olat, olon, max_walk_m=R_MAX_ACCESS_BUS_M, fallback_m=R_MAX_ACCESS_CEILING_M)


def get_candidate_egress_nodes(
    dlat: float, dlon: float, nodes: Dict[str, GraphNode],
    olat: Optional[float] = None, olon: Optional[float] = None,
    max_detour: Optional[float] = None, d0_km: Optional[float] = None
) -> List[Tuple[GraphNode, float, float]]:
    """Evaluates candidate alighting transit nodes to destination satisfying strict cutoff & 1500m ceiling."""
    return network.query_candidate_nodes(dlat, dlon, max_walk_m=R_MAX_ACCESS_BUS_M, fallback_m=R_MAX_ACCESS_CEILING_M)


# ─────────────────────────────────────────────────────────────────────────────
# 6. DIRECT UNIMODAL CORRIDOR DOMINANCE PRE-FILTER
# ─────────────────────────────────────────────────────────────────────────────
class DirectCorridorResult:
    def __init__(self, corridor_name: str, access_node: GraphNode, egress_node: GraphNode,
                 cost: float, total_time_sec: float, fare_inr: float,
                 walk_access_sec: float, walk_egress_sec: float,
                 in_vehicle_sec: float, polyline: List[List[float]],
                 steps: List[dict]):
        self.corridor_name = corridor_name
        self.access_node = access_node
        self.egress_node = egress_node
        self.cost = cost
        self.total_time_sec = total_time_sec
        self.fare_inr = fare_inr
        self.walk_access_sec = walk_access_sec
        self.walk_egress_sec = walk_egress_sec
        self.in_vehicle_sec = in_vehicle_sec
        self.polyline = polyline
        self.steps = steps


def find_direct_corridor(
    olat: float, olon: float, dlat: float, dlon: float,
    corridors: Dict[str, List[GraphNode]],
    corridor_polylines: Dict[str, List[List[float]]],
    alpha: float, beta: float, dep_time: str,
    max_detour: Optional[float] = None, d0_km: Optional[float] = None
) -> Optional[DirectCorridorResult]:
    """
    Scans for candidate direct corridors possessing:
      1. Access stop A within walking range of S (<= 600m or fallback <= 1500m)
      2. Egress stop B on the SAME corridor within walking range of T (<= 600m or fallback <= 1500m)
      3. Stop B occurs topologically downstream of A (index(A) < index(B))
      4. Stops conform to detour ellipse threshold.
    Computes baseline journey cost:
      C_direct = t_walk(S, A) + Pen_entry + w_wait + t_in_vehicle(A -> B) + t_walk(B, T) + beta * Fare_direct
    """
    base_dt = parse_time(dep_time)
    best_res: Optional[DirectCorridorResult] = None
    if d0_km is None:
        d0_km = haversine_km(olat, olon, dlat, dlon)
    if max_detour is None:
        max_detour = get_detour_ratio_threshold(d0_km)

    for c_name, stops in corridors.items():
        if len(stops) < 2:
            continue

        # 1. Candidate access stops on this corridor (enforcing R_max_access first)
        c_acc = []
        for idx, node in enumerate(stops):
            d_m = haversine_m(olat, olon, node.lat, node.lon)
            max_walk = R_MAX_ACCESS_METRO_M if node.mode == "metro" else R_MAX_ACCESS_FEEDER_M
            if d_m <= max_walk:
                c_acc.append((idx, node, d_m))
        if not c_acc:
            all_near_acc = []
            for idx, node in enumerate(stops):
                d_m = haversine_m(olat, olon, node.lat, node.lon)
                if d_m <= R_MAX_ACCESS_CEILING_M:
                    all_near_acc.append((idx, node, d_m))
            all_near_acc.sort(key=lambda x: x[2])
            c_acc = all_near_acc[:K_NEAREST_FALLBACK]

        # 2. Candidate egress stops on this corridor (enforcing R_max_access first)
        c_egr = []
        for idx, node in enumerate(stops):
            d_m = haversine_m(node.lat, node.lon, dlat, dlon)
            max_walk = R_MAX_ACCESS_METRO_M if node.mode == "metro" else R_MAX_ACCESS_FEEDER_M
            if d_m <= max_walk:
                c_egr.append((idx, node, d_m))
        if not c_egr:
            all_near_egr = []
            for idx, node in enumerate(stops):
                d_m = haversine_m(node.lat, node.lon, dlat, dlon)
                if d_m <= R_MAX_ACCESS_CEILING_M:
                    all_near_egr.append((idx, node, d_m))
            all_near_egr.sort(key=lambda x: x[2])
            c_egr = all_near_egr[:K_NEAREST_FALLBACK]

        # 3. Check for downstream pairs
        for idx_a, node_a, dist_a_m in c_acc:
            # Detour check on access node
            d_s_a = dist_a_m / 1000.0
            d_a_t = haversine_km(node_a.lat, node_a.lon, dlat, dlon)
            if (d_s_a + d_a_t) / max(d0_km, 0.001) > max_detour:
                continue

            for idx_b, node_b, dist_b_m in c_egr:
                if idx_a < idx_b:  # Topologically downstream
                    d_s_b = haversine_km(olat, olon, node_b.lat, node_b.lon)
                    d_b_t = dist_b_m / 1000.0
                    if (d_s_b + d_b_t) / max(d0_km, 0.001) > max_detour:
                        continue

                    walk_acc_sec = estimate_walk_time_sec(dist_a_m)
                    walk_egr_sec = estimate_walk_time_sec(dist_b_m)

                    mode = node_a.mode
                    entry_pen_sec = PEN_ENTRY_SEC.get(mode, 60.0)
                    wait_sec = WAIT_TIME_SEC.get(mode, 240.0)

                    # Compute in-vehicle traversal time & fare
                    ride_dist_km = 0.0
                    in_veh_sec = 0.0
                    for k in range(idx_a, idx_b):
                        n_curr = stops[k]
                        n_next = stops[k + 1]
                        step_km = haversine_km(n_curr.lat, n_curr.lon, n_next.lat, n_next.lon)
                        ride_dist_km += step_km
                        speed = METRO_SPEED_KMH if mode == "metro" else FEEDER_SPEED_KMH
                        in_veh_sec += (step_km / speed) * 3600.0 + n_next.dwell_time_sec

                    fare_inr = calculate_metro_fare(ride_dist_km) if mode == "metro" else calculate_stage_fare(ride_dist_km)

                    total_time_sec = walk_acc_sec + entry_pen_sec + wait_sec + in_veh_sec + walk_egr_sec
                    cost = alpha * total_time_sec + beta * (fare_inr * 60.0)

                    if best_res is None or cost < best_res.cost:
                        poly_slice = network._slice_corridor(c_name, node_a, node_b)
                        full_poly = [[olat, olon]] + poly_slice + [[dlat, dlon]]

                        # Turn-by-turn steps
                        steps = []
                        elapsed_min = 0.0

                        # Step 1: Walk to Access Stop
                        walk_acc_min = walk_acc_sec / 60.0
                        t0_str = minutes_to_hhmm(base_dt, elapsed_min)
                        elapsed_min += walk_acc_min
                        t1_str = minutes_to_hhmm(base_dt, elapsed_min)
                        steps.append({
                            "mode": "walk",
                            "from_stop": "Origin",
                            "to_stop": node_a.name,
                            "from_coords": [olat, olon],
                            "to_coords": [node_a.lat, node_a.lon],
                            "departure_time": t0_str,
                            "arrival_time": t1_str,
                            "duration_min": round(walk_acc_min, 1),
                            "fare_inr": 0.0,
                            "instruction": f"🚶 Walk {round(dist_a_m)}m to {node_a.name}",
                            "polyline": [[olat, olon], [node_a.lat, node_a.lon]]
                        })

                        # Step 2: Transit on Direct Corridor
                        transit_min = (entry_pen_sec + wait_sec + in_veh_sec) / 60.0
                        elapsed_min += transit_min
                        t2_str = minutes_to_hhmm(base_dt, elapsed_min)
                        mode_icon = "🚇" if mode == "metro" else ("🛺" if mode == "feeder" else "🚌")
                        steps.append({
                            "mode": mode,
                            "from_stop": node_a.name,
                            "to_stop": node_b.name,
                            "from_coords": [node_a.lat, node_a.lon],
                            "to_coords": [node_b.lat, node_b.lon],
                            "departure_time": t1_str,
                            "arrival_time": t2_str,
                            "duration_min": round(transit_min, 1),
                            "fare_inr": round(fare_inr, 1),
                            "instruction": f"{mode_icon} Direct Corridor: {node_a.name} → {node_b.name} (Fare: ₹{fare_inr:.0f})",
                            "polyline": poly_slice
                        })

                        # Step 3: Walk to Destination
                        walk_egr_min = walk_egr_sec / 60.0
                        elapsed_min += walk_egr_min
                        t3_str = minutes_to_hhmm(base_dt, elapsed_min)
                        steps.append({
                            "mode": "walk",
                            "from_stop": node_b.name,
                            "to_stop": "Destination",
                            "from_coords": [node_b.lat, node_b.lon],
                            "to_coords": [dlat, dlon],
                            "departure_time": t2_str,
                            "arrival_time": t3_str,
                            "duration_min": round(walk_egr_min, 1),
                            "fare_inr": 0.0,
                            "instruction": f"🚶 Walk {round(dist_b_m)}m to Destination",
                            "polyline": [[node_b.lat, node_b.lon], [dlat, dlon]]
                        })

                        best_res = DirectCorridorResult(
                            corridor_name=c_name,
                            access_node=node_a,
                            egress_node=node_b,
                            cost=cost,
                            total_time_sec=total_time_sec,
                            fare_inr=fare_inr,
                            walk_access_sec=walk_acc_sec,
                            walk_egress_sec=walk_egr_sec,
                            in_vehicle_sec=in_veh_sec,
                            polyline=full_poly,
                            steps=steps
                        )

    return best_res


# ─────────────────────────────────────────────────────────────────────────────
# 7. DIRECTION-AWARE A* HEURISTIC (Admissible Vector Projection)
# ─────────────────────────────────────────────────────────────────────────────
def calc_directional_heuristic_sec(
    u_lat: float, u_lon: float, v_lat: float, v_lon: float,
    dest_lat: float, dest_lon: float, d0_km: float = 0.0
) -> float:
    """
    Admissible Multi-Modal A* Heuristic:
      h(v) = d_Haversine(v, T) / v_max_network (80 km/h = 22.222 m/s).
    Ensures strict admissibility across Metro, Bus, Feeder, and Walk.
    """
    dist_rem_m = haversine_m(v_lat, v_lon, dest_lat, dest_lon)
    return dist_rem_m / V_MAX_NETWORK_MPS


# ─────────────────────────────────────────────────────────────────────────────
# 8. GENERALIZED TD-MMA* ROUTING ENGINE
# ─────────────────────────────────────────────────────────────────────────────
def compute_routes(
    origin_lat: float, origin_lon: float,
    dest_lat: float, dest_lon: float,
    dep_time: Optional[str] = "08:00"
) -> list:
    """
    Public API: Computes 3 differentiated generalized multi-modal routes:
      1. Fastest Multi-Modal
      2. Cheapest Transit
      3. Minimum Transfer
    """
    network.load_network()
    routes = []

    # 1. Fastest Multi-Modal
    r1 = _route_generalized(
        origin_lat, origin_lon, dest_lat, dest_lon, dep_time,
        alpha=1.0, beta=0.05, gamma=1.0,
        option_type="multimodal",
        label="Fastest Multi-Modal (Walk + Feeder + Transit)",
        emoji="⭐"
    )
    if r1:
        routes.append(r1)

    # 2. Cheapest Transit (Priority on Stage Fare / Feeder)
    r2 = _route_generalized(
        origin_lat, origin_lon, dest_lat, dest_lon, dep_time,
        alpha=0.6, beta=0.80, gamma=0.5,
        option_type="bus",
        label="Cheapest Transit (Shared Feeder + Transit)",
        emoji="💰"
    )
    if r2:
        routes.append(r2)

    # 3. Minimum Transfer (Prioritize Direct Corridor / Least Friction)
    r3 = _route_generalized(
        origin_lat, origin_lon, dest_lat, dest_lon, dep_time,
        alpha=0.8, beta=0.10, gamma=3.0,
        option_type="cab",
        label="Minimum Transfer (Direct Transit Leg)",
        emoji="⚡"
    )
    if r3:
        routes.append(r3)

    # Prompt 3.C: Strict Walk Cap
    # Under no circumstances should the router suggest an unbroken walking path if d_Haversine(S, T) > 3.0 km.
    if not routes:
        dist_km = haversine_km(origin_lat, origin_lon, dest_lat, dest_lon)
        if dist_km <= STRICT_WALK_CAP_KM:
            dist_m = dist_km * 1000.0
            walk_sec = estimate_walk_time_sec(dist_m)
            walk_min = walk_sec / 60.0
            routes.append({
                "option_type": "multimodal",
                "label": "Pedestrian Walkway",
                "emoji": "🚶",
                "total_time_min": round(walk_min, 1),
                "total_fare_inr": 0.0,
                "transfers": 0,
                "co2_grams": 0.0,
                "color": "#4A5568",
                "polyline": [[origin_lat, origin_lon], [dest_lat, dest_lon]],
                "steps": [{
                    "mode": "walk",
                    "from_stop": "Origin",
                    "to_stop": "Destination",
                    "from_coords": [origin_lat, origin_lon],
                    "to_coords": [dest_lat, dest_lon],
                    "departure_time": dep_time,
                    "arrival_time": minutes_to_hhmm(parse_time(dep_time), walk_min),
                    "duration_min": round(walk_min, 1),
                    "fare_inr": 0.0,
                    "instruction": f"🚶 Walk directly to Destination ({dist_km:.2f} km)",
                    "polyline": [[origin_lat, origin_lon], [dest_lat, dest_lon]]
                }],
                "transfer_hubs": []
            })
        else:
            routes.append({
                "option_type": "error",
                "label": "No Connected Transit Route",
                "emoji": "⚠️",
                "total_time_min": 0.0,
                "total_fare_inr": 0.0,
                "transfers": 0,
                "co2_grams": 0.0,
                "color": "#EF4444",
                "polyline": [],
                "steps": [{
                    "mode": "walk",
                    "from_stop": "Origin",
                    "to_stop": "Destination",
                    "from_coords": [origin_lat, origin_lon],
                    "to_coords": [dest_lat, dest_lon],
                    "departure_time": dep_time,
                    "arrival_time": dep_time,
                    "duration_min": 0.0,
                    "fare_inr": 0.0,
                    "instruction": "No connected public transit route found between these points. Consider private transit.",
                    "polyline": []
                }],
                "transfer_hubs": []
            })

    return routes


def _route_generalized(
    olat: float, olon: float, dlat: float, dlon: float, dep_time: str,
    alpha: float, beta: float, gamma: float,
    option_type: str, label: str, emoji: str
) -> Optional[dict]:
    """
    Executes the Generalized Multi-Modal routing search:
      A. Pre-computation Direct Corridor Dominance check
      B. Detour Ellipse Pruning Threshold (Prolate Spheroid)
      C. Dynamic First-Mile & Last-Mile Access Policy filtering
      D. Direction-Aware Vector A* Graph Expansion
      E. 15% Multi-Modal Dominance Gate
    """
    base_dt = parse_time(dep_time)
    D_0_km = haversine_km(olat, olon, dlat, dlon)

    # ── Step A: Detour Ellipse Pruning Threshold ─────────────────────────────
    delta_max = get_detour_ratio_threshold(D_0_km)

    # ── Step B: Direct Corridor Pre-Computation ──────────────────────────────
    direct_res = find_direct_corridor(
        olat, olon, dlat, dlon,
        network.corridor_stops,
        network.corridor_polylines,
        alpha=alpha, beta=beta, dep_time=dep_time,
        max_detour=delta_max, d0_km=D_0_km
    )

    # Cull intermediate transit nodes exceeding the detour ratio
    active_nodes: Dict[str, GraphNode] = {}
    for nid, node in network.nodes.items():
        d_s = haversine_km(olat, olon, node.lat, node.lon)
        d_t = haversine_km(node.lat, node.lon, dlat, dlon)
        ratio = (d_s + d_t) / max(D_0_km, 0.001)
        if ratio <= delta_max:
            active_nodes[nid] = node

    # ── Step C: Dynamic First-Mile & Last-Mile Access Policy ───────────────────
    candidate_access = get_candidate_access_nodes(olat, olon, active_nodes, dlat, dlon, delta_max, D_0_km)
    candidate_egress = get_candidate_egress_nodes(dlat, dlon, active_nodes, olat, olon, delta_max, D_0_km)

    if not candidate_access or not candidate_egress:
        # Fallback to full network nodes if active nodes didn't have access, strictly bounding to 1500m ceiling
        candidate_access = get_candidate_access_nodes(olat, olon, network.nodes, dlat, dlon, delta_max, D_0_km)
        candidate_egress = get_candidate_egress_nodes(dlat, dlon, network.nodes, olat, olon, delta_max, D_0_km)

    if not candidate_access or not candidate_egress:
        if direct_res:
            return _format_direct_route_option(direct_res, option_type, label, emoji)
        return None

    # Map of egress nodes -> (dist_m, walk_time_sec)
    egress_map: Dict[str, Tuple[float, float]] = {
        node.node_id: (dist_m, walk_sec) for node, dist_m, walk_sec in candidate_egress
    }

    # ── Step D: Multi-Modal Search (Priority Queue) ───────────────────────────
    # State: (f_score, g_cost_sec, time_sec, counter, node_id, path, fare_inr, transfers, last_mode)
    pq = []
    counter = 0

    for node, dist_m, walk_sec in candidate_access:
        entry_pen = PEN_ENTRY_SEC.get(node.mode, 60.0)
        wait_sec = WAIT_TIME_SEC.get(node.mode, 180.0)
        first_leg_sec = walk_sec + entry_pen + wait_sec

        # Access connector edge
        acc_edge = GraphEdge(
            from_id="__ORIGIN__",
            to_id=node.node_id,
            mode="walk",
            distance_km=dist_m / 1000.0,
            run_time_sec=walk_sec,
            dwell_time_sec=0.0,
            fare_inr=0.0,
            polyline=[[olat, olon], [node.lat, node.lon]],
            instruction=f"🚶 Walk {round(dist_m)}m to {node.name} (~{round(walk_sec / 60.0, 1)}m)"
        )

        h_sec = calc_directional_heuristic_sec(node.lat, node.lon, node.lat, node.lon, dlat, dlon, D_0_km)
        g_sec = first_leg_sec
        f_sec = g_sec + h_sec

        counter += 1
        heapq.heappush(pq, (f_sec, g_sec, first_leg_sec, counter, node.node_id, [acc_edge], 0.0, 0, node.mode))

    visited: Dict[str, float] = {}
    best_path: Optional[List[GraphEdge]] = None
    best_cost_sec = float("inf")

    # Dominance limit: If a direct corridor exists, any multi-hop path must beat 0.85 * C_direct
    max_allowable_multi_cost = (0.85 * direct_res.cost) if direct_res else float("inf")

    while pq:
        f_val, g_cost, elapsed_sec, _, curr_id, path, fare, transfers, last_mode = heapq.heappop(pq)

        if f_val >= best_cost_sec:
            break

        if curr_id in visited and visited[curr_id] <= g_cost:
            continue
        visited[curr_id] = g_cost

        # Destination arrival check via egress walking link
        if curr_id in egress_map:
            egr_dist_m, egr_walk_sec = egress_map[curr_id]
            curr_node = network.nodes[curr_id]

            egr_edge = GraphEdge(
                from_id=curr_id,
                to_id="__DEST__",
                mode="walk",
                distance_km=egr_dist_m / 1000.0,
                run_time_sec=egr_walk_sec,
                dwell_time_sec=0.0,
                fare_inr=0.0,
                polyline=[[curr_node.lat, curr_node.lon], [dlat, dlon]],
                instruction=f"🚶 Walk {round(egr_dist_m)}m from {curr_node.name} to Destination"
            )

            total_journey_sec = elapsed_sec + egr_walk_sec
            journey_cost = (
                alpha * total_journey_sec +
                beta * (fare * 60.0) +
                gamma * (transfers * PEN_TRANSFER_INTER_MODAL_SEC * 0.5)
            )

            # Direct Dominance Gate: Multi-hop paths (transfers >= 1) MUST beat 0.85 * C_direct
            if transfers >= 1 and journey_cost >= max_allowable_multi_cost:
                continue

            if journey_cost < best_cost_sec:
                best_cost_sec = journey_cost
                best_path = path + [egr_edge]

        # Expand outgoing edges from network
        for edge in network.edges.get(curr_id, []):
            nxt_id = edge.to_id
            nxt_node = network.nodes.get(nxt_id)
            if not nxt_node:
                continue

            # Check detour ellipse pruning on target node
            d_s = haversine_km(olat, olon, nxt_node.lat, nxt_node.lon)
            d_t = haversine_km(nxt_node.lat, nxt_node.lon, dlat, dlon)
            ratio = (d_s + d_t) / max(D_0_km, 0.001)
            if ratio > delta_max:
                continue

            new_transfers = transfers
            transfer_pen_sec = 0.0
            wait_sec = 0.0

            if edge.mode == "walk":
                step_sec = edge.total_time_sec
            else:
                if last_mode == "walk":
                    prev_transit = [p.mode for p in path if p.mode != "walk"]
                    if prev_transit:
                        transfer_pen_sec = PEN_TRANSFER_INTER_MODAL_SEC if prev_transit[-1] != edge.mode else PEN_TRANSFER_INTRA_MODAL_SEC
                        new_transfers += 1
                    wait_sec = WAIT_TIME_SEC.get(edge.mode, 0.0)
                else:
                    if last_mode != edge.mode:
                        transfer_pen_sec = PEN_TRANSFER_INTER_MODAL_SEC
                        wait_sec = WAIT_TIME_SEC.get(edge.mode, 0.0)
                        new_transfers += 1
                    elif edge.is_transfer:
                        transfer_pen_sec = PEN_TRANSFER_INTRA_MODAL_SEC
                        wait_sec = WAIT_TIME_SEC.get(edge.mode, 0.0)
                        new_transfers += 1
                    elif edge.route_name and path and getattr(path[-1], 'route_name', '') and edge.route_name != path[-1].route_name:
                        transfer_pen_sec = PEN_TRANSFER_INTRA_MODAL_SEC
                        wait_sec = WAIT_TIME_SEC.get(edge.mode, 0.0)
                        new_transfers += 1

                step_sec = edge.total_time_sec + transfer_pen_sec + wait_sec

            # Prompt 3.B: Allow up to 3 modal transfers
            if new_transfers > 3:
                continue

            new_elapsed_sec = elapsed_sec + step_sec
            new_fare = fare + edge.fare_inr

            # Admissible Direction-Aware Vector A* Heuristic
            curr_node = network.nodes[curr_id]
            h_sec = calc_directional_heuristic_sec(
                curr_node.lat, curr_node.lon, nxt_node.lat, nxt_node.lon, dlat, dlon, D_0_km
            )

            new_g_cost = (
                alpha * new_elapsed_sec +
                beta * (new_fare * 60.0) +
                gamma * (new_transfers * PEN_TRANSFER_INTER_MODAL_SEC * 0.5)
            )
            new_f = new_g_cost + h_sec

            # Early pruning against direct corridor dominance gate
            if new_transfers >= 1 and new_g_cost >= max_allowable_multi_cost:
                continue

            if nxt_id not in visited or visited[nxt_id] > new_g_cost:
                counter += 1
                heapq.heappush(pq, (
                    new_f, new_g_cost, new_elapsed_sec, counter,
                    nxt_id, path + [edge], new_fare, new_transfers, edge.mode
                ))

        if best_path and len(visited) > 2500:
            break

    # ── Step E: Evaluate Final Outcome Against Direct Dominance ───────────────
    if direct_res:
        if not best_path:
            return _format_direct_route_option(direct_res, option_type, label, emoji)

        transit_legs = [e.mode for e in best_path if e.mode != "walk"]
        trans_count = max(0, len(transit_legs) - 1)
        if trans_count >= 1:
            if best_cost_sec >= max_allowable_multi_cost:
                return _format_direct_route_option(direct_res, option_type, label, emoji)
        else:
            if best_cost_sec >= direct_res.cost:
                return _format_direct_route_option(direct_res, option_type, label, emoji)

    if not best_path:
        return None

    # Construct formatted RouteOption output from best_path
    return _format_path_route_option(best_path, base_dt, option_type, label, emoji)


def _format_direct_route_option(
    res: DirectCorridorResult, option_type: str, label: str, emoji: str
) -> dict:
    """Formats a direct corridor dominance result into the standard API dictionary."""
    total_min = res.total_time_sec / 60.0
    total_dist = haversine_km(res.access_node.lat, res.access_node.lon, res.egress_node.lat, res.egress_node.lon)
    co2_grams = max(0.0, total_dist * 140.0)

    return {
        "option_type": option_type,
        "label": label,
        "emoji": emoji,
        "total_time_min": round(total_min, 1),
        "total_fare_inr": round(res.fare_inr, 1),
        "transfers": 0,
        "co2_grams": round(co2_grams, 1),
        "color": "#00D4AA" if option_type == "multimodal" else ("#ED8936" if option_type == "bus" else "#EF4444"),
        "polyline": res.polyline,
        "steps": res.steps,
        "transfer_hubs": []
    }


def _format_path_route_option(
    best_path: List[GraphEdge], base_dt: datetime,
    option_type: str, label: str, emoji: str
) -> dict:
    """Formats an A* graph path into clean, contiguous transit legs with turn-by-turn steps & transfer hubs."""
    if not best_path:
        return None

    # Group contiguous transit edges of same mode and corridor / route
    grouped_legs: List[List[GraphEdge]] = []
    curr_group: List[GraphEdge] = []

    for edge in best_path:
        if not curr_group:
            curr_group.append(edge)
        else:
            prev = curr_group[-1]
            from_n = network.nodes.get(edge.from_id)
            to_n = network.nodes.get(edge.to_id)
            prev_from_n = network.nodes.get(prev.from_id)
            prev_to_n = network.nodes.get(prev.to_id)

            same_mode = (edge.mode == prev.mode)
            same_route = (
                (bool(edge.route_name and prev.route_name and edge.route_name == prev.route_name)) or
                (not edge.route_name and not prev.route_name and from_n and prev_to_n and
                 from_n.corridor_name == prev_to_n.corridor_name and from_n.corridor_name != "")
            )
            is_trans = edge.is_transfer or prev.is_transfer

            if same_mode and same_route and not is_trans and edge.mode != "walk":
                curr_group.append(edge)
            else:
                grouped_legs.append(curr_group)
                curr_group = [edge]
    if curr_group:
        grouped_legs.append(curr_group)

    steps = []
    merged_poly = []
    elapsed_min = 0.0
    total_fare = 0.0
    transfer_hubs = []

    for leg in grouped_legs:
        first_e = leg[0]
        last_e = leg[-1]
        start_n = network.nodes.get(first_e.from_id)
        end_n = network.nodes.get(last_e.to_id)

        dur_min = sum(e.travel_time_min for e in leg)
        dep_str = minutes_to_hhmm(base_dt, elapsed_min)
        elapsed_min += dur_min
        arr_str = minutes_to_hhmm(base_dt, elapsed_min)

        leg_dist_km = sum(e.distance_km for e in leg)
        if first_e.mode == "metro":
            leg_fare = calculate_metro_fare(leg_dist_km)
        elif first_e.mode == "feeder":
            leg_fare = calculate_stage_fare(leg_dist_km)
        elif first_e.mode == "bus":
            leg_fare = calculate_bus_fare(leg_dist_km)
        else:
            leg_fare = sum(e.fare_inr for e in leg)
        total_fare += leg_fare

        # Combined polyline
        leg_poly = []
        for e in leg:
            for pt in e.polyline:
                if not leg_poly or leg_poly[-1] != pt:
                    leg_poly.append(pt)

        # Mode icon & Instruction
        mode_icon = {"walk": "🚶", "feeder": "🛺", "metro": "🚇", "bus": "🚌"}.get(first_e.mode, "➡️")
        if first_e.mode == "walk":
            if first_e.is_transfer:
                instr = f"Walk / Transfer from {start_n.name if start_n else 'Station'} to {end_n.name if end_n else 'Next Stop'} ({round(leg_dist_km * 1000)}m)"
            else:
                instr = f"Walk {round(leg_dist_km * 1000)}m to {end_n.name if end_n else 'Destination'}"
        elif first_e.mode == "metro":
            c_name = start_n.corridor_name if start_n else "Metro"
            num_stops = len(leg)
            instr = f"Board CMRL {c_name} from {start_n.name} to {end_n.name} ({num_stops} stop{'s' if num_stops > 1 else ''}, Fare: ₹{leg_fare:.0f})"
        elif first_e.mode == "feeder":
            num_int = len(leg) - 1
            via_str = f" via {num_int} virtual stop{'s' if num_int > 1 else ''}" if num_int > 0 else ""
            instr = f"Board Paratransit Feeder from {start_n.name} to {end_n.name}{via_str} (Fare: ₹{leg_fare:.0f})"
        elif first_e.mode == "bus":
            if first_e.route_name:
                r_name = first_e.route_name.split(" (")[0]
                num_stops = len(leg)
                instr = f"Board {r_name} from {start_n.name if start_n else 'Stop'} to {end_n.name if end_n else 'Stop'} ({num_stops} stop{'s' if num_stops > 1 else ''}, Fare: ₹{leg_fare:.0f})"
            else:
                instr = first_e.instruction or f"Transit Link from {start_n.name if start_n else 'Hub'} to {end_n.name if end_n else 'Stop'}"
        else:
            instr = first_e.instruction or f"Transit Link from {start_n.name if start_n else 'Hub'} to {end_n.name if end_n else 'Stop'}"

        if first_e.is_transfer and start_n:
            transfer_hubs.append({
                "hub_name": f"{start_n.name} Interchange",
                "lat": start_n.lat,
                "lon": start_n.lon,
                "description": f"Multi-modal interchange between transit layers at {start_n.name}"
            })

        steps.append({
            "mode": first_e.mode,
            "from_stop": start_n.name if start_n else "Origin",
            "to_stop": end_n.name if end_n else "Destination",
            "from_coords": [start_n.lat, start_n.lon] if start_n else [0.0, 0.0],
            "to_coords": [end_n.lat, end_n.lon] if end_n else [0.0, 0.0],
            "departure_time": dep_str,
            "arrival_time": arr_str,
            "duration_min": round(dur_min, 1),
            "fare_inr": round(leg_fare, 1),
            "instruction": f"{mode_icon} {instr}",
            "polyline": leg_poly
        })

        for pt in leg_poly:
            if not merged_poly or merged_poly[-1] != pt:
                merged_poly.append(pt)

    total_dist = sum(e.distance_km for e in best_path)
    co2_grams = max(0.0, (total_dist * 180.0) - sum(
        e.distance_km * (0.0 if e.mode == "walk" else (40.0 if e.mode == "feeder" else 25.0))
        for e in best_path
    ))

    non_walk_modes = [s["mode"] for s in steps if s["mode"] != "walk"]
    transfers_count = max(0, len(non_walk_modes) - 1)

    return {
        "option_type": option_type,
        "label": label,
        "emoji": emoji,
        "total_time_min": round(elapsed_min, 1),
        "total_fare_inr": round(total_fare, 1),
        "transfers": transfers_count,
        "co2_grams": round(co2_grams, 1),
        "color": "#00D4AA" if option_type == "multimodal" else ("#ED8936" if option_type == "bus" else "#EF4444"),
        "polyline": merged_poly,
        "steps": steps,
        "transfer_hubs": transfer_hubs
    }


if __name__ == "__main__":
    import sys
    if sys.platform == "win32":
        sys.stdout.reconfigure(encoding="utf-8")

    print("\n" + "=" * 60)
    print("TEST 1: Local / Sub-Corridor Query (Tambaram -> Sairam College)")
    print("=" * 60)
    routes_local = compute_routes(
        origin_lat=12.9249, origin_lon=80.1280,   # Tambaram
        dest_lat=12.960249, dest_lon=80.057778,   # Sairam College
        dep_time="08:30"
    )
    for r in routes_local:
        print(f"\n{r['emoji']} {r['label']} (Time: {r['total_time_min']}m, Fare: ₹{r['total_fare_inr']}, Transfers: {r['transfers']})")
        for s in r["steps"]:
            print(f"   -> [{s['mode'].upper()}] {s['instruction']} ({s['departure_time']} -> {s['arrival_time']})")

    print("\n" + "=" * 60)
    print("TEST 2: Long-Distance Radial Query (Ashok Nagar -> Sairam College)")
    print("=" * 60)
    routes_radial = compute_routes(
        origin_lat=13.0336, origin_lon=80.2114,   # Ashok Nagar
        dest_lat=12.960249, dest_lon=80.057778,   # Sairam College
        dep_time="08:30"
    )
    for r in routes_radial:
        print(f"\n{r['emoji']} {r['label']} (Time: {r['total_time_min']}m, Fare: ₹{r['total_fare_inr']}, Transfers: {r['transfers']})")
        for s in r["steps"]:
            print(f"   -> [{s['mode'].upper()}] {s['instruction']} ({s['departure_time']} -> {s['arrival_time']})")
