import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'transit_router_engine.dart';

class ApiService {
  static String get _baseUrl =>
      kIsWeb ? 'http://localhost:8000' : 'http://10.0.2.2:8000';

  static String get baseUrl => _baseUrl;

  /// Fetch route options for origin → destination using the Multi-Modal GTFS Router Engine
  static Future<List<RouteOption>> getRoutes({
    required double originLat,
    required double originLon,
    required double destLat,
    required double destLon,
    String depTime = '08:00',
  }) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/route').replace(queryParameters: {
        'origin_lat': originLat.toString(),
        'origin_lon': originLon.toString(),
        'dest_lat': destLat.toString(),
        'dest_lon': destLon.toString(),
        'dep_time': depTime,
      });

      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final rawOptions = data['options'] as List? ?? [];
        if (rawOptions.isNotEmpty) {
          return rawOptions
              .map((o) => RouteOption.fromJson(o as Map<String, dynamic>))
              .toList();
        }
      }
    } catch (e) {
      debugPrint('[ApiService] Backend route call failed, falling back to local engine: $e');
    }

    // Local fallback: Dynamic Multi-Modal Generalized Transit Router Engine
    return await TransitRouterEngine.computeRoutes(
      originLat: originLat,
      originLon: originLon,
      destLat: destLat,
      destLon: destLon,
      depTime: depTime,
    );
  }


  /// Upload telemetry batch to backend
  static Future<bool> uploadTelemetry(List<TelemetryPoint> points) async {
    try {
      final body = json.encode({
        'points': points.map((p) => p.toJson()).toList(),
      });

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/telemetry/ingest'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Health check
  static Future<bool> isBackendReachable() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
