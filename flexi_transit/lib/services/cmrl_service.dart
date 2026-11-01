import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/models.dart';

/// Loads and provides access to CMRL Metro station and line GTFS data bundled as JSON assets.
class CmrlService {
  static List<CmrlStop> _stops = [];
  static List<CmrlShape> _shapes = [];
  static bool _loaded = false;

  /// Load CMRL data from Flutter assets.
  static Future<void> loadData() async {
    if (_loaded) return;

    try {
      final stopsJson = await rootBundle.loadString('assets/data/cmrl_stops.json');
      final stopsList = json.decode(stopsJson) as List;
      _stops = stopsList.map((e) => CmrlStop.fromJson(e)).toList();

      final shapesJson = await rootBundle.loadString('assets/data/cmrl_shapes.json');
      final shapesList = json.decode(shapesJson) as List;
      _shapes = shapesList.map((e) => CmrlShape.fromJson(e)).toList();

      _loaded = true;
    } catch (e, stack) {
      print('[CMRL SERVICE ERROR] Failed to load CMRL assets: $e\n$stack');
      _stops = [];
      _shapes = [];
      _loaded = true;
    }
  }

  /// All CMRL Metro stations.
  static List<CmrlStop> get stops => _stops;

  /// All CMRL Metro line shapes.
  static List<CmrlShape> get shapes => _shapes;

  /// Total count of CMRL stations.
  static int get stopCount => _stops.length;

  /// Search CMRL Metro stations matching query.
  static List<CmrlStop> searchStops(String query) {
    if (query.trim().isEmpty) return [];
    final q = query.toLowerCase().trim();
    return _stops.where((s) => s.stopName.toLowerCase().contains(q)).toList();
  }

  /// Check if data has been loaded.
  static bool get isLoaded => _loaded;
}
