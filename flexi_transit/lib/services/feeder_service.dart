import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import '../models/models.dart';

/// Service managing mined informal paratransit feeder networks
/// (virtual stops and snapped road centerlines from all_routes_mined_network_repaired)
class FeederService {
  static bool _loaded = false;
  static List<FeederCorridor> _corridors = [];
  static List<VirtualFeederStop> _stops = [];

  static bool get isLoaded => _loaded;
  static List<FeederCorridor> get corridors => _corridors;
  static List<VirtualFeederStop> get stops => _stops;

  static const double earthRadiusKm = 6371.0;

  static double haversineKm(double lat1, double lon1, double lat2, double lon2) {
    final dLat = (lat2 - lat1) * (pi / 180.0);
    final dLon = (lon2 - lon1) * (pi / 180.0);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * (pi / 180.0)) *
            cos(lat2 * (pi / 180.0)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return 2 * earthRadiusKm * asin(sqrt(a));
  }

  static Future<void> loadData() async {
    if (_loaded) return;
    try {
      final jsonString =
          await rootBundle.loadString('assets/data/feeder_network.json');
      final data = json.decode(jsonString);

      final rawCorridors = data['corridors'] as List? ?? [];
      final rawStops = data['stops'] as List? ?? [];

      _corridors = rawCorridors
          .map((c) => FeederCorridor.fromJson(c as Map<String, dynamic>))
          .toList();

      _stops = rawStops
          .map((s) => VirtualFeederStop.fromJson(s as Map<String, dynamic>))
          .toList();

      _loaded = true;
    } catch (e) {
      // Fallback in case asset load has delay
      _corridors = [];
      _stops = [];
    }
  }

  static List<VirtualFeederStop> getStopsNearPoint(
      LatLng point, double radiusKm) {
    return _stops.where((s) {
      final d = haversineKm(point.latitude, point.longitude, s.lat, s.lon);
      return d <= radiusKm;
    }).toList();
  }

  static VirtualFeederStop? getNearestStop(LatLng point) {
    if (_stops.isEmpty) return null;
    VirtualFeederStop? best;
    double bestDist = double.infinity;
    for (final s in _stops) {
      final d = haversineKm(point.latitude, point.longitude, s.lat, s.lon);
      if (d < bestDist) {
        bestDist = d;
        best = s;
      }
    }
    return best;
  }

  static FeederCorridor? getCorridor(String name) {
    for (final c in _corridors) {
      if (c.corridorName == name) return c;
    }
    return null;
  }

  /// Extracts the exact snapped road polyline segment from a corridor between two stops.
  static List<List<double>> getCorridorSlice(
      String corridorName, VirtualFeederStop from, VirtualFeederStop to) {
    final corridor = getCorridor(corridorName);
    if (corridor == null || corridor.polyline.isEmpty) {
      return [
        [from.lat, from.lon],
        [to.lat, to.lon]
      ];
    }

    final poly = corridor.polyline;
    int idxFrom = -1;
    int idxTo = -1;
    double minDFrom = double.infinity;
    double minDTo = double.infinity;

    for (int i = 0; i < poly.length; i++) {
      final dF = haversineKm(from.lat, from.lon, poly[i][0], poly[i][1]);
      if (dF < minDFrom) {
        minDFrom = dF;
        idxFrom = i;
      }
      final dT = haversineKm(to.lat, to.lon, poly[i][0], poly[i][1]);
      if (dT < minDTo) {
        minDTo = dT;
        idxTo = i;
      }
    }

    if (idxFrom != -1 && idxTo != -1) {
      if (idxFrom <= idxTo) {
        return poly.sublist(idxFrom, idxTo + 1);
      } else {
        return poly.sublist(idxTo, idxFrom + 1).reversed.toList();
      }
    }

    return poly;
  }

  /// Identifies transfer hubs between paratransit virtual stops and CMRL metro stations (<= 400m)
  static List<TransferHub> findTransferHubs(List<CmrlStop> metroStops,
      {double maxDistMeters = 400.0}) {
    final hubs = <TransferHub>[];
    for (final vStop in _stops) {
      for (final mStop in metroStops) {
        final distM =
            haversineKm(vStop.lat, vStop.lon, mStop.lat, mStop.lon) * 1000.0;
        if (distM <= maxDistMeters) {
          hubs.add(TransferHub(
            hubName: '${mStop.stopName} Interchange',
            lat: mStop.lat,
            lon: mStop.lon,
            description:
                '${vStop.stopName} ⇋ ${mStop.stopName} Metro concourse (${distM.round()}m walk)',
          ));
        }
      }
    }
    return hubs;
  }

  /// Returns primary origin stand and destination stand for each mined route.
  static List<FeederStand> getPrimaryStands() {
    final list = <FeederStand>[];

    // Canonical terminus stands for mined routes
    final canonicalStands = [
      const FeederStand(
        id: 'STAND_SAIRAM',
        standName: 'Sairam College Feeder Stand',
        routeName: 'Sairam – Tambaram Corridor',
        point: LatLng(12.960249, 80.057778),
        isOrigin: true,
      ),
      const FeederStand(
        id: 'STAND_TAMBARAM',
        standName: 'Tambaram Feeder Stand',
        routeName: 'Sairam – Tambaram Corridor',
        point: LatLng(12.930233, 80.119513),
        isOrigin: false,
      ),
      const FeederStand(
        id: 'STAND_KASI',
        standName: 'Kasi Theatre Feeder Stand',
        routeName: 'Kasi Theatre – Ekkattuthangal Corridor',
        point: LatLng(13.031697, 80.210167),
        isOrigin: true,
      ),
      const FeederStand(
        id: 'STAND_EKATU',
        standName: 'Ekkattuthangal Feeder Stand',
        routeName: 'Kasi Theatre – Ekkattuthangal Corridor',
        point: LatLng(13.023249, 80.205734),
        isOrigin: false,
      ),
    ];
    list.addAll(canonicalStands);

    // Also deduplicate and append any other dynamically loaded terminal stops
    for (final s in _stops) {
      if (!s.stopType.contains('TERMINAL')) continue;
      final pt = LatLng(s.lat, s.lon);
      final exists = list.any((st) =>
          haversineKm(st.point.latitude, st.point.longitude, pt.latitude, pt.longitude) < 0.25);
      if (!exists) {
        list.add(FeederStand(
          id: s.stopId,
          standName: '${s.stopName} Feeder Stand',
          routeName: s.corridorName,
          point: pt,
          isOrigin: s.stopType.contains('ORIGIN'),
        ));
      }
    }

    return list;
  }
}

/// Primary auto stand terminus for mined paratransit corridor
class FeederStand {
  final String id;
  final String standName;
  final String routeName;
  final LatLng point;
  final bool isOrigin;

  const FeederStand({
    required this.id,
    required this.standName,
    required this.routeName,
    required this.point,
    required this.isOrigin,
  });
}

