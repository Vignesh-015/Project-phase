// FlexiTransit-AI Models

// ─────────────────────────────────────────────────────────────────────────────
// Route Option Model
// ─────────────────────────────────────────────────────────────────────────────
class JourneyStep {
  final String mode;
  final String fromStop;
  final String toStop;
  final List<double> fromCoords;
  final List<double> toCoords;
  final String departureTime;
  final String arrivalTime;
  final double durationMin;
  final double fareInr;
  final String instruction;
  final List<List<double>> polyline;
  final String busNumbers; // e.g. '15B / 15C / 23C'

  JourneyStep({
    required this.mode,
    required this.fromStop,
    required this.toStop,
    required this.fromCoords,
    required this.toCoords,
    required this.departureTime,
    required this.arrivalTime,
    required this.durationMin,
    required this.fareInr,
    required this.instruction,
    required this.polyline,
    this.busNumbers = '',
  });

  factory JourneyStep.fromJson(Map<String, dynamic> json) {
    return JourneyStep(
      mode: json['mode'] ?? '',
      fromStop: json['from_stop'] ?? '',
      toStop: json['to_stop'] ?? '',
      fromCoords: (json['from_coords'] as List? ?? [0.0, 0.0])
          .map((e) => (e as num).toDouble())
          .toList(),
      toCoords: (json['to_coords'] as List? ?? [0.0, 0.0])
          .map((e) => (e as num).toDouble())
          .toList(),
      departureTime: json['departure_time'] ?? '',
      arrivalTime: json['arrival_time'] ?? '',
      durationMin: (json['duration_min'] ?? 0).toDouble(),
      fareInr: (json['fare_inr'] ?? 0).toDouble(),
      instruction: json['instruction'] ?? '',
      polyline: (json['polyline'] as List? ?? [])
          .map((p) => (p as List).map((e) => (e as num).toDouble()).toList())
          .toList(),
      busNumbers: json['bus_numbers'] ?? '',
    );
  }

  String get modeIcon {
    switch (mode) {
      case 'walk':
        return '🚶';
      case 'feeder':
      case 'auto':
        return '🛺';
      case 'metro':
        return '🚇';
      case 'bus':
        return '🚌';
      case 'cab':
        return '🚕';
      default:
        return '➡️';
    }
  }

  String get modeLabel {
    switch (mode) {
      case 'walk':
        return 'Walk';
      case 'feeder':
        return 'Feeder Auto';
      case 'auto':
        return 'Shared Auto';
      case 'metro':
        return 'Metro';
      case 'bus':
        return 'Bus';
      case 'cab':
        return 'Cab';
      default:
        return 'Transit';
    }
  }

  int get modeColorHex {
    switch (mode) {
      case 'walk':
        return 0xFF4A5568; // Dashed dark gray
      case 'feeder':
        return 0xFFED8936; // Vibrant orange/amber
      case 'auto':
        return 0xFFFFB800;
      case 'metro':
        return 0xFF00529B; // Blue Line / Green Line
      case 'bus':
        return 0xFFFF6B35;
      case 'cab':
        return 0xFFEF4444;
      default:
        return 0xFF6B7280;
    }
  }
}

class TransferHub {
  final String hubName;
  final double lat;
  final double lon;
  final String description;

  TransferHub({
    required this.hubName,
    required this.lat,
    required this.lon,
    required this.description,
  });

  factory TransferHub.fromJson(Map<String, dynamic> json) {
    return TransferHub(
      hubName: json['hub_name'] ?? '',
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      description: json['description'] ?? '',
    );
  }
}

class RouteOption {
  final String optionType;
  final String label;
  final String emoji;
  final double totalTimeMin;
  final double totalFareInr;
  final int transfers;
  final double co2Grams;
  final String color;
  final List<List<double>> polyline;
  final List<JourneyStep> steps;
  final List<TransferHub> transferHubs;

  RouteOption({
    required this.optionType,
    required this.label,
    required this.emoji,
    required this.totalTimeMin,
    required this.totalFareInr,
    required this.transfers,
    required this.co2Grams,
    required this.color,
    required this.polyline,
    required this.steps,
    this.transferHubs = const [],
  });

