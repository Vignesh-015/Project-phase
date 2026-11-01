import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import '../models/models.dart';

/// Loads and provides access to MTC GTFS data bundled as JSON assets.
class MtcService {
  static List<MtcStop> _stops = [];
  static List<MtcRoute> _routes = [];
  static Map<String, List<String>> _stopRoutes = {};
  static bool _loaded = false;

  /// Load all MTC data from Flutter assets. Call once at app startup.
  static Future<void> loadData() async {
    if (_loaded) return;

    try {
      // Load stops
      final stopsJson = await rootBundle.loadString('assets/data/mtc_stops.json');
      final stopsList = json.decode(stopsJson) as List;
      _stops = stopsList.map((e) => MtcStop.fromJson(e)).toList();

      // Load routes
      final routesJson = await rootBundle.loadString('assets/data/mtc_routes.json');
      final routesList = json.decode(routesJson) as List;
      _routes = routesList.map((e) => MtcRoute.fromJson(e)).toList();

      // Load stop→routes index
      final stopRoutesJson =
          await rootBundle.loadString('assets/data/mtc_stop_routes.json');
      final rawMap = json.decode(stopRoutesJson) as Map<String, dynamic>;
      _stopRoutes = rawMap.map(
        (k, v) => MapEntry(k, (v as List).map((e) => e.toString()).toList()),
      );

      _loaded = true;
    } catch (e) {
      // Gracefully degrade if assets aren't available
      _stops = [];
      _routes = [];
      _stopRoutes = {};
      _loaded = true;
    }
  }

  /// All MTC bus stops.
  static List<MtcStop> get stops => _stops;

  /// All MTC routes.
  static List<MtcRoute> get routes => _routes;

  /// Returns route short names for a given stop ID.
  static List<String> getRoutesForStop(String stopId) {
    return _stopRoutes[stopId] ?? [];
  }

  /// Returns stops within [radiusKm] kilometers of [center].
  /// Results are sorted by distance (nearest first).
  static List<MtcStop> getStopsNearPoint(LatLng center, double radiusKm) {
    final results = <_ScoredStop>[];

    for (final stop in _stops) {
      final dist = _haversineKm(center.latitude, center.longitude, stop.lat, stop.lon);
      if (dist <= radiusKm) {
        results.add(_ScoredStop(stop, dist));
      }
    }

    results.sort((a, b) => a.dist.compareTo(b.dist));
    return results.map((s) => s.stop).toList();
  }

  /// Returns stops visible within a map bounding box (fast, no sqrt needed).
  static List<MtcStop> getStopsInBounds({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
  }) {
    return _stops.where((s) {
      return s.lat >= minLat &&
          s.lat <= maxLat &&
          s.lon >= minLon &&
          s.lon <= maxLon;
    }).toList();
  }

  /// Number of stops loaded.
  static int get stopCount => _stops.length;

  /// Whether data has been loaded.
  static bool get isLoaded => _loaded;
}

class _ScoredStop {
  final MtcStop stop;
  final double dist;
  _ScoredStop(this.stop, this.dist);
}

/// Haversine distance in km between two lat/lon points.
double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const R = 6371.0;
  final dLat = _toRad(lat2 - lat1);
  final dLon = _toRad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_toRad(lat1)) *
          math.cos(_toRad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return R * c;
}

double _toRad(double deg) => deg * math.pi / 180;
