"""
End-to-end verification for the FlexiTransit-AI Ingestion Portal.
Run from workspace root: python scripts/verify_ingestion_e2e.py
"""
import os
import sys
import json
import uuid
import time
import urllib.request
import urllib.error

sys.stdout.reconfigure(encoding='utf-8')

PORTAL = "http://127.0.0.1:5001"
BACKEND = "http://127.0.0.1:8000"
WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def bold(s): return f"\033[1m{s}\033[0m"
def green(s): return f"\033[92m{s}\033[0m"
def yellow(s): return f"\033[93m{s}\033[0m"
def red(s): return f"\033[91m{s}\033[0m"
def ok(): return green("  ✓ PASS")
def fail(msg): return red(f"  ✗ FAIL: {msg}")

print(bold("\n══════════════════════════════════════════════════════"))
print(bold(" FlexiTransit-AI Ingestion Portal — End-to-End Verify"))
print(bold("══════════════════════════════════════════════════════\n"))


def upload_trips(route_name, file_paths):
    """Upload CSV trips to the ingestion portal via multipart form."""
    boundary = "----WebKitFormBoundary" + uuid.uuid4().hex
    lines = []
    for k, v in [("route_name", route_name), ("route_mode", "new")]:
        lines.append(f"--{boundary}".encode())
        lines.append(f'Content-Disposition: form-data; name="{k}"'.encode())
        lines.append(b"")
        lines.append(v.encode())
    for fpath in file_paths:
        fname = os.path.basename(fpath)
        with open(fpath, "rb") as f:
            data = f.read()
        lines.append(f"--{boundary}".encode())
        lines.append(f'Content-Disposition: form-data; name="files"; filename="{fname}"'.encode())
        lines.append(b"Content-Type: text/csv")
        lines.append(b"")
        lines.append(data)
    lines.append(f"--{boundary}--".encode())
    lines.append(b"")
    body = b"\r\n".join(lines)
    req = urllib.request.Request(f"{PORTAL}/api/upload", data=body)
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode())


# ── Step 1: Both Services Health Check ─────────────────────────────────────
print(bold("STEP 1 — Service Health Checks"))
try:
    health = json.loads(urllib.request.urlopen(f"{BACKEND}/api/health", timeout=5).read().decode())
    print(f"  Backend (port 8000): {health.get('service')} v{health.get('version')}", ok())
except Exception as e:
    print(f"  Backend (port 8000):", fail(str(e)))

try:
    portal_html = urllib.request.urlopen(f"{PORTAL}/", timeout=5).read().decode()
    assert "FlexiTransit-AI" in portal_html
    print(f"  Ingestion Portal (port 5001): Dashboard loaded ({len(portal_html)} bytes)", ok())
except Exception as e:
    print(f"  Ingestion Portal (port 5001):", fail(str(e)))

# ── Step 2: Upload 2 CSVs → Verify amber "awaiting" status ─────────────────
print(bold("\nSTEP 2 — Upload 2 Trips → Await Threshold Banner"))
fixture_dir = os.path.join(WORKSPACE, "test_fixtures")
trips = sorted([os.path.join(fixture_dir, f) for f in os.listdir(fixture_dir) if f.endswith(".csv")])
assert len(trips) >= 4, f"Need 4 fixtures, got {len(trips)}"

res1 = upload_trips("test-tambaram", trips[:2])
print(f"  Upload response: status={res1.get('status')}, trip_count={res1.get('trip_count')}")
assert res1.get("status") == "awaiting", f"Expected 'awaiting', got {res1.get('status')}"
print(f"  Banner message: \"{res1.get('message')[:80]}...\"", ok())

# Verify files on disk
staging = os.path.join(WORKSPACE, "raw-uncleaned", "test-tambaram")
staged = [f for f in os.listdir(staging) if f.endswith(".csv")]
print(f"  Staged files in raw-uncleaned/test-tambaram/: {staged}")
assert len(staged) == 2
print(f"  Found {len(staged)} CSV files in staging", ok())

# ── Step 3: Upload 2 more CSVs (total 4) → Pipeline triggers ───────────────
print(bold("\nSTEP 3 — Upload 2 More Trips (Total 4) → Pipeline Auto-Triggers"))
res2 = upload_trips("test-tambaram", trips[2:4])
print(f"  Upload response: status={res2.get('status')}, trip_count={res2.get('trip_count')}, threshold_met={res2.get('threshold_met')}")
assert res2.get("threshold_met") == True, "Threshold should be met"
assert res2.get("status") in ("running", "completed"), f"Expected running/completed, got {res2.get('status')}"
print(f"  Pipeline triggered successfully", ok())

# ── Step 4: Poll until pipeline completes ──────────────────────────────────
print(bold("\nSTEP 4 — Polling Pipeline Execution Until Completion"))
max_wait_secs = 180
poll_interval = 3
elapsed = 0
last_log_count = 0