  factory RouteOption.fromJson(Map<String, dynamic> json) {
    final rawHubs = json['transfer_hubs'] as List? ?? [];
    return RouteOption(
      optionType: json['option_type'] ?? '',
      label: json['label'] ?? '',
      emoji: json['emoji'] ?? '',
      totalTimeMin: (json['total_time_min'] ?? 0).toDouble(),
      totalFareInr: (json['total_fare_inr'] ?? 0).toDouble(),
      transfers: (json['transfers'] ?? 0).toInt(),
      co2Grams: (json['co2_grams'] ?? 0).toDouble(),
      color: json['color'] ?? '#00D4AA',
      polyline: (json['polyline'] as List? ?? [])
          .map((p) => (p as List).map((e) => (e as num).toDouble()).toList())
          .toList(),
      steps: (json['steps'] as List? ?? [])
          .map((s) => JourneyStep.fromJson(s))
          .toList(),
      transferHubs: rawHubs.map((h) => TransferHub.fromJson(h)).toList(),
    );
  }

  String get totalTimeFormatted {
    final h = (totalTimeMin / 60).floor();
    final m = (totalTimeMin % 60).round();
    if (h > 0) return '${h}h ${m}m';
    return '$m min';
  }

  String get fareFormatted => '₹${totalFareInr.toStringAsFixed(0)}';

