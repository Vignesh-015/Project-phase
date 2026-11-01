import urllib.request
import json

def test_api():
    print("Testing /api/health...")
    with urllib.request.urlopen("http://localhost:8000/api/health", timeout=5) as resp:
        print("Health:", resp.read().decode("utf-8"))

    print("\nTesting /api/route for Tambaram -> Sairam (Local)...")
    url = "http://localhost:8000/api/route?origin_lat=12.9249&origin_lon=80.1280&dest_lat=12.960249&dest_lon=80.057778&dep_time=08:30"
    with urllib.request.urlopen(url, timeout=5) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        print(f"Total options: {data.get('total_options')}")
        for o in data.get("options", []):
            print(f"  {o.get('emoji')} {o.get('label')} | Time: {o.get('total_time_min')}m | Fare: ₹{o.get('total_fare_inr')} | Transfers: {o.get('transfers')}")

    print("\nTesting /api/route for Ashok Nagar -> Sairam (Radial)...")
    url2 = "http://localhost:8000/api/route?origin_lat=13.0336&origin_lon=80.2114&dest_lat=12.960249&dest_lon=80.057778&dep_time=08:30"
    with urllib.request.urlopen(url2, timeout=5) as resp:
        data2 = json.loads(resp.read().decode("utf-8"))
        print(f"Total options: {data2.get('total_options')}")
        for o in data2.get("options", []):
            print(f"  {o.get('emoji')} {o.get('label')} | Time: {o.get('total_time_min')}m | Fare: ₹{o.get('total_fare_inr')} | Transfers: {o.get('transfers')}")

if __name__ == "__main__":
    import sys
    if sys.platform == "win32":
        sys.stdout.reconfigure(encoding="utf-8")
    test_api()