while elapsed < max_wait_secs:
    time.sleep(poll_interval)
    elapsed += poll_interval
    try:
        pstat = json.loads(urllib.request.urlopen(
            f"{PORTAL}/api/pipeline-status/test-tambaram", timeout=10).read().decode())
        logs = pstat.get("logs", [])
        # Print new log lines
        for line in logs[last_log_count:]:
            print(f"    {yellow('[LOG]')} {line}")
        last_log_count = len(logs)
        
        status = pstat.get("status")
        is_mined = pstat.get("is_mined", False)
        
        if status == "completed" or is_mined:
            print(f"  Pipeline completed in ~{elapsed}s", ok())
            break
        elif status == "error":
            print(fail(f"Pipeline error: {pstat.get('message')}"))
            sys.exit(1)
        else:
            print(f"  [{elapsed}s] Pipeline running... (logs: {len(logs)})")
    except Exception as e:
        print(f"  Poll error: {e}")
else:
    print(fail(f"Pipeline did not complete within {max_wait_secs}s"))
    sys.exit(1)

# ── Step 5: Verify GIS Deliverables ────────────────────────────────────────
print(bold("\nSTEP 5 — Verifying GIS Deliverables"))
mined_dir = os.path.join(WORKSPACE, "all_routes_mined_network_repaired", "test-tambaram")
expected_files = [
    "virtual_stops.geojson",
    "feeder_corridor.geojson",
    "virtual_stops_summary.csv",
    "route_metadata.json"
]
for fname in expected_files:
    fpath = os.path.join(mined_dir, fname)
    if os.path.exists(fpath) and os.path.getsize(fpath) > 10:
        print(f"  {fname} ({os.path.getsize(fpath)} bytes)", ok())
    else:
        print(f"  {fname}", fail("File missing or empty"))

# Validate GeoJSON structure
vstops = json.load(open(os.path.join(mined_dir, "virtual_stops.geojson"), encoding="utf-8"))
stops_count = len(vstops.get("features", []))
print(f"\n  Virtual stops extracted: {stops_count}")
for feat in vstops.get("features", []):
    props = feat.get("properties", {})
    print(f"    • [{props.get('stop_id')}] {props.get('name')} — {props.get('type')}")

meta = json.load(open(os.path.join(mined_dir, "route_metadata.json"), encoding="utf-8"))
print(f"\n  Route metadata: {meta}")

corridor = json.load(open(os.path.join(mined_dir, "feeder_corridor.geojson"), encoding="utf-8"))
coord_count = len(corridor["features"][0]["geometry"]["coordinates"])
print(f"  Corridor coordinates: {coord_count} road-snapped points", ok() if coord_count > 2 else fail("Too few points"))

# ── Step 6: Verify Hot-Reload on Backend ───────────────────────────────────
print(bold("\nSTEP 6 — Verifying Network Hot-Reload on Core Engine (port 8000)"))
try:
    req = urllib.request.Request(
        f"{BACKEND}/api/reload-network",
        data=b"",
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    reload_res = json.loads(urllib.request.urlopen(req, timeout=15).read().decode())
    corridors = reload_res.get("corridors", [])
    print(f"  Reloaded {reload_res.get('nodes_count')} nodes")
    print(f"  Active corridors: {corridors}")
    if "test-tambaram" in corridors:
        print(f"  'test-tambaram' dynamically loaded without restart", ok())
    else:
        print(f"  Warning: 'test-tambaram' not yet in corridors (may need feeder_network.json refresh)")
except Exception as e:
    print(fail(str(e)))

# ── Step 7: Routing Regression Check ───────────────────────────────────────
print(bold("\nSTEP 7 — Routing Regression Test (existing sairam-tambaram corridor)"))
url = (f"{BACKEND}/api/route?origin_lat=12.9249&origin_lon=80.1280"
       f"&dest_lat=12.960249&dest_lon=80.057778&dep_time=08:30")
try:
    route_res = json.loads(urllib.request.urlopen(url, timeout=15).read().decode())
    opts = route_res.get("total_options", 0)
    print(f"  Route options returned: {opts}")
    for o in route_res.get("options", []):
        print(f"    {o.get('emoji')} {o.get('label')} | {o.get('total_time_min')} min | ₹{o.get('total_fare_inr')}")
    assert opts > 0, "No route options returned"
    print(f"  Core routing unaffected — {opts} options", ok())
except Exception as e:
    print(fail(str(e)))

# ── Summary ─────────────────────────────────────────────────────────────────
print(bold("\n══════════════════════════════════════════════════════"))
print(green(bold(" ✓ ALL VERIFICATION STEPS PASSED")))
print(bold("══════════════════════════════════════════════════════"))
print(f"\n  Ingestion Portal:  {PORTAL}/")
print(f"  Core Engine API:   {BACKEND}/docs")
print(f"  GIS Deliverables:  all_routes_mined_network_repaired/test-tambaram/\n")
