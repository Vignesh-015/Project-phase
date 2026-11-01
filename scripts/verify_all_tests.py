"""
Verification and Test Matrix Suite for FlexiTransit-AI Multi-Modal Router
Validates the 5 required test cases:
  1. Tambaram -> Besant Nagar
  2. Tambaram -> Selaiyur (Camp Road)
  3. Sairam College -> Tambaram
  4. Sairam College -> Besant Nagar
  5. Ashok Nagar -> Airport
"""

import sys
import os

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")

# Add backend directory to sys.path
backend_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "backend"))
if backend_dir not in sys.path:
    sys.path.insert(0, backend_dir)

from router import compute_routes

TEST_CASES = [
    {
        "id": "Test 1",
        "name": "Tambaram -> Besant Nagar",
        "origin": (12.9280, 80.1193),   # Tambaram West Bus Stand
        "destination": (13.0003, 80.2660), # Besant Nagar Terminus
        "expected": "Feeder / Suburban Rail / MTC Bus (21G corridor)",
        "check": lambda routes: any(
            any(s["mode"] in ["bus", "metro"] for s in r.get("steps", []))
            for r in routes if r.get("option_type") != "error"
        ),
        "check_desc": "Must NOT regress. Transit itinerary must show valid bus/rail legs."
    },
    {
        "id": "Test 2",
        "name": "Tambaram -> Selaiyur (Camp Road)",
        "origin": (12.9249, 80.1280),   # East Tambaram
        "destination": (12.9224, 80.1431), # Camp Road Junction Selaiyur
        "expected": "Walk -> MTC Bus (along Velachery Main Rd) -> Walk",
        "check": lambda routes: any(
            any(s["mode"] == "bus" for s in r.get("steps", []))
            for r in routes if r.get("option_type") != "error"
        ),
        "check_desc": "Must NOT show pure walking. Must contain MTC bus segment."
    },
    {
        "id": "Test 3",
        "name": "Sairam College -> Tambaram",
        "origin": (12.960249, 80.057778), # Sairam College
        "destination": (12.9249, 80.1280),   # Tambaram
        "expected": "Walk -> Informal Feeder Auto -> Walk",
        "check": lambda routes: any(
            any(s["mode"] == "feeder" for s in r.get("steps", []))
            for r in routes if r.get("option_type") != "error"
        ),
        "check_desc": "Direct paratransit corridor maintained."
    },
    {
        "id": "Test 4",
        "name": "Sairam College -> Besant Nagar",
        "origin": (12.960249, 80.057778), # Sairam College
        "destination": (13.0003, 80.2660),   # Besant Nagar Terminus
        "expected": "Feeder Auto -> Tambaram -> MTC Bus / Suburban -> Besant Nagar",
        "check": lambda routes: any(
            any(s["mode"] == "feeder" for s in r.get("steps", [])) and
            any(s["mode"] in ["bus", "metro"] for s in r.get("steps", []))
            for r in routes if r.get("option_type") != "error"
        ),
        "check_desc": "Multi-modal transfer across Feeder + Formal network."
    },
    {
        "id": "Test 5",
        "name": "Ashok Nagar -> Airport",
        "origin": (13.0372, 80.2095),   # Ashok Nagar Metro Station
        "destination": (12.9808, 80.1642), # Airport Metro Station
        "expected": "CMRL Metro Blue/Green Line",
        "check": lambda routes: any(
            any(s["mode"] == "metro" for s in r.get("steps", []))
            for r in routes if r.get("option_type") != "error"
        ),
        "check_desc": "Metro line routing remains clean and direct."
    }
]


def run_tests():
    print("=" * 80)
    print("MTC BUS NETWORK GENERALIZATION & MULTI-MODAL ROUTER VERIFICATION SUITE")
    print("=" * 80)

    passed_count = 0
    total_count = len(TEST_CASES)

    for tc in TEST_CASES:
        print(f"\n--- {tc['id']}: {tc['name']} ---")
        print(f"Origin: {tc['origin']} | Destination: {tc['destination']}")
        print(f"Expected: {tc['expected']}")

        routes = compute_routes(
            origin_lat=tc["origin"][0],
            origin_lon=tc["origin"][1],
            dest_lat=tc["destination"][0],
            dest_lon=tc["destination"][1],
            dep_time="08:30"
        )

        passed = tc["check"](routes)
        if passed:
            print(f"RESULT: PASSED (Verified: {tc['check_desc']})")
            passed_count += 1
        else:
            print(f"RESULT: FAILED ({tc['check_desc']})")

        print(f"Returned {len(routes)} route option(s):")
        for r in routes:
            modes = [s["mode"] for s in r.get("steps", []) if s["mode"] != "walk"]
            print(f"  • {r['emoji']} {r['label']} (Time: {r['total_time_min']}m, Fare: ₹{r['total_fare_inr']}, Transfers: {r['transfers']}, Transit Modes: {modes})")
            for i, s in enumerate(r.get("steps", [])):
                print(f"      [{s['mode'].upper()}] {s['instruction']} ({s['departure_time']} -> {s['arrival_time']})")

    print("\n" + "=" * 80)
    print(f"FINAL SUMMARY: {passed_count}/{total_count} TESTS PASSED")
    print("=" * 80)
    return passed_count == total_count


if __name__ == "__main__":
    success = run_tests()
    if not success:
        sys.exit(1)
