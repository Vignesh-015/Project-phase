import 'dart:convert';
import 'package:http/http.dart' as http;

class NominatimPlace {
  final String displayName;
  final String shortName;
  final double lat;
  final double lon;
  final String type;

  NominatimPlace({
    required this.displayName,
    required this.shortName,
    required this.lat,
    required this.lon,
    required this.type,
  });

  factory NominatimPlace.fromJson(Map<String, dynamic> json) {
    final rawName = json['display_name'] ?? '';
    final parts = rawName.split(',');
    final short = parts.isNotEmpty ? parts.first.trim() : rawName;

    return NominatimPlace(
      displayName: rawName,
      shortName: short,
      lat: double.parse(json['lat'].toString()),
      lon: double.parse(json['lon'].toString()),
      type: json['type'] ?? 'place',
    );
  }
}

/// Geocoding Service powered by OpenStreetMap Nominatim API.
class NominatimService {
  static final Map<String, List<NominatimPlace>> _cache = {};

  /// Search locations in Chennai matching query.
  static Future<List<NominatimPlace>> searchPlaces(String query) async {
    if (query.trim().length < 2) return [];
    final q = query.trim().toLowerCase();

    if (_cache.containsKey(q)) {
      return _cache[q]!;
    }

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent('$query Chennai')}&format=json&limit=5&addressdetails=1',
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'FlexiTransitAI/1.0 (transit-app@flexitransit.org)',
          'Accept-Language': 'en-US,en;q=0.9',
        },
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final List list = json.decode(response.body);
        final results = list
            .map((item) => NominatimPlace.fromJson(item))
            .where((p) => p.lat >= 12.7 && p.lat <= 13.3 && p.lon >= 79.7 && p.lon <= 80.4)
            .toList();

        _cache[q] = results;
        return results;
      }
    } catch (_) {
      // Return empty if network request fails or times out
    }
    return [];
  }
}
