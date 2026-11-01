import urllib.request
import json
import sys

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")

url = "http://localhost:8000/api/route?origin_lat=13.0336&origin_lon=80.2114&dest_lat=12.960249&dest_lon=80.057778&dep_time=08:30"
res = json.loads(urllib.request.urlopen(url).read().decode("utf-8"))

print(f"Total options: {res.get('total_options')}")
for opt in res.get("options", []):
    print(f"\n{opt.get('emoji')} {opt.get('label')}: {opt.get('total_time_min')} min | ₹{opt.get('total_fare_inr')} | Polyline Points: {len(opt.get('polyline', []))}")
    for s in opt.get("steps", []):
        print(f"   -> [{s.get('mode').upper()}] {s.get('instruction')} ({s.get('departure_time')} -> {s.get('arrival_time')})")