  int get colorHex {
    final hex = color.replaceFirst('#', '');
    return int.parse('FF$hex', radix: 16);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Virtual Feeder Stop Model (Mined Paratransit)
// ─────────────────────────────────────────────────────────────────────────────
class VirtualFeederStop {
  final String stopId;
  final String stopName;
  final String stopType; // 'TERMINAL_ORIGIN', 'INTERMEDIATE_VIRTUAL_STOP', 'TERMINAL_DESTINATION'
  final double lat;
  final double lon;
  final double distanceFromOriginM;
  final int tripSupportCount;
  final double avgDwellTimeSec;
  final String corridorName;
  final String mode; // 'INFORMAL_SHARED_AUTO'

  VirtualFeederStop({
    required this.stopId,
    required this.stopName,
    required this.stopType,
    required this.lat,
    required this.lon,
    required this.distanceFromOriginM,
    required this.tripSupportCount,
    required this.avgDwellTimeSec,
    required this.corridorName,
    this.mode = 'INFORMAL_SHARED_AUTO',
  });

  factory VirtualFeederStop.fromJson(Map<String, dynamic> json) {
    return VirtualFeederStop(
      stopId: json['stop_id'] ?? '',
      stopName: json['stop_name'] ?? 'Virtual Stop',
      stopType: json['stop_type'] ?? 'INTERMEDIATE_VIRTUAL_STOP',
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      distanceFromOriginM: (json['distance_from_origin_m'] ?? 0.0).toDouble(),
      tripSupportCount: (json['trip_support_count'] ?? 0).toInt(),
      avgDwellTimeSec: (json['avg_dwell_time_sec'] ?? 30.0).toDouble(),
      corridorName: json['corridor_name'] ?? '',
      mode: json['mode'] ?? 'INFORMAL_SHARED_AUTO',
    );
  }

  bool get isTerminal =>
      stopType == 'TERMINAL_ORIGIN' || stopType == 'TERMINAL_DESTINATION';
}

// ─────────────────────────────────────────────────────────────────────────────
// Feeder Corridor Model (Mined Centerline Alignment)
// ─────────────────────────────────────────────────────────────────────────────
class FeederCorridor {
  final String corridorName;
  final double distanceM;
  final List<List<double>> polyline; // [[lat, lon], ...]
  final List<VirtualFeederStop> stops;

  FeederCorridor({
    required this.corridorName,
    required this.distanceM,
    required this.polyline,
    required this.stops,
  });

  factory FeederCorridor.fromJson(Map<String, dynamic> json) {
    final rawStops = json['stops'] as List? ?? [];
    final rawPoly = json['polyline'] as List? ?? [];
    return FeederCorridor(
      corridorName: json['corridor_name'] ?? '',
      distanceM: (json['distance_m'] ?? 0.0).toDouble(),
      polyline: rawPoly
          .map((p) => [(p[0] as num).toDouble(), (p[1] as num).toDouble()])
          .toList(),
      stops: rawStops.map((s) => VirtualFeederStop.fromJson(s)).toList(),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Telemetry Point Model
// ─────────────────────────────────────────────────────────────────────────────
class TelemetryPoint {
  final String traceId;
  final String deviceId;
  final double latitude;
  final double longitude;
  final double speed;
  final double bearing;
  final String timestamp;
  final String sourceType;

  TelemetryPoint({
    required this.traceId,
    required this.deviceId,
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.bearing,
    required this.timestamp,
    required this.sourceType,
  });

  Map<String, dynamic> toJson() => {
        'trace_id': traceId,
        'device_id': deviceId,
        'latitude': latitude,
        'longitude': longitude,
        'speed': speed,
        'bearing': bearing,
        'timestamp': timestamp,
        'source_type': sourceType,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// MTC Bus Stop Model
// ─────────────────────────────────────────────────────────────────────────────
class MtcStop {
  final String stopId;
  final String stopName;
  final double lat;
  final double lon;
  final int tripCount;   // number of trips serving this stop
  final String freq;     // 'high' | 'medium' | 'low'

  MtcStop({
    required this.stopId,
    required this.stopName,
    required this.lat,
    required this.lon,
    required this.tripCount,
    required this.freq,
  });

  factory MtcStop.fromJson(Map<String, dynamic> json) {
    return MtcStop(
      stopId:    json['id']?.toString() ?? '',
      stopName:  json['name'] ?? '',
      lat:       (json['lat'] as num).toDouble(),
      lon:       (json['lon'] as num).toDouble(),
      tripCount: (json['trips'] ?? 0).toInt(),
      freq:      json['freq'] ?? 'low',
    );
  }

  /// Color intensity based on frequency
  int get freqColorHex {
    switch (freq) {
      case 'high':
        return 0xFF00E676;   // vivid green
      case 'medium':
        return 0xFF69F0AE;   // medium green
      default:
        return 0xFF1DE9B6;   // teal-green
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MTC Route Model
// ─────────────────────────────────────────────────────────────────────────────
class MtcRoute {
  final String routeId;
  final String shortName;
  final String longName;

  MtcRoute({
    required this.routeId,
    required this.shortName,
    required this.longName,
  });

  factory MtcRoute.fromJson(Map<String, dynamic> json) {
    return MtcRoute(
      routeId:   json['route_id']?.toString() ?? '',
      shortName: json['short_name'] ?? '',
      longName:  json['long_name'] ?? '',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CMRL Metro Station Model
// ─────────────────────────────────────────────────────────────────────────────
class CmrlStop {
  final String stopId;
  final String stopName;
  final double lat;
  final double lon;
  final String line;
  final String colorHex;
  final bool isInterchange;
  final int peakFreqMin;
  final String firstTrain;
  final String lastTrain;

  CmrlStop({
    required this.stopId,
    required this.stopName,
    required this.lat,
    required this.lon,
    required this.line,
    required this.colorHex,
    required this.isInterchange,
    required this.peakFreqMin,
    required this.firstTrain,
    required this.lastTrain,
  });

  factory CmrlStop.fromJson(Map<String, dynamic> json) {
    return CmrlStop(
      stopId:        json['id']?.toString() ?? '',
      stopName:      json['name'] ?? '',
      lat:           (json['lat'] as num).toDouble(),
      lon:           (json['lon'] as num).toDouble(),
      line:          json['line'] ?? 'CMRL Metro',
      colorHex:      json['color'] ?? '#00B0FF',
      isInterchange: json['interchange'] ?? false,
      peakFreqMin:   (json['peak_freq_min'] ?? 6).toInt(),
      firstTrain:    json['first_train'] ?? '05:00',
      lastTrain:     json['last_train'] ?? '23:00',
    );
  }

  int get parsedColorHex {
    final hex = colorHex.replaceFirst('#', '');
    return int.parse('FF$hex', radix: 16);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CMRL Metro Shape Model
// ─────────────────────────────────────────────────────────────────────────────
class CmrlShape {
  final String shapeId;
  final String name;
  final String colorHex;
  final List<List<double>> polyline;

  CmrlShape({
    required this.shapeId,
    required this.name,
    required this.colorHex,
    required this.polyline,
  });

  factory CmrlShape.fromJson(Map<String, dynamic> json) {
    return CmrlShape(
      shapeId:  json['shape_id'] ?? '',
      name:     json['name'] ?? '',
      colorHex: json['color'] ?? '#00B0FF',
      polyline: (json['polyline'] as List? ?? [])
          .map((p) => List<double>.from(p))
          .toList(),
    );
  }

  int get parsedColorHex {
    final hex = colorHex.replaceFirst('#', '');
    return int.parse('FF$hex', radix: 16);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Geocoded Location Model (Photon / OSM)
// ─────────────────────────────────────────────────────────────────────────────
class GeocodedLocation {
  final String name;
  final String address;
  final double lat;
  final double lon;
  final String type;
  final String providerId;

  GeocodedLocation({
    required this.name,
    required this.address,
    required this.lat,
    required this.lon,
    required this.type,
    this.providerId = 'osm',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'address': address,
        'latitude': lat,
        'longitude': lon,
        'type': type,
        'provider_id': providerId,
      };

  factory GeocodedLocation.fromPhotonJson(Map<String, dynamic> feature) {
    final props = feature['properties'] as Map<String, dynamic>? ?? {};
    final coords = feature['geometry']['coordinates'] as List? ?? [0.0, 0.0];

    final name = props['name'] ?? props['street'] ?? props['district'] ?? props['city'] ?? 'Selected Location';
    final parts = <String>[];
    if (props.containsKey('street')) parts.add(props['street']);
    if (props.containsKey('district')) parts.add(props['district']);
    if (props.containsKey('city')) parts.add(props['city']);
    if (props.containsKey('state')) parts.add(props['state']);
    if (props.containsKey('country')) parts.add(props['country']);

    final address = parts.isNotEmpty ? parts.join(', ') : (props['country'] ?? name);

    return GeocodedLocation(
      name: name,
      address: address,
      lat: (coords[1] as num).toDouble(),
      lon: (coords[0] as num).toDouble(),
      type: props['osm_type'] ?? props['type'] ?? 'place',
      providerId: 'photon_${props["osm_id"] ?? ""}',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OSRM Route & Turn-by-Turn Models
// ─────────────────────────────────────────────────────────────────────────────
class OSRMStep {
  final String instruction;
  final String name;
  final double distanceMeters;
  final double durationSeconds;
  final String modifier;
  final String type;

  OSRMStep({
    required this.instruction,
    required this.name,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.modifier,
    required this.type,
  });

  factory OSRMStep.fromOsrmJson(Map<String, dynamic> json) {
    final maneuver = json['maneuver'] as Map<String, dynamic>? ?? {};
    final typeStr = maneuver['type'] ?? 'turn';
    final modStr = maneuver['modifier'] ?? '';
    final streetName = json['name'] ?? '';

    String text;
    if (typeStr == 'depart') {
      text = 'Head ${modStr.isNotEmpty ? modStr : "forward"} on ${streetName.isNotEmpty ? streetName : "the road"}';
    } else if (typeStr == 'arrive') {
      text = 'Arrive at destination';
    } else if (typeStr == 'turn') {
      text = 'Turn ${modStr.isNotEmpty ? modStr : "onto"} ${streetName.isNotEmpty ? streetName : "next road"}';
    } else if (typeStr == 'new name' || typeStr == 'continue') {
      text = 'Continue on ${streetName.isNotEmpty ? streetName : "the road"}';
    } else {
      text = '${typeStr.toUpperCase()} ${modStr.isNotEmpty ? modStr : ""} on ${streetName.isNotEmpty ? streetName : "road"}';
    }

    return OSRMStep(
      instruction: text,
      name: streetName,
      distanceMeters: (json['distance'] ?? 0).toDouble(),
      durationSeconds: (json['duration'] ?? 0).toDouble(),
      modifier: modStr,
      type: typeStr,
    );
  }

  String get distanceFormatted {
    if (distanceMeters >= 1000) {
      return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
    }
    return '${distanceMeters.toStringAsFixed(0)} m';
  }
}

class OSRMRoute {
  final List<List<double>> polyline;
  final double distanceMeters;
  final double durationSeconds;
  final List<OSRMStep> steps;

  OSRMRoute({
    required this.polyline,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.steps,
  });

  String get distanceKmFormatted => '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  String get durationMinFormatted => '${(durationSeconds / 60).round()} min';
}



