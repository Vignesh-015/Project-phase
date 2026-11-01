import os
import sys

# Test script for cross-city multi-hop routing
base_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, base_dir)
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

import router

print("Network nodes before load:", len(router.network.nodes))
router.network.load_network()
print("Network nodes after load:", len(router.network.nodes))
print("Network edges after load:", sum(len(e) for e in router.network.edges.values()))

# Test 1: Sairam College -> Besant Nagar Terminus (~23 km)
sairam_lat, sairam_lon = 12.960249, 80.057778
besant_lat, besant_lon = 13.00033, 80.26607

delta_max = router.get_detour_ratio_threshold(router.haversine_km(sairam_lat, sairam_lon, besant_lat, besant_lon))
print(f"delta_max: {delta_max}")
acc = router.get_candidate_access_nodes(sairam_lat, sairam_lon, router.network.nodes, besant_lat, besant_lon, delta_max, router.haversine_km(sairam_lat, sairam_lon, besant_lat, besant_lon))
print("Access candidates:", [(n.node_id, n.name, round(d)) for n, d, _ in acc])
egr = router.get_candidate_egress_nodes(besant_lat, besant_lon, router.network.nodes, sairam_lat, sairam_lon, delta_max, router.haversine_km(sairam_lat, sairam_lon, besant_lat, besant_lon))
print("Egress candidates:", [(n.node_id, n.name, round(d)) for n, d, _ in egr])

routes = router.compute_routes(sairam_lat, sairam_lon, besant_lat, besant_lon, "08:00")
print(f"\nRoutes from Sairam to Besant Nagar (Total: {len(routes)}):")
for i, r in enumerate(routes):
    print(f"\nOption {i+1}: {r.get('label')} ({r.get('option_type')})")
    print(f"  Time: {r.get('total_time_min')} min | Fare: Rs {r.get('total_fare_inr')} | Transfers: {r.get('transfers')}")
    for step in r.get('steps', []):
        print(f"    - [{step.get('mode')}] {step.get('instruction')} ({step.get('duration_min')} min)")

# Test 2: Local Corridor (Sairam College -> Tambaram)
tambaram_lat, tambaram_lon = 12.92805, 80.11933
local_routes = router.compute_routes(sairam_lat, sairam_lon, tambaram_lat, tambaram_lon, "08:00")
print(f"\nRoutes from Sairam to Tambaram (Total: {len(local_routes)}):")
for i, r in enumerate(local_routes):
    print(f"\nOption {i+1}: {r.get('label')} ({r.get('option_type')})")
    print(f"  Time: {r.get('total_time_min')} min | Fare: Rs {r.get('total_fare_inr')} | Transfers: {r.get('transfers')}")
    for step in r.get('steps', []):
        print(f"    - [{step.get('mode')}] {step.get('instruction')} ({step.get('duration_min')} min)")
