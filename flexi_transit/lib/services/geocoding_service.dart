import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/models.dart';

/// OSM-Compatible Geocoding and Reverse Geocoding Service powered by Photon & Nominatim fallback.
class GeocodingService {
  static const String _photonBaseUrl = 'https://photon.komoot.io';
  static const String _nominatimBaseUrl = 'https://nominatim.openstreetmap.org';

  static final Map<String, List<GeocodedLocation>> _searchCache = {};
  static final Map<String, String> _reverseCache = {};

  static int _activeRequestId = 0;

  /// Search places, streets, areas, and buildings using Photon API with Chennai geographic bias.
  static Future<List<GeocodedLocation>> searchPlaces(
    String query, {
    double biasLat = 13.0827,
    double biasLon = 80.2707,
  }) async {
    final cleanQuery = query.trim().toLowerCase();
    if (cleanQuery.length < 2) return [];

    if (_searchCache.containsKey(cleanQuery)) {
      return _searchCache[cleanQuery]!;
    }

    final currentId = ++_activeRequestId;

    try {
      final uri = Uri.parse(
        '$_photonBaseUrl/api/?q=${Uri.encodeComponent(query)}&lat=$biasLat&lon=$biasLon&location_bias_scale=0.6&limit=10',
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'FlexiTransitAI/1.0 (transit-app@flexitransit.org)',
          'Accept-Language': 'en',
        },
      ).timeout(const Duration(seconds: 4));

      // Stale response check: ignore if a newer request was dispatched
      if (currentId != _activeRequestId) return [];

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final features = data['features'] as List? ?? [];
        final results = features
            .map((f) => GeocodedLocation.fromPhotonJson(f))
            .toList();

        _searchCache[cleanQuery] = results;
        return results;
      }
    } catch (_) {
      // Ignore network timeout or errors
    }

    return [];
  }

  /// Reverse geocode coordinates to human-readable address.
  static Future<String> reverseGeocode(double lat, double lon) async {
    final cacheKey = '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}';
    if (_reverseCache.containsKey(cacheKey)) {
      return _reverseCache[cacheKey]!;
    }

    // Try Photon Reverse Geocoder first
    try {
      final photonUri = Uri.parse('$_photonBaseUrl/reverse?lat=$lat&lon=$lon');
      final response = await http.get(photonUri).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final features = data['features'] as List? ?? [];
        if (features.isNotEmpty) {
          final loc = GeocodedLocation.fromPhotonJson(features.first);
          final address = '${loc.name}, ${loc.address}';
          _reverseCache[cacheKey] = address;
          return address;
        }
      }
    } catch (_) {}

    // Nominatim Reverse fallback
    try {
      final nomUri = Uri.parse(
        '$_nominatimBaseUrl/reverse?lat=$lat&lon=$lon&format=json',
      );
      final response = await http.get(
        nomUri,
        headers: {
          'User-Agent': 'FlexiTransitAI/1.0 (transit-app@flexitransit.org)',
        },
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final addressStr = data['display_name'] ?? '$lat, $lon';
        _reverseCache[cacheKey] = addressStr;
        return addressStr;
      }
    } catch (_) {}

    final rawFallback = '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}';
    return rawFallback;
  }
}
