"""
Standalone test script to verify generalized multi-modal router logic.
"""
import math

EARTH_RADIUS_KM = 6371.0

def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(math.sqrt(max(0.0, min(1.0, a))))

def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    return haversine_km(lat1, lon1, lat2, lon2) * 1000.0

# 1. Test Detour Ellipse
# Tambaram to Sairam
tambaram = (12.9249, 80.1280)
sairam = (12.9602, 80.0578)
d0 = haversine_km(tambaram[0], tambaram[1], sairam[0], sairam[1])
print(f"Tambaram -> Sairam D0: {d0:.2f} km")

# Airport Metro
airport = (12.9818, 80.1633)
d_s_m = haversine_km(tambaram[0], tambaram[1], airport[0], airport[1])
d_m_t = haversine_km(airport[0], airport[1], sairam[0], sairam[1])
detour_ratio = (d_s_m + d_m_t) / d0
threshold = 1.30 if d0 <= 5.0 else (1.45 if d0 <= 15.0 else 1.60)
print(f"Airport Metro detour ratio for Tambaram->Sairam: {detour_ratio:.2f} (Threshold: {threshold}) -> Culled? {detour_ratio > threshold}")

# 2. Test Directional Heuristic
def calc_phi(u, v, T):
    lat_rad = math.radians(u[0])
    vec_uT = (T[0] - u[0], (T[1] - u[1]) * math.cos(lat_rad))
    vec_uv = (v[0] - u[0], (v[1] - u[1]) * math.cos(lat_rad))
    mag_uT = math.hypot(vec_uT[0], vec_uT[1])
    mag_uv = math.hypot(vec_uv[0], vec_uv[1])
    if mag_uT < 1e-9 or mag_uv < 1e-9:
        return 1.0
    dot = vec_uT[0] * vec_uv[0] + vec_uT[1] * vec_uv[1]
    cos_theta = max(-1.0, min(1.0, dot / (mag_uT * mag_uv)))
    return 1.0 + 0.5 * max(0.0, 1.0 - cos_theta)

# Towards dest (theta ~ 0)
v_toward = (tambaram[0] + (sairam[0]-tambaram[0])*0.1, tambaram[1] + (sairam[1]-tambaram[1])*0.1)
phi_toward = calc_phi(tambaram, v_toward, sairam)
print(f"Phi toward dest: {phi_toward:.2f}")

# Away from dest (theta ~ 180)
v_away = (tambaram[0] - (sairam[0]-tambaram[0])*0.1, tambaram[1] - (sairam[1]-tambaram[1])*0.1)
phi_away = calc_phi(tambaram, v_away, sairam)
print(f"Phi away from dest: {phi_away:.2f}")
