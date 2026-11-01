import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/models.dart';

/// OSM-Compatible OSRM Routing Engine Service
class RoutingService {
  static const String _osrmBaseUrl = 'https://router.project-osrm.org/route/v1/driving';

  /// Calculate routes from origin (lat, lon) to destination (lat, lon)
  static Future<List<OSRMRoute>> getRoutes({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
  }) async {
    try {
      final url = '$_osrmBaseUrl/$originLon,$originLat;$destLon,$destLat?overview=full&geometries=geojson&steps=true&alternatives=true';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final routesJson = data['routes'] as List? ?? [];
        final routes = <OSRMRoute>[];

        for (final r in routesJson) {
          final distance = (r['distance'] ?? 0).toDouble();
          final duration = (r['duration'] ?? 0).toDouble();
          final geometry = r['geometry']['coordinates'] as List? ?? [];
          
          final polyline = geometry
              .map((c) => [(c[1] as num).toDouble(), (c[0] as num).toDouble()])
              .toList();

          final steps = <OSRMStep>[];
          final legs = r['legs'] as List? ?? [];
          for (final leg in legs) {
            final legSteps = leg['steps'] as List? ?? [];
            for (final step in legSteps) {
              steps.add(OSRMStep.fromOsrmJson(step));
            }
          }

          routes.add(OSRMRoute(
            polyline: polyline,
            distanceMeters: distance,
            durationSeconds: duration,
            steps: steps,
          ));
        }

        return routes;
      }
    } catch (_) {
      // Fallback straight-line route if OSRM is temporarily offline/unreachable
    }

    // Straight-line fallback
    return [
      OSRMRoute(
        polyline: [
          [originLat, originLon],
          [destLat, destLon]
        ],
        distanceMeters: 5000,
        durationSeconds: 900,
        steps: [
          OSRMStep(
            instruction: 'Proceed from origin toward destination',
            name: 'Direct Path',
            distanceMeters: 5000,
            durationSeconds: 900,
            modifier: 'straight',
            type: 'depart',
          )
        ],
      )
    ];
  }
}
